--[[--
Database side of statsync: what to export, merging imported segments into
statistics.sqlite3, and the plugin's own state (statsync.sqlite3).

Only the main KOReader process uses this module. Every write is a short
transaction, opened and closed in one call, so the statistics plugin (which
runs in the same process, between our calls) never finds the database
locked by us.

Event key: (md5, page, start_time). Merge rule: union by key; for a key on
both sides, the larger duration wins, with the total_pages of the row that
has it; on equal durations the larger total_pages wins (so the result
doesn't depend on order).
--]]

local Codec = require("concordance/codec")

local Store = {}
Store.__index = Store

local BUSY_TIMEOUT_MS = 5000

-- Same as STATISTICS_SQL_BOOK_TOTALS_QUERY in statistics.koplugin/main.lua,
-- which insertDB() stores in book.total_read_pages/total_read_time. The
-- tests compare this with the text in KOReader's source.
Store.BOOK_TOTALS_QUERY = [[
    SELECT count(DISTINCT page),
           sum(duration)
    FROM   page_stat
    WHERE  id_book = %d;
]]

-- foreign_books: book rows statsync created, for books known only from other
-- devices. While KOReader hasn't touched one (last_open unchanged), its title
-- and authors follow the newest remote record, otherwise they're local.
-- (No semicolons in SQL comments: ljsqlite3's exec splits on them.)
local STATE_SCHEMA = [[
    CREATE TABLE IF NOT EXISTS exported (
        md5        TEXT    NOT NULL,
        page       INTEGER NOT NULL,
        start_time INTEGER NOT NULL,
        duration   INTEGER NOT NULL,
        PRIMARY KEY (md5, page, start_time)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS seen_segments (
        device_id   TEXT    NOT NULL,
        name        TEXT    NOT NULL,
        size        INTEGER,
        etag        TEXT,
        imported_at INTEGER,
        events      INTEGER,
        PRIMARY KEY (device_id, name)
    );
    CREATE TABLE IF NOT EXISTS bad_segments (
        device_id TEXT    NOT NULL,
        name      TEXT    NOT NULL,
        size      INTEGER,
        etag      TEXT,
        version   INTEGER,
        reason    TEXT,
        PRIMARY KEY (device_id, name)
    );
    CREATE TABLE IF NOT EXISTS foreign_books (
        id_book   INTEGER PRIMARY KEY,
        md5       TEXT NOT NULL,
        last_open INTEGER
    );
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT
    );
]]

local function num(v) return v ~= nil and tonumber(v) or nil end

--- opts: sq3 (lua-ljsqlite3 module), stats_path, state_path, logger (optional),
-- join_versions (default true: readings of a book's other versions go into
-- the row this device keeps for it, see joinVersions; false keeps a row per
-- file), open_md5 (optional, function -> the open book's MD5: its rows are
-- never removed)
function Store.new(opts)
    local self = setmetatable({}, Store)
    self.SQ3 = assert(opts.sq3, "sq3 module")
    self.stats_path = assert(opts.stats_path)
    self.state_path = assert(opts.state_path)
    self.log = opts.logger
    self.join_versions = opts.join_versions ~= false
    self.open_md5 = opts.open_md5
    return self
end

function Store:_openMd5()
    if not self.open_md5 then return nil end
    local ok, md5 = pcall(self.open_md5)
    return ok and md5 or nil
end

function Store:_open(path)
    local conn = self.SQ3.open(path)
    conn:set_busy_timeout(BUSY_TIMEOUT_MS)
    return conn
end

function Store:openState()
    local conn = self:_open(self.state_path)
    conn:exec(STATE_SCHEMA)
    return conn
end

function Store:openStats()
    local conn = self:_open(self.stats_path)
    local ok, has_book = pcall(conn.rowexec, conn,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('book', 'page_stat_data');")
    if not ok or num(has_book) ~= 2 then
        conn:close()
        return nil, "statistics database not initialised"
    end
    return conn
end

local function packn(...) return { n = select("#", ...), ... } end

local function withConn(conn, fn)
    local res = packn(pcall(fn, conn))
    conn:close()
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

local function rollback(conn)
    pcall(conn.exec, conn, "ROLLBACK;")
end

-- Export --------------------------------------------------------------------

-- A cheap summary of page_stat_data (one pass, no joins). Only used to
-- skip the export diff when nothing changed since everything was known to
-- be exported: any change at all (new rows, a VACUUM renumbering rowids)
-- gives another value, and then the full diff runs.
local FINGERPRINT_QUERY = "SELECT count(*), max(rowid), total(duration) FROM page_stat_data;"

local function fingerprint(conn)
    local n, maxid, total = conn:rowexec(FINGERPRINT_QUERY)
    return string.format("%s/%s/%s", tostring(num(n)), tostring(num(maxid)), tostring(num(total)))
end

function Store:_getMeta(key)
    local conn = self:openState()
    return withConn(conn, function()
        local row = conn:prepare("SELECT value FROM meta WHERE key = ?;"):bind(key):step()
        return row and row[1]
    end)
end

function Store:_setMeta(key, value)
    local conn = self:openState()
    return withConn(conn, function()
        conn:prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);"):bind(key, value):step()
    end)
end

--- Records that everything in page_stat_data as of fingerprint `fp` is exported.
function Store:markClean(fp)
    if fp then self:_setMeta("clean_fingerprint", fp) end
end

--- Writes a segment of events this device hasn't published yet.
-- opts: device_id, out_path, now, max_events, and force_diff (don't skip the
-- diff even if page_stat_data looks unchanged).
-- Returns nil when there's nothing new, else { events, books, more, size, fp }.
-- `more` means max_events was reached and another segment is due. After a
-- confirmed upload of a segment without `more`, call markClean(res.fp).
function Store:export(opts)
    local state = self:openState() -- creates the schema on first use
    state:close()
    local clean = self:_getMeta("clean_fingerprint")
    local conn, err = self:openStats()
    if not conn then return nil, err end
    local fp
    local res = packn(withConn(conn, function()
        fp = fingerprint(conn)
        if not opts.force_diff and fp == clean then return nil, nil, "unchanged" end
        conn:exec("ATTACH DATABASE '" .. self.state_path:gsub("'", "''") .. "' AS st;")
        local stmt = conn:prepare([[
            SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages
            FROM   page_stat_data p
            JOIN   book b ON b.id = p.id_book
            LEFT JOIN st.exported e
                   ON e.md5 = b.md5 AND e.page = p.page AND e.start_time = p.start_time
            WHERE  b.md5 IS NOT NULL AND b.md5 <> ''
              AND  p.duration > coalesce(e.duration, -1)
            ORDER  BY p.start_time, b.md5, p.page
            LIMIT  ?;
        ]])
        stmt:bind(opts.max_events)
        local events, md5s, md5_list = {}, {}, {}
        local row = stmt:step()
        while row do
            local md5 = row[1]
            events[#events + 1] = Codec.eventLine(md5, num(row[2]), num(row[3]), num(row[4]), num(row[5]) or 0)
            if not md5s[md5] then
                md5s[md5] = true
                md5_list[#md5_list + 1] = md5
            end
            row = stmt:step()
        end
        stmt:close()
        conn:exec("DETACH DATABASE st;")
        if #events == 0 then return nil, nil, "nothing new" end

        -- Metadata of the books these events belong to: of several local
        -- rows for one md5, the most recently opened.
        local bstmt = conn:prepare([[
            SELECT title, authors, series, language, pages, last_open
            FROM   book WHERE md5 = ?
            ORDER  BY last_open DESC, id ASC LIMIT 1;
        ]])
        table.sort(md5_list)
        local book_lines = {}
        for _, md5 in ipairs(md5_list) do
            local b = bstmt:reset():bind(md5):step()
            book_lines[#book_lines + 1] = Codec.bookLine{
                md5 = md5, title = b[1], authors = b[2], series = b[3], language = b[4],
                pages = num(b[5]), last_open = num(b[6]),
            }
        end
        bstmt:close()

        local tmp = opts.out_path .. ".tmp"
        local f = assert(io.open(tmp, "wb"))
        f:write(Codec.headerLine(opts.device_id, opts.now), "\n")
        f:write(table.concat(book_lines, "\n"), "\n")
        f:write(table.concat(events, "\n"), "\n")
        f:write(Codec.trailerLine(#book_lines, #events), "\n")
        f:close()
        assert(os.rename(tmp, opts.out_path))
        local size = io.open(opts.out_path, "rb"):seek("end")
        return { events = #events, books = #book_lines, more = #events >= opts.max_events, size = size, fp = fp }
    end))
    if res[3] == "nothing new" then self:markClean(fp) end
    return res[1], res[2], res[3]
end

-- Exported / seen bookkeeping ----------------------------------------------

local UPSERT_EXPORTED = [[
    INSERT INTO exported (md5, page, start_time, duration) VALUES (?, ?, ?, ?)
    ON CONFLICT (md5, page, start_time) DO UPDATE SET duration = max(duration, excluded.duration);
]]
local INSERT_SEEN = [[
    INSERT OR REPLACE INTO seen_segments (device_id, name, size, etag, imported_at, events)
    VALUES (?, ?, ?, ?, ?, ?);
]]

--- After a confirmed upload: records the segment's events as exported, and
-- the segment as seen (it's this device's own data, nothing to import).
function Store:markExported(path, device_id, name, size, etag, now)
    local conn = self:openState()
    return withConn(conn, function()
        conn:exec("BEGIN;")
        local ok, res, err = pcall(function()
            local up = conn:prepare(UPSERT_EXPORTED)
            local header, rerr = Codec.readSegment(path, { event = function(e)
                up:reset():bind(e.md5, e.page, e.start, e.dur):step()
            end })
            up:close()
            if not header then return nil, rerr end
            conn:prepare(INSERT_SEEN):bind(device_id, name, size, etag, now, header.events):step()
            return header.events
        end)
        if not ok or not res then
            rollback(conn)
            if not ok then error(res, 0) end
            return nil, err
        end
        conn:exec("COMMIT;")
        return res
    end)
end

--- Records segments as seen without importing them: a pack's (whose
-- records are already here, or were just imported) and the segments it
-- covers. items: { name, size, etag, exact }; with exact, the row is
-- replaced (size and ETag known), otherwise only added if missing.
function Store:markSeen(device_id, items, now)
    local conn = self:openState()
    return withConn(conn, function()
        conn:exec("BEGIN;")
        local ok, err = pcall(function()
            local put = conn:prepare(INSERT_SEEN)
            local add = conn:prepare([[
                INSERT OR IGNORE INTO seen_segments (device_id, name, size, etag, imported_at, events)
                VALUES (?, ?, NULL, NULL, ?, NULL);]])
            for _, it in ipairs(items) do
                if it.exact then
                    put:reset():bind(device_id, it.name, it.size, it.etag, now, it.events or 0):step()
                else
                    add:reset():bind(device_id, it.name, now):step()
                end
            end
            put:close()
            add:close()
        end)
        if not ok then
            rollback(conn)
            error(err, 0)
        end
        conn:exec("COMMIT;")
        return true
    end)
end

--- { [device_id] = { [name] = { size=, etag= } } } of imported segments.
function Store:seenSegments()
    local conn = self:openState()
    return withConn(conn, function()
        local seen = {}
        for row in conn:prepare("SELECT device_id, name, size, etag FROM seen_segments;"):rows() do
            seen[row[1]] = seen[row[1]] or {}
            seen[row[1]][row[2]] = { size = num(row[3]), etag = row[4] }
        end
        return seen
    end)
end

--- Segments that failed to import with this format version, same shape.
-- `version`: another stream's (annotations'), default the statistics'.
function Store:badSegments(version)
    local conn = self:openState()
    return withConn(conn, function()
        local bad = {}
        local stmt = conn:prepare("SELECT device_id, name, size, etag, reason FROM bad_segments WHERE version = ?;")
        stmt:bind(version or (Codec.VERSION * 1000 + Codec.MINOR))
        for row in stmt:rows() do
            bad[row[1]] = bad[row[1]] or {}
            bad[row[1]][row[2]] = { size = num(row[3]), etag = row[4], reason = row[5] }
        end
        return bad
    end)
end

function Store:recordBad(device_id, name, size, etag, reason, version)
    local conn = self:openState()
    return withConn(conn, function()
        conn:prepare("INSERT OR REPLACE INTO bad_segments VALUES (?, ?, ?, ?, ?, ?);")
            :bind(device_id, name, size, etag, version or (Codec.VERSION * 1000 + Codec.MINOR), reason):step()
    end)
end

--- "Rebuild from server": forget which segments were imported (and which
-- were bad), so the next sync imports everything again.
function Store:forgetSeen()
    local conn = self:openState()
    return withConn(conn, function()
        conn:exec("DELETE FROM seen_segments; DELETE FROM bad_segments;")
    end)
end

--- Records where segments go (server and folder). When that changes, the
-- record of what was sent and imported is about the old place, so it's
-- cleared: everything is sent to, and imported from, the new one.
-- Returns true when it cleared something.
function Store:useLocation(location)
    local old = self:_getMeta("location")
    if old == location then return false end
    local conn = self:openState()
    withConn(conn, function()
        conn:exec("BEGIN;")
        local ok, err = pcall(function()
            if old then
                conn:exec("DELETE FROM exported; DELETE FROM seen_segments; DELETE FROM bad_segments;")
                conn:exec("DELETE FROM meta WHERE key = 'clean_fingerprint';")
            end
            local stmt = conn:prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('location', ?);")
            stmt:bind(location):step()
            stmt:close()
            conn:exec("COMMIT;")
        end)
        if not ok then rollback(conn); error(err, 0) end
    end)
    return old ~= nil
end

--- The folder was renamed on the server, files and all: if segments went
-- to `from`, they're taken to be at `to`, so nothing is sent again.
-- Returns true when it moved.
function Store:moveLocation(from, to)
    if not from or not to or from == to or self:_getMeta("location") ~= from then return false end
    local conn = self:openState()
    withConn(conn, function()
        local stmt = conn:prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('location', ?);")
        stmt:bind(to):step()
        stmt:close()
    end)
    return true
end

--- Forgets where segments went. Without `resend`, the next location is
-- taken as the same place (the folder was moved, files and all), so nothing
-- is sent again. With `resend`, everything is sent to it and imported again.
function Store:forgetLocation(resend)
    local conn = self:openState()
    return withConn(conn, function()
        if resend then
            conn:exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('location', '(send everything again)');")
        else
            conn:exec("DELETE FROM meta WHERE key = 'location';")
        end
    end)
end

function Store:counts()
    local conn = self:openState()
    return withConn(conn, function()
        return {
            exported = num(conn:rowexec("SELECT count(*) FROM exported;")),
            seen = num(conn:rowexec("SELECT count(*) FROM seen_segments WHERE name LIKE 'seg-%';")),
            bad = num(conn:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'seg-%';")),
            ann_seen = num(conn:rowexec("SELECT count(*) FROM seen_segments WHERE name LIKE 'ann-%';")),
            ann_bad = num(conn:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'ann-%';")),
            book_seen = num(conn:rowexec("SELECT count(*) FROM seen_segments WHERE name LIKE 'book-%';")),
            book_bad = num(conn:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'book-%';")),
            id_seen = num(conn:rowexec("SELECT count(*) FROM seen_segments WHERE name LIKE 'id-%';")),
            id_bad = num(conn:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'id-%';")),
        }
    end)
end

-- Import ---------------------------------------------------------------------

local function str(v) return v == nil and "" or tostring(v) end

-- Tie-break for equal last_open, so foreign rows converge whatever the order.
local function metaKey(b)
    return table.concat({ str(b.title), str(b.authors), str(b.series), str(b.language), str(b.pages) }, "\0")
end

--- Moves book row `from`'s events into row `to`. A key on both sides
-- follows the merge rule. Returns the events that were in `from`
-- ({ { page, start, dur }, … }), empty if none.
local function mergeRow(conn, from, to)
    local q_events = conn:prepare("SELECT page, start_time, duration, total_pages FROM page_stat_data WHERE id_book = ?;")
    local events = {}
    q_events:bind(from)
    local e = q_events:step()
    while e do
        events[#events + 1] = { num(e[1]), num(e[2]), num(e[3]), num(e[4]) or 0 }
        e = q_events:step()
    end
    q_events:close()
    if #events == 0 then return events end
    local q_event = conn:prepare("SELECT duration, total_pages FROM page_stat_data WHERE id_book = ? AND page = ? AND start_time = ?;")
    local upd_event = conn:prepare("UPDATE page_stat_data SET duration = ?, total_pages = ? WHERE id_book = ? AND page = ? AND start_time = ?;")
    local del_event = conn:prepare("DELETE FROM page_stat_data WHERE id_book = ? AND page = ? AND start_time = ?;")
    for _, ev in ipairs(events) do
        -- Keys the target already has: keep the winner there, drop this copy.
        local page, start, dur, tp = ev[1], ev[2], ev[3], ev[4]
        local t = q_event:reset():bind(to, page, start):step()
        if t then
            local t_dur, t_tp = num(t[1]), num(t[2]) or 0
            if dur > t_dur or (dur == t_dur and tp > t_tp) then
                upd_event:reset():bind(dur, tp, to, page, start):step()
            end
            del_event:reset():bind(from, page, start):step()
        end
    end
    local move = conn:prepare("UPDATE page_stat_data SET id_book = ? WHERE id_book = ?;")
    move:bind(to, from):step()
    for _, st in ipairs({ q_event, upd_event, del_event, move }) do st:close() end
    return events
end

--- Gathers each book's events into one row. KOReader makes a new book row
-- when a file's title or authors change, so one md5 can have several rows,
-- and how the events are split between them differs from device to device.
-- Each md5's events go to its most recently opened row (the one KOReader
-- uses now, and where imports put new events); the other rows are left
-- empty. A key on both sides follows the merge rule. Adds the ids it
-- changed to `affected`.
function Store.consolidate(conn, affected)
    local md5s = {}
    local q_md5s = conn:prepare([[
        SELECT md5 FROM book WHERE md5 IS NOT NULL AND md5 <> ''
        GROUP BY md5 HAVING count(*) > 1;]])
    local m = q_md5s:step()
    while m do
        md5s[#md5s + 1] = m[1]
        m = q_md5s:step()
    end
    q_md5s:close()
    if #md5s == 0 then return end
    local q_rows = conn:prepare("SELECT id FROM book WHERE md5 = ? ORDER BY last_open DESC, id ASC;")
    for _, md5 in ipairs(md5s) do
        local ids = {}
        q_rows:reset():bind(md5)
        local r = q_rows:step()
        while r do
            ids[#ids + 1] = num(r[1])
            r = q_rows:step()
        end
        local target = ids[1]
        for i = 2, #ids do
            if #mergeRow(conn, ids[i], target) > 0 then
                affected[ids[i]] = true
                affected[target] = true
            end
        end
    end
    q_rows:close()
end

-- Versions of a book ---------------------------------------------------------
--
-- The book identity's joined groups (id_groups in the state database, kept
-- by idstore.lua) say which MD5s are one book. Readings stay under the MD5
-- they were made with on the server; on this device, the readings of a
-- book's versions gather in one row (see IDENTITY.md, Statistics):
--
-- - the row they go to: the most recently opened row this device uses for
--   any of the versions, else (a book only known from other devices) the
--   most recently opened of the rows made for them;
-- - rows made only for other devices' readings (foreign_books, untouched
--   by KOReader since) are emptied into it and removed. Rows KOReader uses
--   here stay: with two versions opened on this device, each keeps its own
--   (the reader shows the open file's row), and imports for a version
--   with a row of its own go there;
-- - readings that join a row of another MD5 are marked exported under that
--   MD5 too, so they're never sent as this device's own.
--
-- Files no device has an identity record for (gone before book identity
-- read them, or without a UUID, such as PDFs) are joined by title and
-- author instead, for statistics only: a file without a record joins the
-- book whose statistics carry exactly the same title and authors (see
-- Store.titleKey), when only one book does; files without a record that
-- share a title and authors, with no such book, join each other. Files
-- with records are only ever joined by identity. The web app follows the
-- same rule (concordance-web/app/library.py).

--- Changes when the rules below change, so every device joins again once
-- (1: by identity, 2: and by title for files without a record).
Store.JOIN_RULES = 2

local function hasTable(conn, name)
    local n = conn:rowexec("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '" .. name .. "';")
    return num(n) ~= 0
end

--- What two books must share to be joined by title: lowercased (ASCII),
-- punctuation and control characters as spaces, spaces collapsed, title
-- and authors joined. Nil when either is missing or a placeholder.
function Store.titleKey(title, authors)
    local function norm(v)
        if type(v) ~= "string" then return "" end
        return (v:lower():gsub("[%p%c]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
    end
    local t, a = norm(title), norm(authors)
    if t == "" or t == "n a" or t == "untitled" then return nil end
    if a == "" or a == "n a" or a == "unknown" or a == "unknown author" then return nil end
    return t .. "\0" .. a
end

--- md5 -> { md5, … } (its group, sorted), for MD5s in joined groups: the
-- book identity's, widened by title for files without a record (above).
-- Only once book identity is in use (its tables exist).
local function loadGroups(stats, state)
    if not hasTable(state, "id_groups") then return {} end
    local of, by = {}, {}
    local stmt = state:prepare("SELECT md5, grp FROM id_groups ORDER BY grp, md5;")
    local r = stmt:step()
    while r do
        local md5, grp = r[1], r[2]
        by[grp] = by[grp] or {}
        table.insert(by[grp], md5)
        of[md5] = by[grp]
        r = stmt:step()
    end
    stmt:close()
    if not hasTable(state, "id_facts") then return of end

    local recorded = {}
    stmt = state:prepare("SELECT DISTINCT md5 FROM id_facts;")
    r = stmt:step()
    while r do recorded[r[1]] = true; r = stmt:step() end
    stmt:close()
    local by_key, keys = {}, {}
    stmt = stats:prepare("SELECT DISTINCT md5, title, authors FROM book WHERE md5 IS NOT NULL ORDER BY md5;")
    r = stmt:step()
    while r do
        local key = Store.titleKey(r[2], r[3])
        if key then
            if not by_key[key] then by_key[key] = {}; keys[#keys + 1] = key end
            table.insert(by_key[key], r[1])
        end
        r = stmt:step()
    end
    stmt:close()
    table.sort(keys)
    local placed = {}
    for _, key in ipairs(keys) do
        local loose, book, books, seen = {}, nil, 0, {}
        for _, md5 in ipairs(by_key[key]) do
            if recorded[md5] then
                local id = of[md5] and of[md5][1] or md5 -- the book: its group, or the file alone
                if not seen[id] then seen[id], book, books = true, id, books + 1 end
            elseif not placed[md5] then
                loose[#loose + 1] = md5
            end
        end
        if #loose > 0 and books <= 1 then
            local members = {}
            if book then
                for _, m in ipairs(of[book] or { book }) do members[#members + 1] = m end
            end
            for _, m in ipairs(loose) do
                members[#members + 1] = m
                placed[m] = true
            end
            if #members >= 2 then
                table.sort(members)
                for _, m in ipairs(members) do of[m] = members end
            end
        end
    end
    return of
end

--- The rows of these MD5s, the one their readings go to first:
-- { { id, md5, last_open, foreign }, … }. now_foreign: rows made in this
-- import, not yet in foreign_books.
local function versionRows(stats, state, md5s, now_foreign)
    local q_rows = stats:prepare("SELECT id, last_open FROM book WHERE md5 = ?;")
    local q_foreign = state:prepare("SELECT md5, last_open FROM foreign_books WHERE id_book = ?;")
    local out = {}
    for _, md5 in ipairs(md5s) do
        q_rows:reset():bind(md5)
        local r = q_rows:step()
        while r do
            local row = { id = num(r[1]), md5 = md5, last_open = num(r[2]) }
            local f = q_foreign:reset():bind(row.id):step()
            row.foreign = (now_foreign and now_foreign[row.id] ~= nil)
                or (f ~= nil and f[1] == md5 and num(f[2]) == row.last_open)
            out[#out + 1] = row
            r = q_rows:step()
        end
    end
    q_rows:close()
    q_foreign:close()
    table.sort(out, function(a, b)
        if a.foreign ~= b.foreign then return not a.foreign end
        if (a.last_open or 0) ~= (b.last_open or 0) then return (a.last_open or 0) > (b.last_open or 0) end
        return a.id < b.id
    end)
    return out
end

--- Empties the rows made for other devices' readings of a book's versions
-- into the row its readings go to (see above). Adds the ids it changed to
-- `affected`; returns the number of rows removed. keep_md5: the open
-- book's MD5 (its rows stay).
function Store.joinVersionsIn(stats, state, affected, keep_md5)
    local groups = loadGroups(stats, state)
    local done, removed = {}, 0
    local up = state:prepare(UPSERT_EXPORTED)
    local del_book = stats:prepare("DELETE FROM book WHERE id = ?;")
    local del_foreign = state:prepare("DELETE FROM foreign_books WHERE id_book = ?;")
    for _, group in pairs(groups) do
        if not done[group] then
            done[group] = true
            local rows = versionRows(stats, state, group)
            local target = rows[1]
            for i = 2, #rows do
                local r = rows[i]
                if r.foreign and r.md5 ~= keep_md5 then
                    for _, ev in ipairs(mergeRow(stats, r.id, target.id)) do
                        up:reset():bind(target.md5, ev[1], ev[2], ev[3]):step()
                    end
                    del_book:reset():bind(r.id):step()
                    del_foreign:reset():bind(r.id):step()
                    affected[target.id] = true
                    removed = removed + 1
                end
            end
        end
    end
    for _, st in ipairs({ up, del_book, del_foreign }) do st:close() end
    return removed
end

--- Recomputes book.total_read_pages/total_read_time the way insertDB() does.
function Store.recomputeTotals(conn, ids)
    local up = conn:prepare("UPDATE book SET total_read_time = ?, total_read_pages = ? WHERE id = ?;")
    for id in pairs(ids) do
        local pages, time = conn:rowexec(string.format(Store.BOOK_TOTALS_QUERY, id))
        up:reset():bind(time, pages, id):step()
    end
    up:close()
end

-- Merges one parsed segment into the open stats and state connections,
-- inside transactions the caller opened. Returns the summary, or raises.
local function mergeSegment(stats, state, path, opts)
    opts = opts or {}
    local summary = { events = 0, inserted = 0, updated = 0, books_new = 0, books_updated = 0, affected = {} }
    local now_foreign = {}
    local groups = opts.join and loadGroups(stats, state) or {}

    local q_ids = stats:prepare("SELECT id, title, authors, series, language, pages, last_open FROM book WHERE md5 = ? ORDER BY last_open DESC, id ASC;")
    local q_foreign = state:prepare("SELECT md5, last_open FROM foreign_books WHERE id_book = ?;")
    local q_exists = stats:prepare("SELECT id FROM book WHERE title IS ? AND authors IS ? AND md5 = ? AND id <> ?;")
    local ins_book = stats:prepare([[
        INSERT INTO book (title, authors, notes, last_open, highlights, pages, series, language, md5, total_read_time, total_read_pages)
        VALUES (?, ?, 0, ?, 0, ?, ?, ?, ?, 0, 0);
    ]])
    local upd_full = stats:prepare("UPDATE book SET title = ?, authors = ?, series = ?, language = ?, pages = ?, last_open = ? WHERE id = ?;")
    local upd_meta = stats:prepare("UPDATE book SET series = ?, language = ?, last_open = ? WHERE id = ?;")
    local upd_last = stats:prepare("UPDATE book SET last_open = ? WHERE id = ?;")
    local set_foreign = state:prepare("INSERT OR REPLACE INTO foreign_books (id_book, md5, last_open) VALUES (?, ?, ?);")
    local q_event = stats:prepare("SELECT duration, total_pages FROM page_stat_data WHERE id_book = ? AND page = ? AND start_time = ?;")
    local ins_event = stats:prepare("INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES (?, ?, ?, ?, ?);")
    local upd_event = stats:prepare("UPDATE page_stat_data SET duration = ?, total_pages = ? WHERE id_book = ? AND page = ? AND start_time = ?;")
    local up_exported = state:prepare(UPSERT_EXPORTED)

    -- md5 -> { target = id, ids = { id, … } }
    local books = {}

    local function localRows(md5)
        local rows = {}
        q_ids:reset():bind(md5)
        local r = q_ids:step()
        while r do
            rows[#rows + 1] = { id = num(r[1]), title = r[2], authors = r[3], series = r[4],
                                language = r[5], pages = num(r[6]), last_open = num(r[7]) }
            r = q_ids:step()
        end
        return rows
    end

    local function isUntouchedForeign(row, md5)
        local f = q_foreign:reset():bind(row.id):step()
        if not f then return false end
        return f[1] == md5 and num(f[2]) == row.last_open
    end

    local function onBook(rec)
        local md5 = rec.md5
        local rows = localRows(md5)
        -- A version of a book with no row of its own that KOReader uses:
        -- its readings go to the book's row (another version's).
        local group = groups[md5]
        if group then
            local own = false
            for _, r in ipairs(rows) do
                if not (now_foreign[r.id] or isUntouchedForeign(r, md5)) then own = true break end
            end
            if not own then
                local vrows = versionRows(stats, state, group, now_foreign)
                local target = vrows[1]
                if target and target.md5 ~= md5 then
                    local ids, md5s = {}, {}
                    for i, r in ipairs(vrows) do
                        ids[i] = r.id
                        md5s[r.id] = r.md5
                    end
                    books[md5] = { target = target.id, ids = ids, target_md5 = target.md5, md5s = md5s }
                    return
                end
            end
        end
        if #rows == 0 then
            ins_book:reset():bind(rec.title or "N/A", rec.authors or "N/A", rec.last_open, rec.pages,
                rec.series or "N/A", rec.language or "N/A", md5):step()
            local id = num(stats:rowexec("SELECT last_insert_rowid();"))
            books[md5] = { target = id, ids = { id } }
            now_foreign[id] = { md5 = md5, last_open = rec.last_open }
            summary.books_new = summary.books_new + 1
            summary.affected[id] = true
            return
        end
        local ids = {}
        for i, r in ipairs(rows) do ids[i] = r.id end
        local target = rows[1] -- most recently opened local row
        books[md5] = books[md5] or { target = target.id, ids = ids }
        local in_last, t_last = rec.last_open or 0, target.last_open or 0
        if isUntouchedForeign(target, md5) or now_foreign[target.id] then
            -- Only known from other devices: newest record wins entirely.
            if in_last > t_last or (in_last == t_last and metaKey(rec) > metaKey(target)) then
                local title, authors = rec.title or "N/A", rec.authors or "N/A"
                if q_exists:reset():bind(title, authors, md5, target.id):step() then
                    title, authors = target.title, target.authors -- would clash with another row
                end
                upd_full:reset():bind(title, authors, rec.series or "N/A", rec.language or "N/A",
                    rec.pages, rec.last_open, target.id):step()
                now_foreign[target.id] = { md5 = md5, last_open = rec.last_open }
                summary.books_updated = summary.books_updated + 1
            end
        elseif in_last > t_last then
            -- KOReader finds this row by its own title and authors: keep
            -- those (and the local page count, which the page_stat view
            -- scales by), take the rest from the newer record.
            if rec.series or rec.language then
                upd_meta:reset():bind(rec.series or target.series, rec.language or target.language,
                    rec.last_open, target.id):step()
            else
                upd_last:reset():bind(rec.last_open, target.id):step()
            end
            summary.books_updated = summary.books_updated + 1
        end
    end

    local function onEvent(e)
        local b = books[e.md5]
        summary.events = summary.events + 1
        local found_id, found_dur, found_tp
        for _, id in ipairs(b.ids) do
            local r = q_event:reset():bind(id, e.page, e.start):step()
            if r and (not found_id or num(r[1]) > found_dur) then
                found_id, found_dur, found_tp = id, num(r[1]), num(r[2])
            end
        end
        if not found_id then
            ins_event:reset():bind(b.target, e.page, e.start, e.dur, e.tp):step()
            summary.inserted = summary.inserted + 1
            summary.affected[b.target] = true
        elseif e.dur > found_dur or (e.dur == found_dur and e.tp > (found_tp or 0)) then
            upd_event:reset():bind(e.dur, e.tp, found_id, e.page, e.start):step()
            summary.updated = summary.updated + 1
            summary.affected[found_id] = true
        end
        up_exported:reset():bind(e.md5, e.page, e.start, e.dur):step()
        if b.target_md5 then
            -- Under the row's MD5 too, or it would go out as this device's.
            up_exported:reset():bind(b.target_md5, e.page, e.start, e.dur):step()
            -- And under the MD5 of the row it was found in, when that's
            -- another of the book's rows.
            local found_md5 = found_id and b.md5s and b.md5s[found_id]
            if found_md5 and found_md5 ~= b.target_md5 and found_md5 ~= e.md5 then
                up_exported:reset():bind(found_md5, e.page, e.start, e.dur):step()
            end
        end
    end

    local header, err = Codec.readSegment(path, { book = onBook, event = onEvent })
    for _, s in ipairs({ q_ids, q_foreign, q_exists, ins_book, upd_full, upd_meta, upd_last,
                         q_event, ins_event, upd_event, up_exported }) do
        s:close()
    end
    if header then
        for id, f in pairs(now_foreign) do
            set_foreign:reset():bind(id, f.md5, f.last_open):step()
        end
    end
    set_foreign:close()
    if not header then return nil, err end
    if opts.join then
        summary.joined = Store.joinVersionsIn(stats, state, summary.affected, opts.keep_md5)
    end
    Store.consolidate(stats, summary.affected)
    Store.recomputeTotals(stats, summary.affected)
    return summary
end

--- Gathers the readings of each book's versions (see Versions of a book),
-- after the groups changed. Returns { removed (rows), affected (ids) }, or
-- nil and an error.
function Store:joinVersions()
    if not self.join_versions then return { removed = 0, affected = {} } end
    local stats = self:openStats()
    if not stats then return { removed = 0, affected = {} } end -- statistics not in use
    local state = self:openState()
    local affected = {}
    local keep = self:_openMd5()
    local ok, removed = pcall(function()
        stats:exec("BEGIN IMMEDIATE;")
        state:exec("BEGIN IMMEDIATE;")
        local n = Store.joinVersionsIn(stats, state, affected, keep)
        Store.consolidate(stats, affected)
        Store.recomputeTotals(stats, affected)
        return n
    end)
    if ok then
        local cok, cerr = pcall(stats.exec, stats, "COMMIT;")
        if cok then cok, cerr = pcall(state.exec, state, "COMMIT;") end
        if not cok then ok, removed = false, cerr end
    end
    if not ok then rollback(stats); rollback(state) end
    stats:close()
    state:close()
    if not ok then return nil, tostring(removed) end
    return { removed = removed, affected = affected }
end

--- Imports one downloaded segment. Both databases are written in their own
-- transaction; statistics first, so a crash in between at worst repeats
-- the (idempotent) import next time, and never marks unimported data seen.
-- Returns the summary, or nil, an error, and "format" (the file is bad) or
-- "db" (database trouble). Either way the segment is left unseen.
function Store:importSegment(path, device_id, name, size, etag, now)
    local stats, err = self:openStats()
    if not stats then return nil, err, "db" end
    local state = self:openState()
    local ok, summary, merr = pcall(function()
        stats:exec("BEGIN IMMEDIATE;")
        state:exec("BEGIN IMMEDIATE;")
        -- If everything was exported before this import, it still is after
        -- (imported events go into `exported`), so carry the fingerprint
        -- forward. Nothing else can write while we hold the write lock.
        -- (Statements that returned a row must be closed before COMMIT.)
        local q_clean = state:prepare("SELECT value FROM meta WHERE key = 'clean_fingerprint';")
        local clean_row = q_clean:step()
        q_clean:close()
        local was_clean = clean_row and clean_row[1] == fingerprint(stats)
        local s, e = mergeSegment(stats, state, path,
            { join = self.join_versions, keep_md5 = self.join_versions and self:_openMd5() or nil })
        if not s then return nil, e end
        state:prepare(INSERT_SEEN):bind(device_id, name, size, etag, now, s.events):step()
        if was_clean then
            state:prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('clean_fingerprint', ?);")
                :bind(fingerprint(stats)):step()
        end
        return s
    end)
    if ok and summary then
        local cok, cerr = pcall(stats.exec, stats, "COMMIT;")
        if cok then
            cok, cerr = pcall(state.exec, state, "COMMIT;")
        end
        if not cok then
            rollback(stats); rollback(state)
            ok, summary, merr = false, nil, cerr
        end
    else
        rollback(stats)
        rollback(state)
    end
    stats:close()
    state:close()
    if not ok then return nil, tostring(merr or summary), "db" end
    if not summary then return nil, merr, "format" end
    return summary
end

return Store
