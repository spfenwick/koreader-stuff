-- Unit tests for Concordance's book identity: the record format
-- (concordance/idformat.lua), reading book files (concordance/idscan.lua, with
-- archives stood in for), the store (concordance/idstore.lua) and packing.
-- Run through scripts/test-concordance.sh, which sets KOREADER_SRC.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local IdFormat = require("concordance/idformat")
local IdScan = require("concordance/idscan")
local IdStore = require("concordance/idstore")
local Pack = require("concordance/pack")

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
    S.writeFile(path, '{"t":"h","format":"statsync-id","v":3,"device":"devA"}\n' .. IdFormat.trailerLine(0) .. "\n")
    check(IdFormat.readSegment(path) == nil, "newer major version rejected")

    -- Version 2: unlinks and numbered links.
    local link0 = { md5 = "m", src = "link", uuids = { U_LIB } }
    local link1 = { md5 = "m", src = "link", uuids = { U_LIB }, n = 1 }
    local unlink0 = { md5 = "m", src = "unlink", uuids = { U_LIB } }
    check(IdFormat.factKey(link0) ~= IdFormat.factKey(link1) and IdFormat.factKey(link0) ~= IdFormat.factKey(unlink0)
        and IdFormat.factKey(link0) == IdFormat.factKey{ md5 = "m", src = "link", uuids = { U_LIB }, n = 0 },
        "fact key: a link's number matters, 0 is as none")
    check(not IdFormat.needsV2(link0) and IdFormat.needsV2(link1) and IdFormat.needsV2(unlink0), "what needs version 2")
    check(IdFormat.validRecord(link1) and IdFormat.validRecord(unlink0)
        and not IdFormat.validRecord{ md5 = "m", src = "file", uuids = { U_LIB }, n = 1 }
        and not IdFormat.validRecord{ md5 = "m", src = "link", uuids = { U_LIB }, n = IdFormat.MAX_N + 1 }
        and not IdFormat.validRecord{ md5 = "m", src = "link", uuids = { U_LIB }, n = 1.5 }
        and not IdFormat.validRecord{ md5 = "m", src = "unlink", uuids = { U_LIB }, sig = "s" },
        "numbers only on links and unlinks, whole and in range")
    S.writeFile(path, table.concat({ IdFormat.headerLine("devA", 1, 2), IdFormat.recordLine(link1),
        IdFormat.recordLine(unlink0), IdFormat.trailerLine(2) }, "\n") .. "\n")
    local got2 = {}
    local h2 = IdFormat.readSegment(path, { record = function(rec) got2[#got2 + 1] = rec end })
    check(h2 and h2.v == 2 and h2.needs_v2 and got2[1].n == 1 and got2[2].src == "unlink" and got2[2].n == nil,
        "version 2 segment round trip")
    check(IdFormat.headerLine("devA", 1):find('"v":1', 1, true), "segments say version 1 unless told otherwise")
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
    -- A spine file that can't be read: no signature, rather than one that
    -- another damaged book could share.
    addBook("/b/holed1.epub", "md5h1", OPF9, CH1, CH2)
    addBook("/b/holed2.epub", "md5h2", OPF9, CH1:gsub("dark", "stormy"), CH2)
    archives["/b/holed1.epub"].entries["OEBPS/text/ch1.html"] = nil
    archives["/b/holed2.epub"].entries["OEBPS/text/ch1.html"] = nil
    for _, a in ipairs({ archives["/b/holed1.epub"], archives["/b/holed2.epub"] }) do
        a.order = { "mimetype", "OEBPS/text/ch 2.html", "META-INF/container.xml", "OEBPS/content.opf" }
    end
    local h1 = assert(IdScan.scan("/b/holed1.epub", scan_deps))
    check(h1.sig == nil and #h1.uuids == 2, "a spine file missing: UUIDs read, no signature")
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
    for i = 1, IdStore.MAX_GROUP + 1 do fact(string.format("m%02d", i), { U[6] }, "sm" .. i, "Many", "Mo") end
    -- Many rewrites of one book: one body, however many files.
    for i = 1, IdStore.MAX_GROUP + 3 do fact(string.format("w%02d", i), { U[7] }, "sw", "Rewritten", "Rae") end
    local groups = G:groups()
    local by = {}
    for _, g in ipairs(groups) do by[g.md5s[1]] = g end
    check(#groups == 5, "five groups of two or more (" .. #groups .. ")")
    check(by.x1 and #by.x1.md5s == 3 and by.x1.ok and by.x1.sigs == 1, "transitive: three files, one body")
    check(by.e1 and by.e1.ok and by.e1.sigs == 2, "two editions under one UUID")
    check(by.u1 and not by.u1.ok and by.u1.why == "titles differ", "unrelated books held")
    check(by.m01 and not by.m01.ok, "oversized group held")
    check(by.w01 and by.w01.ok and #by.w01.md5s == IdStore.MAX_GROUP + 3 and by.w01.bodies == 1,
        "many rewrites of one body: joined")
    local c = G:counts()
    check(c.versions == 2 and c.editions == 1 and c.held == 2, "counts by kind")

    -- Position peers (level 2), from the joined groups.
    G:refreshGroups()
    local function same(list, want) return table.concat(list, ",") == want end
    check(same(G:positionPeers("x2"), "x1,x3"), "peers: the other versions with the same body")
    check(same(G:positionPeers("e1"), ""), "peers: another edition isn't one")
    check(same(G:positionPeers("u1"), "") and same(G:positionPeers("m01"), ""), "peers: held groups give none")
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
    local ProgressHook = require("concordance/progresshook")
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
    if debug.getinfo(function(_a) end, "u").nparams then
        local Changed = { get_progress = function(_self, _u, _k, _doc, _cb, _extra) end }
        local before = Changed.get_progress
        check(not ProgressHook.install(Changed, { peers = function() return {} end, schedule = function() end })
            and Changed.get_progress == before, "not installed over a changed signature")
        check(not ProgressHook.compatible(function(...) end), "a vararg get_progress isn't taken as the same")
    end
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

-- Athenaeum's side: links, files never opened, book states ---------------------------------

do
    local BookStore = require("concordance/bookstore")
    local AnnFormat = require("concordance/annformat")
    local Identity = require("concordance/identity")
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

    -- A PDF Athenaeum matched by title joins its book (level 1 only).
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

-- Which files sharing a UUID are one book ---------------------------------------------------

do
    local J = newStore("J")
    local U = {}
    for i = 1, 20 do U[i] = string.format("00000000-0000-4000-9000-%012d", i) end
    local function fact(md5, uuids, sig, title, authors)
        J:recordScan({ path = "/j/" .. md5, md5 = md5, size = 1, mtime = 1 },
            { md5 = md5, uuids = uuids, sig = sig, title = title, authors = authors }, "devJ")
    end
    -- A series from one template: a publisher's UUID on every volume, the
    -- same author, each with a UUID of its own.
    fact("v1", { U[1], U[2] }, "sv1", "Saga, Volume 1", "Ann")
    fact("v2", { U[1], U[3] }, "sv2", "Saga, Volume 2", "Ann")
    -- Title and author both corrected in Calibre: both UUIDs kept.
    fact("t1", { U[4], U[5] }, "st1", "Teh Book", "Smith, J")
    fact("t2", { U[4], U[5] }, "st2", "The Book: A Novel", "John Smith")
    -- Retitled, one UUID, but the same text.
    fact("b1", { U[6] }, "sb", "Working Title", "Bo")
    fact("b2", { U[6] }, "sb", "Final Title", "Bo")
    -- A new edition, retitled, one UUID, other text: taken for another book.
    fact("n1", { U[7] }, "sn1", "First Edition", "Ned")
    fact("n2", { U[7] }, "sn2", "Second Edition", "Ned")
    -- One file that doesn't fit leaves the others joined.
    fact("o1", { U[8] }, "so1", "Same", "Oz")
    fact("o2", { U[8] }, "so2", "Same", "Oz")
    fact("o3", { U[8] }, "so3", "Something Else", "Oz")
    -- A file without a title joins on its UUID.
    fact("q1", { U[9] }, "sq1", "Titled", "Q")
    fact("q2", { U[9] }, "sq2", nil, nil)
    J:refreshGroups()
    local of, held = {}, {}
    for _, g in ipairs(J:groups()) do
        for _, m in ipairs(g.md5s) do
            if g.ok then of[m] = table.concat(g.md5s, ",") else held[m] = g.why end
        end
    end
    check(of.v1 == nil and of.v2 == nil and held.v1 == "titles differ", "a series sharing a publisher's UUID: not joined")
    check(of.t1 == "t1,t2", "title and author both edited, two UUIDs shared: joined")
    check(of.b1 == "b1,b2", "retitled, the same text: joined")
    check(of.n1 == nil and held.n1 == "titles differ", "retitled, one UUID, other text: not joined")
    check(of.o1 == "o1,o2" and of.o3 == nil and held.o3 == "titles differ", "the file that doesn't fit stays out, the rest join")
    check(of.q1 == "q1,q2", "a file without a title joins on its UUID")
    -- A catalog's own ID for the book (a link names it) joins whatever the titles.
    J:link({ { md5 = "pdf", uuids = { U[7] }, title = "Second Edition" } }, "devJ")
    J:refreshGroups()
    of = {}
    for _, g in ipairs(J:groups()) do
        if g.ok then for _, m in ipairs(g.md5s) do of[m] = table.concat(g.md5s, ",") end end
    end
    check(of.n1 == "n1,n2,pdf", "a catalog's ID for the book: its files join whatever their titles (" .. tostring(of.n1) .. ")")
    -- A UUID on very many files is some tool's constant: it joins nothing.
    local K = newStore("K")
    for i = 1, IdStore.MAX_CARRIERS + 1 do
        K:recordScan({ path = "/k/" .. i, md5 = "k" .. i, size = 1, mtime = 1 },
            { md5 = "k" .. i, uuids = { U[20] }, sig = "sk" .. i, title = "Same Title" }, "devK")
    end
    K:refreshGroups()
    local kg = K:groups()
    check(#kg == 1 and not kg[1].ok and #K:positionPeers("k1") == 0, "a UUID on very many files joins nothing")
end

-- Links withdrawn and made again -------------------------------------------------------------

do
    local U = {}
    for i = 1, 9 do U[i] = string.format("00000000-0000-4000-a000-%012d", i) end
    local A, B = newStore("RA"), newStore("RB")
    local function groupOf(store, md5)
        store:refreshGroups()
        for _, g in ipairs(store:groups()) do
            if g.ok then for _, m in ipairs(g.md5s) do if m == md5 then return table.concat(g.md5s, ",") end end end
        end
    end
    local function always() return true end
    A:recordScan({ path = "/r/e", md5 = "e", size = 1, mtime = 1 }, { md5 = "e", uuids = { U[1] }, sig = "s", title = "Book" }, "devA")
    check(A:link({ { md5 = "p", uuids = { U[1] }, title = "Book" } }, "devA") == 1 and groupOf(A, "p") == "e,p", "linked")
    local function uuidsOf(store, md5) return table.concat((store:uuids({ [md5] = true }))[md5] or {}, ",") end
    check(uuidsOf(A, "p") == U[1], "a linked file's UUIDs")

    -- Nothing to withdraw while the match is still made, the file isn't
    -- there to speak for, or the book isn't in the catalog just now.
    check(A:retract{ device = "devA", present = { p = true }, current = { p = { [U[1]] = true } }, known = always } == 0,
        "still matched: kept")
    check(A:retract{ device = "devA", present = {}, current = {}, known = always } == 0, "file not there: kept")
    check(A:retract{ device = "devA", present = { p = true }, current = {}, known = function() return false end } == 0,
        "book not in the catalog just now: kept")
    check(A:retract{ device = "devOther", present = { p = true }, current = {}, known = always } == 0,
        "another device's link: not this one's to withdraw")
    -- No longer matched: withdrawn.
    check(A:retract{ device = "devA", present = { p = true }, current = {}, known = always } == 1, "withdrawn")
    check(A:retract{ device = "devA", present = { p = true }, current = {}, known = always } == 0, "only once")
    check(groupOf(A, "p") == nil and uuidsOf(A, "p") == "", "a withdrawn link joins nothing and names no UUID")

    -- Sent as version 2, and the same on a device that gets the records in
    -- another order.
    local segA = TMP .. "/RA.jsonl"
    local exp = A:export{ device_id = "devA", out_path = segA, now = 1, max_records = 100 }
    check(exp and exp.records == 3 and S.readFile(segA):find('"v":2', 1, true) and S.readFile(segA):find('"src":"unlink"', 1, true),
        "the unlink is sent, in a version 2 segment")
    A:markExported(segA, "devA", "id-0000000001.jsonl.zst", 1, nil, 1)
    local recs = {}
    IdFormat.readSegment(segA, { record = function(r) recs[#recs + 1] = r end })
    local rev = TMP .. "/RA-reversed.jsonl"
    local lines = { IdFormat.headerLine("devA", 1, 2) }
    for i = #recs, 1, -1 do lines[#lines + 1] = IdFormat.recordLine(recs[i]) end
    lines[#lines + 1] = IdFormat.trailerLine(#recs)
    S.writeFile(rev, table.concat(lines, "\n") .. "\n")
    check(B:importSegment(rev, "devA", "id-0000000001.jsonl.zst", 1, nil, 1), "imported")
    check(groupOf(B, "p") == nil and uuidsOf(B, "p") == "", "withdrawn on the other device too, whatever the order")

    -- Matched again: a link numbered above the unlink counts.
    check(B:link({ { md5 = "p", uuids = { U[1] }, title = "Book" } }, "devB") == 1 and groupOf(B, "p") == "e,p",
        "matched again: linked again")
    check(B:link({ { md5 = "p", uuids = { U[1] }, title = "Book" } }, "devB") == 0, "and only once")
    local segB = TMP .. "/RB.jsonl"
    B:export{ device_id = "devB", out_path = segB, now = 2, max_records = 100 }
    check(S.readFile(segB):find('"n":1', 1, true), "the new link carries its number")
    A:importSegment(segB, "devB", "id-0000000001.jsonl.zst", 1, nil, 2)
    check(groupOf(A, "p") == "e,p", "and counts where the unlink was made")
    -- That link is the other device's: this one leaves it alone.
    check(A:retract{ device = "devA", present = { p = true }, current = {}, known = always } == 0,
        "the newer link is another device's")

    -- Devices that keep disagreeing: it stays withdrawn in the end.
    local C = newStore("RC")
    local made = 0
    for _ = 1, IdFormat.MAX_N + 3 do
        made = made + C:link({ { md5 = "x", uuids = { U[2] } } }, "devC")
        C:retract{ device = "devC", present = { x = true }, current = {}, known = always }
    end
    check(made == IdFormat.MAX_N + 1 and C:link({ { md5 = "x", uuids = { U[2] } } }, "devC") == 0,
        "made and withdrawn too often: stays withdrawn")

    -- A database from before unlinks gets the new column.
    local old_path = TMP .. "/old-id.sqlite3"
    local oc = S.SQ3.open(old_path)
    oc:exec([[CREATE TABLE id_facts (md5 TEXT NOT NULL, fact TEXT NOT NULL, src TEXT NOT NULL, uuids TEXT NOT NULL,
        sig TEXT, title TEXT, authors TEXT, ids TEXT, device TEXT NOT NULL, PRIMARY KEY (md5, fact)) WITHOUT ROWID;]])
    oc:exec("INSERT INTO id_facts VALUES ('p', 'p|link|" .. U[3] .. "|', 'link', '" .. U[3] .. "', NULL, 'T', NULL, NULL, 'devO');")
    oc:exec("INSERT INTO id_facts VALUES ('e', 'e|file|" .. U[3] .. "|s', 'file', '" .. U[3] .. "', 's', 'T', NULL, NULL, 'devO');")
    oc:close()
    local O = IdStore.new{ sq3 = S.SQ3, state_path = old_path }
    check(groupOf(O, "p") == "e,p", "an older database: its links still count")
    check(O:retract{ device = "devO", present = { p = true }, current = {}, known = always } == 1 and groupOf(O, "p") == nil,
        "and can be withdrawn")

    -- Through the interface: a file's links are found under its sidecar's
    -- MD5 or its own.
    local Identity = require("concordance/identity")
    local BookStore = require("concordance/bookstore")
    local R = newStore("RI")
    Identity.setup{
        id_store = function() return R end,
        book_store = function() return BookStore.new{ sq3 = S.SQ3, state_path = TMP .. "/RI.sqlite3" } end,
        device_id = function() return "devI" end, device_names = function() return {} end,
        files = function() return { ["/c/opened.pdf"] = { md5 = "side" } } end,
        handles = function() return false end, scan = function() end, refresh = function() end,
        logger = { warn = function(...) print("identity warning:", ...) end },
    }
    local links = { { path = "/c/opened.pdf", md5 = "own1", uuids = { U[4] } }, { path = "/c/other.pdf", md5 = "own2", uuids = { U[5] } } }
    check(Identity.recordLinks(links) == 2, "two links recorded")
    local folder = { { path = "/c/opened.pdf", md5 = "own1" }, { path = "/c/other.pdf", md5 = "own2" } }
    local in_catalog = function(u) return u == U[4] or u == U[5] end
    check(Identity.retractLinks(links, folder, in_catalog) == 0, "all still matched: nothing withdrawn")
    check(Identity.retractLinks({ links[2] }, folder, in_catalog) == 1, "the match that's gone is withdrawn")
    local rc = R:open()
    check(rc:rowexec("SELECT count(*) FROM id_facts WHERE src = 'unlink' AND md5 = 'side'") == 1,
        "under the sidecar's MD5, where the link was")
    rc:close()
    check(Identity.retractLinks({}, {}, in_catalog) == 0 and Identity.retractLinks({}, { folder[2] }, function() error("x") end) == 0,
        "no files, or a lookup that fails: nothing withdrawn")

    -- A UUID named by files that aren't one book is no book's state.
    local SB = BookStore.new{ sq3 = S.SQ3, state_path = TMP .. "/RS.sqlite3" }
    local SI = newStore("RS")
    SI:recordScan({ path = "/s/1", md5 = "s1", size = 1, mtime = 1 }, { md5 = "s1", uuids = { U[6] }, sig = "a", title = "One" }, "d")
    SI:recordScan({ path = "/s/2", md5 = "s2", size = 1, mtime = 1 }, { md5 = "s2", uuids = { U[6] }, sig = "b", title = "Two" }, "d")
    SI:recordScan({ path = "/s/3", md5 = "s3", size = 1, mtime = 1 }, { md5 = "s3", uuids = { U[7] }, sig = "c", title = "Three" }, "d")
    SI:refreshGroups()
    local sc = SB:open()
    sc:exec("INSERT INTO book_merged (md5, prop, updated, device, deleted, hash, value) VALUES ('s1', 'rating', 1, 'd', 0, 'h', '5');")
    sc:exec("INSERT INTO book_merged (md5, prop, updated, device, deleted, hash, value) VALUES ('s3', 'rating', 1, 'd', 0, 'h', '3');")
    sc:close()
    local sts = SB:statesByUuid(IdStore.usedFacts)
    check(sts[U[6]] == nil and sts[U[7]] and sts[U[7]].rating == 3, "an ID shared by different books gives no state")
end

S.finish("concordance identity tests")
