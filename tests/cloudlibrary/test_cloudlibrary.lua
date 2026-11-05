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
package.path = REPO .. "/cloudlibrary.koplugin/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Feed = require("cloudlibrary/feed")
local Store = require("cloudlibrary/store")
local Sync = require("cloudlibrary/sync")
local Matcher = require("cloudlibrary/matcher")
local Virtual = require("cloudlibrary/virtual")

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

    -- Quick sync: nothing new costs two requests (stats + nothing else).
    newSync(store, server, 4000):full()
    local s = newSync(store, server)
    local q = s:quick()
    eq(q.added, 0, "quick: nothing new")
    check(not q.needs_full, "quick: no full sync needed")
    eq(s.requests, 1, "quick when counts match: one request")

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
    eq(again:count(), 12, "data persists")
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
