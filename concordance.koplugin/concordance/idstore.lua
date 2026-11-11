--[[--
The book identity side of the sync state database (concordance/state.sqlite3):
facts about book files from every device (see idformat.lua), what's
waiting to be sent, and which files this device has read. Main process
only; every call is one short transaction.

Facts don't change, so the merged state is a set: importing adds the
facts not already there. Nothing is ever removed. A link (a match made
outside the file) can be withdrawn by an unlink, itself a fact: see
"Links" below.

Tables:

    id_facts   (md5, fact) -> src, uuids ("\n"-joined), sig, title,
               authors, ids ("\n"-joined), device (first to send it), n
               (a link's or unlink's number)
    id_uuids   (uuid, md5): the UUIDs of each MD5 (withdrawn links' left
               out)
    id_outbox  (md5, fact): facts to send
    id_scanned path -> md5 (the sidecar's), size, mtime: files read, and
               what they were then (read again when any of it changes)
    id_groups  md5 -> grp: the groups that are joined (two or more MD5s,
               guards passed), grp being the group's smallest MD5. Rebuilt
               by refreshGroups() after each sync. Book data reads it (see
               bookstore.lua).
    id_pos     md5 -> grp: within those groups, the MD5s whose positions
               match (level 2: the same body signature), two or more per
               grp, grp being the smallest. Rebuilt with id_groups.
               Annotations, the handmade TOC and flows read it.
--]]

local IdFormat = require("concordance/idformat")

local IdStore = {}
IdStore.__index = IdStore

local BUSY_TIMEOUT_MS = 5000

--- Groups with more bodies than this aren't joined (see IDENTITY.md):
-- files sharing a body signature count once, a file without one as one.
IdStore.MAX_GROUP = 32
--- A UUID carried by more files than this joins nothing: some tool's
-- constant, not a book's ID.
IdStore.MAX_CARRIERS = 200

-- (No semicolons in SQL comments: ljsqlite3's exec splits on them.)
local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS id_facts (
        md5     TEXT NOT NULL,
        fact    TEXT NOT NULL,
        src     TEXT NOT NULL,
        uuids   TEXT NOT NULL,
        sig     TEXT,
        title   TEXT,
        authors TEXT,
        ids     TEXT,
        device  TEXT NOT NULL,
        n       INTEGER,
        PRIMARY KEY (md5, fact)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS id_uuids (
        uuid TEXT NOT NULL,
        md5  TEXT NOT NULL,
        PRIMARY KEY (uuid, md5)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS id_uuids_md5 ON id_uuids (md5);
    CREATE TABLE IF NOT EXISTS id_outbox (
        md5  TEXT NOT NULL,
        fact TEXT NOT NULL,
        PRIMARY KEY (md5, fact)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS id_scanned (
        path  TEXT PRIMARY KEY,
        md5   TEXT NOT NULL,
        size  INTEGER,
        mtime INTEGER
    );
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

local function split(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for line in s:gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end

--- opts: sq3, state_path
function IdStore.new(opts)
    local self = setmetatable({}, IdStore)
    self.SQ3 = assert(opts.sq3, "sq3 module")
    self.state_path = assert(opts.state_path)
    return self
end

-- Databases whose id_facts is known to have the n column (added with
-- unlinks), by path: looked at once per process.
local has_n = {}

function IdStore:open()
    local conn = self.SQ3.open(self.state_path)
    conn:set_busy_timeout(BUSY_TIMEOUT_MS)
    conn:exec(SCHEMA)
    if not has_n[self.state_path] then
        local found = false
        local stmt = conn:prepare("PRAGMA table_info(id_facts);")
        local r = stmt:step()
        while r do
            if r[2] == "n" then found = true end
            r = stmt:step()
        end
        stmt:close()
        if not found then conn:exec("ALTER TABLE id_facts ADD COLUMN n INTEGER;") end
        has_n[self.state_path] = true
    end
    return conn
end

local function packn(...) return { n = select("#", ...), ... } end

function IdStore:_tx(fn)
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

function IdStore:_read(fn)
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

-- Links ----------------------------------------------------------------------------------
--
-- A link for (md5, uuids) counts while its number is above every unlink's
-- for the same md5 and uuids. link() numbers a new one just above the
-- unlinks; retract() numbers an unlink as the links it withdraws.

--- From rows of { src, uuids, n, … } for one MD5 (links and unlinks; others
-- ignored): { [uuids] = { link = highest link number or nil, unlink =
-- highest unlink number or -1 } }.
local function linkNumbers(list, src_at, uuids_at, n_at)
    local out = {}
    for _, r in ipairs(list) do
        local src = r[src_at]
        if src == "link" or src == "unlink" then
            local e = out[r[uuids_at]] or { unlink = -1 }
            out[r[uuids_at]] = e
            local n = num(r[n_at]) or 0
            if src == "link" then
                if not e.link or n > e.link then e.link = n end
            elseif n > e.unlink then
                e.unlink = n
            end
        end
    end
    return out
end

local function linkCounts(e)
    return e ~= nil and e.link ~= nil and e.link > e.unlink
end

--- id_uuids for one MD5, from its facts: every UUID a file, sidecar or
-- counting link names.
local function syncUuids(conn, md5)
    local stmt = conn:prepare("SELECT src, uuids, n FROM id_facts WHERE md5 = ?;")
    stmt:bind(md5)
    local facts = rows(stmt)
    local numbers = linkNumbers(facts, 1, 2, 3)
    local want = {}
    for _, r in ipairs(facts) do
        if (r[1] ~= "link" and r[1] ~= "unlink") or (r[1] == "link" and linkCounts(numbers[r[2]])) then
            for _, uuid in ipairs(split(r[2])) do want[uuid] = true end
        end
    end
    local del = conn:prepare("DELETE FROM id_uuids WHERE md5 = ?;")
    del:bind(md5):step()
    del:close()
    local u = conn:prepare("INSERT OR IGNORE INTO id_uuids (uuid, md5) VALUES (?, ?);")
    for uuid in pairs(want) do u:reset():bind(uuid, md5):step() end
    u:close()
end

--- Adds a fact unless it's known. Returns true if it was new.
local function addFact(conn, r, device)
    local key = IdFormat.factKey(r)
    local q = conn:prepare("SELECT 1 FROM id_facts WHERE md5 = ? AND fact = ?;")
    local known = q:bind(r.md5, key):step()
    q:close()
    if known then return false, key end
    local uuids = IdFormat.sortedUnique(r.uuids)
    local put = conn:prepare([[
        INSERT INTO id_facts (md5, fact, src, uuids, sig, title, authors, ids, device, n)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
    put:bind(r.md5, key, r.src, table.concat(uuids, "\n"), r.sig, r.title, r.authors,
        r.ids and #r.ids > 0 and table.concat(r.ids, "\n") or nil, device,
        (r.src == "link" or r.src == "unlink") and (r.n or 0) or nil):step()
    put:close()
    if r.src == "link" or r.src == "unlink" then
        syncUuids(conn, r.md5)
    else
        local u = conn:prepare("INSERT OR IGNORE INTO id_uuids (uuid, md5) VALUES (?, ?);")
        for _, uuid in ipairs(uuids) do u:reset():bind(uuid, r.md5):step() end
        u:close()
    end
    return true, key
end

-- Scanning ------------------------------------------------------------------------------

--- Which of these files to read: files = { { path, md5 (the sidecar's,
-- nil for a file never opened), size, mtime }, … }; those not read
-- before, or changed since.
function IdStore:toScan(files)
    return self:_read(function(conn)
        local q = conn:prepare("SELECT md5, size, mtime FROM id_scanned WHERE path = ?;")
        local out = {}
        for _, f in ipairs(files) do
            local r = q:reset():bind(f.path):step()
            if not r or r[1] ~= (f.md5 or "") or num(r[2]) ~= f.size or num(r[3]) ~= f.mtime then
                out[#out + 1] = f
            end
        end
        q:close()
        return out
    end)
end

--- Records what reading a file found. item = { path, md5 (the sidecar's),
-- size, mtime }; info from IdScan.scan, or nil when the file couldn't be
-- read or isn't an EPUB (it's not read again until it changes). Files
-- without UUIDs give no facts. Returns the number of new facts.
function IdStore:recordScan(item, info, device)
    return self:_tx(function(conn)
        local added = 0
        local function add(r)
            local ok, err = IdFormat.validRecord(r)
            if not ok then error("invalid identity record for " .. tostring(item.path) .. ": " .. err, 0) end
            local new, key = addFact(conn, r, device)
            if new then
                local o = conn:prepare("INSERT OR IGNORE INTO id_outbox (md5, fact) VALUES (?, ?);")
                o:bind(r.md5, key):step()
                o:close()
                added = added + 1
            end
        end
        if info and info.uuids and #info.uuids > 0 then
            local base = { uuids = info.uuids, title = info.title, authors = info.authors, ids = info.ids }
            add{ md5 = info.md5, src = "file", sig = info.sig, uuids = base.uuids, title = base.title,
                 authors = base.authors, ids = base.ids }
            -- KOReader keeps a book's MD5 when its file is replaced: the
            -- sidecar's MD5 then names the old file, whose positions this
            -- file can't vouch for.
            if item.md5 and item.md5 ~= "" and item.md5 ~= info.md5 then
                add{ md5 = item.md5, src = "sidecar", uuids = base.uuids, title = base.title,
                     authors = base.authors, ids = base.ids }
            end
        end
        local s = conn:prepare("INSERT OR REPLACE INTO id_scanned (path, md5, size, mtime) VALUES (?, ?, ?, ?);")
        s:bind(item.path, item.md5 or "", item.size, item.mtime):step()
        s:close()
        return added
    end)
end

--- Records matches made outside the file (src "link"): another plugin
-- (Cloud library) found which catalog book a file is, by its title.
-- list = { { md5, uuids, title, authors }, … }. Only links that don't
-- count already are written and sent: new ones, and ones withdrawn since
-- (numbered above the unlink, up to IdFormat.MAX_N). Returns the number of
-- new facts.
function IdStore:link(list, device)
    return self:_tx(function(conn)
        local q = conn:prepare("SELECT src, uuids, n FROM id_facts WHERE md5 = ? AND src IN ('link', 'unlink');")
        local o = conn:prepare("INSERT OR IGNORE INTO id_outbox (md5, fact) VALUES (?, ?);")
        local added = 0
        for _, l in ipairs(list) do
            local uuids = {}
            for _, u in ipairs(l.uuids or {}) do uuids[#uuids + 1] = IdFormat.normalizeUuid(u) end
            local r = { md5 = l.md5, src = "link", uuids = IdFormat.sortedUnique(uuids), title = l.title,
                        authors = l.authors }
            if IdFormat.validRecord(r) then
                local found = {}
                local row = q:reset():bind(r.md5):step()
                while row do
                    found[#found + 1] = { row[1], row[2], row[3] }
                    row = q:step()
                end
                local e = linkNumbers(found, 1, 2, 3)[table.concat(r.uuids, "\n")]
                if not linkCounts(e) then
                    r.n = e and e.unlink + 1 or 0
                    if r.n <= IdFormat.MAX_N then
                        local isnew, key = addFact(conn, r, device)
                        if isnew then
                            o:reset():bind(r.md5, key):step()
                            added = added + 1
                        end
                    end
                end
            end
        end
        q:close()
        o:close()
        return added
    end)
end

--- Withdraws links this device made that no longer hold. opts: device,
-- present = { [md5] = true } (the files the other plugin can speak for
-- just now), current = { [md5] = { [uuids ("\n"-joined, sorted)] = true } }
-- (the matches it makes now), known(uuid) -> true when the book a link
-- names is one it still knows (a book missing from its list is no reason
-- to withdraw: the list may be behind). A counting link of this device's
-- for a present MD5, to a known book, that isn't current gets an unlink.
-- Returns the number of unlinks made.
function IdStore:retract(opts)
    return self:_tx(function(conn)
        local all = rows(conn:prepare("SELECT md5, src, uuids, n, device FROM id_facts WHERE src IN ('link', 'unlink');"))
        local by_md5 = {}
        for _, r in ipairs(all) do
            by_md5[r[1]] = by_md5[r[1]] or {}
            table.insert(by_md5[r[1]], r)
        end
        local o = conn:prepare("INSERT OR IGNORE INTO id_outbox (md5, fact) VALUES (?, ?);")
        local made = 0
        for md5, facts in pairs(by_md5) do
            if opts.present[md5] then
                local numbers = linkNumbers(facts, 2, 3, 4)
                local mine = {}
                for _, r in ipairs(facts) do
                    if r[2] == "link" and r[5] == opts.device and (num(r[4]) or 0) == (numbers[r[3]].link or -1) then
                        mine[r[3]] = true
                    end
                end
                for uuids in pairs(mine) do
                    local e = numbers[uuids]
                    local known = true
                    for _, u in ipairs(split(uuids)) do if not opts.known(u) then known = false end end
                    if linkCounts(e) and known and not (opts.current[md5] and opts.current[md5][uuids]) then
                        local isnew, key = addFact(conn, { md5 = md5, src = "unlink", uuids = split(uuids), n = e.link },
                            opts.device)
                        if isnew then
                            o:reset():bind(md5, key):step()
                            made = made + 1
                        end
                    end
                end
            end
        end
        o:close()
        return made
    end)
end

--- Forgets files that are gone (paths not in the set).
function IdStore:keepScanned(present)
    return self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM id_scanned WHERE path = ?;")
        local n = 0
        for _, r in ipairs(rows(conn:prepare("SELECT path FROM id_scanned;"))) do
            if not present[r[1]] then
                del:reset():bind(r[1]):step()
                n = n + 1
            end
        end
        del:close()
        return n
    end)
end

-- Export --------------------------------------------------------------------------------

--- Writes a segment of the facts waiting to be sent. opts: device_id,
-- out_path, now, max_records. Returns nil when there's nothing to send,
-- else { records, more, size }. After a confirmed upload, call
-- markExported with the same file.
function IdStore:export(opts)
    return self:_read(function(conn)
        local stmt = conn:prepare([[
            SELECT f.md5, f.src, f.uuids, f.sig, f.title, f.authors, f.ids, f.n
            FROM id_outbox o JOIN id_facts f ON f.md5 = o.md5 AND f.fact = o.fact
            ORDER BY o.md5, o.fact LIMIT ?;]])
        stmt:bind(opts.max_records)
        local recs = rows(stmt)
        if #recs == 0 then return nil end
        local lines, v2 = { false }, false
        for _, r in ipairs(recs) do
            local rec = { md5 = r[1], src = r[2], uuids = split(r[3]), sig = r[4],
                          title = r[5], authors = r[6], ids = split(r[7]), n = num(r[8]) }
            if IdFormat.needsV2(rec) then v2 = true end
            lines[#lines + 1] = IdFormat.recordLine(rec)
        end
        lines[1] = IdFormat.headerLine(opts.device_id, opts.now, v2 and 2 or 1)
        lines[#lines + 1] = IdFormat.trailerLine(#recs)
        local tmp = opts.out_path .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(table.concat(lines, "\n"), "\n")
        f:close()
        assert(os.rename(tmp, opts.out_path))
        local size = io.open(opts.out_path, "rb"):seek("end")
        return { records = #recs, more = #recs >= opts.max_records, size = size }
    end)
end

local INSERT_SEEN = [[
    INSERT OR REPLACE INTO seen_segments (device_id, name, size, etag, imported_at, events)
    VALUES (?, ?, ?, ?, ?, ?);
]]

--- After a confirmed upload: what the segment holds is sent, and the
-- segment is seen.
function IdStore:markExported(path, device_id, name, size, etag, now)
    return self:_tx(function(conn)
        local del = conn:prepare("DELETE FROM id_outbox WHERE md5 = ? AND fact = ?;")
        local header, err = IdFormat.readSegment(path, { record = function(r)
            del:reset():bind(r.md5, IdFormat.factKey(r)):step()
        end })
        del:close()
        if not header then error(err, 0) end
        local stmt = conn:prepare(INSERT_SEEN)
        stmt:bind(device_id, name, size, etag, now, header.records):step()
        stmt:close()
        return header.records
    end)
end

--- Every fact is to be sent again (a new server or folder).
function IdStore:requeueAll()
    return self:_tx(function(conn)
        conn:exec("INSERT OR IGNORE INTO id_outbox (md5, fact) SELECT md5, fact FROM id_facts;")
    end)
end

-- Import --------------------------------------------------------------------------------

--- Merges a downloaded segment. Returns { records, applied }, or nil, an
-- error and "format" or "db". The segment is recorded as seen in the same
-- transaction.
function IdStore:importSegment(path, device_id, name, size, etag, now)
    local summary = { records = 0, applied = 0 }
    local ok, res, err = pcall(self._tx, self, function(conn)
        local unsend = conn:prepare("DELETE FROM id_outbox WHERE md5 = ? AND fact = ?;")
        local header, rerr = IdFormat.readSegment(path, { record = function(r)
            summary.records = summary.records + 1
            local new, key = addFact(conn, r, r.dev)
            if new then summary.applied = summary.applied + 1 end
            -- Another device has sent it: no need to send it too.
            unsend:reset():bind(r.md5, key):step()
        end })
        unsend:close()
        if not header then error({ format = rerr }, 0) end
        local stmt = conn:prepare(INSERT_SEEN)
        stmt:bind(device_id, name, size, etag, now, header.records):step()
        stmt:close()
        return summary
    end)
    if ok then return res end
    if type(res) == "table" and res.format then return nil, res.format, "format" end
    return nil, tostring(res or err), "db"
end

-- Groups --------------------------------------------------------------------------------

local function normTitle(s)
    if type(s) ~= "string" then return "" end
    return (s:lower():gsub("[%p%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

--- The facts that count, per MD5: { [md5] = { { uuids, sig, title,
-- authors, link (true for a link) }, … } }. A link (a match made outside
-- the file, by another plugin) only counts while it isn't withdrawn, for an
-- MD5 with no fact read from a file, and only when all its links name the
-- same UUIDs: links that disagree leave the MD5 out.
-- Also returns { [uuid] = true } for the UUIDs counting links name: the
-- other plugin's own book IDs (a catalog's), not ones files happen to share.
local function usedFacts(conn)
    local by_md5 = {}
    local all = rows(conn:prepare("SELECT md5, src, uuids, sig, title, authors, n FROM id_facts;"))
    for _, r in ipairs(all) do
        local e = by_md5[r[1]] or { files = {}, links = {}, rows = {} }
        by_md5[r[1]] = e
        if r[2] == "link" or r[2] == "unlink" then
            table.insert(e.rows, r)
        else
            table.insert(e.files, { uuids = r[3], sig = r[4], title = r[5], authors = r[6] })
        end
    end
    local out, catalog = {}, {}
    for md5, e in pairs(by_md5) do
        local numbers = linkNumbers(e.rows, 2, 3, 7)
        local seen = {}
        for _, r in ipairs(e.rows) do
            if r[2] == "link" and linkCounts(numbers[r[3]]) and not seen[r[3]] then
                seen[r[3]] = true
                table.insert(e.links, { uuids = r[3], title = r[5], authors = r[6], link = true })
                for _, uuid in ipairs(split(r[3])) do catalog[uuid] = true end
            end
        end
        if #e.files > 0 then
            out[md5] = e.files
        elseif #e.links == 1 then
            out[md5] = e.links
        end
    end
    return out, catalog
end

--- MD5s that belong together. Two files sharing a UUID are the same book
-- when there's no sign they aren't, or a sign they are:
--   - their titles agree (or one has none), or
--   - they have the same body signature, or
--   - they share two or more UUIDs (Calibre gives a book two, and keeps
--     both when it rewrites the file; a publisher's template shared by a
--     series gives one), or
--   - the UUID is a catalog's own ID for the book (a counting link names it).
-- Otherwise (one shared UUID, other titles, other text) they're taken for
-- different books that share an ID by mistake. Groups are what these pairs
-- connect, transitively: one file that doesn't fit stays out, the rest
-- still join.
--
-- Returns { { md5s = { … }, uuids = { … }, sigs = n (distinct signatures
-- known), title, ok, why }, … }, largest first: the groups of two or more
-- (ok, unless they hold more than MAX_GROUP bodies), and with ok = false
-- the sets of files that share UUIDs but weren't all joined.
local function computeGroups(conn)
    local function forest()
        local parent = {}
        local function find(x)
            parent[x] = parent[x] or x
            while parent[x] ~= x do
                parent[x] = parent[parent[x]]
                x = parent[x]
            end
            return x
        end
        local function union(a, b)
            local ra, rb = find(a), find(b)
            if ra ~= rb then if ra < rb then parent[rb] = ra else parent[ra] = rb end end
        end
        return find, union
    end
    local used, catalog = usedFacts(conn)
    -- What's known of each MD5.
    local info, carriers = {}, {}
    for md5, facts in pairs(used) do
        local e = { uuids = {}, sigs = {}, titles = {}, any_title = nil }
        info[md5] = e
        for _, f in ipairs(facts) do
            for _, uuid in ipairs(split(f.uuids)) do
                if not e.uuids[uuid] then
                    e.uuids[uuid] = true
                    carriers[uuid] = carriers[uuid] or {}
                    table.insert(carriers[uuid], md5)
                end
            end
            if f.sig then e.sigs[f.sig] = true end
            if f.title and normTitle(f.title) ~= "" then
                e.titles[normTitle(f.title)] = true
                e.any_title = e.any_title or f.title
            end
        end
    end
    local function share(a, b)
        for k in pairs(a) do if b[k] then return true end end
        return false
    end
    local function sameBook(a, b, uuid)
        local ia, ib = info[a], info[b]
        if catalog[uuid] then return true end
        if next(ia.titles) == nil or next(ib.titles) == nil or share(ia.titles, ib.titles) then return true end
        if share(ia.sigs, ib.sigs) then return true end
        local n = 0
        for u in pairs(ia.uuids) do if ib.uuids[u] then n = n + 1 end end
        return n >= 2
    end
    local find, union = forest()         -- joined
    local cfind, cunion = forest()       -- sharing a UUID at all
    local uuid_list = {}
    for uuid in pairs(carriers) do uuid_list[#uuid_list + 1] = uuid end
    table.sort(uuid_list)
    for _, uuid in ipairs(uuid_list) do
        local list = carriers[uuid]
        table.sort(list)
        if #list > IdStore.MAX_CARRIERS then
            for i = 2, #list do cunion(list[1], list[i]) end
        else
            for i = 1, #list do
                for j = i + 1, #list do
                    cunion(list[i], list[j])
                    if sameBook(list[i], list[j], uuid) then union(list[i], list[j]) end
                end
            end
        end
    end
    local function collect(findfn)
        local sets = {}
        for md5 in pairs(info) do
            local root = findfn(md5)
            sets[root] = sets[root] or {}
            table.insert(sets[root], md5)
        end
        return sets
    end
    local function describe(md5s)
        table.sort(md5s)
        local g = { md5s = md5s, uuids = {}, ok = true }
        local uuids, sigs, sigless = {}, {}, 0
        for _, md5 in ipairs(md5s) do
            local e = info[md5]
            for u in pairs(e.uuids) do uuids[u] = true end
            if next(e.sigs) == nil then sigless = sigless + 1 end
            for sig in pairs(e.sigs) do sigs[sig] = true end
            g.title = g.title or e.any_title
        end
        for u in pairs(uuids) do g.uuids[#g.uuids + 1] = u end
        table.sort(g.uuids)
        g.sigs = 0
        for _ in pairs(sigs) do g.sigs = g.sigs + 1 end
        g.bodies = g.sigs + sigless
        return g
    end
    local out = {}
    local joined = collect(find)
    for _, md5s in pairs(joined) do
        if #md5s >= 2 then
            local g = describe(md5s)
            if g.bodies > IdStore.MAX_GROUP then
                g.ok, g.why = false, "more than " .. IdStore.MAX_GROUP .. " versions"
            end
            out[#out + 1] = g
        end
    end
    -- Files sharing UUIDs that weren't all joined: reported, not joined.
    for root, md5s in pairs(collect(cfind)) do
        if #md5s >= 2 and #md5s > #joined[find(root)] then
            local g = describe(md5s)
            g.ok, g.why = false, "titles differ"
            out[#out + 1] = g
        end
    end
    table.sort(out, function(a, b)
        if #a.md5s ~= #b.md5s then return #a.md5s > #b.md5s end
        if a.md5s[1] ~= b.md5s[1] then return a.md5s[1] < b.md5s[1] end
        return a.ok and not b.ok
    end)
    return out
end

IdStore.usedFacts = usedFacts

function IdStore:groups()
    return self:_read(computeGroups)
end

--- Within each joined group, the MD5s whose positions match: those sharing
-- a body signature, transitively. Returns { { md5, … } (sorted), … } for
-- sets of two or more.
local function computePositions(conn, groups)
    local sigs = {}
    for _, r in ipairs(rows(conn:prepare("SELECT md5, sig FROM id_facts WHERE sig IS NOT NULL;"))) do
        sigs[r[1]] = sigs[r[1]] or {}
        sigs[r[1]][r[2]] = true
    end
    local out = {}
    for _, g in ipairs(groups) do
        local parent = {}
        local function find(x)
            while parent[x] ~= x do x = parent[x] end
            return x
        end
        local by_sig = {}
        for _, md5 in ipairs(g.md5s) do
            parent[md5] = md5
            for sig in pairs(sigs[md5] or {}) do
                if by_sig[sig] then
                    local ra, rb = find(by_sig[sig]), find(md5)
                    if ra ~= rb then if ra < rb then parent[rb] = ra else parent[ra] = rb end end
                else
                    by_sig[sig] = md5
                end
            end
        end
        local sets = {}
        for _, md5 in ipairs(g.md5s) do
            local root = find(md5)
            sets[root] = sets[root] or {}
            table.insert(sets[root], md5)
        end
        for _, set in pairs(sets) do
            if #set >= 2 then
                table.sort(set)
                out[#out + 1] = set
            end
        end
    end
    return out
end

-- md5 -> its set's members, joined (to tell whether it changed).
local function loadSets(conn, tbl)
    local members = {}
    for _, r in ipairs(rows(conn:prepare("SELECT grp, md5 FROM " .. tbl .. " ORDER BY grp, md5;"))) do
        members[r[1]] = members[r[1]] or {}
        table.insert(members[r[1]], r[2])
    end
    local out = {}
    for _, list in pairs(members) do
        local key = table.concat(list, ",")
        for _, md5 in ipairs(list) do out[md5] = key end
    end
    return out
end

local function diffSets(old, new, changed)
    local any = false
    for md5, key in pairs(old) do if new[md5] ~= key then changed[md5] = true; any = true end end
    for md5, key in pairs(new) do if old[md5] ~= key then changed[md5] = true; any = true end end
    return any
end

local function writeSets(conn, tbl, sets)
    conn:exec("DELETE FROM " .. tbl .. ";")
    local put = conn:prepare("INSERT INTO " .. tbl .. " (md5, grp) VALUES (?, ?);")
    for _, set in ipairs(sets) do
        for _, md5 in ipairs(set) do put:reset():bind(md5, set[1]):step() end
    end
    put:close()
end

--- Brings id_groups and id_pos in line with the facts. Returns the MD5s
-- whose group or position set changed (joined, left, or its members
-- changed): { [md5] = true }.
function IdStore:refreshGroups()
    return self:_tx(function(conn)
        local groups, group_sets = {}, {}
        for _, g in ipairs(computeGroups(conn)) do
            if g.ok then
                groups[#groups + 1] = g
                group_sets[#group_sets + 1] = g.md5s
            end
        end
        local pos_sets = computePositions(conn, groups)
        local function keys(sets)
            local out = {}
            for _, set in ipairs(sets) do
                local key = table.concat(set, ",")
                for _, md5 in ipairs(set) do out[md5] = key end
            end
            return out
        end
        local changed = {}
        if diffSets(loadSets(conn, "id_groups"), keys(group_sets), changed) then
            writeSets(conn, "id_groups", group_sets)
        end
        if diffSets(loadSets(conn, "id_pos"), keys(pos_sets), changed) then
            writeSets(conn, "id_pos", pos_sets)
        end
        return changed
    end)
end

--- The other MD5s whose positions match this one's (level 2: same joined
-- group and same body signature), sorted. Empty when this MD5 has no
-- signature or isn't in a group.
function IdStore:positionPeers(md5)
    return self:_read(function(conn)
        local stmt = conn:prepare([[
            SELECT g.md5 FROM id_pos me JOIN id_pos g ON g.grp = me.grp AND g.md5 <> me.md5
            WHERE me.md5 = ? ORDER BY g.md5;]])
        stmt:bind(md5)
        local out = {}
        for _, r in ipairs(rows(stmt)) do out[#out + 1] = r[1] end
        return out
    end)
end

-- Status --------------------------------------------------------------------------------

--- The UUIDs known for these MD5s (from any device's facts):
-- { [md5] = { uuid, … } }, only for MD5s with any. md5s = { [md5] = true }.
function IdStore:uuids(md5s)
    return self:_read(function(conn)
        local stmt = conn:prepare("SELECT uuid FROM id_uuids WHERE md5 = ? ORDER BY uuid;")
        local out = {}
        for md5 in pairs(md5s) do
            stmt:reset():bind(md5)
            local r = stmt:step()
            while r do
                out[md5] = out[md5] or {}
                table.insert(out[md5], r[1])
                r = stmt:step()
            end
        end
        stmt:close()
        return out
    end)
end

function IdStore:counts()
    local groups = self:groups()
    local versions, editions, held = 0, 0, 0
    for _, g in ipairs(groups) do
        if not g.ok then held = held + 1
        elseif g.sigs > 1 then editions = editions + 1
        else versions = versions + 1 end
    end
    return self:_read(function(conn)
        return {
            files = num(conn:rowexec("SELECT count(DISTINCT md5) FROM id_facts;")),
            scanned = num(conn:rowexec("SELECT count(*) FROM id_scanned;")),
            outbox = num(conn:rowexec("SELECT count(*) FROM id_outbox;")),
            groups = #groups, versions = versions, editions = editions, held = held,
        }
    end)
end

return IdStore
