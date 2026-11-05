--[[
Tests for cloudlibrary.koplugin: feed parsing, the catalog store, full and
quick sync against a fake Calibre-Web server, matching local files, and
virtual entries. Runs in KOReader's own LuaJIT (for SQLite, libarchive, luxl):

    tests/cloudlibrary/run_tests.sh
]]

local REPO, TMP = arg[1], arg[2]
assert(REPO and TMP, "usage: test_cloudlibrary.lua <repo> <tmpdir>")

require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(TMP .. "/settings.reader.lua")
-- As reader.lua does at startup (needed to draw icons).
require("document/canvascontext"):init(require("device"))
package.path = REPO .. "/cloudlibrary.koplugin/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Feed = require("cloudlibrary/feed")
local Store = require("cloudlibrary/store")
local Sync = require("cloudlibrary/sync")
local Matcher = require("cloudlibrary/matcher")
local Virtual = require("cloudlibrary/virtual")
local Covers = require("cloudlibrary/covers")
local Downloads = require("cloudlibrary/downloads")

local failures, checks = 0, 0
local function check(cond, msg)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.stderr:write("FAIL: " .. msg .. "\n")
    end
    return cond
end

local function eq(a, b, msg)
    return check(a == b, msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

local function esc(s)
    return (s:gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- Every module loads (catches mistakes in code that only runs at load time) ------------

do
    for _i, name in ipairs({ "badge", "covers", "downloads", "feed", "http", "library", "matcher",
            "search", "store", "sync", "timing", "virtual" }) do
        local ok, err = pcall(require, "cloudlibrary/" .. name)
        check(ok, "module " .. name .. " loads: " .. tostring(err))
    end
    local chunk, err = loadfile(REPO .. "/cloudlibrary.koplugin/main.lua")
    check(chunk ~= nil, "main.lua parses: " .. tostring(err))
    local ok, plugin = pcall(chunk)
    check(ok and type(plugin) == "table" and plugin.name == "cloudlibrary", "main.lua loads: " .. tostring(plugin))
end

-- A fake Calibre-Web OPDS server -------------------------------------------------

local ORIGIN = "https://cwa.test"

local Server = {}
Server.__index = Server

function Server.new(books, page_size)
    return setmetatable({ books = books, page_size = page_size or 3, fail = {}, log = {} }, Server)
end

local function feedXml(self_href, entries, next_href)
    local out = { '<?xml version="1.0" encoding="UTF-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">',
        '<id>urn:uuid:feed</id><title>Test</title>',
        '<link rel="self" href="' .. esc(self_href) .. '" type="application/atom+xml"/>',
        '<link rel="start" href="/opds" type="application/atom+xml"/>' }
    if next_href then
        table.insert(out, '<link rel="next" title="Next" href="' .. esc(next_href) .. '" type="application/atom+xml"/>')
    end
    for _i, e in ipairs(entries) do table.insert(out, e) end
    table.insert(out, "</feed>")
    return table.concat(out, "\n")
end

local function navEntry(title, href)
    return "<entry><title>" .. esc(title) .. "</title><id>" .. esc(href) .. "</id>"
        .. '<link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="' .. esc(href) .. '"/></entry>'
end

local function bookEntry(b)
    local parts = { "<entry>", "<title>" .. esc(b.title) .. "</title>",
        "<id>urn:uuid:" .. b.uuid .. "</id>",
        "<updated>" .. os.date("!%Y-%m-%dT%H:%M:%S+00:00", b.added) .. "</updated>" }
    for _i, a in ipairs(b.authors) do
        table.insert(parts, "<author><name>" .. esc(a) .. "</name></author>")
    end
    table.insert(parts, "<published>" .. (b.year and (b.year .. "-05-01") or "101-01-01") .. "T00:00:00+00:00</published>")
    table.insert(parts, "<dcterms:language>eng</dcterms:language>")
    for _i, t in ipairs(b.tags or {}) do
        table.insert(parts, '<category scheme="http://www.bisg.org/standards/bisac_subject/index.html" term="'
            .. esc(t) .. '" label="' .. esc(t) .. '"/>')
    end
    if b.pages then
        table.insert(parts, '<category scheme="custom_column:Pages" term="Pages" label="' .. b.pages .. '"/>')
    end
    if b.summary then table.insert(parts, "<summary>" .. esc(b.summary) .. "</summary>") end
    table.insert(parts, '<link type="image/jpeg" href="/opds/cover/' .. b.id .. '" rel="http://opds-spec.org/image"/>')
    table.insert(parts, '<link type="image/jpeg" href="/opds/cover/' .. b.id .. '" rel="http://opds-spec.org/image/thumbnail"/>')
    table.insert(parts, '<link rel="http://opds-spec.org/acquisition" href="/opds/download/' .. b.id
        .. '/' .. (b.format or "epub") .. '/" length="' .. (b.size or 1000) .. '" type="application/'
        .. ((b.format or "epub") == "pdf" and "pdf" or "epub+zip") .. '"/>')
    table.insert(parts, "</entry>")
    return table.concat(parts)
end

local function paged(self, path, items, render)
    local offset = tonumber(path:match("offset=(%d+)")) or 0
    local base = path:gsub("%?.*$", "")
    local entries = {}
    for i = offset + 1, math.min(offset + self.page_size, #items) do
        table.insert(entries, render(items[i]))
    end
    local next_href = offset + self.page_size < #items
        and (base .. "?offset=" .. (offset + self.page_size)) or nil
    return feedXml(path, entries, next_href)
end

function Server:sorted(by)
    local list = {}
    for _i, b in ipairs(self.books) do table.insert(list, b) end
    if by == "title" then
        table.sort(list, function(a, b) return a.title < b.title end)
    else
        table.sort(list, function(a, b) return a.added > b.added end)
    end
    return list
end

function Server:seriesList()
    local names, members = {}, {}
    for _i, b in ipairs(self.books) do
        if b.series then
            if not members[b.series] then
                members[b.series] = {}
                table.insert(names, b.series)
            end
            table.insert(members[b.series], b)
        end
    end
    table.sort(names)
    for _i, name in ipairs(names) do
        table.sort(members[name], function(a, b) return a.series_index < b.series_index end)
    end
    return names, members
end

function Server:handle(url)
    table.insert(self.log, url)
    local path = url:sub(#ORIGIN + 1)
    if path == "" then path = "/" end
    for pattern in pairs(self.fail) do
        if path:find(pattern, 1, true) then return nil, "fake failure: " .. path end
    end
    local route = path:gsub("%?.*$", "")
    if route == "/" or route == "/opds" then
        return feedXml("/opds", {
            navEntry("Alphabetical Books", "/opds/books"),
            navEntry("Recently added Books", "/opds/new"),
            navEntry("Authors", "/opds/author"),
            navEntry("Series", "/opds/series"),
        })
    elseif route == "/opds/books" then
        return feedXml("/opds/books?", { navEntry("All", "/opds/books/letter/00"), navEntry("A", "/opds/books/letter/A") })
    elseif route == "/opds/books/letter/00" then
        return paged(self, path, self:sorted("title"), bookEntry)
    elseif route == "/opds/new" then
        return paged(self, path, self:sorted("added"), bookEntry)
    elseif route == "/opds/series" then
        return feedXml("/opds/series?", { navEntry("All", "/opds/series/letter/00"), navEntry("B", "/opds/series/letter/B") })
    elseif route == "/opds/series/letter/00" then
        local names = self:seriesList()
        local ids = {}
        for i, name in ipairs(names) do ids[i] = { name = name, id = i } end
        self.series_ids = ids
        return paged(self, path, ids, function(s) return navEntry(s.name, "/opds/series/" .. s.id) end)
    elseif route:match("^/opds/series/%d+$") then
        local n = tonumber(route:match("(%d+)$"))
        local _names, members = self:seriesList()
        local s = self.series_ids and self.series_ids[n]
        return paged(self, path, s and members[s.name] or {}, bookEntry)
    elseif route == "/opds/stats" then
        return string.format('{"books": %d, "authors": 1, "categories": 1, "series": 1}', #self.books)
    end
    return nil, "404 " .. path
end

local function makeBooks(n)
    local books = {}
    for i = 1, n do
        books[i] = {
            id = 1000 + i,
            uuid = string.format("00000000-0000-4000-8000-%012d", i),
            title = string.format("Book %02d", i),
            authors = { "Author " .. (i % 3) },
            added = 1700000000 + i * 3600,
            year = 2000 + i,
            tags = { "Fiction" },
            pages = 100 + i,
            summary = "Summary " .. i,
        }
    end
    return books
end

local function newSync(store, server, now)
    return Sync.new{
        store = store, root = ORIGIN .. "/",
        fetch = function(url) return server:handle(url) end,
        now = now and function() return now end,
    }
end

local function rmrf(path) os.execute("rm -rf '" .. path .. "'") end
local function mkdir(path) os.execute("mkdir -p '" .. path .. "'") end

-- Feed ---------------------------------------------------------------------------

do
    local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
  <!-- a comment -->
  <link rel="next" title="Next" href="/opds/books/letter/00?offset=60" type="application/atom+xml"/>
  <entry>
    <title>Smith &amp; Wesson&#8217;s &#x201C;Book&#x201D;</title>
    <id>urn:uuid:b8a79349-b2f7-406d-bd6b-1daa4ef57361</id>
    <updated>2025-04-23T11:28:40+02:00</updated>
    <author><name>Ann One</name></author>
    <author><name>Bob Two</name></author>
    <publisher><name>Pub</name></publisher>
    <published>101-01-01T00:00:00+00:00</published>
    <dcterms:language>eng</dcterms:language>
    <dcterms:language>fra</dcterms:language>
    <category scheme="http://www.bisg.org/standards/bisac_subject/index.html" term="Technology" label="Technology"/>
    <category scheme="custom_column:Pages" term="Pages" label="120"/>
    <summary>Line one &lt;b&gt;bold&lt;/b&gt;</summary>
    <link type="image/jpeg" href="/opds/cover/3506" rel="http://opds-spec.org/image"/>
    <link type="image/jpeg" href="/opds/thumb/3506" rel="http://opds-spec.org/image/thumbnail"/>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/3506/epub/"
          length="646372" mtime="2025-04-23T11:28:40+00:00" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/3506/pdf/" length="9" type="application/pdf"/>
  </entry>
  <entry>
    <title>Second</title>
    <id>urn:uuid:22222222-2222-4222-8222-222222222222</id>
    <updated>2024-01-01T00:00:00+00:00</updated>
    <published>1999-03-04T00:00:00+00:00</published>
    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Para<br/>graph</p></div></content>
    <link rel="http://opds-spec.org/acquisition/open-access" href="/get/2" type="application/epub+zip"/>
  </entry>
  <entry>
    <title>All</title>
    <id>/opds/books/letter/00</id>
    <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/opds/books/letter/00"/>
  </entry>
</feed>]]
    local feed = Feed.parse(xml)
    check(feed ~= nil, "feed parses")
    eq(feed.next, "/opds/books/letter/00?offset=60", "next link")
    eq(#feed.books, 2, "book entries")
    eq(#feed.sections, 1, "navigation entries")
    eq(feed.sections[1].title, "All", "section title")
    local b = feed.books[1]
    eq(b.title, "Smith & Wesson\u{2019}s \u{201C}Book\u{201D}", "entities decoded")
    eq(b.uuid, "b8a79349-b2f7-406d-bd6b-1daa4ef57361", "uuid from urn")
    eq(#b.authors, 2, "both authors kept")
    eq(b.authors[2], "Bob Two", "second author")
    eq(#b.languages, 2, "both languages kept")
    eq(b.publisher, "Pub", "publisher")
    eq(b.published, nil, "Calibre's year 101 is unknown")
    eq(b.added, 1745400520, "time with +02:00 offset")
    eq(b.tags[1], "Technology", "tag")
    eq(#b.tags, 1, "custom column isn't a tag")
    eq(b.custom.Pages, "120", "custom column")
    eq(b.summary, "Line one <b>bold</b>", "summary text")
    eq(b.cover, "/opds/thumb/3506", "thumbnail preferred")
    eq(b.calibre_id, 3506, "calibre id from download link")
    eq(#b.formats, 2, "both formats")
    eq(b.formats[1].size, 646372, "format size")
    local b2 = feed.books[2]
    eq(b2.published, 1999, "year")
    check(b2.summary and b2.summary:find("Para", 1, true), "xhtml content kept as text")
    eq(#b2.formats, 1, "acquisition sub-relation counts")
    eq(Feed.parseTime("2024-02-29T23:59:59Z"), 1709251199, "leap day")
    eq(Feed.parseTime("1970-01-01T00:00:00+00:00"), 0, "epoch")
    check(Feed.parse("<html><body>no</body></html>") == nil, "non-feed rejected")
end

-- Errors keep their message through the timing wrappers ------------------------------------

do
    os.execute("mkdir -p '" .. TMP .. "/db'")
    local store = Store.open(TMP .. "/db/err.sqlite3", false)
    local s = Sync.new{ store = store, root = ORIGIN .. "/",
        fetch = function() return nil, "Network error: host not found", "network" end }
    local r, err = s:full()
    check(r == nil and err == "Network error: host not found", "sync error message kept: " .. tostring(err))
    store:close()
end

-- Resolving links --------------------------------------------------------------------

do
    eq(Sync.resolve("https://h.test/opds", "/opds/new"), "https://h.test/opds/new", "absolute path")
    eq(Sync.resolve("https://h.test/", "opds/new"), "https://h.test/opds/new", "relative to root")
    eq(Sync.resolve("https://h.test/a/b?x=1", "c"), "https://h.test/a/c", "relative to file")
    eq(Sync.resolve("https://h.test/a", "https://o.test/x"), "https://o.test/x", "full URL")
    eq(Sync.resolve("https://h.test", "x"), "https://h.test/x", "origin without slash")
end

-- Full sync -----------------------------------------------------------------------------

rmrf(TMP .. "/db")
mkdir(TMP .. "/db")

do
    local books = makeBooks(10)
    books[2].series, books[2].series_index = "Saga", 2
    books[5].series, books[5].series_index = "Saga", 1
    books[7].series, books[7].series_index = "Trilogy", 1
    local server = Server.new(books, 3)
    local store = Store.open(TMP .. "/db/a.sqlite3", false)

    local quick = newSync(store, server):quick()
    check(quick and quick.needs_full, "quick sync before any full sync asks for one")

    local r, err = newSync(store, server, 1000):full()
    check(r ~= nil, "full sync: " .. tostring(err))
    eq(r.total, 10, "all books stored")
    eq(r.added, 10, "all new")
    eq(r.deleted, 0, "nothing deleted")
    eq(r.in_series, 3, "series members")
    eq(store:count(), 10, "count")
    local b5 = store:getBook(books[5].uuid)
    eq(b5.series, "Saga", "series name")
    eq(b5.series_index, 1, "series position")
    eq(store:getBook(books[2].uuid).series_index, 2, "series order")
    eq(b5.pages, 105, "pages column")
    eq(b5.summary, "Summary 5", "summary stored")
    eq(b5.formats[1].href, "/opds/download/1005/epub/", "format href")
    eq(b5.calibre_id, 1005, "calibre id")
    eq(b5.published, 2005, "year")
    eq(#store:listing(), 10, "listing")
    check(store:listing()[1].summary == nil, "listing leaves summaries out")

    -- Endpoints are found once and remembered.
    local log_before = #server.log
    newSync(store, server, 1001):full()
    local root_hits = 0
    for i = log_before + 1, #server.log do
        if server.log[i] == ORIGIN .. "/" then root_hits = root_hits + 1 end
    end
    eq(root_hits, 0, "root feed not read again")

    -- Remove one, edit one, change series membership.
    table.remove(books, 3)
    books[1].title = "Book 01 (revised)"
    books[2].series = nil
    local r2 = newSync(store, server, 2000):full()
    eq(r2.deleted, 1, "removed book deleted")
    eq(r2.total, 9, "count after removal")
    eq(store:getBook(books[1].uuid).title, "Book 01 (revised)", "edit picked up")
    eq(store:getBook(books[2].uuid).series, nil, "series cleared")
    eq(store:getBook(books[4].uuid).series_index, 1, "remaining series member")

    -- A failure part-way deletes nothing.
    table.remove(books, 1)
    server.fail["offset=6"] = true
    local r3, err3 = newSync(store, server, 3000):full()
    check(r3 == nil and err3, "failed crawl reports an error")
    eq(store:count(), 9, "failed crawl deletes nothing")
    server.fail = {}

    -- Quick sync: nothing new costs two requests (the count, the newest page).
    newSync(store, server, 4000):full()
    local s = newSync(store, server)
    local q = s:quick()
    eq(q.added, 0, "quick: nothing new")
    check(not q.needs_full, "quick: no full sync needed")
    eq(s.requests, 2, "quick when counts match: count and newest page")

    -- One added and one removed: the count is unchanged, the newest page
    -- still shows the new book, and a full sync is asked for (the removal).
    local swap = makeBooks(20)[20]
    swap.added = 1750000000 -- newer than the books so far, older than ones added later
    local removed = table.remove(books, 1)
    table.insert(books, swap)
    local qs = newSync(store, server):quick()
    eq(qs.added, 1, "quick: new book found though the count is unchanged")
    check(store:has(swap.uuid), "new book stored")
    check(qs.needs_full, "quick: asks for a full sync to find the removal")
    local fs = newSync(store, server, 4500):full()
    eq(fs.deleted, 1, "full sync removes the other book")
    check(not store:has(removed.uuid), "removed book gone")

    -- New books arrive.
    local extra = makeBooks(14)
    for i = 11, 14 do
        extra[i].added = 1800000000 + i
        table.insert(books, extra[i])
    end
    local q2 = newSync(store, server):quick()
    eq(q2.added, 4, "quick: new books added")
    check(not q2.needs_full, "quick: counts match afterwards")
    check(store:has(extra[14].uuid), "newest book stored")

    -- A removal can't be seen by a quick sync.
    table.remove(books, 1)
    local q3 = newSync(store, server):quick()
    check(q3.needs_full, "quick: count mismatch asks for a full sync")
    store:close()

    -- Reopen.
    local again = Store.open(TMP .. "/db/a.sqlite3", false)
    eq(again:count(), #books + 1, "data persists")
    again:close()
end

-- Matching local files -------------------------------------------------------------------

local function writeEpub(path, opf_metadata)
    local Archiver = require("ffi/archiver")
    local w = Archiver.Writer:new()
    assert(w:open(path, "epub"), "can't write epub")
    w:addFileFromMemory("mimetype", "application/epub+zip")
    w:addFileFromMemory("META-INF/container.xml", [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]])
    w:addFileFromMemory("OEBPS/content.opf", [[<?xml version="1.0"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
]] .. opf_metadata .. [[
</metadata></package>]])
    w:close()
end

do
    local folder = TMP .. "/library"
    rmrf(folder)
    mkdir(folder)
    local catalog = {
        { id = "AAAAAAAA-0000-4000-8000-000000000001", title = "The First Book", authors = { "Jane Doe" } },
        { id = "00000000-0000-4000-8000-000000000002", title = "Second: A Story", authors = { "John Roe", "Ann Poe" } },
        { id = "00000000-0000-4000-8000-000000000003", title = "Unique Title", authors = { "Zed" } },
        { id = "00000000-0000-4000-8000-000000000004", title = "Twin", authors = { "One" } },
        { id = "00000000-0000-4000-8000-000000000005", title = "Twin", authors = { "Two" } },
        { id = "00000000-0000-4000-8000-000000000006", title = "Not Here", authors = { "Nobody" } },
    }
    -- 1: by UUID, though the EPUB's title differs.
    writeEpub(folder .. "/renamed.epub", [[
<dc:identifier opf:scheme="calibre" id="calibre_id">7</dc:identifier>
<dc:identifier opf:scheme="uuid" id="uuid_id">aaaaaaaa-0000-4000-8000-000000000001</dc:identifier>
<dc:title>Something Else</dc:title><dc:creator>X</dc:creator>]])
    -- 2: KOReader's OPDS file name, several authors, punctuation changed.
    local f = io.open(folder .. "/John Roe, Ann Poe - Second_ A Story.pdf", "w"); f:write("x"); f:close()
    -- 3: EPUB without UUID: title and author.
    writeEpub(folder .. "/u.epub", [[<dc:title>Unique Title</dc:title><dc:creator opf:role="aut">Zed</dc:creator>]])
    -- 4: "Twin" by author Two.
    f = io.open(folder .. "/Two - Twin.cbz", "w"); f:write("x"); f:close()
    -- Not in the catalog; and an ambiguous title with no author.
    f = io.open(folder .. "/Stranger.pdf", "w"); f:write("x"); f:close()
    f = io.open(folder .. "/Twin.pdf", "w"); f:write("x"); f:close()
    -- Not a book; hidden.
    f = io.open(folder .. "/notes.xyz", "w"); f:write("x"); f:close()
    f = io.open(folder .. "/.hidden.epub", "w"); f:write("x"); f:close()

    local store = Store.open(TMP .. "/db/m.sqlite3", false)
    eq(Matcher.scan(folder, store), 6, "scan reads every book file")
    eq(Matcher.scan(folder, store), 0, "unchanged files aren't read again")
    local matched, unmatched = Matcher.match(folder, store:localFiles(), catalog)
    eq(matched[catalog[1].id], folder .. "/renamed.epub", "matched by UUID")
    eq(matched[catalog[2].id], folder .. "/John Roe, Ann Poe - Second_ A Story.pdf", "matched by file name")
    eq(matched[catalog[3].id], folder .. "/u.epub", "matched by EPUB title and author")
    eq(matched[catalog[5].id], folder .. "/Two - Twin.cbz", "same title, right author")
    eq(matched[catalog[4].id], nil, "ambiguous title alone doesn't match")
    eq(matched[catalog[6].id], nil, "missing book not matched")
    eq(#unmatched, 2, "files not in the catalog")

    -- Unscanned files still match by name.
    local m2 = Matcher.match(folder, {}, catalog)
    eq(m2[catalog[2].id] ~= nil, true, "file name match without a scan")

    -- Changed and removed files.
    os.remove(folder .. "/Stranger.pdf")
    lfs.touch(folder .. "/u.epub", os.time() + 10, os.time() + 10)
    eq(Matcher.scan(folder, store), 1, "changed file read again")
    local files = store:localFiles()
    check(files[folder .. "/Stranger.pdf"] == nil, "removed file forgotten")
    store:close()
end

-- Store: upgrade from the phase 1 schema ---------------------------------------------------

do
    local SQ3 = require("lua-ljsqlite3/init")
    local path = TMP .. "/db/v1.sqlite3"
    os.remove(path)
    local conn = SQ3.open(path)
    conn:exec([[CREATE TABLE books (uuid TEXT PRIMARY KEY, calibre_id INTEGER, title TEXT,
        authors TEXT, tags TEXT, language TEXT, publisher TEXT, published INTEGER, added INTEGER,
        pages INTEGER, summary TEXT, formats TEXT, cover TEXT, size INTEGER, series TEXT,
        series_index REAL, seen INTEGER, series_seen INTEGER);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE local_files (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, uuids TEXT,
            title TEXT, authors TEXT);
        INSERT INTO books (uuid, title, cover, added) VALUES ('old-1', 'Kept', '/opds/cover/1', 5);
        INSERT INTO meta VALUES ('last_full_sync', '123');
        PRAGMA user_version=1;]])
    conn:close()
    local store = Store.open(path, false)
    eq(store:count(), 1, "upgrade keeps books")
    eq(store:getMeta("last_full_sync"), "123", "upgrade keeps sync state")
    store:setCover("old-1", "old-1.webp", 300, 450)
    local listing = store:listing()
    eq(listing[1].cover_file, "old-1.webp", "cover columns added")
    store:close()

    -- 2 -> 3 forgets cover failures (version 2 also recorded network errors).
    local conn2 = SQ3.open(path)
    conn2:exec("UPDATE books SET cover_file = NULL, cover_failed = 99; PRAGMA user_version=2;")
    conn2:close()
    local store3 = Store.open(path, false)
    eq(store3:listing()[1].cover_failed, nil, "old failure marks cleared")
    eq(store3:count(), 1, "books kept")
    store3:close()
end

-- Covers ------------------------------------------------------------------------------

do
    eq(Covers.imageType("RIFF\0\0\0\0WEBPVP8 xx"), "webp", "webp detected")
    eq(Covers.imageType("\255\216\255\224\0\16JFIF\0\1\1"), "jpg", "jpeg detected")
    eq(Covers.imageType("\137PNG\r\n\26\n\0\0\0\13"), "png", "png detected")
    eq(Covers.imageType("<html>Not found</html>"), nil, "html isn't an image")

    local Blitbuffer = require("ffi/blitbuffer")
    local png_path = TMP .. "/sample.png"
    local bb = Blitbuffer.new(30, 45, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_GRAY)
    bb:writePNG(png_path)
    bb:free()
    local f = io.open(png_path, "rb"); local png = f:read("*a"); f:close()

    local store = Store.open(TMP .. "/db/covers.sqlite3", false)
    local books = makeBooks(5)
    local server = Server.new(books, 10)
    newSync(store, server, 100):full()
    local with_cover, downloaded = store:coverCounts()
    eq(with_cover, 5, "books with a cover on the server")
    eq(downloaded, 0, "none downloaded yet")
    local missing = store:missingCovers(nil, 0)
    eq(#missing, 5, "all covers missing")
    eq(missing[1].id, books[5].uuid, "newest book first")
    eq(missing[1].href, "/opds/cover/1005", "cover link")

    local dir = TMP .. "/covers"
    rmrf(dir); mkdir(dir)
    local asked = {}
    local fetch = function(url)
        table.insert(asked, url)
        if url:find("/1001$") then return "<html>oops</html>" end
        if url:find("/1002$") then return nil, "404", "http" end
        return png
    end
    local r = Covers.download(fetch, ORIGIN .. "/", store, dir, store:missingCovers(nil, 0),
        { now = function() return 5000 end })
    eq(r.fetched, 3, "covers downloaded")
    eq(r.failed, 2, "bad responses counted as failed")
    eq(asked[1], ORIGIN .. "/opds/cover/1005", "cover URL resolved against the catalog")
    local res = r.results[books[5].uuid]
    check(res and res.w == 30 and res.h == 45, "image size recorded")
    check(lfs.attributes(dir .. "/" .. res.file, "mode") == "file", "cover file written")
    check(lfs.attributes(dir .. "/" .. res.file .. ".part") == nil, "no partial file left")
    eq(r.results[books[1].uuid], false, "html response failed")
    local _w, have = store:coverCounts()
    eq(have, 3, "store knows the downloaded covers")
    eq(#store:missingCovers(nil, 1000), 0, "failed covers aren't retried at once")
    eq(#store:missingCovers(nil, 6000), 2, "failed covers retried later")
    local l = {}
    for _i, b in ipairs(store:listing()) do l[b.id] = b end
    eq(l[books[5].uuid].cover_w, 30, "listing has the cover size")
    eq(l[books[1].uuid].cover_failed, 5000, "listing has the failure time")

    -- "Download all covers" retries covers that failed recently.
    local retry = Covers.downloadMissing(fetch, ORIGIN .. "/", store, dir,
        { now = function() return 5001 end, retry_all = true })
    eq(retry.fetched + retry.failed, 2, "retry_all includes recent failures")

    -- A lost network stops the batch without marking anything failed.
    store:setCoverFailed(books[1].uuid, nil)
    store:setCoverFailed(books[2].uuid, nil)
    local calls = 0
    local offline = Covers.download(function()
        calls = calls + 1
        return nil, "Network error: timeout", "network"
    end, ORIGIN .. "/", store, dir, store:missingCovers(nil, 0), { now = function() return 7000 end })
    eq(calls, 1, "batch stops at the first network error")
    eq(offline.failed, 0, "network errors aren't failures")
    check(offline.network_error ~= nil, "network error reported")
    eq(#store:missingCovers(nil, 0), 2, "covers still wanted after a network error")

    -- A deadline stops the batch.
    local t = 0
    local r2 = Covers.download(fetch, ORIGIN .. "/", store, dir, store:missingCovers(nil, 6000),
        { now = function() t = t + 1; return t end, deadline = 2 })
    eq(r2.fetched + r2.failed, 1, "deadline respected")

    -- Books gone from the catalog lose their cover file.
    local f2 = io.open(dir .. "/stray.webp", "w"); f2:write("x"); f2:close()
    table.remove(books, 5)
    newSync(store, server, 200):full()
    eq(Covers.cleanup(store, dir), 2, "unused cover files removed")
    check(lfs.attributes(dir .. "/" .. res.file) == nil, "removed book's cover deleted")
    store:close()

    -- Cover states.
    local can = true
    Virtual.canFetchCovers = function() return can end
    local ready = { id = "r", cover = png_path, cover_w = 30, cover_h = 45 }
    eq(Virtual.coverState(ready), "ready", "downloaded cover is ready")
    local unsized = { id = "u", cover = png_path }
    eq(Virtual.coverState(unsized), "ready", "cover size found by decoding")
    eq(unsized.cover_w, 30, "decoded size kept")
    local pending = { id = "p", cover_href = "/opds/cover/1" }
    eq(Virtual.coverState(pending), "pending", "cover can be downloaded")
    can = false
    eq(Virtual.coverState(pending), "none", "offline: no cover for now")
    can = true
    pending.cover_failed = 1
    eq(Virtual.coverState(pending), "none", "failed cover isn't asked for again")
    eq(Virtual.coverState({ id = "n" }), "none", "no cover on the server")
    Virtual.canFetchCovers = nil
end

-- Timings ------------------------------------------------------------------------------

do
    local Timing = require("cloudlibrary/timing")
    Timing.reset()
    check(Timing.text():find("No timings yet", 1, true), "empty timings")
    Timing.record("catalog: load", 120, "2154 books")
    Timing.record("catalog: load", 80)
    Timing.record("sync (full): network", 30500, "157 requests")
    local st = Timing.stats["catalog: load"]
    eq(st.count, 2, "timing count")
    eq(st.total, 200, "timing total")
    eq(st.max, 120, "timing max")
    eq(st.last, 80, "timing last")
    local text = Timing.text()
    check(text:find("CATALOG", 1, true) and text:find("SYNC (FULL)", 1, true), "grouped by step")
    check(text:find("load: 80.0 ms  (avg 100 ms, max 120 ms, 2×)", 1, true), "summary line: " .. text)
    check(text:find("network: 30.5 s", 1, true), "seconds for long steps")
    Timing.recordAll({ total = { ms = 5, note = "x" }, bad = "no" }, "covers (all): ")
    check(Timing.stats["covers (all): total"] and not Timing.stats["covers (all): bad"], "recordAll")
    local t0 = Timing.start()
    check(Timing.since(t0) >= 0, "clock runs forward")
    Timing.reset()

    -- Sync and cover results carry their timings.
    local store = Store.open(TMP .. "/db/timing.sqlite3", false)
    local server = Server.new(makeBooks(4), 2)
    local r = newSync(store, server):full()
    local t = r.timing
    check(t and t.total and t.network and t.parsing and t.database and t["books list"] and t.series,
        "full sync timings")
    check(t.total.note:find("requests", 1, true), "requests in the note")
    check(t.network.ms >= 0 and t.total.ms >= t.network.ms, "network time within the total")
    local q = newSync(store, server):quick()
    check(q.timing and q.timing.total, "quick sync timings")
    local png = io.open(TMP .. "/sample.png", "rb"):read("*a")
    local cr = Covers.download(function() return png end, ORIGIN .. "/", store, TMP .. "/covers",
        store:missingCovers(2, 0))
    check(cr.timing and cr.timing.network and cr.timing["reading images"] and cr.timing.saving,
        "cover download timings")
    check(cr.timing.total.note:find("2 covers", 1, true), "cover count in the note")
    store:close()
end

-- Downloads -----------------------------------------------------------------------------

do
    eq(Downloads.extension({ type = "application/epub+zip" }), "epub", "epub type")
    eq(Downloads.extension({ type = "application/pdf; charset=binary" }), "pdf", "type with parameters")
    eq(Downloads.extension({ type = "application/vnd.comicbook+zip" }), "cbz", "comic type")
    eq(Downloads.extension({ type = "application/x-mobi8-ebook" }), "azw3", "azw3 type")
    eq(Downloads.extension({ type = "application/octet-stream", href = "/opds/download/7/fb2/" }), "fb2",
        "format from a Calibre-Web link")
    eq(Downloads.extension({ href = "/files/book.DJVU" }), "djvu", "format from a file name")
    eq(Downloads.extension({ type = "application/x-unknown" }), nil, "unknown format")
    local choices = Downloads.choices({
        { type = "application/pdf", href = "/d/1/pdf/" },
        { type = "application/x-weird", href = "/opds/download/1/weird/" },
        { type = "application/epub+zip", href = "/d/1/epub/" },
        { type = "application/x-nothing" },
    })
    eq(#choices, 3, "formats with an extension")
    eq(choices[1].ext, "epub", "EPUB preferred")
    eq(choices[2].ext, "pdf", "then PDF")
    eq(choices[3].ext, "weird", "unknown formats last")

    local folder = TMP .. "/downloads"
    rmrf(folder); mkdir(folder)
    local book = { id = "d1", title = "Why: A \"Question\"?", authors = { "Ann One", "Bob Two" }, added = 1600000000 }
    local name = Downloads.fileName(book, "epub", folder)
    eq(name, "Ann One, Bob Two - Why_ A _Question__.epub", "KOReader-style name, unsafe characters replaced")
    local f = io.open(folder .. "/" .. name, "w"); f:write("x"); f:close()
    eq(Downloads.fileName(book, "epub", folder), "Ann One, Bob Two - Why_ A _Question__ (2).epub",
        "existing file not overwritten")
    eq(Downloads.fileName({ id = "x", title = "T" }, "pdf", folder), "T.pdf", "no author")

    local path = folder .. "/ok.epub"
    local r = Downloads.fetch(function(_url, part)
        local out = io.open(part, "wb"); out:write("book bytes"); out:close(); return true
    end, "https://x/1", path)
    check(r and r.path == path and r.size == 10, "downloaded and renamed")
    check(lfs.attributes(path .. ".part") == nil, "no partial file left")
    local r2, err2 = Downloads.fetch(function(_url, part)
        local out = io.open(part, "wb"); out:write("half"); out:close(); return nil, "timeout"
    end, "https://x/2", folder .. "/bad.epub")
    check(r2 == nil and err2 == "timeout", "failure reported")
    check(lfs.attributes(folder .. "/bad.epub") == nil and lfs.attributes(folder .. "/bad.epub.part") == nil,
        "failed download leaves nothing")
    local r3, err3 = Downloads.fetch(function(_url, part)
        io.open(part, "wb"):close(); return true
    end, "https://x/3", folder .. "/empty.epub")
    check(r3 == nil and err3:find("empty", 1, true), "empty file rejected")
    local r4 = Downloads.fetch(function(_url, part)
        local out = io.open(part, "wb"); out:write("y"); out:close(); return true
    end, "https://x/4", path)
    check(r4 == nil, "won't replace a file that appeared meanwhile")

    local attr = Downloads.finish(path, book)
    eq(attr.modification, 1600000000, "file dated when the book was added")
end

-- Search ----------------------------------------------------------------------------------

do
    local Search = require("cloudlibrary/search")
    local m = Search.matcher("cloud", false, false)
    check(m("The Cloud Atlas") and not m("Clout"), "plain, case-insensitive")
    check(not Search.matcher("cloud", true, false)("Cloud"), "case-sensitive")
    check(Search.matcher("c*d a?las", false, true)("cloud atlas"), "wildcards")
    check(not Search.matcher("a.c", false, true)("abc"), "a dot is a dot")
    check(Search.matcher("(", false, true)("x") == false, "bad pattern doesn't throw")
    check(Search.matcher("*", false, false)("anything"), "* matches everything")
    local books = {
        { id = "1", title = "Sharpe's Tiger", authors = { "Bernard Cornwell" }, series = "Sharpe" },
        { id = "2", title = "The Pagan Lord", authors = { "Bernard Cornwell" }, series = "The Saxon Stories" },
        { id = "3", title = "Security", authors = { "Poul Anderson" } },
    }
    eq(#Search.cloudMatches(books, "cornwell", false, false), 2, "match by author")
    eq(#Search.cloudMatches(books, "saxon", false, false), 1, "match by series")
    eq(#Search.cloudMatches(books, "tiger", false, false), 1, "match by title")
    eq(#Search.cloudMatches(books, "zzz", false, false), 0, "no match")
    check(Search.inScope("/mnt/onboard/Books", "/mnt/onboard/Books/", false), "same folder")
    check(Search.inScope("/mnt/onboard/Books", "/mnt/onboard", true), "folder below, with subfolders")
    check(not Search.inScope("/mnt/onboard/Books", "/mnt/onboard", false), "folder below, no subfolders")
    check(not Search.inScope("/mnt/onboard/Books", "/mnt/onboard/Bo", true), "prefix isn't a parent")
    check(Search.inScope("/x", "/", true), "root")
end

-- Badge ----------------------------------------------------------------------------------

do
    local Badge = require("cloudlibrary/badge")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local bb = Blitbuffer.new(400, 300, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_GRAY)
    local cover = { image = true, dimen = Geom:new{ x = 20, y = 10, w = 120, h = 180 } }
    local menu = { item_group = {
        { entry = { path = "/lib/local.epub" }, dimen = Geom:new{ x = 0, y = 0, w = 160, h = 200 }, { { cover } } },
        { entry = { path = "/lib/other.epub" }, dimen = Geom:new{ x = 200, y = 0, w = 160, h = 200 } },
    } }
    Badge.isOnDevice = function(path) return path == "/lib/local.epub" end
    Badge.enabled = true
    Badge.paintOn(menu, bb)
    local x, y, size = Badge.place(cover.dimen)
    check(x + size <= 140 and y + size <= 190 and x > 20, "badge inside the cover's corner")
    local function changed(x0, y0, w, h)
        for yy = y0, y0 + h - 1 do
            for xx = x0, x0 + w - 1 do
                if bb:getPixel(xx, yy):getColor8().a ~= Blitbuffer.COLOR_GRAY.a then return true end
            end
        end
        return false
    end
    check(changed(x, y, size, size), "badge drawn on the local book")
    check(not changed(200, 0, 160, 200), "no badge on a book not on the device")
    bb:fill(Blitbuffer.COLOR_GRAY)
    Badge.enabled = false
    Badge.paintOn(menu, bb)
    check(not changed(x, y, size, size), "badge can be turned off")
    Badge.enabled = true
    Badge.isOnDevice = nil
    bb:free()
end

-- Virtual entries ---------------------------------------------------------------------

do
    Virtual.setCatalog("/lib/", {
        { id = "x1", title = "One" }, { id = "x1", title = "One again" }, { id = "x2", title = "Two" },
        { title = "no id" },
    })
    eq(#Virtual.books, 2, "one entry per catalog book")
    eq(Virtual.folder, "/lib", "folder normalised")
    check(Virtual.isVirtual("/lib/cloud-x2.epub"), "virtual path")
end

io.stdout:write(string.format("cloudlibrary: %d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
