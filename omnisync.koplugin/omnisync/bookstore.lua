--[[--
The book data side of the sync state database (omnisync/state.sqlite3): the
merged state of every book's properties (see bookformat.lua), what this
device's copy held when last looked at, what's waiting to be sent, and
where this device keeps each book. Main process only; every call is one
short transaction.

The merged state is a last-writer-wins map per book: for each property the
record with the highest (updated, device, hash) wins, a clear being a
record like any other (hash ""). Merging is idempotent and order
independent, and clears are kept, so a late old record can't bring a value
back.

KOReader keeps no times for these properties, so a change is dated when
it's noticed. Values this device already had before it first looked at a
book are older than that: they're dated from what the sidecar says (the
status's date, the custom metadata file's time), so they don't override
what other devices have sent since.

Tables:

    book_merged (md5, prop) -> updated, device, deleted, hash, value
    book_local  (md5, prop) -> hash: this device's copy, as last seen ("" = none)
    book_outbox (md5, prop) -> updated: changes to send
    book_books  md5 -> title, authors, write (closed-book properties to write here)
    book_files  path -> md5, sig: where this device has each book, and its
                sidecar's size and time when last read
    coll_files  path -> md5, sig: books in collections or the reading
                history, with the file's size and time when its MD5 was
                found (see collsync.lua)

Segments imported are recorded in seen_segments and bad_segments, like the
other streams' (names book-…).

Versions of a book: id_groups (kept by idstore.lua) says which MD5s are
the same book. A book's merged value of a property about the book (status,
rating, review, custom metadata: BookFormat.GROUP_PROPS) is then the winner
across all of them. id_pos says which of them have matching positions (the
same body); the handmade TOC and flows are the winner across those. Changes
are still recorded under the book's own MD5, so nothing on the server
changes and devices without the groups carry on as before.
--]]

local AnnFormat = require("omnisync/annformat")
local BookFormat = require("omnisync/bookformat")

local BookStore = {}
BookStore.__index = BookStore

local BUSY_TIMEOUT_MS = 5000

-- (No semicolons in SQL comments: ljsqlite3's exec splits on them.)
local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS book_merged (
        md5     TEXT NOT NULL,
        prop    TEXT NOT NULL,
        updated INTEGER NOT NULL,
        device  TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        hash    TEXT NOT NULL,
        value   TEXT,
        PRIMARY KEY (md5, prop)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS book_local (
        md5  TEXT NOT NULL,
        prop TEXT NOT NULL,
        hash TEXT NOT NULL,
        PRIMARY KEY (md5, prop)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS book_outbox (
        md5     TEXT NOT NULL,
        prop    TEXT NOT NULL,
        updated INTEGER NOT NULL,
        PRIMARY KEY (md5, prop)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS book_books (
        md5     TEXT PRIMARY KEY,
        title   TEXT,
        authors TEXT,
        write   INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS book_files (
        path TEXT PRIMARY KEY,
        md5  TEXT NOT NULL,
        sig  TEXT
    );
    CREATE INDEX IF NOT EXISTS book_files_md5 ON book_files (md5);
    CREATE TABLE IF NOT EXISTS coll_files (
        path TEXT PRIMARY KEY,
        md5  TEXT NOT NULL,
        sig  TEXT
    );
    CREATE INDEX IF NOT EXISTS coll_files_md5 ON coll_files (md5);
    CREATE TABLE IF NOT EXISTS id_groups (
        md5 TEXT PRIMARY KEY,
        grp TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS id_groups_grp ON id_groups (grp);
    CREATE TABLE IF NOT EXISTS id_pos (
        md5 TEXT PRIMARY KEY,
        grp TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS id_pos_grp ON id_pos (grp);
    CREATE TABLE IF NOT EXISTS seen_segments (
        device_id   TEXT    NOT NULL,
        name        TEXT    NOT NULL,
        size        INTEGER,
        etag        TEXT,
        imported_at INTEGER,
        events      INTEGER,
        PRIMARY KEY (device_id, name)
    );
]]

local function num(v) return v ~= nil and tonumber(v) or nil end

--- opts: sq3, state_path, md5 (function: string -> hex digest; default ffi/sha2)
function BookStore.new(opts)
    local self = setmetatable({}, BookStore)
    self.SQ3 = assert(opts.sq3, "sq3 module")
    self.state_path = assert(opts.state_path)
    self.md5 = opts.md5 or require("ffi/sha2").md5
    return self
end

function BookStore:open()
    local conn = self.SQ3.open(self.state_path)
    conn:set_busy_timeout(BUSY_TIMEOUT_MS)
    conn:exec(SCHEMA)
    return conn
end

local function packn(...) return { n = select("#", ...), ... } end

function BookStore:_tx(fn)
    local conn = self:open()
    conn:exec("BEGIN IMMEDIATE;")
    local res = packn(pcall(fn, conn))
    if res[1] then
        local ok, err = pcall(conn.exec, conn, "COMMIT;")
        if not ok then res = { false, err, n = 2 } end
    end
    if not res[1] then pcall(conn.exec, conn, "ROLLBACK;") end
    conn:close()
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

function BookStore:_read(fn)
    local conn = self:open()
    local res = packn(pcall(fn, conn))
    conn:close()
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

local function rows(stmt)
    local out = {}
    local r = stmt:step()
    while r do
        out[#out + 1] = r
        r = stmt:step()
    end
    stmt:close()
    return out
end

--- Does record a win over record b (either may be nil)?
function BookStore.wins(a, b)
    if not a then return false end
    if not b then return true end
    if a.updated ~= b.updated then return a.updated > b.updated end
    if a.device ~= b.device then return a.device > b.device end
    return a.hash > b.hash
end

local function loadMerged(conn, md5)
    local stmt = conn:prepare("SELECT prop, updated, device, deleted, hash, value FROM book_merged WHERE md5 = ?;")
    stmt:bind(md5)
    local map = {}
    for _, r in ipairs(rows(stmt)) do
        map[r[1]] = { updated = num(r[2]), device = r[3], deleted = num(r[4]) == 1, hash = r[5], value = r[6] }
    end
    return map
end

--- The MD5s of the book's versions, its own first.
local function groupOf(conn, md5)
    local stmt = conn:prepare([[
        SELECT g.md5 FROM id_groups g JOIN id_groups me ON me.grp = g.grp
        WHERE me.md5 = ? AND g.md5 <> me.md5 ORDER BY g.md5;]])
    stmt:bind(md5)
    local out = { md5 }
    for _, r in ipairs(rows(stmt)) do out[#out + 1] = r[1] end
    return out
end

--- The versions of the book whose positions match this one's.
local function positionPeers(conn, md5)
    local stmt = conn:prepare([[
        SELECT g.md5 FROM id_pos me JOIN id_pos g ON g.grp = me.grp AND g.md5 <> me.md5
        WHERE me.md5 = ?;]])
    stmt:bind(md5)
    local out = {}
    for _, r in ipairs(rows(stmt)) do out[r[1]] = true end
    return out
end

--- The merged state as it applies to this book: its own records, with
-- the properties about the book taken from whichever version's record
-- wins, and those holding positions from whichever version with matching
-- positions.
local function loadEffective(conn, md5)
    local eff = loadMerged(conn, md5)
    local group = groupOf(conn, md5)
    local peers = #group > 1 and positionPeers(conn, md5) or {}
    for i = 2, #group do
        local same_pos = peers[group[i]]
        for prop, m in pairs(loadMerged(conn, group[i])) do
            if (BookFormat.isGroupProp(prop) or (same_pos and BookFormat.isPositionProp(prop)))
                    and BookStore.wins(m, eff[prop]) then
                eff[prop] = m
            end
        end
    end
    return eff
end

local function loadLocal(conn, md5)
    local stmt = conn:prepare("SELECT prop, hash FROM book_local WHERE md5 = ?;")
    stmt:bind(md5)
    local map = {}
    for _, r in ipairs(rows(stmt)) do map[r[1]] = r[2] end
    return map
end

local function putMerged(conn, md5, prop, rec)
    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO book_merged (md5, prop, updated, device, deleted, hash, value)
        VALUES (?, ?, ?, ?, ?, ?, ?);]])
    stmt:bind(md5, prop, rec.updated, rec.device, rec.deleted and 1 or 0, rec.hash, rec.value):step()
    stmt:close()
end

local function putOutbox(conn, md5, prop, updated)
    local stmt = conn:prepare("INSERT OR REPLACE INTO book_outbox (md5, prop, updated) VALUES (?, ?, ?);")
    stmt:bind(md5, prop, updated):step()
    stmt:close()
end

local function putLocal(conn, md5, prop, hash)
    local stmt = conn:prepare("INSERT OR REPLACE INTO book_local (md5, prop, hash) VALUES (?, ?, ?);")
    stmt:bind(md5, prop, hash):step()
    stmt:close()
end

local function ensureBook(conn, md5, info)
    local stmt = conn:prepare("INSERT OR IGNORE INTO book_books (md5, title, authors) VALUES (?, ?, ?);")
    stmt:bind(md5, info and info.title, info and info.authors):step()
    stmt:close()
end

--- Does the merged record differ from this device's copy (hash, "" for none)?
local function differs(m, hash)
    if m.deleted then return hash ~= nil and hash ~= "" end
    return hash ~= m.hash
end

-- Is anything to be written into this book while it's closed?
local function updateWrite(conn, md5, merged, loc)
    local write = false
    for prop, m in pairs(merged) do
        if BookFormat.CLOSED_PROPS[prop] and loc[prop] ~= nil and differs(m, loc[prop]) then
            write = true
            break
        end
    end
    local stmt = conn:prepare("UPDATE book_books SET write = ? WHERE md5 = ?;")
    stmt:bind(write and 1 or 0, md5):step()
    stmt:close()
    return write
end

--- Looks again at what's to be written into these books and their other
-- versions. md5s = { [md5] = true }. Returns the set with the versions added.
local function updateWriteGroups(conn, md5s)
    local all = {}
    for md5 in pairs(md5s) do
        for _, m in ipairs(groupOf(conn, md5)) do all[m] = true end
    end
    local known = conn:prepare("SELECT 1 FROM book_books WHERE md5 = ?;")
    for md5 in pairs(all) do
        if known:reset():bind(md5):step() then
            updateWrite(conn, md5, loadEffective(conn, md5), loadLocal(conn, md5))
        end
    end
    known:close()
    return all
end

--- Encodes current values: prop -> { hash, json } ("" and nil for none).
-- Values that can't be encoded are left out (and counted).
function BookStore:snapshot(values)
    local snap, skipped = {}, 0
    for prop, v in pairs(values) do
        if v == false or v == nil then
            snap[prop] = { hash = "" }
        else
            local json = AnnFormat.encodeValue(v)
            if json and BookFormat.validValue(prop, AnnFormat.decodeValue(json)) then
                snap[prop] = { hash = self.md5(json), json = json }
            else
                skipped = skipped + 1
            end
        end
    end
    return snap, skipped
end

-- Local changes -------------------------------------------------------------------

--- Compares a book's current properties with what this device saw last
-- time, and records the changes as this device's. opts: md5, values
-- ({ [prop] = value, or false for none }: only these properties are looked
-- at), now, device, title, authors, path and sig (where the book is, and
-- its sidecar's signature), fresh (look at it as if for the first time: its
-- settings were reset), times ({ [prop] = epoch }: how old the values were
-- before this device first looked; default 0).
--
-- Rules:
-- - First look (or fresh): values are recorded with their old times, so
--   they only win over what the merged state lacks or holds older. No
--   clears.
-- - A changed value afterwards is recorded as changed now; a value gone is
--   a clear.
-- - Status: KOReader always has one once a book has been opened, and sets
--   "reading" when there's none. So a missing status isn't a clear, and
--   "reading" where there was none is as old as can be.
--
-- Returns { changed, skipped, write }.
function BookStore:observe(opts)
    return self:_tx(function(conn) return self:_observeIn(conn, opts) end)
end

--- observe() for several books in one transaction. Returns the summaries.
function BookStore:observeMany(list)
    if #list == 0 then return {} end
    return self:_tx(function(conn)
        local out = {}
        for i, opts in ipairs(list) do out[i] = self:_observeIn(conn, opts) end
        return out
    end)
end

function BookStore:_observeIn(conn, opts)
    local md5, now, device = opts.md5, opts.now, opts.device
    local snap, skipped = self:snapshot(opts.values)
    local times = opts.times or {}
    ensureBook(conn, md5, opts)
    if opts.title or opts.authors then
        local up = conn:prepare("UPDATE book_books SET title = coalesce(?, title), authors = coalesce(?, authors) WHERE md5 = ?;")
        up:bind(opts.title, opts.authors, md5):step()
        up:close()
    end
    if opts.path then
        local f = conn:prepare("INSERT OR REPLACE INTO book_files (path, md5, sig) VALUES (?, ?, ?);")
        f:bind(opts.path, md5, opts.sig):step()
        f:close()
    end
    local merged = loadMerged(conn, md5)
    local eff = loadEffective(conn, md5)
    local loc = loadLocal(conn, md5)
    local res = { changed = 0, skipped = skipped }

    -- Recorded under this book's own MD5; compared with what applies
    -- to it (its versions' records too) to tell whether it changed.
    local function record(prop, rec)
        if BookStore.wins(rec, merged[prop]) then
            putMerged(conn, md5, prop, rec)
            putOutbox(conn, md5, prop, rec.updated)
            merged[prop] = rec
            if BookStore.wins(rec, eff[prop]) then eff[prop] = rec end
            res.changed = res.changed + 1
        end
    end

    for prop, s in pairs(snap) do
        local prev = loc[prop]
        local first = opts.fresh or prev == nil
        local m = eff[prop]
        local same = m and not m.deleted and m.hash == s.hash
        if s.hash == "" then
            if not first and prev ~= "" and prop ~= "status" and not (m and m.deleted) then
                record(prop, { updated = now, device = device, deleted = true, hash = "" })
            end
        elseif not same and (first or prev ~= s.hash) then
            local upd = now
            if first then upd = times[prop] or 0 end
            if prop == "status" and (first or prev == "") and AnnFormat.decodeValue(s.json) == "reading" then
                upd = 0
            end
            record(prop, { updated = upd, device = device, deleted = false, hash = s.hash, value = s.json })
        end
        putLocal(conn, md5, prop, s.hash)
        loc[prop] = s.hash
    end
    res.write = updateWrite(conn, md5, eff, loc)
    return res
end

-- Applying the merged state ----------------------------------------------------------

--- What to change in a book to match the merged state: the properties in
-- `values` (current values, as for observe) whose merged value differs.
-- Returns { { prop, value (nil to clear), updated }, … }, sorted by prop.
function BookStore:plan(md5, values)
    local snap = self:snapshot(values)
    return self:_read(function(conn)
        local merged = loadEffective(conn, md5)
        local ops = {}
        for prop, s in pairs(snap) do
            local m = merged[prop]
            if m and BookFormat.known(prop) and differs(m, s.hash) then
                if m.deleted then
                    ops[#ops + 1] = { prop = prop, updated = m.updated }
                else
                    local v = AnnFormat.decodeValue(m.value)
                    if v ~= nil then ops[#ops + 1] = { prop = prop, value = v, updated = m.updated } end
                end
            end
        end
        table.sort(ops, function(a, b) return a.prop < b.prop end)
        return ops
    end)
end

--- Records the values as this device's copy after applying (so applied
-- changes aren't taken for local ones). Returns whether closed-book
-- properties are still to be written.
function BookStore:applied(md5, values, path, sig)
    local snap = self:snapshot(values)
    return self:_tx(function(conn)
        ensureBook(conn, md5)
        for prop, s in pairs(snap) do putLocal(conn, md5, prop, s.hash) end
        if path then
            local f = conn:prepare("INSERT OR REPLACE INTO book_files (path, md5, sig) VALUES (?, ?, ?);")
            f:bind(path, md5, sig):step()
            f:close()
        end
        return updateWrite(conn, md5, loadEffective(conn, md5), loadLocal(conn, md5))
    end)
end

--- applied() for several books in one transaction: list = { { md5, values }, … }.
function BookStore:appliedMany(list)
    if #list == 0 then return end
    return self:_tx(function(conn)
        for _, a in ipairs(list) do
            ensureBook(conn, a.md5)
            for prop, s in pairs(self:snapshot(a.values)) do putLocal(conn, a.md5, prop, s.hash) end
        end
    end)
end

-- Collections ---------------------------------------------------------------------------

local IS_COLL = "substr(prop, 1, 5) = 'coll.'"

--- This device's copy of collection properties, as last seen:
-- { [md5] = { [prop] = hash } } (the collections record included).
function BookStore:localColl()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare("SELECT md5, prop, hash FROM book_local WHERE " .. IS_COLL .. ";"))) do
            out[r[1]] = out[r[1]] or {}
            out[r[1]][r[2]] = r[3]
        end
        return out
    end)
end

--- Forgets this device's copy of a book's collection properties (the book
-- is gone from this device: that's not a removal from its collections).
function BookStore:forgetLocalColl(md5)
    return self:_tx(function(conn)
        local stmt = conn:prepare("DELETE FROM book_local WHERE md5 = ? AND " .. IS_COLL .. ";")
        stmt:bind(md5):step()
        stmt:close()
    end)
end

--- The merged collections: { [id] = { name, deleted, updated } }.
function BookStore:collections()
    return self:_read(function(conn)
        local out = {}
        for prop, m in pairs(loadMerged(conn, BookFormat.COLLECTIONS)) do
            local id = BookFormat.collId(prop)
            local v = id and not m.deleted and AnnFormat.decodeValue(m.value)
            if id then
                out[id] = { deleted = m.deleted or type(v) ~= "table", updated = m.updated,
                            name = type(v) == "table" and v.name or nil }
            end
        end
        return out
    end)
end

--- The merged memberships that apply to these books (their versions'
-- records included): { [md5] = { [id] = in_it } }, only for books with any.
-- md5s = { [md5] = true }.
function BookStore:memberships(md5s)
    return self:_read(function(conn)
        local with = {}
        local stmt = conn:prepare("SELECT DISTINCT md5 FROM book_merged WHERE " .. IS_COLL .. " AND md5 <> ?;")
        stmt:bind(BookFormat.COLLECTIONS)
        for _, r in ipairs(rows(stmt)) do
            for _, m in ipairs(groupOf(conn, r[1])) do with[m] = true end
        end
        local out = {}
        for md5 in pairs(md5s) do
            if with[md5] then
                local map
                for prop, m in pairs(loadEffective(conn, md5)) do
                    local id = BookFormat.collId(prop)
                    if id then
                        map = map or {}
                        map[id] = not m.deleted
                    end
                end
                out[md5] = map
            end
        end
        return out
    end)
end

-- Reading history ------------------------------------------------------------------------

--- The reading history in the merged state, as it applies to each book
-- (its versions' records included): { [md5] = { time, hash, seen, group } }
-- for every book with a record and every version of one. seen is this
-- device's copy (hash) as last seen or applied, nil if none; group the
-- book's MD5s, its own first.
function BookStore:history()
    local HIST = BookFormat.HISTORY
    return self:_read(function(conn)
        local md5s = {}
        local stmt = conn:prepare("SELECT md5 FROM book_merged WHERE prop = ? AND deleted = 0;")
        stmt:bind(HIST)
        for _, r in ipairs(rows(stmt)) do
            for _, m in ipairs(groupOf(conn, r[1])) do md5s[m] = true end
        end
        local loc = conn:prepare("SELECT hash FROM book_local WHERE md5 = ? AND prop = ?;")
        local out = {}
        for md5 in pairs(md5s) do
            local m = loadEffective(conn, md5)[HIST]
            local t = m and not m.deleted and tonumber(AnnFormat.decodeValue(m.value))
            if t then
                local seen = loc:reset():bind(md5, HIST):step()
                out[md5] = { time = t, hash = m.hash, seen = seen and seen[1] or nil, group = groupOf(conn, md5) }
            end
        end
        loc:close()
        return out
    end)
end

--- path -> { md5, sig } for books whose MD5 was found for collections or
-- the reading history.
function BookStore:collFiles()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare("SELECT path, md5, sig FROM coll_files;"))) do
            out[r[1]] = { md5 = r[2], sig = r[3] }
        end
        return out
    end)
end

--- Records (md5 given) or forgets (md5 nil) books' MD5s: list = { { path, md5, sig }, … }.
function BookStore:setCollFiles(list)
    if #list == 0 then return end
    return self:_tx(function(conn)
        local put = conn:prepare("INSERT OR REPLACE INTO coll_files (path, md5, sig) VALUES (?, ?, ?);")
        local del = conn:prepare("DELETE FROM coll_files WHERE path = ?;")
        for _, f in ipairs(list) do
            if f.md5 then put:reset():bind(f.path, f.md5, f.sig):step()
            else del:reset():bind(f.path):step() end
        end
        put:close()
        del:close()
    end)
end

--- After the groups changed (IdStore:refreshGroups): looks again at what's
-- to be written into these books and their versions. md5s = { [md5] = true }.
-- Returns the set with the versions added.
function BookStore:regroup(md5s)
    return self:_tx(function(conn) return updateWriteGroups(conn, md5s) end)
end

-- Where books are -----------------------------------------------------------------------

--- path -> { md5, sig } for every book file seen on this device.
function BookStore:files()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare("SELECT path, md5, sig FROM book_files;"))) do
            out[r[1]] = { md5 = r[2], sig = r[3] }
        end
        return out
    end)
end

--- Forgets a book file that's gone from this device.
function BookStore:forgetFile(path)
    return self:_tx(function(conn)
        local stmt = conn:prepare("DELETE FROM book_files WHERE path = ?;")
        stmt:bind(path):step()
        stmt:close()
    end)
end

--- Book files with properties to write while closed: { { path, md5 }, … }.
function BookStore:toWrite()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare([[
            SELECT f.path, f.md5 FROM book_files f JOIN book_books b ON b.md5 = f.md5
            WHERE b.write = 1 ORDER BY f.path;]]))) do
            out[#out + 1] = { path = r[1], md5 = r[2] }
        end
        return out
    end)
end

-- Export --------------------------------------------------------------------------------

--- Writes a segment of the changes waiting to be sent. opts: device_id,
-- out_path, now, max_records. Returns nil when there's nothing to send, else
-- { records, books, more, size }. After a confirmed upload, call
-- markExported with the same file.
function BookStore:export(opts)
    return self:_read(function(conn)
        local stmt = conn:prepare([[
            SELECT o.md5, o.prop, m.updated, m.device, m.deleted, m.value
            FROM book_outbox o JOIN book_merged m ON m.md5 = o.md5 AND m.prop = o.prop
            ORDER BY o.md5, o.prop LIMIT ?;]])
        stmt:bind(opts.max_records)
        local recs = rows(stmt)
        if #recs == 0 then return nil end
        local md5s, nbooks = {}, 0
        local bstmt = conn:prepare("SELECT title, authors FROM book_books WHERE md5 = ?;")
        local lines = {}
        for _, r in ipairs(recs) do
            local md5 = r[1]
            if not md5s[md5] then
                md5s[md5] = true
                nbooks = nbooks + 1
                local b = bstmt:reset():bind(md5):step()
                lines[#lines + 1] = BookFormat.bookLine{ md5 = md5, title = b and b[1], authors = b and b[2] }
            end
            lines[#lines + 1] = BookFormat.recordLine{
                md5 = md5, prop = r[2], updated = num(r[3]), device = r[4],
                value_json = num(r[5]) ~= 1 and r[6] or nil,
            }
        end
        bstmt:close()
        local tmp = opts.out_path .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(BookFormat.headerLine(opts.device_id, opts.now), "\n")
        f:write(table.concat(lines, "\n"), "\n")
        f:write(BookFormat.trailerLine(nbooks, #recs), "\n")
        f:close()
        assert(os.rename(tmp, opts.out_path))
        local size = io.open(opts.out_path, "rb"):seek("end")
        return { records = #recs, books = nbooks, more = #recs >= opts.max_records, size = size }
    end)
end

local INSERT_SEEN = [[
    INSERT OR REPLACE INTO seen_segments (device_id, name, size, etag, imported_at, events)
    VALUES (?, ?, ?, ?, ?, ?);
]]

--- After a confirmed upload: what the segment holds is sent (unless it
-- changed again since), and the segment is seen.
function BookStore:markExported(path, device_id, name, size, etag, now)
    return self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM book_outbox WHERE md5 = ? AND prop = ? AND updated <= ?;")
        local header, err = BookFormat.readSegment(path, { record = function(r)
            del:reset():bind(r.md5, r.prop, r.upd):step()
        end })
        del:close()
        if not header then error(err, 0) end
        local stmt = conn:prepare(INSERT_SEEN)
        stmt:bind(device_id, name, size, etag, now, header.records):step()
        stmt:close()
        return header.records
    end)
end

--- Everything in the merged state is to be sent again (a new server or folder).
function BookStore:requeueAll()
    return self:_tx(function(conn)
        conn:exec("INSERT OR REPLACE INTO book_outbox (md5, prop, updated) SELECT md5, prop, updated FROM book_merged;")
    end)
end

-- Import --------------------------------------------------------------------------------

--- Merges a downloaded segment. Returns { records, applied, affected =
-- { [md5] = true } }, or nil, an error and "format" or "db". The segment is
-- recorded as seen in the same transaction.
function BookStore:importSegment(path, device_id, name, size, etag, now)
    local summary = { records = 0, applied = 0, affected = {} }
    local ok, res, err = pcall(self._tx, self, function(conn)
        local q = conn:prepare("SELECT updated, device, hash FROM book_merged WHERE md5 = ? AND prop = ?;")
        local put = conn:prepare([[
            INSERT OR REPLACE INTO book_merged (md5, prop, updated, device, deleted, hash, value)
            VALUES (?, ?, ?, ?, ?, ?, ?);]])
        local unsend = conn:prepare("DELETE FROM book_outbox WHERE md5 = ? AND prop = ? AND updated <= ?;")
        local book_info = {}
        local function onRecord(r)
            summary.records = summary.records + 1
            local rec = { updated = r.upd, device = r.dev, deleted = r.t == "x",
                          hash = r.t == "p" and self.md5(r.value_json) or "", value = r.value_json }
            local cur = q:reset():bind(r.md5, r.prop):step()
            local m = cur and { updated = num(cur[1]), device = cur[2], hash = cur[3] }
            if BookStore.wins(rec, m) then
                put:reset():bind(r.md5, r.prop, rec.updated, rec.device, rec.deleted and 1 or 0,
                    rec.hash, rec.value):step()
                unsend:reset():bind(r.md5, r.prop, rec.updated):step()
                summary.applied = summary.applied + 1
                if not summary.affected[r.md5] then
                    summary.affected[r.md5] = true
                    ensureBook(conn, r.md5, book_info[r.md5])
                end
            end
        end
        local header, rerr = BookFormat.readSegment(path, {
            book = function(b) book_info[b.md5] = b end,
            record = onRecord,
        })
        for _, s in ipairs({ q, put, unsend }) do s:close() end
        if not header then error({ format = rerr }, 0) end
        local fill = conn:prepare([[UPDATE book_books SET title = coalesce(title, ?), authors = coalesce(authors, ?)
                                    WHERE md5 = ?;]])
        for md5 in pairs(summary.affected) do
            local b = book_info[md5]
            if b then fill:reset():bind(b.title, b.authors, md5):step() end
        end
        fill:close()
        -- The other versions of these books are affected too.
        summary.affected = updateWriteGroups(conn, summary.affected)
        local stmt = conn:prepare(INSERT_SEEN)
        stmt:bind(device_id, name, size, etag, now, header.records):step()
        stmt:close()
        return summary
    end)
    if ok then return res end
    if type(res) == "table" and res.format then return nil, res.format, "format" end
    return nil, tostring(res or err), "db"
end

-- Status --------------------------------------------------------------------------------

function BookStore:counts()
    return self:_read(function(conn)
        return {
            books = num(conn:rowexec("SELECT count(DISTINCT md5) FROM book_merged WHERE deleted = 0 AND md5 <> '"
                .. BookFormat.COLLECTIONS .. "';")),
            outbox = num(conn:rowexec("SELECT count(*) FROM book_outbox;")),
            write = num(conn:rowexec([[SELECT count(DISTINCT b.md5) FROM book_books b
                                       JOIN book_files f ON f.md5 = b.md5 WHERE b.write = 1;]])),
        }
    end)
end

return BookStore
