-- Unit tests for Concordance's collections and favorites sync
-- (concordance/collsync.lua, with its records in concordance/bookstore.lua), with
-- KOReader's ReadCollection stood in for and book files as real files.
-- Run through scripts/test-concordance.sh, which sets KOREADER_SRC.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local BookFormat = require("concordance/bookformat")
local BookStore = require("concordance/bookstore")
local CollSync = require("concordance/collsync")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/coll"
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

-- KOReader's ReadCollection, enough of it -------------------------------------------------
local RC = {}
RC.__index = RC
local function newRC()
    return setmetatable({ coll = { favorites = {} }, coll_settings = { favorites = { order = 1 } }, writes = 0 }, RC)
end
function RC:_read() end
function RC:write() self.writes = self.writes + 1 end
function RC:addCollection(name)
    local max = 0
    for _, st in pairs(self.coll_settings) do if st.order > max then max = st.order end end
    self.coll_settings[name] = { order = max + 1 }
    self.coll[name] = {}
end
function RC:renameCollection(name, new)
    self.coll_settings[new], self.coll[new] = self.coll_settings[name], self.coll[name]
    self.coll_settings[name], self.coll[name] = nil, nil
end
function RC:removeCollection(name)
    self.coll_settings[name], self.coll[name] = nil, nil
end
function RC:addItem(file, name)
    assert(lfs.attributes(file, "mode") == "file", "addItem: no file " .. file)
    local max = 0
    for _, it in pairs(self.coll[name]) do if it.order > max then max = it.order end end
    self.coll[name][file] = { file = file, order = max + 1 }
end
-- Test helpers
function RC:put(name, file)
    if not self.coll[name] then self:addCollection(name) end
    self:addItem(file, name)
end
function RC:has(name, file) return self.coll[name] ~= nil and self.coll[name][file] ~= nil end
function RC:count(name)
    local n = 0
    for _ in pairs(self.coll[name] or {}) do n = n + 1 end
    return n
end

-- A simulated device ---------------------------------------------------------------------
local Dev = {}
Dev.__index = Dev
local nrandom = 0
local function newDev(name)
    local dir = TMP .. "/" .. name
    S.mkdirp(dir .. "/books")
    local d = setmetatable({ name = name, dir = dir, scheduled = {}, idle = true, rc = newRC(), refreshed = 0 }, Dev)
    d.store = BookStore.new{ sq3 = S.SQ3, state_path = dir .. "/state.sqlite3", md5 = digest }
    d.sync = CollSync.new{
        store = d.store, getDeviceId = function() return name end, now = function() return clock end,
        logger = quiet, enabled = function() return true end,
        schedule = function(_, fn) table.insert(d.scheduled, fn) end,
        readcollection = d.rc, docsettings = false, lfs = lfs,
        partial_md5 = function(path) return digest(S.readFile(path)) end,
        realpath = function(p) return p end,
        idle = function() return d.idle end,
        refresh_ui = function() d.refreshed = d.refreshed + 1 end,
        random_id = function() nrandom = nrandom + 1; return "r" .. nrandom end,
    }
    return d
end
function Dev:run()
    while #self.scheduled > 0 do table.remove(self.scheduled, 1)() end
end
--- A book file; the same content is the same book (MD5) on every device.
function Dev:book(name, sub)
    local path = self.dir .. "/books/" .. (sub and sub .. "-" or "") .. name .. ".epub"
    S.writeFile(path, "book " .. name)
    return path
end
--- The book was opened here (book data knows where it is).
function Dev:opened(path)
    self.store:observe{ md5 = digest(S.readFile(path)), values = {}, now = clock, device = self.name, path = path }
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
--- Before a sync (refresh, observe), then the sync, then after (apply).
function Dev:before()
    self.sync:refresh(); self:run()
    return self.sync:observe()
end
function Dev:after()
    self.sync:afterSync(); self:run()
end
local function round(...)
    local devs = { ... }
    for _, d in ipairs(devs) do d:before() end
    for _, d in ipairs(devs) do
        local others = {}
        for _, o in ipairs(devs) do if o ~= d then others[#others + 1] = o end end
        d:send(unpack(others))
    end
    for _, d in ipairs(devs) do d:after() end
end

-- Format ---------------------------------------------------------------------------------
do
    check(BookFormat.collId("coll.favorites") == "favorites" and not BookFormat.collId("coll.a b")
        and not BookFormat.collId("collx"), "collection IDs")
    check(BookFormat.validValue("coll.x", true) and BookFormat.validValue("coll.x", { name = "X" })
        and not BookFormat.validValue("coll.x", "yes") and not BookFormat.validValue("coll.x", { name = "" }),
        "collection values")
    check(BookFormat.known("coll.x") and BookFormat.isGroupProp("coll.x") and not BookFormat.CLOSED_PROPS["coll.x"],
        "memberships: applied, shared by versions, not sidecar writes")
    local f = TMP .. "/seg.jsonl"
    local function write(md5, v)
        S.writeFile(f, table.concat({ BookFormat.headerLine("d", 1), BookFormat.bookLine{ md5 = md5 },
            BookFormat.recordLine{ md5 = md5, prop = "coll.x", updated = 1, device = "d", value_json = v },
            BookFormat.trailerLine(1, 1) }, "\n") .. "\n")
        return BookFormat.readSegment(f)
    end
    check(write(string.rep("a", 32), "true") and write(BookFormat.COLLECTIONS, '{"name":"X"}'), "good records read")
    check(not write(string.rep("a", 32), '{"name":"X"}') and not write(BookFormat.COLLECTIONS, "true"),
        "a collection on a book, or a membership on the collections record, rejected")
end

-- Two devices: first sync, union, IDs ------------------------------------------------------
local a, b = newDev("a"), newDev("b")
local a1, a2, a3 = a:book("one"), a:book("two"), a:book("three")
local b1, b2, b3 = b:book("one", "elsewhere"), b:book("two", "elsewhere"), b:book("three", "elsewhere")
local b4 = b:book("four")
for _, p in ipairs({ a1, a2, a3, b1, b2, b3 }) do (p:find("/a/") and a or b):opened(p) end
do
    a.rc:put("favorites", a1)
    a.rc:put("Sci-fi", a2)
    b.rc:put("favorites", b4) -- B's own favourite from before syncing
    b.rc:put("Sci-fi", b3)    -- made on B too, before they synced
    round(a, b)
    check(a.rc.coll_settings.favorites.concordance_id == "favorites", "favorites has its fixed ID")
    check(a.rc.coll_settings["Sci-fi"].concordance_id == b.rc.coll_settings["Sci-fi"].concordance_id,
        "the same name on two devices is the same collection")
    check(b.rc:has("favorites", b1) and b.rc:has("favorites", b4), "B: A's favourite added, its own kept")
    check(b.rc:has("Sci-fi", b2) and b.rc:has("Sci-fi", b3), "B: Sci-fi has both")
    check(a.rc:has("favorites", a1) and a.rc:count("favorites") == 1, "A: B's favourite isn't on A: nothing to add")
    local b5 = b:book("five")
    a.rc:put("favorites", a:book("five"))
    a:before(); a:send(b); b:after()
    check(not b.rc:has("favorites", b5), "a book never opened on B isn't found there")
    check(a.rc:has("Sci-fi", a2) and a.rc:has("Sci-fi", a3), "A: Sci-fi has both")
    check(b.refreshed > 0, "file browser refreshed after changes")
    -- Nothing more to do
    tick(5)
    check(a:before() == 0 and b:before() == 0, "applied changes aren't taken for local ones")
    check(a:send(b) == 0 and b:send(a) == 0, "nothing to send")
    local conn = a.store:open()
    local all = tonumber(conn:rowexec("SELECT count(DISTINCT md5) FROM book_merged WHERE deleted = 0;"))
    conn:close()
    check(a.store:counts().books == all - 1, "counts don't include the collections record")
end

-- A book arriving later is put in its collections -----------------------------------------
do
    local a4 = a:book("four")
    a:opened(a4)
    a.sync:onBookOpened(digest(S.readFile(a4)))
    check(a.rc:has("favorites", a4), "a book opened for the first time goes into its collections")
end

-- Changes: take out, rename, add, remove a collection ----------------------------------------
do
    tick(10)
    b.rc.coll.favorites[b1] = nil
    b.rc:renameCollection("Sci-fi", "SF")
    b.rc:put("Classics", b4)
    round(a, b)
    check(not a.rc:has("favorites", a1), "taken out of favorites everywhere")
    check(a.rc.coll["Sci-fi"] == nil and a.rc:has("SF", a2) and a.rc:has("SF", a3), "rename keeps the books")
    check(a.rc:has("Classics", a:book("four")), "new collection and its book")
    tick(10)
    a.rc:removeCollection("Classics")
    round(a, b)
    check(b.rc.coll.Classics == nil, "removed collection removed everywhere")
    -- A collection of the same name made again later isn't removed.
    tick(10)
    b.rc:put("Classics", b2)
    round(a, b)
    check(a.rc:has("Classics", a2) and b.rc:has("Classics", b2), "a collection made again later stays")
end

-- A file gone from a device isn't a removal ---------------------------------------------------
do
    tick(10)
    os.remove(b3)
    b.rc.coll.SF[b3] = nil -- KOReader drops missing files
    round(a, b)
    check(a.rc:has("SF", a3), "B's missing file doesn't take the book out on A")
    S.writeFile(b3, "book three")
    tick(10)
    round(a, b)
    check(b.rc:has("SF", b3), "the file back: back in its collection")
end

-- Busy, then applied later ---------------------------------------------------------------------
do
    tick(10)
    a.rc:put("favorites", a3)
    a:before()
    a:send(b)
    b.idle = false
    local n, why = b.sync:apply()
    check(not n and why == "busy", "nothing applied while a menu is open")
    b.sync:afterSync()
    local fn = table.remove(b.scheduled, 1)
    check(fn ~= nil, "retry scheduled")
    b.idle = true
    fn()
    check(b.rc:has("favorites", b3), "applied when the menu closes")
end

-- Name clash: a rename to a name taken here by another collection ------------------------------
do
    tick(10)
    b.rc:put("Later", b1)       -- B's own, not synced yet
    a.rc:renameCollection("SF", "Later")
    a:before()
    a:send(b)
    b:after()
    check(b.rc.coll["Later (2)"] ~= nil and b.rc:has("Later (2)", b2) and b.rc:has("Later", b1),
        "the incoming one gets a free name; B's own keeps its name")
    b:before(); b:send(a); a:after()
    check(a.rc.coll["Later (2)"] ~= nil and a.rc.coll.Later ~= nil, "the free name and B's collection reach A")
    check(a.rc.coll_settings["Later (2)"].concordance_id ~= a.rc.coll_settings.Later.concordance_id, "two collections, two IDs")
end

-- Versions of a book share memberships ---------------------------------------------------------
do
    local c = newDev("c")
    local v1, v2 = c:book("ed1"), c:book("ed2")
    local m1, m2 = digest(S.readFile(v1)), digest(S.readFile(v2))
    c:opened(v1); c:opened(v2)
    local conn = c.store:open()
    conn:exec(string.format("INSERT INTO id_groups (md5, grp) VALUES ('%s', 'g'), ('%s', 'g');", m1, m2))
    conn:close()
    c.rc:put("favorites", v1)
    c:before()
    c.sync:apply()
    check(c.rc:has("favorites", v2), "the other version goes into the collection too")
end

-- A collection's ID under OmniSync's key: kept, under Concordance's.
do
    local st
    for name, cs in pairs(a.rc.coll_settings) do
        if name ~= "favorites" and a.rc.coll[name] and cs.concordance_id then st = cs end
    end
    local id = st and st.concordance_id
    check(id ~= nil, "a collection with an ID")
    if not st then st = {} end
    st.omnisync_id, st.concordance_id = id, nil
    a:before()
    check(st.concordance_id == id and st.omnisync_id == nil, "OmniSync's collection ID kept as Concordance's")
end

S.finish("concordance collection tests")
