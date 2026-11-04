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

local Codec = require("supersync/codec")

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

--- opts: sq3 (lua-ljsqlite3 module), stats_path, state_path, logger (optional)
function Store.new(opts)
    local self = setmetatable({}, Store)
    self.SQ3 = assert(opts.sq3, "sq3 module")
    self.stats_path = assert(opts.stats_path)
    self.state_path = assert(opts.state_path)
    self.log = opts.logger
    return self
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

--- "Rebuild from cloud": forget which segments were imported (and which
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
        }
    end)
end

-- Import ---------------------------------------------------------------------

local function str(v) return v == nil and "" or tostring(v) end

-- Tie-break for equal last_open, so foreign rows converge whatever the order.
local function metaKey(b)
    return table.concat({ str(b.title), str(b.authors), str(b.series), str(b.language), str(b.pages) }, "\0")
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
local function mergeSegment(stats, state, path)
    local summary = { events = 0, inserted = 0, updated = 0, books_new = 0, books_updated = 0, affected = {} }
    local now_foreign = {}

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
    Store.recomputeTotals(stats, summary.affected)
    return summary
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
        local s, e = mergeSegment(stats, state, path)
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
