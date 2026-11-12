-- Unit tests for Concordance's reading history sync (concordance/histsync.lua,
-- with its records in concordance/bookstore.lua), with KOReader's ReadHistory
-- stood in for and book files as real files.
-- Run through scripts/test-concordance.sh, which sets KOREADER_SRC.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local BookFormat = require("concordance/bookformat")
local BookStore = require("concordance/bookstore")
local CollSync = require("concordance/collsync")
local HistSync = require("concordance/histsync")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/hist"
S.rmrf(TMP)
S.mkdirp(TMP)

local quiet = { info = function() end, warn = function(...) if os.getenv("STATSYNC_VERBOSE") then print(...) end end,
                dbg = function() end, err = print }
local lfs = require("lfs")

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

-- KOReader's ReadHistory, enough of it ------------------------------------------------------
local RH = {}
RH.__index = RH
local function newRH() return setmetatable({ hist = {}, size = 500, flushes = 0 }, RH) end
-- As KOReader's with force_read: the saved history read back, every entry
-- a new table.
function RH:reload(force_read)
    if not force_read then return end
    self.reloads = (self.reloads or 0) + 1
    local fresh = {}
    for i, v in ipairs(self.hist) do
        local e = {}
        for k, x in pairs(v) do e[k] = x end
        fresh[i] = e
    end
    self.hist = fresh
end
function RH:getIndexByFile(file)
    for i, v in ipairs(self.hist) do if v.file == file then return i end end
end
function RH:getIndexByTime(t)
    local i = 1
    while self.hist[i] and self.hist[i].time >= t do i = i + 1 end
    return i
end
function RH:_reduce() while #self.hist > self.size do table.remove(self.hist) end end
function RH:_flush() self.flushes = self.flushes + 1 end
function RH:updateDateTimeString() end
-- As KOReader's: with a time, only an existing file, put in at that time.
function RH:addItem(file, ts, no_flush)
    if self.incognito then return end -- ZenOS's incognito mode wraps it so
    if ts and lfs.attributes(file, "mode") ~= "file" then return end
    local index = self:getIndexByFile(file)
    if ts and index and self.hist[index].time == ts then return end
    local now = ts or clock
    lfs.touch(file, now, lfs.attributes(file, "modification"))
    if index then table.remove(self.hist, index) end
    index = ts and self:getIndexByTime(ts) or 1
    table.insert(self.hist, index, { file = file, time = now, text = file:gsub(".*/", ""),
                                      dim = false, select_enabled = true, mandatory = "t" })
    self.added = (self.added or 0) + 1
    if not no_flush then
        self:_reduce()
        self:_flush()
    end
    return true
end
-- Test helpers
function RH:open(file, t)
    local i = self:getIndexByFile(file)
    if i then table.remove(self.hist, i) end
    table.insert(self.hist, 1, { file = file, time = t or clock, text = file:gsub(".*/", ""),
                                  dim = false, select_enabled = true })
end
function RH:remove(file) table.remove(self.hist, assert(self:getIndexByFile(file))) end
function RH:timeOf(file)
    local i = self:getIndexByFile(file)
    return i and self.hist[i].time
end
function RH:entry(file) return self.hist[self:getIndexByFile(file) or 0] end
function RH:files()
    local out = {}
    for i, v in ipairs(self.hist) do out[i] = (v.file:gsub(".*/", ""):gsub("%.epub$", "")) end
    return table.concat(out, ",")
end

-- No collections: CollSync is only the MD5 finder here.
local RC = { coll = { favorites = {} }, coll_settings = { favorites = { order = 1 } } }
function RC._read() end
function RC.write() end

-- A simulated device ---------------------------------------------------------------------
local Dev = {}
Dev.__index = Dev
local function newDev(name)
    local dir = TMP .. "/" .. name
    S.mkdirp(dir .. "/books")
    local d = setmetatable({ name = name, dir = dir, scheduled = {}, idle = true, rh = newRH(),
                             uuid_of = {}, cloud = {}, open = nil }, Dev)
    d.store = BookStore.new{ sq3 = S.SQ3, state_path = dir .. "/state.sqlite3", md5 = digest }
    local common = {
        store = d.store, getDeviceId = function() return name end, now = function() return clock end,
        logger = quiet, enabled = function() return true end,
        schedule = function(_, fn) table.insert(d.scheduled, fn) end,
        lfs = lfs, realpath = function(p) return p end,
        idle = function() return d.idle end,
        refresh_ui = function(paths) d.refreshed = paths end,
    }
    local coll = {}
    for k, v in pairs(common) do coll[k] = v end
    coll.readcollection, coll.docsettings = RC, false
    coll.partial_md5 = function(path) return digest(S.readFile(path)) end
    d.finder = CollSync.new(coll)
    local hist = {}
    for k, v in pairs(common) do hist[k] = v end
    hist.finder, hist.readhistory = d.finder, d.rh
    hist.open_book = function() return d.open end
    hist.uuids = function(md5s)
        local out = {}
        for md5 in pairs(md5s) do if d.uuid_of[md5] then out[md5] = { d.uuid_of[md5] } end end
        return out
    end
    hist.resolve = function(uuids)
        for _, u in ipairs(uuids) do if d.cloud[u] then return d.cloud[u] end end
    end
    d.sync = HistSync.new(hist)
    return d
end
function Dev:run()
    while #self.scheduled > 0 do table.remove(self.scheduled, 1)() end
end
--- A book file; the same content is the same book (MD5) on every device.
-- Known to the sync (opened here before) unless `unknown`.
function Dev:book(name, content, unknown)
    local path = self.dir .. "/books/" .. name .. ".epub"
    S.writeFile(path, content or ("book " .. name))
    if not unknown then
        self.store:observe{ md5 = digest(S.readFile(path)), values = {}, now = clock, device = self.name, path = path }
    end
    return path
end
local seq = 0
function Dev:send(...)
    local out = self.dir .. "/out.jsonl"
    local exp = self.store:export{ device_id = self.name, out_path = out, now = clock, max_records = 1000 }
    if not exp then return 0 end
    seq = seq + 1
    local segname = BookFormat.segmentName(seq)
    self.store:markExported(out, self.name, segname, exp.size, nil, clock)
    for _, other in ipairs({ ... }) do
        local res, err = other.store:importSegment(out, self.name, segname, exp.size, nil, clock)
        check(res, "import into " .. other.name .. ": " .. tostring(err))
    end
    return exp.records
end
function Dev:before()
    self.sync:refresh(); self:run()
    return self.sync:observe()
end
function Dev:after()
    self.sync:afterSync(); self:run()
end
local function round(...)
    local devs = { ... }
    local sent = 0
    for _, d in ipairs(devs) do d:before() end
    for _, d in ipairs(devs) do
        local others = {}
        for _, o in ipairs(devs) do if o ~= d then others[#others + 1] = o end end
        sent = sent + d:send(unpack(others))
    end
    for _, d in ipairs(devs) do d:after() end
    return sent
end

-- Format -------------------------------------------------------------------------------------
do
    check(BookFormat.known("hist"), "hist is a known property")
    check(BookFormat.validValue("hist", 1800000000), "a time is a valid hist")
    check(not BookFormat.validValue("hist", "yesterday"), "a string isn't")
    check(not BookFormat.validValue("hist", 1.5), "nor a fraction")
    check(BookFormat.isGroupProp("hist"), "versions of a book share it")
end

-- Two histories merged ------------------------------------------------------------------------
local A, B = newDev("A"), newDev("B")
local a1, a2, a3 = A:book("one"), A:book("two"), A:book("three")
local b1, b2, b3 = B:book("one"), B:book("two"), B:book("three")
do
    A.rh:open(a1, clock); tick(10)
    B.rh:open(b2, clock); tick(10)
    A.rh:open(a3, clock); tick(10)
    local A_first = A.rh.hist[1]
    round(A, B)
    check(A.rh:files() == "three,two,one", "A has B's book in time order: " .. A.rh:files())
    -- ZenOS caches the "last read" order while hist[1] is the same table.
    check(A.rh.reloads == 1 and A.rh.hist[1] ~= A_first and A.rh.hist[1].file == A_first.file
        and A.rh.hist[1].time == A_first.time, "A's history read back after saving: new tables")
    check(A.refreshed and #A.refreshed == 1 and A.refreshed[1] == a2,
        "views refreshed for the book put into the history")
    check(B.rh:files() == "three,two,one", "B has A's books in time order: " .. B.rh:files())
    check(B.rh:timeOf(b1) == A.rh:timeOf(a1), "at the time it was read")
    check(B.rh:entry(b3).select_enabled and not B.rh:entry(b3).dim, "an ordinary entry")
    check(B.rh.added == 2 and B.rh:entry(b3).mandatory, "files go in through ReadHistory:addItem")
    local flushes = B.rh.flushes
    check(round(A, B) == 0, "nothing more to send")
    check(B.rh.flushes == flushes, "nothing written again")
end

-- Newer here wins; reopening moves it up everywhere ----------------------------------------
do
    B.rh:open(b1, clock); tick(10)
    round(A, B)
    check(A.rh:files() == "one,three,two", "reopened on B: top on A too: " .. A.rh:files())
    check(A.rh:timeOf(a1) == B.rh:timeOf(b1), "same time")
end

-- Removals stay where they're made -----------------------------------------------------------
do
    B.rh:remove(b2)
    round(A, B)
    check(B.rh:getIndexByFile(b2) == nil, "removed on B: not put back")
    check(A.rh:getIndexByFile(a2) ~= nil, "still on A")
    round(A, B)
    check(B.rh:getIndexByFile(b2) == nil, "still not put back")
    A.rh:open(a2, clock); tick(10)
    round(A, B)
    check(B.rh:files() == "two,one,three", "opened again on A: back on B, on top: " .. B.rh:files())
end

-- A book that isn't on the device: through Cloud library, or not at all ---------------------
do
    local a4 = A:book("four")
    local md5 = digest(S.readFile(a4))
    A.rh:open(a4, clock); tick(10)
    round(A, B)
    check(B.rh:files() == "two,one,three", "not on B, no cloud: not added")
    -- Cloud library loads its catalog: the book's cloud entry.
    B.uuid_of[md5] = "11111111-2222-3333-4444-555555555555"
    B.cloud["11111111-2222-3333-4444-555555555555"] = B.dir .. "/books/cloud-1111.epub"
    round(A, B)
    local e = B.rh:entry(B.dir .. "/books/cloud-1111.epub")
    check(e and B.rh.hist[1] == e, "cloud entry on top once found")
    check(e and e.time == A.rh:timeOf(a4), "at the time it was read")
    check(e and not e.dim and not e.select_enabled, "shown, but never reopened at startup")
    -- Downloaded: Cloud library now gives the file.
    local b4 = B:book("four", nil, true)
    B.cloud["11111111-2222-3333-4444-555555555555"] = b4
    B.rh:remove(B.dir .. "/books/cloud-1111.epub")
    round(A, B)
    check(B.rh:getIndexByFile(b4) == nil, "seen already: not added again by itself")
end

do
    A.rh:open(A:book("five"), clock); tick(10)
    local b5 = B:book("five", nil, true)
    round(A, B)
    check(B.rh:getIndexByFile(b5) == nil, "on B but never opened there, no cloud: not found")
end

-- The open book stays on top ---------------------------------------------------------------
do
    B.rh:open(b3, clock); tick(5)
    B.open = b3
    A.rh:open(a1, clock); tick(5)
    round(A, B)
    check(B.rh.hist[1].file == b3, "while B reads three, A's newer book waits: " .. B.rh:files())
    -- Closing: KOReader sets the top entry's time, then a sync.
    B.open = nil
    B.rh.hist[1].time = clock; tick(5)
    round(A, B)
    check(B.rh:files():sub(1, 9) == "three,one", "B's own book on top after closing: " .. B.rh:files())
    check(A.rh.hist[1].file == a3, "and on A")
end

-- Busy, then retried ----------------------------------------------------------------------
do
    A.rh:open(a2, clock); tick(10)
    A:before(); B:before()
    A:send(B); B:send(A)
    A:after()
    B.idle = false
    B.sync:afterSync()
    check(B.rh.hist[1].file ~= b2, "a menu is open: not yet")
    check(#B.scheduled == 1 and B.sync.retrying, "retry scheduled")
    B.idle = true
    B:run()
    check(B.rh.hist[1].file == b2, "applied on retry")
end

-- Versions of a book --------------------------------------------------------------------------
do
    local C, D = newDev("C"), newDev("D")
    local cv = C:book("v", "version one")
    local dv = D:book("v", "version two")
    local mc, md = digest(S.readFile(cv)), digest(S.readFile(dv))
    -- The identity groups (kept by idstore.lua) join the two files.
    for _, dev in ipairs({ C, D }) do
        local conn = S.SQ3.open(dev.dir .. "/state.sqlite3")
        dev.store:open():close() -- schema
        conn:exec(string.format("INSERT INTO id_groups (md5, grp) VALUES ('%s', '%s'), ('%s', '%s');",
            mc, mc < md and mc or md, md, mc < md and mc or md))
        conn:close()
    end
    D.rh:open(dv, clock - 100)
    C.rh:open(cv, clock); tick(10)
    round(C, D)
    check(D.rh.hist[1].file == dv and D.rh:timeOf(dv) == C.rh:timeOf(cv), "read as version one: version two moves up")
end

-- The size limit -------------------------------------------------------------------------------
do
    local E, F = newDev("E"), newDev("F")
    F.rh.size = 2
    for i = 1, 4 do
        E.rh:open(E:book("b" .. i), clock); tick(10)
        F:book("b" .. i)
    end
    round(E, F)
    check(F.rh:files() == "b4,b3", "only the newest that fit: " .. F.rh:files())
    local flushes = F.rh.flushes
    round(E, F)
    check(F.rh:files() == "b4,b3" and F.rh.flushes == flushes, "the ones that didn't fit aren't tried again")
end

-- Saved once; ZenOS's incognito mode: waits -----------------------------------------------------
do
    local G, H = newDev("G"), newDev("H")
    local g1, g2 = G:book("one"), G:book("two")
    local h1, h2 = H:book("one"), H:book("two")
    G.rh:open(g1, clock); tick(10)
    G.rh:open(g2, clock); tick(10)
    H.rh.incognito = true
    round(G, H)
    check(H.rh:files() == "", "incognito: not put into the history: " .. H.rh:files())
    H.rh.incognito = false
    local flushes = H.rh.flushes
    round(G, H)
    check(H.rh:files() == "two,one" and H.rh:timeOf(h1) == G.rh:timeOf(g1) and H.rh:timeOf(h2) == G.rh:timeOf(g2),
        "incognito off: put in at the next sync: " .. H.rh:files())
    check(H.rh.flushes == flushes + 1, "the history saved once")
end

S.finish("concordance history tests")
