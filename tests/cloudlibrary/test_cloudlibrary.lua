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

-- ZenOS's book sources (common/book_sources.lua), which the plugin needs:
-- records what the plugin registers and reports.
local ZenOS = { sources = {}, changes = {}, integrated = 0 }
package.loaded["common/book_sources"] = {
    register = function(id, source) ZenOS.sources[id] = source return true end,
    changed = function(paths) table.insert(ZenOS.changes, paths or false) end,
    bookInfo = function() end,
    listingKey = function() end,
    installMetadataIntegration = function() ZenOS.integrated = ZenOS.integrated + 1 return true end,
}

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
    for _i, name in ipairs({ "badge", "covers", "downloads", "feed", "guard", "history", "http", "library", "matcher",
            "search", "store", "sync", "timing", "virtual", "zenos_source" }) do
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
    local cover = b.cover_href or ("/opds/cover/" .. b.id)
    table.insert(parts, '<link type="image/jpeg" href="' .. cover .. '" rel="http://opds-spec.org/image"/>')
    table.insert(parts, '<link type="image/jpeg" href="' .. cover .. '" rel="http://opds-spec.org/image/thumbnail"/>')
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

local function books_uuid(i) return string.format("00000000-0000-4000-8000-%012d", i) end

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

    -- A list with no books (an expired login, a restricted view) deletes nothing.
    do
        local kept = books
        server.books = {}
        local r_empty, err_empty = newSync(store, server, 2500):full()
        check(r_empty and r_empty.deleted == 0, "empty list: nothing deleted " .. tostring(err_empty))
        eq(store:count(), 9, "empty list: books kept")
        server.books = kept
    end

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
        { id = "333d496c-3946-448d-bb64-de3905aaaf83", title = "Rewritten", authors = { "Nagel" } },
    }
    -- 1: by UUID, though the EPUB's title differs.
    writeEpub(folder .. "/renamed.epub", [[
<dc:identifier opf:scheme="calibre" id="calibre_id">7</dc:identifier>
<dc:identifier opf:scheme="uuid" id="uuid_id">aaaaaaaa-0000-4000-8000-000000000001</dc:identifier>
<dc:title>Something Else</dc:title><dc:creator>X</dc:creator>]])
    -- 7: by UUID as Calibre 9 writes it ("uuid:..."), next to the package's
    -- own UUID; the EPUB's title differs.
    writeEpub(folder .. "/calibre9.epub", [[
<dc:identifier>calibre:4644</dc:identifier>
<dc:identifier>uuid:333D496C-3946-448D-BB64-DE3905AAAF83</dc:identifier>
<dc:identifier id="uuid_id">uuid:dd15c660-aec5-41ff-af25-8a01b8b592eb</dc:identifier>
<dc:title>Edited Elsewhere</dc:title><dc:creator>X</dc:creator>]])
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
    eq(Matcher.scan(folder, store), 7, "scan reads every book file")
    eq(Matcher.scan(folder, store), 0, "unchanged files aren't read again")
    local matched, unmatched, by_title = Matcher.match(folder, store:localFiles(), catalog)
    local scanned = store:localFiles()
    check(scanned[folder .. "/u.epub"].md5 and #scanned[folder .. "/u.epub"].md5 == 32
        and scanned[folder .. "/Stranger.pdf"].md5, "each file's partial MD5 kept")
    check(not by_title[catalog[1].id] and not by_title[catalog[7].id] and by_title[catalog[2].id]
        and by_title[catalog[3].id] and by_title[catalog[5].id], "which books matched by title")
    eq(matched[catalog[1].id], folder .. "/renamed.epub", "matched by UUID")
    eq(matched[catalog[7].id], folder .. "/calibre9.epub", "matched by uuid:-prefixed UUID")
    eq(matched[catalog[2].id], folder .. "/John Roe, Ann Poe - Second_ A Story.pdf", "matched by file name")
    eq(matched[catalog[3].id], folder .. "/u.epub", "matched by EPUB title and author")
    eq(matched[catalog[5].id], folder .. "/Two - Twin.cbz", "same title, right author")
    eq(matched[catalog[4].id], nil, "ambiguous title alone doesn't match")
    eq(matched[catalog[6].id], nil, "missing book not matched")
    eq(#unmatched, 2, "files not in the catalog")

    -- Title alone, only when the file doesn't name someone else.
    do
        local tf = TMP .. "/titles"
        os.execute("mkdir -p '" .. tf .. "'")
        local cat = {
            { id = "00000000-0000-4000-8000-0000000000d1", title = "Dune", authors = { "Frank Herbert" } },
            { id = "00000000-0000-4000-8000-0000000000d2", title = "Emma", authors = { "Jane Austen" } },
            { id = "00000000-0000-4000-8000-0000000000d3", title = "Ulysses", authors = { "James Joyce" } },
            { id = "00000000-0000-4000-8000-0000000000d4", title = "Nameless", authors = {} },
        }
        for _i, name in ipairs({ "Some Other Writer - Dune.pdf", "Emma.pdf", "Ann Editor, James Joyce - Ulysses.pdf",
                                 "Whoever - Nameless.pdf" }) do
            local tfile = io.open(tf .. "/" .. name, "w"); tfile:write("x"); tfile:close()
        end
        local tm, tun, tby = Matcher.match(tf, {}, cat)
        eq(tm[cat[1].id], nil, "title alone: not when the file names another author")
        eq(tm[cat[2].id], tf .. "/Emma.pdf", "title alone: a file naming no author")
        eq(tm[cat[3].id], tf .. "/Ann Editor, James Joyce - Ulysses.pdf", "title alone: the book's author among those named")
        eq(tm[cat[4].id], tf .. "/Whoever - Nameless.pdf", "title alone: a catalog book without an author")
        eq(#tun, 1, "the other author's file is left unmatched")
        check(tby[cat[2].id] and tby[cat[3].id], "matched by title")
    end
    -- Identifiers without the dc: prefix are read too.
    do
        local pf = TMP .. "/prefix"
        os.execute("mkdir -p '" .. pf .. "'")
        writeEpub(pf .. "/plain.epub", [[<identifier>urn:uuid:00000000-0000-4000-8000-0000000000e1</identifier>
<dc:title>Whatever</dc:title>]])
        local pstore = Store.open(TMP .. "/db/prefix.sqlite3", false)
        Matcher.scan(pf, pstore)
        local pm, _pu, pby = Matcher.match(pf, pstore:localFiles(),
            { { id = "00000000-0000-4000-8000-0000000000e1", title = "Catalog Title", authors = { "X" } } })
        check(pm["00000000-0000-4000-8000-0000000000e1"] == pf .. "/plain.epub"
            and not pby["00000000-0000-4000-8000-0000000000e1"], "an identifier without the dc: prefix matches by UUID")
        pstore:close()
    end

    -- A second copy of a matched book isn't a file missing from the catalog.
    do
        local cf = TMP .. "/copies"
        os.execute("mkdir -p '" .. cf .. "'")
        for _i, name in ipairs({ "Zed - Unique Title.pdf", "Zed - Unique Title.cbz", "Nobody - Nothing.pdf" }) do
            local cfile = io.open(cf .. "/" .. name, "w"); cfile:write("x"); cfile:close()
        end
        local cm, cun, _cby, ccopies = Matcher.match(cf, {}, catalog)
        local first = cm[catalog[3].id]
        local second = first == cf .. "/Zed - Unique Title.pdf" and cf .. "/Zed - Unique Title.cbz" or cf .. "/Zed - Unique Title.pdf"
        check(first ~= nil and ccopies[second] == catalog[3].id, "a second copy is known as the book's")
        eq(#cun, 1, "only the stranger is unmatched")
        eq(cun[1], cf .. "/Nobody - Nothing.pdf", "the stranger")
    end

    -- Unscanned files still match by name.
    local m2 = Matcher.match(folder, {}, catalog)
    eq(m2[catalog[2].id] ~= nil, true, "file name match without a scan")

    -- Changed and removed files.
    os.remove(folder .. "/Stranger.pdf")
    lfs.touch(folder .. "/u.epub", os.time() + 10, os.time() + 10)
    local read, removed = Matcher.scan(folder, store)
    eq(read, 1, "changed file read again")
    eq(removed, 1, "removed file counted")
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

    -- 3 -> 4 reads every file again (UUIDs written "uuid:..." were missed).
    local conn3 = SQ3.open(path)
    conn3:exec([[INSERT INTO local_files (path, mtime, size, uuids) VALUES ('/x.epub', 1, 2, NULL);
        PRAGMA user_version=3;]])
    conn3:close()
    local store4 = Store.open(path, false)
    eq(next(store4:localFiles()), nil, "scanned files forgotten")
    eq(store4:count(), 1, "books kept")
    store4:close()

    -- 4 -> 5 adds match keys, filled by fillMatchKeys().
    local conn4 = SQ3.open(path)
    conn4:exec([[CREATE TABLE b2 AS SELECT uuid, calibre_id, title, authors, tags, language, publisher,
            published, added, pages, summary, formats, cover, size, series, series_index, seen,
            series_seen, cover_file, cover_w, cover_h, cover_failed FROM books;
        DROP TABLE books; ALTER TABLE b2 RENAME TO books;
        UPDATE books SET title = 'The  Kept!', authors = 'Ann  Author' || char(10) || 'Bob';
        PRAGMA user_version=4;]])
    conn4:close()
    local store5 = Store.open(path, false)
    eq(store5:listing()[1].match_title, nil, "match key empty before filling")
    eq(store5:fillMatchKeys(), 1, "match keys filled")
    eq(store5:fillMatchKeys(), 0, "match keys filled once")
    local row = store5:listing()[1]
    eq(row.match_title, "the kept", "match title normalised")
    eq(row.match_author, "ann author", "match author normalised")
    eq(#row.authors, 2, "authors split when used")
    eq(row.authors[2], "Bob", "second author")
    eq(#row.tags, 0, "no tags: empty list")
    store5:close()

    -- 5 -> 6 adds cover_stale, keeping downloaded covers.
    local conn5 = SQ3.open(path)
    conn5:exec([[CREATE TABLE b2 AS SELECT uuid, calibre_id, title, authors, tags, language, publisher,
            published, added, pages, summary, formats, cover, size, series, series_index, seen,
            series_seen, cover_file, cover_w, cover_h, cover_failed, match_title, match_author FROM books;
        DROP TABLE books; ALTER TABLE b2 RENAME TO books;
        UPDATE books SET cover_file = 'ol/old-1.webp';
        PRAGMA user_version=5;]])
    conn5:close()
    local store6 = Store.open(path, false)
    eq(store6:count(), 1, "5 -> 6 keeps books")
    eq(store6:listing()[1].cover_file, "ol/old-1.webp", "5 -> 6 keeps covers")
    eq(store6:markCoversStale(), 1, "cover_stale column added")
    store6:setCover("old-1", "ol/old-1.webp", 1, 1, { etag = '"e"', checked = 0 })
    store6:markCoversStale({ "old-1" })
    eq(store6:missingCovers(nil, 0)[1].etag, '"e"', "6 -> 7: ETag columns added")
    store6:setLocalFile("/k.epub", { mtime = 1, size = 2, uuids = { "u" } })
    store6:close()

    -- 7 -> 8 adds local files' MD5; files without one are read again.
    local conn7 = SQ3.open(path)
    conn7:exec([[CREATE TABLE lf2 AS SELECT path, mtime, size, uuids, title, authors FROM local_files;
        DROP TABLE local_files; ALTER TABLE lf2 RENAME TO local_files; PRAGMA user_version=7;]])
    conn7:close()
    local store8 = Store.open(path, false)
    local kept = store8:localFiles()["/k.epub"]
    eq(kept and kept.md5, nil, "7 -> 8: files kept, no MD5 yet")
    store8:setLocalFile("/k.epub", { mtime = 1, size = 2, uuids = { "u" }, md5 = "abc" })
    eq(store8:localFiles()["/k.epub"].md5, "abc", "7 -> 8: MD5 column added")
    eq(store8:count(), 1, "7 -> 8 keeps books")
    store8:close()
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
    eq(res.file, books[5].uuid:sub(1, 2):lower() .. "/" .. books[5].uuid .. ".png",
        "cover in a subfolder named after the start of the UUID")
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

    -- "Download missing covers" retries covers that failed recently.
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

    -- A new cover link makes the cover missing again; unchanged ones are kept.
    books[5].cover_href = "/opds/cover/1005?v=2"
    newSync(store, server, 150):full()
    local l2 = {}
    for _i, b in ipairs(store:listing()) do l2[b.id] = b end
    eq(l2[books[5].uuid].cover_file, nil, "changed cover link forgets the file")
    eq(l2[books[5].uuid].cover_w, nil, "changed cover link forgets the size")
    eq(l2[books[4].uuid].cover_file ~= nil, true, "unchanged cover kept")
    local again = store:missingCovers(nil, 0)
    local wanted = false
    for _i, m in ipairs(again) do
        if m.id == books[5].uuid then wanted = m.href == "/opds/cover/1005?v=2" end
    end
    check(wanted, "changed cover downloaded again, from the new link")

    -- Calibre-Web keeps the link (/opds/cover/<id>) but a new cover rewrites
    -- the book: a changed file size downloads the cover again, keeping the
    -- old file until then.
    local function row(id)
        for _i, b in ipairs(store:listing()) do
            if b.id == id then return b end
        end
    end
    local old_file = row(books[4].uuid).cover_file
    check(old_file ~= nil, "book 4 has a cover")
    eq(row(books[4].uuid).cover_stale, nil, "not stale before")
    newSync(store, server, 160):full()
    eq(row(books[4].uuid).cover_stale, nil, "same size: not stale")
    books[4].size = 2222
    newSync(store, server, 170):full()
    eq(row(books[4].uuid).cover_stale, true, "changed size: stale")
    eq(row(books[4].uuid).cover_file, old_file, "old cover kept until the new one arrives")
    local stale_wanted = false
    for _i, m in ipairs(store:missingCovers(nil, 0)) do
        if m.id == books[4].uuid then stale_wanted = true end
    end
    check(stale_wanted, "stale cover downloaded again")
    local _wc, have_before = store:coverCounts()
    newSync(store, server, 175):full()
    eq(row(books[4].uuid).cover_stale, true, "still stale on the next sync")
    Covers.download(function() return png end, ORIGIN .. "/", store, dir,
        { { id = books[4].uuid, href = "/opds/cover/1004" } }, { now = function() return 8000 end })
    eq(row(books[4].uuid).cover_stale, nil, "downloaded: not stale")
    local _wc2, have_after = store:coverCounts()
    eq(have_after, have_before, "refetch doesn't change the cover count")
    -- "Refresh all covers" and a download mark covers stale.
    eq(store:markCoversStale({ books[4].uuid, "no-such-book" }), 1, "one book marked")
    eq(row(books[4].uuid).cover_stale, true, "marked stale")
    eq(row(books[3].uuid).cover_stale, nil, "others untouched")
    check(store:markCoversStale() >= 2, "all downloaded covers marked")
    eq(row(books[5].uuid).cover_stale, nil, "books without a cover file not marked")

    -- Stale covers are asked for with their ETag / Last-Modified: a changed
    -- cover keeps its link and the catalog doesn't say it changed.
    do
        local cstore = Store.open(TMP .. "/db/check.sqlite3", false)
        local cbooks = makeBooks(3)
        newSync(cstore, Server.new(cbooks, 10), 100):full()
        local cdir = TMP .. "/covers-check"
        rmrf(cdir); mkdir(cdir)
        local etags, sent = {}, {}
        local cfetch = function(url, headers)
            local id = url:match("/(%d+)$")
            sent[id] = headers or false
            local tag = etags[id] or '"v1"'
            if headers and headers["If-None-Match"] == tag then return nil, "not modified", "not_modified" end
            return png, nil, nil, { etag = tag, ["last-modified"] = "Mon, 09 Nov 2026 03:29:15 GMT" }
        end
        local t = 1000
        local clock = function() return t end
        local first = Covers.download(cfetch, ORIGIN .. "/", cstore, cdir, cstore:missingCovers(nil, 0), { now = clock })
        eq(first.fetched, 3, "check: covers downloaded")
        eq(sent["1001"], false, "first download isn't conditional")
        eq(#cstore:missingCovers(nil, 0), 0, "downloaded: nothing missing")

        -- "Refresh all covers", with one cover changed on the server.
        etags["1002"] = '"v2"'
        eq(cstore:markCoversStale(), 3, "all marked stale")
        local stale = cstore:missingCovers(nil, 0)
        eq(#stale, 3, "stale covers wanted")
        eq(stale[1].etag, '"v1"', "stale covers carry their ETag")
        eq(stale[1].modified, "Mon, 09 Nov 2026 03:29:15 GMT", "and Last-Modified")
        t = 5000
        local rr = Covers.downloadMissing(cfetch, ORIGIN .. "/", cstore, cdir, { now = clock, limit = 10 })
        eq(sent["1001"]["If-None-Match"], '"v1"', "conditional request with the ETag")
        eq(sent["1001"]["If-Modified-Since"], "Mon, 09 Nov 2026 03:29:15 GMT", "and Last-Modified")
        eq(rr.unchanged, 2, "refresh: unchanged covers")
        eq(rr.fetched, 1, "refresh: changed cover downloaded")
        eq(rr.failed, 0, "refresh: nothing failed")
        eq(#cstore:missingCovers(nil, 0), 0, "refresh: no longer stale")
        eq(rr.more, false, "refresh: done")
        cstore:markCoversStale({ cbooks[2].uuid })
        eq(cstore:missingCovers(nil, 0)[1].etag, '"v2"', "new ETag recorded")
        local _wc, have = cstore:coverCounts()
        eq(have, 3, "covers still counted")

        -- After a sync, prefetch doesn't check kept covers.
        cstore:setCoverUnchanged(cbooks[2].uuid, t)
        sent = {}
        etags["1003"] = '"v3"'
        local p = Covers.prefetch(cfetch, ORIGIN .. "/", cstore, cdir, { now = clock, limit = 10 })
        eq(p.fetched + p.unchanged, 0, "prefetch: kept covers left alone")
        eq(next(sent), nil, "prefetch: nothing asked for")

        -- A network error stops the refresh, leaving the covers stale.
        cstore:markCoversStale()
        t = 7000
        local off = Covers.downloadMissing(function() return nil, "timeout", "network" end, ORIGIN .. "/",
            cstore, cdir, { now = clock, limit = 10 })
        check(off.network_error ~= nil, "refresh: network error reported")
        eq(#cstore:missingCovers(nil, 0), 3, "refresh: still stale after a network error")
        cstore:close()
    end

    -- Books gone from the catalog lose their cover file.
    local f2 = io.open(dir .. "/stray.webp", "w"); f2:write("x"); f2:close()
    table.remove(books, 5)
    newSync(store, server, 200):full()
    eq(Covers.cleanup(store, dir), 2, "unused cover files removed")
    check(lfs.attributes(dir .. "/" .. res.file) == nil, "removed book's cover deleted")

    -- Covers saved before subfolders are moved into them.
    local flat = books[4].uuid .. ".png"
    local nested = Covers.fileFor(books[4].uuid, "png")
    os.rename(dir .. "/" .. nested, dir .. "/" .. flat)
    store:moveCoverFile(nested, flat)
    local removed, moved = Covers.cleanup(store, dir)
    eq(removed, 0, "nothing removed when moving")
    eq(moved, 1, "flat cover moved")
    check(lfs.attributes(dir .. "/" .. nested, "mode") == "file", "cover now in its subfolder")
    check(lfs.attributes(dir .. "/" .. flat) == nil, "flat file gone")
    eq(store:coverFiles()[nested], true, "store points at the moved file")
    eq(Covers.fileFor("..x", "png"), "_/..x.png", "odd ids go in a catch-all subfolder")
    store:close()

    -- A first sync backfills every cover, a batch at a time.
    local bstore = Store.open(TMP .. "/db/backfill.sqlite3", false)
    newSync(bstore, Server.new(makeBooks(7), 10), 100):full()
    local bdir = TMP .. "/covers-backfill"
    rmrf(bdir); mkdir(bdir)
    local good = function() return png end
    local clock = function() return 9000 end
    local b1 = Covers.prefetch(good, ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock })
    check(b1.backfill and b1.more, "first prefetch backfills and asks for more")
    eq(b1.fetched, 3, "first batch")
    local lost = Covers.prefetch(function() return nil, "timeout", "network" end,
        ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock })
    check(lost.backfill and not lost.more, "lost network stops the chain")
    eq(bstore:getMeta("covers_backfill"), "1", "backfilling resumes after the next sync")
    local b2 = Covers.prefetch(good, ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock })
    check(b2.backfill and b2.more, "resumed with most covers already downloaded")
    local b3 = Covers.prefetch(good, ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock })
    eq(b3.fetched, 1, "last batch")
    check(b3.backfill_done and not b3.more, "backfill finished")
    eq(bstore:getMeta("covers_backfill"), nil, "backfill flag cleared")
    -- Later syncs: a few new books get one batch, no backfill.
    newSync(bstore, Server.new(makeBooks(9), 10), 200):full()
    local later = Covers.prefetch(good, ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock })
    check(not later.backfill and not later.more, "no backfill when most covers are here")
    eq(later.fetched, 2, "new books' covers fetched")

    -- A job that dies leaves the cover it was on; it's then skipped.
    newSync(bstore, Server.new(makeBooks(12), 10), 300):full()
    local died = pcall(Covers.downloadMissing, function(url)
        if url:find("/1011$") then error("decoder crash") end
        return png
    end, ORIGIN .. "/", bstore, bdir, { limit = 3, now = clock, track = true })
    check(not died, "simulated crash")
    eq(bstore:getMeta(Covers.PROGRESS_KEY), books_uuid(11), "cover being worked on recorded")
    eq(Covers.recoverCrash(bstore, 9500), books_uuid(11), "crashed cover found")
    eq(bstore:getMeta(Covers.PROGRESS_KEY), nil, "progress cleared")
    -- "Download missing covers" batches skip covers that failed during it
    -- (books 12 done, 11 crashed, 10 left).
    local m1 = Covers.downloadMissing(good, ORIGIN .. "/", bstore, bdir,
        { limit = 1, now = clock, retry_before = 9400, track = true })
    check(m1.fetched == 1 and not m1.more, "crashed cover left out of the run")
    bstore:setCover(books_uuid(10), nil, nil, nil)
    local m2 = Covers.downloadMissing(good, ORIGIN .. "/", bstore, bdir,
        { limit = 1, now = clock, retry_before = 9400, track = true })
    check(m2.fetched == 1 and not m2.left, "batch then finds nothing left")
    local m3 = Covers.downloadMissing(good, ORIGIN .. "/", bstore, bdir,
        { limit = 1, now = clock, retry_before = 9600, track = true })
    eq(m3.fetched, 1, "a later run retries the crashed cover")
    eq(bstore:getMeta(Covers.PROGRESS_KEY), nil, "finished batch leaves no progress mark")
    bstore:close()

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
    -- A KEPUB gets a name KOReader opens.
    eq(Downloads.fileName({ id = "x", title = "K" }, "kepub", folder), "K.kepub.epub", "kepub name")
    local kf = io.open(folder .. "/K.kepub.epub", "w"); kf:write("x"); kf:close()
    eq(Downloads.fileName({ id = "x", title = "K" }, "kepub", folder), "K (2).kepub.epub", "second kepub name")
    os.remove(folder .. "/K.kepub.epub")
    do
        local Http = require("cloudlibrary/http")
        eq(Http.auth({ username = "ann", password = "p%41ss" }), "Basic " .. require("mime").b64("ann:p%41ss"),
            "password with % sent as typed")
        eq(Http.auth({ username = "" }), nil, "no header without a user name")
    end

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
    Badge.isCloud = function(path) return path == "/lib/cloud-x.epub" end
    check(Badge.cloud_enabled and not Badge.local_enabled, "defaults: cloud badge on, local badge off")
    Badge.local_enabled = true
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
    Badge.local_enabled = false
    Badge.paintOn(menu, bb)
    check(not changed(x, y, size, size), "local badge can be turned off")

    -- Cloud badge: drawn on cloud-only books, with the plugin's icon.
    menu.item_group[2].entry.path = "/lib/cloud-x.epub"
    check(Badge.kind("/lib/cloud-x.epub") == "cloud" and Badge.kind("/lib/local.epub") == nil, "badge kinds")
    Badge.paintOn(menu, bb)
    local cx, cy, csize = Badge.place(menu.item_group[2].dimen)
    check(changed(cx, cy, csize, csize), "cloud badge drawn on the cloud book")
    check(not changed(x, y, size, size), "no cloud badge on the local book")
    local inner = {}
    for yy = cy + math.floor(csize / 4), cy + math.floor(csize * 3 / 4) do
        for xx = cx + math.floor(csize / 4), cx + math.floor(csize * 3 / 4) do
            if bb:getPixel(xx, yy):getColor8().a < 128 then table.insert(inner, 1) end
        end
    end
    check(#inner > 10, "cloud icon loaded (dark pixels inside the badge)")
    bb:fill(Blitbuffer.COLOR_GRAY)
    Badge.cloud_enabled = false
    Badge.paintOn(menu, bb)
    check(not changed(cx, cy, csize, csize), "cloud badge can be turned off")
    Badge.cloud_enabled = true

    -- Plain list rows (no cover): room is made before the name, and the
    -- badge drawn there.
    local item = { path = "/lib/cloud-x.epub" }
    Badge.decorate(item)
    local _size, slot = Badge.plainSize()
    check(item.indent == slot, "plain row: room made for the cloud badge")
    local other = { path = "/lib/local.epub" }
    Badge.decorate(other)
    check(other.indent == nil, "plain row: no room for a book without a badge")
    bb:fill(Blitbuffer.COLOR_GRAY)
    local row = { entry = item, dimen = Geom:new{ x = 0, y = 220, w = 400, h = 60 },
        _underline_container = { dimen = Geom:new{ x = 50, y = 220, w = 300, h = 60 } } }
    Badge.paintOn({ item_group = { row } }, bb)
    check(changed(50, 230, 40, 40), "plain row: badge drawn before the name")
    check(not changed(300, 220, 100, 60), "plain row: nothing on the row's right")
    bb:fill(Blitbuffer.COLOR_GRAY)
    item.indent = nil
    Badge.paintOn({ item_group = { row } }, bb)
    check(not changed(0, 220, 400, 60), "plain row without room: no badge")

    -- Not-in-catalog badge: off by default, its own icon.
    check(not Badge.noncloud_enabled, "default: not-in-catalog badge off")
    Badge.isNonCloud = function(path) return path == "/lib/mine.epub" end
    check(Badge.kind("/lib/mine.epub") == nil, "no not-in-catalog badge while off")
    Badge.noncloud_enabled = true
    check(Badge.kind("/lib/mine.epub") == "noncloud", "not-in-catalog badge kind")
    bb:fill(Blitbuffer.COLOR_GRAY)
    menu.item_group[2].entry.path = "/lib/mine.epub"
    Badge.paintOn(menu, bb)
    local dark = 0
    for yy = cy + math.floor(csize / 4), cy + math.floor(csize * 3 / 4) do
        for xx = cx + math.floor(csize / 4), cx + math.floor(csize * 3 / 4) do
            if bb:getPixel(xx, yy):getColor8().a < 128 then dark = dark + 1 end
        end
    end
    check(dark > 10, "crossed-out cloud icon drawn")

    -- Cloud books Concordance knows a status for: the cloud with a mark cut out.
    Badge.noncloud_enabled = false
    menu.item_group[2].entry.path = "/lib/cloud-x.epub"
    local state
    Badge.cloudState = function(path) return path == "/lib/cloud-x.epub" and state or nil end
    local function light()
        bb:fill(Blitbuffer.COLOR_GRAY)
        Badge.paintOn(menu, bb)
        local n = 0
        for yy = cy + math.floor(csize * 0.4), cy + math.floor(csize * 0.75) do
            for xx = cx + math.floor(csize * 0.35), cx + math.floor(csize * 0.65) do
                if bb:getPixel(xx, yy):getColor8().a > 200 then n = n + 1 end
            end
        end
        return n
    end
    local plain = light()
    for status, kind in pairs({ complete = "cloud-complete", reading = "cloud-reading", abandoned = "cloud-abandoned" }) do
        state = status
        check(Badge.kind("/lib/cloud-x.epub") == kind, "badge kind for " .. status)
        check(light() > plain + 3, "mark cut out of the cloud for " .. status)
    end
    state = "something else"
    check(Badge.kind("/lib/cloud-x.epub") == "cloud", "unknown status: plain cloud")
    Badge.cloudState = nil

    -- ZenOS Home covers (cover_common.make_cover_widget): badged when built
    -- for Home, painted after the cover.
    Badge.noncloud_enabled = false
    local painted = 0
    local covers = { make_cover_widget = function(book, w, h)
        local frame = { getSize = function() return { w = w, h = h } end }
        function frame:paintTo(target) painted = painted + 1 target:paintRect(0, 0, 1, 1, Blitbuffer.COLOR_GRAY) end
        return frame, w, h, false
    end }
    package.loaded["modules/filebrowser/patches/home/widgets/cover_common"] = covers
    check(Badge.installHome(), "Home badges installed")
    local function build(chunkname, path)
        return assert(loadstring("local covers, book = ... local f, w, h, n = covers.make_cover_widget(book, 120, 180)"
            .. " return f, w, h, n",
            chunkname))(covers, { path = path })
    end
    local home_frame, fw, fh, hyd = build("@/zen/modules/filebrowser/patches/home/widgets/strip_common.lua",
        "/lib/cloud-x.epub")
    check(fw == 120 and fh == 180 and hyd == false, "ZenOS's results passed on")
    bb:fill(Blitbuffer.COLOR_GRAY)
    home_frame:paintTo(bb, 20, 10)
    check(painted == 1, "cover painted first")
    check(changed(x, y, size, size), "cloud badge on a Home cover")
    local browser_frame = build("@/zen/modules/filebrowser/patches/zen_renderer.lua", "/lib/cloud-x.epub")
    bb:fill(Blitbuffer.COLOR_GRAY)
    browser_frame:paintTo(bb, 20, 10)
    check(not changed(x, y, size, size), "file browser covers left to the list badges (no double badge)")
    local other_frame = build("@/zen/modules/filebrowser/patches/home/widgets/featured_common.lua", "/lib/other.epub")
    bb:fill(Blitbuffer.COLOR_GRAY)
    other_frame:paintTo(bb, 20, 10)
    check(not changed(x, y, size, size), "no badge on a Home book without one")
    Badge.cloud_enabled = false
    bb:fill(Blitbuffer.COLOR_GRAY)
    home_frame:paintTo(bb, 20, 10)
    check(not changed(x, y, size, size), "Home badge follows the setting at paint time")
    Badge.cloud_enabled = true
    package.loaded["modules/filebrowser/patches/home/widgets/cover_common"] = nil
    Badge.noncloud_enabled, Badge.isNonCloud = false, nil

    Badge.cloud_enabled, Badge.local_enabled = true, false
    Badge.isOnDevice, Badge.isCloud = nil, nil
    bb:free()
end

-- Guard -------------------------------------------------------------------------------------

do
    local Guard = require("cloudlibrary/guard")
    local function reset()
        Guard.failed, Guard.unavailable, Guard.on_failure, Guard.notified = {}, {}, {}, false
    end
    reset()

    -- A working hook, keeping nils in its results.
    local target = { f = function(_self, a) return nil, a, nil end }
    Guard.hook("search", target, "f", function(orig, self, a) return orig(self, a .. "!") end)
    local r1, r2, r3 = target:f("x")
    check(r1 == nil and r2 == "x!" and r3 == nil, "hook result kept")
    check(select("#", target:f("x")) == 3, "hook keeps every return value")

    -- The plugin's code fails: the original runs, the feature turns off once.
    local turned_off = 0
    Guard.on_failure.search = function() turned_off = turned_off + 1 end
    local calls = 0
    local t2 = { f = function(_self, a) calls = calls + 1; return "orig " .. a end }
    Guard.hook("search", t2, "f", function(_orig, _self, _a) error("plugin bug") end)
    eq(t2:f("a"), "orig a", "original used after a plugin error")
    check(Guard.failed.search ~= nil and Guard.failed.search:find("plugin bug", 1, true), "error recorded")
    check(not Guard.ok("search"), "feature off")
    eq(turned_off, 1, "turned off once")
    eq(t2:f("b"), "orig b", "later calls go straight to the original")
    eq(calls, 2, "original not called twice for one call afterwards")
    check(Guard.ok("badge"), "other features unaffected")

    -- The plugin's code fails after the original ran: the original isn't
    -- run again (a delete, or opening a book, would happen twice).
    reset()
    local ran = 0
    local t5 = { f = function(_self, a) ran = ran + 1; return nil, "done " .. a end }
    Guard.hook("search", t5, "f", function(orig, self, a) orig(self, a); error("late plugin bug") end)
    local l1, l2 = t5:f("a")
    check(l1 == nil and l2 == "done a", "original's results kept after a late plugin error")
    eq(ran, 1, "original run once")
    check(not Guard.ok("search"), "feature off after a late plugin error")

    -- The original fails: its error passes through, nothing turns off.
    reset()
    local t3 = { f = function() error("koreader bug") end }
    Guard.hook("badge", t3, "f", function(orig, self) return orig(self) end)
    local ok3, err3 = pcall(t3.f, t3)
    check(not ok3 and tostring(err3):find("koreader bug", 1, true), "original's error passed through")
    check(Guard.ok("badge"), "not blamed on the plugin")

    -- Missing function: reported, nothing hooked.
    reset()
    check(Guard.hook("badge", {}, "nope", function() end) == nil, "nothing to hook")
    check(Guard.unavailable.badge ~= nil, "missing function reported")

    -- Library failure turns everything off; setCatalog then shows nothing.
    reset()
    local t4 = { f = function() return 1 end }
    Guard.hook("library", t4, "f", function() error("boom") end)
    t4:f()
    check(not Guard.ok("library") and not Guard.ok("search") and not Guard.ok("badge"),
        "library failure turns off search and badge too")
    Virtual.setCatalog("/lib", { { id = "a", title = "A" } })
    eq(#Virtual.books, 0, "no cloud books once the library is off")

    -- Background tasks: errors reported, tasks keep running.
    reset()
    eq(Guard.call("jobs", function(a, b) return a + b end, 2, 3), 5, "protected call result")
    eq(Guard.call("jobs", function() error("job bug") end), nil, "protected call error")
    check(Guard.failed.jobs ~= nil, "job error recorded")
    eq(Guard.call("jobs", function() return "again" end), "again", "jobs still run after an error")
    check(Guard.ok("library"), "a job error doesn't turn the library off")
    check(Guard.statusText():find("jobs error", 1, true), "job error in status")

    -- Menu and button callbacks, nested.
    reset()
    local ran = {}
    local menu = Guard.wrapCallbacks({ {
        text = "top",
        sub_item_table_func = function()
            return { { text = "inner", callback = function() ran.inner = true; error("menu bug") end } }
        end,
    }, { text = "plain", callback = function() ran.plain = true end } })
    menu[2].callback()
    local sub = menu[1].sub_item_table_func()
    local okm = pcall(sub[1].callback)
    check(ran.plain and ran.inner and okm, "menu callbacks run, errors contained")
    local rows = Guard.wrapCallbacks({ { { text = "b", callback = function() error("button bug") end } } })
    check(pcall(rows[1][1].callback), "button callback errors contained")

    -- Startup check against this KOReader.
    reset()
    check(Guard.check(), "startup check passes: " .. Guard.statusText())
    eq(Guard.statusText(), "", "no problems on this KOReader")
    local FileChooser = require("ui/widget/filechooser")
    local real = FileChooser.getListItem
    FileChooser.getListItem = function(_self) end
    check(not Guard.check(), "startup check notices a changed function")
    check(Guard.statusText():find("getListItem takes 1 parameters, expected 6", 1, true),
        "problem described: " .. Guard.statusText())
    FileChooser.getListItem = real
    local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    local real_show = FileSearcher.onShowSearchResults
    FileSearcher.onShowSearchResults = nil
    check(Guard.check(), "search missing doesn't stop the library")
    check(Guard.unavailable.search ~= nil and not Guard.ok("search"), "search not started")
    FileSearcher.onShowSearchResults = real_show
    local zen = package.loaded["common/book_sources"]
    package.loaded["common/book_sources"] = nil
    local real_path = package.path
    package.path = REPO .. "/cloudlibrary.koplugin/?.lua"
    check(not Guard.check() and Guard.zenos_missing, "no ZenOS: library not started")
    check(Guard.statusText():find("needs ZenOS", 1, true), "missing ZenOS described: " .. Guard.statusText())
    package.path = real_path
    package.loaded["common/book_sources"] = zen
    check(Guard.check() and not Guard.zenos_missing, "ZenOS back")
    reset()
end

-- Settings: their own file, moved from settings.reader.lua ----------------------------

do
    local Settings = require("cloudlibrary/settings")
    local Library = require("cloudlibrary/library")
    local Updater = require("cloudlibrary/updater")
    os.remove(Settings.path())
    Settings.reset()
    G_reader_settings:saveSetting("cloudlibrary", { folder = "/books", badge_local = true, show = false })
    G_reader_settings:saveSetting("cloudlibrary_updates", { mode = "install", last_check = 123 })
    eq(Library.settings().folder, "/books", "plugin settings moved")
    eq(Library.settings().show, false, "false values moved")
    eq(Updater.getMode(), "install", "updater mode moved")
    eq(Updater.getSettings().last_check, 123, "updater state moved")
    eq(G_reader_settings:readSetting("cloudlibrary"), nil, "removed from settings.reader.lua")
    eq(G_reader_settings:readSetting("cloudlibrary_updates"), nil, "updater key removed too")
    check(lfs.attributes(Settings.path(), "mode") == "file", "settings file written: " .. Settings.path())

    Library.save("search", false)
    Updater.setMode("off")
    Settings.reset()
    eq(Library.settings().search, false, "saved setting read back from the file")
    eq(Library.settings().folder, "/books", "moved setting kept in the file")
    eq(Updater.getMode(), "off", "updater mode read back from the file")

    -- A copy written by an older version again: moved over the file's.
    G_reader_settings:saveSetting("cloudlibrary", { folder = "/other" })
    Settings.reset()
    eq(Library.settings().folder, "/other", "older copy moved again")
    eq(Library.settings().search, false, "other keys kept")
    eq(G_reader_settings:readSetting("cloudlibrary"), nil, "older copy removed")

    os.remove(Settings.path())
    Settings.reset()
end

-- Deleting a downloaded book makes it a cloud book again -------------------------------

do
    local Library = require("cloudlibrary/library")
    local Search = require("cloudlibrary/search")
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    local folder = TMP .. "/deleted"
    lfs.mkdir(folder)
    local server = { url = "http://test.invalid/opds", username = "u" }
    local real_server, real_tick = Library.server, UIManager.nextTick
    Library.server = function() return server end
    UIManager.nextTick = function(_self, fn) fn() end
    Library.save("folder", folder)
    Library.save("auto_sync", false)
    eq(Library.quickSyncMode(), "never", "old automatic sync off: no quick syncs")
    eq(Library.fullSyncMode(), "never", "old automatic sync off: no full syncs")
    Library.save("quick_sync", "3h")
    Library.save("full_sync", "bogus")
    eq(Library.quickSyncMode(), "3h", "quick sync schedule")
    eq(Library.fullSyncMode(), "never", "unknown full sync schedule ignored")
    Library.save("quick_sync", "never")
    Library.save("full_sync", nil)
    local store = Store.open(Library.dbPath(server), false)
    store:upsertBooks({
        { uuid = "del-1", title = "Kept Book", authors = { "Ann Author" } },
        { uuid = "del-2", title = "Other Book", authors = { "Bo Writer" } },
    }, 1)
    store:close()
    local path = folder .. "/Ann Author - Kept Book.epub"
    local f = io.open(path, "w"); f:write("x"); f:close()
    local cloud_path = folder .. "/cloud-del-1.epub"

    Search.install(Virtual)
    Library.installDeleteHooks()
    Library.load()
    check(not Virtual.isVirtual(cloud_path), "downloaded book isn't a cloud book")
    eq(#Virtual.books, 1, "one cloud book before deleting")

    -- Results shown before the delete, as KOReader caches them.
    local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    FileSearcher.search_path, FileSearcher.search_string = folder, "book"
    local fc = {
        getCollate = function() return nil end,
        getListItem = function(_self, _dir, _name, item_path) return { path = item_path } end,
        genItemTable = function(_self, _dirs, files) return files end,
    }
    local searcher = { include_subfolders = true, ui = { file_chooser = fc } }
    local results = Search.augment(searcher, {})
    eq(#results, 1, "search before deleting: the other cloud book")

    check(FileManager.deleteFile(FileManager, path, true), "file deleted")
    check(Virtual.isVirtual(cloud_path), "deleted book is a cloud book again")
    eq(#Virtual.books, 2, "two cloud books after deleting")
    eq(#Search.augment(searcher, results), 2, "cached search results get it too")
    eq(#Search.augment(searcher, {}), 2, "new search finds it")

    -- The cloud entry is back as soon as the delete returns (the caller
    -- redraws then), before the reload; the reload then changes nothing.
    f = io.open(path, "w"); f:write("x"); f:close()
    Library.load()
    check(not Virtual.isVirtual(cloud_path), "downloaded again")
    local ticks = {}
    UIManager.nextTick = function(_self, fn) table.insert(ticks, fn) end
    check(FileManager.deleteFile(FileManager, path, true), "deleted again")
    check(Virtual.isVirtual(cloud_path), "cloud entry back before the reload")
    eq(#ticks, 1, "reload still scheduled")
    local sig = Virtual.catalog_sig
    local refreshed, real_refresh = 0, Virtual.refresh
    Virtual.refresh = function() refreshed = refreshed + 1 end
    local i = 1
    while ticks[i] do ticks[i]() i = i + 1 end -- runs ticks they schedule too
    eq(Virtual.catalog_sig, sig, "reload finds the same cloud books")
    eq(refreshed, 1, "folder redrawn once more after the delete's own redraw")
    eq(#ticks, 2, "that redraw comes after the reload")

    -- Several at once: entries back before deleteSelectedFiles redraws;
    -- files it couldn't delete keep their own entry.
    f = io.open(path, "w"); f:write("x"); f:close()
    local stuck = folder .. "/Bo Writer - Other Book.epub"
    f = io.open(stuck, "w"); f:write("x"); f:close()
    UIManager.nextTick = function(_self, fn) fn() end
    Library.load()
    eq(#Virtual.books, 0, "both downloaded")
    -- KOReader's deleteSelectedFiles, as a stand-in: one file can't be
    -- deleted; it redraws (here: looks at the entries) after deleting.
    local saved_delete, saved_delete_file = FileManager.deleteSelectedFiles, FileManager.deleteFile
    local seen_during
    FileManager.deleteSelectedFiles = function(self)
        os.remove(path)
        self.selected_files[path] = nil
        seen_during = Virtual.isVirtual(cloud_path)
    end
    Library.installDeleteHooks()
    ticks = {}
    UIManager.nextTick = function(_self, fn) table.insert(ticks, fn) end
    FileManager.deleteSelectedFiles({ selected_files = { [path] = true, [stuck] = true } })
    check(seen_during, "deleted book's cloud entry there when the list is redrawn")
    check(not Virtual.isVirtual(folder .. "/cloud-del-2.epub"), "file not deleted: no cloud entry for it")
    i = 1
    while ticks[i] do ticks[i]() i = i + 1 end
    check(Virtual.isVirtual(cloud_path) and not Virtual.isVirtual(folder .. "/cloud-del-2.epub"),
        "reload agrees")
    FileManager.deleteSelectedFiles, FileManager.deleteFile = saved_delete, saved_delete_file
    os.remove(stuck)
    Virtual.refresh = real_refresh
    UIManager.nextTick = function(_self, fn) fn() end

    -- The library folder setting is a symlink: KOReader's delete dialog
    -- passes the file's real path, and the cloud entry still comes back.
    local link = TMP .. "/library-link"
    os.execute(string.format("ln -s '%s' '%s'", folder, link))
    Library.save("folder", link)
    f = io.open(path, "w"); f:write("x"); f:close()
    Library.load()
    local link_cloud = link .. "/cloud-del-1.epub"
    check(not Virtual.isVirtual(link_cloud), "symlinked folder: downloaded")
    local real_file = require("ffi/util").realpath(path)
    check(real_file and real_file:sub(1, #link) ~= link, "deleted by its real path")
    check(FileManager.deleteFile(FileManager, real_file, true), "deleted by real path")
    check(Virtual.isVirtual(link_cloud), "symlinked folder: cloud entry back")
    Library.save("folder", folder)
    os.remove(link)
    Library.load()

    -- Deleting a cloud entry or a file elsewhere doesn't reload.
    local loads, real_load = 0, Library.load
    Library.load = function() loads = loads + 1 end
    local other = TMP .. "/elsewhere.epub"
    f = io.open(other, "w"); f:write("x"); f:close()
    FileManager.deleteFile(FileManager, other, true)
    eq(loads, 0, "file outside the library: no reload")
    Library.load = real_load

    Library.server, UIManager.nextTick = real_server, real_tick
    Virtual.setCatalog(nil, {})
end

-- Cloud books in the reading history --------------------------------------------------

do
    local Library = require("cloudlibrary/library")
    local History = require("cloudlibrary/history")
    local Guard = require("cloudlibrary/guard")
    local ReadHistory = require("readhistory")
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    local folder = TMP .. "/histlib"
    lfs.mkdir(folder)
    local server = { url = "http://hist.invalid/opds", username = "u" }
    local real_server, real_tick = Library.server, UIManager.nextTick
    Library.server = function() return server end
    UIManager.nextTick = function(_self, fn) fn() end
    Library.save("folder", folder)
    local U1 = "aaaaaaaa-0000-4000-8000-000000000001"
    local U2 = "aaaaaaaa-0000-4000-8000-000000000002"
    local store = Store.open(Library.dbPath(server), false)
    store:upsertBooks({
        { uuid = U1, title = "Up", authors = { "Bo Writer" } },
        { uuid = U2, title = "Down", authors = { "Ann Author" } },
    }, 1)
    store:close()
    local down = folder .. "/Ann Author - Down.epub"
    local f = io.open(down, "w"); f:write("x"); f:close()
    local cloud1 = folder .. "/cloud-" .. U1 .. ".epub"

    eq(Library.pathForUuids({ U1 }), nil, "before installing: nothing")
    Library.installHistory()
    Library.load()
    eq(Library.pathForUuids({ U1:upper() }), cloud1, "a cloud book: its cloud entry (any case)")
    eq(Library.pathForUuids({ "11111111-0000-4000-8000-000000000000", U2 }), down, "a downloaded book: its file")
    eq(Library.pathForUuids({ "11111111-0000-4000-8000-000000000000" }), nil, "not in the catalog")

    -- A cloud entry, as Concordance puts one in.
    ReadHistory.hist = {
        { time = 200, file = down, text = "Ann Author - Down.epub", dim = false, select_enabled = true },
        { time = 100, file = cloud1, text = "cloud.epub", dim = false, select_enabled = false },
    }
    ReadHistory:_flush()
    local saved = Library.settings().history_cloud
    check(type(saved) == "table" and #saved == 1 and saved[1].file == cloud1 and saved[1].time == 100,
        "cloud entries remembered on save")
    ReadHistory:reload(true)
    local e = ReadHistory.hist[ReadHistory:getIndexByFile(cloud1) or 0]
    check(e and not e.dim and not e.select_enabled, "read back: shown, never reopened")
    ReadHistory.hist[1].time = 50 -- the cloud entry newest
    table.sort(ReadHistory.hist, function(a, b) return a.time > b.time end)
    ReadHistory:ensureLastFile()
    eq(G_reader_settings:readSetting("lastfile"), down, "startup book: never a cloud entry")

    -- Auto-remove on: kept, and put back after KOReader dropped it at startup.
    G_reader_settings:saveSetting("autoremove_deleted_items_from_history", true)
    ReadHistory:clearMissing()
    check(ReadHistory:getIndexByFile(cloud1), "auto-remove keeps cloud entries")
    Guard.failed.history = "as before the plugin loads"
    ReadHistory:clearMissing() -- KOReader's own
    Guard.failed.history = nil
    check(not ReadHistory:getIndexByFile(cloud1), "KOReader alone drops it")
    History.restore(ReadHistory)
    e = ReadHistory.hist[ReadHistory:getIndexByFile(cloud1) or 0]
    check(e and e.time == 100, "put back at startup, at its time")
    G_reader_settings:delSetting("autoremove_deleted_items_from_history")
    History.restore(ReadHistory) -- auto-remove off: a missing entry was removed by hand
    ReadHistory:removeItemByPath(cloud1)
    History.restore(ReadHistory)
    check(not ReadHistory:getIndexByFile(cloud1), "removed by hand: stays removed")
    ReadHistory.hist = {
        { time = 100, file = cloud1, text = "cloud.epub", dim = false, select_enabled = false },
    }
    ReadHistory:_flush()

    -- Tapping or long-pressing it in the History view shows its details.
    local shown, real_show = {}, Virtual.showDetails
    Virtual.showDetails = function(path) table.insert(shown, path) end
    local manager = { booklist_menu = {
        onMenuSelect = function() return "opened" end, onMenuHold = function() return "held" end,
    } }
    History.wrapHistoryMenu(manager)
    check(manager.booklist_menu:onMenuSelect({ file = cloud1 }) == true and shown[1] == cloud1, "tap: details")
    check(manager.booklist_menu:onMenuHold({ file = cloud1 }) == true and #shown == 2, "long-press: details")
    eq(manager.booklist_menu:onMenuSelect({ file = down }), "opened", "a file opens as usual")
    Virtual.showDetails = real_show

    -- Downloaded: the entry becomes the file.
    local up = folder .. "/Bo Writer - Up.epub"
    f = io.open(up, "w"); f:write("y"); f:close()
    Library.load()
    check(ReadHistory:getIndexByFile(up) and not ReadHistory:getIndexByFile(cloud1), "downloaded: the file's entry")
    eq(ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0].time, 100, "at the same time")
    eq(Library.pathForUuids({ U1 }), up, "and Concordance gets the file")

    -- Deleted: back to the cloud entry, before the caller redraws (the
    -- reload after it hasn't run), with the entry in the middle of the
    -- history and a new first entry (ZenOS's "last read" sort rebuilds its
    -- index only when the length or first or last entry changes).
    table.insert(ReadHistory.hist, 1, { time = 300, file = down, text = "Ann Author - Down.epub",
        dim = false, select_enabled = true })
    table.insert(ReadHistory.hist, { time = 10, file = folder .. "/old.epub", text = "old.epub",
        dim = true, select_enabled = false })
    local first, last, len = ReadHistory.hist[1], ReadHistory.hist[#ReadHistory.hist], #ReadHistory.hist
    local moved = ReadHistory.hist[2]
    Library.installDeleteHooks()
    local ticks = {}
    UIManager.nextTick = function(_self, fn) table.insert(ticks, fn) end
    -- An open ZenOS Series list with the book, and its book list.
    local real_stack = UIManager._window_stack
    local series_files = { up }
    local series_redraws = 0
    local series = { item_table = { { text = "Saga", _zen_files = series_files } },
        updateItems = function() series_redraws = series_redraws + 1 end }
    local book_list = { item_table = { { text = "Bo Writer - Up", path = up, filepath = up } },
        updateItems = function() series_redraws = series_redraws + 1 end }
    UIManager._window_stack = { { widget = series }, { widget = book_list } }
    check(FileManager.deleteFile(FileManager, up, true), "file deleted")
    eq(series_files[1], cloud1, "series list has the cloud entry before the caller redraws")
    eq(book_list.item_table[1].path, cloud1, "book list item is the cloud entry")
    eq(series_redraws, 2, "both redrawn")
    -- ZenOS then takes the deleted file out of its lists: nothing to take.
    for i = #series_files, 1, -1 do
        if series_files[i] == up then table.remove(series_files, i) end
    end
    eq(#series_files, 1, "book still in the series after ZenOS's clean-up")
    UIManager._window_stack = real_stack
    check(ReadHistory:getIndexByFile(cloud1) and not ReadHistory:getIndexByFile(up),
        "deleted: the cloud entry again, before the reload")
    eq(ReadHistory:getIndexByFile(cloud1), 2, "in the same place")
    check(ReadHistory.hist[2] ~= moved, "moved entry is a new table")
    check(not ReadHistory.hist[2].dim and not ReadHistory.hist[2].select_enabled,
        "the cloud entry kept as one through the re-read")
    check(ReadHistory.hist[1] ~= first and ReadHistory.hist[1].file == down and ReadHistory.hist[1].time == 300,
        "history read back after saving: a new first entry")
    check(#ReadHistory.hist == len and ReadHistory.hist[#ReadHistory.hist] ~= last
        and ReadHistory.hist[#ReadHistory.hist].file == last.file, "same length and entries, new tables")
    -- ZenOS's Home forgets the file and the cloud entry and is rebuilt.
    local forgot, rebuilt = {}, 0
    local real_fm = FileManager.instance
    FileManager.instance = { zenos = { _zen_shared = { home = {
        invalidateBookCache = function(p, history_changed) if history_changed then forgot[p] = true end end,
        rebuildActive = function() rebuilt = rebuilt + 1 end,
    } } } }
    package.loaded["common/shared_state"] = { get = function(p, key) return p._zen_shared[key] end }
    UIManager.nextTick = function(_self, fn) fn() end
    for _i, fn in ipairs(ticks) do fn() end
    check(forgot[up] and forgot[cloud1], "Home forgets the deleted file and the cloud entry")
    eq(rebuilt, 1, "Home rebuilt after the delete")
    FileManager.instance = real_fm
    package.loaded["common/shared_state"] = nil
    e = ReadHistory.hist[ReadHistory:getIndexByFile(cloud1) or 0]
    check(e and not e.dim, "shown as a cloud book")
    eq(e and e.time, 100, "at its read time")

    -- Gone from the catalog: greyed out.
    store = Store.open(Library.dbPath(server), false)
    store:upsertBooks({ { uuid = U2, title = "Down", authors = { "Ann Author" } } }, 2)
    store:deleteUnseen(2)
    store:close()
    Library.load()
    e = ReadHistory.hist[ReadHistory:getIndexByFile(cloud1) or 0]
    check(e and e.dim, "book gone from the catalog: greyed out")

    ReadHistory.hist = {}
    ReadHistory:_flush()
    Library.server, UIManager.nextTick = real_server, real_tick
    Library.save("folder", nil)
    Virtual.setCatalog(nil, {})
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

    -- List items carry the book's metadata (ZenOS's series grouping reads
    -- CoverBrowser's database for items without it, where cloud books aren't).
    Virtual.setCatalog("/lib/", { { id = "s1", title = "Third", series = "Saga", series_index = 3 } })
    local fc = { getListItem = function(_self, _dir, _name, item_path) return { path = item_path } end }
    local item = Virtual.listItem(fc, Virtual.books[1])
    check(item.doc_props and item.doc_props.series == "Saga" and item.doc_props.series_index == 3
        and item.doc_props.display_title == "Third", "list item has the book's series and title")
    fc.getListItem = function(_self, _dir, _name, item_path) return { path = item_path, doc_props = { title = "Own" } } end
    eq(Virtual.listItem(fc, Virtual.books[1]).doc_props.title, "Own", "metadata set by a sort is kept")
end

-- ZenOS book sources -----------------------------------------------------------------------

do
    local ZenSource = require("cloudlibrary/zenos_source")
    local Settings = require("cloudlibrary/settings")
    local zen_tags = { { tag = "x", files = { "/lib/a.epub", "/lib/a.epub" } }, { tag = "y", files = { "/lib/a.epub" } } }
    local db = { getGroupedByTags = function() return zen_tags end }
    local orig_tags = db.getGroupedByTags
    package.loaded["common/db_bookinfo"] = db
    Virtual.setCatalog("/lib", {
        { id = "c1", title = "Cloud One", authors = { "Ann", "Bo" }, series = "Saga", series_index = "2",
          tags = { "x" }, language = "en" },
    })
    local fmu = require("apps/filemanager/filemanagerutil")
    local real_openFile = fmu.openFile
    check(ZenSource.install(Virtual), "registers with ZenOS")
    local source = ZenOS.sources.cloudlibrary
    check(source ~= nil, "source registered as cloudlibrary")
    eq(ZenOS.integrated, 1, "ZenOS's metadata integration installed")
    check(ZenSource.install(Virtual) and ZenOS.integrated == 1, "registers once")

    local books = source.books()
    eq(#books, 1, "cloud books listed")
    eq(books[1].file, "/lib/cloud-c1.epub", "book path")
    local info = books[1].info
    eq(info.authors, "Ann\nBo", "authors joined as in bookinfo")
    eq(info.series_index, 2, "series number")
    eq(info.keywords, "x", "tags as keywords")
    eq(info.language, "en", "language")
    check(source.books() == books, "books cached while the catalog is unchanged")
    Settings.save("zenos_groups", false)
    eq(#source.books(), 0, "groups setting off: none")
    Settings.save("zenos_groups", true)

    check(source.owns("/lib/cloud-c1.epub") and not source.owns("/lib/a.epub"), "owns cloud books only")
    local shown
    local real_show = Virtual.showDetails
    Virtual.showDetails = function(path) shown = path end
    check(source.open("/lib/cloud-c1.epub") == true and shown == "/lib/cloud-c1.epub", "open shows details")
    shown = nil
    check(not source.open("/lib/a.epub") and shown == nil, "other books not handled")
    check(source.showContextMenu(nil, { path = "/lib/cloud-c1.epub" }) == true, "long-press shows details")

    -- Open backstop, outside ZenOS's openFile wrapper (ZenOS wraps it later).
    local opened
    fmu.openFile = function(_ui, file) opened = file end
    shown = nil
    source.books() -- ZenOS rebuilding a grouping
    fmu.openFile(nil, "/lib/cloud-c1.epub")
    check(shown == "/lib/cloud-c1.epub" and opened == nil, "tap from other ZenOS views: details")
    fmu.openFile(nil, "/lib/a.epub")
    eq(opened, "/lib/a.epub", "other books open as usual")
    fmu.openFile = real_openFile
    Virtual.showDetails = real_show

    local bi = source.bookInfo("/lib/cloud-c1.epub", false)
    check(bi and bi.title == "Cloud One" and bi.cover_fetched == "Y", "bookInfo for a cloud book")
    check(source.bookInfo("/lib/a.epub", false) == nil, "bookInfo: nil for other books")

    local key = source.listingKey("/lib")
    check(type(key) == "string" and key ~= "", "listing key for the library folder")
    eq(source.listingKey("/lib/"), key, "trailing slash")
    eq(source.listingKey("/"), key, "parent folders count the books")
    check(source.listingKey("/libx") == nil and source.listingKey("/lib/sub") == nil, "no key for other folders")

    ZenOS.changes = {}
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two" } })
    check(source.listingKey("/lib") ~= key, "key changes with the catalog")
    local paths = ZenOS.changes[#ZenOS.changes]
    check(type(paths) == "table" and table.concat(paths, " ") == "/lib/cloud-c1.epub /lib/cloud-c2.epub",
        "ZenOS told of old and new books")
    eq(source.books()[1].file, "/lib/cloud-c2.epub", "books rebuilt after a catalog change")
    local key2 = source.listingKey("/lib")
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two" } })
    eq(source.listingKey("/lib"), key2, "same catalog, same key (stable across restarts)")
    local real_extra = Virtual.listingExtra
    Virtual.listingExtra = function() return "badges" end
    check(source.listingKey("/lib") ~= key2, "key changes with badge settings")
    Virtual.listingExtra = real_extra

    -- Covers arriving: ZenOS drops its cached covers.
    ZenOS.changes = {}
    Covers.on_arrived({ Virtual.books[1] })
    check(ZenOS.changes[1] and ZenOS.changes[1][1] == "/lib/cloud-c2.epub", "cover arrival reported")

    -- Tags: each book once.
    check(db.getGroupedByTags ~= orig_tags, "tags hooked")
    local tags = db.getGroupedByTags()
    eq(#tags[1].files, 1, "tag lists each book once")
    eq(#zen_tags[1].files, 2, "ZenOS's cached list is left alone")
    check(tags[2] == zen_tags[2], "unchanged tag groups reused")
    check(db.getGroupedByTags() == tags, "de-duplicated once while ZenOS's list is the same")

    -- A download: open views point at the file and are redrawn.
    local UIManager = require("ui/uimanager")
    local real_stack = UIManager._window_stack
    local cloud, file = "/lib/cloud-c2.epub", "/lib/Ann - Cloud Two.epub"
    local shared_files = { "/lib/a.epub", cloud }
    local updates, tbr_reloads, home_rebuilds = 0, 0, 0
    local groups = { item_table = {
        { text = "Ann", _zen_files = shared_files },
        { text = "Saga", series_items = { { text = "cloud-c2", path = cloud, filepath = cloud } } },
    }, updateItems = function() updates = updates + 1 end }
    local detail = { item_table = { { text = "cloud-c2", path = cloud, filepath = cloud } },
        updateItems = function() updates = updates + 1 end }
    local history = { item_table = { { text = "Cloud Two", file = cloud } },
        updateItems = function() updates = updates + 1 end }
    local unrelated = { item_table = { { path = "/lib/a.epub" } },
        updateItems = function() error("redrawn without the book") end }
    local tbr = { item_table = {}, _zen_tbr_refresh = function() tbr_reloads = tbr_reloads + 1 end }
    UIManager._window_stack = { { widget = groups }, { widget = detail }, { widget = history },
        { widget = unrelated }, { widget = tbr } }
    local FileManager = require("apps/filemanager/filemanager")
    local real_fm = FileManager.instance
    local plugin = { _zen_shared = { home = { rebuildActive = function() home_rebuilds = home_rebuilds + 1 end } },
        _zen_shared_registry = { home = true } }
    FileManager.instance = { zenos = plugin }
    package.loaded["common/shared_state"] = { get = function(p, key) return p._zen_shared[key] end }
    ZenSource.downloaded(cloud, file)
    eq(shared_files[2], file, "group's file list (shared with its book list) has the file")
    eq(groups.item_table[2].series_items[1].path, file, "series group's book has the file")
    check(detail.item_table[1].path == file and detail.item_table[1].filepath == file, "book list item has the file")
    eq(detail.item_table[1].text, "Ann - Cloud Two", "file name shown as the file browser would")
    eq(history.item_table[1].file, file, "history item has the file")
    eq(history.item_table[1].text, "Cloud Two", "other titles kept")
    eq(updates, 3, "views listing the book redrawn")
    eq(tbr_reloads, 1, "To Be Read reloaded")
    eq(home_rebuilds, 1, "Home rebuilt")
    UIManager._window_stack = real_stack
    FileManager.instance = real_fm
    package.loaded["common/shared_state"] = nil

    package.loaded["common/db_bookinfo"] = nil
    Virtual.setCatalog(nil, {})
end

-- Concordance: what it's told, and the state it gives back -------------------------------------

do
    local Library = require("cloudlibrary/library")
    local Virtual = require("cloudlibrary/virtual")
    local saved = { Library.catalog, Library.matched, Library.by_title, Library.file_info, Library.on_device }
    local A_ID, B_ID, C_ID = "AAAAAAAA-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000b2",
        "00000000-0000-4000-8000-0000000000c3"
    Library.catalog = {
        { id = A_ID, title = "By UUID", authors = { "Ann" } },
        { id = B_ID, title = "By Title", authors = { "Bo", "Cy" } },
        { id = C_ID, title = "A PDF", authors = {} },
    }
    Library.matched = { [A_ID] = "/lib/a.epub", [B_ID] = "/lib/b.epub", [C_ID] = "/lib/c.pdf" }
    Library.by_title = { [B_ID] = true }
    Library.file_info = { ["/lib/a.epub"] = { md5 = "ma" }, ["/lib/b.epub"] = { md5 = "mb" }, ["/lib/c.pdf"] = { md5 = "mc" } }
    Library.on_device = { ["/lib/b.epub"] = true, ["/lib/a.epub"] = true, ["/lib/c.pdf"] = true }
    eq(table.concat(Library.localFiles(), ","), "/lib/a.epub,/lib/b.epub,/lib/c.pdf", "local files for Concordance")
    local links = Library.links()
    eq(#links, 2, "links: files that don't name the book's UUID")
    eq(links[1].path .. " " .. links[1].md5 .. " " .. links[1].uuids[1] .. " " .. links[1].authors,
        "/lib/b.epub mb " .. B_ID .. " Bo\nCy", "link: matched by title")
    eq(links[2].path .. " " .. links[2].uuids[1], "/lib/c.pdf " .. C_ID, "link: a PDF")
    Library.file_info["/lib/c.pdf"].md5 = nil
    eq(#Library.links(), 1, "links: not until the file's MD5 is known")

    -- Without Concordance: no state.
    package.loaded["concordance/identity"] = nil
    eq(Library.stateText(A_ID), nil, "no Concordance: no state")
    local listener
    local states = {}
    local THIS = {}
    package.loaded["concordance/identity"] = {
        THIS_DEVICE = THIS,
        available = function() return true end,
        bookState = function(uuids) return states[uuids[1]] end,
        onChanged = function(key, fn) listener = { key, fn } end,
    }
    eq(Library.stateText(A_ID), nil, "Concordance knows nothing: no state")
    check(listener and listener[1] == "cloudlibrary", "listens for Concordance's changes")
    local t = os.time{ year = 2026, month = 10, day = 5, hour = 12 }
    states[A_ID] = { status = "complete", rating = 4, last_read = t, last_device = "Kobo Forma" }
    eq(Library.stateText(A_ID), "Finished · ★★★★☆ · Last read 5 Oct 2026 on Kobo Forma", "state line")
    states[A_ID] = { status = "abandoned", last_read = t, last_device = THIS }
    eq(Library.stateText(A_ID), "On hold · Last read 5 Oct 2026 on this device", "on hold, on this device")
    states[A_ID] = { status = "reading", last_read = t }
    eq(Library.stateText(A_ID), "Reading · Last read 5 Oct 2026", "device not named")
    states[A_ID] = { rating = 9 }
    eq(Library.stateText(A_ID), nil, "nonsense rating: nothing to say")
    states[A_ID] = { status = "reading" }
    eq(Virtual.stateText(A_ID), "Reading", "the details sheet asks the library")
    package.loaded["concordance/identity"].bookState = function() error("boom") end
    eq(Virtual.stateText(A_ID), nil, "a Concordance error leaves the line out")
    package.loaded["concordance/identity"] = nil
    -- For Concordance to withdraw links: every file with its MD5, and what's in the catalog.
    Library.file_info["/lib/stray.pdf"] = { md5 = "ms" }
    Library.file_info["/lib/unread.pdf"] = {}
    local ff = Library.folderFiles()
    eq(#ff, 3, "folder files: those with an MD5")
    eq(ff[3].path .. " " .. ff[3].md5, "/lib/stray.pdf ms", "folder files: unmatched ones too")
    check(Library.inCatalog(A_ID:lower()) and Library.inCatalog(B_ID:upper()) and not Library.inCatalog("nope")
        and not Library.inCatalog(nil), "in the catalog, whatever the case")
    Library.catalog = {}
    check(not Library.inCatalog(A_ID), "another catalog: looked up afresh")
    Library.catalog, Library.matched, Library.by_title, Library.file_info, Library.on_device = unpack(saved)
end

-- The menu: groups in order, every entry explained.

do
    local Library = require("cloudlibrary/library")
    local function labels(items)
        local out = {}
        for _i, item in ipairs(items) do
            local text = item.text or (item.text_func and item.text_func()) or "?"
            table.insert(out, (text:gsub(":.*$", "")))
            check(item.help_text ~= nil or text:find("^Check for updates") or text:find("^Automatic updates"),
                "menu entry explained: " .. text)
        end
        return table.concat(out, " | ")
    end
    local items = Library.menuEntry(nil).sub_item_table_func()
    eq(labels(items),
        "Quick sync now | Full sync now | Download missing covers | Refresh all covers | Quick sync | Full sync | Catalog | Folder"
        .. " | Show cloud books | Mark cloud books | Mark books on this device | Mark books not in the cloud library"
        .. " | Include cloud books in Authors, Series and Tags | Include cloud books in file search | Status | Timings",
        "menu")
    for _i, item in ipairs(items) do
        if item.text == "Include cloud books in file search" then
            check(item.separator, "display group ends after file search")
        end
    end
end

io.stdout:write(string.format("cloudlibrary: %d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
