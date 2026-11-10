-- Unit tests for OmniSync's book data sync: the record format
-- (omnisync/bookformat.lua), the merge and change detection
-- (omnisync/bookstore.lua), and reading, applying and writing book data in
-- KOReader (omnisync/booksync.lua) with sidecars as real files and
-- KOReader's DocSettings stood in for.
-- Run through scripts/test-omnisync.sh, which sets KOREADER_SRC.

local S = dofile("tests/omnisync/support.lua")
local check = S.check

local AnnFormat = require("omnisync/annformat")
local BookFormat = require("omnisync/bookformat")
local BookStore = require("omnisync/bookstore")
local BookSync = require("omnisync/booksync")
local IdStore = require("omnisync/idstore")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/book"
S.rmrf(TMP)
S.mkdirp(TMP)

local quiet = { info = function() end, warn = function(...) if os.getenv("STATSYNC_VERBOSE") then print(...) end end,
                dbg = function() end, err = print }
local lfs = require("lfs")

-- Simple md5 stand-in: any stable digest will do for the tests.
local function digest(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c * 7) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local clock = 1800000000
local function tick(n) clock = clock + (n or 1) end

-- Lua tables to files, as KOReader's dump does --------------------------------------------
local function serialize(v, indent)
    indent = indent or ""
    if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        local out = { "{\n" }
        for _, k in ipairs(keys) do
            local kk = type(k) == "number" and string.format("[%d]", k) or string.format("[%q]", k)
            out[#out + 1] = string.format("%s    %s = %s,\n", indent, kk, serialize(v[k], indent .. "    "))
        end
        return table.concat(out) .. indent .. "}"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

-- KOReader's DocSettings, enough of it: sidecars in <book>.sdr/ ------------------------------
local function sdrDir(path) return (path:gsub("%.[^./]*$", "")) .. ".sdr" end
local function isFile(p) return lfs.attributes(p, "mode") == "file" end
local Settings = {}
Settings.__index = Settings
function Settings:readSetting(k) return self.data[k] end
function Settings:saveSetting(k, v) self.data[k] = v end
function Settings:delSetting(k) self.data[k] = nil end
function Settings:flush()
    S.mkdirp(sdrDir(self.doc_path))
    S.writeFile(sdrDir(self.doc_path) .. "/metadata.epub.lua", "return " .. serialize(self.data) .. "\n")
end
function Settings:flushCustomMetadata(doc_path)
    S.mkdirp(sdrDir(doc_path))
    S.writeFile(sdrDir(doc_path) .. "/custom_metadata.lua", "return " .. serialize(self.data) .. "\n")
    return true
end
function Settings:getCustomMetadataFile() end
local function load(file)
    local ok, data = pcall(dofile, file)
    return ok and type(data) == "table" and data or {}
end
local DocSettings = {}
function DocSettings:findSidecarFile(path)
    local f = sdrDir(path) .. "/metadata.epub.lua"
    return isFile(f) and f or nil
end
function DocSettings:hasSidecarFile(path) return self:findSidecarFile(path) ~= nil end
function DocSettings:findCustomMetadataFile(path)
    local f = sdrDir(path) .. "/custom_metadata.lua"
    return isFile(f) and f or nil
end
function DocSettings:open(path)
    local f = self:findSidecarFile(path)
    return setmetatable({ doc_path = path, data = f and load(f) or {} }, Settings)
end
function DocSettings.openSettingsFile(file)
    return setmetatable({ data = file and load(file) or {}, sidecar_file = file }, Settings)
end
function DocSettings.removeSidecarDir() end

local function readSidecar(path) return load(sdrDir(path) .. "/metadata.epub.lua") end
local function readCustom(path)
    local f = sdrDir(path) .. "/custom_metadata.lua"
    return isFile(f) and load(f) or nil
end
local function writeSidecar(path, data)
    local ds = setmetatable({ doc_path = path, data = data }, Settings)
    ds:flush()
end

-- A simulated device ---------------------------------------------------------------------
local Dev = {}
Dev.__index = Dev
local function newDev(name)
    local dir = TMP .. "/" .. name
    S.mkdirp(dir .. "/books")
    local d = setmetatable({ name = name, dir = dir, hist = {}, scheduled = {}, events = {}, cache = {} }, Dev)
    d.store = BookStore.new{ sq3 = S.SQ3, state_path = dir .. "/state.sqlite3", md5 = digest }
    d.sync = BookSync.new{
        store = d.store, getDeviceId = function() return name end, now = function() return clock end,
        logger = quiet, enabled = function() return true end,
        schedule = function(_, fn) table.insert(d.scheduled, fn) end,
        readerUI = function() return d.ui end,
        docsettings = DocSettings, lfs = lfs,
        readhistory = { hist = d.hist },
        booklist = {
            setBookInfoCacheProperty = function(file, k, v) d.cache[file] = d.cache[file] or {}; d.cache[file][k] = v end,
            resetBookInfoCache = function(file) d.cache[file] = "reset" end,
        },
        event = { new = function(_, n, a) return { name = n, args = a } end },
        ui_manager = { broadcastEvent = function(_, ev) table.insert(d.events, ev) end, setDirty = function() end },
        global_settings = { readSetting = function() return nil end },
    }
    return d
end
function Dev:run()
    while #self.scheduled > 0 do table.remove(self.scheduled, 1)() end
end
function Dev:book(name, data)
    local path = self.dir .. "/books/" .. name .. ".epub"
    S.writeFile(path, "book")
    if data then writeSidecar(path, data) end
    table.insert(self.hist, { file = path })
    return path
end
-- Sends this device's changes to the others (export, then import elsewhere).
local seq = 0
function Dev:send(...)
    local out = self.dir .. "/out.jsonl"
    local exp = self.store:export{ device_id = self.name, out_path = out, now = clock, max_records = 1000 }
    if not exp then return 0 end
    seq = seq + 1
    local name = BookFormat.segmentName(seq)
    self.store:markExported(out, self.name, name, exp.size, nil, clock)
    for _, other in ipairs({ ... }) do
        local res, err = other.store:importSegment(out, self.name, name, exp.size, nil, clock)
        check(res, "import into " .. other.name .. ": " .. tostring(err))
    end
    return exp.records
end
function Dev:merged(md5, prop)
    local conn = self.store:open()
    local stmt = conn:prepare("SELECT value, deleted, updated FROM book_merged WHERE md5 = ? AND prop = ?;")
    local r = stmt:bind(md5, prop):step()
    stmt:close()
    conn:close()
    if not r then return nil end
    if tonumber(r[2]) == 1 then return "(cleared)" end
    return AnnFormat.decodeValue(r[1]), tonumber(r[3])
end

local MD5 = string.rep("a", 32)

-- Format ------------------------------------------------------------------------------------
do
    check(BookFormat.validValue("status", "complete") and not BookFormat.validValue("status", "done"), "status values")
    check(BookFormat.validValue("rating", 5) and not BookFormat.validValue("rating", 6)
        and not BookFormat.validValue("rating", 2.5), "rating values")
    check(BookFormat.validValue("toc.rolling", { enabled = true, items = { { title = "A", depth = 1, xpointer = "/x" } } }),
        "rolling TOC with XPointers")
    check(not BookFormat.validValue("toc.rolling", { items = { { title = "A", page = 3 } } }), "rolling TOC without XPointer rejected")
    check(not BookFormat.validValue("flows.paging", { items = { { hidden = true, xpointer = "/x" } } }), "paging flows need pages")
    check(BookFormat.validValue("future.thing", { anything = 1 }) and not BookFormat.known("future.thing"),
        "unknown properties accepted, not applied")
    check(BookFormat.segmentSeq(BookFormat.segmentName(42)) == 42 and not BookFormat.segmentSeq("ann-0000000001.jsonl.zst"),
        "segment names")

    local f = TMP .. "/seg.jsonl"
    local function write(lines) S.writeFile(f, table.concat(lines, "\n") .. "\n") end
    local hdr = BookFormat.headerLine("dev1", 1)
    local b = BookFormat.bookLine{ md5 = MD5, title = "T" }
    local p = BookFormat.recordLine{ md5 = MD5, prop = "status", updated = 5, device = "dev1", value_json = '"complete"' }
    local x = BookFormat.recordLine{ md5 = MD5, prop = "rating", updated = 6, device = "dev1" }
    write({ hdr, b, p, x, '{"t":"zz","later":1}', BookFormat.trailerLine(1, 2) })
    local got = {}
    local h = BookFormat.readSegment(f, { record = function(r) got[#got + 1] = r end })
    check(h and h.records == 2 and got[1].value_json == '"complete"' and got[2].t == "x",
        "segment read, unknown record type skipped")
    write({ hdr, b, BookFormat.recordLine{ md5 = MD5, prop = "status", updated = 5, device = "d", value_json = '"done"' },
        BookFormat.trailerLine(1, 1) })
    check(not BookFormat.readSegment(f), "bad status rejects the segment")
    write({ hdr, b, p })
    local _, err = BookFormat.readSegment(f)
    check(err and err:find("truncated"), "truncated segment rejected")
    write({ hdr, p, BookFormat.trailerLine(0, 1) })
    check(not BookFormat.readSegment(f), "record before its book rejected")
end

-- Merge and change detection ----------------------------------------------------------------
do
    local a, b, c = newDev("merge-a"), newDev("merge-b"), newDev("merge-c")
    local function obs(d, values, extra)
        local o = { md5 = MD5, values = values, now = clock, device = d.name }
        for k, v in pairs(extra or {}) do o[k] = v end
        return d.store:observe(o)
    end
    -- A finished the book on 2026-03-01; B opened it later and KOReader set "reading".
    local march = os.time{ year = 2026, month = 3, day = 1, hour = 12 }
    obs(a, { status = "complete", rating = 4, note = false }, { times = { status = march, rating = march } })
    obs(b, { status = "reading", rating = false, note = false }, { times = { status = march + 86400 * 30 } })
    check(a:merged(MD5, "status") == "complete", "first look: A's own status recorded")
    a:send(b, c)
    b:send(a, c)
    for _, d in ipairs({ a, b, c }) do
        check(d:merged(MD5, "status") == "complete", d.name .. ": a first-look 'reading' never beats a real status")
        check(d:merged(MD5, "rating") == 4, d.name .. ": rating from A")
    end
    -- B now applies the merged state, then the user rates the book 2 there.
    local ops = b.store:plan(MD5, { status = "reading", rating = false, note = false })
    check(#ops == 2 and ops[1].prop == "rating" and ops[1].value == 4 and ops[2].prop == "status"
        and ops[2].value == "complete", "plan: rating and status to apply on B")
    b.store:applied(MD5, { status = "complete", rating = 4, note = false })
    tick(10)
    obs(b, { status = "complete", rating = 2, note = "Fine." })
    check(b:send(a, c) == 2, "B sends its two changes")
    check(a:merged(MD5, "rating") == 2 and c:merged(MD5, "note") == "Fine.", "B's rating and review everywhere")
    -- A clears the rating; C, meanwhile, had no idea.
    a.store:applied(MD5, { status = "complete", rating = 2, note = "Fine." })
    tick(10)
    obs(a, { status = "complete", rating = false, note = "Fine." })
    a:send(b, c)
    check(b:merged(MD5, "rating") == "(cleared)" and c:merged(MD5, "rating") == "(cleared)", "a cleared rating is cleared everywhere")
    -- A late old segment can't bring it back
    local stale = TMP .. "/stale.jsonl"
    S.writeFile(stale, table.concat({ BookFormat.headerLine("old", 1), BookFormat.bookLine{ md5 = MD5 },
        BookFormat.recordLine{ md5 = MD5, prop = "rating", updated = clock - 100, device = "old", value_json = "5" },
        BookFormat.trailerLine(1, 1) }, "\n") .. "\n")
    c.store:importSegment(stale, "old", "book-0000000001.jsonl.zst", 1, nil, clock)
    check(c:merged(MD5, "rating") == "(cleared)", "late old rating doesn't come back")
    -- Importing the same segment twice changes nothing
    local before = c.store:counts().outbox
    c.store:importSegment(stale, "old", "book-0000000001.jsonl.zst", 1, nil, clock)
    check(c.store:counts().outbox == before, "importing twice changes nothing")

    -- A missing status isn't a clear; "reading" after none is the weakest.
    tick(10)
    obs(a, { status = false, rating = false, note = "Fine." })
    check(a.store:counts().outbox == 0, "status gone: nothing sent")
    tick(10)
    obs(a, { status = "reading", rating = false, note = "Fine." })
    check(a:merged(MD5, "status") == "complete", "'reading' where there was no status doesn't override")
    -- A deliberate change to reading does.
    tick(10)
    a.store:applied(MD5, { status = "complete" })
    obs(a, { status = "reading" })
    check(a:merged(MD5, "status") == "reading", "changing finished to reading is a change")

    -- Fresh (reset settings): nothing cleared, merged values come back.
    tick(10)
    a.store:applied(MD5, { status = "reading", rating = false, note = "Fine." })
    obs(a, { status = false, rating = false, note = false }, { fresh = true })
    check(a:merged(MD5, "note") == "Fine.", "reset sidecar: review not cleared")
    local ops2 = a.store:plan(MD5, { status = "reading", note = false })
    check(#ops2 == 1 and ops2[1].prop == "note", "reset sidecar: review to put back")

    -- Order independence: three devices' changes in every order give the same state.
    local recs = {}
    local function seg(dev, prop, upd, value)
        local p = TMP .. "/o-" .. dev .. "-" .. prop .. "-" .. upd .. ".jsonl"
        S.writeFile(p, table.concat({ BookFormat.headerLine(dev, 1), BookFormat.bookLine{ md5 = MD5 },
            BookFormat.recordLine{ md5 = MD5, prop = prop, updated = upd, device = dev,
                value_json = value and AnnFormat.encodeValue(value) or nil },
            BookFormat.trailerLine(1, 1) }, "\n") .. "\n")
        recs[#recs + 1] = { path = p, dev = dev, name = BookFormat.segmentName(#recs + 1) }
    end
    seg("x", "meta.title", 100, "One")
    seg("y", "meta.title", 200, "Two")
    seg("z", "meta.title", 200, nil)
    local perms = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
    local results = {}
    for i, perm in ipairs(perms) do
        local d = newDev("perm" .. i)
        for _, k in ipairs(perm) do d.store:importSegment(recs[k].path, recs[k].dev, recs[k].name, 1, nil, 1) end
        results[#results + 1] = tostring(d:merged(MD5, "meta.title"))
    end
    local same = true
    for _, r in ipairs(results) do same = same and r == results[1] end
    check(same and results[1] == "(cleared)", "every order gives the same state (" .. table.concat(results, ",") .. ")")
end

-- Closed books: refresh and writes ---------------------------------------------------------
do
    local a, b = newDev("closed-a"), newDev("closed-b")
    local MD = string.rep("b", 32)
    local props = { title = "Original", authors = "Writer" }
    local pa = a:book("novel", { partial_md5_checksum = MD, doc_props = props,
                                 summary = { status = "reading", modified = "2026-01-01" } })
    local pb = b:book("novel", { partial_md5_checksum = MD, doc_props = props,
                                 summary = { status = "reading", modified = "2026-01-02" } })
    a.sync:refresh(); a:run()
    b.sync:refresh(); b:run()
    check(a.store:files()[pa] and a.store:files()[pa].sig, "refresh: the book file and its sidecar recorded")
    -- The user marks it finished and rates it in A's file browser, and renames it.
    tick(100)
    local data = readSidecar(pa)
    data.summary = { status = "complete", rating = 5, note = "Loved it", modified = "2026-02-02" }
    writeSidecar(pa, data)
    S.mkdirp(sdrDir(pa))
    S.writeFile(sdrDir(pa) .. "/custom_metadata.lua", "return " .. serialize{
        doc_props = props, custom_props = { title = "Better title", series = "Saga" } } .. "\n")
    lfs.touch(sdrDir(pa) .. "/metadata.epub.lua", clock + 5, clock + 5)
    a.sync:refresh(); a:run()
    check(a:merged(MD, "status") == "complete" and a:merged(MD, "meta.title") == "Better title",
        "changes made in the file browser recorded")
    check(a:send(b) == 5, "five changes sent")
    check(b.store:counts().write == 1, "B has a book to write")
    b.sync:afterSync(nil); b:run()
    local s = readSidecar(pb).summary
    check(s.status == "complete" and s.rating == 5 and s.note == "Loved it", "written into B's closed book: "
        .. tostring(s.status) .. ", " .. tostring(s.rating))
    check(s.modified == os.date("%Y-%m-%d", clock), "status date set to when it changed")
    local cm = readCustom(pb)
    check(cm and cm.custom_props.title == "Better title" and cm.custom_props.series == "Saga"
        and cm.doc_props.title == "Original" and cm.doc_props.display_title == nil,
        "custom metadata file created, with the original props kept")
    check(b.cache[pb] == "reset", "file browser cache refreshed")
    local changed_event = false
    for _, ev in ipairs(b.events) do changed_event = changed_event or ev.name == "BookMetadataChanged" end
    check(changed_event, "BookMetadataChanged sent")
    check(b.store:counts().write == 0 and b.store:counts().outbox == 0, "nothing left to write, nothing echoed back")
    -- Next refresh on B: our own write isn't a change.
    b.sync:refresh(); b:run()
    check(b.store:counts().outbox == 0, "B's refresh after writing finds no changes")

    -- A resets the custom title; B's file loses it, keeps the series.
    tick(100)
    S.writeFile(sdrDir(pa) .. "/custom_metadata.lua", "return " .. serialize{
        doc_props = props, custom_props = { series = "Saga" } } .. "\n")
    lfs.touch(sdrDir(pa) .. "/custom_metadata.lua", clock, clock)
    a.sync:refresh(); a:run()
    check(a:merged(MD, "meta.title") == "(cleared)", "custom title reset recorded as a clear")
    a:send(b)
    b.sync:afterSync(nil); b:run()
    cm = readCustom(pb)
    check(cm and cm.custom_props.title == nil and cm.custom_props.series == "Saga", "custom title removed on B")

    -- A book never opened on B (no sidecar) isn't written.
    local MD2 = string.rep("c", 32)
    local pa2 = a:book("other", { partial_md5_checksum = MD2, doc_props = { title = "Other" },
                                  summary = { status = "complete", modified = "2026-01-01" } })
    a.sync:refresh(); a:run()
    a:send(b)
    S.writeFile(b.dir .. "/books/other.epub", "book")
    b.sync:afterSync(nil); b:run()
    check(not isFile(sdrDir(b.dir .. "/books/other.epub") .. "/metadata.epub.lua"), "no sidecar created for a book not opened here")
    check(pa2, "other book")

    -- A sidecar reset in B's file browser (no summary, reset marker) clears nothing.
    tick(100)
    writeSidecar(pb, { partial_md5_checksum = MD, docsettings_reset_done = true })
    b.sync:refresh(); b:run()
    check(b.store:counts().outbox == 0, "reset sidecar: nothing sent")
    b.sync:afterSync(nil); b:run()
    s = readSidecar(pb).summary
    check(s and s.status == "complete" and s.rating == 5, "reset sidecar: status and rating put back")

    -- A book deleted from B is forgotten.
    os.remove(pb)
    b.sync:refresh(); b:run()
    check(not b.store:files()[pb], "deleted book forgotten")
end

-- Versions of a book (IDENTITY.md, level 1) ---------------------------------------------------
do
    local a, b = newDev("ver-a"), newDev("ver-b")
    -- A has the file as first downloaded (X); B downloaded it after the
    -- server rewrote it (Y). Both carry the book's UUID.
    local X, Y = string.rep("1", 32), string.rep("2", 32)
    local UUID = "333d496c-0000-4000-8000-000000000001"
    local function ids(d) return IdStore.new{ sq3 = S.SQ3, state_path = d.dir .. "/state.sqlite3" } end
    local function facts(d, list)
        local st = ids(d)
        for _, f in ipairs(list) do
            st:recordScan({ path = "/f/" .. f.md5, md5 = f.md5, size = 1, mtime = 1 },
                { md5 = f.md5, uuids = f.uuids or { UUID }, sig = f.sig or "s1", title = f.title or "Saga",
                  authors = f.authors or "Ann Writer" }, d.name)
        end
        return st:refreshGroups()
    end
    local props = { title = "Saga", authors = "Ann Writer" }
    local pa = a:book("saga", { partial_md5_checksum = X, doc_props = props,
                                summary = { status = "reading", modified = "2026-01-01" } })
    local pb = b:book("saga", { partial_md5_checksum = Y, doc_props = props,
                                summary = { status = "reading", modified = "2026-01-02" } })
    a.sync:refresh(); a:run()
    b.sync:refresh(); b:run()

    -- A finishes and rates the book before either device knows the files are one book.
    tick(100)
    local data = readSidecar(pa)
    data.summary = { status = "complete", rating = 4, modified = "2026-03-01" }
    writeSidecar(pa, data)
    lfs.touch(sdrDir(pa) .. "/metadata.epub.lua", clock, clock)
    a.sync:refresh(); a:run()
    a:send(b)
    b:send(a)
    check(b.store:counts().write == 0, "not joined yet: nothing to write into B's version")
    check(#b.store:plan(Y, { status = "reading", rating = false }) == 0, "not joined yet: nothing to apply")

    -- The identity facts arrive: X and Y are one book.
    local changed = facts(b, { { md5 = X }, { md5 = Y } })
    check(changed[X] and changed[Y], "groups: both files joined")
    check(next(ids(b):refreshGroups()) == nil, "groups: refreshing again changes nothing")
    local all = b.store:regroup(changed)
    check(all[X] and all[Y], "regroup returns the versions")
    check(b.store:counts().write == 1, "joined: B's version has values to write")
    b.sync:afterSync(nil); b:run()
    local s = readSidecar(pb).summary
    check(s.status == "complete" and s.rating == 4, "A's status and rating written into B's version: "
        .. tostring(s.status) .. ", " .. tostring(s.rating))
    check(b.store:counts().outbox == 0, "nothing recorded under B's MD5 for values that came from A's")

    -- B puts it on hold and clears the rating: A gets both, through its own version.
    facts(a, { { md5 = X }, { md5 = Y } })
    tick(100)
    data = readSidecar(pb)
    data.summary = { status = "abandoned", modified = "2026-04-01" }
    writeSidecar(pb, data)
    lfs.touch(sdrDir(pb) .. "/metadata.epub.lua", clock, clock)
    b.sync:refresh(); b:run()
    check(b:merged(Y, "status") == "abandoned" and b:merged(Y, "rating") == "(cleared)",
        "B's changes recorded under its own MD5")
    check(b:merged(X, "status") == "complete", "A's records untouched on B")
    b:send(a)
    a.sync:afterSync(nil); a:run()
    s = readSidecar(pa).summary
    check(s.status == "abandoned" and s.rating == nil, "B's status and cleared rating reach A's version")
    check(a.store:counts().outbox == 0 and a.store:counts().write == 0, "nothing echoed back from A")

    -- A clear isn't lost when the book's own MD5 already holds an older clear.
    tick(100)
    local MP, MQ = string.rep("3", 32), string.rep("4", 32)
    local d = newDev("ver-c")
    local function obs(md5, values) return d.store:observe{ md5 = md5, values = values, now = clock, device = "c" } end
    obs(MP, { rating = 3 })
    tick(1)
    obs(MP, { rating = false }) -- cleared under P
    tick(1)
    local seg = TMP .. "/ver-q.jsonl"
    S.writeFile(seg, table.concat({ BookFormat.headerLine("q", 1), BookFormat.bookLine{ md5 = MQ },
        BookFormat.recordLine{ md5 = MQ, prop = "rating", updated = clock, device = "q", value_json = "5" },
        BookFormat.trailerLine(1, 1) }, "\n") .. "\n")
    d.store:importSegment(seg, "q", BookFormat.segmentName(900), 1, nil, clock)
    d.store:regroup(facts(d, { { md5 = MP, uuids = { "0000aaaa-0000-4000-8000-000000000002" } }, { md5 = MQ, uuids = { "0000aaaa-0000-4000-8000-000000000002" } } }))
    local ops = d.store:plan(MP, { rating = false })
    check(#ops == 1 and ops[1].value == 5, "the other version's newer rating applies")
    d.store:applied(MP, { rating = 5 })
    tick(10)
    obs(MP, { rating = false })
    check(#d.store:plan(MP, { rating = false }) == 0, "clearing it again sticks")

    -- Positions cross only versions with the same body: a handmade TOC
    -- made on one applies to the other.
    local toc = { enabled = true, items = { { title = "One", depth = 1, xpointer = "/body/DocFragment[2]" } } }
    obs(MQ, { ["toc.rolling"] = toc })
    ops = d.store:plan(MP, { ["toc.rolling"] = false })
    check(#ops == 1 and ops[1].prop == "toc.rolling" and ops[1].value.items[1].title == "One",
        "handmade TOC shared by versions with the same body")
    -- Another edition (a different body) under the same ID: it stays with its file.
    local MV, MW = string.rep("a", 32), string.rep("b", 32)
    local ed = "0000aaaa-0000-4000-8000-000000000004"
    facts(d, { { md5 = MV, uuids = { ed }, sig = "s1" }, { md5 = MW, uuids = { ed }, sig = "s2" } })
    obs(MW, { ["toc.rolling"] = toc, ["flows.rolling"] = { enabled = true, items = {} } })
    obs(MW, { status = "complete" })
    ops = d.store:plan(MV, { ["toc.rolling"] = false, ["flows.rolling"] = false, status = "reading" })
    check(#ops == 1 and ops[1].prop == "status", "another edition: its status applies, not its TOC or flows")

    -- Guards: unrelated books sharing a UUID by mistake aren't joined.
    local MR, MS = string.rep("5", 32), string.rep("6", 32)
    obs(MR, { status = "complete" })
    local ch = facts(d, { { md5 = MR, uuids = { "0000aaaa-0000-4000-8000-000000000003" }, title = "One Book", authors = "Someone" },
                          { md5 = MS, uuids = { "0000aaaa-0000-4000-8000-000000000003" }, title = "Another", authors = "Else" } })
    check(not ch[MR] and not ch[MS], "guarded group not joined")
    check(#d.store:plan(MS, { status = "reading" }) == 0, "guarded group: nothing applied")

    -- A third file joins P and Q: all three are refreshed.
    local MT = string.rep("7", 32)
    ch = facts(d, { { md5 = MT, uuids = { "0000aaaa-0000-4000-8000-000000000002" } } })
    check(ch[MP] and ch[MQ] and ch[MT], "a new version refreshes the whole group")
end

-- The open book ------------------------------------------------------------------------------
do
    local a, b = newDev("open-a"), newDev("open-b")
    local MD = string.rep("e", 32)
    local XP1, XP2 = "/body/DocFragment[2]/body/h1/text().0", "/body/DocFragment[9]/body/h1/text().0"
    local pa = a:book("tome", { partial_md5_checksum = MD, doc_props = { title = "Tome" },
                                summary = { status = "complete", modified = "2026-01-01" } })
    a.sync:refresh(); a:run()
    -- A builds a handmade table of contents in the reader.
    local function reader(dev, path, summary, toc)
        local doc = { partial_md5_checksum = MD, summary = summary }
        local ui = {
            rolling = true, document = { file = path }, doc_props = { title = "Tome", display_title = "Tome" },
            doc_settings = { readSetting = function(_, k) return doc[k] end, saveSetting = function(_, k, v) doc[k] = v end,
                             getCustomMetadataFile = function() end },
            handmade = { toc = toc or {}, toc_enabled = toc ~= nil, flow_points = {}, flows_enabled = false,
                         calls = 0,
                         updateHandmagePages = function(h) for _, it in ipairs(h.toc) do it.page = 7 end end,
                         setupFlows = function(h) h.calls = h.calls + 1 end,
                         setupToc = function(h) h.calls = h.calls + 1 end },
            handleEvent = function(self, ev) self.events = self.events or {}; table.insert(self.events, ev.name) end,
        }
        ui.dialog = ui
        ui._doc = doc
        dev.ui = ui
        return ui
    end
    local ua = reader(a, pa, { status = "complete", modified = "2026-01-01" },
        { { title = "Part one", depth = 1, page = 3, xpointer = XP1 }, { title = "Part two", depth = 1, page = 90, xpointer = XP2 } })
    a.sync:onReadSettings(ua, { readSetting = function(_, k) return ua._doc[k] end })
    a.sync:onReaderReady(ua)
    tick(5)
    a.sync:onClose(ua)
    local v = a:merged(MD, "toc.rolling")
    check(type(v) == "table" and v.enabled == true and #v.items == 2 and v.items[1].page == nil
        and v.items[2].xpointer == XP2, "handmade TOC recorded without layout-dependent page numbers")
    a:send(b)

    -- B opens the book for the first time: KOReader sets "reading".
    local pb = b:book("tome", { partial_md5_checksum = MD, doc_props = { title = "Tome" } })
    local ub = reader(b, pb, nil, nil)
    b.sync:onReadSettings(ub, { readSetting = function(_, k) return ub._doc[k] end })
    ub._doc.summary = { status = "reading", modified = os.date("%Y-%m-%d", clock) } -- what ReaderUI does next
    b.sync:onReaderReady(ub)
    check(ub._doc.summary.status == "complete", "opened book: 'complete' from A applied, not KOReader's 'reading'")
    check(#ub.handmade.toc == 2 and ub.handmade.toc_enabled and ub.handmade.toc[1].page == 7,
        "opened book: handmade TOC applied, page numbers recomputed")
    check(ub.handmade.calls == 2 and ub.events and ub.events[1] == "UpdateToc", "TOC set up and UpdateToc sent")
    check(b.cache[pb] and b.cache[pb].status == "complete", "file browser cache updated for the open book")
    tick(5)
    b.sync:onClose(ub)
    check(b.store:counts().outbox == 0, "nothing echoed back on close")

    -- While B reads, A renames the book and edits the TOC; B applies live after a sync.
    tick(5)
    a.ui = nil
    S.mkdirp(sdrDir(pa))
    S.writeFile(sdrDir(pa) .. "/custom_metadata.lua", "return " .. serialize{
        doc_props = { title = "Tome" }, custom_props = { title = "The Tome" } } .. "\n")
    local da = readSidecar(pa)
    da.handmade_toc = { { title = "Part one", depth = 1, page = 3, xpointer = XP1 } }
    da.handmade_toc_enabled = true
    writeSidecar(pa, da)
    lfs.touch(sdrDir(pa) .. "/metadata.epub.lua", clock + 9, clock + 9)
    a.sync:refresh(); a:run()
    check(a:send(b) == 2, "A sends the new title and TOC")
    ub = reader(b, pb, { status = "complete", modified = "2026-01-01" },
        { { title = "Part one", depth = 1, page = 3, xpointer = XP1 }, { title = "Part two", depth = 1, page = 90, xpointer = XP2 } })
    b.sync.loaded = nil
    b.sync:afterSync({ book_affected = { [MD] = true } }); b:run()
    check(#ub.handmade.toc == 1, "open book: TOC change applied live")
    check(ub.doc_props.title == "The Tome" and ub.doc_props.display_title == "The Tome", "open book: title updated")
    local cm = readCustom(pb)
    check(cm and cm.custom_props.title == "The Tome", "open book: custom metadata file written")
end

S.finish("omnisync book data tests")
