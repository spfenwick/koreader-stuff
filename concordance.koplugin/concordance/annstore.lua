--[[--
The annotation side of the statistics sync state database (concordance/state.sqlite3): the
merged state of every book's annotations, what this device's copy of each
book held when last looked at, what's waiting to be sent, and deletions
waiting for the user's decision. Main process only; every call is one short
transaction.

The merged state is a last-writer-wins map per (md5, kind): for each key the
record with the highest (updated, device, hash) wins, a deletion being a
record like any other (hash ""). That makes merging idempotent and order
independent. Deletions are kept, so a late old record can't bring an
annotation back.

Tables:

    ann_merged  (md5, kind, key) -> updated, device, deleted, hash, fields
    ann_local   (md5, kind, key) -> hash, upd: this device's copy, as last seen
    ann_books   (md5, kind) -> title, authors, path, observed, pending, held_at
    ann_held    (md5, kind, key): deletions waiting for the user
    ann_outbox  (md5, kind, key) -> updated: changes to send

Segments imported are recorded in the statistics' seen_segments and
bad_segments tables (their names, ann-…, can't clash with seg-…).

Versions of a book: id_pos (kept by idstore.lua) says which MD5s are the
same book with matching positions (the same body). A book's merged state is
then, key by key, the winner across all of them. Keys are creation times,
so an annotation made on one version is the same annotation on the others.
Changes are still recorded under the book's own MD5, so nothing on the
server changes and devices without the groups carry on as before.
--]]

local AnnFormat = require("concordance/annformat")

local AnnStore = {}
AnnStore.__index = AnnStore

local BUSY_TIMEOUT_MS = 5000

-- (No semicolons in SQL comments: ljsqlite3's exec splits on them.)
local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS ann_merged (
        md5     TEXT NOT NULL,
        kind    TEXT NOT NULL,
        key     TEXT NOT NULL,
        updated INTEGER NOT NULL,
        device  TEXT NOT NULL,
        deleted INTEGER NOT NULL,
        hash    TEXT NOT NULL,
        fields  TEXT,
        PRIMARY KEY (md5, kind, key)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS ann_local (
        md5  TEXT NOT NULL,
        kind TEXT NOT NULL,
        key  TEXT NOT NULL,
        hash TEXT NOT NULL,
        upd  INTEGER,
        PRIMARY KEY (md5, kind, key)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS ann_books (
        md5      TEXT NOT NULL,
        kind     TEXT NOT NULL,
        title    TEXT,
        authors  TEXT,
        path     TEXT,
        observed INTEGER NOT NULL DEFAULT 0,
        pending  INTEGER NOT NULL DEFAULT 0,
        held_at  INTEGER,
        PRIMARY KEY (md5, kind)
    );
    CREATE TABLE IF NOT EXISTS ann_held (
        md5  TEXT NOT NULL,
        kind TEXT NOT NULL,
        key  TEXT NOT NULL,
        PRIMARY KEY (md5, kind, key)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS ann_outbox (
        md5     TEXT NOT NULL,
        kind    TEXT NOT NULL,
        key     TEXT NOT NULL,
        updated INTEGER NOT NULL,
        PRIMARY KEY (md5, kind, key)
    ) WITHOUT ROWID;
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

--- Mass deletion: more than this many of a book's items gone at once waits
-- for the user.
AnnStore.MASS_MIN = 5

local function num(v) return v ~= nil and tonumber(v) or nil end

--- opts: sq3, state_path, md5 (function: string -> hex digest; default ffi/sha2)
function AnnStore.new(opts)
    local self = setmetatable({}, AnnStore)
    self.SQ3 = assert(opts.sq3, "sq3 module")
    self.state_path = assert(opts.state_path)
    self.md5 = opts.md5 or require("ffi/sha2").md5
    return self
end

function AnnStore:open()
    local conn = self.SQ3.open(self.state_path)
    conn:set_busy_timeout(BUSY_TIMEOUT_MS)
    conn:exec(SCHEMA)
    return conn
end

local function packn(...) return { n = select("#", ...), ... } end

--- Runs fn(conn) in a write transaction; rolls back if it raises.
function AnnStore:_tx(fn)
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

function AnnStore:_read(fn)
    local conn = self:open()
    local res = packn(pcall(fn, conn))
    conn:close()
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

-- Records ------------------------------------------------------------------------

--- Does record a win over record b (either may be nil)?
function AnnStore.wins(a, b)
    if not a then return false end
    if not b then return true end
    if a.updated ~= b.updated then return a.updated > b.updated end
    if a.device ~= b.device then return a.device > b.device end
    return a.hash > b.hash
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

local function loadMerged(conn, md5, kind)
    local stmt = conn:prepare("SELECT key, updated, device, deleted, hash, fields FROM ann_merged WHERE md5 = ? AND kind = ?;")
    stmt:bind(md5, kind)
    local map, n = {}, 0
    for _, r in ipairs(rows(stmt)) do
        map[r[1]] = { updated = num(r[2]), device = r[3], deleted = num(r[4]) == 1, hash = r[5], fields = r[6] }
        n = n + 1
    end
    return map, n
end

--- The other versions of the book whose positions match this one's.
local function peersOf(conn, md5)
    local stmt = conn:prepare([[
        SELECT g.md5 FROM id_pos me JOIN id_pos g ON g.grp = me.grp AND g.md5 <> me.md5
        WHERE me.md5 = ? ORDER BY g.md5;]])
    stmt:bind(md5)
    local out = {}
    for _, r in ipairs(rows(stmt)) do out[#out + 1] = r[1] end
    return out
end

--- The merged state as it applies to this book: key by key, the winner
-- across it and its versions with matching positions. Also returns its
-- own records.
local function loadEffective(conn, md5, kind)
    local own = loadMerged(conn, md5, kind)
    local peers = peersOf(conn, md5)
    if #peers == 0 then return own, own end
    local eff = {}
    for key, m in pairs(own) do eff[key] = m end
    for _, peer in ipairs(peers) do
        for key, m in pairs(loadMerged(conn, peer, kind)) do
            if AnnStore.wins(m, eff[key]) then eff[key] = m end
        end
    end
    return eff, own
end

local function loadLocal(conn, md5, kind)
    local stmt = conn:prepare("SELECT key, hash, upd FROM ann_local WHERE md5 = ? AND kind = ?;")
    stmt:bind(md5, kind)
    local map, n = {}, 0
    for _, r in ipairs(rows(stmt)) do
        map[r[1]] = { hash = r[2], upd = num(r[3]) }
        n = n + 1
    end
    return map, n
end

local function loadHeld(conn, md5, kind)
    local stmt = conn:prepare("SELECT key FROM ann_held WHERE md5 = ? AND kind = ?;")
    stmt:bind(md5, kind)
    local set, n = {}, 0
    for _, r in ipairs(rows(stmt)) do set[r[1]] = true; n = n + 1 end
    return set, n
end

local function loadBook(conn, md5, kind)
    local stmt = conn:prepare("SELECT title, authors, path, observed, pending, held_at FROM ann_books WHERE md5 = ? AND kind = ?;")
    local r = stmt:bind(md5, kind):step()
    stmt:close()
    if not r then return nil end
    return { title = r[1], authors = r[2], path = r[3], observed = num(r[4]) == 1, pending = num(r[5]) == 1,
             held_at = num(r[6]) }
end

local function ensureBook(conn, md5, kind, info)
    local stmt = conn:prepare("INSERT OR IGNORE INTO ann_books (md5, kind, title, authors) VALUES (?, ?, ?, ?);")
    stmt:bind(md5, kind, info and info.title, info and info.authors):step()
    stmt:close()
end

local function setBook(conn, md5, kind, col, value)
    local stmt = conn:prepare("UPDATE ann_books SET " .. col .. " = ? WHERE md5 = ? AND kind = ?;")
    stmt:bind(value, md5, kind):step()
    stmt:close()
end

local function putMerged(conn, md5, kind, key, rec)
    local stmt = conn:prepare([[
        INSERT OR REPLACE INTO ann_merged (md5, kind, key, updated, device, deleted, hash, fields)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);]])
    stmt:bind(md5, kind, key, rec.updated, rec.device, rec.deleted and 1 or 0, rec.hash, rec.fields):step()
    stmt:close()
end

local function putOutbox(conn, md5, kind, key, updated)
    local stmt = conn:prepare("INSERT OR REPLACE INTO ann_outbox (md5, kind, key, updated) VALUES (?, ?, ?, ?);")
    stmt:bind(md5, kind, key, updated):step()
    stmt:close()
end

--- Snapshot of a list: key -> { hash, upd, fields, item }, plus the count.
-- Items that can't be encoded are left out (and reported in `skipped`).
function AnnStore:snapshot(items, kind)
    local keys = AnnFormat.keys(items, kind)
    local snap, n, skipped = {}, 0, 0
    for i, item in ipairs(items) do
        -- Only items whose position fits the list's kind: anything else
        -- would make a segment every other device rejects.
        local json = AnnFormat.validItem(item, kind) and AnnFormat.fieldsJson(item)
        if json then
            snap[keys[i]] = { hash = self.md5(json), fields = json, upd = AnnFormat.itemTime(item), index = i }
            n = n + 1
        else
            skipped = skipped + 1
        end
    end
    return snap, n, skipped
end

-- Does the merged state differ from the snapshot (held keys aside)?
local function differs(merged, snap, held)
    for key, m in pairs(merged) do
        if not held[key] then
            local s = snap[key]
            if m.deleted then
                if s then return true end
            elseif not s or s.hash ~= m.hash then
                return true
            end
        end
    end
    return false
end

local function writeLocal(conn, md5, kind, snap)
    local del = conn:prepare("DELETE FROM ann_local WHERE md5 = ? AND kind = ?;")
    del:bind(md5, kind):step()
    del:close()
    local ins = conn:prepare("INSERT INTO ann_local (md5, kind, key, hash, upd) VALUES (?, ?, ?, ?, ?);")
    for key, s in pairs(snap) do
        ins:reset():bind(md5, kind, key, s.hash, s.upd):step()
    end
    ins:close()
end

-- Local changes -------------------------------------------------------------------

--- Compares a book's current list with what this device saw last time, and
-- records the changes as this device's. opts: md5, kind, items, now, device,
-- title, authors, path.
--
-- The first time a book is seen here, nothing counts as deleted: items the
-- merged state lacks, or holds an older version of, are this device's;
-- anything else is left for applying. Afterwards, an item gone since last
-- time is a deletion, unless many went at once (see MASS_MIN), which is held
-- for the user (see resolveHeld).
--
-- Returns { added, changed, deleted, held (number newly held), pending
-- (merged state differs from the list), skipped }.
function AnnStore:observe(opts)
    local md5, kind, now, device = opts.md5, opts.kind, opts.now, opts.device
    local snap, ncur, skipped = self:snapshot(opts.items, kind)
    return self:_tx(function(conn)
        ensureBook(conn, md5, kind, opts)
        local book = loadBook(conn, md5, kind)
        -- Recorded under this book's own MD5 (own); compared with what
        -- applies to it (its versions' records too) to tell what changed.
        local merged, own = loadEffective(conn, md5, kind)
        local prev = loadLocal(conn, md5, kind)
        local held = loadHeld(conn, md5, kind)
        local res = { added = 0, changed = 0, deleted = 0, held = 0, skipped = skipped }

        local function record(key, rec)
            if AnnStore.wins(rec, own[key]) then
                putMerged(conn, md5, kind, key, rec)
                putOutbox(conn, md5, kind, key, rec.updated)
                own[key] = rec
                if AnnStore.wins(rec, merged[key]) then merged[key] = rec end
                return true
            end
        end

        for key, s in pairs(snap) do
            local p = prev[key]
            if not (book.observed and p and p.hash == s.hash) then
                local upd = s.upd or now
                -- Changed without its own timestamp moving on (an outside
                -- edit): it happened since we last looked, so now.
                if book.observed and p and (s.upd == nil or (p.upd and s.upd <= p.upd)) then upd = now end
                local m = merged[key]
                if not (m and m.hash == s.hash) then
                    -- Made from the merged record (this device had it): it's
                    -- later than it, whatever the clocks say. Otherwise a
                    -- record stamped by a clock running ahead would win, and
                    -- the edit be undone here.
                    if book.observed and p and m and p.hash == m.hash and upd <= m.updated then
                        upd = m.updated + 1
                    end
                    if record(key, { updated = upd, device = device, deleted = false, hash = s.hash, fields = s.fields }) then
                        if m and not m.deleted then res.changed = res.changed + 1 else res.added = res.added + 1 end
                    end
                end
            end
            if held[key] then
                -- Back again (undone, or restored by hand): no longer held.
                local stmt = conn:prepare("DELETE FROM ann_held WHERE md5 = ? AND kind = ? AND key = ?;")
                stmt:bind(md5, kind, key):step()
                stmt:close()
                held[key] = nil
            end
        end

        if book.observed then
            local gone = {}
            for key in pairs(prev) do
                if not snap[key] and not held[key] then gone[#gone + 1] = key end
            end
            local mass = #gone > AnnStore.MASS_MIN
            if mass then
                local stmt = conn:prepare("INSERT OR IGNORE INTO ann_held (md5, kind, key) VALUES (?, ?, ?);")
                for _, key in ipairs(gone) do
                    stmt:reset():bind(md5, kind, key):step()
                    held[key] = true
                end
                stmt:close()
                setBook(conn, md5, kind, "held_at", now)
                res.held = #gone
            else
                for _, key in ipairs(gone) do
                    -- As for an edit: removing what the merged record
                    -- holds is later than it.
                    local m, upd = merged[key], now
                    if m and prev[key].hash == m.hash and upd <= m.updated then upd = m.updated + 1 end
                    if record(key, { updated = upd, device = device, deleted = true, hash = "" }) then
                        res.deleted = res.deleted + 1
                    end
                end
            end
        end

        writeLocal(conn, md5, kind, snap)
        local up = conn:prepare([[UPDATE ann_books SET observed = 1, pending = ?,
            title = coalesce(?, title), authors = coalesce(?, authors), path = coalesce(?, path)
            WHERE md5 = ? AND kind = ?;]])
        res.pending = differs(merged, snap, held)
        up:bind(res.pending and 1 or 0, opts.title, opts.authors, opts.path, md5, kind):step()
        up:close()
        if not next(held) then setBook(conn, md5, kind, "held_at", nil) end
        return res
    end)
end

-- Applying the merged state ----------------------------------------------------------

--- What to change in a book's list to match the merged state (held
-- deletions aside). `items` is the current list. Returns a list of
-- { op = "add"|"replace"|"remove", key, index (replace/remove), item (add/replace) }.
function AnnStore:plan(md5, kind, items)
    local snap = self:snapshot(items, kind)
    return self:_read(function(conn)
        local merged = loadEffective(conn, md5, kind)
        local held = loadHeld(conn, md5, kind)
        local ops = {}
        for key, m in pairs(merged) do
            if not held[key] then
                local s = snap[key]
                if m.deleted then
                    if s then ops[#ops + 1] = { op = "remove", key = key, index = s.index } end
                elseif not s then
                    local item = AnnFormat.itemFromJson(m.fields)
                    if item then ops[#ops + 1] = { op = "add", key = key, item = item } end
                elseif s.hash ~= m.hash then
                    local item = AnnFormat.itemFromJson(m.fields)
                    if item then ops[#ops + 1] = { op = "replace", key = key, index = s.index, item = item } end
                end
            end
        end
        table.sort(ops, function(a, b) return a.key < b.key end)
        return ops
    end)
end

--- Records the list as this device's copy after applying (so the applied
-- changes aren't taken for local ones), and whether anything's left to apply.
function AnnStore:applied(md5, kind, items)
    local snap = self:snapshot(items, kind)
    return self:_tx(function(conn)
        ensureBook(conn, md5, kind)
        writeLocal(conn, md5, kind, snap)
        local pending = differs((loadEffective(conn, md5, kind)), snap, loadHeld(conn, md5, kind))
        local stmt = conn:prepare("UPDATE ann_books SET observed = 1, pending = ? WHERE md5 = ? AND kind = ?;")
        stmt:bind(pending and 1 or 0, md5, kind):step()
        stmt:close()
        return pending
    end)
end

--- Books with merged changes not in their list yet, where this device has
-- seen them: { { md5, kind, path }, … }.
function AnnStore:toWrite()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare([[
            SELECT md5, kind, path FROM ann_books
            WHERE pending = 1 AND path IS NOT NULL ORDER BY path, kind;]]))) do
            out[#out + 1] = { md5 = r[1], kind = r[2], path = r[3] }
        end
        return out
    end)
end

--- The kinds of list seen at this path for this book (to tell an empty
-- list's kind).
function AnnStore:kindsAt(md5, path)
    return self:_read(function(conn)
        local stmt = conn:prepare("SELECT kind FROM ann_books WHERE md5 = ? AND path = ? AND observed = 1;")
        stmt:bind(md5, path)
        local out = {}
        for _, r in ipairs(rows(stmt)) do out[#out + 1] = r[1] end
        return out
    end)
end

function AnnStore:isPending(md5, kind)
    return self:_read(function(conn)
        local b = loadBook(conn, md5, kind)
        return b ~= nil and b.pending
    end)
end

--- After the groups changed (IdStore:refreshGroups): looks again at what's
-- to be applied to these books, seen on this device. md5s = { [md5] = true }.
-- Returns those now with changes to apply: { ["md5\0kind"] = { md5, kind } }.
function AnnStore:regroup(md5s)
    return self:_tx(function(conn)
        local out = {}
        local stmt = conn:prepare("SELECT kind FROM ann_books WHERE md5 = ? AND observed = 1;")
        for md5 in pairs(md5s) do
            stmt:reset():bind(md5)
            local kinds = {}
            local r = stmt:step()
            while r do kinds[#kinds + 1] = r[1]; r = stmt:step() end
            for _, kind in ipairs(kinds) do
                local pending = differs((loadEffective(conn, md5, kind)), loadLocal(conn, md5, kind),
                    loadHeld(conn, md5, kind))
                setBook(conn, md5, kind, "pending", pending and 1 or 0)
                if pending then out[md5 .. "\0" .. kind] = { md5 = md5, kind = kind } end
            end
        end
        stmt:close()
        return out
    end)
end

-- Held deletions -----------------------------------------------------------------------

--- Books with held deletions: { { md5, kind, title, authors, count, total, held_at }, … }
function AnnStore:held()
    return self:_read(function(conn)
        local out = {}
        for _, r in ipairs(rows(conn:prepare([[
            SELECT h.md5, h.kind, b.title, b.authors, count(*), b.held_at,
                   (SELECT count(*) FROM ann_local l WHERE l.md5 = h.md5 AND l.kind = h.kind)
            FROM ann_held h LEFT JOIN ann_books b ON b.md5 = h.md5 AND b.kind = h.kind
            GROUP BY h.md5, h.kind ORDER BY b.held_at, h.md5, h.kind;]]))) do
            local count = num(r[5])
            out[#out + 1] = { md5 = r[1], kind = r[2], title = r[3], authors = r[4], count = count,
                              held_at = num(r[6]), total = count + num(r[7]) }
        end
        return out
    end)
end

--- The user's answer for a book's held deletions: "remove" (delete them
-- everywhere) or "restore" (put them back here, from the merged state).
function AnnStore:resolveHeld(md5, kind, answer, now, device)
    return self:_tx(function(conn)
        local held = loadHeld(conn, md5, kind)
        local merged = loadMerged(conn, md5, kind)
        local n = 0
        if answer == "remove" then
            for key in pairs(held) do
                local rec = { updated = now, device = device, deleted = true, hash = "" }
                if AnnStore.wins(rec, merged[key]) then
                    putMerged(conn, md5, kind, key, rec)
                    putOutbox(conn, md5, kind, key, now)
                    n = n + 1
                end
            end
        end
        local del = conn:prepare("DELETE FROM ann_held WHERE md5 = ? AND kind = ?;")
        del:bind(md5, kind):step()
        del:close()
        setBook(conn, md5, kind, "held_at", nil)
        if answer == "restore" then setBook(conn, md5, kind, "pending", 1) end
        return n
    end)
end

-- Export --------------------------------------------------------------------------------

--- Writes a segment of the changes waiting to be sent. opts: device_id,
-- out_path, now, max_records. Returns nil when there's nothing to send, else
-- { records, books, more, size }. After a confirmed upload, call
-- markExported with the same file.
function AnnStore:export(opts)
    return self:_read(function(conn)
        local stmt = conn:prepare([[
            SELECT o.md5, o.kind, o.key, m.updated, m.device, m.deleted, m.fields
            FROM ann_outbox o JOIN ann_merged m ON m.md5 = o.md5 AND m.kind = o.kind AND m.key = o.key
            ORDER BY o.md5, o.kind, o.key LIMIT ?;]])
        stmt:bind(opts.max_records)
        local recs = rows(stmt)
        if #recs == 0 then return nil end
        local md5s, books = {}, {}
        local bstmt = conn:prepare("SELECT title, authors FROM ann_books WHERE md5 = ? AND (title IS NOT NULL OR authors IS NOT NULL) LIMIT 1;")
        local lines = {}
        for _, r in ipairs(recs) do
            local md5 = r[1]
            if not md5s[md5] then
                md5s[md5] = true
                local b = bstmt:reset():bind(md5):step()
                books[#books + 1] = AnnFormat.bookLine{ md5 = md5, title = b and b[1], authors = b and b[2] }
                lines[#lines + 1] = books[#books]
            end
            lines[#lines + 1] = AnnFormat.recordLine{
                md5 = md5, kind = r[2], key = r[3], updated = num(r[4]), device = r[5],
                fields_json = num(r[6]) ~= 1 and r[7] or nil,
            }
        end
        bstmt:close()
        local tmp = opts.out_path .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(AnnFormat.headerLine(opts.device_id, opts.now), "\n")
        f:write(table.concat(lines, "\n"), "\n")
        f:write(AnnFormat.trailerLine(#books, #recs), "\n")
        f:close()
        assert(os.rename(tmp, opts.out_path))
        local size = io.open(opts.out_path, "rb"):seek("end")
        return { records = #recs, books = #books, more = #recs >= opts.max_records, size = size }
    end)
end

local INSERT_SEEN = [[
    INSERT OR REPLACE INTO seen_segments (device_id, name, size, etag, imported_at, events)
    VALUES (?, ?, ?, ?, ?, ?);
]]

--- After a confirmed upload: what the segment holds is sent (unless it
-- changed again since), and the segment is seen.
function AnnStore:markExported(path, device_id, name, size, etag, now)
    return self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM ann_outbox WHERE md5 = ? AND kind = ? AND key = ? AND updated <= ?;")
        local header, err = AnnFormat.readSegment(path, { record = function(r)
            del:reset():bind(r.md5, r.kind, r.key, r.upd):step()
        end })
        del:close()
        if not header then error(err, 0) end
        local stmt = conn:prepare(INSERT_SEEN)
        stmt:bind(device_id, name, size, etag, now, header.records):step()
        stmt:close()
        return header.records
    end)
end

--- Everything in the merged state is to be sent again (a new server or
-- folder, or annotation sync turned on again).
function AnnStore:requeueAll()
    return self:_tx(function(conn)
        conn:exec("INSERT OR REPLACE INTO ann_outbox (md5, kind, key, updated) SELECT md5, kind, key, updated FROM ann_merged;")
    end)
end

-- Import --------------------------------------------------------------------------------

--- Merges a downloaded segment. Returns { records, applied, affected =
-- { ["md5\0kind"] = { md5, kind } } }, or nil, an error and "format" or "db".
-- The segment is recorded as seen in the same transaction.
function AnnStore:importSegment(path, device_id, name, size, etag, now)
    local summary = { records = 0, applied = 0, affected = {} }
    local ok, res, err = pcall(self._tx, self, function(conn)
        local q = conn:prepare("SELECT updated, device, hash FROM ann_merged WHERE md5 = ? AND kind = ? AND key = ?;")
        local put = conn:prepare([[
            INSERT OR REPLACE INTO ann_merged (md5, kind, key, updated, device, deleted, hash, fields)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);]])
        local unsend = conn:prepare("DELETE FROM ann_outbox WHERE md5 = ? AND kind = ? AND key = ? AND updated <= ?;")
        local book_info = {}
        local function onRecord(r)
            summary.records = summary.records + 1
            local rec = { updated = r.upd, device = r.dev, deleted = r.t == "x",
                          hash = r.t == "a" and self.md5(r.fields_json) or "", fields = r.fields_json }
            local cur = q:reset():bind(r.md5, r.kind, r.key):step()
            local m = cur and { updated = num(cur[1]), device = cur[2], hash = cur[3] }
            if AnnStore.wins(rec, m) then
                put:reset():bind(r.md5, r.kind, r.key, rec.updated, rec.device, rec.deleted and 1 or 0,
                    rec.hash, rec.fields):step()
                unsend:reset():bind(r.md5, r.kind, r.key, rec.updated):step()
                summary.applied = summary.applied + 1
                local id = r.md5 .. "\0" .. r.kind
                if not summary.affected[id] then
                    summary.affected[id] = { md5 = r.md5, kind = r.kind }
                    ensureBook(conn, r.md5, r.kind, book_info[r.md5])
                end
            end
        end
        local header, rerr = AnnFormat.readSegment(path, {
            book = function(b) book_info[b.md5] = b end,
            record = onRecord,
        })
        for _, s in ipairs({ q, put, unsend }) do s:close() end
        if not header then error({ format = rerr }, 0) end
        local pend = conn:prepare("UPDATE ann_books SET pending = 1 WHERE md5 = ? AND kind = ?;")
        local fill = conn:prepare([[UPDATE ann_books SET title = coalesce(title, ?), authors = coalesce(authors, ?)
                                    WHERE md5 = ? AND kind = ?;]])
        for _, a in pairs(summary.affected) do
            pend:reset():bind(a.md5, a.kind):step()
            local b = book_info[a.md5]
            if b then fill:reset():bind(b.title, b.authors, a.md5, a.kind):step() end
        end
        -- The versions of these books with matching positions, seen here,
        -- are affected too.
        local seen = conn:prepare("UPDATE ann_books SET pending = 1 WHERE md5 = ? AND kind = ? AND observed = 1;")
        local extra = {}
        for _, a in pairs(summary.affected) do
            for _, peer in ipairs(peersOf(conn, a.md5)) do
                local id = peer .. "\0" .. a.kind
                if not summary.affected[id] then
                    seen:reset():bind(peer, a.kind):step()
                    if num(conn:rowexec("SELECT changes();")) ~= 0 then extra[id] = { md5 = peer, kind = a.kind } end
                end
            end
        end
        seen:close()
        for id, a in pairs(extra) do summary.affected[id] = a end
        pend:close()
        fill:close()
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

function AnnStore:counts()
    return self:_read(function(conn)
        return {
            annotations = num(conn:rowexec("SELECT count(*) FROM ann_merged WHERE deleted = 0;")),
            deleted = num(conn:rowexec("SELECT count(*) FROM ann_merged WHERE deleted = 1;")),
            books = num(conn:rowexec("SELECT count(DISTINCT md5) FROM ann_merged WHERE deleted = 0;")),
            outbox = num(conn:rowexec("SELECT count(*) FROM ann_outbox;")),
            pending = num(conn:rowexec("SELECT count(*) FROM ann_books WHERE pending = 1;")),
            held = num(conn:rowexec("SELECT count(DISTINCT md5 || kind) FROM ann_held;")),
        }
    end)
end

return AnnStore
