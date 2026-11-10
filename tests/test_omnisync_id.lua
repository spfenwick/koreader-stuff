-- Unit tests for OmniSync's book identity: the record format
-- (omnisync/idformat.lua), reading book files (omnisync/idscan.lua, with
-- archives stood in for), the store (omnisync/idstore.lua) and packing.
-- Run through scripts/test-omnisync.sh, which sets KOREADER_SRC.

local S = dofile("tests/omnisync/support.lua")
local check = S.check

local IdFormat = require("omnisync/idformat")
local IdScan = require("omnisync/idscan")
local IdStore = require("omnisync/idstore")
local Pack = require("omnisync/pack")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/id"
S.rmrf(TMP)
S.mkdirp(TMP)

-- Any stable digest will do for the tests.
local function digest(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c * 7) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local U_LIB = "333d496c-3946-448d-bb64-de3905aaaf83" -- Calibre library UUID (the OPDS ID)
local U_PKG = "dd15c660-aec5-41ff-af25-8a01b8b592eb" -- the package's unique identifier

-- Format ------------------------------------------------------------------------------------

do
    check(IdFormat.normalizeUuid("urn:uuid:" .. U_LIB:upper()) == U_LIB, "urn:uuid: stripped, lowercased")
    check(IdFormat.normalizeUuid("uuid:" .. U_LIB) == U_LIB, "uuid: stripped")
    check(IdFormat.normalizeUuid(" " .. U_LIB .. " ") == U_LIB, "bare UUID, spaces trimmed")
    check(IdFormat.normalizeUuid("isbn:9780195056440") == nil and IdFormat.normalizeUuid("calibre:4644") == nil,
        "other identifiers aren't UUIDs")

    local r = { md5 = string.rep("a", 32), src = "file", uuids = { U_PKG, U_LIB, U_PKG }, sig = "s1",
                title = "The View From Nowhere", authors = "Thomas Nagel", ids = { "isbn:9780195056440" } }
    check(IdFormat.factKey(r) == IdFormat.factKey{ md5 = r.md5, src = "file", uuids = { U_LIB, U_PKG }, sig = "s1",
        title = "Other" }, "fact key: uuid order, repeats and display fields don't matter")
    check(IdFormat.factKey(r) ~= IdFormat.factKey{ md5 = r.md5, src = "sidecar", uuids = { U_LIB, U_PKG } },
        "fact key: src and sig matter")

    local path = TMP .. "/seg.jsonl"
    local lines = { IdFormat.headerLine("devA", 1700000000), IdFormat.recordLine(r),
                    '{"t":"later","x":1}', IdFormat.trailerLine(1) }
    S.writeFile(path, table.concat(lines, "\n") .. "\n")
    local got = {}
    local header, err = IdFormat.readSegment(path, { record = function(rec) got[#got + 1] = rec end })
    check(header and header.records == 1, "segment read: " .. tostring(err))
    local g = got[1]
    check(g and g.md5 == r.md5 and g.src == "file" and g.sig == "s1" and #g.uuids == 2
        and g.uuids[1] == U_LIB and g.title == r.title and g.ids[1] == "isbn:9780195056440" and g.dev == "devA",
        "record round trip (unknown record type skipped)")

    local function bad(body, what)
        S.writeFile(path, IdFormat.headerLine("devA", 1) .. "\n" .. body .. "\n")
        local h, e = IdFormat.readSegment(path)
        check(h == nil, what .. " rejected (" .. tostring(e) .. ")")
    end
    bad('{"t":"i","md5":"m","src":"file","uuids":["not-a-uuid"]}\n' .. IdFormat.trailerLine(1), "bad UUID")
    bad('{"t":"i","md5":"m","src":"file","uuids":[]}\n' .. IdFormat.trailerLine(1), "record without UUIDs")
    bad(IdFormat.recordLine(r) .. "\n" .. IdFormat.trailerLine(2), "wrong trailer count")
    bad(IdFormat.recordLine(r), "missing trailer")
    S.writeFile(path, '{"t":"h","format":"statsync-id","v":2,"device":"devA"}\n' .. IdFormat.trailerLine(0) .. "\n")
    check(IdFormat.readSegment(path) == nil, "newer major version rejected")
    check(IdFormat.segmentSeq(IdFormat.segmentName(42)) == 42 and IdFormat.segmentSeq("book-0000000042.jsonl.zst") == nil,
        "segment names")
end

-- Reading book files -------------------------------------------------------------------------

-- Package files as Calibre 6 and Calibre 9 wrote them for the same book.
local OPF6 = [[<?xml version="1.0"  encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uuid_id">
  <metadata xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>The View From Nowhere</dc:title>
    <dc:creator opf:role="aut" opf:file-as="Nagel, Thomas">Thomas Nagel</dc:creator>
    <dc:identifier id="uuid_id" opf:scheme="uuid">]] .. U_PKG .. [[</dc:identifier>
    <dc:identifier opf:scheme="calibre">]] .. U_LIB .. [[</dc:identifier>
    <dc:identifier opf:scheme="ISBN">9780195056440</dc:identifier>
    <dc:identifier opf:scheme="AMAZON">0195056442</dc:identifier>
  </metadata>
  <manifest>
    <item href="text/ch1.html" id="c1" media-type="application/xhtml+xml"/>
    <item href="text/ch%202.html" id="c2" media-type="application/xhtml+xml"/>
    <item href="toc.ncx" media-type="application/x-dtbncx+xml" id="ncx"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>]]
local OPF9 = [[<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uuid_id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title id="id">The View From Nowhere</dc:title>
    <dc:creator id="id-1">Thomas Nagel</dc:creator>
    <dc:identifier>isbn:9780195056440</dc:identifier>
    <dc:identifier>amazon:0195056442</dc:identifier>
    <dc:identifier>calibre:4644</dc:identifier>
    <dc:identifier>uuid:]] .. U_LIB .. [[</dc:identifier>
    <dc:identifier id="uuid_id">uuid:]] .. U_PKG .. [[</dc:identifier>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="text/ch1.html" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch%202.html" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>]]
local CONTAINER = [[<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>]]

local CH1 = [[<html xmlns="http://www.w3.org/1999/xhtml"><head><title>1</title>
  <link href="stylesheet.css" rel="stylesheet"/></head>
<body class="calibre"><h1 class="h">One</h1><p class="p1">It was a  dark
night.</p></body></html>]]
local CH2 = [[<html><head/><body><p>Two &amp; more.</p><img src="a.jpg"/></body></html>]]

--- A stand-in archive: entries = { name = data }, read in the order given.
local archives = {}
local function fakeArchive(path)
    local a = archives[path]
    if not a then return nil end
    return {
        read = function(_, name) return a.entries[name] end,
        each = function(_, set, fn)
            for _, name in ipairs(a.order) do
                if set[name] then fn(name, a.entries[name]) end
            end
        end,
        close = function() end,
    }
end
local function addBook(path, fingerprint, opf, ch1, ch2)
    local entries = { ["mimetype"] = "application/epub+zip", ["META-INF/container.xml"] = CONTAINER,
                      ["OEBPS/content.opf"] = opf, ["OEBPS/text/ch1.html"] = ch1, ["OEBPS/text/ch 2.html"] = ch2 }
    -- Storage order isn't spine order.
    archives[path] = { fingerprint = fingerprint, entries = entries,
                       order = { "mimetype", "OEBPS/text/ch 2.html", "META-INF/container.xml", "OEBPS/content.opf",
                                 "OEBPS/text/ch1.html" } }
end
local scan_deps = {
    md5 = digest,
    partialMD5 = function(path) return archives[path] and archives[path].fingerprint end,
    openArchive = fakeArchive,
}

do
    local i6, i9 = IdScan.parseOpf(OPF6), IdScan.parseOpf(OPF9)
    check(#i6.uuids == 2 and i6.uuids[1] == U_LIB and i6.uuids[2] == U_PKG, "Calibre 6: both UUIDs")
    check(#i9.uuids == 2 and i9.uuids[1] == U_LIB and i9.uuids[2] == U_PKG, "Calibre 9: the same UUIDs")
    local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
    check(has(i6.ids, "isbn:9780195056440") and has(i9.ids, "isbn:9780195056440"), "ISBN in the same form from both")
    check(has(i9.ids, "calibre:4644") and not has(i9.ids, U_LIB), "other identifiers kept, UUIDs not among them")
    check(i6.title == "The View From Nowhere" and i9.title == i6.title and i6.authors == "Thomas Nagel"
        and i9.authors == "Thomas Nagel", "title and authors")
    check(IdScan.parseOpf("<package><metadata/></package>").uuids[1] == nil, "no identifiers: no UUIDs")

    local files = IdScan.spine(OPF6, "OEBPS/content.opf")
    check(#files == 2 and files[1] == "OEBPS/text/ch1.html" and files[2] == "OEBPS/text/ch 2.html",
        "spine: reading order, relative to the package file, %-escapes decoded")

    -- A Calibre rewrite: package file and <head> differ, attributes and
    -- whitespace too; the body's elements and text don't.
    addBook("/b/old.epub", "md5old", OPF6, CH1, CH2)
    addBook("/b/new.epub", "md5new", OPF9,
        CH1:gsub('<head>.-</head>', '<head><link href="x.css"/><title>1</title></head>')
           :gsub('class="calibre"', 'class="calibre1"'):gsub("  dark\n", " dark "),
        CH2)
    addBook("/b/edited.epub", "md5edit", OPF9, CH1:gsub("dark", "stormy"), CH2)
    addBook("/b/retagged.epub", "md5tag", OPF9, CH1:gsub("<h1(.-)</h1>", "<h2%1</h2>"), CH2)
    addBook("/b/reordered.epub", "md5ord", OPF9:gsub('<itemref idref="c1"/><itemref idref="c2"/>',
        '<itemref idref="c2"/><itemref idref="c1"/>'), CH1, CH2)
    local old = assert(IdScan.scan("/b/old.epub", scan_deps))
    local new = assert(IdScan.scan("/b/new.epub", scan_deps))
    check(old.md5 == "md5old" and new.md5 == "md5new", "the file's own fingerprint")
    check(old.sig and old.sig == new.sig, "rewritten copy: same body signature")
    check(IdScan.scan("/b/edited.epub", scan_deps).sig ~= old.sig, "changed text: another signature")
    check(IdScan.scan("/b/retagged.epub", scan_deps).sig ~= old.sig, "changed element: another signature")
    check(IdScan.scan("/b/reordered.epub", scan_deps).sig ~= old.sig, "changed spine order: another signature")
    check(IdScan.scan("/b/missing.epub", scan_deps) == nil, "unreadable file: nothing")
    archives["/b/noopf.epub"] = { fingerprint = "x", entries = {}, order = {} }
    local none, why = IdScan.scan("/b/noopf.epub", scan_deps)
    check(none == nil and why == "no package file", "no package file: nothing")
    check(IdScan.handles("/a/B.EPUB") and not IdScan.handles("/a/b.pdf") and not IdScan.handles("/a/epub"),
        "only EPUBs are read")
end

-- Store ----------------------------------------------------------------------------------------

local function newStore(name) return IdStore.new{ sq3 = S.SQ3, state_path = TMP .. "/" .. name .. ".sqlite3" } end

local function facts(store)
    local conn = store:open()
    local out = {}
    for r in conn:prepare("SELECT md5, fact, src, uuids, sig FROM id_facts ORDER BY md5, fact"):rows() do
        out[#out + 1] = table.concat({ r[1], r[2], r[3], r[4], r[5] or "-" }, " ")
    end
    conn:close()
    return table.concat(out, "\n"), #out
end

do
    local A, B = newStore("A"), newStore("B")
    local old = assert(IdScan.scan("/b/old.epub", scan_deps))
    local new = assert(IdScan.scan("/b/new.epub", scan_deps))

    -- A: the book as first downloaded. B: the same path, file replaced by
    -- the rewritten copy, sidecar kept (its MD5 is the old file's).
    local itemA = { path = "/b/book.epub", md5 = "md5old", size = 10, mtime = 100 }
    check(A:recordScan(itemA, old, "devA") == 1, "same MD5 as the sidecar: one fact")
    local itemB = { path = "/b/book.epub", md5 = "md5old", size = 11, mtime = 200 }
    check(B:recordScan(itemB, new, "devB") == 2, "file replaced under its sidecar: two facts")
    local _, nb = facts(B)
    check(nb == 2, "both kept")
    local conn = B:open()
    local side = conn:rowexec("SELECT sig FROM id_facts WHERE md5 = 'md5old' AND src = 'sidecar'")
    conn:close()
    check(side == nil, "the sidecar's fact has no signature")
    check(B:recordScan(itemB, new, "devB") == 0, "the same again: nothing new")

    -- What to read again.
    check(#A:toScan{ itemA } == 0, "unchanged file not read again")
    check(#A:toScan{ { path = itemA.path, md5 = "md5old", size = 12, mtime = 100 } } == 1, "changed size: read again")
    check(#A:toScan{ { path = itemA.path, md5 = "md5other", size = 10, mtime = 100 } } == 1, "changed MD5: read again")
    check(#A:toScan{ { path = "/b/other.epub", md5 = "m", size = 1, mtime = 1 } } == 1, "new file: read")
    check(A:recordScan({ path = "/b/plain.epub", md5 = "mp", size = 1, mtime = 1 }, nil, "devA") == 0
        and #A:toScan{ { path = "/b/plain.epub", md5 = "mp", size = 1, mtime = 1 } } == 0,
        "unreadable file: no facts, not read again until it changes")
    check(A:keepScanned{ [itemA.path] = true } == 1 and #A:toScan{ { path = "/b/plain.epub", md5 = "mp", size = 1, mtime = 1 } } == 1,
        "gone files forgotten")

    -- Export and import.
    local seg = TMP .. "/A-1.jsonl"
    local exp = A:export{ device_id = "devA", out_path = seg, now = 1, max_records = 100 }
    check(exp and exp.records == 1 and not exp.more, "export")
    check(A:markExported(seg, "devA", "id-0000000001.jsonl.zst", exp.size, nil, 2) == 1
        and A:export{ device_id = "devA", out_path = seg, now = 1, max_records = 100 } == nil,
        "nothing left to send after the upload")
    local segB = TMP .. "/B-1.jsonl"
    local expB = B:export{ device_id = "devB", out_path = segB, now = 1, max_records = 1 }
    check(expB and expB.records == 1 and expB.more, "export capped, more to come")
    B:markExported(segB, "devB", "id-0000000001.jsonl.zst", expB.size, nil, 2)
    local segB2 = TMP .. "/B-2.jsonl"
    expB = B:export{ device_id = "devB", out_path = segB2, now = 1, max_records = 100 }
    check(expB and expB.records == 1 and not expB.more, "the rest next time")

    local res = assert(A:importSegment(segB, "devB", "id-0000000001.jsonl.zst", 1, nil, 3))
    check(res.records == 1, "import counted")
    assert(A:importSegment(segB2, "devB", "id-0000000002.jsonl.zst", 1, nil, 3))
    assert(B:importSegment(seg, "devA", "id-0000000001.jsonl.zst", 1, nil, 3))
    check(facts(A) == facts(B), "same facts on both devices")
    local again = assert(A:importSegment(segB, "devB", "id-0000000001.jsonl.zst", 1, nil, 4))
    check(again.applied == 0, "importing again changes nothing")
    S.writeFile(TMP .. "/junk.jsonl", "nonsense\n")
    local nothing, ferr, kind = A:importSegment(TMP .. "/junk.jsonl", "devB", "id-0000000009.jsonl.zst", 1, nil, 4)
    check(nothing == nil and kind == "format", "bad segment reported as such (" .. tostring(ferr) .. ")")

    -- A fact this device also has, received from another: not sent again.
    local C = newStore("C")
    C:recordScan(itemA, old, "devC")
    assert(C:importSegment(seg, "devA", "id-0000000001.jsonl.zst", 1, nil, 3))
    check(C:export{ device_id = "devC", out_path = TMP .. "/C.jsonl", now = 1, max_records = 100 } == nil,
        "a fact received from elsewhere isn't sent again")
    C:requeueAll()
    local cexp = C:export{ device_id = "devC", out_path = TMP .. "/C.jsonl", now = 1, max_records = 100 }
    check(cexp and cexp.records == 1, "everything sent again after a change of folder")

    -- Groups: the two versions are one book.
    local groups = A:groups()
    check(#groups == 1 and #groups[1].md5s == 2 and groups[1].md5s[1] == "md5new" and groups[1].md5s[2] == "md5old"
        and groups[1].sigs == 1 and groups[1].ok, "one book in two versions, same body")
    local counts = A:counts()
    check(counts.versions == 1 and counts.editions == 0 and counts.held == 0 and counts.files == 2, "counts")
end

do
    local G = newStore("G")
    local function fact(md5, uuids, sig, title, authors)
        G:recordScan({ path = "/g/" .. md5, md5 = md5, size = 1, mtime = 1 },
            { md5 = md5, uuids = uuids, sig = sig, title = title, authors = authors }, "devG")
    end
    local U = {}
    for i = 1, 12 do U[i] = string.format("00000000-0000-4000-8000-%012d", i) end
    -- Linked through a UUID each shares with the next.
    fact("x1", { U[1] }, "s1", "Book", "Ann")
    fact("x2", { U[1], U[2] }, "s1", "Book", "Ann")
    fact("x3", { U[2] }, "s1", "Book (revised)", "Ann")
    -- Another edition kept the UUID: other body.
    fact("e1", { U[3] }, "s2", "Edition", "Bo")
    fact("e2", { U[3] }, "s3", "Edition", "Bo")
    -- Unrelated books with one UUID: titles and authors differ.
    fact("u1", { U[4] }, "s4", "Cats", "Cy")
    fact("u2", { U[4] }, "s5", "Dogs", "Di")
    -- A book on its own.
    fact("solo", { U[5] }, "s6", "Solo", "Sol")
    -- Too many files under one UUID.
    for i = 1, IdStore.MAX_GROUP + 1 do fact("m" .. i, { U[6] }, "s7", "Many", "Mo") end
    local groups = G:groups()
    local by = {}
    for _, g in ipairs(groups) do by[g.md5s[1]] = g end
    check(#groups == 4, "four groups of two or more (" .. #groups .. ")")
    check(by.x1 and #by.x1.md5s == 3 and by.x1.ok and by.x1.sigs == 1, "transitive: three files, one body")
    check(by.e1 and by.e1.ok and by.e1.sigs == 2, "two editions under one UUID")
    check(by.u1 and not by.u1.ok and by.u1.why == "titles and authors differ", "unrelated books held")
    check(by.m1 and not by.m1.ok, "oversized group held")
    local c = G:counts()
    check(c.versions == 1 and c.editions == 1 and c.held == 2, "counts by kind")

    -- Position peers (level 2), from the joined groups.
    G:refreshGroups()
    local function same(list, want) return table.concat(list, ",") == want end
    check(same(G:positionPeers("x2"), "x1,x3"), "peers: the other versions with the same body")
    check(same(G:positionPeers("e1"), ""), "peers: another edition isn't one")
    check(same(G:positionPeers("u1"), "") and same(G:positionPeers("m1"), ""), "peers: held groups give none")
    check(same(G:positionPeers("solo"), "") and same(G:positionPeers("nope"), ""), "peers: none for a lone or unknown MD5")
    -- A sidecar's MD5 (no signature of its own) joins at level 1 only.
    G:recordScan({ path = "/g/replaced", md5 = "side", size = 1, mtime = 1 },
        { md5 = "x4", uuids = { U[1] }, sig = "s1", title = "Book", authors = "Ann" }, "devG")
    G:refreshGroups()
    check(same(G:positionPeers("side"), ""), "peers: none for an MD5 without a signature")
    check(same(G:positionPeers("x1"), "x2,x3,x4"), "peers: not the signatureless MD5")
    check(next(G:refreshGroups()) == nil, "refresh again: nothing changed")
    -- Another device read the original file: its signature joins it at level 2.
    G:recordScan({ path = "/g/original", md5 = "side", size = 1, mtime = 1 },
        { md5 = "side", uuids = { U[1] }, sig = "s1", title = "Book", authors = "Ann" }, "devH")
    local changed = G:refreshGroups()
    check(changed.side and changed.x1 and not changed.e1, "a signature arriving later: its group is refreshed")
    check(same(G:positionPeers("side"), "x1,x2,x3,x4"), "peers: now with the signature")
end

-- Progress sync hook ---------------------------------------------------------------------------

do
    local ProgressHook = require("omnisync/progresshook")
    local P = ProgressHook.pick
    check(P({ percentage = 0.2, timestamp = 10 }, { { percentage = 0.1, timestamp = 20 } }).timestamp == 20,
        "pick: newest wins, even if behind")
    check(P({ percentage = 0.2, timestamp = 30 }, { { percentage = 0.5, timestamp = 20 } }).timestamp == 30,
        "pick: own kept when newest")
    check(P({}, { { percentage = 0.5, timestamp = 1 } }).percentage == 0.5, "pick: nothing for this MD5, another's")
    check(P({ percentage = 0.2 }, { { percentage = 0.5 } }).percentage == 0.2, "pick: no timestamps, own kept")
    check(P(nil, { { percentage = 0.3 }, { percentage = 0.6 } }).percentage == 0.6, "pick: no timestamps, furthest")

    -- A stand-in for KOSyncClient and its server.
    local server = {
        own = { percentage = 0.1, progress = "/body/a", timestamp = 100, device_id = "d1" },
        peer1 = { percentage = 0.4, progress = "/body/b", timestamp = 300, device_id = "d2" },
        peer2 = { percentage = 0.3, progress = "/body/c", timestamp = 200, device_id = "d3" },
    }
    local down, asked = {}, {}
    local queue = {}
    local Client = {}
    function Client:get_progress(_, _, document, callback)
        asked[#asked + 1] = document
        if down[document] then return callback(false, nil) end
        callback(true, server[document] or {})
    end
    local peers = { own = { "peer1", "peer2", "gone" } }
    check(ProgressHook.install(Client, {
        peers = function(md5) if md5 == "boom" then error("db locked") end return peers[md5] or {} end,
        schedule = function(fn) queue[#queue + 1] = fn end,
    }), "hook installed")
    check(not ProgressHook.install(Client, { peers = function() return {} end, schedule = function() end }),
        "installed once only")
    local function run()
        while #queue > 0 do table.remove(queue, 1)() end
    end
    local function get(doc)
        asked = {}
        local got
        Client:get_progress("u", "k", doc, function(ok, body) got = { ok = ok, body = body } end)
        run()
        return got
    end

    local g = get("own")
    check(g.ok and g.body.progress == "/body/b" and table.concat(asked, ",") == "own,peer1,peer2,gone",
        "the newest position among the versions")
    server.own.timestamp = 400
    g = get("own")
    check(g.ok and g.body.progress == "/body/a", "this version's own when it's newest")
    server.own = nil
    g = get("own")
    check(g.ok and g.body.progress == "/body/b", "nothing for this MD5: another version's")
    down.peer1 = true
    g = get("own")
    check(g.ok and g.body.progress == "/body/c", "a failed request for another version is skipped")
    down.own = true
    g = get("own")
    check(not g.ok and #asked == 1, "this MD5's request failed: reported, nothing else asked")
    g = get("lonely")
    check(g.ok and #asked == 1 and g.body.percentage == nil, "no other versions: one request, as before")
    g = get("boom")
    check(g.ok and #asked == 1, "a failed lookup leaves progress sync as it was")
end

-- Packing ---------------------------------------------------------------------------------

do
    local P = newStore("P")
    local function seg(name, recs)
        local lines = { IdFormat.headerLine("devP", 1) }
        for _, r in ipairs(recs) do lines[#lines + 1] = IdFormat.recordLine(r) end
        lines[#lines + 1] = IdFormat.trailerLine(#recs)
        local path = TMP .. "/" .. name
        S.writeFile(path, table.concat(lines, "\n") .. "\n")
        return path
    end
    local u = { "00000000-0000-4000-8000-000000000001" }
    local r1 = { md5 = "a", src = "file", uuids = u, sig = "s" }
    local r2 = { md5 = "b", src = "file", uuids = u, sig = "s", title = "T" }
    local r3 = { md5 = "a", src = "sidecar", uuids = u }
    local p1, p2 = seg("p1.jsonl", { r1, r2 }), seg("p2.jsonl", { r2, r3 })
    local b = Pack.builder("id")
    b:add(assert(b:read(p1)))
    b:add(assert(b:read(p2)))
    check(b:count() == 3, "pack: each distinct record once")
    local out = TMP .. "/pack.jsonl"
    assert(b:write(out, "devP", 2))
    local Q = newStore("Q")
    assert(P:importSegment(p1, "devP", "id-0000000001.jsonl.zst", 1, nil, 1))
    assert(P:importSegment(p2, "devP", "id-0000000002.jsonl.zst", 1, nil, 1))
    assert(Q:importSegment(out, "devP", "id-0000000003.jsonl.zst", 1, nil, 1))
    check(facts(P) == facts(Q), "a pack gives the same facts as its segments")
end

-- Cloud library's side: links, files never opened, book states ---------------------------------

do
    local BookStore = require("omnisync/bookstore")
    local AnnFormat = require("omnisync/annformat")
    local Identity = require("omnisync/identity")
    local L = newStore("L")
    local U = {}
    for i = 1, 9 do U[i] = string.format("00000000-0000-4000-8000-%012d", i) end
    local function fact(md5, uuids, sig, title)
        L:recordScan({ path = "/l/" .. md5, md5 = md5, size = 1, mtime = 1 },
            { md5 = md5, uuids = uuids, sig = sig, title = title or "Book", authors = "Ann" }, "devA")
    end
    fact("e1", { U[1], U[4] }, "s1")
    fact("e2", { U[1] }, "s1")
    fact("e3", { U[4] }, "s1")
    fact("z", { U[9] }, "s9", "Other")
    fact("r", { U[2] }, "s2", "Third")

    -- A PDF Cloud library matched by title joins its book (level 1 only).
    check(L:link({ { md5 = "p1", uuids = { U[1]:upper() }, title = "Book", authors = "Ann" } }, "devA") == 1,
        "link recorded")
    check(L:link({ { md5 = "p1", uuids = { U[1] }, title = "Book", authors = "Ann" } }, "devA") == 0,
        "the same link again: nothing new")
    -- A file's own facts win over a link for its MD5.
    L:link({ { md5 = "e1", uuids = { U[9] } } }, "devA")
    -- Links that disagree leave the MD5 out.
    L:link({ { md5 = "q", uuids = { U[2] } }, { md5 = "q", uuids = { U[3] } } }, "devA")
    L:refreshGroups()
    local groups = L:groups()
    local of = {}
    for _, g in ipairs(groups) do for _, m in ipairs(g.md5s) do of[m] = table.concat(g.md5s, ",") end end
    check(of.p1 == "e1,e2,e3,p1", "linked PDF in the book's group (" .. tostring(of.p1) .. ")")
    check(of.z == nil, "a link doesn't override the file's own UUIDs")
    check(of.q == nil and of.r == nil, "conflicting links: the MD5 isn't joined")
    check(#L:positionPeers("p1") == 0 and #L:positionPeers("e1") == 2, "a link has no positions")
    local exp = L:export{ device_id = "devA", out_path = TMP .. "/L.jsonl", now = 1, max_records = 100 }
    check(exp and S.readFile(TMP .. "/L.jsonl"):find('"src":"link"', 1, true), "links are sent")

    -- A file never opened (no sidecar MD5): read once, again once opened.
    local item = { path = "/l/new.epub", size = 5, mtime = 5 }
    check(L:recordScan(item, { md5 = "n1", uuids = { U[5] }, sig = "s5", title = "New", authors = "N" }, "devA") == 1,
        "unopened file: its own fact")
    check(#L:toScan{ item } == 0, "unopened file not read again")
    check(#L:toScan{ { path = item.path, md5 = "n1", size = 5, mtime = 5 } } == 1, "read again once opened")

    -- Book states by UUID, from every version's book data.
    local B = BookStore.new{ sq3 = S.SQ3, state_path = TMP .. "/L.sqlite3" }
    local conn = B:open()
    local put = conn:prepare([[INSERT INTO book_merged (md5, prop, updated, device, deleted, hash, value)
        VALUES (?, ?, ?, ?, ?, ?, ?);]])
    local function merged(md5, prop, upd, dev, v)
        put:reset():bind(md5, prop, upd, dev, v == nil and 1 or 0, v == nil and "" or "h" .. upd,
            v ~= nil and AnnFormat.encodeValue(v) or nil):step()
    end
    merged("e1", "status", 10, "devA", "reading")
    merged("e2", "status", 20, "devB", "complete")
    merged("p1", "rating", 5, "devA", 4)
    merged("e2", "hist", 30, "devB", 1700000000)
    merged("z", "rating", 9, "devA", 2)
    put:close()
    conn:close()
    local states = B:statesByUuid(IdStore.usedFacts)
    local s1 = states[U[1]]
    check(s1 and s1.status == "complete" and s1.rating == 4 and s1.last_read == 1700000000 and s1.last_device == "devB",
        "state: newest status, the linked PDF's rating, last read")
    check(states[U[4]] and states[U[4]].status == "complete", "state through the joined group (another UUID)")
    check(states[U[9]] and states[U[9]].rating == 2 and states[U[9]].status == nil, "a book on its own")
    check(states[U[5]] == nil, "nothing known: no state")
    conn = B:open()
    conn:exec("INSERT OR REPLACE INTO book_merged (md5, prop, updated, device, deleted, hash) VALUES ('e3', 'rating', 50, 'devC', 1, '');")
    conn:close()
    check(B:statesByUuid(IdStore.usedFacts)[U[1]].rating == nil, "a later clear on another version wins")

    -- The interface other plugins use.
    check(not Identity.available() and Identity.bookState({ U[1] }) == nil, "not set up: nothing")
    local refreshed, this_device, names = 0, "devB", {}
    local scanned = {}
    Identity.setup{
        id_store = function() return L end, book_store = function() return B end,
        device_id = function() return this_device end,
        device_names = function() return names end,
        files = function() return { ["/l/opened.pdf"] = { md5 = "sidecarmd5" } } end,
        handles = IdScan.handles,
        scan = function(path)
            scanned[#scanned + 1] = path
            return { md5 = "fresh", uuids = { U[6] }, sig = "s6", title = "Fresh", authors = "F" }
        end,
        refresh = function() refreshed = refreshed + 1 end,
        logger = { warn = function() end },
    }
    local st = Identity.bookState({ U[1]:upper() })
    check(st and st.status == "complete" and st.last_device == Identity.THIS_DEVICE, "last read on this device")
    this_device = "devC"
    local rev = Identity.revision()
    local told = 0
    Identity.onChanged("test", function() told = told + 1 end)
    Identity.changed()
    check(Identity.revision() ~= rev and told == 1, "changes: revision moves, listeners told")
    check(Identity.bookState({ U[1] }).last_device == nil, "unnamed device: no name")
    names.devB = "Kobo Forma"
    check(Identity.bookState({ U[1] }).last_device == "Kobo Forma", "named device")
    check(Identity.bookState({ U[7] }) == nil and Identity.bookState("junk") == nil, "unknown book: nil")

    check(Identity.recordLinks({ { path = "/l/opened.pdf", md5 = "filemd5", uuids = { U[7] } },
        { path = "/l/none.pdf", uuids = { U[7] } } }) == 1, "links: those with an MD5 recorded")
    conn = L:open()
    check(conn:rowexec("SELECT count(*) FROM id_facts WHERE src = 'link' AND md5 = 'sidecarmd5'") == 1,
        "a book opened here is linked under its sidecar's MD5")
    conn:close()

    local real_lfs = package.loaded["libs/libkoreader-lfs"]
    package.loaded["libs/libkoreader-lfs"] = { attributes = function(path)
        if path:match("%.epub$") or path:match("%.pdf$") then return { mode = "file", size = 9, modification = 9 } end
    end }
    check(Identity.fileAdded("/l/fresh.epub") == 1 and refreshed == 1 and scanned[1] == "/l/fresh.epub",
        "a download read at once, groups refreshed")
    check(Identity.fileAdded("/l/fresh.epub") == 0 and #scanned == 1, "not read twice")
    check(Identity.fileAdded("/l/fresh.pdf") == 0 and #scanned == 1, "files the scanner doesn't read are skipped")
    package.loaded["libs/libkoreader-lfs"] = real_lfs
end

S.finish("omnisync identity tests")
