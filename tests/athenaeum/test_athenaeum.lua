--[[
Tests for athenaeum.koplugin: feed parsing, the catalog store, full and
quick sync against a fake Calibre-Web server, matching local files, and
virtual entries. Runs in KOReader's own LuaJIT (for SQLite, libarchive, luxl):

    tests/athenaeum/run_tests.sh
]]

local REPO, TMP = arg[1], arg[2]
assert(REPO and TMP, "usage: test_athenaeum.lua <repo> <tmpdir>")

require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(TMP .. "/settings.reader.lua")
-- As reader.lua does at startup (needed to draw icons).
require("document/canvascontext"):init(require("device"))
package.path = REPO .. "/athenaeum.koplugin/?.lua;" .. package.path

-- ZenOS's book sources (common/book_sources.lua), which the plugin needs:
-- records what the plugin registers and reports.
local ZenOS = { sources = {}, changes = {}, history_changes = {}, moves = {}, integrated = 0, home_on_top = false }
package.loaded["common/book_sources"] = {
    register = function(id, source) ZenOS.sources[id] = source return true end,
    changed = function(paths) table.insert(ZenOS.changes, paths or false) end,
    historyChanged = function(paths) table.insert(ZenOS.history_changes, paths or false) end,
    moved = function(old, new) table.insert(ZenOS.moves, { old, new }) return true end,
    isHomeOnTop = function() return ZenOS.home_on_top end,
    bookInfo = function() end,
    listingKey = function() end,
    badge = function() end,
    installMetadataIntegration = function() ZenOS.integrated = ZenOS.integrated + 1 return true end,
}

local lfs = require("libs/libkoreader-lfs")
local Feed = require("athenaeum/feed")
local Store = require("athenaeum/store")
local Sync = require("athenaeum/sync")
local Matcher = require("athenaeum/matcher")
local Virtual = require("athenaeum/virtual")
local Covers = require("athenaeum/covers")
local Downloads = require("athenaeum/downloads")

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
        local ok, err = pcall(require, "athenaeum/" .. name)
        check(ok, "module " .. name .. " loads: " .. tostring(err))
    end
    local chunk, err = loadfile(REPO .. "/athenaeum.koplugin/main.lua")
    check(chunk ~= nil, "main.lua parses: " .. tostring(err))
    local ok, plugin = pcall(chunk)
    check(ok and type(plugin) == "table" and plugin.name == "athenaeum", "main.lua loads: " .. tostring(plugin))
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

    -- 8 -> 9 adds books' file names, given by the next load.
    local conn8 = SQ3.open(path)
    conn8:exec([[DROP TABLE books;
        CREATE TABLE books (uuid TEXT PRIMARY KEY, calibre_id INTEGER, title TEXT, authors TEXT,
            tags TEXT, language TEXT, publisher TEXT, published INTEGER, added INTEGER, pages INTEGER,
            summary TEXT, formats TEXT, cover TEXT, size INTEGER, series TEXT, series_index REAL,
            seen INTEGER, series_seen INTEGER, cover_file TEXT, cover_w INTEGER, cover_h INTEGER,
            cover_failed INTEGER, match_title TEXT, match_author TEXT, cover_stale INTEGER,
            cover_etag TEXT, cover_modified TEXT, cover_checked INTEGER);
        INSERT INTO books (uuid, title) VALUES ('old-1', 'Kept');
        UPDATE books SET formats = 'application/pdf' || char(9) || '5' || char(9) || '/d/1/pdf/';
        PRAGMA user_version=8;]])
    conn8:close()
    local store9 = Store.open(path, false)
    eq(store9:count(), 1, "8 -> 9 keeps books")
    eq(store9:listing()[1].file_stem, nil, "8 -> 9: no file name yet")
    local unnamed = store9:unnamedFormats()
    eq(unnamed["old-1"] and unnamed["old-1"][1].type, "application/pdf", "unnamed books with their formats")
    store9:setFileNames({ { id = "old-1", stem = "A - Kept", ext = "pdf" } })
    local named = store9:listing()[1]
    eq(named.file_stem, "A - Kept", "file stem stored")
    eq(named.file_ext, "pdf", "file suffix stored")
    eq(next(store9:unnamedFormats()), nil, "no unnamed books left")
    -- A new title from the catalog keeps the name.
    store9:upsertBooks({ { uuid = "old-1", title = "Renamed", authors = { "A" } } }, 2)
    eq(store9:listing()[1].file_stem, "A - Kept", "title change keeps the file name")
    store9:close()
end

-- File names -------------------------------------------------------------------------

do
    local Names = require("athenaeum/names")
    local function split(name) return table.concat({ Names.split(name) }, "|") end
    eq(split("A - T.epub"), "A - T|epub", "split: epub")
    eq(split("A - T.kepub.epub"), "A - T|kepub.epub", "split: kepub")
    eq(split("A - T.KEPUB.EPUB"), "A - T|KEPUB.EPUB", "split: suffix case kept")
    eq(split("A. B - T.pdf"), "A. B - T|pdf", "split: dots in the stem")
    eq(split("noext"), "noext|", "split: no suffix")
    eq(Names.join("A - T", "pdf"), "A - T.pdf", "join")

    local function base(b) return Downloads.baseStem(b) end
    local function suffix(b) return b.pdf_only and "pdf" or "epub" end
    local opts = { base = base, suffix = suffix }
    local books = {
        { id = "a", title = "Same", authors = { "Ann" } },
        { id = "b", title = "Same", authors = { "Ann" } },             -- same author and title
        { id = "c", title = "Taken", authors = { "Ann" } },            -- an unrelated file has the name
        { id = "d", title = "Here", authors = { "Bo" } },              -- on the device as a PDF
        { id = "e", title = "Paper", authors = { "Cy" }, pdf_only = true },
        { id = "f", title = "Case", authors = { "Di" } },              -- a file differs only in case
    }
    local matched = { d = "/lib/Bo - Here.pdf" }
    local files = { "Ann - Taken.epub", "Bo - Here.pdf", "di - case.EPUB" }
    local changes = Names.assign(books, matched, files, opts)
    eq(#changes, 6, "every book named")
    eq(Names.join(books[1].file_stem, books[1].file_ext), "Ann - Same.epub", "named like a download")
    eq(books[2].file_stem, "Ann - Same (2)", "same name: numbered")
    eq(books[3].file_stem, "Ann - Taken (2)", "a file's name: numbered")
    eq(Names.join(books[4].file_stem, books[4].file_ext), "Bo - Here.pdf", "on the device: the file's name")
    eq(Names.join(books[5].file_stem, books[5].file_ext), "Cy - Paper.pdf", "PDF-only: pdf")
    eq(books[6].file_stem, "Di - Case (2)", "clashes ignore case (FAT)")
    eq(changes[1].old_stem, nil, "new name: no old one")

    -- Loaded again: nothing changes.
    eq(#Names.assign(books, matched, files, opts), 0, "names kept")
    -- A new title keeps the name.
    books[1].title = "Different"
    eq(#Names.assign(books, matched, files, opts), 0, "title change keeps the name")
    eq(books[1].file_stem, "Ann - Same", "old stem kept")
    -- A stored suffix is kept (it follows the format downloaded).
    books[5].file_ext = "epub"
    eq(#Names.assign(books, matched, files, opts), 0, "stored suffix kept")
    books[5].file_ext = "pdf"

    -- Downloaded under another name (renamed, or from before names): the
    -- book takes the file's name; its old stem is free again.
    local moved = Names.assign(books, { d = "/lib/Bo - Here.pdf", a = "/lib/Mine.kepub.epub" },
        { "Ann - Taken.epub", "Bo - Here.pdf", "di - case.EPUB", "Mine.kepub.epub" }, opts)
    eq(#moved, 1, "one book renamed")
    eq(moved[1].id, "a", "the downloaded book")
    eq(moved[1].old_stem, "Ann - Same", "old stem reported")
    eq(Names.join(books[1].file_stem, books[1].file_ext), "Mine.kepub.epub", "file's name taken")

    -- A file turns up with a cloud book's name: the book is renamed.
    local bumped = Names.assign(books, { d = "/lib/Bo - Here.pdf", a = "/lib/Mine.kepub.epub" },
        { "Ann - Taken.epub", "Bo - Here.pdf", "di - case.EPUB", "Mine.kepub.epub", "Cy - Paper.epub" }, opts)
    eq(#bumped, 1, "one book bumped")
    eq(Names.join(books[5].file_stem, books[5].file_ext), "Cy - Paper (2).pdf", "bumped, suffix kept")

    -- Two books stored with the same stem (an older catalog): the first keeps it.
    local twins = { { id = "x", file_stem = "Z", file_ext = "epub" }, { id = "y", title = "Z", file_stem = "Z", file_ext = "epub" } }
    Names.assign(twins, {}, {}, opts)
    eq(twins[1].file_stem, "Z", "first keeps a shared stem")
    eq(twins[2].file_stem, "Z (2)", "second renamed")

    -- Matcher.match reports the book files it saw.
    local nf = TMP .. "/names"
    rmrf(nf); mkdir(nf)
    for _i, name in ipairs({ "A - T.epub", "notes.txt.bak", "B.pdf" }) do
        local f = io.open(nf .. "/" .. name, "w"); f:write("x"); f:close()
    end
    local names = select(5, Matcher.match(nf, {}, {}))
    table.sort(names)
    eq(table.concat(names, "|"), "A - T.epub|B.pdf", "book files' names")
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
    local Timing = require("athenaeum/timing")
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

    -- Stems and suffixes for books' file names.
    eq(Downloads.baseStem(book), "Ann One, Bob Two - Why_ A _Question__", "stem: as a download's name")
    eq(Downloads.baseStem({ id = "x" }), "x", "stem: no title")
    eq(Downloads.baseStem({ id = "x", title = "Dots..." }), "Dots", "stem: no trailing dots")
    local long = Downloads.baseStem({ id = "x", title = string.rep("\u{6F22}", 200) })
    check(#long <= 240, "stem: long titles shortened (" .. #long .. " bytes)")
    check(require("util").fixUtf8(long, "?") == long, "stem: shortened on a character boundary")
    eq(Downloads.suffix("kepub"), "kepub.epub", "kepub suffix")
    eq(Downloads.defaultSuffix({ { type = "application/pdf", href = "/d/1/pdf/" } }), "pdf", "PDF-only book: pdf")
    eq(Downloads.defaultSuffix({ { type = "application/pdf", href = "/d/1/pdf/" },
        { type = "application/epub+zip", href = "/d/1/epub/" } }), "epub", "EPUB preferred")
    eq(Downloads.defaultSuffix(nil), "epub", "no formats: epub")
    do
        local Http = require("athenaeum/http")
        eq(Http.auth({ username = "ann", password = "p%41ss" }), "Basic " .. require("mime").b64("ann:p%41ss"),
            "password with % sent as typed")
        eq(Http.auth({ username = "" }), nil, "no header without a user name")
        -- A network error is tried again once per job, after a pause.
        local answers, calls, slept = {}, 0, {}
        local function fetch()
            calls = calls + 1
            local a = table.remove(answers, 1)
            return a[1], a[2], a[3]
        end
        local function sleep(s) slept[#slept + 1] = s end
        local f = Http.retrying(fetch, 5, sleep)
        answers = { { nil, "Network error: timeout", "network" }, { "body" } }
        eq(f("u"), "body", "network error, then the server answers: the body")
        check(calls == 2 and slept[1] == 5, "tried again after 5 seconds")
        answers = { { nil, "Network error: timeout", "network" } }
        local body, err, kind = f("u")
        check(body == nil and kind == "network" and calls == 3 and #slept == 1,
            "only once per job: the next network error is returned at once")
        f = Http.retrying(fetch, 5, sleep)
        answers = { { nil, "Request failed: 500", "http" } }
        body, err, kind = f("u")
        check(kind == "http" and calls == 4 and #slept == 1, "a server error isn't tried again")
        answers = { { nil, "not modified", "not_modified" } }
        body, err, kind = f("u")
        check(kind == "not_modified" and calls == 5 and #slept == 1, "nor a 304")
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
    local Search = require("athenaeum/search")
    local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    check(Search.inScope("/mnt/onboard/Books", "/mnt/onboard/Books/", false), "same folder")
    check(Search.inScope("/mnt/onboard/Books", "/mnt/onboard", true), "folder below, with subfolders")
    check(not Search.inScope("/mnt/onboard/Books", "/mnt/onboard", false), "folder below, no subfolders")
    check(not Search.inScope("/mnt/onboard/Books", "/mnt/onboard/Bo", true), "prefix isn't a parent")
    check(Search.inScope("/x", "/", true), "root")

    -- The search text as getList prepares it.
    eq(Search.query({ case_sensitive = false }, "Cloud.A"), "cloud.a", "lowercased, plain")
    eq(Search.query({ case_sensitive = true }, "Cloud"), "Cloud", "case-sensitive: as typed")
    eq(Search.query({ use_patterns = true }, "c*d a?l.s"), "c.*d a.l%.s", "patterns: wildcards")
    eq(Search.query({ use_patterns = true }, "*"), "*", "* alone shows everything")

    Virtual.setCatalog("/lib", {
        { id = "q1", title = "Sharpe's Tiger", authors = { "Bernard Cornwell" }, series = "Sharpe" },
        { id = "q2", title = "Security", authors = { "Poul Anderson" } },
    })
    local tiger, security = Virtual.books[1], Virtual.books[2]
    local FC = { show_file = function() return true end }
    local DR = { hasProvider = function() return true end }
    local function search(searcher, text, path, found)
        return Search.cloudEntries(Virtual, searcher, found or {},
            { path = path or "/lib", string = text, FileChooser = FC, DocumentRegistry = DR })
    end
    local function names(entries)
        local out = {}
        for i, e in ipairs(entries) do out[i] = e[1] end
        table.sort(out)
        return table.concat(out, "|")
    end

    -- KOReader's own isFileMatch: by file name, plain text.
    local ko = setmetatable({ case_sensitive = false, use_patterns = false, include_metadata = false,
        include_subfolders = true, no_metadata_count = 0 }, { __index = FileSearcher })
    eq(names(search(ko, "cornwell")), tiger.filename, "KOReader's matching: file name")
    eq(names(search(ko, "*")), names({ { tiger.filename }, { security.filename } }), "* finds them all")
    local entries = search(ko, "anderson")
    check(entries[1][2] == security.path and entries[1][3].mode == "file", "entry: name, path, attributes")
    eq(#search(ko, "cornwell", "/elsewhere"), 0, "library folder not searched: nothing")
    eq(#search(ko, "cornwell", "/"), 1, "library below the searched folder, with subfolders")
    ko.include_subfolders = false
    eq(#search(ko, "cornwell", "/"), 0, "library below, without subfolders: nothing")
    ko.include_subfolders = true
    eq(#search(ko, "cornwell", "/lib", { [tiger.path] = true }), 0, "a file found at the path: not again")
    FC.show_file = function(_self, name) return name ~= tiger.filename end
    eq(#search(ko, "cornwell"), 0, "the browser's filter applies")
    FC.show_file = function() return true end

    -- Whatever isFileMatch is (ZenOS's, with its search on), it decides,
    -- with the prepared text; content search is off for cloud books, and
    -- they don't count as files without metadata.
    local asked = {}
    local zen = { case_sensitive = false, include_subfolders = true, include_content = true,
        no_metadata_count = 3 }
    function zen:isFileMatch(name, path, text, is_file)
        asked[#asked + 1] = text
        check(is_file and self.include_content == false, "asked as a file, without content search")
        self.no_metadata_count = self.no_metadata_count + 1
        return path == security.path
    end
    eq(names(search(zen, "Moby Dick")), security.filename, "the searcher's isFileMatch decides")
    eq(asked[1], "moby dick", "with the text getList would pass")
    check(zen.include_content == true and zen.no_metadata_count == 3, "content search and count put back")
    zen.isFileMatch = function() error("matcher bug") end
    check(not pcall(search, zen, "x") and zen.include_content == true, "put back after an error too")

    Search.enabled = false
    eq(#search(ko, "*"), 0, "setting off: nothing")
    Search.enabled = true
    Virtual.setCatalog(nil, {})
end

-- Badge ----------------------------------------------------------------------------------

do
    local Badge = require("athenaeum/badge")
    -- The library's (set when it's loaded), put back at the end.
    local real_on_device, real_cloud, real_non_cloud = Badge.isOnDevice, Badge.isCloud, Badge.isNonCloud
    Badge.isOnDevice = function(path) return path == "/lib/local.epub" end
    Badge.isCloud = function(path) return path == "/lib/cloud-x.epub" end
    check(Badge.cloud_enabled and not Badge.local_enabled, "defaults: cloud badge on, local badge off")

    -- Kinds, and their icons (ZenOS paints them on covers).
    check(Badge.kind("/lib/cloud-x.epub") == "cloud" and Badge.kind("/lib/local.epub") == nil, "badge kinds")
    Badge.local_enabled = true
    check(Badge.kind("/lib/local.epub") == "local", "local badge kind")
    Badge.local_enabled = false
    for _i, kind in ipairs({ "cloud", "local", "noncloud" }) do
        local icon = Badge.icon(kind)
        check(icon:match("%.svg$") and lfs.attributes(icon, "mode") == "file", "icon file for " .. kind)
    end
    check(Badge.icon("cloud") ~= Badge.icon("local"), "own icon for each kind")
    Badge.cloud_enabled = false
    check(Badge.kind("/lib/cloud-x.epub") == nil, "cloud badge can be turned off")
    Badge.cloud_enabled = true

    -- Not-in-catalog badge: off by default.
    check(not Badge.noncloud_enabled, "default: not-in-catalog badge off")
    Badge.isNonCloud = function(path) return path == "/lib/mine.epub" end
    check(Badge.kind("/lib/mine.epub") == nil, "no not-in-catalog badge while off")
    Badge.noncloud_enabled = true
    check(Badge.kind("/lib/mine.epub") == "noncloud", "not-in-catalog badge kind")
    Badge.noncloud_enabled = false

    -- The cloud badge shows only that the book is in the cloud, whatever
    -- its reading status.
    check(Badge.cloudState == nil, "no reading status for the cloud badge")
    check(Badge.icon(Badge.kind("/lib/cloud-x.epub")) == Badge.icon("cloud"), "plain cloud icon")

    Badge.noncloud_enabled, Badge.local_enabled, Badge.cloud_enabled = false, false, true
    Badge.isOnDevice, Badge.isCloud, Badge.isNonCloud = real_on_device, real_cloud, real_non_cloud
end

-- Guard -------------------------------------------------------------------------------------

do
    local Guard = require("athenaeum/guard")
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
    package.path = REPO .. "/athenaeum.koplugin/?.lua"
    check(not Guard.check() and Guard.zenos_missing, "no ZenOS: library not started")
    check(Guard.statusText():find("needs ZenOS", 1, true), "missing ZenOS described: " .. Guard.statusText())
    package.path = real_path
    package.loaded["common/book_sources"] = zen
    check(Guard.check() and not Guard.zenos_missing, "ZenOS back")

    reset()
end

-- Settings: their own file ----------------------------------------------------------

do
    local Settings = require("athenaeum/settings")
    local Library = require("athenaeum/library")
    local Updater = require("athenaeum/updater")
    os.remove(Settings.path())
    os.remove(Settings.sharedPath())
    Settings.reset()
    Library.save("folder", "/books")
    Library.save("search", false)
    Updater.setMode("off")
    check(lfs.attributes(Settings.path(), "mode") == "file", "settings file written: " .. Settings.path())
    Settings.reset()
    eq(Library.settings().search, false, "saved setting read back from the file")
    eq(Library.settings().folder, "/books", "folder read back from the file")
    eq(Updater.getMode(), "off", "updater mode read back from the file")

    os.remove(Settings.path())
    os.remove(Settings.sharedPath())
    Settings.reset()
end

-- Deleting a downloaded book makes it a cloud book again -------------------------------

do
    local Library = require("athenaeum/library")
    local Search = require("athenaeum/search")
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    local folder = TMP .. "/deleted"
    lfs.mkdir(folder)
    local server = { url = "http://test.invalid/opds", username = "u" }
    local real_server, real_tick = Library.server, UIManager.nextTick
    Library.server = function() return server end
    UIManager.nextTick = function(_self, fn) fn() end
    Library.save("folder", folder)
    eq(Library.quickSyncOn(), true, "quick syncs on by default")
    Library.save("auto_sync", false)
    eq(Library.quickSyncOn(), false, "old automatic sync off: no quick syncs")
    eq(Library.fullSyncMode(), "never", "old automatic sync off: no full syncs")
    Library.setQuickSync(true)
    eq(Library.quickSyncOn(), true, "quick syncs turned on over the old switch")
    eq(Library.settings().quick_sync, nil, "on: nothing saved (older versions: hourly)")
    eq(Library.fullSyncMode(), "never", "full syncs left as they were")
    Library.save("quick_sync", "3h")
    eq(Library.quickSyncOn(), true, "an older version's interval: on")
    Library.save("full_sync", "bogus")
    eq(Library.fullSyncMode(), "weekly", "unknown full sync schedule ignored: the default")
    Library.setQuickSync(false)
    eq(Library.settings().quick_sync, "never", "off saved as never (older versions: off too)")
    eq(Library.quickSyncOn(), false, "quick syncs off")

    -- The automatic sync: a quick sync each time while on and online, a
    -- full sync only when due with quick syncs off.
    do
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local real_sync, real_connected = Library.sync, NetworkMgr.isConnected
        local real_schedule, real_unschedule = UIManager.scheduleIn, UIManager.unschedule
        local started, scheduled
        Library.sync = function(mode, quiet, opts) started = { mode, quiet, opts } return true end
        UIManager.scheduleIn = function(_self, s, fn) scheduled = { s, fn } end
        UIManager.unschedule = function() scheduled = nil end
        local online = true
        NetworkMgr.isConnected = function() return online end
        local function run() started = nil Library.syncIfDue() return started and started[1] end
        Library.setQuickSync(true)
        eq(run(), "quick", "quick sync on wake-up/Wi-Fi/file browser")
        eq(started[2], true, "automatic: quiet")
        check(started[3] and started[3].defer_full == true, "automatic: a full sync due by time waits")
        eq(run(), "quick", "and again straight after: no interval")
        online = false
        eq(run(), nil, "offline: nothing")
        online = true
        Library.setQuickSync(false)
        Library.save("full_sync", "daily")
        local st = Store.open(Library.dbPath(server), false)
        st:setMeta("last_full_sync", os.time())
        st:close()
        eq(run(), nil, "quick syncs off, full sync not due: nothing")
        st = Store.open(Library.dbPath(server), false)
        st:setMeta("last_full_sync", os.time() - 2 * 24 * 3600)
        st:close()
        scheduled = nil
        eq(run(), nil, "quick syncs off, full sync due: not at once")
        check(scheduled and scheduled[1] == 120, "but in two minutes")
        Library._deferredFullSync()
        eq(started and started[1], "full", "then a full sync")
        Library.job = { mode = "prefetch" }
        started, scheduled = nil, nil
        Library._deferredFullSync()
        check(not started and scheduled and scheduled[1] == 30, "another job running: tried again soon")
        Library.job = nil
        online = false
        started, scheduled = nil, nil
        Library._deferredFullSync()
        check(not started and not scheduled, "offline by then: left for the next automatic sync")
        online = true
        Library.save("full_sync", "never")
        scheduled = nil
        eq(run(), nil, "both off: nothing")
        check(not scheduled, "both off: nothing later either")
        Library.sync, NetworkMgr.isConnected = real_sync, real_connected
        UIManager.scheduleIn, UIManager.unschedule = real_schedule, real_unschedule
    end

    -- An automatic sync that couldn't reach the server says nothing; one
    -- asked for still reports it.
    do
        local ffiutil = require("ffi/util")
        local NetworkMgr = require("ui/network/manager")
        local UIManager = require("ui/uimanager")
        local real = { ffiutil.isSubProcessDone, ffiutil.readAllFromFD, Library.syncIfDue,
            package.loaded["ui/widget/notification"], UIManager.scheduleIn, NetworkMgr.isConnected,
            Library.last_result }
        local notified = {}
        package.loaded["ui/widget/notification"] = {
            SOURCE_ALWAYS_SHOW = 1, notify = function(_self, text) notified[#notified + 1] = text end,
        }
        ffiutil.isSubProcessDone = function() return true end
        UIManager.scheduleIn = function() end
        NetworkMgr.isConnected = function() return false end
        local function finish(job, err)
            ffiutil.readAllFromFD = function() return require("dump")({ mode = job.mode, error = err }) end
            Library.job = job
            Library.poll()
        end
        finish({ mode = "quick", quiet = true, opts = {}, t0 = 0 }, "Network error: timeout")
        eq(#notified, 0, "automatic, network error: no notification")
        finish({ mode = "quick", quiet = true, opts = {}, t0 = 0 }, "The server refused the user name or password (401).")
        eq(#notified, 1, "automatic, another error: still reported")
        finish({ mode = "quick", quiet = false, opts = {}, t0 = 0 }, "Network error: timeout")
        eq(#notified, 2, "asked for: a network error reported")
        ffiutil.isSubProcessDone, ffiutil.readAllFromFD, Library.syncIfDue = real[1], real[2], real[3]
        package.loaded["ui/widget/notification"], UIManager.scheduleIn, NetworkMgr.isConnected = real[4], real[5], real[6]
        Library.job, Library.last_result = nil, real[7]
    end

    -- A quick sync that found nothing doesn't reload the listing or fetch covers.
    do
        local changed, wanted = Library._listingMayHaveChanged, Library._coversWanted
        local function quick(sync, scanned) return { mode = "quick", sync = sync, scanned = scanned } end
        eq(changed("quick", quick({ added = 0 }, 0)), false, "nothing new: no reload")
        eq(changed("quick", quick({ added = 2 }, 0)), true, "new books: reload")
        eq(changed("quick", quick({ added = 0 }, 1)), true, "changed files: reload")
        eq(changed("quick", quick({ added = 0, escalated = true, deleted = 0 }, 0)), true, "became a full sync: reload")
        eq(changed("quick", { mode = "quick", error = "x" }), true, "failed: reload")
        eq(changed("full", { mode = "full", sync = { added = 0, deleted = 0 } }), true, "full sync: reload")
        local real_stats = Library.stats
        Library.stats = { covers = 5, covers_available = 5 }
        eq(wanted(quick({ added = 0 }, 0)), false, "every cover there, nothing new: no cover download")
        eq(wanted(quick({ added = 1 }, 0)), true, "a new book: cover download")
        Library.stats = { covers = 4, covers_available = 5 }
        eq(wanted(quick({ added = 0 }, 0)), true, "a cover missing: cover download")
        Library.stats = real_stats
    end

    Library.save("quick_sync", "never")
    Library.save("auto_sync", false)
    Library.save("full_sync", nil)
    local store = Store.open(Library.dbPath(server), false)
    store:upsertBooks({
        { uuid = "del-1", title = "Kept Book", authors = { "Ann Author" } },
        { uuid = "del-2", title = "Other Book", authors = { "Bo Writer" } },
    }, 1)
    store:close()
    local path = folder .. "/Ann Author - Kept Book.epub"
    local f = io.open(path, "w"); f:write("x"); f:close()
    -- A cloud entry is where its book's file is or would be.
    local cloud_path = path

    Search.install(Virtual)
    Library.installDeleteHooks()
    Library.load()
    check(not Virtual.isVirtual(cloud_path), "downloaded book isn't a cloud book")
    eq(#Virtual.books, 1, "one cloud book before deleting")
    do
        local st = Store.open(Library.dbPath(server), false)
        local names = {}
        for _i, b in ipairs(st:listing()) do names[b.id] = b.file_stem .. "." .. b.file_ext end
        st:close()
        eq(names["del-1"], "Ann Author - Kept Book.epub", "load: downloaded book named after its file")
        eq(names["del-2"], "Bo Writer - Other Book.epub", "load: cloud book named like a download")
    end

    -- Status: headed sections, as Concordance's.
    do
        local text = Library.statusText()
        check(text:find("^Overview\n   Quick sync: last never %(automatic off%)\n   Full sync: last [^\n]* %(never%)\n"
            .. "   Last error: none\n   Problems since KOReader started: none\n"), "status overview: " .. text)
        check(text:find("\n\nCatalog\n   Catalog: http://test.invalid/opds\n   Folder: " .. folder, 1, true),
            "status catalog section: " .. text)
        check(text:find("\n\nBooks\n   In the catalog: 2\n   On this device: 1\n   Shown as cloud books: 1\n", 1, true),
            "status book counts: " .. text)
        check(text:find("\n\nCovers\n   Downloaded: ", 1, true), "status covers: " .. text)
        local real_server = Library.server
        Library.server = function() return nil end
        check(Library.statusText():find("^Overview\n   No catalog chosen%."), "status without a catalog")
        Library.server = real_server
    end

    -- Search through the hooks: KOReader's getList walk, then the cloud
    -- books; cached results are dropped once the cloud books changed.
    local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    FileSearcher.search_path, FileSearcher.search_string = folder, "book"
    local searcher = setmetatable({ include_subfolders = true, case_sensitive = false, use_patterns = false,
        include_metadata = false, ui = {} }, { __index = FileSearcher })
    local function found()
        local _dirs, files = searcher:getList()
        local out = {}
        for _i, entry in ipairs(files) do out[#out + 1] = entry[2] end
        table.sort(out)
        return out
    end
    local before = found()
    eq(#before, 2, "search before deleting: the file and the other cloud book")
    eq(before[1], path, "the file, found by the walk")
    Search.dropStale(FileSearcher, Virtual.generation)
    FileSearcher.search_hash = "cached"
    Search.dropStale(FileSearcher, Virtual.generation)
    eq(FileSearcher.search_hash, "cached", "cloud books unchanged: cached results kept")
    check(FileManager.deleteFile(FileManager, path, true), "file deleted")
    check(Virtual.isVirtual(cloud_path), "deleted book is a cloud book again")
    eq(#Virtual.books, 2, "two cloud books after deleting")
    Search.dropStale(FileSearcher, Virtual.generation)
    eq(FileSearcher.search_hash, nil, "cloud books changed: cached results dropped")
    local after = found()
    eq(#after, 2, "new search: both, now cloud books")
    check(after[1] == path and Virtual.isVirtual(after[1]), "the deleted book, at its path")

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
    local ZenSourceDel = require("athenaeum/zenos_source")
    local was_registered_del = ZenSourceDel.registered
    ZenSourceDel.registered = true
    ZenOS.changes = {}
    local i = 1
    while ticks[i] do ticks[i]() i = i + 1 end -- runs ticks they schedule too
    eq(Virtual.catalog_sig, sig, "reload finds the same cloud books")
    -- ZenOS redraws the folder (on its next tick, after the delete's own
    -- redraw) when told of the deleted file.
    eq(#ZenOS.changes, 1, "ZenOS told once, after the reload")
    local told_del = {}
    for _j, p in ipairs(ZenOS.changes[1] or {}) do told_del[p] = true end
    check(told_del[path], "ZenOS told of the deleted file")
    ZenSourceDel.registered = was_registered_del

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
    check(not Virtual.isVirtual(stuck), "file not deleted: no cloud entry for it")
    i = 1
    while ticks[i] do ticks[i]() i = i + 1 end
    check(Virtual.isVirtual(cloud_path) and not Virtual.isVirtual(stuck),
        "reload agrees")
    FileManager.deleteSelectedFiles, FileManager.deleteFile = saved_delete, saved_delete_file
    os.remove(stuck)
    UIManager.nextTick = function(_self, fn) fn() end

    -- The library folder setting is a symlink: KOReader's delete dialog
    -- passes the file's real path, and the cloud entry still comes back.
    local link = TMP .. "/library-link"
    os.execute(string.format("ln -s '%s' '%s'", folder, link))
    Library.save("folder", link)
    f = io.open(path, "w"); f:write("x"); f:close()
    Library.load()
    local link_cloud = link .. "/Ann Author - Kept Book.epub"
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
    local Library = require("athenaeum/library")
    local History = require("athenaeum/history")
    local Guard = require("athenaeum/guard")
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
    -- Where the book's file would be.
    local cloud1 = folder .. "/Bo Writer - Up.epub"

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
    eq(e and e.text, "Bo Writer - Up.epub", "read back: named like the book in the library folder")
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

    ReadHistory:reload(true)
    eq(ReadHistory.hist[1].text, "Bo Writer - Up.epub", "a cloud entry put in by hand is named too")

    -- Tapping or long-pressing it in the History view shows its details;
    -- long-press adds "Remove from history".
    local shown, shown_opts, real_show = {}, {}, Virtual.showDetails
    Virtual.showDetails = function(path, opts) table.insert(shown, path); table.insert(shown_opts, opts or false) end
    local refreshed = 0
    local manager = { booklist_menu = {
        onMenuSelect = function() return "opened" end, onMenuHold = function() return "held" end,
    }, updateItemTable = function() refreshed = refreshed + 1 end }
    History.wrapHistoryMenu(manager)
    check(manager.booklist_menu:onMenuSelect({ file = cloud1 }) == true and shown[1] == cloud1, "tap: details")
    check(not shown_opts[1], "tap: no history row")
    check(manager.booklist_menu:onMenuHold({ file = cloud1 }) == true and #shown == 2, "long-press: details")
    local closed = 0
    local rows = type(shown_opts[2]) == "table" and shown_opts[2].extra_rows(function() closed = closed + 1 end) or {}
    local remove = rows[1] and rows[1][1]
    check(remove and remove.text:find("Remove from history", 1, true), "long-press: Remove from history row")
    eq(manager.booklist_menu:onMenuSelect({ file = down }), "opened", "a file opens as usual")
    Virtual.showDetails = real_show
    if remove then remove.callback() end
    check(closed == 1 and refreshed == 1 and not ReadHistory:getIndexByFile(cloud1),
        "Remove from history: closes the details, removes the entry, redraws the list")
    check(#(Library.settings().history_cloud or {}) == 0, "and it isn't put back at startup")
    ReadHistory.hist = {
        { time = 100, file = cloud1, text = "cloud.epub", dim = false, select_enabled = false },
    }
    ReadHistory:_flush()

    -- Downloaded: the file is at the cloud entry's path, and the entry opens it.
    local up = cloud1
    f = io.open(up, "w"); f:write("y"); f:close()
    Library.load()
    e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
    check(e and e.select_enabled and not e.dim, "downloaded: the same entry opens the file")
    eq(e and e.time, 100, "at the same time")
    eq(#ReadHistory.hist, 1, "no second entry")
    eq(Library.pathForUuids({ U1 }), up, "and Concordance gets the file")

    -- Deleted: back to the cloud entry, before the caller redraws (the
    -- reload after it hasn't run), with the entry in the middle of the
    -- history and a new first entry (ZenOS's "last read" sort rebuilds its
    -- index only when the length or first or last entry changes).
    table.insert(ReadHistory.hist, 1, { time = 300, file = down, text = "Ann Author - Down.epub",
        dim = false, select_enabled = true })
    table.insert(ReadHistory.hist, { time = 10, file = folder .. "/old.epub", text = "old.epub",
        dim = true, select_enabled = false })
    local len = #ReadHistory.hist
    Library.installDeleteHooks()
    local ticks = {}
    UIManager.nextTick = function(_self, fn) table.insert(ticks, fn) end
    -- ZenOS's open views are told the book changed (it's at the same path).
    local ZenSourceMod = require("athenaeum/zenos_source")
    local was_registered = ZenSourceMod.registered
    ZenSourceMod.registered = true
    ZenOS.moves, ZenOS.changes, ZenOS.history_changes = {}, {}, {}
    check(FileManager.deleteFile(FileManager, up, true), "file deleted")
    local told_now = {}
    for _i, paths in ipairs(ZenOS.changes) do
        for _j, p in ipairs(paths or {}) do told_now[p] = true end
    end
    check(#ZenOS.moves == 0 and told_now[up], "ZenOS told the book changed, before the caller redraws")
    check(#ticks > 0, "the reload waits for the caller's redraw")
    eq(ReadHistory:getIndexByFile(cloud1), 2, "deleted: the cloud entry, in the same place")
    check(not ReadHistory.hist[2].dim and not ReadHistory.hist[2].select_enabled,
        "the cloud entry is a cloud entry again")
    check(ReadHistory.hist[1].file == down and ReadHistory.hist[1].time == 300 and #ReadHistory.hist == len,
        "the other entries as they were")
    -- ZenOS's "last read" index can't see the entry changed in the middle:
    -- it's told the history changed, before the caller redraws.
    local hist_told = {}
    for _i, paths in ipairs(ZenOS.history_changes) do
        for _j, p in ipairs(paths or {}) do hist_told[p] = true end
    end
    check(hist_told[cloud1], "ZenOS told the history changed, before the caller redraws")
    -- ZenOS is told the file and the cloud entry changed (Home forgets them).
    ZenOS.changes = {}
    UIManager.nextTick = function(_self, fn) fn() end
    for _i, fn in ipairs(ticks) do fn() end
    local told = {}
    for _i, paths in ipairs(ZenOS.changes) do
        for _j, p in ipairs(paths or {}) do told[p] = true end
    end
    check(told[up], "ZenOS told of the deleted book after the reload")
    ZenSourceMod.registered = was_registered
    e = ReadHistory.hist[ReadHistory:getIndexByFile(cloud1) or 0]
    check(e and not e.dim, "shown as a cloud book")
    eq(e and e.time, 100, "at its read time")

    -- Every way KOReader deletes: the entry stays, as a cloud entry at its
    -- time. (KOReader greys it out, or removes it with auto-remove on.)
    local function saved_has(path)
        for _i, s in ipairs(Library.settings().history_cloud or {}) do
            if s.file == path and s.time == 100 then return true end
        end
        return false
    end
    local selecting = { onToggleSelectMode = function() end }
    local ways = {
        { "one file", false, function() return FileManager.deleteFile(FileManager, up, true) end },
        { "one file, auto-remove on", true, function() return FileManager.deleteFile(FileManager, up, true) end },
        { "selected files", false, function()
            selecting.selected_files = { [up] = true }
            FileManager.deleteSelectedFiles(selecting)
            return true
        end },
        { "selected files, auto-remove on", true, function()
            selecting.selected_files = { [up] = true }
            FileManager.deleteSelectedFiles(selecting)
            return true
        end },
    }
    for _i, way in ipairs(ways) do
        local name, autoremove, delete = way[1], way[2], way[3]
        f = io.open(up, "w"); f:write("y"); f:close()
        Library.load()
        e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
        check(e and e.select_enabled and e.time == 100, name .. ": downloaded, the entry opens it")
        G_reader_settings:saveSetting("autoremove_deleted_items_from_history", autoremove)
        check(delete(), name .. ": deleted")
        check(not lfs.attributes(up), name .. ": no file")
        e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
        check(e and not e.dim and not e.select_enabled and e.time == 100,
            name .. ": kept as a cloud entry at its time")
        eq(ReadHistory:getIndexByFile(down), 1, name .. ": in its place")
        check(saved_has(up), name .. ": remembered as a cloud entry (put back at startup)")
        ReadHistory:reload(true)
        e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
        check(e and not e.dim and not e.select_enabled, name .. ": the same read back")
        G_reader_settings:delSetting("autoremove_deleted_items_from_history")
    end

    -- A file that isn't a catalog book's: as KOReader does.
    local stranger = folder .. "/stranger.epub"
    for _i, autoremove in ipairs({ false, true }) do
        f = io.open(stranger, "w"); f:write("z"); f:close()
        table.insert(ReadHistory.hist, { time = 5, file = stranger, text = "stranger.epub",
            dim = false, select_enabled = true })
        ReadHistory:_flush()
        Library.load()
        G_reader_settings:saveSetting("autoremove_deleted_items_from_history", autoremove)
        check(FileManager.deleteFile(FileManager, stranger, true), "a file not in the catalog: deleted")
        e = ReadHistory.hist[ReadHistory:getIndexByFile(stranger) or 0]
        if autoremove then
            check(not e, "not in the catalog, auto-remove on: removed")
        else
            check(e and e.dim, "not in the catalog: greyed out")
            ReadHistory:removeItemByPath(stranger)
        end
        G_reader_settings:delSetting("autoremove_deleted_items_from_history")
    end

    -- Deleted outside KOReader (over USB): KOReader greys the entry out at
    -- startup; once the catalog is loaded it's a cloud entry again.
    f = io.open(up, "w"); f:write("y"); f:close()
    Library.load()
    os.remove(up)
    e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
    e.dim, e.select_enabled = true, false
    Library.load()
    e = ReadHistory.hist[ReadHistory:getIndexByFile(up) or 0]
    check(e and not e.dim and not e.select_enabled and e.time == 100,
        "deleted outside KOReader: a cloud entry after the load")

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

-- Books moved (Library.booksMoved) ---------------------------------------------------

do
    local Library = require("athenaeum/library")
    local ReadHistory = require("readhistory")
    local ReadCollection = require("readcollection")
    local ZenSourceMod = require("athenaeum/zenos_source")
    local folder = TMP .. "/movedlib"
    rmrf(folder); mkdir(folder)
    local zen_told, real_changed = {}, ZenSourceMod.changed
    ZenSourceMod.changed = function(paths) table.insert(zen_told, table.concat(paths or {}, ">")) end
    local function moved(old, new) Library.booksMoved({ { old, new } }) end
    local function entry(path) return ReadHistory.hist[ReadHistory:getIndexByFile(path) or 0] end
    local function saved()
        local out = {}
        for _i, e in ipairs(Library.settings().history_cloud or {}) do out[e.file] = e.time end
        return out
    end
    local function touch(path) local f = io.open(path, "w"); f:write("x"); f:close() end

    -- A cloud entry moved to another cloud path (a file took its name).
    local cloud_old, cloud_new = folder .. "/Ann - Cloud.epub", folder .. "/Ann - Cloud (2).epub"
    local other = folder .. "/Other.epub"
    touch(other)
    ReadHistory.hist = {
        { time = 500, file = other, text = "Other.epub", dim = false, select_enabled = true },
        { time = 300, file = cloud_old, text = "Ann - Cloud.epub", dim = false, select_enabled = false },
    }
    ReadHistory:_flush()
    Library.save("history_cloud", { { file = cloud_old, time = 300 } })
    moved(cloud_old, cloud_new)
    check(not entry(cloud_old), "moved: no entry at the old path")
    local e = entry(cloud_new)
    check(e and e.time == 300 and not e.select_enabled, "moved: cloud entry at the new path, same time")
    eq(ReadHistory:getIndexByFile(cloud_new), 2, "moved: keeps its place by time")
    eq(saved()[cloud_new], 300, "moved: saved cloud entry follows")
    eq(saved()[cloud_old], nil, "moved: old saved entry gone")
    eq(zen_told[1], cloud_old .. ">" .. cloud_new, "moved: ZenOS told both paths changed")

    -- A cloud entry moved to a file (another format downloaded).
    local pdf = folder .. "/Ann - Cloud (2).pdf"
    touch(pdf)
    moved(cloud_new, pdf)
    e = entry(pdf)
    check(e and e.time == 300 and e.select_enabled, "to a file: opens")
    eq(saved()[pdf], nil, "to a file: no longer a saved cloud entry")
    eq(next(saved()), nil, "to a file: saved list empty")

    -- A file renamed outside KOReader, both paths in the history and the
    -- old one in a collection: one entry at the newer time, collection moved.
    local renamed = folder .. "/Bo - Renamed.epub"
    ReadHistory.hist = {
        { time = 700, file = renamed, text = "Bo - Renamed.epub", dim = false, select_enabled = true },
        { time = 600, file = other, text = "Other.epub", dim = false, select_enabled = true },
    }
    ReadHistory:_flush()
    ReadCollection:addCollection("athenaeum-test")
    ReadCollection:addItem(other, "athenaeum-test")
    ReadCollection:write({ ["athenaeum-test"] = true })
    os.rename(other, renamed)
    moved(other, renamed)
    eq(#ReadHistory.hist, 1, "renamed: one entry")
    eq(entry(renamed) and entry(renamed).time, 700, "renamed: the newer time")
    check(ReadCollection:isFileInCollection(renamed, "athenaeum-test"), "renamed: collection entry moved")
    check(not ReadCollection:isFileInCollection(other, "athenaeum-test"), "renamed: old collection entry gone")

    -- To a path without a file, collections are left alone (KOReader's
    -- collections can't hold one).
    os.remove(renamed)
    moved(renamed, folder .. "/Bo - Gone.epub")
    check(ReadCollection:isFileInCollection(renamed, "athenaeum-test"), "no file: collections untouched")
    check(entry(folder .. "/Bo - Gone.epub"), "no file: the history entry still moves")

    -- Nothing to do.
    local n = #zen_told
    moved(pdf, pdf)
    moved(nil, pdf)
    Library.booksMoved({})
    eq(#zen_told, n, "same path or no path: nothing")
    -- Several: ZenOS told once.
    n = #zen_told
    touch(pdf)
    Library.booksMoved({ { folder .. "/a.epub", folder .. "/b.epub" }, { folder .. "/c.epub", pdf } })
    eq(#zen_told - n, 1, "several moved: ZenOS told once")
    eq(zen_told[#zen_told], folder .. "/a.epub>" .. folder .. "/b.epub>" .. folder .. "/c.epub>" .. pdf,
        "several moved: every old and new path")

    ReadCollection:removeCollection("athenaeum-test")
    ReadCollection:write()
    ReadHistory.hist = {}
    ReadHistory:_flush()
    Library.save("history_cloud", nil)
    ZenSourceMod.changed = real_changed
end

-- One path per book: downloads and renames ------------------------------------------------

do
    local Library = require("athenaeum/library")
    local History = require("athenaeum/history")
    local ReadHistory = require("readhistory")
    local UIManager = require("ui/uimanager")
    local folder = TMP .. "/stablelib"
    rmrf(folder); mkdir(folder)
    local server = { url = "http://stable.invalid/opds", username = "u" }
    local real_server, real_tick = Library.server, UIManager.nextTick
    Library.server = function() return server end
    UIManager.nextTick = function(_self, fn) fn() end
    Library.save("folder", folder)
    Library.save("history_cloud", nil)
    local S1 = "bbbbbbbb-0000-4000-8000-000000000001"
    local S2 = "bbbbbbbb-0000-4000-8000-000000000002"
    local store = Store.open(Library.dbPath(server), false)
    store:upsertBooks({
        { uuid = S1, title = "Cloud", authors = { "Ann" },
          formats = { { type = "application/epub+zip", href = "/d/1/epub/" } } },
        { uuid = S2, title = "Held", authors = { "Bo" } },
    }, 1)
    store:close()
    local held = folder .. "/Bo - Held.epub"
    local f = io.open(held, "w"); f:write("x"); f:close()
    local function entry(path) return ReadHistory.hist[ReadHistory:getIndexByFile(path) or 0] end
    Library.installHistory()
    Library.load()

    -- A cloud book's entry (as Concordance puts one in) and a downloaded one's.
    local cloud = folder .. "/Ann - Cloud.epub"
    ReadHistory.hist = {
        { time = 300, file = cloud, text = "x", dim = false, select_enabled = false },
        { time = 200, file = held, text = "x", dim = false, select_enabled = true },
    }
    ReadHistory:_flush()
    local saved = {}
    for _i, se in ipairs(Library.settings().history_cloud or {}) do saved[se.file] = se end
    check(saved[cloud] and saved[cloud].id == S1 and saved[cloud].time == 300, "saved cloud entry with its ID")
    check(not saved[held], "a file isn't saved")
    -- 0.9's paths aren't known any more: an entry at one is a missing file.
    local old = folder .. "/cloud-" .. S1 .. ".epub"
    check(not History.isCloudPath(old), "a cloud-<id> path isn't a cloud entry")
    local e

    -- A cloud entry before the catalog is loaded: known by the saved list.
    Virtual.setCatalog(nil, {})
    check(History.isCloudPath(cloud), "before loading: a saved cloud entry")
    check(not History.isCloudPath(held), "a file isn't")
    check(not History.isCloudPath(folder .. "/Unknown.epub"), "an unknown path isn't")
    Library.load()

    -- Downloads go to the cloud entry's path.
    local book = { id = S1, title = "Cloud", authors = { "Ann" } }
    eq(Library.downloadName(S1, book, "epub", folder), "Ann - Cloud.epub", "download: the cloud entry's name")
    eq(Library.downloadName(S1, book, "pdf", folder), "Ann - Cloud.pdf", "another format: same stem")
    eq(Library.downloadName("nope", book, "epub", folder), "Ann - Cloud.epub", "no name: as before")

    -- A different book's file turns up with the cloud book's name: the
    -- book is renamed, and its history entry follows.
    local intruder = folder .. "/Ann - Cloud.epub"
    f = io.open(intruder, "w"); f:write("other"); f:close()
    local attr = lfs.attributes(intruder)
    store = Store.open(Library.dbPath(server), false)
    store:setLocalFile(intruder, { mtime = attr.modification, size = attr.size, uuids = {},
        title = "Something Else", authors = { "Zed" } })
    store:close()
    eq(Library.downloadName(S1, book, "epub", folder), "Ann - Cloud (2).epub", "download: the name is taken")
    Library.load()
    local bumped = folder .. "/Ann - Cloud (2).epub"
    eq(Virtual.by_id[S1] and Virtual.by_id[S1].path, bumped, "renamed past the file")
    e = entry(bumped)
    check(e and e.time == 300 and not e.select_enabled, "history entry followed")
    eq(Library.downloadName(S1, book, "epub", folder), "Ann - Cloud (2).epub", "downloads follow")

    ReadHistory.hist = {}
    ReadHistory:_flush()
    Library.save("history_cloud", nil)
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
    check(Virtual.isVirtual("/lib/Two.epub"), "virtual path: named like a download")

    -- The names the catalog gave (Library.nameBooks); two books with one
    -- name (shouldn't happen) still get an entry each.
    Virtual.setCatalog("/lib", {
        { id = "n1", title = "T", file_stem = "Ann - T", file_ext = "pdf" },
        { id = "n2", title = "U", file_stem = "Ann - T", file_ext = "pdf" },
    })
    eq(Virtual.by_id.n1.path, "/lib/Ann - T.pdf", "path from the stored name")
    eq(Virtual.by_id.n2.path, "/lib/U.pdf", "a clashing name: renamed (from its title), suffix kept")
    -- A file turned up at a cloud book's name: listed as itself.
    local lfc = { getListItem = function(_self, _dir, name, item_path) return { path = item_path, text = name } end }
    local listed = { { path = "/lib/Ann - T.pdf", text = "Ann - T.pdf" } }
    Virtual._addCloudItems(lfc, "/lib", listed, {})
    eq(#listed, 2, "one cloud book added")
    eq(listed[2].path, "/lib/U.pdf", "the other cloud book")
    -- The browser's filters apply to cloud books too (status filter...).
    local asked
    lfc.show_file = function(_self, name, item_path) asked = { name, item_path } return nil end
    listed = { { path = "/lib/Ann - T.pdf", text = "Ann - T.pdf" } }
    Virtual._addCloudItems(lfc, "/lib", listed, {})
    eq(#listed, 1, "filtered out: not added")
    check(asked and asked[1] == "U.pdf" and asked[2] == "/lib/U.pdf", "filter asked with name and path")
    lfc.show_file = function() return true end
    listed = {}
    Virtual._addCloudItems(lfc, "/lib", listed, {})
    eq(#listed, 2, "let through: added")
    lfc.show_file = function() error("filter bug") end
    check(Virtual._passesFilter(lfc, Virtual.books[1]), "a failing filter lets the book through")
    check(Virtual._passesFilter({}, Virtual.books[1]), "no filter: let through")
    Virtual.setCatalog("/lib/", {
        { id = "x1", title = "One" }, { id = "x1", title = "One again" }, { id = "x2", title = "Two" },
        { title = "no id" },
    })

    -- List items carry the book's metadata (ZenOS's series grouping reads
    -- CoverBrowser's database for items without it, where cloud books aren't).
    Virtual.setCatalog("/lib/", { { id = "s1", title = "Third", series = "Saga", series_index = 3 } })
    local item = Virtual.withProps({ path = Virtual.books[1].path }, Virtual.books[1])
    check(item.doc_props and item.doc_props.series == "Saga" and item.doc_props.series_index == 3
        and item.doc_props.display_title == "Third", "list item has the book's series and title")
    eq(Virtual.withProps({ doc_props = { title = "Own" } }, Virtual.books[1]).doc_props.title, "Own",
        "metadata set by a sort is kept")
end

-- The listing hook: every return value passed on; folder counts --------------------

do
    Virtual.setCatalog("/lib", { { id = "c1", title = "One" }, { id = "c2", title = "Two" } })
    local real_rebuilding = Virtual.listingRebuilding
    Virtual.listingRebuilding = function() end
    local fc = { name = "filemanager", show_file = function() return true end,
        getListItem = function(_self, _dir, name, item_path) return { path = item_path, text = name } end }
    local function orig(_self, _path, collate)
        if collate then return { { path = "/lib/sub" } }, { { path = "/lib/local.epub" } }, true, "extra", nil end
        return { true }, { true }, false, "extra", nil
    end
    local r = { n = select("#", Virtual._listing(orig, fc, "/lib", {})), Virtual._listing(orig, fc, "/lib", {}) }
    eq(r.n, 5, "listing: every value returned, nils at the end too")
    check(#r[2] == 3 and r[3] == true and r[4] == "extra", "listing: cloud books added, later values kept")
    r = { Virtual._listing(orig, fc, "/lib") }
    check(#r[2] == 3 and r[2][2] == true and r[2][3] == true and r[3] == false and r[4] == "extra",
        "count: cloud books counted as true, later values kept")
    r = { Virtual._listing(orig, fc, "/elsewhere") }
    eq(#r[2], 1, "another folder: nothing added")

    -- getPathList (KOReader 2026.07 and later): fills the lists it's given.
    local function porig(_self, _path, collate, dirs, files)
        table.insert(dirs, collate and { path = "/lib/sub" } or true)
        table.insert(files, collate and { path = "/lib/local.epub" } or true)
        return true, "extra"
    end
    local dirs, files = {}, {}
    r = { n = select("#", Virtual._pathListing(porig, fc, "/lib", {}, dirs, files)),
        Virtual._pathListing(porig, fc, "/lib", {}, {}, {}) }
    check(r.n == 2 and r[1] == true and r[2] == "extra", "getPathList: every value returned")
    check(#files == 3 and files[2].path and files[3].path, "getPathList: cloud items added to its files")
    files = {}
    Virtual._pathListing(porig, fc, "/lib", nil, {}, files)
    check(#files == 3 and files[2] == true and files[3] == true, "getPathList count: cloud books counted")
    files = {}
    Virtual._pathListing(porig, fc, "/lib/sub", {}, {}, files)
    eq(#files, 1, "getPathList: another folder, nothing added")
    local shown = 0
    Virtual.listingRebuilding = function() shown = shown + 1 end
    fc.path = "/"
    Virtual._pathListing(porig, fc, "/lib", {}, {}, {})
    eq(shown, 0, "flat view from a folder above: no rebuilding message")
    fc.path = "/lib"
    Virtual._pathListing(porig, fc, "/lib", {}, {}, {})
    eq(shown, 1, "the library shown: rebuilding message")
    Virtual._pathListing(porig, fc, "/lib", nil, {}, {})
    eq(shown, 1, "a count: no message")
    fc.path = nil
    Virtual.listingRebuilding = function() end

    -- getList beside getPathList: ZenOS's flat view walks the library itself
    -- (getPathList never runs for it); the books are added then, once.
    local function zen_flat(_self, _path, collate)
        return {}, { collate and { path = "/lib/local.epub" } or true }, true, "extra"
    end
    local function through_path(self, path, collate)
        local d, f = {}, {}
        local ok_p = Virtual._pathListing(porig, self, path, collate, d, f)
        return d, f, ok_p, "extra"
    end
    r = { Virtual._flatFallback(zen_flat, fc, "/lib", {}) }
    check(#r[2] == 3 and r[2][2].path and r[4] == "extra", "flat fallback: ZenOS's walk, cloud books added")
    r = { Virtual._flatFallback(zen_flat, fc, "/lib") }
    eq(#r[2], 3, "flat fallback: counted too")
    r = { Virtual._flatFallback(through_path, fc, "/lib", {}) }
    eq(#r[2], 3, "getPathList ran: added there only, not again")
    r = { Virtual._flatFallback(through_path, fc, "/lib") }
    eq(#r[2], 3, "getPathList ran: counted once")
    r = { Virtual._flatFallback(zen_flat, fc, "/elsewhere") }
    eq(#r[2], 1, "flat fallback: another folder, nothing added")
    -- A count of the library inside another folder's getList.
    local function nested(self, _path, collate)
        local inner = { Virtual._flatFallback(zen_flat, self, "/lib") }
        local d, f = {}, {}
        Virtual._pathListing(porig, self, "/lib", collate, d, f)
        return d, f, #inner[2]
    end
    r = { Virtual._flatFallback(nested, fc, "/lib", {}) }
    check(#r[2] == 3 and r[3] == 3, "nested getList: each counted once")
    local zen_sources = package.loaded["common/book_sources"]
    zen_sources.booksWithoutFile = function() return {} end
    r = { Virtual._flatFallback(zen_flat, fc, "/lib", {}) }
    eq(#r[2], 1, "ZenOS lists source books in its flat view: not added")
    zen_sources.booksWithoutFile = nil

    -- Counting with something other than true: cloud books left out.
    eq(Virtual._placeholdersIn({ true }, { true }), true, "true placeholders")
    eq(Virtual._placeholdersIn({}, {}), nil, "nothing to tell by")
    eq(Virtual._placeholdersIn({ true }, { { path = "x" } }), false, "an item among them")
    local items = function() return {}, { { path = "/lib/local.epub" } }, true end
    r = { Virtual._listing(items, fc, "/lib") }
    check(#r[2] == 1 and Virtual.count_placeholders == false and Virtual.count_problem,
        "count with items: cloud books not added, problem noted")
    r = { Virtual._listing(orig, fc, "/lib") }
    eq(#r[2], 1, "stays off for the run")
    check(require("athenaeum/library").statusText():find("folder counts leave cloud books out", 1, true),
        "problem in Status")
    Virtual.count_placeholders, Virtual.count_problem = nil, nil

    -- KOReader's own getPathList, with its flat view: walking a folder above
    -- the library reaches the library folder, and the cloud books are listed
    -- there (by full path: a file of the same name elsewhere isn't the book).
    do
        local FileChooser = require("ui/widget/filechooser")
        if type(FileChooser.getPathList) == "function" then
            local top = TMP .. "/flat"
            local lib = top .. "/lib"
            lfs.mkdir(top); lfs.mkdir(lib); lfs.mkdir(top .. "/other")
            local f = io.open(lib .. "/local.epub", "w"); f:write("x"); f:close()
            Virtual.setCatalog(lib, { { id = "f1", title = "Flat", file_stem = "Same", file_ext = "epub" } })
            f = io.open(top .. "/other/Same.epub", "w"); f:write("x"); f:close()
            local probe = setmetatable({ name = "filemanager", is_fm = true, exclude_dirs = {},
                exclude_files = {}, show_unsupported = true, path = top }, { __index = FileChooser })
            probe.getPathList = function(self, ...) return Virtual._pathListing(FileChooser.getPathList, self, ...) end
            local real_flat = FileChooser.show_flat_view
            FileChooser.show_flat_view = true
            local fdirs, ffiles = {}, {}
            local ok_walk, readable = pcall(probe.getPathList, probe, top, {}, fdirs, ffiles)
            FileChooser.show_flat_view = real_flat
            local paths = {}
            for _i, item in ipairs(ok_walk and ffiles or {}) do paths[item.path] = true end
            check(ok_walk and readable == true, "flat view walk: " .. tostring(readable))
            check(paths[lib .. "/Same.epub"] and paths[top .. "/other/Same.epub"] and paths[lib .. "/local.epub"],
                "flat view: the cloud book listed beside a same-named file elsewhere")
            eq(#ffiles, 3, "flat view: three books")
            Virtual.setCatalog(nil, {})
        end
    end

    -- The startup check, with KOReader's own getList on this plugin's folder.
    local FileChooser = require("ui/widget/filechooser")
    eq(Virtual.checkCountPlaceholders(FileChooser), true, "KOReader counts with true")
    eq(Virtual.count_placeholders, true, "so cloud books are counted")
    local fake = { getList = function() return { { path = "/x/sub" } }, {} end }
    eq(Virtual.checkCountPlaceholders(fake, "/x"), false, "a KOReader counting with items: noticed")
    check(Virtual.count_placeholders == false and Virtual.count_problem, "and cloud books not counted")
    Virtual.count_placeholders, Virtual.count_problem = nil, nil
    eq(Virtual.checkCountPlaceholders({ getList = function() error("boom") end }, "/x"), nil,
        "a failing check: trusted")
    eq(Virtual.count_placeholders, nil, "nothing changed")
    Virtual.listingRebuilding = real_rebuilding
    Virtual.setCatalog(nil, {})
end

-- Metadata sorts get cloud books' metadata from the book sources directly ----------

do
    Virtual.setCatalog("/lib/", { { id = "m1", title = "Meta" } })
    local cloud = Virtual.books[1].path
    local zen = package.loaded["common/book_sources"]
    local real_info = zen.bookInfo
    zen.bookInfo = function(path, get_cover)
        if path == cloud and get_cover == false then
            return { title = "Edited", authors = "A", series = "S", series_index = 2,
                language = "en", keywords = "K", description = "D", cover_fetched = "Y" }
        end
    end
    local slow = 0
    local bookinfo = { getDocProps = function(_self, file) slow = slow + 1 return { title = "db " .. file } end }
    local ui = { coverbrowser = {}, bookinfo = bookinfo }
    local got, other
    Virtual._withCloudDocProps(ui, function()
        got = ui.bookinfo:getDocProps(cloud)
        other = ui.bookinfo:getDocProps("/lib/local.epub")
    end)
    check(got and got.title == "Edited" and got.display_title == "Edited" and got.series_index == 2
        and got.description == "D" and got.cover_fetched == nil, "cloud book: the sources' fields")
    eq(other and other.title, "db /lib/local.epub", "local file: asked as before")
    eq(slow, 1, "only the local file reached the slow lookup")
    check(rawget(bookinfo, "getDocProps") ~= nil and bookinfo.getDocProps(bookinfo, cloud).title == "db " .. cloud,
        "put back after the listing")
    check(not pcall(Virtual._withCloudDocProps, ui, function() error("boom") end)
        and bookinfo.getDocProps(bookinfo, cloud).title == "db " .. cloud, "put back after a failed listing too")
    zen.bookInfo = function() return { authors = "A" } end
    Virtual._withCloudDocProps(ui, function() got = ui.bookinfo:getDocProps(cloud) end)
    eq(got.display_title, "Meta", "no title: the file name, as KOReader shows it")
    local plain = { bookinfo = bookinfo } -- no CoverBrowser: KOReader's own lookup
    Virtual._withCloudDocProps(plain, function() got = plain.bookinfo:getDocProps(cloud) end)
    eq(got.title, "db " .. cloud, "without CoverBrowser: not answered")
    zen.bookInfo = real_info
    Virtual.setCatalog(nil, {})
end

-- Cloud books skip the opened (sidecar) and collection (realpath) checks ----------

do
    local Guard = require("athenaeum/guard")
    local BookList = require("ui/widget/booklist")
    local ReadCollection = require("readcollection")
    local real_opened, real_in = BookList.hasBookBeenOpened, ReadCollection.isFileInCollections
    local real_coll = ReadCollection.coll
    local asked = {}
    BookList.hasBookBeenOpened = function(file) asked[#asked + 1] = file return true end
    ReadCollection.isFileInCollections = function(_self, file) asked[#asked + 1] = file return true end
    Virtual.setCatalog("/lib/", { { id = "c1", title = "Cloud" } })
    local cloud = Virtual.books[1].path
    Virtual._installCloudShortcuts()
    asked = {} -- the collections check at install asks once
    check(Guard.ok("library"), "library on")
    eq(BookList.hasBookBeenOpened(cloud), false, "cloud book: never opened")
    eq(BookList.hasBookBeenOpened("/lib/local.epub"), true, "local file: asked as before")
    ReadCollection.coll = { favorites = { [cloud] = { file = cloud } }, other = {} }
    eq(ReadCollection:isFileInCollections(cloud, true), true, "cloud book in a collection")
    ReadCollection.coll = { favorites = {} }
    eq(ReadCollection:isFileInCollections(cloud, true), false, "cloud book in none")
    eq(ReadCollection:isFileInCollections("/lib/local.epub", true), true, "local file: asked as before")
    eq(#asked, 2, "only local files reach KOReader's checks")
    BookList.hasBookBeenOpened, ReadCollection.isFileInCollections = real_opened, real_in
    ReadCollection.coll = real_coll

    -- Collections as the shortcut expects on this KOReader (checked with
    -- KOReader's own functions, on a real file).
    eq(Virtual._checkCollections(ReadCollection, real_in), nil, "collections keyed by file path")
    check(next(ReadCollection.coll or {}) == nil or ReadCollection.coll["athenaeum-check"] == nil,
        "the check leaves the real collections alone")
    -- KOReader keeping them another way: the shortcut isn't installed.
    local real_add = ReadCollection.addItem
    ReadCollection.addItem = function(self, file, name) self.coll[name][#self.coll[name] + 1] = file end
    eq(Virtual._checkCollections(ReadCollection, real_in), "collections aren't tables keyed by file path",
        "changed shape noticed")
    local before = ReadCollection.isFileInCollections
    Virtual.collections_problem = nil
    Virtual._installCloudShortcuts()
    check(ReadCollection.isFileInCollections == before and Virtual.collections_problem ~= nil,
        "changed shape: KOReader's own check kept")
    check(Guard.ok("library"), "changed shape: library still on")
    ReadCollection.addItem = real_add
    eq(Virtual._checkCollections(ReadCollection, function() return false end),
        "isFileInCollections doesn't find a file added to a collection", "lookup change noticed")
    BookList.hasBookBeenOpened, ReadCollection.isFileInCollections = real_opened, real_in
    Virtual.collections_problem = nil
end

-- "Rebuilding library…" while the listing is rebuilt after a catalog change ---------------

do
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    local saved = { show = UIManager.show, close = UIManager.close,
        forceRePaint = UIManager.forceRePaint, nextTick = UIManager.nextTick }
    local shown, closed, ticks = {}, {}, {}
    UIManager.show = function(_self, w) table.insert(shown, w) end
    UIManager.close = function(_self, w) table.insert(closed, w) end
    UIManager.forceRePaint = function() end
    UIManager.nextTick = function(_self, fn) table.insert(ticks, fn) end
    local real_fm = FileManager.instance
    FileManager.instance = {}

    Virtual.setCatalog("/lib", { { id = "r1", title = "One" } })
    Virtual.listingRebuilding() -- whatever earlier tests changed
    shown, closed, ticks = {}, {}, {}
    Virtual.setCatalog("/lib", { { id = "r1", title = "One" } })
    check(not Virtual.listingRebuilding(), "same cloud books: no message")
    Virtual.setCatalog("/lib", { { id = "r1", title = "One" }, { id = "r2", title = "Two" } })
    check(Virtual.listingRebuilding(), "cloud books changed: message")
    eq(#shown, 1, "one message")
    eq(shown[1] and shown[1].text, "Rebuilding library…", "message text")
    eq(#closed, 0, "up while the listing is built")
    for _i, fn in ipairs(ticks) do fn() end
    check(closed[1] ~= nil and closed[1] == shown[1], "closed on the next tick, before the repaint")
    check(not Virtual.listingRebuilding(), "once per change")

    -- ZenOS's Home on top, or the file browser hidden behind it: the
    -- listing is rebuilt out of sight, with no message, and that counts.
    ZenOS.home_on_top = true
    Virtual.setCatalog("/lib", { { id = "r1", title = "One" } })
    check(not Virtual.listingRebuilding(), "Home on top: no message")
    check(not Virtual.listingRebuilding(), "the hidden rebuild counts as the rebuild")
    ZenOS.home_on_top = false
    Virtual.setCatalog("/lib", { { id = "r3", title = "Three" } })
    check(Virtual.listingRebuilding(), "Home not on top: message")
    eq(#shown, 2, "two messages in all")
    FileManager.instance = real_fm
    for k, fn in pairs(saved) do UIManager[k] = fn end
    Virtual.setCatalog(nil, {})
end

-- ZenOS book sources -----------------------------------------------------------------------

do
    local ZenSource = require("athenaeum/zenos_source")
    local Settings = require("athenaeum/settings")
    local db = { getGroupedByTags = function() return {} end }
    local orig_tags = db.getGroupedByTags
    package.loaded["common/db_bookinfo"] = db
    Virtual.setCatalog("/lib", {
        { id = "c1", title = "Cloud One", authors = { "Ann", "Bo" }, series = "Saga", series_index = "2",
          tags = { "x" }, language = "en" },
    })
    local fmu = require("apps/filemanager/filemanagerutil")
    local real_openFile = fmu.openFile
    check(ZenSource.install(Virtual), "registers with ZenOS")
    local source = ZenOS.sources.athenaeum
    check(source ~= nil, "source registered as athenaeum")
    eq(ZenOS.integrated, 1, "ZenOS's metadata integration installed")
    check(ZenSource.install(Virtual) and ZenOS.integrated == 1, "registers once")

    local books = source.books()
    eq(#books, 1, "cloud books listed")
    eq(books[1].file, "/lib/Ann, Bo - Cloud One.epub", "book path")
    local info = books[1].info
    eq(info.authors, "Ann\nBo", "authors joined as in bookinfo")
    eq(info.series_index, 2, "series number")
    eq(info.keywords, "x", "tags as keywords")
    eq(info.language, "en", "language")
    check(source.books() == books, "books cached while the catalog is unchanged")

    check(source.owns("/lib/Ann, Bo - Cloud One.epub") and not source.owns("/lib/a.epub"), "owns cloud books only")

    -- Covers: cloud books are never extracted by CoverBrowser; their
    -- covers are downloaded, and it waits while they are.
    check(source.fetchCovers == nil, "covers aren't ZenOS's to ask for")
    do
        local bim = package.loaded["bookinfomanager"]
        local stub = {}
        stub.extractInBackground = function(self, files) self.extracted = files return "started" end
        stub.isExtractingInBackground = function() return false end
        package.loaded["bookinfomanager"] = stub
        local real_request, real_busy = Virtual.requestCovers, Virtual.coversBusy
        local requested, busy
        Virtual.requestCovers = function(list) requested = list return true end
        Virtual.coversBusy = function() return busy end
        check(Virtual._installBookInfo(), "extraction hooks installed")
        eq(stub:extractInBackground({ { filepath = "/lib/Ann, Bo - Cloud One.epub" }, "/lib/a.epub" }),
            "started", "other paths still extracted")
        check(requested and #requested == 1 and requested[1].path == "/lib/Ann, Bo - Cloud One.epub",
            "the cloud book's cover requested")
        check(#stub.extracted == 1 and stub.extracted[1] == "/lib/a.epub", "only the other path extracted")
        stub.extracted = nil
        check(stub:extractInBackground({ "/lib/Ann, Bo - Cloud One.epub" }) == true and stub.extracted == nil,
            "only cloud books: success, nothing extracted")
        busy = true
        check(stub:isExtractingInBackground(), "CoverBrowser waits while covers download")
        busy = false
        check(not stub:isExtractingInBackground(), "and not after")
        -- Can't download now: shown without a cover for now, ZenOS told.
        Virtual.requestCovers = function() return false end
        ZenOS.changes = {}
        stub:extractInBackground({ "/lib/Ann, Bo - Cloud One.epub" })
        check(Virtual.by_path["/lib/Ann, Bo - Cloud One.epub"].cover_retry_at ~= nil
            and #ZenOS.changes == 1, "offline: retried later, ZenOS told")
        Virtual.by_path["/lib/Ann, Bo - Cloud One.epub"].cover_retry_at = nil
        Virtual.requestCovers, Virtual.coversBusy = real_request, real_busy
        package.loaded["bookinfomanager"] = bim
    end

    -- Cover badges: the icon of the badge the book gets (ZenOS paints it).
    local Badge = require("athenaeum/badge")
    local real_is_cloud = Badge.isCloud
    Badge.isCloud = function(path) return path == "/lib/Ann, Bo - Cloud One.epub" end
    local given = source.badge("/lib/Ann, Bo - Cloud One.epub")
    check(type(given) == "table" and given.icon == Badge.icon("cloud"), "cloud book: cloud badge")
    eq(source.badge("/lib/a.epub"), nil, "other books: no badge")
    Badge.cloud_enabled = false
    eq(source.badge("/lib/Ann, Bo - Cloud One.epub"), nil, "badge setting off: no badge")
    Badge.cloud_enabled = true
    Badge.isCloud = real_is_cloud
    local repaints = 0
    package.loaded["common/book_sources"].statusChanged = function() repaints = repaints + 1 end
    ZenSource.badgesChanged()
    eq(repaints, 1, "badge settings changed: ZenOS repaints")
    package.loaded["common/book_sources"].statusChanged = nil
    local shown, shown_opts
    local real_show = Virtual.showDetails
    Virtual.showDetails = function(path, opts) shown, shown_opts = path, opts end
    check(source.open("/lib/Ann, Bo - Cloud One.epub") == true and shown == "/lib/Ann, Bo - Cloud One.epub", "open shows details")
    shown = nil
    check(not source.open("/lib/a.epub") and shown == nil, "other books not handled")
    check(source.showContextMenu(nil, { path = "/lib/Ann, Bo - Cloud One.epub" }) == true, "long-press shows details")
    check(shown_opts == nil, "long-press elsewhere: no history row")
    check(source.showContextMenu(nil, { path = "/lib/Ann, Bo - Cloud One.epub", _zen_is_history = true,
        _zen_history_path = "/lib/Ann, Bo - Cloud One.epub" }) == true and type(shown_opts) == "table"
        and type(shown_opts.extra_rows) == "function", "long-press on Home's Recently read: history row")
    local history_rows = shown_opts and shown_opts.extra_rows(function() end) or {}
    check(history_rows[1] and history_rows[1][1].text:find("Remove from history", 1, true),
        "Recently read: Remove from history")

    Virtual.showDetails = real_show
    -- ZenOS asks the source wherever a book is opened or long-pressed:
    -- Athenaeum doesn't hook either itself.
    check(fmu.openFile == real_openFile, "openFile not hooked")

    local bi = source.bookInfo("/lib/Ann, Bo - Cloud One.epub", false)
    check(bi and bi.title == "Cloud One" and bi.cover_fetched == "Y", "bookInfo for a cloud book")
    check(source.bookInfo("/lib/a.epub", false) == nil, "bookInfo: nil for other books")

    local key = source.listingKey("/lib")
    check(type(key) == "string" and key ~= "", "listing key for the library folder")
    eq(source.listingKey("/lib/"), key, "trailing slash")
    eq(source.listingKey("/"), key, "parent folders count the books")
    check(source.listingKey("/libx") == nil and source.listingKey("/lib/sub") == nil, "no key for other folders")

    -- Reading status and rating from other devices (Concordance), as the
    -- library gives them (ZenSource.state, tested with Concordance below).
    local real_state = ZenSource.state
    ZenSource.state = function(path)
        return path == "/lib/Ann, Bo - Cloud One.epub" and { status = "complete", rating = 4, finished_at = 1700000000 } or nil
    end
    local st = source.status("/lib/Ann, Bo - Cloud One.epub")
    eq(st.status .. " " .. st.rating, "complete 4", "status and rating of a cloud book")
    eq(st.finished_at, 1700000000, "when it was finished")
    eq(source.status("/lib/a.epub"), nil, "nothing known: nothing given")
    -- Books read elsewhere waiting to go into the history (Concordance).
    local real_history = ZenSource.history
    ZenSource.history = function() return { { file = "/lib/Ann, Bo - Cloud One.epub", time = 1700000000 } } end
    local waiting = source.history()
    eq(#waiting .. " " .. waiting[1].file .. " " .. waiting[1].time, "1 /lib/Ann, Bo - Cloud One.epub 1700000000",
        "history: the books waiting")
    ZenSource.history = function() return nil end
    eq(#source.history(), 0, "history: none known, an empty list")
    ZenSource.history = real_history
    ZenSource.state = function() return nil end
    eq(source.status("/lib/Ann, Bo - Cloud One.epub"), nil, "no state: no status")
    ZenSource.state = real_state
    ZenOS.changes = {}
    local status_changes = 0
    package.loaded["common/book_sources"].statusChanged = function() status_changes = status_changes + 1 end
    local cached_books = source.books()
    ZenSource.statesChanged()
    eq(status_changes, 1, "new states: ZenOS reads the statuses again")
    eq(#ZenOS.changes, 0, "groupings kept")
    check(source.books() == cached_books, "cloud books list kept")
    package.loaded["common/book_sources"].statusChanged = nil

    ZenOS.changes = {}
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two" } })
    check(source.listingKey("/lib") ~= key, "key changes with the catalog")
    local paths = ZenOS.changes[#ZenOS.changes]
    check(type(paths) == "table" and table.concat(paths, " ") == "/lib/Ann, Bo - Cloud One.epub /lib/Cloud Two.epub",
        "ZenOS told of old and new books")
    eq(source.books()[1].file, "/lib/Cloud Two.epub", "books rebuilt after a catalog change")
    local key2 = source.listingKey("/lib")
    ZenOS.changes = {}
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two" } })
    eq(source.listingKey("/lib"), key2, "same catalog, same key (stable across restarts)")
    eq(#ZenOS.changes, 0, "same catalog: ZenOS not told (nothing to redraw)")
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two", language = "fr" },
        { id = "c3", title = "Cloud Three" } })
    paths = ZenOS.changes[#ZenOS.changes]
    check(#ZenOS.changes == 1 and type(paths) == "table"
        and table.concat(paths, " ") == "/lib/Cloud Two.epub /lib/Cloud Three.epub",
        "ZenOS told of a book whose metadata changed (not in the signature) and a new one")
    -- A stored row's lists are split when first read (tags when the book
    -- is drawn): that isn't a change.
    local row_mt = { __index = function(book, key)
        if key == "tags" then
            local list = { rawget(book, "_tags") }
            rawset(book, key, list)
            return list
        end
    end }
    local function rows()
        return { setmetatable({ id = "c2", title = "Cloud Two", _tags = "Fantasy" }, row_mt) }
    end
    Virtual.setCatalog("/lib", rows())
    local _tags = Virtual.books[1].tags
    ZenOS.changes = {}
    Virtual.setCatalog("/lib", rows())
    eq(#ZenOS.changes, 0, "tags read on the old row: no change")
    Virtual.setCatalog("/lib", { { id = "c2", title = "Cloud Two" } })

    -- Covers arriving: ZenOS drops its cached covers.
    ZenOS.changes = {}
    Covers.on_arrived({ Virtual.books[1] })
    check(ZenOS.changes[1] and ZenOS.changes[1][1] == "/lib/Cloud Two.epub", "cover arrival reported")

    -- ZenOS waits for every book it asked covers for: books queued behind a
    -- batch whose download can't start are reported too, retried soon.
    do
        local ffiutil = require("ffi/util")
        local UIManager = require("ui/uimanager")
        local real = { ffiutil.isSubProcessDone, ffiutil.readAllFromFD, ffiutil.runInSubProcess,
            UIManager.scheduleIn, Covers.on_arrived, Covers.config }
        ffiutil.isSubProcessDone = function() return true end
        ffiutil.readAllFromFD = function()
            return require("dump")({ results = { a = { file = "a/a.webp", w = 10, h = 15 } } })
        end
        ffiutil.runInSubProcess = function() return nil, "no fork" end
        UIManager.scheduleIn = function() end
        Covers.config = { dir = "/covers" }
        local done = { id = "a", path = "/lib/A.epub" }
        local queued = { id = "b", path = "/lib/B.epub" }
        local reported
        Covers.on_arrived = function(books) reported = books end
        Covers.job = { pid = 1, fd = 1, books = { done }, started = require("athenaeum/timing").start() }
        Covers.pending, Covers.pending_count = { b = queued }, 1
        Covers.poll()
        check(reported and #reported == 2 and reported[1] == done and reported[2] == queued,
            "unstarted batch reported with the finished one")
        check(done.cover == "/covers/a/a.webp" and queued.cover_retry_at ~= nil and not Covers.busy(),
            "finished cover kept, queued one retried soon, not busy")
        ffiutil.isSubProcessDone, ffiutil.readAllFromFD, ffiutil.runInSubProcess = real[1], real[2], real[3]
        UIManager.scheduleIn, Covers.on_arrived, Covers.config = real[4], real[5], real[6]
        Covers.pending, Covers.pending_count = {}, 0
    end

    -- ZenOS's tag groups are left alone.
    check(db.getGroupedByTags == orig_tags, "tags not hooked")

    check(ZenSource.moved == nil, "ZenOS's moved() isn't used")

    package.loaded["common/db_bookinfo"] = nil
    Virtual.setCatalog(nil, {})
end

-- Concordance: what it's told, and the state it gives back -------------------------------------

do
    local Library = require("athenaeum/library")
    local Virtual = require("athenaeum/virtual")
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
    local ZenSource_history = require("athenaeum/zenos_source").history
    eq(#ZenSource_history(), 0, "no Concordance: no books waiting for the history")
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
    eq(#ZenSource_history(), 0, "older Concordance: no books waiting for the history")
    package.loaded["concordance/identity"].pendingHistory = function()
        return { { file = "/lib/cloud-a.epub", time = 1700000000 } }
    end
    eq(ZenSource_history()[1].file, "/lib/cloud-a.epub", "books waiting for the history, from Concordance")
    package.loaded["concordance/identity"].pendingHistory = nil
    check(listener and listener[1] == "athenaeum", "listens for Concordance's changes")
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
    local ZenSource = require("athenaeum/zenos_source")
    local Badge = require("athenaeum/badge")
    local real_by_path = Virtual.by_path
    Virtual.by_path = { ["/lib/cloud-a.epub"] = { id = A_ID } }
    eq(ZenSource.state("/lib/cloud-a.epub").status, "reading", "ZenOS gets the cloud book's state")
    eq(Badge.kind("/lib/cloud-a.epub"), "cloud", "the badge shows no state")
    eq(ZenSource.state("/lib/elsewhere.epub"), nil, "no state for books not in the catalog")
    -- The library's downloaded books (ZenOS asks only while they have no
    -- sidecar here): their catalog book's state, with the rating.
    states[A_ID] = { status = "complete", status_at = 1700000000, rating = 5 }
    local st = ZenSource.state("/lib/a.epub")
    eq(st and (st.status .. " " .. st.rating), "complete 5", "a matched file gets its book's state")
    eq(st.finished_at, 1700000000, "finished: the status's date")
    states[A_ID] = { status = "reading", status_at = 1700000000 }
    eq(ZenSource.state("/lib/a.epub").finished_at, nil, "not finished: no date")
    states[A_ID] = { status = "complete", rating = 5 }
    Library.copies = { ["/lib/a copy.epub"] = A_ID }
    Library.on_device["/lib/a copy.epub"] = true
    eq(ZenSource.state("/lib/a copy.epub").status, "complete", "a second copy too")
    states[A_ID] = { rating = 3 }
    eq(ZenSource.state("/lib/a.epub").rating, 3, "a rating alone")
    states[A_ID] = { last_read = t }
    eq(ZenSource.state("/lib/a.epub"), nil, "neither status nor rating: nothing")
    states[A_ID] = { status = "reading" }
    Library.unmatch({ "/lib/a.epub" })
    eq(ZenSource.state("/lib/a.epub"), nil, "unmatched (deleted): nothing")
    Library.restoreMatched({ ["/lib/a.epub"] = A_ID }) -- the file isn't really there
    eq(ZenSource.state("/lib/a.epub"), nil, "not restored without its file")
    Library.on_device["/lib/a copy.epub"], Library.copies = nil, nil
    -- A cloud book's status, set from its details (Concordance): a "Read
    -- status" row opening a menu drawn like ZenOS's.
    local full = { title = "By UUID", authors = { "Ann" } }
    local plain = #Library.detailsButtons(A_ID, full, function() end)
    local sets = {}
    package.loaded["concordance/identity"].setBookState = function(id, values, info)
        sets[#sets + 1] = { id = id, values = values, info = info }
        return 1
    end
    states[A_ID] = { status = "reading", rating = 3 }
    local closed = 0
    local rows = Library.detailsButtons(A_ID, full, function() closed = closed + 1 end)
    eq(#rows, plain + 1, "with Concordance: one Read status row (no rating row)")
    check(rows[#rows][1].text:find("Read status", 1, true) ~= nil and rows[#rows][1].align == "left",
        "the Read status row")
    local menu_closed = 0
    local function closeMenu() menu_closed = menu_closed + 1 end
    local srows = Library.statusRows(A_ID, full, closeMenu)
    local function label(i) return (srows[i][1].text:gsub("^[^%w]*%s%s", "")) end
    eq(#srows, 4, "four statuses, one per row")
    eq(label(1) .. "|" .. label(2) .. "|" .. label(3) .. "|" .. label(4),
        "Unread|Reading  ✓|On hold|Finished", "status rows, the current one ticked")
    check(srows[2][1].enabled == false and srows[4][1].enabled ~= false and srows[1][1].align == "left",
        "the current status can't be chosen again")
    srows[4][1].callback()
    eq(sets[1].id .. " " .. sets[1].values.status .. " " .. sets[1].info.title .. " " .. sets[1].info.authors[1],
        A_ID .. " complete By UUID Ann", "finished: set in Concordance, with the book's title and authors")
    eq(menu_closed, 1, "the menu closed")
    srows[1][1].callback()
    eq(sets[2].values.status, false, "unread: the status cleared")
    states[A_ID] = nil
    srows = Library.statusRows(A_ID, full, closeMenu)
    check(label(1) == "Unread  ✓" and srows[1][1].enabled == false and srows[2][1].enabled ~= false,
        "nothing known: unread")
    local notified = {}
    local real_notification = package.loaded["ui/widget/notification"]
    package.loaded["ui/widget/notification"] = {
        SOURCE_ALWAYS_SHOW = 1, notify = function(_self, text) notified[#notified + 1] = text end,
    }
    package.loaded["concordance/identity"].setBookState = function() return nil, "disk full" end
    srows[2][1].callback()
    eq(notified[1], "Couldn't save the book's status.", "a failure is reported")
    package.loaded["concordance/identity"].setBookState = function() error("Concordance bug") end
    srows[2][1].callback()
    eq(#notified, 2, "an error too")
    eq(menu_closed, 4, "the menu closed each time")
    package.loaded["ui/widget/notification"] = real_notification
    package.loaded["concordance/identity"].setBookState = nil
    -- Downloading from the details: one format, a plain row; several, a
    -- "Download" row opening a menu of them, the preferred first.
    local real_download = Library.download
    local downloads = {}
    Library.download = function(id, opts) downloads[#downloads + 1] = { id = id, ext = opts.ext, open = opts.open } end
    local one = Library.detailsButtons(A_ID, { formats = { { href = "/x/a.epub" } } }, function() end)
    check(not one[1][1].text:find("\u{E841}", 1, true) and one[1][1].text:find("Download", 1, true)
        and one[1][1].align == "left", "one format: a plain Download row")
    one[1][1].callback()
    eq(downloads[1] and downloads[1].ext, "epub", "one format: downloaded")
    local formats = { { href = "/x/a.pdf" }, { href = "/x/a.epub" }, { href = "/x/a.mobi" } }
    local several = Library.detailsButtons(A_ID, { formats = formats }, function() end)
    check(several[2][1].text:find("Download & read", 1, true) ~= nil, "Download & read second")
    several[2][1].callback()
    check(downloads[2].ext == "epub" and downloads[2].open, "Download & read: the preferred format")
    check(not several[3] or not several[3][1].text:find("Download", 1, true), "no row per format on the sheet")
    local fclosed = 0
    local frows = Library.formatRows(A_ID, require("athenaeum/downloads").choices(formats),
        function() fclosed = fclosed + 1 end)
    local function flabel(i) return (frows[i][1].text:gsub("^[^%w]*%s%s", "")) end
    eq(#frows, 3, "a row per format")
    eq(flabel(1) .. "|" .. flabel(2) .. "|" .. flabel(3), "EPUB|PDF|MOBI", "the preferred first")
    check(frows[1][1].align == "left", "left-aligned, as ZenOS's menus")
    frows[2][1].callback()
    check(fclosed == 1 and downloads[3].ext == "pdf" and not downloads[3].open, "a format chosen: menu closed, downloaded")
    Library.download = real_download
    package.loaded["concordance/identity"].bookState = function() error("boom") end
    eq(Virtual.stateText(A_ID), nil, "a Concordance error leaves the line out")
    eq(ZenSource.state("/lib/cloud-a.epub"), nil, "a Concordance error leaves the status out")
    Virtual.by_path = real_by_path
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

-- Catalog metadata for downloaded books: over the file's own, under custom
-- metadata; CoverBrowser's cached rows brought up to date.

do
    local Library = require("athenaeum/library")
    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local real_extend = BookInfo.extendProps
    local folder = TMP .. "/catalogmeta"
    lfs.mkdir(folder)
    Library.save("folder", folder)
    local book, mine, other = folder .. "/Ann - Old.epub", folder .. "/Mine.epub", TMP .. "/elsewhere/Old.epub"
    local saved = { Library.catalog, Library.matched, Library.copies, Library.on_device }
    Library.catalog = {
        { id = "m1", title = "New Title", authors = { "Ann", "Bo" }, series = "Saga", tags = { "gothic", "classic" } },
        { id = "m2", title = "Catalog Mine", authors = { "Cy" }, series = "Other", series_index = 2 },
    }
    Library.matched = { m1 = book, m2 = mine }
    Library.copies = {}
    Library.on_device = { [book] = true, [mine] = true }
    os.execute("mkdir -p '" .. folder .. "/Mine.sdr'")
    local f = io.open(folder .. "/Mine.sdr/custom_metadata.lua", "w")
    f:write('return { custom_props = { title = "My Title" } }\n')
    f:close()

    Library.installCatalogMetadataHook()
    check(BookInfo.extendProps ~= real_extend, "extendProps hooked")
    local own = { title = "Old", authors = "Ann", series = "Saga", series_index = 3, language = "en",
                  keywords = "fiction", pages = 10 }
    local p = BookInfo.extendProps(own, book)
    eq(p.title, "New Title", "catalog title over the file's")
    eq(p.authors, "Ann\nBo", "catalog authors")
    eq(p.keywords, "gothic\nclassic", "catalog tags as keywords")
    eq(p.series_index, 3, "no series number in the catalog: the file's")
    eq(p.language, "en", "the file's language kept")
    eq(p.pages, 10, "pages kept")
    eq(own.title, "Old", "the file's props not changed")
    p = BookInfo.extendProps({ title = "Mine (file)", series_index = 7 }, mine)
    eq(p.title, "My Title", "custom metadata over the catalog")
    eq(p.authors, "Cy", "catalog authors under no override")
    eq(p.series_index, 2, "the catalog's series number")
    eq(BookInfo.extendProps({ title = "Old" }, other).title, "Old", "books outside the library: their own")
    eq(BookInfo.extendProps({ title = "Old" }).title, "Old", "no path: their own")

    -- CoverBrowser's cached rows (a stand-in: path -> row).
    local rows = {
        [book] = { title = "Old", authors = "Ann", series = "Saga", series_index = 3, keywords = "fiction" },
        [mine] = { title = "My Title", authors = "Cy", series = "Other", series_index = 2 },
        [folder .. "/Unmatched.epub"] = { title = "U", authors = "U" },
    }
    local set_calls = {}
    local bim = {
        openDbConnection = function() end,
        setBookInfoProperties = function(_self, path, props)
            set_calls[#set_calls + 1] = path
            for k, v in pairs(props) do rows[path][k] = v end
        end,
        db_conn = { prepare = function()
            local list, i, stmt = {}, 0, {}
            function stmt:bind(n, prefix)
                for path, r in pairs(rows) do
                    if path:sub(1, n) == prefix then
                        local dir, name = path:match("^(.*/)([^/]+)$")
                        list[#list + 1] = { dir, name, r.title, r.authors, r.series, r.series_index, r.keywords }
                    end
                end
                return self
            end
            function stmt:step(out)
                i = i + 1
                if not list[i] then return nil end
                for k = 1, 7 do out[k] = list[i][k] end
                return out
            end
            function stmt:close() end
            return stmt
        end },
    }
    ZenOS.changes = {}
    local updated = Library.refreshCatalogMetadata(bim)
    eq(table.concat(updated, " "), book, "only the out-of-date row updated")
    eq(rows[book].title .. "|" .. rows[book].authors .. "|" .. rows[book].keywords,
        "New Title|Ann\nBo|gothic\nclassic", "row brought up to the catalog")
    eq(rows[book].series_index, 3, "the file's series number left")
    eq(rows[mine].title, "My Title", "custom title left in the row")
    eq(rows[folder .. "/Unmatched.epub"].title, "U", "files not in the catalog left")
    check(ZenOS.changes[1] and ZenOS.changes[1][1] == book, "ZenOS told of the changed book")
    set_calls = {}
    eq(#Library.refreshCatalogMetadata(bim), 0, "up to date: nothing written")
    eq(#set_calls, 0, "no writes the second time")
    eq(#Library.refreshCatalogMetadata({}), 0, "no CoverBrowser: nothing done")

    BookInfo.extendProps = real_extend
    Library.catalog, Library.matched, Library.copies, Library.on_device = unpack(saved)
end

-- The menu: groups in order, every entry explained.

do
    local Library = require("athenaeum/library")
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
        "Quick sync now | Full sync now | Download missing covers | Refresh all covers | Quick sync automatically | Full sync | Catalog | Folder"
        .. " | Mark cloud books | Mark books on this device | Mark books not in the catalog"
        .. " | Include cloud books in file search | Status | Timings",
        "menu")
    for _i, item in ipairs(items) do
        if item.text == "Include cloud books in file search" then
            check(item.separator, "display group ends after file search")
        end
    end
end

io.stdout:write(string.format("athenaeum: %d checks, %d failures\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
