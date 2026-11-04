-- Unit tests for supersync.koplugin: the segment codec, the merge, book
-- identity, the export diff, segment validation, the network job against an
-- in-memory server, and the engine's one-at-a-time rule.
--
-- Statistics databases are created and written by KOReader's own
-- statistics.koplugin code (see tests/supersync/support.lua).
-- Run through scripts/test-statsync.sh, which sets KOREADER_SRC.

local S = dofile("tests/supersync/support.lua")
local check = S.check

local Codec = require("supersync/codec")
local Store = require("supersync/store")
local NetJob = require("supersync/netjob")
local Engine = require("supersync/engine")
local WebDav = require("supersync/webdav")

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
    local Zstd = require("supersync/zstd")
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

do -- several local rows for one md5: merge into the newest, update an existing key in place
    local A, B = device("A"), device("B")
    B:read({ title = "Old title", authors = "X", md5 = BOOK1.md5, pages = 100 }, { { 1, 1000, 10 } })
    B:read({ title = "New title", authors = "X", md5 = BOOK1.md5, pages = 100 }, { { 2, 2000, 10 } })
    local cb = B:open(); cb:exec("UPDATE book SET last_open = 50 WHERE title = 'Old title';"); cb:close()
    A:read(BOOK1, { { 1, 1000, 25 }, { 3, 3000, 5 } })
    import(B, export(A), "A")
    local c = B:open()
    local old_dur = tonumber(c:rowexec("SELECT duration FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.title = 'Old title' AND start_time = 1000"))
    local new_rows = tonumber(c:rowexec("SELECT count(*) FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.title = 'New title'"))
    local dups = tonumber(c:rowexec("SELECT count(*) FROM page_stat_data WHERE start_time = 1000"))
    c:close()
    check(old_dur == 25 and dups == 1, "existing key updated in its own row, not duplicated")
    check(new_rows == 2, "new key goes to the most recently opened row")
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
    -- Empty server, first sync (full listing)
    local t = memTransport()
    local r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta,
                           seen = {}, tmp_dir = tmp, full_list = true }, t)
    check(r.ok and r.uploaded and r.uploaded.name == "seg-0000000001.jsonl.zst" and r.uploaded.verified,
        "empty server: folders made, first segment uploaded and verified")
    check(t.files["devices/dev1/meta.json"] == "{}", "meta.json written")
    check(r.full_listed, "full listing done")

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
    check(r.uploaded and r.uploaded.name == "seg-0000000002.jsonl.zst", "upload takes the first unused number")
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
    check(t.requests == 5 and not r.full_listed, "ordinary sync: 1 listing + 2 downloads + 1 miss per device (" .. t.requests .. " requests)")
    -- Nothing new: one listing plus one miss per device
    t.log, t.requests = {}, 0
    r = NetJob.run({ device_id = "dev1", meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 5 }, dev2 = { 1, 2, 3, 4 } } }, t)
    check(#r.downloads == 0 and t.requests == 3, "nothing new: 3 small requests")

    -- Own record behind (restored), ordinary sync: name taken, so list and continue after the highest
    t.files["devices/dev1/seg-0000000003.jsonl.zst"] = "lost"
    r = NetJob.run({ device_id = "dev1", pending = { path = pending, size = 1 }, meta_path = meta, tmp_dir = tmp,
                     seen = seenSet{ dev1 = { 1, 2, 5 }, dev2 = { 1, 2, 3, 4 } } }, t)
    check(r.uploaded and r.uploaded.name == "seg-0000000004.jsonl.zst" and t.files["devices/dev1/seg-0000000003.jsonl.zst"] == "lost",
        "taken name: not overwritten, upload takes the next unused number")
    check(names(r)["dev1/seg-0000000003.jsonl.zst"] == "lost" and #r.downloads == 1, "and the lost own segment is downloaded")
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

S.finish("supersync unit tests")
