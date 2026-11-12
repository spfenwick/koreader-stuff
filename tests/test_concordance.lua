-- Unit tests for concordance.koplugin: the segment codec, the merge, book
-- identity, the export diff, segment validation, the network job against an
-- in-memory server, and the engine's one-at-a-time rule.
--
-- Statistics databases are created and written by KOReader's own
-- statistics.koplugin code (see tests/concordance/support.lua).
-- Run through scripts/test-statsync.sh, which sets KOREADER_SRC.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local Codec = require("concordance/codec")
local Store = require("concordance/store")
local NetJob = require("concordance/netjob")
local Engine = require("concordance/engine")
local WebDav = require("concordance/webdav")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set")
S.rmrf(TMP)
S.mkdirp(TMP)

-- Codec ------------------------------------------------------------------------

do
    local samples = {
        "plain", "", "Ünïcødé — “quotes” 日本語 😀", 'quote " backslash \\ slash /',
        "tab\tnewline\ncr\rnul\0bell\7", "\127del",
    }
    for _, s in ipairs(samples) do
        local enc = Codec.encode(s)
        check(not enc:find("[%z\1-\31]"), "no raw control characters in " .. enc)
        check(Codec.decode(enc) == s, "string round trip: " .. enc)
    end
    check(Codec.decode('"\\ud83d\\ude00"') == "😀", "surrogate pair")
    check(Codec.decode('"\\u00e9"') == "é", "\\u escape")
    check(Codec.decode('"\\ud83d"') == nil, "lone surrogate rejected")
    check(Codec.encode({ b = 1, a = { 1, 2, 3 }, c = "x" }) == '{"a":[1,2,3],"b":1,"c":"x"}', "sorted keys, arrays")
    check(Codec.encode(1700000000) == "1700000000", "integers stay integers")
    check(Codec.encode(1.5) == "1.5", "floats")
    for _, bad in ipairs({ "{", "[1,]", "{\"a\":1,}", "01", "1.", "\"\\x\"", "nul", "{\"a\":1}x",
                           "{\"a\":1,\"a\":2}", "\"a\nb\"" }) do
        check(Codec.decode(bad) == nil, "rejects " .. bad)
    end
    local t = Codec.decode('{"x":[true,false,null],"y":-1.5e3,"z":{}}')
    check(t and t.x[1] == true and t.x[2] == false and t.y == -1500, "decodes literals and numbers")

    local line = Codec.eventLine("0123456789abcdef0123456789abcdef", 12, 1700000000, 45, 300)
    local fast = Codec.parseLine(line)
    local slow = Codec.decode(line)
    check(fast and fast.md5 == slow.md5 and fast.page == 12 and fast.start == 1700000000
        and fast.dur == 45 and fast.tp == 300, "event fast path matches the general parser")
    check(Codec.parseLine('{"t":"e","md5":"x","page":-1,"start":1,"dur":1,"tp":1}') == nil, "negative page rejected")
    check(Codec.parseLine('{"t":"e","md5":"x","page":1,"start":1,"dur":1.5,"tp":1}') == nil, "fractional duration rejected")
    check(Codec.parseLine('{"t":"e","md5":"x","page":1,"start":1,"dur":1}') == nil, "missing field rejected")
    check(Codec.parseLine('{"t":"b","md5":"x","title":5}') == nil, "non-string title rejected")
    check(Codec.segmentName(7) == "seg-0000000007.jsonl.zst" and Codec.segmentSeq("seg-0000000007.jsonl.zst") == 7, "segment names")
    check(Codec.segmentSeq("seg-1.jsonl.part") == nil and Codec.segmentSeq("meta.json") == nil, "non-segments ignored")
    check(Codec.segmentSeq("seg-0000000007.jsonl") == nil, "0.2.2's uncompressed segments not taken for these")

    -- zstd
    local Zstd = require("concordance/zstd")
    local text = string.rep('{"t":"e","md5":"0123456789abcdef0123456789abcdef","page":1,"start":1,"dur":5,"tp":9}\n', 500)
    local packed = assert(Zstd.compress(text))
    check(#packed < #text / 10 and Zstd.decompress(packed) == text, "zstd round trip (" .. #text .. " -> " .. #packed .. ")")
    check(Zstd.decompress("") == nil and Zstd.decompress("this is not a segment\n") == nil, "not zstd: refused")
    check(Zstd.decompress(packed:sub(1, #packed - 5)) == nil, "truncated zstd: refused")
    local small_ok, small_err = Zstd.decompress(packed, 1000)
    check(small_ok == nil and small_err:find("more than"), "too big to unpack: refused before allocating")
    local zin, zout, zback = TMP .. "/z.jsonl", TMP .. "/z.jsonl.zst", TMP .. "/z2.jsonl"
    S.writeFile(zin, text)
    check(Zstd.compressFile(zin, zout) == #packed and Zstd.decompressFile(zout, zback) and S.readFile(zback) == text,
        "zstd file round trip")
    check(WebDav._base64("user:pässword") == "dXNlcjpww6Rzc3dvcmQ=" and WebDav._base64("ab") == "YWI="
        and WebDav._base64("abc") == "YWJj" and WebDav._base64("a") == "YQ==", "base64")
end

-- Segment files ------------------------------------------------------------------

local function segment(lines)
    local path = TMP .. "/seg-" .. tostring(math.random(1e9)) .. ".jsonl"
    S.writeFile(path, table.concat(lines, "\n") .. "\n")
    return path
end
local HEADER = Codec.headerLine("dev1", 1700000000)
local BOOK = Codec.bookLine{ md5 = "m1", title = "T", authors = "A", pages = 10, last_open = 5 }
local EV = Codec.eventLine("m1", 1, 100, 10, 10)

do
    check(Codec.readSegment(segment{ HEADER, BOOK, EV, Codec.trailerLine(1, 1) }) ~= nil, "valid segment")
    local cases = {
        { "no header", { BOOK, EV, Codec.trailerLine(1, 1) } },
        { "no trailer (truncated)", { HEADER, BOOK, EV } },
        { "count mismatch", { HEADER, BOOK, EV, Codec.trailerLine(1, 2) } },
        { "event before book", { HEADER, EV, BOOK, Codec.trailerLine(1, 1) } },
        { "garbage line", { HEADER, BOOK, "{nope", EV, Codec.trailerLine(1, 1) } },
        { "half a line", { HEADER, BOOK, EV:sub(1, 20) } },
        { "data after trailer", { HEADER, BOOK, EV, Codec.trailerLine(1, 1), EV } },
        { "major version 2", { (HEADER:gsub('"v":1', '"v":2')), BOOK, EV, Codec.trailerLine(1, 1) } },
        { "binary", { "\31\139\8\0\0\0" } },
        { "empty", { "" } },
    }
    for _, c in ipairs(cases) do
        local ok, err = Codec.readSegment(segment(c[2]))
        check(ok == nil and err, "rejects segment: " .. c[1])
    end
    local skipped = Codec.readSegment(segment{ (HEADER:gsub('"minor":0', '"minor":3')), BOOK,
        '{"t":"del","md5":"m1","before":50}', EV, Codec.trailerLine(1, 1) })
    check(skipped and skipped.events == 1, "unknown record type skipped within major version 1")
end

-- Merge and identity -----------------------------------------------------------------

local n_dev = 0
local function device(name)
    n_dev = n_dev + 1
    local d = S.newDevice(name, TMP .. "/dev" .. n_dev .. "-" .. name)
    d.store = Store.new{ sq3 = S.SQ3, stats_path = d.db, state_path = d.state }
    return d
end

local seg_n = 0
-- Exports from `d` (and marks exported, as after a confirmed upload).
local function export(d, max_events)
    seg_n = seg_n + 1
    local path = TMP .. "/export-" .. seg_n .. ".jsonl"
    local res = d.store:export{ device_id = d.name, out_path = path, now = 1700000000, max_events = max_events or 100000 }
    if not res then return nil end
    d.store:markExported(path, d.name, "seg-" .. seg_n, res.size, nil, 1700000000)
    return path, res
end

local function import(d, path, from)
    local s, err, kind = d.store:importSegment(path, from or "other", path:match("[^/]+$"), nil, nil, 1700000000)
    return s, err, kind
end

local BOOK1 = { title = "Der Zauberberg — Ünïcødé 📚", authors = "Thomas Mann", md5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", pages = 100 }
local BOOK2 = { title = "Book Two", authors = "N/A", md5 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", pages = 50 }

do -- basic propagation, idempotence, unicode
    local A, B = device("A"), device("B")
    A:read(BOOK1, { { 1, 1000, 30 }, { 2, 1030, 40 }, { 3, 1070, 25 } })
    A:read(BOOK2, { { 1, 2000, 10 } })
    local seg = export(A)
    check(seg ~= nil, "A exports")
    local s = import(B, seg, "A")
    check(s and s.inserted == 4 and s.books_new == 2, "B inserts 4 events and 2 books")
    check(B:dump() == A:dump(), "B equals A after import")
    local again = import(B, seg, "A")
    check(again and again.inserted == 0 and again.updated == 0, "second import changes nothing")
    check(B:dump() == A:dump(), "idempotent")
    local c = B:open()
    check(c:rowexec("SELECT title FROM book WHERE md5 = '" .. BOOK1.md5 .. "'") == BOOK1.title, "unicode title kept exactly")
    c:close()
    local ok, why = B:totalsMatch()
    check(ok, "totals match KOReader after import: " .. tostring(why))
    check(export(B) == nil, "imported events aren't exported back")
end

do -- order independence, larger duration wins with its total_pages
    local A, B, C = device("A"), device("B"), device("C")
    -- Same key on all three with different durations / layouts.
    A:read(BOOK1, { { 5, 5000, 20 }, { 6, 5020, 30 } })
    B:read(BOOK1, { { 5, 5000, 50 }, { 7, 6000, 10 } })
    C:read(BOOK1, { { 5, 5000, 35 }, { 8, 7000, 12 } })
    -- B saw it with a different page count (layout)
    local cb = B:open()
    cb:exec("UPDATE page_stat_data SET total_pages = 200 WHERE start_time = 5000;")
    cb:close()
    local segs = { A = export(A), B = export(B), C = export(C) }
    local orders = { { "A", "B", "C" }, { "C", "B", "A" }, { "B", "A", "C" }, { "C", "A", "B" } }
    local dumps = {}
    for i, order in ipairs(orders) do
        local D = device("D" .. i)
        for _, from in ipairs(order) do import(D, segs[from], from) end
        dumps[i] = D:dump()
        local ok, why = D:totalsMatch()
        check(ok, "totals match in order " .. i .. ": " .. tostring(why))
    end
    for i = 2, #dumps do check(dumps[i] == dumps[1], "same result in import order " .. i) end
    check(dumps[1]:find(BOOK1.md5 .. "|5|5000|50|200", 1, true), "largest duration wins, with its total_pages")
    -- Each device converges to the same too.
    import(A, segs.B, "B"); import(A, segs.C, "C")
    import(B, segs.A, "A"); import(B, segs.C, "C")
    import(C, segs.B, "B"); import(C, segs.A, "A")
    check(A:dump() == dumps[1] and B:dump() == dumps[1] and C:dump() == dumps[1], "all devices converge")
    for _, d in ipairs({ A, B, C }) do check(export(d) == nil, d.name .. " has nothing to echo") end
end

do -- equal durations: larger total_pages wins either way
    local A, B = device("A"), device("B")
    A:read(BOOK1, { { 1, 100, 30 } })
    B:read(BOOK1, { { 1, 100, 30 } })
    local cb = B:open(); cb:exec("UPDATE page_stat_data SET total_pages = 300;"); cb:close()
    local sa, sb = export(A), export(B)
    import(A, sb, "B"); import(B, sa, "A")
    check(A:dump() == B:dump() and A:dump():find("|300$"), "tie broken by total_pages")
end

do -- book identity: same md5, different title/authors locally
    local A, B = device("A"), device("B")
    A:read(BOOK1, { { 1, 1000, 30 } })
    local renamed = { title = "Magic Mountain", authors = "Mann, Thomas", md5 = BOOK1.md5, pages = 120,
                      series = "Local series" }
    B:read(renamed, { { 2, 2000, 40 } })
    -- A opened it later, with other series metadata
    local ca = A:open()
    ca:exec("UPDATE book SET last_open = last_open + 1000, series = 'Remote series', language = 'de';")
    ca:close()
    import(B, export(A), "A")
    local c = B:open()
    check(tonumber(c:rowexec("SELECT count(*) FROM book")) == 1, "no duplicate book row")
    local title, authors, series, pages = c:rowexec("SELECT title, authors, series, pages FROM book")
    c:close()
    check(title == "Magic Mountain" and authors == "Mann, Thomas", "local title and authors kept (KOReader looks the row up by them)")
    check(series == "Remote series", "newer series taken")
    check(tonumber(pages) == 120, "local page count kept")
    check(B:count("SELECT count(*) FROM page_stat_data") == 2, "events merged into the local row")
    -- KOReader opening the book on B still finds the same row.
    local id = B:read(renamed, { { 3, 3000, 5 } })
    check(id == 1 and B:count("SELECT count(*) FROM book") == 1, "KOReader still finds its row")
    local ok, why = B:totalsMatch()
    check(ok, "totals after identity merge: " .. tostring(why))
end

do -- several local rows for one md5: all events end up in the newest
    local A, B = device("A"), device("B")
    B:read({ title = "Old title", authors = "X", md5 = BOOK1.md5, pages = 100 }, { { 1, 1000, 10 } })
    B:read({ title = "New title", authors = "X", md5 = BOOK1.md5, pages = 100 }, { { 2, 2000, 10 } })
    local cb = B:open(); cb:exec("UPDATE book SET last_open = 50 WHERE title = 'Old title';"); cb:close()
    A:read(BOOK1, { { 1, 1000, 25 }, { 3, 3000, 5 } })
    import(B, export(A), "A")
    local c = B:open()
    local new_dur = tonumber(c:rowexec("SELECT duration FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.title = 'New title' AND start_time = 1000"))
    local new_rows = tonumber(c:rowexec("SELECT count(*) FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.title = 'New title'"))
    local old_rows = tonumber(c:rowexec("SELECT count(*) FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.title = 'Old title'"))
    local old_book = tonumber(c:rowexec("SELECT count(*) FROM book WHERE title = 'Old title'"))
    local dups = tonumber(c:rowexec("SELECT count(*) FROM page_stat_data WHERE start_time = 1000"))
    c:close()
    check(new_dur == 25 and dups == 1, "existing key moved to the newest row with the longer duration, not duplicated")
    check(new_rows == 3 and old_rows == 0, "every event of the md5 is in the most recently opened row")
    check(old_book == 1, "the older row is left (empty), not deleted")
    local ok, why = B:totalsMatch()
    check(ok, "totals after gathering rows: " .. tostring(why))
end

do -- rows split differently on two devices end up with the same totals
    -- Like a title changing case: A has one row with everything, B made a
    -- second row for the new title and has events in both.
    local A, B = device("A"), device("B")
    local old = { title = "Owned By The Alphas", authors = "JC", md5 = BOOK2.md5, pages = 50 }
    local new = { title = "Owned by the Alphas", authors = "JC", md5 = BOOK2.md5, pages = 50 }
    B:read(old, { { 1, 1000, 30 }, { 2, 1100, 30 } })
    B:read(new, { { 3, 2000, 40 } })
    local cb = B:open(); cb:exec("UPDATE book SET last_open = 50 WHERE title = 'Owned By The Alphas';"); cb:close()
    A:read(new, { { 4, 3000, 20 } })
    import(A, export(B), "B")
    import(B, export(A), "A")
    local function bookTime(d, title)
        local c = d:open()
        local t = tonumber(c:rowexec("SELECT coalesce(total_read_time, 0) FROM book WHERE title = '" .. title .. "'"))
        c:close()
        return t
    end
    check(bookTime(A, "Owned by the Alphas") == 120 and bookTime(B, "Owned by the Alphas") == 120,
        "same book time on both devices")
    check(bookTime(B, "Owned By The Alphas") == 0, "older row on B now empty")
    -- Opening the older title again makes it the newest: everything follows it.
    B:read(old, { { 5, 4000, 10 } })
    local cb2 = B:open(); cb2:exec("UPDATE book SET last_open = 9e9 WHERE title = 'Owned By The Alphas';"); cb2:close()
    A:read(new, { { 6, 5000, 10 } })
    import(B, export(A), "A")
    check(bookTime(B, "Owned By The Alphas") == 140 and bookTime(B, "Owned by the Alphas") == 0,
        "events follow the row opened most recently")
    local ok, why = B:totalsMatch()
    check(ok, "totals: " .. tostring(why))
end

do -- foreign books converge on the newest metadata whatever the order, until opened locally
    local A, B = device("A"), device("B")
    A:read({ title = "Title A", authors = "Au", md5 = BOOK2.md5, pages = 50 }, { { 1, 100, 10 } })
    B:read({ title = "Title B", authors = "Au", md5 = BOOK2.md5, pages = 60 }, { { 2, 200, 10 } })
    -- Opened at different times (the simulated devices all run in the same second).
    local ca = A:open(); ca:exec("UPDATE book SET last_open = last_open - 1000;"); ca:close()
    local cb = B:open(); cb:exec("UPDATE book SET last_open = last_open + 500;"); cb:close()
    local sa, sb = export(A), export(B)
    local titles = {}
    for i, order in ipairs({ { sa, sb }, { sb, sa } }) do
        local D = device("F" .. i)
        import(D, order[1]); import(D, order[2])
        local c = D:open()
        titles[i] = c:rowexec("SELECT title || '/' || pages FROM book")
        c:close()
    end
    check(titles[1] == "Title B/60" and titles[2] == "Title B/60", "foreign book takes the newest record in any order")
    local D = device("F3")
    import(D, sa)
    D:read({ title = "Title A", authors = "Au", md5 = BOOK2.md5, pages = 55 }, { { 3, 300, 10 } }) -- opened locally
    import(D, sb)
    local c = D:open()
    check(c:rowexec("SELECT title FROM book") == "Title A", "once opened locally, the title stays local")
    c:close()
end

do -- export diff
    local A, B = device("A"), device("B")
    A:read(BOOK1, { { 1, 1000, 30 }, { 2, 1100, 30 } })
    local _, r1 = export(A)
    check(r1 and r1.events == 2, "first export has both events")
    check(export(A) == nil, "nothing new, nothing exported")
    A:read(BOOK1, { { 3, 1200, 30 } })
    local _, r2 = export(A)
    check(r2 and r2.events == 1, "only the new event exported")
    -- An event (e.g. from KOReader's own cloud sync) got longer locally
    local c = A:open(); c:exec("UPDATE page_stat_data SET duration = 99 WHERE start_time = 1000;"); c:close()
    local seg, r3 = export(A)
    check(r3 and r3.events == 1, "a longer duration is exported again")
    import(B, seg)
    -- Events with an older start_time inserted later are still found
    A:read(BOOK1, { { 9, 500, 12 } })
    local _, r4 = export(A)
    check(r4 and r4.events == 1, "late-inserted older event exported")
    -- Books without md5 are skipped
    local c2 = A:open()
    c2:exec("INSERT INTO book (title, authors, md5, pages, last_open) VALUES ('nomd5', 'x', NULL, 10, 1);")
    c2:exec("INSERT INTO page_stat_data VALUES (last_insert_rowid(), 1, 9999, 10, 10);")
    c2:close()
    check(export(A) == nil, "events of books without md5 aren't exported")
    -- The cap splits big exports
    local D = device("cap")
    local sessions = {}
    for i = 1, 250 do sessions[i] = { i, 10000 + i * 60, 30 } end
    D:read(BOOK1, sessions)
    local _, c1 = export(D, 100)
    local _, c2r = export(D, 100)
    local _, c3 = export(D, 100)
    check(c1.events == 100 and c1.more and c2r.events == 100 and c3.events == 50 and not c3.more and export(D, 100) == nil,
        "export cap: 100 + 100 + 50, then nothing")
end

do -- skipping the diff when page_stat_data is unchanged
    local A = device("A")
    A:read(BOOK1, { { 1, 1000, 30 } })
    local path = TMP .. "/fp.jsonl"
    local res = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100 }
    check(res and res.fp, "export returns a fingerprint")
    -- KOReader writes more reading while the upload is in progress
    A:read(BOOK1, { { 2, 2000, 30 } })
    A.store:markExported(path, "A", "seg-1", res.size, nil, 1)
    A.store:markClean(res.fp)
    local again, _, why = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100 }
    check(again and again.events == 1, "rows written during the upload are still exported (" .. tostring(why) .. ")")
    A.store:markExported(path, "A", "seg-2", again.size, nil, 1)
    A.store:markClean(again.fp)
    local none, _, why2 = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100 }
    check(none == nil and why2 == "unchanged", "unchanged table: diff skipped")
    local none2, _, why3 = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100, force_diff = true }
    check(none2 == nil and why3 == "nothing new", "forced diff runs")
    -- An import keeps it clean
    local B = device("B")
    B:read(BOOK2, { { 1, 5000, 20 } })
    local bseg = export(B)
    local imp, imp_err = import(A, bseg, "B")
    check(imp ~= nil, "import into a clean table succeeds: " .. tostring(imp_err))
    check(A.store:seenSegments()["B"] ~= nil, "and the segment is recorded as seen")
    local _, _, why4 = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100 }
    check(why4 == "unchanged", "after an import into a clean table, the diff is still skipped")
    check(A:count("SELECT count(*) FROM page_stat_data") == 3, "and the import happened")
    local c = A:open(); c:exec("VACUUM;"); c:exec("UPDATE page_stat_data SET duration = duration + 1 WHERE start_time = 1000;"); c:close()
    local more = A.store:export{ device_id = "A", out_path = path, now = 1, max_events = 100 }
    check(more and more.events == 1, "a change after the fingerprint is found")
end

do -- a bad segment changes nothing and isn't marked seen
    local B = device("B")
    B:read(BOOK1, { { 1, 1000, 30 } })
    local before = B:dump()
    local bad = segment{ HEADER, Codec.bookLine{ md5 = "zz", title = "Z", last_open = 1 },
                         Codec.eventLine("zz", 1, 5, 5, 5), Codec.eventLine("zz", 2, 6, 5, 5) } -- no trailer
    local s, err, kind = import(B, bad, "X")
    check(s == nil and kind == "format" and err:find("truncated"), "truncated segment rejected as bad format")
    check(B:dump() == before and B:count("SELECT count(*) FROM book") == 1, "nothing written from a bad segment")
    check(next(B.store:seenSegments()) == nil, "bad segment not marked seen")
    local cs = S.SQ3.open(B.state)
    check(tonumber(cs:rowexec("SELECT count(*) FROM exported")) == 0, "exported unchanged by a bad segment")
    cs:close()
end

do -- pruneBad forgets bad segments from an older reader, and ones since imported
    local B = device("B")
    B.store:recordBad("X", "id-1.jsonl.zst", 10, "e", "unsupported format version 2", 301000) -- older reader
    B.store:recordBad("X", "id-2.jsonl.zst", 10, "e", "truncated", 302000) -- still bad
    B.store:recordBad("X", "id-3.jsonl.zst", 10, "e", "truncated", 302000) -- then imported
    B.store:markSeen("X", { { name = "id-3.jsonl.zst", size = 11, etag = "f", events = 1 } }, 1)
    B.store:pruneBad({ 302000 })
    local bad = B.store:badSegments(302000)
    check(bad.X and bad.X["id-2.jsonl.zst"] and not bad.X["id-3.jsonl.zst"], "pruneBad keeps only what's still bad")
    check(next(B.store:badSegments(301000)) == nil, "pruneBad drops an older version's")
end

do -- our totals query is KOReader's
    local norm = function(s) return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
    local theirs = S.koreaderTotalsQuery()
    check(theirs and norm(theirs) == norm(Store.BOOK_TOTALS_QUERY), "BOOK_TOTALS_QUERY matches statistics.koplugin")
end

-- Network job against an in-memory server ---------------------------------------------

local function memTransport(files)
    local t = { files = files or {}, bytes_up = 0, bytes_down = 0, requests = 0, log = {} }
    local function isDir(p) return t.files[p] == true end
    local function note(what) t.requests = t.requests + 1; table.insert(t.log, what) end
    function t:list(path)
        note("list " .. path)
        if path ~= "" and not isDir(path) then return nil, "HTTP 404", 404 end
        local out = {}
        for p, v in pairs(self.files) do
            local parent, name = p:match("^(.*)/([^/]+)$")
            if not parent then parent, name = "", p end
            if parent == path then out[#out + 1] = { name = name, is_dir = v == true, size = v ~= true and #v or nil } end
        end
        return out
    end
    function t:stat(path)
        note("stat " .. path)
        local v = self.files[path]
        if type(v) ~= "string" then return nil, "HTTP 404", 404 end
        return { size = #v }
    end
    -- t.no_size: a server that doesn't report sizes.
    local stat_with_size = t.stat
    function t:stat(path)
        local st, err, code = stat_with_size(self, path)
        if st and self.no_size then st.size = nil end
        return st, err, code
    end
    function t:mkdir(path) note("mkdir " .. path); if path ~= "" then self.files[path] = true end return true end
    function t:put(path, lp) note("put " .. path); self.files[path] = S.readFile(lp); return true end
    function t:put_new(path, lp)
        note("put_new " .. path)
        if self.files[path] then return false end
        self.files[path] = S.readFile(lp)
        return true
    end
    function t:get(path, lp)
        note("get " .. path)
        if type(self.files[path]) ~= "string" then return nil, "HTTP 404", 404 end
        S.writeFile(lp, self.files[path])
        return true, {}
    end
    function t:delete(path) note("delete " .. path); self.files[path] = nil; return true end
    return t
end

do
    local tmp = TMP .. "/netjob"
    S.mkdirp(tmp)
    local pending = TMP .. "/pending.jsonl"
    S.writeFile(pending, "x")
    local meta = TMP .. "/meta.json"
    S.writeFile(meta, "{}")
    local function seenSet(spec)
        local out = {}
        for dev, nums in pairs(spec) do
            out[dev] = {}
            for _, n in ipairs(nums) do out[dev][Codec.segmentName(n)] = { size = 1 } end
        end
        return out
    end
    local function names(r)
        local got = {}
        for _, d in ipairs(r.downloads) do got[d.device .. "/" .. d.name] = S.readFile(d.path) end
        return got
    end
    -- A server that reports no sizes: the upload counts, marked unchecked.
    do
        local tn = memTransport()
        tn.no_size = true
        local rn = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta,
                                seen = {}, tmp_dir = tmp, full_list = true }, tn)
        check(rn.ok and rn.uploaded and rn.uploaded.verified and rn.uploaded.unchecked,
            "no size from the server: upload accepted, marked unchecked")
    end
    -- Empty server, first sync (full listing)
    local t = memTransport()
    local r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta,
                           seen = {}, tmp_dir = tmp, full_list = true }, t)
    check(r.ok and r.uploaded and r.uploaded.name == "seg-0000000001.jsonl.zst" and r.uploaded.verified,
        "empty server: folders made, first segment uploaded and verified")
    check(t.files["devices/dev1/meta.json"] == "{}", "meta.json written")
    check(r.full_listed, "full listing done")

    -- Ordinary sync: meta.json written only when it changed, keeping a
    -- higher packed number the server's copy has.
    do
        local tm = memTransport({ devices = true, ["devices/dev1"] = true, ["devices/dev1/seg-0000000001.jsonl.zst"] = "x",
                                  ["devices/dev1/meta.json"] = '{"deviceName":"Old","packed":{"stats":7}}' })
        local m = TMP .. "/regular-meta.json"
        S.writeFile(m, Codec.encode{ deviceName = "New", versions = { concordance = "1.0.0" }, packed = { ann = 2 } })
        local seen1 = { dev1 = { ["seg-0000000001.jsonl.zst"] = { size = 1 } } }
        local rm = NetJob.run({ device_id = "dev1", meta_path = m, seen = seen1, tmp_dir = tmp, expect_own = true }, tm)
        check(rm.ok and not rm.meta_written and tm.files["devices/dev1/meta.json"]:find("Old", 1, true),
            "ordinary sync, meta.json unchanged: not written")
        rm = NetJob.run({ device_id = "dev1", meta_path = m, seen = seen1, tmp_dir = tmp, expect_own = true,
                          rewrite_meta = true }, tm)
        local got = Codec.decode(tm.files["devices/dev1/meta.json"])
        check(rm.ok and rm.meta_written and not rm.full_listed and got.deviceName == "New"
            and got.versions.concordance == "1.0.0", "ordinary sync, meta.json changed: written")
        check(got.packed.stats == 7 and got.packed.ann == 2, "the server's higher packed number kept")
        check(Codec.decode(S.readFile(m)).packed.stats == nil, "local meta.json left as it was")
    end

    -- Full listing: restored device continues after its highest segment, gets its lost ones back
    t.files["devices/dev1/seg-0000000005.jsonl.zst"] = "old"
    t.files["devices/dev1/.upload-dead.part"] = "half"
    t.files["devices/dev2"] = true
    t.files["devices/dev2/seg-0000000001.jsonl.zst"] = "abc"
    t.files["devices/dev2/seg-0000000002.jsonl.zst"] = "abcd"
    t.files["devices/bad id!"] = true
    local seen = { dev1 = { ["seg-0000000001.jsonl.zst"] = { size = 1 } }, dev2 = { ["seg-0000000001.jsonl.zst"] = { size = 3 } } }
    r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta, seen = seen, tmp_dir = tmp,
                     full_list = true,
                     bad = { dev2 = { ["seg-0000000002.jsonl.zst"] = { size = 99 } } } }, t)
    check(r.uploaded and r.uploaded.name == "seg-0000000002.jsonl.zst",
        "upload takes the first free number above the highest this device used")
    check(t.files["devices/dev1/.upload-dead.part"] == nil, "leftover temporary upload deleted")
    local got = names(r)
    check(got["dev1/seg-0000000005.jsonl.zst"] == "old", "own unseen segment downloaded (restore from backup)")
    check(got["dev2/seg-0000000002.jsonl.zst"] == "abcd", "bad entry with another size is retried")
    check(not got["dev2/seg-0000000001.jsonl.zst"] and not got["dev1/seg-0000000002.jsonl.zst"], "seen and just-uploaded segments skipped")
    check(#r.devices == 2, "invalid device folder names ignored")

    -- Ordinary sync: no folder listings, next segments asked for by name
    t.files["devices/dev2/seg-0000000003.jsonl.zst"] = "three"
    t.files["devices/dev2/seg-0000000004.jsonl.zst"] = "four"
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 5 }, dev2 = { 1, 2 } } }, t)
    got = names(r)
    check(got["dev2/seg-0000000003.jsonl.zst"] == "three" and got["dev2/seg-0000000004.jsonl.zst"] == "four" and #r.downloads == 2,
        "probing downloads the next segments in order")
    check(t.requests == 6 and not r.full_listed,
        "ordinary sync: 1 listing + 2 downloads + 1 miss per device, and 1 past dev1's gap (" .. t.requests .. " requests)")
    -- Nothing new: one listing plus one miss per device
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 5 }, dev2 = { 1, 2, 3, 4 } } }, t)
    check(#r.downloads == 0 and t.requests == 4, "nothing new: 4 small requests")

    -- Own record behind (restored), ordinary sync: name taken, so list and continue after the highest
    t.files["devices/dev1/seg-0000000003.jsonl.zst"] = "lost"
    r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 5 }, dev2 = { 1, 2, 3, 4 } } }, t)
    check(r.uploaded and r.uploaded.name == "seg-0000000006.jsonl.zst" and t.files["devices/dev1/seg-0000000003.jsonl.zst"] == "lost",
        "upload above the highest number this device used, not in a gap below it")
    check(names(r)["dev1/seg-0000000003.jsonl.zst"] == "lost" and #r.downloads == 1, "and the lost own segment is downloaded")
    -- Own record further behind: the name is taken, so list and take the first free one above
    r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1 }, dev2 = { 1, 2, 3, 4 } } }, t)
    check(r.uploaded and r.uploaded.name == "seg-0000000004.jsonl.zst" and t.files["devices/dev1/seg-0000000003.jsonl.zst"] == "lost",
        "taken name: not overwritten, the first free number above it taken")
    -- A stray number far ahead doesn't make readers skip the real next ones
    t.files["devices/dev2/seg-0000000900.jsonl.zst"] = "stray"
    t.files["devices/dev2/seg-0000000005.jsonl.zst"] = "five"
    r = NetJob.run({ device_id = "dev1", meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 3, 4, 5 }, dev2 = { 1, 2, 3, 4 } },
                     bad = seenSet{ dev2 = { 900 } } }, t)
    check(names(r)["dev2/seg-0000000005.jsonl.zst"] == "five", "probing continues from the first unseen number")

    -- Same size as the known-bad copy: skipped
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     bad = { dev2 = { ["seg-0000000002.jsonl.zst"] = { size = 4 } } } }, t)
    check(not names(r)["dev2/seg-0000000002.jsonl.zst"], "known-bad segment not downloaded again")
    -- Download budget
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, max_download_bytes = 1, full_list = true }, t)
    check(#r.downloads == 1 and r.remote_more, "download budget stops early and says there's more")
    -- Annotations: their own numbering and probing, next to the statistics
    local at = memTransport()
    local apend = TMP .. "/ann-pending.jsonl.zst"
    S.writeFile(apend, "ann")
    r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta, seen = {},
                     tmp_dir = tmp, full_list = true, ann = { pending = { path = apend, size = 3 } } }, at)
    check(r.uploaded and r.uploaded.name == "seg-0000000001.jsonl.zst" and r.ann_uploaded
        and r.ann_uploaded.name == "ann-0000000001.jsonl.zst" and r.ann_uploaded.verified, "both streams uploaded, each as number 1")
    at.files["devices/dev2"] = true
    at.files["devices/dev2/seg-0000000001.jsonl.zst"] = "s1"
    at.files["devices/dev2/ann-0000000001.jsonl.zst"] = "a1"
    at.files["devices/dev2/ann-0000000002.jsonl.zst"] = "a2"
    local aseen = { dev1 = { ["seg-0000000001.jsonl.zst"] = { size = 1 }, ["ann-0000000001.jsonl.zst"] = { size = 3 } } }
    at.log, at.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = aseen, tmp_dir = tmp, ann = {} }, at)
    local by = {}
    for _, d in ipairs(r.downloads) do by[d.device .. "/" .. d.name] = d.stream end
    check(by["dev2/seg-0000000001.jsonl.zst"] == "stats" and by["dev2/ann-0000000001.jsonl.zst"] == "ann"
        and by["dev2/ann-0000000002.jsonl.zst"] == "ann" and #r.downloads == 3, "probing finds each stream's next segments")
    check(at.requests == 8, "ordinary sync with annotations: 1 listing + 3 downloads + 1 miss per stream and device (" .. at.requests .. ")")
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = aseen, tmp_dir = tmp }, at)
    check(#r.downloads == 1 and r.downloads[1].stream == "stats", "annotation sync off: annotation segments left alone")
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     ann = { bad = { dev2 = { ["ann-0000000002.jsonl.zst"] = { size = 2 } } } } }, at)
    local names2 = names(r)
    check(names2["dev2/ann-0000000001.jsonl.zst"] and not names2["dev2/ann-0000000002.jsonl.zst"], "known-bad annotation segment skipped")

    -- Unreachable server
    local down = memTransport()
    down.list = function() return nil, "connection refused" end
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp }, down)
    check(r.ok == false and r.error:find("refused"), "offline server reported")
end

-- Engine: one sync at a time, one more if asked meanwhile -----------------------------------

do
    local tasks = {}
    local runs, spawned = 0, 0
    local fake_store = {
        export = function() return nil end,
        seenSegments = function() return {} end,
        badSegments = function() return {} end,
    }
    local e = Engine.new{
        store = fake_store, work_dir = TMP .. "/engine", tmp_dir = TMP .. "/engine/in",
        logger = { info = function() end, warn = function() end, dbg = function() end },
        schedule = function(_, fn) table.insert(tasks, fn) end,
        now = function() return 0 end,
        canRun = function() return true end,
        flush = function() runs = runs + 1 end,
        getDeviceId = function() return "dev1" end,
        spawn = function(fn) spawned = spawned + 1; return { fn = fn } end,
        isDone = function(h)
            if not h.ran then h.ran = true; h.fn(); collectgarbage("restart") end
            return true
        end,
        kill = function() end,
        makeTransport = function() return memTransport() end,
        saveStatus = function() end,
    }
    local function drain() while #tasks > 0 do table.remove(tasks, 1)() end end
    check(e:request("a") == "started", "first request starts")
    check(e:request("b") == "queued" and e:request("c") == "queued" and e:request("d") == "queued", "requests while running are queued")
    drain()
    check(runs == 2, "exactly one more run after the queued requests (got " .. runs .. ")")
    check(not e.running, "idle afterwards")
    check(e:request("e") == "started", "next request starts again")
    drain()
    check(runs == 3, "and runs once")
end

-- Packs ------------------------------------------------------------------------------------
local Pack = require("concordance/pack")
local AnnFormat = require("concordance/annformat")
local AnnStore = require("concordance/annstore")
local BookFormat = require("concordance/bookformat")
local BookStore = require("concordance/bookstore")
local Zstd = require("concordance/zstd")


-- A pack leaves the database exactly as importing its segments does.
local function writeLines(path, lines) S.writeFile(path, table.concat(lines, "\n") .. "\n") end
local function buildPack(stream, paths, out)
    local b = Pack.builder(stream)
    for _, path in ipairs(paths) do b:add(assert(b:read(path))) end
    assert(b:write(out, "dev1", 1700000000))
    return b:count()
end
do
    math.randomseed(7)
    local md5s = { string.rep("a", 32), string.rep("b", 32), string.rep("c", 32) }
    local titles = { "One", "Two — Ünïcødé", "Three" }
    -- Statistics: the same readings again with other durations, book
    -- records with other last-opened times and titles.
    local paths = {}
    for i = 1, 12 do
        local books, events, used = {}, {}, {}
        for _ = 1, 6 do
            local m = math.random(#md5s)
            if not used[m] then
                used[m] = true
                books[#books + 1] = Codec.bookLine{ md5 = md5s[m], title = titles[m] .. (math.random(3) == 1 and " (ed.)" or ""),
                    authors = "A", series = "S" .. math.random(2), language = "en", pages = 100, last_open = 1000 + math.random(50) }
            end
            events[#events + 1] = Codec.eventLine(md5s[m], math.random(5), 2000 + math.random(10), math.random(60), 100 + math.random(2))
        end
        local lines = { Codec.headerLine("dev1", 1700000000 + i) }
        for _, l in ipairs(books) do lines[#lines + 1] = l end
        for _, l in ipairs(events) do lines[#lines + 1] = l end
        lines[#lines + 1] = Codec.trailerLine(#books, #events)
        paths[i] = TMP .. "/pk-seg-" .. i .. ".jsonl"
        writeLines(paths[i], lines)
    end
    local X, Y = device("PackSeq"), device("PackOne")
    for i, path in ipairs(paths) do assert(X.store:importSegment(path, "dev1", Codec.segmentName(i), nil, nil, 1)) end
    local pack = TMP .. "/pk-stats.jsonl"
    local n = buildPack("stats", paths, pack)
    check(n < 12 * 6, "the pack keeps one of each reading: " .. n)
    check(Codec.readSegment(pack), "the pack is a valid statistics file")
    assert(Y.store:importSegment(pack, "dev1", Codec.segmentName(13), nil, nil, 1))
    local function books(d)
        local out = {}
        local conn = S.SQ3.open(d.db)
        for r in conn:prepare("SELECT md5, title, authors, series, language, pages, last_open FROM book ORDER BY md5, title;"):rows() do
            out[#out + 1] = table.concat({ tostring(r[1]), tostring(r[2]), tostring(r[3]), tostring(r[4]),
                tostring(r[5]), tostring(r[6]), tostring(r[7]) }, "|")
        end
        conn:close()
        return table.concat(out, "\n")
    end
    check(X:dump() == Y:dump() and books(X) == books(Y) and X:totalsMatch() and Y:totalsMatch(),
        "statistics: the pack gives the same readings, books and totals as its segments")

    -- Annotations and book data: edits, deletions, ties.
    local function lwwCase(stream, fmt, Store, record, table_sql)
        local lpaths = {}
        for i = 1, 10 do
            local lines = { fmt.headerLine("dev1", 1700000000 + i) }
            local seen_books, recs = {}, {}
            for _ = 1, 5 do
                local m = math.random(#md5s)
                if not seen_books[m] then
                    seen_books[m] = true
                    lines[#lines + 1] = fmt.bookLine{ md5 = md5s[m], title = titles[m], authors = "A" }
                end
                recs[#recs + 1] = record(md5s[m])
            end
            local nb = #lines - 1
            for _, l in ipairs(recs) do lines[#lines + 1] = l end
            lines[#lines + 1] = fmt.trailerLine(nb, #recs)
            lpaths[i] = TMP .. "/pk-" .. stream .. "-" .. i .. ".jsonl"
            writeLines(lpaths[i], lines)
        end
        local s1 = Store.new{ sq3 = S.SQ3, state_path = TMP .. "/pk-" .. stream .. "-seq.sqlite3" }
        local s2 = Store.new{ sq3 = S.SQ3, state_path = TMP .. "/pk-" .. stream .. "-one.sqlite3" }
        for i, path in ipairs(lpaths) do assert(s1:importSegment(path, "dev1", "x" .. i, nil, nil, 1)) end
        local pack = TMP .. "/pk-" .. stream .. ".jsonl"
        local n = buildPack(stream, lpaths, pack)
        check(fmt.readSegment(pack), stream .. ": the pack is a valid file")
        assert(s2:importSegment(pack, "dev1", "pack", nil, nil, 1))
        local function dump(store)
            local conn = S.SQ3.open(store.state_path)
            local out = {}
            for r in conn:prepare(table_sql):rows() do
                local row = {}
                for i = 1, 8 do row[i] = tostring(r[i]) end
                out[#out + 1] = table.concat(row, "|")
            end
            conn:close()
            return table.concat(out, "\n")
        end
        check(n < 50 and dump(s1) == dump(s2), stream .. ": the pack (" .. n .. " records) gives the same merged state")
    end
    lwwCase("ann", AnnFormat, AnnStore, function(md5)
        local fields = math.random(3) > 1 and Codec.encode{ page = "/body/p[" .. math.random(9) .. "]", text = "t" .. math.random(3),
            datetime = "2026-01-01 00:00:00" } or nil
        return AnnFormat.recordLine{ md5 = md5, kind = "rolling", key = "k" .. math.random(4), updated = 10 + math.random(3),
            device = "d" .. math.random(2), fields_json = fields }
    end, "SELECT md5, kind, key, updated, device, deleted, hash, fields FROM ann_merged ORDER BY md5, kind, key;")
    lwwCase("book", BookFormat, BookStore, function(md5)
        local props = { "status", "rating", "note" }
        local values = { status = '"complete"', rating = tostring(math.random(5)), note = '"n' .. math.random(3) .. '"' }
        local prop = props[math.random(3)]
        return BookFormat.recordLine{ md5 = md5, prop = prop, updated = 10 + math.random(3), device = "d" .. math.random(2),
            value_json = math.random(4) > 1 and values[prop] or nil }
    end, "SELECT md5, prop, updated, device, deleted, hash, value, md5 FROM book_merged ORDER BY md5, prop;")
end

-- The network step: packing this device's segments.
do
    local tmp = TMP .. "/packjob"
    S.mkdirp(tmp)
    local meta = TMP .. "/pack-meta.json"
    S.writeFile(meta, "{}")
    local t = memTransport()
    t.files["devices"] = true
    t.files["devices/dev1"] = true
    t.files["devices/dev2"] = true
    local function seg(i)
        local lines = { Codec.headerLine("dev1", 1700000000 + i),
            Codec.bookLine{ md5 = string.rep("a", 32), title = "T", authors = "A", pages = 10, last_open = i },
            Codec.eventLine(string.rep("a", 32), i % 7, 3000 + i, 30, 10), Codec.trailerLine(1, 1) }
        return assert(Zstd.compress(table.concat(lines, "\n") .. "\n"))
    end
    for i = 1, 120 do t.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    local own_seen = {}
    for i = 1, 120 do own_seen[Codec.segmentName(i)] = { size = 1 } end
    local function run(pack, extra)
        local params = { device_id = "dev1", meta_path = meta, seen = { dev1 = own_seen }, tmp_dir = tmp, full_list = true,
                         pack = pack or {} }
        params.pack.caps = params.pack.caps or { stats = 20000 }
        for k, v in pairs(extra or {}) do params[k] = v end
        return NetJob.run(params, t)
    end
    local PNAME = Codec.segmentName(121)

    local r = run()
    check(r.ok and #r.packed == 1 and r.packed[1].name == PNAME and r.packed[1].first == 1 and r.packed[1].last == 120,
        "120 small segments packed into the next segment, " .. PNAME)
    check(t.files["devices/dev1/" .. Codec.segmentName(1)] and t.files["devices/dev1/" .. Codec.segmentName(120)],
        "the segments stay for now")
    local plain = tmp .. "/check.jsonl"
    S.writeFile(tmp .. "/check.zst", t.files["devices/dev1/" .. PNAME])
    assert(Zstd.decompressFile(tmp .. "/check.zst", plain))
    local h = Codec.readSegment(plain)
    check(h and h.events == 120 and h.device == "dev1", "the pack, an ordinary segment, holds every segment's readings")
    own_seen[PNAME] = { size = 1 }

    -- Readers: nothing special. A reader that had segments 1 to 120 gets
    -- the next one, the pack, as it would any segment.
    local all = {}
    for i = 1, 120 do all[Codec.segmentName(i)] = { size = 1 } end
    r = NetJob.run({ device_id = "dev2", meta_path = meta, seen = { dev1 = all }, tmp_dir = tmp }, t)
    check(#r.downloads == 1 and r.downloads[1].name == PNAME, "a reader that had them gets the pack by probing")

    -- Not packed again; nothing deleted before its time.
    r = run{ after = { stats = 120 } }
    check(#r.packed == 0 and not next(r.deleted), "the next day: nothing new to pack, nothing deleted yet")
    -- A week later: the segments go, if the pack (or a later one holding it) is there.
    local entry = { stream = "stats", name = PNAME, first = 1, last = 120, holders = { PNAME } }
    local missing = { stream = "stats", name = Codec.segmentName(999), first = 1, last = 120, holders = { Codec.segmentName(999) } }
    r = run{ after = { stats = 120 }, delete = { missing } }
    check(not next(r.deleted) and r.left[missing.name] == 120 and t.files["devices/dev1/" .. Codec.segmentName(1)],
        "a pack that isn't there: its segments are kept")
    r = run{ after = { stats = 120 }, delete = { entry } }
    check(r.deleted[PNAME] == 120 and r.left[PNAME] == 0 and not t.files["devices/dev1/" .. Codec.segmentName(1)]
        and not t.files["devices/dev1/" .. Codec.segmentName(120)] and t.files["devices/dev1/" .. PNAME],
        "then deleted, the pack kept")

    -- Numbers once used are never used again, though their segments are gone.
    local pending = TMP .. "/pack-pending.zst"
    S.writeFile(pending, "x")
    r = run({ after = { stats = 120 } }, { pending = { path = pending, size = 1 } })
    check(r.uploaded and r.uploaded.name == Codec.segmentName(122), "after a listing: the next upload is 122")
    r = NetJob.run({ device_id = "dev1", meta_path = meta, tmp_dir = tmp, pending = { path = pending, size = 1 },
                     seen = { dev1 = { [PNAME] = { size = 1 } } } }, t)
    check(r.uploaded and r.uploaded.name == Codec.segmentName(123),
        "without a listing, knowing only the pack: past it, not 1 (got " .. tostring(r.uploaded and r.uploaded.name) .. ")")
    -- A new reader, after the deletion: its first sync is a full listing.
    r = NetJob.run({ device_id = "dev2", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true }, t)
    local got = {}
    for _, d in ipairs(r.downloads) do got[d.name] = true end
    check(got[PNAME] and got[Codec.segmentName(122)] and got[Codec.segmentName(123)] and #r.downloads == 3,
        "a new reader gets the pack and what came after")

    -- Too few small segments: no pack. Big ones are left out.
    local u = memTransport()
    u.files["devices"] = true
    u.files["devices/dev1"] = true
    for i = 1, 99 do u.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 20000 } } }, u)
    check(#r.packed == 0, "99 small segments: not packed yet")
    u.files["devices/dev1/" .. Codec.segmentName(1)] = u.files["devices/dev1/" .. Codec.segmentName(1)] .. string.rep("x", Pack.SMALL)
    for i = 100, 101 do u.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 20000 } } }, u)
    check(#r.packed == 1 and r.packed[1].first == 2 and r.packed[1].last == 101 and r.packed[1].name == Codec.segmentName(102),
        "a big first segment is left as it is")
    -- The cap: a pack holds no more records than one import.
    local v = memTransport()
    v.files["devices"] = true
    v.files["devices/dev1"] = true
    for i = 1, 150 do v.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 110 } } }, v)
    check(#r.packed == 1 and r.packed[1].last == 110 and r.packed[1].name == Codec.segmentName(151),
        "packs stop at the cap: " .. tostring(r.packed[1] and r.packed[1].last))

    -- A short run ended by a big segment never grows: packing goes on past it.
    local w = memTransport()
    w.files["devices"] = true
    w.files["devices/dev1"] = true
    for i = 1, 160 do w.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    w.files["devices/dev1/" .. Codec.segmentName(50)] = seg(50) .. string.rep("x", Pack.SMALL)
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 20000 } } }, w)
    check(#r.packed == 1 and r.packed[1].first == 51 and r.packed[1].last == 160,
        "49 small, a big one, then 110 small: the 110 are packed (got "
        .. tostring(r.packed[1] and r.packed[1].first) .. "-" .. tostring(r.packed[1] and r.packed[1].last) .. ")")
    -- And past a gap, the same.
    w.files["devices/dev1/" .. Codec.segmentName(50)] = nil
    w.files["devices/dev1/" .. Codec.segmentName(161)] = nil -- the pack just made
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 20000 } } }, w)
    check(#r.packed == 1 and r.packed[1].first == 51 and r.packed[1].last == 160, "past a gap too")
    -- The last run, still short, waits for more.
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { after = { stats = 160 }, caps = { stats = 20000 } } }, w)
    check(#r.packed == 0, "after the pack, the run is short and the newest: no pack yet")

    -- Busy segments: the cap is reached before 100 of them. The pack is
    -- made anyway, and the next one starts where it ends.
    local x = memTransport()
    x.files["devices"] = true
    x.files["devices/dev1"] = true
    for i = 1, 120 do x.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                     pack = { caps = { stats = 40 } } }, x)
    check(#r.packed == 1 and r.packed[1].first == 1 and r.packed[1].last == 40,
        "a full pack of 40 is made, though fewer than 100 (got " .. tostring(r.packed[1] and r.packed[1].last) .. ")")
    -- 41 to 121 (the pack) is too short to look at yet; once 100 have built
    -- up, the next 40 are packed.
    local pack2 = { device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, full_list = true,
                    pack = { after = { stats = 40 }, caps = { stats = 40 } } }
    r = NetJob.run(pack2, x)
    check(#r.packed == 0, "the rest waits for 100 to build up")
    for i = 122, 140 do x.files["devices/dev1/" .. Codec.segmentName(i)] = seg(i) end
    r = NetJob.run(pack2, x)
    check(#r.packed == 1 and r.packed[1].first == 41 and r.packed[1].last == 80,
        "then the next 40 (got " .. tostring(r.packed[1] and r.packed[1].first) .. "-"
        .. tostring(r.packed[1] and r.packed[1].last) .. ")")
end

-- Folder dates: unchanged folders are skipped by ordinary syncs.
do
    check(NetJob.parseHttpDate("Thu, 05 Nov 2026 21:31:52 GMT") == 1793914312
        and NetJob.parseHttpDate("Thu, 01 Jan 1970 00:00:10 GMT") == 10
        and NetJob.parseHttpDate("Sun, 29 Feb 2032 12:00:00 GMT") == 1961668800
        and NetJob.parseHttpDate("nonsense") == nil, "HTTP dates (GMT, leap years), nonsense refused")

    local tmp = TMP .. "/dates"
    S.mkdirp(tmp)
    local meta = TMP .. "/dates-meta.json"
    S.writeFile(meta, "{}")
    local t = memTransport()
    local dates = {}
    local list = t.list
    t.server_date = "Fri, 06 Nov 2026 10:00:00 GMT"
    function t:list(path)
        local out, e, c = list(self, path)
        if out then
            for _, x in ipairs(out) do if x.is_dir then x.modified = dates[path .. "/" .. x.name] end end
            out.server_date = self.server_date
        end
        return out, e, c
    end
    t.files["devices"] = true
    for _, id in ipairs({ "dev1", "dev2", "dev3" }) do
        t.files["devices/" .. id] = true
        dates["devices/" .. id] = "Fri, 06 Nov 2026 09:00:00 GMT"
    end
    t.files["devices/dev2/seg-0000000001.jsonl.zst"] = "a"
    t.files["devices/dev3/seg-0000000001.jsonl.zst"] = "b"
    local seen = { dev1 = { [Codec.segmentName(1)] = { size = 1 } }, dev2 = { [Codec.segmentName(1)] = { size = 1 } },
                   dev3 = { [Codec.segmentName(1)] = { size = 1 } } }
    local r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp }, t)
    check(r.folders.dev2 and r.folders.dev2.reliable and r.folders.dev2.complete.stats
        and r.folders.dev2.modified == dates["devices/dev2"], "folders gone through, with their dates")
    local folders = {}
    for id, f in pairs(r.folders) do folders[id] = { modified = f.modified, streams = f.complete } end
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp, folders = folders }, t)
    check(t.requests == 1 and #r.downloads == 0, "nothing changed: one listing, no request per device (" .. t.requests .. ")")
    -- dev3 adds a segment: its folder's date changes.
    t.files["devices/dev3/seg-0000000002.jsonl.zst"] = "c"
    dates["devices/dev3"] = "Fri, 06 Nov 2026 09:30:00 GMT"
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp, folders = folders }, t)
    check(#r.downloads == 1 and r.downloads[1].device == "dev3" and t.requests == 3,
        "a changed folder is gone through, the rest skipped (" .. t.requests .. " requests)")
    -- Annotations weren't gone through before: not skipped for them.
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp, folders = folders, ann = {} }, t)
    local probed = false
    for _, line in ipairs(t.log) do if line:find("dev2/ann%-") then probed = true end end
    check(probed, "a stream not gone through before is checked")
    -- A date too close to the server's clock isn't relied on.
    dates["devices/dev2"] = "Fri, 06 Nov 2026 09:59:59 GMT"
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp }, t)
    check(r.folders.dev2 and not r.folders.dev2.reliable and r.folders.dev3.reliable, "a date within a second or two isn't relied on")
    -- Without seen segments (a rebuild), nothing is skipped.
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = {}, tmp_dir = tmp, folders = folders }, t)
    check(#r.downloads >= 2, "nothing seen: every folder gone through")

    -- The dates can't be trusted: a full listing finds a segment in a
    -- folder whose date didn't change.
    t.files["devices/dev2/seg-0000000002.jsonl.zst"] = "d"
    dates["devices/dev2"] = "Fri, 06 Nov 2026 09:00:00 GMT"
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp, folders = folders, full_list = true }, t)
    check(r.dates_unreliable and #r.downloads >= 1, "full listing: an unchanged date with something new: dates not trusted")
    -- Or this device's own folder kept its date across an upload.
    r = NetJob.run({ device_id = "dev1", meta_path = meta, seen = seen, tmp_dir = tmp, folders = folders,
                     own_check = dates["devices/dev1"] }, t)
    check(r.dates_unreliable and t.requests > 1, "own folder's date unchanged after an upload: dates not trusted, nothing skipped")
end

-- Other devices' names, from their meta.json -------------------------------------------------

do
    local tmp = TMP .. "/names"
    S.mkdirp(tmp)
    local t = memTransport{
        devices = true, ["devices/dev1"] = true, ["devices/dev2"] = true, ["devices/dev3"] = true,
        ["devices/dev2/meta.json"] = '{"deviceId":"dev2","deviceName":"Kobo Forma"}',
    }
    local r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = {} }, t)
    check(r.ok and r.device_names and r.device_names.dev2 == "Kobo Forma", "a device's name read")
    check(r.device_names.dev3 == nil and r.device_names.dev1 == nil, "no meta.json: no name, and not our own")
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = { dev2 = "Kobo Forma" } }, t)
    local asked = {}
    for _, l in ipairs(t.log) do if l:find("meta.json", 1, true) then asked[#asked + 1] = l end end
    check(#asked == 1 and asked[1]:find("dev3", 1, true), "named devices aren't asked again")
    check(r.device_meta_tags and r.device_meta_tags.dev3 == "-", "no meta.json: noted, so it isn't asked every sync")
    t.log = {}
    NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = { dev2 = "Kobo Forma" }, meta_tags = { dev3 = "-" } }, t)
    asked = {}
    for _, l in ipairs(t.log) do if l:find("meta.json", 1, true) then asked[#asked + 1] = l end end
    check(#asked == 0, "noted as missing: not asked again without a full listing")
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp }, t)
    check(r.device_names == nil, "names only read when asked for")

    -- Read again only when a full listing shows its meta.json changed.
    local function metaGets()
        local n = {}
        for _, l in ipairs(t.log) do
            local id = l:match("^get devices/([^/]+)/meta%.json$")
            if id then n[#n + 1] = id end
        end
        return n
    end
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = {}, full_list = true }, t)
    local tags = r.device_meta_tags or {}
    check(tags.dev2 and tags.dev3 == nil and #metaGets() == 1, "full listing: meta.json read, its tag kept; none for a device without one")
    local named = { dev2 = r.device_names.dev2 }
    tags.dev3 = "-"
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = named, meta_tags = tags, full_list = true }, t)
    check(#metaGets() == 0 and r.device_names == nil, "unchanged meta.json: not read again")
    t.files["devices/dev2/meta.json"] = '{"deviceId":"dev2","deviceName":"Bedside Kobo"}'
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = named, meta_tags = tags }, t)
    check(#metaGets() == 0, "renamed, no full listing: not read yet")
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = named, meta_tags = tags, full_list = true }, t)
    check(#metaGets() == 1 and r.device_names and r.device_names.dev2 == "Bedside Kobo"
        and r.device_meta_tags.dev2 ~= tags.dev2, "renamed: read again on the next full listing")
    -- Named before tags were kept (an older version): read once to get one.
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = { dev2 = "Kobo Forma" }, meta_tags = {}, full_list = true }, t)
    check(#metaGets() == 1 and r.device_names.dev2 == "Bedside Kobo", "named without a tag: read once on a full listing")
    -- A nameless meta.json: read once, not every sync.
    t.files["devices/dev3/meta.json"] = '{"deviceId":"dev3","deviceName":""}'
    t.log = {}
    r = NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = named, meta_tags = { dev2 = "x" } }, t)
    local nameless = r.device_meta_tags or {}
    check(nameless.dev3 and not (r.device_names or {}).dev3, "nameless device: tag kept, no name")
    t.log = {}
    NetJob.run({ device_id = "dev1", seen = {}, tmp_dir = tmp, named = named, meta_tags = { dev2 = "x", dev3 = nameless.dev3 } }, t)
    check(#metaGets() == 0, "nameless device: not read again until it changes")
    -- Tags: etag first, else size and date, else none.
    check(NetJob.metaTag{ etag = '"abc"', size = 3 } == 'e:"abc"' and NetJob.metaTag{ size = 3, modified = "x" } == "s:3@x"
        and NetJob.metaTag{} == nil, "metaTag")
end

-- The statistics plugin's schema version ------------------------------------------------

do
    local d = device("schema")
    check(d.store:statsSchemaProblem() == nil, "KOReader's current statistics schema is supported")
    local c = d:open()
    c:exec("PRAGMA user_version=20991231;")
    c:close()
    local warned = 0
    d.store.log = { warn = function() warned = warned + 1 end }
    local conn, why, kind = d.store:openStats()
    check(conn == nil and kind == "schema" and why:find("20991231"), "a newer schema is left alone")
    check(d.store:statsSchemaProblem() and warned == 1, "the problem reported, the warning logged once")
    local _, err = d.store:export{ device_id = "x", out_path = TMP .. "/schema.jsonl", now = 1, max_events = 10 }
    check(err and err:find("not supported"), "nothing exported from it")
end

S.finish("concordance unit tests")
