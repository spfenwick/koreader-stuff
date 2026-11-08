--[[
The catalog cache: one SQLite database per library (server and account).

books        one row per catalog entry, keyed by the entry's UUID
meta         key/value: server key, sync times and results
local_files  what's known about files in the library folder (see matcher)

Lists are stored as text joined with "\n" (authors, tags), as CoverBrowser
does. formats is "type\tsize\thref" lines. match_title and match_author
are the title and first author normalised for matching (see matcher.lua),
so loading doesn't redo it for every book.
]]

local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local SCHEMA_VERSION = 5

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS books (
    uuid TEXT PRIMARY KEY,
    calibre_id INTEGER,
    title TEXT,
    authors TEXT,
    tags TEXT,
    language TEXT,
    publisher TEXT,
    published INTEGER,
    added INTEGER,
    pages INTEGER,
    summary TEXT,
    formats TEXT,
    cover TEXT,
    size INTEGER,
    series TEXT,
    series_index REAL,
    seen INTEGER,
    series_seen INTEGER,
    cover_file TEXT,
    cover_w INTEGER,
    cover_h INTEGER,
    cover_failed INTEGER,
    match_title TEXT,
    match_author TEXT
);
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
CREATE TABLE IF NOT EXISTS local_files (
    path TEXT PRIMARY KEY,
    mtime INTEGER,
    size INTEGER,
    uuids TEXT,
    title TEXT,
    authors TEXT
);
]]

local Store = {}
Store.__index = Store

local function num(v)
    return v ~= nil and tonumber(v) or nil
end

local function join(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    return table.concat(list, "\n")
end

local function split(s)
    local out = {}
    if type(s) ~= "string" then return out end
    for line in s:gmatch("[^\n]+") do table.insert(out, line) end
    return out
end
Store.split = split

--- Opens (and creates or upgrades) the database at path.
-- wal: use WAL journaling (KOReader's Device:canUseWAL()).
function Store.open(path, wal)
    local conn = SQ3.open(path)
    conn:set_busy_timeout(5000)
    conn:exec(wal and "PRAGMA journal_mode=WAL;" or "PRAGMA journal_mode=TRUNCATE;")
    local version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if version == 1 then
        -- 1 -> 2: covers.
        conn:exec([[ALTER TABLE books ADD COLUMN cover_file TEXT;
            ALTER TABLE books ADD COLUMN cover_w INTEGER;
            ALTER TABLE books ADD COLUMN cover_h INTEGER;
            ALTER TABLE books ADD COLUMN cover_failed INTEGER;]])
    end
    if version == 1 or version == 2 then
        -- 2 -> 3: version 2 also marked covers as failed when the network
        -- was lost; forget those marks.
        conn:exec("UPDATE books SET cover_failed = NULL;")
    end
    if version >= 1 and version <= 3 then
        -- 3 -> 4: the matcher missed UUIDs written "uuid:..." (newer
        -- Calibre); read every file again.
        conn:exec("DELETE FROM local_files;")
    end
    if version >= 1 and version <= 4 then
        -- 4 -> 5: normalised title and author (filled by fillMatchKeys()).
        local have = {}
        local stmt = conn:prepare("PRAGMA table_info(books);")
        for row in stmt:rows() do have[row[2]] = true end
        stmt:close()
        for _i, col in ipairs({ "match_title", "match_author" }) do
            if not have[col] then conn:exec("ALTER TABLE books ADD COLUMN " .. col .. " TEXT;") end
        end
    elseif version ~= 0 and version ~= SCHEMA_VERSION then
        -- A cache: start again rather than migrate.
        logger.info("CloudLibrary: catalog schema", version, "-> rebuilding")
        conn:exec("DROP TABLE IF EXISTS books; DROP TABLE IF EXISTS meta; DROP TABLE IF EXISTS local_files;")
    end
    -- Up to date: nothing to write (a write here is a disk sync on e-readers).
    if version ~= SCHEMA_VERSION then
        conn:exec(SCHEMA)
        conn:exec("PRAGMA user_version=" .. SCHEMA_VERSION .. ";")
    end
    return setmetatable({ conn = conn, path = path }, Store)
end

function Store:close()
    if self.conn then
        self.conn:close()
        self.conn = nil
    end
end

function Store:begin() self.conn:exec("BEGIN;") end
function Store:commit() self.conn:exec("COMMIT;") end
function Store:rollback() pcall(self.conn.exec, self.conn, "ROLLBACK;") end

function Store:getMeta(key)
    local stmt = self.conn:prepare("SELECT value FROM meta WHERE key = ?;")
    local row = stmt:bind(key):step()
    local value = row and row[1]
    stmt:close()
    return value ~= nil and tostring(value) or nil
end

function Store:setMeta(key, value)
    local stmt = self.conn:prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);")
    stmt:bind(key, value ~= nil and tostring(value) or nil):step()
    stmt:close()
end

local UPSERT = [[
INSERT INTO books (uuid, calibre_id, title, authors, tags, language, publisher,
    published, added, pages, summary, formats, cover, size, seen, match_title, match_author)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(uuid) DO UPDATE SET
    calibre_id = excluded.calibre_id, title = excluded.title,
    authors = excluded.authors, tags = excluded.tags, language = excluded.language,
    publisher = excluded.publisher, published = excluded.published,
    added = excluded.added, pages = excluded.pages, summary = excluded.summary,
    formats = excluded.formats, cover = excluded.cover, size = excluded.size,
    seen = excluded.seen, match_title = excluded.match_title, match_author = excluded.match_author,
    -- A new cover link means a new cover: forget the downloaded one.
    cover_file = CASE WHEN cover IS excluded.cover THEN cover_file END,
    cover_w = CASE WHEN cover IS excluded.cover THEN cover_w END,
    cover_h = CASE WHEN cover IS excluded.cover THEN cover_h END,
    cover_failed = CASE WHEN cover IS excluded.cover THEN cover_failed END;
]]

local function formatsText(formats)
    local lines = {}
    for _i, f in ipairs(formats or {}) do
        table.insert(lines, table.concat({ f.type or "", tostring(f.size or ""), f.href or "" }, "\t"))
    end
    return join(lines)
end

--- Inserts or updates parsed feed books (see feed.lua). Returns how many
-- weren't in the store before.
function Store:upsertBooks(books, seen)
    local normalize = require("cloudlibrary/matcher").normalize
    local exists = self.conn:prepare("SELECT 1 FROM books WHERE uuid = ?;")
    local stmt = self.conn:prepare(UPSERT)
    local added = 0
    for _i, b in ipairs(books) do
        if b.uuid and b.uuid ~= "" then
            if not exists:reset():bind(b.uuid):step() then added = added + 1 end
            exists:clearbind()
            local size = 0
            for _j, f in ipairs(b.formats or {}) do size = math.max(size, f.size or 0) end
            local pages = b.custom and tonumber(b.custom.Pages or b.custom.pages)
            stmt:reset():bind(b.uuid, b.calibre_id, b.title, join(b.authors), join(b.tags),
                b.languages and b.languages[1], b.publisher, b.published, b.added, pages,
                b.summary, formatsText(b.formats), b.cover, size, seen,
                normalize(b.title), normalize(b.authors and b.authors[1])):step()
            stmt:clearbind()
        end
    end
    exists:close()
    stmt:close()
    return added
end

--- Deletes books not seen by the full crawl stamped `seen`. Returns the count.
function Store:deleteUnseen(seen)
    local before = self:count()
    local stmt = self.conn:prepare("DELETE FROM books WHERE seen IS NULL OR seen <> ?;")
    stmt:bind(seen):step()
    stmt:close()
    return before - self:count()
end

function Store:setSeries(uuid, name, index, seen)
    local stmt = self.conn:prepare(
        "UPDATE books SET series = ?, series_index = ?, series_seen = ? WHERE uuid = ?;")
    stmt:bind(name, index, seen, uuid):step()
    stmt:close()
end

function Store:clearSeriesNotSeen(seen)
    local stmt = self.conn:prepare(
        "UPDATE books SET series = NULL, series_index = NULL WHERE series_seen IS NULL OR series_seen <> ?;")
    stmt:bind(seen):step()
    stmt:close()
end

function Store:count()
    return tonumber(self.conn:rowexec("SELECT COUNT(*) FROM books;")) or 0
end

function Store:has(uuid)
    local stmt = self.conn:prepare("SELECT 1 FROM books WHERE uuid = ?;")
    local found = stmt:bind(uuid):step() ~= nil
    stmt:close()
    return found
end

-- Listing rows split their authors and tags only when they're used.
local LIST_FIELDS = { authors = 3, tags = 4 }
local ListingRow = {
    __index = function(book, key)
        local raw = LIST_FIELDS[key] and rawget(book, "_" .. key)
        if raw == nil then return nil end
        local list = split(raw ~= false and raw or nil)
        rawset(book, key, list)
        return list
    end,
}

--- What the file browser needs for every book (no summaries), and the
-- cover counts: { with a cover on the server, downloaded, failed }.
-- Numbers are read as REAL: integers would come back as boxed 64-bit
-- values, slow to make and convert for thousands of rows.
function Store:listing()
    local out = {}
    local with_cover, downloaded, failed = 0, 0, 0
    local stmt = self.conn:prepare([[SELECT uuid, title, authors, tags, language,
        CAST(added AS REAL), CAST(size AS REAL), series, series_index, CAST(pages AS REAL),
        cover, cover_file, CAST(cover_w AS REAL), CAST(cover_h AS REAL), CAST(cover_failed AS REAL),
        match_title, match_author FROM books;]])
    local row = {}
    while stmt:step(row) do
        local book = setmetatable({
            id = row[1], title = row[2], _authors = row[3] or false, _tags = row[4] or false,
            language = row[5], added = row[6], size = row[7],
            series = row[8], series_index = row[9], pages = row[10],
            cover_href = row[11], cover_file = row[12], cover_w = row[13],
            cover_h = row[14], cover_failed = row[15],
            match_title = row[16], match_author = row[17],
        }, ListingRow)
        out[#out + 1] = book
        if row[11] ~= nil then with_cover = with_cover + 1 end
        if row[12] ~= nil then downloaded = downloaded + 1
        elseif row[15] ~= nil then failed = failed + 1 end
    end
    stmt:close()
    return out, { with_cover = with_cover, downloaded = downloaded, failed = failed }
end

--- Fills match_title and match_author where missing (rows from before
-- schema 5). Returns how many were filled.
function Store:fillMatchKeys()
    local normalize = require("cloudlibrary/matcher").normalize
    local rows = {}
    local stmt = self.conn:prepare("SELECT uuid, title, authors FROM books WHERE match_title IS NULL;")
    for row in stmt:rows() do
        table.insert(rows, { row[1], normalize(row[2]), normalize(split(row[3])[1]) })
    end
    stmt:close()
    if #rows == 0 then return 0 end
    local upd = self.conn:prepare("UPDATE books SET match_title = ?, match_author = ? WHERE uuid = ?;")
    self:begin()
    for _i, r in ipairs(rows) do
        upd:reset():bind(r[2], r[3], r[1]):step()
        upd:clearbind()
    end
    self:commit()
    upd:close()
    return #rows
end

--- One book with everything, for the details sheet.
function Store:getBook(uuid)
    local stmt = self.conn:prepare([[SELECT uuid, calibre_id, title, authors, tags,
        language, publisher, published, added, pages, summary, formats, cover, size,
        series, series_index FROM books WHERE uuid = ?;]])
    local row = stmt:bind(uuid):step()
    local book
    if row then
        book = {
            id = row[1], calibre_id = num(row[2]), title = row[3], authors = split(row[4]),
            tags = split(row[5]), language = row[6], publisher = row[7],
            published = num(row[8]), added = num(row[9]), pages = num(row[10]),
            summary = row[11], formats = {}, cover_href = row[13], size = num(row[14]),
            series = row[15], series_index = num(row[16]),
        }
        for _i, line in ipairs(split(row[12])) do
            local t, size, href = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
            if t then table.insert(book.formats, { type = t, size = tonumber(size), href = href }) end
        end
    end
    stmt:close()
    return book
end

-- Covers ------------------------------------------------------------------------

--- Records a downloaded cover (file path relative to the covers folder,
-- image size).
function Store:setCover(uuid, file, w, h)
    local stmt = self.conn:prepare(
        "UPDATE books SET cover_file = ?, cover_w = ?, cover_h = ?, cover_failed = NULL WHERE uuid = ?;")
    stmt:bind(file, w, h, uuid):step()
    stmt:close()
end

--- Renames a cover file (moved to another place in the covers folder).
function Store:moveCoverFile(old, new)
    local stmt = self.conn:prepare("UPDATE books SET cover_file = ? WHERE cover_file = ?;")
    stmt:bind(new, old):step()
    stmt:close()
end

function Store:setCoverFailed(uuid, when)
    local stmt = self.conn:prepare("UPDATE books SET cover_failed = ? WHERE uuid = ?;")
    stmt:bind(when, uuid):step()
    stmt:close()
end

--- Books with a cover on the server but not here, newest first. Failed
-- downloads are retried once they're older than retry_before.
function Store:missingCovers(limit, retry_before)
    local out = {}
    local stmt = self.conn:prepare([[SELECT uuid, cover FROM books
        WHERE cover IS NOT NULL AND cover_file IS NULL
          AND (cover_failed IS NULL OR cover_failed < ?)
        ORDER BY added DESC LIMIT ?;]])
    stmt:bind(retry_before or 0, limit or -1)
    for row in stmt:rows() do
        table.insert(out, { id = row[1], href = row[2] })
    end
    stmt:close()
    return out
end

function Store:coverCounts()
    local with_cover, downloaded, failed = self.conn:rowexec([[SELECT
        COUNT(CASE WHEN cover IS NOT NULL THEN 1 END),
        COUNT(cover_file),
        COUNT(CASE WHEN cover_file IS NULL AND cover_failed IS NOT NULL THEN 1 END) FROM books;]])
    return tonumber(with_cover) or 0, tonumber(downloaded) or 0, tonumber(failed) or 0
end

--- Cover file names in use.
function Store:coverFiles()
    local out = {}
    local stmt = self.conn:prepare("SELECT cover_file FROM books WHERE cover_file IS NOT NULL;")
    for row in stmt:rows() do out[row[1]] = true end
    stmt:close()
    return out
end

-- Local files ------------------------------------------------------------------

function Store:localFiles()
    local out = {}
    local stmt = self.conn:prepare("SELECT path, mtime, size, uuids, title, authors FROM local_files;")
    for row in stmt:rows() do
        out[row[1]] = {
            mtime = num(row[2]), size = num(row[3]), uuids = split(row[4]),
            title = row[5], authors = split(row[6]),
        }
    end
    stmt:close()
    return out
end

function Store:setLocalFile(path, info)
    local stmt = self.conn:prepare([[INSERT OR REPLACE INTO local_files
        (path, mtime, size, uuids, title, authors) VALUES (?, ?, ?, ?, ?, ?);]])
    stmt:bind(path, info.mtime, info.size, join(info.uuids), info.title, join(info.authors)):step()
    stmt:close()
end

function Store:removeLocalFile(path)
    local stmt = self.conn:prepare("DELETE FROM local_files WHERE path = ?;")
    stmt:bind(path):step()
    stmt:close()
end

return Store
