-- Unit tests for statsync's annotation sync: the record format, keys, the
-- merge, change detection and held deletions (supersync/annstore.lua), and
-- applying changes inside a reader (supersync/annsync.lua) with KOReader's
-- own ReaderAnnotation code on a stand-in document.
-- Run through scripts/test-statsync.sh, which sets KOREADER_SRC.

local S = dofile("tests/supersync/support.lua")
local check = S.check

local AnnFormat = require("supersync/annformat")
local AnnStore = require("supersync/annstore")
local AnnSync = require("supersync/annsync")
local Codec = require("supersync/codec")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/ann"
S.rmrf(TMP)
S.mkdirp(TMP)

local quiet = { info = function() end, warn = function(...) if os.getenv("STATSYNC_VERBOSE") then print(...) end end,
                dbg = function() end, err = print }

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

-- KOReader's ReaderAnnotation, unmodified, on a stand-in document ------------------

local function loadReaderAnnotation()
    local stubs = {
        docsettings = {}, luasettings = {}, ["ui/widget/notification"] = {},
        ["ui/widget/container/widgetcontainer"] = { extend = function(_, o) o = o or {}; o.__index = o; return o end },
        ["libs/libkoreader-lfs"] = {}, logger = quiet,
        gettext = setmetatable({}, { __call = function(_, s) return s end }),
        ["ffi/util"] = { template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end },
    }
    local saved = {}
    for name, mod in pairs(stubs) do saved[name] = package.loaded[name]; package.loaded[name] = mod end
    local RA = dofile(S.koreader .. "/frontend/apps/reader/modules/readerannotation.lua")
    for name in pairs(stubs) do package.loaded[name] = saved[name] end
    return RA
end
local ReaderAnnotation = loadReaderAnnotation()

-- XPointers here look like /body/DocFragment[F]/body/p[P]/text().O; page = F.
local function xp(f, p, o) return string.format("/body/DocFragment[%d]/body/p[%d]/text().%d", f, p, o) end
local function parseXp(x)
    local f, p, o = tostring(x):match("^/body/DocFragment%[(%d+)%]/body/p%[(%d+)%]/text%(%)%.(%d+)$")
    if not f then return nil end
    return tonumber(f), tonumber(p), tonumber(o)
end
local FakeCre = {
    getPageFromXPointer = function(_, x) return (parseXp(x)) or 1 end,
    isXPointerInDocument = function(_, x) return parseXp(x) ~= nil end,
    -- KOReader's convention: 1 if a is before b, -1 if after, 0 if equal.
    compareXPointers = function(_, a, b)
        local a1, a2, a3 = parseXp(a)
        local b1, b2, b3 = parseXp(b)
        local ka, kb = a1 * 1e8 + a2 * 1e4 + a3, b1 * 1e8 + b2 * 1e4 + b3
        if ka == kb then return 0 end
        return ka < kb and 1 or -1
    end,
    hasHiddenFlows = function() return false end,
}

local clock = 1800000000
local function tick(n) clock = clock + (n or 1) end
local function stamp() return os.date("%Y-%m-%d %H:%M:%S", clock) end

-- A simulated device: a state database, sidecars (md5 -> saved list), and a
-- reader that loads them the way KOReader does.
local Dev = {}
Dev.__index = Dev
local n_dev = 0
local function newDev(name)
    n_dev = n_dev + 1
    local dir = TMP .. "/dev" .. n_dev .. "-" .. name
    S.mkdirp(dir)
    local dev = setmetatable({ name = name, id = "dev" .. name, sidecars = {}, events = {}, asked = {} }, Dev)
    dev.store = AnnStore.new{ sq3 = S.SQ3, state_path = dir .. "/statsync.sqlite3" }
    dev.sync = AnnSync.new{
        store = dev.store, getDeviceId = function() return dev.id end, now = function() return clock end,
        logger = quiet, enabled = function() return true end,
        schedule = function(delay, fn) if delay > 0 then dev.later = fn else fn() end end,
        readerUI = function() return dev.ui end,
        event = { new = function(_, name, args) return { name = name, args = args } end },
        ui_manager = { getTopmostVisibleWidget = function() return dev.top or dev.ui end, setDirty = function() dev.dirty = true end },
        confirm = function(h, text, done) table.insert(dev.asked, { h = h, text = text, done = done }) end,
        -- No book files unless a test sets some up (closed-book writes skip).
        lfs = { attributes = function() return nil end },
        booklist = { resetBookInfoCache = function(p) dev.cache_reset = p end },
    }
    return dev
end

--- A book's saved list for one engine (KOReader keeps the other aside).
function Dev:sidecar(md5, kind, list)
    local key = md5 .. "/" .. (kind or "rolling")
    if list then self.sidecars[key] = list end
    return self.sidecars[key] or {}
end

--- Opens a book (md5) as KOReader would: its saved list, sorted.
function Dev:open(md5, kind, opts)
    opts = opts or {}
    local ui = { rolling = kind ~= "paging" or nil, paging = kind == "paging" or nil, document = setmetatable({ file = "/books/" .. md5 .. ".epub" }, { __index = FakeCre }),
                 doc_props = { display_title = "Book " .. md5:sub(1, 4), authors = "A" } }
    ui.dialog = ui
    local settings = { partial_md5_checksum = md5, cre_dom_version = opts.dom or 20240114 }
    ui.doc_settings = { readSetting = function(_, k) return settings[k] end }
    ui.annotation = setmetatable({ ui = ui, document = ui.document, view = {},
                                   annotations = deepcopy(self:sidecar(md5, kind)) }, { __index = ReaderAnnotation })
    ui.annotation:updateAnnotations(true, true)
    local dev = self
    ui.handleEvent = function(_, ev)
        table.insert(dev.events, ev)
        if ev.name == "AnnotationsModified" then ui.annotation:onAnnotationsModified(ev.args) end
    end
    self.ui = ui
    self.held_on_open = self.sync:onReaderReady(ui)
    return ui
end

--- Closes the open book: KOReader saves the list, then CloseDocument.
function Dev:close()
    local ui = self.ui
    self:sidecar(ui.doc_settings:readSetting("partial_md5_checksum"), ui.paging and "paging" or "rolling",
        deepcopy(ui.annotation.annotations))
    local held = self.sync:onClose(ui)
    self.ui = nil
    return held
end

--- Adds a highlight as KOReader does (addItem, at the current time).
function Dev:highlight(f, p, o1, o2, extra)
    local item = { datetime = stamp(), drawer = "lighten", color = "yellow", text = "text " .. f .. "." .. p .. "." .. o1,
                   page = xp(f, p, o1), pos0 = xp(f, p, o1), pos1 = xp(f, p, o2), chapter = "Chapter " .. f }
    for k, v in pairs(extra or {}) do item[k] = v end
    self.ui.annotation:addItem(item)
    return item
end

function Dev:bookmark(f)
    local item = { datetime = stamp(), page = xp(f, 1, 0), text = "in Chapter " .. f, chapter = "Chapter " .. f }
    self.ui.annotation:addItem(item)
    return item
end

--- Edits an item as KOReader does (AnnotationsModified stamps datetime_updated).
function Dev:edit(item, fields)
    for k, v in pairs(fields) do item[k] = v end
    self.ui.annotation:onAnnotationsModified({ item })
    check(item.datetime_updated ~= nil, "KOReader stamps an edit")
    item.datetime_updated = stamp() -- the simulated clock, not the real one
end

function Dev:remove(item)
    local list = self.ui.annotation.annotations
    for i, it in ipairs(list) do if it == item then table.remove(list, i); return end end
end

--- The list as comparable text (synced fields only).
function Dev:listText(md5)
    local list = self.ui and self.ui.doc_settings:readSetting("partial_md5_checksum") == md5
        and self.ui.annotation.annotations or self:sidecar(md5)
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = AnnFormat.fieldsJson(item) end
    return table.concat(out, "\n")
end

--- Merged state of a book as text (for convergence checks).
function Dev:merged(md5, kind)
    local c = S.SQ3.open(self.store.state_path)
    local rows = {}
    for r in c:prepare("SELECT key, updated, device, deleted, hash FROM ann_merged WHERE md5 = ? AND kind = ? ORDER BY key")
            :bind(md5, kind or "rolling"):rows() do
        rows[#rows + 1] = table.concat({ r[1], tonumber(r[2]), r[3], tonumber(r[4]), r[5] }, "|")
    end
    c:close()
    return table.concat(rows, "\n")
end

function Dev:outbox()
    local c = S.SQ3.open(self.store.state_path)
    local n = tonumber(c:rowexec("SELECT count(*) FROM ann_outbox"))
    c:close()
    return n
end

local seg_n = 0
--- This device's waiting changes as a segment (marked sent, as after an upload).
function Dev:export()
    seg_n = seg_n + 1
    local path = TMP .. "/ann-" .. seg_n .. ".jsonl"
    local res = self.store:export{ device_id = self.id, out_path = path, now = clock, max_records = 1000 }
    if not res then return nil end
    self.store:markExported(path, self.id, "ann-" .. seg_n, res.size, nil, clock)
    return path, res
end

function Dev:import(path, from)
    local s, err, kind = self.store:importSegment(path, from or "other", path:match("[^/]+$"), nil, nil, clock)
    if s and self.ui then self.sync:afterSync({ ann_affected = s.affected }) end
    return s, err, kind
end

local M1 = string.rep("1", 32)
local M2 = string.rep("2", 32)

-- Format ------------------------------------------------------------------------------

do
    -- Lua values that aren't JSON-shaped survive the round trip.
    local item = {
        datetime = "2026-01-02 03:04:05", drawer = "underscore", color = "red", text = "Ünïcødé “x” \0 nul\nline",
        note = "note", text_edited = true, page = 12,
        pos0 = { x = 10.123456789, y = 20.5, page = 12, zoom = 1, rotation = 0 },
        pos1 = { x = 0.1, y = 1e-7, page = 14 },
        pboxes = { { x = 1, y = 2, w = 3, h = 4 }, { x = 5, y = 6, w = 7, h = 8 } },
        ext = { [13] = { pos0 = { x = 1, y = 1 }, pboxes = { { x = 0, y = 0, w = 1, h = 1 } } },
                [14] = { pos0 = { x = 2, y = 2 } } },
        pageno = 12, pageref = "xii",
    }
    local json = assert(AnnFormat.fieldsJson(item))
    check(not json:find("pageno") and not json:find("pageref"), "layout fields not sent")
    local back = AnnFormat.itemFromJson(json)
    check(back.ext[13].pboxes[1].w == 1 and back.ext[14].pos0.x == 2 and back.ext[1] == nil, "page-keyed ext round trip")
    check(back.pos0.x == 10.123456789 and back.pos1.y == 1e-7, "coordinates exact")
    check(back.text == item.text and back.text_edited == true and back.pboxes[2].h == 8, "text, booleans, arrays")
    check(AnnFormat.fieldsJson(back) == json, "canonical: same JSON again")
    -- Same content built in another order: same JSON (hash).
    local other = {}
    local keys = {}
    for k in pairs(item) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return a > b end)
    for _, k in ipairs(keys) do other[k] = deepcopy(item[k]) end
    check(AnnFormat.fieldsJson(other) == json, "field order doesn't matter")
    check(AnnFormat.fieldsJson({ datetime = "x", page = 1, bad = function() end }) == nil, "functions can't be sent")

    -- Keys
    local a = { datetime = "2026-01-01 10:00:00", page = xp(1, 1, 0), pos0 = xp(1, 1, 0), pos1 = xp(1, 1, 5) }
    local b = { datetime = "2026-01-01 10:00:01", page = xp(1, 2, 0), pos0 = xp(1, 2, 0), pos1 = xp(1, 2, 5) }
    local c = { datetime = "2026-01-01 10:00:01", page = xp(1, 3, 0), pos0 = xp(1, 3, 0), pos1 = xp(1, 3, 5) }
    local k = AnnFormat.keys({ a, b, c }, "rolling")
    check(k[1] == a.datetime, "unique creation time is the key")
    check(k[2] ~= k[3] and k[2]:find(b.pos0, 1, true) and k[3]:find(c.pos0, 1, true), "shared second: position added")
    check(AnnFormat.keys({ c, b, a }, "rolling")[1] == k[3], "keys don't depend on list order")
    local dup = AnnFormat.keys({ b, deepcopy(b) }, "rolling")
    check(dup[1] ~= dup[2], "exact duplicates still get distinct keys")
    local pk = AnnFormat.keys({ { datetime = "d", page = 3, pos0 = { x = 1.00001, y = 2 } }, { datetime = "d", page = 3 } }, "paging")
    check(pk[1] == "d|3|1.000,2.000|" and pk[2] == "d|3||", "paging keys: page and rounded coordinates")
    check(AnnFormat.parseTime("2026-01-02 03:04:05") == os.time{ year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 },
        "local time string to epoch")
    check(AnnFormat.parseTime("yesterday") == nil, "bad time rejected")

    -- Segment validation
    local function seg(lines)
        local path = TMP .. "/v-" .. math.random(1e9) .. ".jsonl"
        S.writeFile(path, table.concat(lines, "\n") .. "\n")
        return path
    end
    local H = AnnFormat.headerLine("devX", 1)
    local B = AnnFormat.bookLine{ md5 = M1, title = "T" }
    local R = AnnFormat.recordLine{ md5 = M1, kind = "rolling", key = "k", updated = 5, device = "devX",
                                    fields_json = AnnFormat.fieldsJson{ datetime = "k", page = xp(1, 1, 1) } }
    local X = AnnFormat.recordLine{ md5 = M1, kind = "rolling", key = "k2", updated = 6, device = "devX" }
    local got = {}
    local hdr = AnnFormat.readSegment(seg{ H, B, R, X, AnnFormat.trailerLine(1, 2) }, { record = function(r) got[#got + 1] = r end })
    check(hdr and hdr.records == 2 and got[1].t == "a" and got[2].t == "x" and got[1].dev == "devX", "valid segment read")
    local cases = {
        { "no trailer", { H, B, R } },
        { "counts", { H, B, R, AnnFormat.trailerLine(1, 2) } },
        { "record before book", { H, R, B, AnnFormat.trailerLine(1, 1) } },
        { "major version", { (H:gsub('"v":1', '"v":2')), B, R, AnnFormat.trailerLine(1, 1) } },
        { "statistics segment", { Codec.headerLine("devX", 1), B, R, AnnFormat.trailerLine(1, 1) } },
        { "bad kind", { H, B, (R:gsub('"rolling"', '"scroll"')), AnnFormat.trailerLine(1, 1) } },
        { "paging page not a number", { H, B, (R:gsub('"rolling"', '"paging"')), AnnFormat.trailerLine(1, 1) } },
        { "fractional upd", { H, B, (R:gsub('"upd":5', '"upd":5.5')), AnnFormat.trailerLine(1, 1) } },
        { "fields not an object", { H, B, '{"t":"a","md5":"' .. M1 .. '","kind":"rolling","key":"k","upd":1,"f":[1]}', AnnFormat.trailerLine(1, 1) } },
        { "garbage", { H, B, "{", AnnFormat.trailerLine(1, 0) } },
    }
    for _, cse in ipairs(cases) do
        local ok, err = AnnFormat.readSegment(seg(cse[2]))
        check(ok == nil and err, "rejects annotation segment: " .. cse[1])
    end
    check(AnnFormat.readSegment(seg{ (H:gsub('"minor":0', '"minor":4')), B, '{"t":"future","x":1}', R, AnnFormat.trailerLine(1, 1) }),
        "unknown record type skipped")
    check(AnnFormat.segmentName(3) == "ann-0000000003.jsonl.zst" and AnnFormat.segmentSeq("ann-0000000003.jsonl.zst") == 3
        and AnnFormat.segmentSeq("seg-0000000003.jsonl.zst") == nil, "annotation segment names")
end

-- Sync between devices ---------------------------------------------------------------

do -- adds, edits and deletions reach the other device, which applies them on open
    local A, B = newDev("A"), newDev("B")
    A:open(M1, "rolling")
    local h1 = A:highlight(1, 2, 0, 10); tick()
    local h2 = A:highlight(3, 1, 5, 9, { note = "first note" }); tick()
    A:bookmark(2); tick()
    A:close()
    local seg = A:export()
    check(seg, "A sends its new annotations")
    check(A:export() == nil, "nothing more to send")
    local s = B:import(seg, A.id)
    check(s and s.records == 3 and s.applied == 3 and s.affected[M1 .. "\0rolling"], "B imports 3 records")
    check(B.store:isPending(M1, "rolling"), "book marked to update when opened")
    local ui = B:open(M1, "rolling")
    check(#ui.annotation.annotations == 3, "B's book gets all three on open")
    check(B:listText(M1) == A:listText(M1), "same annotations, same order as A")
    local list = ui.annotation.annotations
    check(list[1].pageno == 1 and list[2].pageno == 2 and list[3].pageno == 3, "sorted by position, page numbers computed")
    check(not B.store:isPending(M1, "rolling"), "no longer pending")
    local ev = B.events[#B.events]
    check(ev and ev.name == "AnnotationsModified" and ev.args.index_modified and ev.args.nb_highlights_added == 1
        and ev.args.nb_notes_added == 1, "AnnotationsModified with count deltas")
    check(list[1].datetime_updated == nil and list[2].datetime_updated == nil, "applying doesn't stamp datetime_updated")
    B:close()
    check(B:export() == nil, "applied changes aren't sent back")

    -- Edit on A (note), delete on A (bookmark)
    tick(10)
    A:open(M1, "rolling")
    local items = A.ui.annotation.annotations
    local h2a = items[3]
    A:edit(h2a, { note = "edited note", color = "green" })
    A:remove(items[2]) -- the bookmark (page 2)
    A:close()
    local seg2, r2 = A:export()
    check(r2 and r2.records == 2, "an edit and a deletion sent")
    B:import(seg2, A.id)
    B:open(M1, "rolling")
    check(#B.ui.annotation.annotations == 2 and B.ui.annotation.annotations[2].note == "edited note"
        and B.ui.annotation.annotations[2].color == "green", "edit and deletion applied")
    check(B:listText(M1) == A:listText(M1), "lists equal again")
    B:close()
    check(B:export() == nil, "still nothing echoed")
    local _ = h1, h2
end

do -- live: the open book gets changes after a sync, unless the user is busy
    local A, B = newDev("A"), newDev("B")
    A:open(M2, "rolling"); A:highlight(1, 1, 0, 3); tick(); A:close()
    B:open(M2, "rolling")
    B.top = {} -- a dialog over the reader
    B:import(A:export(), A.id)
    check(#B.ui.annotation.annotations == 0, "not applied while a dialog is open")
    check(B.later and B.sync.retrying, "a retry is scheduled")
    B.later() -- still busy: tries again
    check(#B.ui.annotation.annotations == 0 and B.sync.retrying, "still busy: not yet")
    B.top = nil
    B.later()
    check(#B.ui.annotation.annotations == 1 and B.dirty and not B.sync.retrying, "applied once the dialog closed, and redrawn")
    -- B's own highlight, made while the sync ran, isn't lost
    tick()
    B:highlight(2, 1, 0, 3); tick()
    A:open(M2, "rolling"); A:highlight(3, 1, 0, 3); tick(); A:close()
    B:import(A:export(), A.id)
    check(#B.ui.annotation.annotations == 3, "remote addition applied next to an unsent local one")
    B:close()
    A:import(B:export(), B.id)
    A:open(M2, "rolling")
    check(#A.ui.annotation.annotations == 3 and A:listText(M2) == B:listText(M2), "both have all three")
    A:close()
end

do -- order independence and newest-wins, three devices
    local A, B, C = newDev("A"), newDev("B"), newDev("C")
    -- Same starting point everywhere
    A:open(M1, "rolling"); local h = A:highlight(1, 1, 0, 5); tick(); A:close()
    local base = A:export()
    B:import(base, A.id); C:import(base, A.id)
    B:open(M1, "rolling"); B:close(); C:open(M1, "rolling"); C:close()
    -- Concurrent: B edits at t+5, C deletes at t+9, A edits at t+2
    local t0 = clock
    clock = t0 + 2; A:open(M1, "rolling"); A:edit(A.ui.annotation.annotations[1], { note = "A" }); A:close()
    clock = t0 + 5; B:open(M1, "rolling"); B:edit(B.ui.annotation.annotations[1], { note = "B" }); B:close()
    clock = t0 + 9; C:open(M1, "rolling"); C:remove(C.ui.annotation.annotations[1]); C:close()
    clock = t0 + 20
    local segs = { A = A:export(), B = B:export(), C = C:export() }
    check(segs.A and segs.B and segs.C, "each sends its change")
    local results = {}
    for i, order in ipairs({ { "A", "B", "C" }, { "C", "B", "A" }, { "B", "C", "A" } }) do
        local D = newDev("D" .. i)
        D:import(base, A.id)
        for _, from in ipairs(order) do D:import(segs[from], from) end
        results[i] = D:merged(M1)
        D:open(M1, "rolling")
        check(#D.ui.annotation.annotations == 0, "newest change (C's deletion) wins in order " .. i)
        D:close()
    end
    check(results[1] == results[2] and results[2] == results[3], "same merged state in any order")
    -- Importing everything twice changes nothing
    local D = newDev("D4")
    for _ = 1, 2 do for _, from in ipairs({ "A", "B", "C" }) do D:import(segs[from], from) end end
    check(D:merged(M1) == results[1], "idempotent")
    -- A late, old segment doesn't bring it back
    D:import(base, A.id)
    check(D:merged(M1) == results[1], "late old record doesn't resurrect a deletion")
    -- An edit newer than the deletion does
    clock = t0 + 30
    A:import(segs.C, C.id)
    A:open(M1, "rolling")
    check(#A.ui.annotation.annotations == 0, "A applies the deletion")
    A:close()
    local _ = h
end

do -- detection details: no timestamp change, first look, the other engine's list
    local A = newDev("A")
    A:open(M1, "rolling"); A:highlight(1, 1, 0, 5); tick(); A:close()
    A:export()
    -- An outside edit (no datetime_updated change) while closed
    tick(100)
    A:sidecar(M1)[1].note = "edited outside"
    local now_before = clock
    A:open(M1, "rolling"); A:close()
    local seg = A:export()
    local rec
    AnnFormat.readSegment(seg, { record = function(r) rec = r end })
    check(rec and rec.upd == now_before and rec.f.note == "edited outside", "outside edit sent with the time it was found")

    -- Paging list of the same book: separate, and the rolling one isn't "deleted"
    A:open(M1, "paging")
    check(#A.ui.annotation.annotations == 0, "paging list doesn't get rolling annotations")
    A:close()
    check(A:export() == nil, "opening with the other engine deletes nothing")

    -- Old DOM version: left out
    local B = newDev("B")
    B:import(seg, A.id)
    B:open(M1, "rolling", { dom = 20180503 })
    check(#B.ui.annotation.annotations == 0, "book on an old DOM version not touched")
    B:close()

    -- First look at a book that already has annotations on both sides
    local C = newDev("C")
    C:sidecar(M1, "rolling", { { datetime = "2020-05-05 05:05:05", drawer = "lighten", page = xp(4, 1, 0), pos0 = xp(4, 1, 0), pos1 = xp(4, 1, 2), text = "C's" } })
    C:import(seg, A.id)
    C:open(M1, "rolling")
    check(#C.ui.annotation.annotations == 2, "first look: merged ones added, own kept")
    C:close()
    local _, cres = C:export()
    check(cres and cres.records == 1, "first look: own annotation sent, nothing deleted")
end

do -- mass deletion: held, then each answer
    local A, B = newDev("A"), newDev("B")
    A:open(M1, "rolling")
    for i = 1, 8 do A:highlight(i, 1, 0, 4); tick() end
    A:close()
    B:import(A:export(), A.id)
    B:open(M1, "rolling"); B:close()
    -- Sidecar reset on A
    A:sidecar(M1, "rolling", {})
    A:open(M1, "rolling")
    check(#A.ui.annotation.annotations == 0, "held ones aren't put back on open")
    check(A.held_on_open == 8, "reset found on open, all 8 held (" .. tostring(A.held_on_open) .. ")")
    check(A:close() == 0, "not held a second time on close")
    check(A:export() == nil, "nothing sent while held")
    local list = A.store:held()
    check(#list == 1 and list[1].count == 8 and list[1].total == 8 and list[1].title == "Book 1111", "held book listed")
    A.sync:askHeld()
    check(#A.asked == 1 and A.asked[1].text:find("8 of 8", 1, true) and A.asked[1].text:find("Book 1111", 1, true), "user asked")
    A.asked[1].done(nil) -- ask later
    check(#A.store:held() == 1, "ask later: still held")
    A.sync:askHeld()
    A.asked[2].done("restore")
    check(#A.store:held() == 0 and A.store:isPending(M1, "rolling"), "restore: no longer held, to be applied")
    A:open(M1, "rolling")
    check(#A.ui.annotation.annotations == 8, "restored on open")
    -- 6 of 8 removed (more than 5): held; answer remove
    tick(5)
    local items = A.ui.annotation.annotations
    for _ = 1, 6 do table.remove(items, 1) end
    A:close()
    A.sync:askHeld()
    A.asked[#A.asked].done("remove")
    local _, r = A:export()
    check(r and r.records == 6, "remove everywhere: 6 deletions sent")
    -- 3 of 8: below the threshold, deleted straight away
    local C = newDev("C")
    C:open(M2, "rolling")
    for i = 1, 8 do C:highlight(i, 1, 0, 4); tick() end
    C:close(); C:export()
    C:open(M2, "rolling")
    for _ = 1, 3 do table.remove(C.ui.annotation.annotations, 1) end
    check(C:close() == 0, "3 of 8 removed: not held")
    local _, cr = C:export()
    check(cr and cr.records == 3, "3 deletions sent straight away")
    -- The only highlight removed: 5 or fewer, deleted straight away
    C:open(M1, "rolling"); C:highlight(1, 1, 0, 1); tick(); C:close(); C:export()
    C:open(M1, "rolling")
    table.remove(C.ui.annotation.annotations, 1)
    check(C:close() == 0, "a book's only highlight removed: not held")
    local _, cr1 = C:export()
    check(cr1 and cr1.records == 1, "its deletion sent straight away")
    -- 6 of 20: fewer than half, but more than 5: held
    local D = newDev("D")
    D:open(M2, "rolling")
    for i = 1, 20 do D:highlight(i, 1, 0, 4); tick() end
    D:close(); D:export()
    D:open(M2, "rolling")
    for _ = 1, 6 do table.remove(D.ui.annotation.annotations, 1) end
    check(D:close() == 6, "6 of 20 removed: held")
    -- All 6 of a book's removed: held
    C:open(M1, "rolling")
    for i = 2, 7 do C:highlight(i, 1, 0, 1); tick() end
    C:close(); C:export()
    C:open(M1, "rolling")
    local before = deepcopy(C.ui.annotation.annotations)
    for _ = 1, 6 do table.remove(C.ui.annotation.annotations, 1) end
    check(C:close() == 6, "all 6 of a book's annotations gone: held")
    -- Put back by hand before answering: no longer held, nothing sent
    C:sidecar(M1, "rolling", before)
    C:open(M1, "rolling")
    check(#C.ui.annotation.annotations == 6, "items back")
    C:close()
    check(#C.store:held() == 0 and C:export() == nil, "back again: no longer held, nothing to send")
end

do -- held deletion resolved as remove reaches the other device
    local A, B = newDev("A"), newDev("B")
    A:open(M1, "rolling")
    for i = 1, 7 do A:highlight(i, 1, 0, 4); tick() end
    A:close()
    B:import(A:export(), A.id)
    B:open(M1, "rolling"); B:close()
    A:sidecar(M1, "rolling", {})
    A:open(M1, "rolling"); A:close()
    A.sync:askHeld()
    A.asked[1].done("remove")
    B:import(A:export(), A.id)
    B:open(M1, "rolling")
    check(#B.ui.annotation.annotations == 0, "removed everywhere: gone on B too")
    B:close()
end

do -- history scan
    local A = newDev("A")
    local files = {
        ["/books/one.epub"] = { partial_md5_checksum = M1, doc_props = { title = "One", authors = "X" },
                                annotations = { { datetime = "2025-01-01 00:00:00", page = xp(1, 1, 0), pos0 = xp(1, 1, 0), pos1 = xp(1, 1, 3), drawer = "lighten" } },
                                annotations_paging = { { datetime = "2025-01-02 00:00:00", page = 3, pos0 = { x = 1, y = 2, page = 3 }, pos1 = { x = 5, y = 2, page = 3 }, drawer = "lighten" } } },
        ["/books/old.epub"] = { partial_md5_checksum = M2, cre_dom_version = 20180503,
                                annotations = { { datetime = "2025-01-03 00:00:00", page = xp(1, 1, 0), pos0 = xp(1, 1, 0), pos1 = xp(1, 1, 3) } } },
        ["/books/none.pdf"] = { partial_md5_checksum = string.rep("3", 32) },
    }
    A.sync.deps.docsettings = {
        hasSidecarFile = function(_, p) return files[p] ~= nil end,
        open = function(_, p) return { readSetting = function(_, k) return files[p][k] end } end,
    }
    A.sync.deps.lfs = { attributes = function(p) return (files[p] or p == "/books/gone.epub") and p ~= "/books/gone.epub" and "file" or nil end }
    A.sync.deps.readhistory = { hist = { { file = "/books/one.epub" }, { file = "/books/old.epub" }, { file = "/books/none.pdf" }, { file = "/books/gone.epub" } } }
    local scanned
    A.sync.deps.saveScanned = function(t) scanned = t end
    local stats
    A.sync:scan(function(s) stats = s end)
    check(stats and stats.books == 1 and stats.lists == 2, "scan: one book, both its lists; old DOM and empty skipped")
    check(scanned == clock, "scan recorded as done")
    local _, r = A:export()
    check(r and r.records == 2, "scanned annotations sent")
    -- Scanning again finds nothing new
    A.sync:scan()
    check(A:export() == nil, "second scan: nothing new")
end

do -- closed books: merged changes written into their sidecars
    local A, B = newDev("A"), newDev("B")
    local PATH = "/books/" .. M1 .. ".epub"
    local files, flushes = {}, 0
    B.sync.deps.docsettings = {
        hasSidecarFile = function(_, p) return files[p] ~= nil end,
        open = function(_, p)
            local data = deepcopy(files[p])
            return { readSetting = function(_, k) return data[k] end,
                     saveSetting = function(_, k, v) data[k] = v end,
                     flush = function() flushes = flushes + 1; files[p] = deepcopy(data) end }
        end,
    }
    B.sync.deps.lfs = { attributes = function(p) return files[p] and "file" or nil end }
    local function sidecarList() return files[PATH].annotations end
    local function texts(list)
        local out = {}
        for _, it in ipairs(list) do out[#out + 1] = it.text end
        table.sort(out)
        return table.concat(out, ",")
    end

    -- B read the book once, with one highlight; it's closed now.
    A:open(M1, "rolling"); local a1 = A:highlight(1, 1, 0, 5); tick(); A:close()
    B:import(A:export(), A.id)
    B:open(M1, "rolling"); B:close()
    files[PATH] = { partial_md5_checksum = M1, doc_props = { title = "One" }, annotations = deepcopy(B:sidecar(M1)) }
    check(#sidecarList() == 1, "B's closed sidecar has the first highlight")

    -- A adds two and edits the first; B syncs with the book closed.
    A:open(M1, "rolling")
    tick(); A:highlight(2, 1, 0, 5); tick(); A:highlight(3, 1, 0, 5)
    tick(); A:edit(A.ui.annotation.annotations[1], { note = "edited on A" })
    A:close()
    B:import(A:export(), A.id)
    B.sync:afterSync({})
    local list = sidecarList()
    check(#list == 3 and files[PATH].annotations_externally_modified == true,
        "written into the closed book, flagged for KOReader to update (" .. #list .. ")")
    local noted
    for _, it in ipairs(list) do if it.note == "edited on A" then noted = it end end
    check(noted and noted.text == a1.text and noted.pageno == nil, "edit written, layout fields left for KOReader")
    check(B.cache_reset == PATH, "file browser's cache refreshed")
    check(B:outbox() == 0 and not B.store:isPending(M1, "rolling"), "nothing echoed back, nothing left to apply")

    -- A change made in the closed sidecar (KOHighlights, say) isn't overwritten: it's sent.
    local xp4 = xp(4, 1, 0)
    table.insert(files[PATH].annotations, { datetime = "2026-07-07 07:07:07", drawer = "lighten", text = "outside",
                                            page = xp4, pos0 = xp4, pos1 = xp(4, 1, 5) })
    A:open(M1, "rolling"); A:remove(A.ui.annotation.annotations[2]); tick(); A:close()
    B:import(A:export(), A.id)
    B.sync:afterSync({})
    check(#sidecarList() == 3 and texts(sidecarList()):find("outside", 1, true), "removal from A written, outside addition kept")
    local _, r = B:export()
    check(r and r.records == 1, "the outside addition is sent from B")

    -- The book open on B: not written (the reader has it, it's applied live).
    A:open(M1, "rolling"); tick(); A:highlight(5, 1, 0, 5); A:close()
    B:import(A:export(), A.id)
    local before = flushes
    B.ui = { document = { file = PATH } }
    B.sync:writeAll()
    check(flushes == before, "the open book's sidecar isn't written")
    B.ui = nil
    B.sync:afterSync({})
    check(flushes == before + 1 and #sidecarList() == 4, "written once the book is closed")

    -- The sidecar's main list is for the other engine: left for when it's opened that way.
    local saved = files[PATH]
    files[PATH] = { partial_md5_checksum = M1, annotations = { { datetime = "2025-01-01 00:00:00", page = 3,
        pos0 = { x = 1, y = 1, page = 3 }, pos1 = { x = 2, y = 1, page = 3 } } }, annotations_rolling = saved.annotations }
    A:open(M1, "rolling"); tick(); A:highlight(6, 1, 0, 5); A:close()
    B:import(A:export(), A.id)
    before = flushes
    B.sync:afterSync({})
    check(flushes == before and #files[PATH].annotations_rolling == 4, "other engine's list not written")
    check(B.store:isPending(M1, "rolling"), "still to apply when opened")
    files[PATH] = saved

    -- Emptied outside (settings reset): held, the user is asked, nothing restored on its own.
    A:open(M1, "rolling"); tick(); A:highlight(7, 1, 0, 5); A:close()
    B:import(A:export(), A.id)
    B.sync:afterSync({})
    check(#sidecarList() == 6, "six in the closed book after catching up")
    tick()
    files[PATH].annotations = {}
    files[PATH].annotations_externally_modified = nil
    B.asked = {}
    -- Noticed when there's next something to write into it.
    A:open(M1, "rolling"); tick(); A:highlight(8, 1, 0, 5); A:close()
    B:import(A:export(), A.id)
    B.sync:afterSync({})
    check(#files[PATH].annotations == 1 and #B.asked == 1 and B.asked[1].text:find("6 of 7", 1, true),
        "emptied closed book: held and asked, only the new one written ("
        .. #files[PATH].annotations .. ", " .. tostring(B.asked[1] and B.asked[1].text) .. ")")
    check(B:export() == nil, "nothing removed elsewhere")
    B.asked[1].done("restore")
    check(#sidecarList() == 7, "restore: written back into the closed book at once")
end

do -- status counts and requeue
    local A = newDev("A")
    A:open(M1, "rolling"); A:highlight(1, 1, 0, 2); tick(); A:highlight(2, 1, 0, 2); tick(); A:close()
    A:export()
    local c = A.store:counts()
    check(c.annotations == 2 and c.books == 1 and c.outbox == 0 and c.held == 0, "counts")
    A.store:requeueAll()
    check(A:outbox() == 2, "requeue: everything to send again")
end

S.finish("supersync annotation tests")
