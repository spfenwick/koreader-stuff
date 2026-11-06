-- Integration test for omnisync.koplugin against a real WebDAV server
-- (rclone serve webdav), with simulated devices: each has its own
-- statistics.sqlite3 written by KOReader's statistics plugin code, and runs
-- the real sync engine, with the network step in a forked subprocess as in
-- KOReader. After each scenario every device's page_stat_data (keyed by
-- md5) must be identical, and stored totals must match KOReader's.

local S = dofile("tests/omnisync/support.lua")
local check = S.check

local AnnFormat = require("omnisync/annformat")
local AnnStore = require("omnisync/annstore")
local BookFormat = require("omnisync/bookformat")
local BookStore = require("omnisync/bookstore")
local Codec = require("omnisync/codec")
local Zstd = require("omnisync/zstd")
local Engine = require("omnisync/engine")
local IdFormat = require("omnisync/idformat")
local IdStore = require("omnisync/idstore")
local Store = require("omnisync/store")
local WebDav = require("omnisync/webdav")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/integration"
S.rmrf(TMP)
S.mkdirp(TMP)

local USER, PASS = "reader", "p%ss:wörd"
local server, serr = S.startWebDav(TMP .. "/server", USER, PASS)
if not server then
    print("omnisync integration: skipped (" .. serr .. ")")
    os.exit(0)
end
S.mkdirp(server.dir .. "/books") -- the configured folder
local REMOTE = server.dir .. "/books/statsync"

local loop = S.Loop.new()
local quiet = { info = function() end, warn = function() end, dbg = function() end, err = print }
local verbose = os.getenv("STATSYNC_VERBOSE") and { info = print, warn = print, dbg = function() end, err = print }

local Sim = {}
Sim.__index = Sim
local devices = {}

local function newSim(name)
    local d = S.newDevice(name, TMP .. "/" .. name)
    if not getmetatable(Sim) then setmetatable(Sim, { __index = getmetatable(d) }) end
    local sim = setmetatable(d, Sim)
    sim.id = "dev" .. name .. "-0001"
    sim.online = true
    sim.http_opts = {}
    sim.time_limit = 60
    sim.status = {}
    sim:makeEngine()
    devices[#devices + 1] = sim
    return sim
end

function Sim:makeEngine()
    local sim = self
    self.store = Store.new{ sq3 = S.SQ3, stats_path = self.db, state_path = self.state }
    self.ann_store = AnnStore.new{ sq3 = S.SQ3, state_path = self.state }
    self.book_store = BookStore.new{ sq3 = S.SQ3, state_path = self.state }
    self.id_store = IdStore.new{ sq3 = S.SQ3, state_path = self.state }
    self.engine = Engine.new{
        store = self.store,
        ann = {
            store = self.ann_store,
            enabled = function() return sim.ann_on == true end,
            collect = function() end,
            afterSync = function(run)
                sim.ann_affected = sim.ann_affected or {}
                for id in pairs(run.ann_affected) do sim.ann_affected[id] = true end
            end,
        },
        book = {
            store = self.book_store,
            collect = function() end,
            afterSync = function(run)
                sim.book_affected = sim.book_affected or {}
                for md5 in pairs(run.book_affected) do sim.book_affected[md5] = true end
            end,
        },
        id = {
            store = self.id_store,
            files = function() return sim.id_files or {} end,
            -- Runs in the subprocess, as in KOReader.
            scan = function(item)
                local info = (sim.id_infos or {})[item.path]
                if info then return info end
                return nil, "not an EPUB"
            end,
        },
        logger = verbose or quiet,
        work_dir = self.dir .. "/work",
        tmp_dir = self.dir .. "/work/incoming",
        device_name = "Simulated " .. self.name,
        getDeviceId = function() return sim.id end,
        now = os.time,
        schedule = function(delay, fn) loop:schedule(delay, fn) end,
        poll_interval = 0.05,
        canRun = function() if sim.online then return true end return false, "offline" end,
        flush = function() end,
        spawn = S.Fork.spawn, isDone = S.Fork.isDone, kill = S.Fork.kill,
        makeTransport = function()
            return WebDav.new{ http = S.Http.new(sim.http_opts), address = server.url,
                               username = USER, password = PASS, root = "books/statsync" }
        end,
        saveStatus = function(st) sim.status = st end,
        onDone = function(_, run) sim.last_run = run end,
    }
    self.engine.deps.time_limit = self.time_limit
end

local function idle()
    for _, d in ipairs(devices) do if d.engine.running then return false end end
    return true
end

--- Syncs the given devices (all at the same moment) and waits for them.
local function sync(list)
    for _, d in ipairs(list) do d.engine:request("test") end
    loop:run(300)
    check(idle(), "all syncs finished")
end

--- Syncs everyone (twice, so each sees the others' latest) and checks convergence.
local function converge(label, list)
    list = list or devices
    sync(list)
    sync(list)
    local ref, n = list[1]:dump()
    local same = true
    for i = 2, #list do
        local other = list[i]:dump()
        if other ~= ref then
            same = false
            print(string.format("  %s: %s differs from %s", label, list[i].name, list[1].name))
            if os.getenv("STATSYNC_VERBOSE") then
                local a, b = {}, {}
                for l in ref:gmatch("[^\n]+") do a[l] = true end
                for l in other:gmatch("[^\n]+") do b[l] = true end
                for l in pairs(a) do if not b[l] then print("    only on " .. list[1].name .. ": " .. l) end end
                for l in pairs(b) do if not a[l] then print("    only on " .. list[i].name .. ": " .. l) end end
            end
        end
    end
    check(same, label .. ": all devices have the same page_stat_data (" .. n .. " rows)")
    for _, d in ipairs(list) do
        local ok, why = d:totalsMatch()
        check(ok, label .. ": totals match KOReader on " .. d.name .. (why and (": " .. why) or ""))
        check(d.last_run and not d.last_run.error, label .. ": " .. d.name .. " synced without error"
            .. (d.last_run and d.last_run.error and (": " .. d.last_run.error) or ""))
    end
    return ref
end

local function remoteSegments(id)
    local out = {}
    local p = io.popen("ls -1 " .. S.q(REMOTE .. "/devices/" .. id) .. " 2>/dev/null")
    for name in p:lines() do out[#out + 1] = name end
    p:close()
    return out
end

local function firstSegment(id)
    for _, name in ipairs(remoteSegments(id)) do
        if Codec.segmentSeq(name) then return name end
    end
end

local function allRemoteSegmentsValid(except)
    for _, d in ipairs(devices) do
        for _, name in ipairs(remoteSegments(d.id)) do
            if Codec.segmentSeq(name) and not (except and except[d.id .. "/" .. name]) then
                local plain = TMP .. "/check.jsonl"
                local zok, zerr = Zstd.decompressFile(REMOTE .. "/devices/" .. d.id .. "/" .. name, plain)
                if not zok then return false, d.id .. "/" .. name .. ": " .. zerr end
                local ok, err = Codec.readSegment(plain)
                if not ok then return false, d.id .. "/" .. name .. ": " .. err end
            end
        end
    end
    return true
end

-- Books, with md5s like KOReader's partial MD5.
local BOOKS = {}
for i = 1, 6 do
    BOOKS[i] = { md5 = string.format("%032x", i * 7919), title = "Book " .. i .. " — “Ünïcødé” 📖",
                 authors = i % 2 == 0 and "Author " .. i or "N/A", pages = 100 + i * 10 }
end

local clock = 1600000000
local function readSome(d, book, pages)
    local sessions = {}
    for p = 1, pages do
        clock = clock + 37
        sessions[#sessions + 1] = { math.random(1, book.pages), clock, math.random(5, 120) }
    end
    d:read(book, sessions)
end

math.randomseed(42)
local A, B, C = newSim("A"), newSim("B"), newSim("C")

-- 1. Empty remote folder ---------------------------------------------------------
sync({ A })
check(io.open(REMOTE .. "/devices/" .. A.id .. "/meta.json") ~= nil, "empty remote: folders and meta.json created")
local meta = Codec.decode(S.readFile(REMOTE .. "/devices/" .. A.id .. "/meta.json") or "")
check(meta and meta.deviceId == A.id and meta.schema == 1, "meta.json content")
check(#remoteSegments(A.id) == 1, "empty remote, nothing read: no segment uploaded")
check(A.status.devices == 1, "one device seen")

-- 2. Interleaved reading -----------------------------------------------------------
for round = 1, 4 do
    for i, d in ipairs({ A, B, C }) do
        readSome(d, BOOKS[(round + i) % 3 + 1], 15)
        readSome(d, BOOKS[4], 5) -- everyone reads book 4
        sync({ d })
    end
end
converge("interleaved reading")
check(allRemoteSegmentsValid(), "every remote segment is complete and valid")
check(C.status.devices == 3, "three devices seen")

-- Same book, different title on one device (edited metadata)
C:read({ md5 = BOOKS[5].md5, title = "My own title", authors = "Me", pages = 90 }, { { 3, clock + 50, 60 } })
A:read(BOOKS[5], { { 4, clock + 90, 30 } })
clock = clock + 200
converge("same book, different titles")
local cc = C:open()
check(tonumber(cc:rowexec("SELECT count(*) FROM book WHERE md5 = '" .. BOOKS[5].md5 .. "'")) == 1
    and cc:rowexec("SELECT title FROM book WHERE md5 = '" .. BOOKS[5].md5 .. "'") == "My own title",
    "C keeps one row with its own title")
cc:close()

-- 3. One device offline for many syncs ------------------------------------------------
C.online = false
for _ = 1, 5 do
    readSome(A, BOOKS[1], 10); readSome(B, BOOKS[2], 10); readSome(C, BOOKS[3], 10)
    sync({ A, B, C })
end
check(C.last_run and C.last_run.skipped == nil and C.engine.running == false, "offline device skipped quietly")
C.online = true
converge("offline device catches up")

-- 4. Upload killed partway --------------------------------------------------------
local sessions = {}
-- Varied durations and gaps, so the segment doesn't compress to almost nothing.
math.randomseed(6)
for i = 1, 6000 do clock = clock + math.random(20, 400); sessions[i] = { (i % 150) + 1, clock, math.random(5, 300) } end
B:read(BOOKS[6], sessions)
local before_segs = #remoteSegments(B.id)
B.http_opts.chunk_delay = 2 -- about 8 KB/s
B.engine.deps.time_limit = 1
sync({ B })
check(B.last_run.error and B.last_run.error:find("timed out"), "slow upload stopped at the time limit")
local partial = false
for _, name in ipairs(remoteSegments(B.id)) do
    if name:match("%.part$") then partial = true end
end
check(#remoteSegments(B.id) - (partial and 1 or 0) == before_segs, "no new segment name after the killed upload")
check(allRemoteSegmentsValid(), "no partial file under a segment name")
local ok_exp = S.SQ3.open(B.state)
local exported_6 = tonumber(ok_exp:rowexec("SELECT count(*) FROM exported WHERE md5 = '" .. BOOKS[6].md5 .. "'"))
ok_exp:close()
check(exported_6 == 0, "killed upload: nothing marked exported")
B.http_opts.chunk_delay = nil
B.engine.deps.time_limit = 60
converge("after killed upload")
for _, name in ipairs(remoteSegments(B.id)) do
    check(not name:match("%.part$"), "leftover temporary upload cleaned up: " .. name)
end

-- 5. Corrupt segment ---------------------------------------------------------------------
-- Put over WebDAV, as a misbehaving device would (rclone doesn't notice
-- files written behind its back until its directory cache expires).
local dav = WebDav.new{ http = S.Http.new(), address = server.url, username = USER, password = PASS, root = "books/statsync" }
local good = S.readFile(REMOTE .. "/devices/" .. A.id .. "/" .. firstSegment(A.id))
S.writeFile(TMP .. "/half.jsonl", good:sub(1, math.floor(#good / 2)))
S.writeFile(TMP .. "/junk.jsonl", "this is not a segment\n")
local nextA = 0
for _, name in ipairs(remoteSegments(A.id)) do nextA = math.max(nextA, Codec.segmentSeq(name) or 0) end
local BAD1, BAD2 = Codec.segmentName(nextA + 1), Codec.segmentName(nextA + 2)
local NEXT_GOOD = Codec.segmentName(nextA + 3)
check(dav:put("devices/" .. A.id .. "/" .. BAD1, TMP .. "/half.jsonl")
    and dav:put("devices/" .. A.id .. "/" .. BAD2, TMP .. "/junk.jsonl"), "corrupt segments uploaded")
-- And one far out of sequence: only a full listing finds it.
check(dav:put("devices/" .. A.id .. "/seg-0000000900.jsonl.zst", TMP .. "/junk.jsonl"), "stray segment uploaded")
local first = "devices/" .. A.id .. "/" .. firstSegment(A.id)
local before = S.readFile(REMOTE .. "/" .. first)
check(dav:put_new(first, TMP .. "/junk.jsonl") == false, "put_new refuses an existing name (MOVE, Overwrite: F)")
check(S.readFile(REMOTE .. "/" .. first) == before, "existing segment unchanged")
readSome(A, BOOKS[2], 8) -- A's next segment goes after the corrupt ones (the names are taken)
converge("corrupt segments skipped")
check(B.last_run.segments_bad == 0, "bad segments are not downloaded again")
local bs = S.SQ3.open(B.state)
check(tonumber(bs:rowexec("SELECT count(*) FROM bad_segments")) == 2, "both corrupt segments recorded as bad")
check(tonumber(bs:rowexec("SELECT count(*) FROM seen_segments WHERE name = '" .. NEXT_GOOD .. "'")) == 1,
    "the valid segment after them was imported")
bs:close()
-- "Sync now" lists every folder: the stray one is found (and is bad too).
B.engine:request("manual", { interactive = true })
loop:run(300)
bs = S.SQ3.open(B.state)
check(tonumber(bs:rowexec("SELECT count(*) FROM bad_segments")) == 3, "full listing finds the out-of-sequence segment")
bs:close()
check(B.status.last_error == nil, "corrupt segments don't fail the sync")

-- 6. Device restored from an old backup ------------------------------------------------------
local backup = TMP .. "/B-backup"
os.execute("cp -r " .. S.q(B.dir) .. " " .. S.q(backup))
for _ = 1, 3 do
    readSome(B, BOOKS[1], 12)
    sync({ B })
end
local b_segs_before = #remoteSegments(B.id)
-- Restore (same device ID, old statistics and state)
S.rmrf(B.dir)
os.execute("cp -r " .. S.q(backup) .. " " .. S.q(B.dir))
B:makeEngine()
readSome(B, BOOKS[3], 7) -- new reading after the restore
converge("restored from backup")
check(#remoteSegments(B.id) == b_segs_before + 1, "restored device wrote a new segment, after its existing ones")
check(allRemoteSegmentsValid({ [A.id .. "/seg-0000000900.jsonl.zst"] = true, [A.id .. "/" .. BAD1] = true, [A.id .. "/" .. BAD2] = true }),
    "no segment overwritten")

-- 7. Two devices syncing at the same moment ------------------------------------------------
readSome(A, BOOKS[4], 20); readSome(B, BOOKS[4], 20); readSome(C, BOOKS[5], 20)
sync({ A, B, C }) -- all three at once
converge("simultaneous syncs")

-- Rebuild from cloud gives the same data
C.store:forgetSeen()
local cdump = C:dump()
sync({ C })
check(C:dump() == cdump and C.last_run.segments_imported > 0, "rebuild from cloud re-imports everything, same result")

-- 8. Annotations ------------------------------------------------------------------------------
local ANN_BOOK = BOOKS[1].md5
local function annItem(i, note)
    local x = string.format("/body/DocFragment[%d]/body/p[1]/text().0", i)
    return { datetime = string.format("2026-03-%02d 10:00:00", i), drawer = "lighten", color = "yellow",
             text = "passage " .. i, note = note, page = x, pos0 = x,
             pos1 = string.format("/body/DocFragment[%d]/body/p[1]/text().9", i) }
end
local function observe(d, items)
    return d.ann_store:observe{ md5 = ANN_BOOK, kind = "rolling", items = items, now = os.time(), device = d.id,
                                title = BOOKS[1].title }
end
local function annMerged(d)
    local c = S.SQ3.open(d.state)
    local rows = {}
    for r in c:prepare("SELECT md5, kind, key, updated, device, deleted, hash FROM ann_merged ORDER BY md5, kind, key"):rows() do
        rows[#rows + 1] = table.concat({ r[1], r[2], r[3], tonumber(r[4]), r[5], tonumber(r[6]), r[7] }, "|")
    end
    c:close()
    return table.concat(rows, "\n"), #rows
end
local function annConverge(label, list)
    sync(list); sync(list)
    local first, n = annMerged(list[1])
    local same = true
    for _, d in ipairs(list) do
        if annMerged(d) ~= first then same = false end
        check(d.last_run and not d.last_run.error and not d.last_run.ann_upload_error,
            label .. ": " .. d.name .. " synced without error " .. tostring(d.last_run and (d.last_run.error or d.last_run.ann_upload_error)))
    end
    check(same, label .. ": all devices have the same merged annotations (" .. n .. ")")
    return first, n
end

A.ann_on, B.ann_on = true, true
local a_items = { annItem(1), annItem(2, "a note"), annItem(3) }
observe(A, a_items)
observe(B, { annItem(4), annItem(5) })
local _, n_ann = annConverge("annotations from two devices", { A, B })
check(n_ann == 5, "five annotations merged")
check(B.ann_affected and B.ann_affected[ANN_BOOK .. "\0rolling"], "B told which book changed")
local function annRemote(id)
    local out = {}
    for name in io.popen("ls " .. S.q(REMOTE .. "/devices/" .. id) .. " 2>/dev/null"):lines() do
        if AnnFormat.segmentSeq(name) then out[#out + 1] = name end
    end
    return out
end
check(#annRemote(A.id) == 1 and #annRemote(B.id) == 1, "one annotation segment each, next to the statistics ones")
-- C has annotation sync off: statistics still sync, annotation segments aren't fetched
readSome(C, BOOKS[2], 3)
sync({ C })
local cs = S.SQ3.open(C.state)
check(tonumber(cs:rowexec("SELECT count(*) FROM seen_segments WHERE name LIKE 'ann-%'")) == 0, "annotation sync off: nothing fetched")
cs:close()
-- Turned on: gets everything
C.ann_on = true
annConverge("third device turned on", { A, B, C })
-- An edit on A and a deletion on B
a_items[2].note = "edited"
a_items[2].datetime_updated = os.date("%Y-%m-%d %H:%M:%S", os.time() + 1)
observe(A, a_items)
local b_list = {}
for _, op in ipairs(B.ann_store:plan(ANN_BOOK, "rolling", {})) do b_list[#b_list + 1] = op.item end
B.ann_store:applied(ANN_BOOK, "rolling", b_list)
table.remove(b_list, 1)
local res = observe(B, b_list)
check(res.deleted == 1 and res.held == 0, "B deletes one (not a mass deletion)")
local merged = annConverge("edit and deletion", { A, B, C })
check(select(2, merged:gsub("|1|", "")) == 1, "one deletion in the merged state")
local plan = C.ann_store:plan(ANN_BOOK, "rolling", {})
local notes = {}
for _, op in ipairs(plan) do if op.item.note then notes[#notes + 1] = op.item.note end end
check(#plan == 4 and #notes == 1 and notes[1] == "edited", "C would apply 4 annotations, with the edited note")
-- A corrupt annotation segment: recorded as bad, the sync carries on
local nextAnn = #annRemote(A.id) + 1
check(dav:put("devices/" .. A.id .. "/" .. AnnFormat.segmentName(nextAnn), TMP .. "/junk.jsonl"), "corrupt annotation segment uploaded")
sync({ C })
local cb = S.SQ3.open(C.state)
check(tonumber(cb:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'ann-%'")) == 1, "corrupt annotation segment recorded as bad")
cb:close()
check(not C.last_run.error, "and doesn't fail the sync")
observe(A, { annItem(1), annItem(3), annItem(6) }) -- A's next one goes after the corrupt name
annConverge("after a corrupt annotation segment", { A, B, C })
-- Rebuild from cloud: same merged state again
local cmerged = annMerged(C)
C.store:forgetSeen()
sync({ C })
check(annMerged(C) == cmerged and C.last_run.ann_segments_imported > 0, "rebuild re-imports annotations, same result")

-- 9. Book data -----------------------------------------------------------------------------------
-- Synced with annotations: status, rating, custom metadata, handmade TOC.
local function bookMerged(d)
    local c = S.SQ3.open(d.state)
    local rows = {}
    for r in c:prepare("SELECT md5, prop, updated, device, deleted, hash FROM book_merged ORDER BY md5, prop"):rows() do
        rows[#rows + 1] = table.concat({ r[1], r[2], tonumber(r[3]), r[4], tonumber(r[5]), r[6] }, "|")
    end
    c:close()
    return table.concat(rows, "\n"), #rows
end
local function bookObserve(d, values, extra)
    local o = { md5 = ANN_BOOK, values = values, now = os.time(), device = d.id, title = BOOKS[1].title }
    for k, v in pairs(extra or {}) do o[k] = v end
    return d.book_store:observe(o)
end
local function bookRemote(id)
    local out = {}
    for name in io.popen("ls " .. S.q(REMOTE .. "/devices/" .. id) .. " 2>/dev/null"):lines() do
        if BookFormat.segmentSeq(name) then out[#out + 1] = name end
    end
    return out
end
bookObserve(A, { status = "complete", rating = 5, ["meta.title"] = "Custom title",
                 ["toc.rolling"] = { enabled = true, items = { { title = "One", depth = 1, xpointer = "/body/p[1]" } } } },
            { times = { status = 1700000000 } })
bookObserve(B, { status = "reading", rating = false }) -- KOReader's default: never wins
sync({ A, B, C }); sync({ A, B, C })
local bm, nb = bookMerged(A)
check(nb == 4 and bookMerged(B) == bm and bookMerged(C) == bm, "book data: same merged state everywhere (" .. nb .. ")")
check(#bookRemote(A.id) == 1, "book data segment next to the others")
check(B.book_affected and B.book_affected[ANN_BOOK], "B told which book's data changed")
local bplan = B.book_store:plan(ANN_BOOK, { status = "reading", rating = false, ["meta.title"] = false })
check(#bplan == 3 and bplan[3].prop == "status" and bplan[3].value == "complete", "B would set A's status, rating and title")
for _, d in ipairs({ A, B, C }) do
    check(d.last_run and not d.last_run.error and not d.last_run.book_upload_error,
        "book data: " .. d.name .. " synced without error")
end
-- A corrupt book data segment: recorded as bad, the sync carries on
check(dav:put("devices/" .. B.id .. "/" .. BookFormat.segmentName(#bookRemote(B.id) + 1), TMP .. "/junk.jsonl"),
    "corrupt book data segment uploaded")
sync({ C })
local cbb = S.SQ3.open(C.state)
check(tonumber(cbb:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'book-%'")) == 1, "corrupt book segment recorded as bad")
cbb:close()
check(not C.last_run.error, "and doesn't fail the sync")
-- Rebuild from cloud
C.store:forgetSeen()
sync({ C })
check(bookMerged(C) == bm and C.last_run.book_segments_imported > 0, "rebuild re-imports book data, same result")

-- 9b. Book identity -------------------------------------------------------------------------------
-- Synced with annotations. A has the book as first downloaded; B has the
-- copy rewritten after an edit on the server, put in place of the old one
-- (its sidecar, and so its MD5, is the old file's).
local function idFacts(d)
    local c = S.SQ3.open(d.state)
    local rows = {}
    for r in c:prepare("SELECT md5, fact, src, uuids, sig FROM id_facts ORDER BY md5, fact"):rows() do
        rows[#rows + 1] = table.concat({ r[1], r[2], r[3], r[4], r[5] or "-" }, "|")
    end
    c:close()
    return table.concat(rows, "\n"), #rows
end
local function idRemote(id)
    local out = {}
    for name in io.popen("ls " .. S.q(REMOTE .. "/devices/" .. id) .. " 2>/dev/null"):lines() do
        if IdFormat.segmentSeq(name) then out[#out + 1] = name end
    end
    return out
end
local UUIDS = { "333d496c-3946-448d-bb64-de3905aaaf83", "dd15c660-aec5-41ff-af25-8a01b8b592eb" }
local OLD_MD5, NEW_MD5 = string.rep("1", 32), string.rep("2", 32)
A.id_files = { { path = "/books/nowhere.epub", md5 = OLD_MD5, size = 555122, mtime = 1000 } }
A.id_infos = { ["/books/nowhere.epub"] = { md5 = OLD_MD5, uuids = UUIDS, sig = "body1",
               title = "The View From Nowhere", authors = "Thomas Nagel", ids = { "isbn:9780195056440" } } }
B.id_files = { { path = "/books/nowhere.epub", md5 = OLD_MD5, size = 554756, mtime = 2000 },
               { path = "/books/notes.epub", md5 = string.rep("3", 32), size = 10, mtime = 2000 } }
B.id_infos = { ["/books/nowhere.epub"] = { md5 = NEW_MD5, uuids = UUIDS, sig = "body1",
               title = "The View From Nowhere", authors = "Thomas Nagel", ids = { "calibre:4644" } } }
-- B's first sync has no time to read files: they wait for the next.
B.engine.deps.id_scan_seconds = 0
sync({ A, B })
check(A.last_run.id_scanned == 1 and A.last_run.id_new_facts == 1, "A read its book in the subprocess")
check(B.last_run.id_scanned == 0 and B.last_run.id_scan_left == 2, "B ran out of time: nothing read yet")
B.engine.deps.id_scan_seconds = 60
sync({ B })
check(B.last_run.id_scanned == 2 and B.last_run.id_new_facts == 2,
    "B read both files next time (the non-EPUB gives nothing; the replaced file gives two facts)")
sync({ A, B, C }); sync({ A, B, C })
local idf, nid = idFacts(A)
check(nid == 3 and idFacts(B) == idf and idFacts(C) == idf, "book identity: the same facts everywhere (" .. nid .. ")")
check(#idRemote(A.id) >= 1 and #idRemote(B.id) >= 1, "identity segments next to the others")
local cg = C.id_store:groups()
check(#cg == 1 and #cg[1].md5s == 2 and cg[1].sigs == 1 and cg[1].ok,
    "C sees one book in two versions, same body")
for _, d in ipairs({ A, B, C }) do
    check(d.last_run and not d.last_run.error and not d.last_run.id_upload_error,
        "book identity: " .. d.name .. " synced without error")
    check(#d.id_store:toScan(d.id_files or {}) == 0, "book identity: " .. d.name .. " has nothing left to read")
end
-- A corrupt identity segment: recorded as bad, the sync carries on
check(dav:put("devices/" .. B.id .. "/" .. IdFormat.segmentName(#idRemote(B.id) + 1), TMP .. "/junk.jsonl"),
    "corrupt identity segment uploaded")
sync({ C })
local cib = S.SQ3.open(C.state)
check(tonumber(cib:rowexec("SELECT count(*) FROM bad_segments WHERE name LIKE 'id-%'")) == 1, "corrupt identity segment recorded as bad")
cib:close()
check(not C.last_run.error, "and doesn't fail the sync")
-- Rebuild from cloud
C.store:forgetSeen()
sync({ C })
check(idFacts(C) == idf and C.last_run.id_segments_imported > 0, "rebuild re-imports book identity, same result")

-- 10. Packs ---------------------------------------------------------------------------------------
-- Packing needs only a few segments here, and deleting waits for nothing,
-- so it all happens in this test.
local Pack = require("omnisync/pack")
Pack.MIN = 3
for _, d in ipairs(devices) do d.engine.deps.pack_grace = 0 end
local function fullListingNext(list)
    for _, d in ipairs(list) do d.engine.status.last_full_list, d.engine.status.ann_last_full_list = 0, 0 end
end
local function onServer(id, name) return io.open(REMOTE .. "/devices/" .. id .. "/" .. name) ~= nil end
-- A reads in short sessions, syncing after each: small segments.
for i = 1, 5 do
    readSome(A, BOOKS[1 + i % 6], 3)
    sync({ A })
end
fullListingNext({ A })
for _, d in ipairs(devices) do d.engine.deps.pack_grace = 3600 end -- not deleted yet
sync({ A })
local a_pack, a_info
for name, p in pairs(A.engine.status.packs or {}) do
    if p.stream == "stats" and (not a_info or p.last > a_info.last) then a_pack, a_info = name, p end
end
check(a_pack and A.last_run.packed >= 1 and onServer(A.id, a_pack), "A packed its small segments: " .. tostring(a_pack)
    .. (a_info and (" (" .. a_info.first .. " to " .. a_info.last .. ")") or ""))
check(a_info and Codec.segmentSeq(a_pack) > a_info.last and onServer(A.id, Codec.segmentName(a_info.last)),
    "the pack is A's next segment; the packed segments are still there")

-- Everyone gets the pack as A's next segment, and a new device too.
local D = newSim("D")
converge("after packing", { A, B, C, D })

-- The packed segments go (at A's next full listing, the wait being over).
for _, d in ipairs(devices) do d.engine.deps.pack_grace = 0 end
fullListingNext({ A })
sync({ A })
local still = 0
for n = a_info and a_info.first or 1, a_info and a_info.last or 0 do
    if onServer(A.id, Codec.segmentName(n)) then still = still + 1 end
end
check(a_info and A.last_run.deleted_originals > 0 and still == 0 and onServer(A.id, a_pack),
    "A deleted its packed segments, and kept the pack (" .. tostring(A.last_run.deleted_originals) .. " deleted)")

-- New readings on A carry on after the pack's number, and reach everyone,
-- including a device that joins after the deletion.
readSome(A, BOOKS[2], 4)
local E = newSim("E")
converge("after deleting packed segments", devices)
-- E never saw the deleted numbers: an ordinary sync carries on past them.
readSome(A, BOOKS[3], 4)
sync({ A })
sync({ E })
check(E:dump() == A:dump() and not E.last_run.full_listed, "an ordinary sync on E gets A's new readings past the gap")

-- rclone keeps a folder's first date: devices notice and check every folder.
check(A.engine.status.folder_dates == "unreliable", "rclone's folder dates found unreliable: "
    .. tostring(A.engine.status.folder_dates))

-- 11. Folder dates on a server that keeps them -------------------------------------------------
-- Listings report each folder's real date (from the files rclone serves),
-- as servers that keep folder dates do.
local lfs = require("lfs")
local real_list = WebDav.list
local function httpDate(t) return os.date("!%a, %d %b %Y %H:%M:%S GMT", t) end
WebDav.list = function(self, path)
    local entries, e, c = real_list(self, path)
    if entries then
        entries.server_date = httpDate(os.time())
        for _, x in ipairs(entries) do
            if x.is_dir then
                local attr = lfs.attributes(REMOTE .. "/" .. (path == "" and "" or path .. "/") .. x.name)
                x.modified = attr and httpDate(attr.modification) or nil
            end
        end
    end
    return entries, e, c
end
for _, d in ipairs(devices) do
    d.engine.status.folder_dates, d.engine.status.folders, d.engine.status.own_check = nil, nil, nil
end
-- Each device uploads, and at its next sync finds its own folder's date
-- changed: the dates can be trusted. (Dates a second or two old aren't
-- relied on, hence the waits.)
for round = 1, 2 do
    S.sleep(3)
    for i, d in ipairs(devices) do readSome(d, BOOKS[1 + (i + round) % 6], 2) end
    sync(devices)
end
local trusted = true
for _, d in ipairs(devices) do
    if d.engine.status.folder_dates ~= "reliable" then trusted = false end
end
check(trusted, "every device found the folder dates follow changes")
converge("folder dates kept")
S.sleep(3)
sync(devices) -- folders gone through and recorded
local quiet = true
sync(devices)
for _, d in ipairs(devices) do
    if d.last_run.result.requests ~= 1 then
        quiet = false
        print("  " .. d.name .. ": " .. tostring(d.last_run.result.requests) .. " requests")
    end
end
check(quiet, "nothing new: one request per sync, every folder skipped")
-- A change in one folder is still found by everyone.
readSome(B, BOOKS[4], 5)
sync({ B })
S.sleep(3)
converge("changed folder found while the others are skipped")
WebDav.list = real_list

server.stop()
S.finish("omnisync integration test")
