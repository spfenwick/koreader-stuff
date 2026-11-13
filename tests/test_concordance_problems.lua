-- Unit tests for Concordance's problem reports (concordance/problems.lua) and
-- the places that report what's missing in KOReader or ZenOS.
-- Run through scripts/test-concordance.sh, which sets KOREADER_SRC.

local S = dofile("tests/concordance/support.lua")
local check = S.check

-- KOReader's UI, enough of it: messages shown, and ticks run by hand.
local shown, ticks = {}, {}
package.loaded["ui/uimanager"] = {
    nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
    show = function(_self, w) shown[#shown + 1] = w end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_self, o) return o end }
local function runTicks()
    while #ticks > 0 do table.remove(ticks, 1)() end
end

local Problems = require("concordance/problems")

-- Reporting and showing ------------------------------------------------------------------

do
    Problems.reset()
    Problems.disable()
    check(Problems.report("a", "Thing A failed", "boom"), "a new problem")
    check(not Problems.report("a", "Thing A failed", "boom again"), "the same one again isn't new")
    runTicks()
    check(#shown == 0, "nothing shown before enable()")
    Problems.enable()
    runTicks()
    check(#shown == 1 and shown[1].text:find("Thing A failed: boom again", 1, true),
        "shown once enabled, with the latest detail: " .. tostring(shown[1] and shown[1].text))
    Problems.report("b", "Thing B is missing")
    Problems.report("c", "Thing C failed", "line one\nline two")
    runTicks()
    check(#shown == 2, "problems found together: one message")
    check(shown[2].text:find("Thing B is missing", 1, true) and shown[2].text:find("Thing C failed: line one", 1, true)
        and not shown[2].text:find("line two", 1, true), "both in it, first line of each detail")
    check(not shown[2].text:find("Thing A", 1, true), "not the one already shown")
    Problems.report("a", "Thing A failed", "once more")
    runTicks()
    check(#shown == 2, "never shown twice in a session")
    local lines = Problems.statusLines()
    check(#lines == 3 and lines[1] == "Thing A failed: once more (×3)", "Status lists them all: " .. tostring(lines[1]))
    Problems.disable()
end

-- A check and the code using what it checks: one problem -----------------------------------

do
    Problems.reset()
    Problems.enable()
    shown = {}
    Problems.requires("ReadHistory", { addItem = function() end }, { addItem = 4, _flush = 1 })
    Problems.report("check:ReadHistory._flush", "Books read elsewhere can't be saved into the history", "ReadHistory:_flush is missing")
    runTicks()
    check(#shown == 1, "found together: one message: " .. #shown)
    Problems.report("check:ReadHistory._flush", "Books read elsewhere can't be saved into the history", "again")
    runTicks()
    check(#shown == 1, "used later: no second message")
    local lines = Problems.statusLines()
    local flush_line
    for _, l in ipairs(lines) do
        if l:find("_flush", 1, true) or l:find("^Books read elsewhere can't be saved") then flush_line = l end
    end
    check(#lines == 2 and flush_line and flush_line:find("^Books read elsewhere can't be saved") and flush_line:find("(×3)", 1, true),
        "Status says what stops working, once: " .. table.concat(lines, " | "))
    -- The other way round: the code first, then a check finds it.
    Problems.report("check:Mod.f", "Thing F stops working", "f is missing")
    Problems.requires("Mod", {}, { f = true })
    check(Problems.list["check:Mod.f"].text == "Thing F stops working" and Problems.list["check:Mod.f"].detail == "f is missing",
        "a check doesn't replace what the code said")
    runTicks()
    check(#shown == 2, "the new problem shown once")
    Problems.disable()
end

-- Checking what's relied on ----------------------------------------------------------------

do
    Problems.reset()
    local mod = {
        ok = function(_self, _a) end,
        short = function(_self) end,
        any = function(...) end,
        list = {},
    }
    local n = Problems.requires("Mod", mod, { ok = 2, short = 2, any = 5, gone = true },
        { list = "table", count = "number" })
    check(n == 3, "three problems: " .. n)
    check(Problems.has("check:Mod.short") and Problems.has("check:Mod.gone") and Problems.has("check:Mod.count"),
        "fewer parameters, a missing function, a missing field")
    check(not Problems.has("check:Mod.ok") and not Problems.has("check:Mod.any"), "matching and vararg ones fine")
    check(Problems.requires("Gone", "can't be loaded: x") == 1 and Problems.has("check:Gone"), "a module that won't load")
end

-- Where it's used ---------------------------------------------------------------------------

do
    Problems.reset()
    local quiet = { info = function() end, warn = function() end, dbg = function() end }
    local HistSync = require("concordance/histsync")
    local h = HistSync.new{
        store = { observeMany = function() return {} end, history = function() return { x = { hash = 1, seen = 2, group = {} } } end },
        finder = { md5s = function() return {} end, paths = function() return {} end, findMd5s = function() end },
        getDeviceId = function() return "d" end, now = os.time, logger = quiet,
        schedule = function() end, enabled = function() return true end,
        readhistory = { reload = function() end }, idle = function() return true end,
    }
    local n, why = h:apply(true)
    check(n == nil and why == "no history" and Problems.has("check:ReadHistory.hist"), "no ReadHistory.hist: reported, nothing done")

    local CollSync = require("concordance/collsync")
    local c = CollSync.new{
        store = {}, getDeviceId = function() return "d" end, now = os.time, logger = quiet,
        schedule = function() end, enabled = function() return true end,
        readcollection = { write = function() end }, docsettings = false,
    }
    check(c:observe() == 0 and Problems.has("check:ReadCollection.coll"), "no ReadCollection.coll: reported, nothing done")
    check(Problems.has("check:ReadCollection._read"), "no ReadCollection:_read: reported")

    local ProgressHook = require("concordance/progresshook")
    check(ProgressHook.oddBody({}) == nil and ProgressHook.oddBody({ message = "none" }) == nil,
        "nothing stored isn't odd")
    check(ProgressHook.oddBody({ progress = "/x", timestamp = 1 }), "a position without a percentage is")
    check(ProgressHook.oddBody({ percentage = "lots" }), "a percentage that isn't a number is")
    Problems.reset()
    local Client = { get_progress = function(_self, _u, _k, doc, cb)
        if doc == "own" then return cb(true, { percentage = 0.1, timestamp = 1 }) end
        cb(true, { pct = 0.5, progress = "/y", timestamp = 2 })
    end }
    local queue = {}
    ProgressHook.install(Client, { peers = function() return { "peer" } end,
        schedule = function(fn) queue[#queue + 1] = fn end })
    local got
    Client:get_progress("u", "k", "own", function(_ok, body) got = body end)
    while #queue > 0 do table.remove(queue, 1)() end
    check(got and got.percentage == 0.1 and Problems.has("progress:shape"),
        "another version's answer changed shape: reported, own position kept")

    Problems.reset()
    local Store = require("concordance/store")
    local dir = assert(os.getenv("STATSYNC_TMP")) .. "/problems"
    S.rmrf(dir)
    S.mkdirp(dir)
    local d = S.newDevice("P", dir .. "/dev")
    local c2 = S.SQ3.open(d.db)
    c2:exec("PRAGMA user_version=20991231;")
    c2:close()
    local st = Store.new{ sq3 = S.SQ3, stats_path = d.db, state_path = d.state }
    check(st:openStats() == nil and Problems.has("stats-schema"), "an unknown statistics schema is reported")
end

S.finish("concordance problem report tests")
