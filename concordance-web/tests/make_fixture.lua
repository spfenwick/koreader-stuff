--[[--
Writes a sample Concordance Reading/ folder: two devices, a year of readings,
highlights, book data, collections, history and book identity (two editions
of one book), in the plugin's own segment formats. Also one corrupt file.

    luajit tests/make_fixture.lua <Reading folder>

Needs the same environment as ingest.lua (CONCORDANCE_LIB, KOREADER_BASE,
KOREADER_STATS).
--]]

local script_dir = (arg[0]:match("^(.*)/") or ".")
package.path = script_dir .. "/../ingest/?.lua;" .. package.path
require("koreader")
local lfs = require("lfs")
local Codec = require("concordance/codec")
local AnnFormat = require("concordance/annformat")
local BookFormat = require("concordance/bookformat")
local IdFormat = require("concordance/idformat")
local Zstd = require("concordance/zstd")
local md5 = require("ffi/sha2").md5

local out = assert(arg[1], "usage: luajit make_fixture.lua <Reading folder>")
os.execute("rm -rf '" .. out .. "' && mkdir -p '" .. out .. "/devices'")

-- Deterministic random numbers.
local seed = 42
local function rand(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % n
end

local BOOKS = {
    { key = "pride", title = "Pride and Prejudice", authors = "Jane Austen", pages = 380, kind = "rolling",
      uuid = "1a2b3c4d-0000-4000-8000-000000000001", series = nil },
    { key = "pride2", title = "Pride & Prejudice (Annotated)", authors = "Jane Austen", pages = 412, kind = "rolling",
      uuid = "1a2b3c4d-0000-4000-8000-000000000001",
      -- The file's own metadata still says the plain title: files that share one
      -- UUID are only joined when their titles agree (or more than the UUID matches).
      id_title = "Pride and Prejudice" },
    { key = "moby", title = "Moby-Dick; or, The Whale", authors = "Herman Melville", pages = 720, kind = "rolling",
      uuid = "1a2b3c4d-0000-4000-8000-000000000002" },
    { key = "frank", title = "Frankenstein", authors = "Mary Wollstonecraft Shelley", pages = 280, kind = "rolling",
      uuid = "1a2b3c4d-0000-4000-8000-000000000003" },
    { key = "origin", title = "On the Origin of Species", authors = "Charles Darwin", pages = 502, kind = "paging",
      uuid = nil },
    { key = "dune", title = "Middlemarch", authors = "George Eliot", pages = 880, kind = "rolling",
      uuid = "1a2b3c4d-0000-4000-8000-000000000005", series = nil },
    -- An older copy of Frankenstein no device has an identity record for:
    -- joined by title and authors.
    { key = "frank_old", title = "Frankenstein", authors = "Mary Wollstonecraft Shelley", pages = 300,
      kind = "rolling", uuid = nil },
    -- A PDF of Moby-Dick, which Cloud library matched to the catalog book:
    -- joined through a link record.
    { key = "moby_pdf", title = "Moby Dick", authors = "Herman Melville", pages = 600, kind = "paging",
      uuid = nil, link = "1a2b3c4d-0000-4000-8000-000000000002" },
}
for _, b in ipairs(BOOKS) do b.md5 = md5(b.key) end
local by = {}
for _, b in ipairs(BOOKS) do by[b.key] = b end

local QUOTES = {
    pride = {
        { 1, "Chapter 1", "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife." },
        { 3, "Chapter 3", "She is tolerable; but not handsome enough to tempt me.", "Darcy at his worst." },
        { 5, "Chapter 5", "Vanity and pride are different things, though the words are often used synonymously." },
        { 11, "Chapter 11", "I declare after all there is no enjoyment like reading!" },
        { 34, "Chapter 34", "In vain have I struggled. It will not do. My feelings will not be repressed.", "The first proposal." },
        { 58, "Chapter 58", "I cannot fix on the hour, or the spot, or the look or the words, which laid the foundation." },
    },
    moby = {
        { 1, "Loomings", "Call me Ishmael." },
        { 1, "Loomings", "Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly November in my soul…", "Same." },
        { 36, "The Quarter-Deck", "Speak not to me of blasphemy, man; I'd strike the sun if it insulted me." },
        { 42, "The Whiteness of the Whale", "It was the whiteness of the whale that above all things appalled me." },
    },
    frank = {
        { 4, "Letter 4", "Nothing is so painful to the human mind as a great and sudden change." },
        { 5, "Chapter 5", "I had desired it with an ardour that far exceeded moderation; but now that I had finished, the beauty of the dream vanished.", "Victor regrets." },
        { 10, "Chapter 10", "Beware; for I am fearless, and therefore powerful." },
    },
    origin = {
        { 12, "Introduction", "I am convinced that Natural Selection has been the main but not exclusive means of modification." },
        { 489, "Recapitulation and Conclusion", "There is grandeur in this view of life, with its several powers.", "The famous last paragraph." },
    },
    dune = {
        { 2, "Prelude", "Who that cares much to know the history of man, and how the mysterious mixture behaves under the varying experiments of Time…" },
        { 86, "Finale", "For the growing good of the world is partly dependent on unhistoric acts." },
    },
}

local DEVICES = {
    { id = "a1f3c09e2b7d4e15", name = "Kobo Libra 2" },
    { id = "7c2e91d04f6a3b88", name = "Pixel 8" },
}

local NOW = 1794000000 -- 2026-11-07
local DAY = 86400

local function writeSegment(dev, name, lines)
    local dir = out .. "/devices/" .. dev.id
    lfs.mkdir(dir)
    local plain = dir .. "/" .. name .. ".plain"
    local f = assert(io.open(plain, "wb"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    assert(Zstd.compressFile(plain, dir .. "/" .. name))
    os.remove(plain)
end

local function writeMeta(dev)
    local f = assert(io.open(out .. "/devices/" .. dev.id .. "/meta.json", "wb"))
    f:write(Codec.encode{ deviceId = dev.id, deviceName = dev.name, schema = 1, createdAt = NOW })
    f:close()
end

-- Statistics: which book was read when. Each device reads some books.
local plan = {
    { dev = 1, book = "pride", from = 380, to = 300 },
    { dev = 2, book = "pride2", from = 290, to = 250 },
    { dev = 1, book = "moby", from = 240, to = 120 },
    { dev = 2, book = "moby", from = 130, to = 90 },
    { dev = 1, book = "frank", from = 85, to = 60 },
    { dev = 2, book = "origin", from = 70, to = 30 },
    { dev = 1, book = "dune", from = 25, to = 0 },
    { dev = 2, book = "frank_old", from = 110, to = 95 },
    { dev = 2, book = "moby_pdf", from = 600, to = 590 },
}
local events = { {}, {} } -- per device: list of lines
local books_used = { {}, {} }
for _, p in ipairs(plan) do
    local b = by[p.book]
    local page = 1
    for d = p.from, p.to, -1 do
        if rand(10) < 7 and page < b.pages then
            local hour = ({ 7, 12, 21, 22, 23 })[rand(5) + 1]
            local t = NOW - d * DAY + hour * 3600 + rand(1800)
            local n = 5 + rand(30)
            for _ = 1, n do
                if page >= b.pages then break end
                local dur = 20 + rand(90)
                table.insert(events[p.dev], Codec.eventLine(b.md5, page, t, dur, b.pages))
                t = t + dur + rand(5)
                page = page + 1
            end
            books_used[p.dev][b.key] = math.max(books_used[p.dev][b.key] or 0, t)
        end
    end
end

for i, dev in ipairs(DEVICES) do
    lfs.mkdir(out .. "/devices/" .. dev.id)
    writeMeta(dev)
    -- Statistics, in two segments.
    local lines = events[i]
    local half = math.floor(#lines / 2)
    for s = 1, 2 do
        local part = {}
        for j = (s == 1 and 1 or half + 1), (s == 1 and half or #lines) do part[#part + 1] = lines[j] end
        local body, nbooks = {}, 0
        body[1] = Codec.headerLine(dev.id, NOW)
        local listed = {}
        for _, l in ipairs(part) do
            local m = l:match('"md5":"(%x+)"')
            if not listed[m] then
                listed[m] = true
                for _, b in ipairs(BOOKS) do
                    if b.md5 == m then
                        body[#body + 1] = Codec.bookLine{ md5 = b.md5, title = b.title, authors = b.authors,
                            pages = b.pages, last_open = books_used[i][b.key] or NOW }
                        nbooks = nbooks + 1
                    end
                end
            end
        end
        for _, l in ipairs(part) do body[#body + 1] = l end
        body[#body + 1] = Codec.trailerLine(nbooks, #part)
        writeSegment(dev, Codec.segmentName(s), body)
    end
end

-- Annotations: device 1 makes most; device 2 those for its books.
local function ann(dev, list_books, seq)
    local body = { AnnFormat.headerLine(dev.id, NOW) }
    local nb, nr = 0, 0
    for _, key in ipairs(list_books) do
        local b = by[key]
        body[#body + 1] = AnnFormat.bookLine{ md5 = b.md5, title = b.title, authors = b.authors }
        nb = nb + 1
        for qi, q in ipairs(QUOTES[key == "pride2" and "pride" or key] or {}) do
            local dt = os.date("!%Y-%m-%d %H:%M:%S", NOW - (300 - qi * 20 - rand(10)) * DAY)
            local f
            if b.kind == "paging" then
                f = { datetime = dt, drawer = "lighten", color = "yellow", text = q[3], chapter = q[2], page = q[1],
                      pos0 = { x = 72, y = 100 + qi * 40, page = q[1] }, pos1 = { x = 400, y = 120 + qi * 40, page = q[1] },
                      note = q[4] }
            else
                local xp = string.format("/body/DocFragment[%d]/body/div/p[%d]/text().%d", q[1] + 2, 3 + qi, 10 * qi)
                f = { datetime = dt, drawer = qi % 3 == 0 and "underscore" or "lighten",
                      color = ({ "yellow", "green", "blue", "red" })[qi % 4 + 1],
                      text = q[3], chapter = q[2], page = xp, pos0 = xp,
                      pos1 = xp:gsub("%.(%d+)$", function(n) return "." .. (tonumber(n) + #q[3]) end),
                      note = q[4] }
            end
            body[#body + 1] = AnnFormat.recordLine{ md5 = b.md5, kind = b.kind, key = dt,
                updated = NOW - (300 - qi * 20) * DAY, device = dev.id, fields_json = AnnFormat.fieldsJson(f) }
            nr = nr + 1
        end
        -- A page bookmark.
        local dt = os.date("!%Y-%m-%d %H:%M:%S", NOW - 50 * DAY)
        local page = b.kind == "paging" and 120 or "/body/DocFragment[20]/body/div/p[1]"
        body[#body + 1] = AnnFormat.recordLine{ md5 = b.md5, kind = b.kind, key = dt, updated = NOW - 50 * DAY,
            device = dev.id, fields_json = AnnFormat.fieldsJson{ datetime = dt, page = page, text = "Page bookmark",
            chapter = "Bookmarked chapter" } }
        nr = nr + 1
    end
    body[#body + 1] = AnnFormat.trailerLine(nb, nr)
    writeSegment(dev, AnnFormat.segmentName(seq), body)
end
ann(DEVICES[1], { "pride", "moby", "frank", "dune" }, 1)
ann(DEVICES[2], { "pride2", "origin" }, 1)

-- Device 2 later removes Frankenstein's bookmark (a deletion record).
do
    local b = by.frank
    local bm = os.date("!%Y-%m-%d %H:%M:%S", NOW - 50 * DAY)
    writeSegment(DEVICES[2], AnnFormat.segmentName(2), {
        AnnFormat.headerLine(DEVICES[2].id, NOW),
        AnnFormat.bookLine{ md5 = b.md5, title = b.title, authors = b.authors },
        AnnFormat.recordLine{ md5 = b.md5, kind = "rolling", key = bm, updated = NOW - 10 * DAY, device = DEVICES[2].id },
        AnnFormat.trailerLine(1, 1),
    })
end

-- Book data.
local function prop(md5_, p, v, upd, dev)
    return BookFormat.recordLine{ md5 = md5_, prop = p, updated = upd, device = dev.id,
        value_json = v ~= nil and AnnFormat.encodeValue(v) or nil }
end
do
    local d1, d2 = DEVICES[1], DEVICES[2]
    local body = { BookFormat.headerLine(d1.id, NOW) }
    local recs = {}
    local function add(r) recs[#recs + 1] = r end
    local books = { "pride", "moby", "frank", "dune" }
    for _, k in ipairs(books) do body[#body + 1] = BookFormat.bookLine{ md5 = by[k].md5, title = by[k].title, authors = by[k].authors } end
    body[#body + 1] = BookFormat.bookLine{ md5 = BookFormat.COLLECTIONS }
    add(prop(by.pride.md5, "status", "complete", NOW - 300 * DAY, d1))
    add(prop(by.pride.md5, "rating", 5, NOW - 300 * DAY, d1))
    add(prop(by.pride.md5, "note", "Funnier than I remembered. Mr Collins steals every scene he is in.", NOW - 299 * DAY, d1))
    add(prop(by.pride.md5, "hist", books_used[1].pride, books_used[1].pride, d1))
    add(prop(by.moby.md5, "status", "abandoned", NOW - 95 * DAY, d1))
    add(prop(by.moby.md5, "rating", 3, NOW - 95 * DAY, d1))
    add(prop(by.moby.md5, "hist", books_used[1].moby, books_used[1].moby, d1))
    add(prop(by.frank.md5, "status", "complete", NOW - 60 * DAY, d1))
    add(prop(by.frank.md5, "rating", 4, NOW - 60 * DAY, d1))
    add(prop(by.frank.md5, "hist", books_used[1].frank, books_used[1].frank, d1))
    add(prop(by.dune.md5, "status", "reading", NOW - 25 * DAY, d1))
    add(prop(by.dune.md5, "hist", books_used[1].dune, books_used[1].dune, d1))
    add(prop(by.dune.md5, "meta.series", "Penguin Classics", NOW - 25 * DAY, d1))
    add(prop(by.dune.md5, "meta.series_index", 2, NOW - 25 * DAY, d1))
    add(prop(by.dune.md5, "meta.keywords", "Victorian\nProvincial life", NOW - 25 * DAY, d1))
    add(prop(by.pride.md5, "coll.favorites", true, NOW - 300 * DAY, d1))
    add(prop(by.frank.md5, "coll.favorites", true, NOW - 60 * DAY, d1))
    add(prop(by.pride.md5, "coll.5f1d2c3b4a596877", true, NOW - 200 * DAY, d1))
    add(prop(by.frank.md5, "coll.5f1d2c3b4a596877", true, NOW - 200 * DAY, d1))
    add(prop(by.dune.md5, "coll.5f1d2c3b4a596877", true, NOW - 20 * DAY, d1))
    add(prop(BookFormat.COLLECTIONS, "coll.5f1d2c3b4a596877", { name = "19th century" }, NOW - 200 * DAY, d1))
    add(prop(BookFormat.COLLECTIONS, "coll.favorites", { name = "Favorites" }, NOW - 300 * DAY, d1))
    for _, r in ipairs(recs) do body[#body + 1] = r end
    body[#body + 1] = BookFormat.trailerLine(#books + 1, #recs)
    writeSegment(d1, BookFormat.segmentName(1), body)

    -- Device 2: the annotated edition (a version of Pride and Prejudice) and Darwin.
    local body2 = { BookFormat.headerLine(d2.id, NOW),
        BookFormat.bookLine{ md5 = by.pride2.md5, title = by.pride2.title, authors = by.pride2.authors },
        BookFormat.bookLine{ md5 = by.origin.md5, title = by.origin.title, authors = by.origin.authors } }
    local r2 = {
        prop(by.pride2.md5, "hist", books_used[2].pride2, books_used[2].pride2, d2),
        prop(by.origin.md5, "status", "complete", NOW - 30 * DAY, d2),
        prop(by.origin.md5, "rating", 4, NOW - 30 * DAY, d2),
        prop(by.origin.md5, "note", "Dense, but the final chapter is worth everything before it.", NOW - 30 * DAY, d2),
        prop(by.origin.md5, "hist", books_used[2].origin, books_used[2].origin, d2),
        prop(by.moby.md5, "hist", books_used[2].moby, books_used[2].moby, d2),
    }
    table.insert(body2, 3, BookFormat.bookLine{ md5 = by.moby.md5, title = by.moby.title, authors = by.moby.authors })
    for _, r in ipairs(r2) do body2[#body2 + 1] = r end
    body2[#body2 + 1] = BookFormat.trailerLine(3, #r2)
    writeSegment(d2, BookFormat.segmentName(1), body2)
end

-- Book identity: every rolling book has a UUID; pride and pride2 share one.
for i, dev in ipairs(DEVICES) do
    local body = { IdFormat.headerLine(dev.id, NOW) }
    local n = 0
    for _, b in ipairs(BOOKS) do
        local mine = (i == 1 and b.key ~= "pride2" and b.key ~= "origin") or (i == 2 and (b.key == "pride2" or b.key == "origin" or b.key == "moby"))
        if mine and b.uuid then
            body[#body + 1] = IdFormat.recordLine{ md5 = b.md5, src = "file", uuids = { b.uuid }, sig = md5(b.key .. "sig"),
                title = b.id_title or b.title, authors = b.authors }
            n = n + 1
        end
        if i == 2 and b.link then
            body[#body + 1] = IdFormat.recordLine{ md5 = b.md5, src = "link", uuids = { b.link },
                title = b.title, authors = b.authors }
            n = n + 1
        end
    end
    body[#body + 1] = IdFormat.trailerLine(n)
    writeSegment(dev, IdFormat.segmentName(1), body)
end

-- A corrupt file, which the ingester should record as bad and move past.
do
    local f = assert(io.open(out .. "/devices/" .. DEVICES[2].id .. "/" .. Codec.segmentName(3), "wb"))
    f:write("not zstd")
    f:close()
end

print("fixture written to " .. out)
