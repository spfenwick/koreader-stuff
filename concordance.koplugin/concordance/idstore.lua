--[[--
The book identity side of the sync state database (concordance/state.sqlite3):
facts about book files from every device (see idformat.lua), what's
waiting to be sent, and which files this device has read. Main process
only; every call is one short transaction.

Facts don't change, so the merged state is a set: importing adds the
facts not already there. Nothing is ever removed.

Tables:

    id_facts   (md5, fact) -> src, uuids ("\n"-joined), sig, title,
               authors, ids ("\n"-joined), device (first to send it)
    id_uuids   (uuid, md5): the UUIDs of each MD5, for grouping
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

--- Groups with more MD5s than this aren't joined (see IDENTITY.md).
IdStore.MAX_GROUP = 8

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

function IdStore:open()
    local conn = self.SQ3.open(self.state_path)
    conn:set_busy_timeout(BUSY_TIMEOUT_MS)
    conn:exec(SCHEMA)
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

--- Adds a fact unless it's known. Returns true if it was new.
local function addFact(conn, r, device)
    local key = IdFormat.factKey(r)
    local q = conn:prepare("SELECT 1 FROM id_facts WHERE md5 = ? AND fact = ?;")
    local known = q:bind(r.md5, key):step()
    q:close()
    if known then return false, key end
    local uuids = IdFormat.sortedUnique(r.uuids)
    local put = conn:prepare([[
        INSERT INTO id_facts (md5, fact, src, uuids, sig, title, authors, ids, device)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);]])
    put:bind(r.md5, key, r.src, table.concat(uuids, "\n"), r.sig, r.title, r.authors,
        r.ids and #r.ids > 0 and table.concat(r.ids, "\n") or nil, device):step()
    put:close()
    local u = conn:prepare("INSERT OR IGNORE INTO id_uuids (uuid, md5) VALUES (?, ?);")
    for _, uuid in ipairs(uuids) do u:reset():bind(uuid, r.md5):step() end
    u:close()
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
-- list = { { md5, uuids, title, authors }, … }. Only facts not known yet
-- are written and sent. Returns the number of new facts.
function IdStore:link(list, device)
    local new = self:_read(function(conn)
        local out = {}
        local q = conn:prepare("SELECT 1 FROM id_facts WHERE md5 = ? AND fact = ?;")
        for _, l in ipairs(list) do
            local uuids = {}
            for _, u in ipairs(l.uuids or {}) do uuids[#uuids + 1] = IdFormat.normalizeUuid(u) end
            local r = { md5 = l.md5, src = "link", uuids = uuids, title = l.title, authors = l.authors }
            if IdFormat.validRecord(r) and not q:reset():bind(r.md5, IdFormat.factKey(r)):step() then
                out[#out + 1] = r
            end
        end
        q:close()
        return out
    end)
    if #new == 0 then return 0 end
    return self:_tx(function(conn)
        local added = 0
        local o = conn:prepare("INSERT OR IGNORE INTO id_outbox (md5, fact) VALUES (?, ?);")
        for _, r in ipairs(new) do
            local isnew, key = addFact(conn, r, device)
            if isnew then
                o:reset():bind(r.md5, key):step()
                added = added + 1
            end
        end
        o:close()
        return added
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
            SELECT f.md5, f.src, f.uuids, f.sig, f.title, f.authors, f.ids
            FROM id_outbox o JOIN id_facts f ON f.md5 = o.md5 AND f.fact = o.fact
            ORDER BY o.md5, o.fact LIMIT ?;]])
        stmt:bind(opts.max_records)
        local recs = rows(stmt)
        if #recs == 0 then return nil end
        local lines = { IdFormat.headerLine(opts.device_id, opts.now) }
        for _, r in ipairs(recs) do
            lines[#lines + 1] = IdFormat.recordLine{ md5 = r[1], src = r[2], uuids = split(r[3]), sig = r[4],
                                                     title = r[5], authors = r[6], ids = split(r[7]) }
        end
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
-- authors }, … } }. A link (a match made outside the file, by another
-- plugin) only counts for an MD5 with no fact read from a file, and only
-- when all its links name the same UUIDs: links that disagree leave the
-- MD5 out.
local function usedFacts(conn)
    local by_md5 = {}
    for _, r in ipairs(rows(conn:prepare("SELECT md5, src, uuids, sig, title, authors FROM id_facts;"))) do
        local e = by_md5[r[1]] or { files = {}, links = {} }
        by_md5[r[1]] = e
        local f = { uuids = r[3], sig = r[4], title = r[5], authors = r[6] }
        if r[2] == "link" then table.insert(e.links, f) else table.insert(e.files, f) end
    end
    local out = {}
    for md5, e in pairs(by_md5) do
        if #e.files > 0 then
            out[md5] = e.files
        else
            local same = true
            for i = 2, #e.links do
                if e.links[i].uuids ~= e.links[1].uuids then same = false end
            end
            if same then out[md5] = e.links end
        end
    end
    return out
end

--- MD5s that belong together: those sharing a UUID, transitively. Returns
-- { { md5s = { … }, uuids = { … }, sigs = n (distinct signatures known),
-- title, ok (false when a guard stops it being joined), why }, … } for
-- groups of two or more MD5s, largest first.
local function computeGroups(conn)
    local parent = {}
    local function find(x)
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
    local used = usedFacts(conn)
    local pairs_list = {}
    for md5, facts in pairs(used) do
        for _, f in ipairs(facts) do
            for _, uuid in ipairs(split(f.uuids)) do pairs_list[#pairs_list + 1] = { uuid, md5 } end
        end
    end
    table.sort(pairs_list, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[2] < b[2]
    end)
    local by_uuid = {}
    for _, p in ipairs(pairs_list) do
        local uuid, md5 = p[1], p[2]
        parent[md5] = parent[md5] or md5
        if by_uuid[uuid] then union(by_uuid[uuid], md5) else by_uuid[uuid] = md5 end
    end
    local groups = {}
    for md5 in pairs(parent) do
        local root = find(md5)
        groups[root] = groups[root] or { md5s = {}, uuids = {}, sig_set = {}, titles = {} }
        table.insert(groups[root].md5s, md5)
    end
    for uuid, md5 in pairs(by_uuid) do
        table.insert(groups[find(md5)].uuids, uuid)
    end
    for md5, facts in pairs(used) do
        local g = groups[find(md5)]
        for _, f in ipairs(facts) do
            if f.sig then g.sig_set[f.sig] = true end
            if f.title then
                local first_author = (f.authors or ""):match("^[^\n]*")
                g.titles[normTitle(f.title) .. "\0" .. normTitle(first_author)] = f.title
            end
        end
    end
    local out = {}
    for _, g in pairs(groups) do
        if #g.md5s >= 2 then
            table.sort(g.md5s)
            table.sort(g.uuids)
            local sigs = 0
            for _ in pairs(g.sig_set) do sigs = sigs + 1 end
            g.sigs, g.sig_set = sigs, nil
            -- Guards: unrelated books sharing a UUID by mistake.
            local titles, authors_of = {}, {}
            for key, title in pairs(g.titles) do
                local t, a = key:match("^(.-)%z(.*)$")
                titles[t] = true
                authors_of[a] = true
                g.title = g.title or title
            end
            local function count(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end
            g.titles = nil
            g.ok = true
            if #g.md5s > IdStore.MAX_GROUP then
                g.ok, g.why = false, "more than " .. IdStore.MAX_GROUP .. " files"
            elseif count(titles) > 1 and count(authors_of) > 1 then
                g.ok, g.why = false, "titles and authors differ"
            end
            out[#out + 1] = g
        end
    end
    table.sort(out, function(a, b)
        if #a.md5s ~= #b.md5s then return #a.md5s > #b.md5s end
        return a.md5s[1] < b.md5s[1]
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
