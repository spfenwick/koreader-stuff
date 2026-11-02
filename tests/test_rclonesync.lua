-- Exercises rclonesync.koplugin: the sync module with a real rclone (a
-- "local" remote standing in for the cloud) and two simulated devices, and
-- the plugin's push/pull flow against stubbed KOReader modules.
--
-- Needs rclone on the PATH and LuaFileSystem; skipped without them.

package.path = "rclonesync.koplugin/?.lua;" .. package.path

local function sh(cmd)
    local pipe = io.popen(cmd)
    local out = pipe:read("*a")
    pipe:close()
    return out
end

local have_lfs, lfs = pcall(require, "lfs")
if not have_lfs or sh("command -v rclone") == "" then
    print("rclonesync: skipped (needs rclone and LuaFileSystem)")
    return
end

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function write(path, data)
    os.execute("mkdir -p " .. q(path:match("^(.*)/[^/]+$")))
    local f = assert(io.open(path, "w"))
    f:write(data)
    f:close()
end
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end
local function exists(path) return lfs.attributes(path) ~= nil end

-- A space and a quote, to check the quoting.
local base = sh("mktemp -d"):gsub("%s+$", "") .. "/it's here"
os.execute("mkdir -p " .. q(base))
local cloud = base .. "/cloud"

-- Two devices: koreader/ and rclone/ side by side, as on a Kobo.
local function device(name)
    local d = { kodir = base .. "/" .. name .. "/koreader", rclone_dir = base .. "/" .. name .. "/rclone" }
    write(d.rclone_dir .. "/rclone.conf", "[Local]\ntype = local\n\n[Other]\ntype = local\n")
    os.execute("ln -s \"$(command -v rclone)\" " .. q(d.rclone_dir .. "/rclone"))
    return d
end
local A, B = device("a"), device("b")

local current = A
package.loaded["libs/libkoreader-lfs"] = lfs
package.loaded["datastorage"] = { getDataDir = function() return current.kodir end }

local Sync = require("rclonesync_sync")
local opts = { remote = "Local", root = cloud .. "/KOReader/Settings" }

local function run(ctx, direction, tweaks)
    local out = sh(Sync.script(ctx, direction, tweaks))
    return Sync.parse(out, direction), out
end

-- Quoting
check(Sync.quote("it's") == [['it'\''s']], "quote")

-- Device A's files
write(A.rclone_dir .. "/settings.txt", "/gestures.lua\n/ZenOS/**\n")
write(A.rclone_dir .. "/patches.txt", "/2-mine.lua\n")
-- Outside settings/: not synced, even if named like a listed file.
write(A.kodir .. "/gestures.lua", "-- not a setting\n")
write(A.kodir .. "/settings/gestures.lua", "return { a = 1 }\n")
write(A.kodir .. "/settings/ZenOS/config.lua", "return {}\n")
write(A.kodir .. "/settings/unlisted.lua", "return {}\n")
write(A.kodir .. "/patches/2-mine.lua", "-- mine\n")
write(A.kodir .. "/patches/1-knuthplass-engine.lua", "-- device A's\n")
write(A.kodir .. "/patches/2-a-only.lua", "-- unlisted\n")
write(A.kodir .. "/fonts/a.ttf", "font a\n")
write(A.kodir .. "/data/dict/d.ifo", "dict\n")
write(A.kodir .. "/icons/i.svg", "<svg/>\n")
write(A.rclone_dir .. "/plugins.txt", "/shared.koplugin/**\n")
write(A.kodir .. "/plugins/shared.koplugin/main.lua", "-- shared\n")
write(A.kodir .. "/plugins/big.koplugin/main.lua", "-- big\n")
write(A.kodir .. "/styletweaks/t.css", "p {}\n")

-- Context
current = A
local ctx = assert(Sync.context(opts))
check(ctx.rclone_dir == A.rclone_dir, "rclone folder found next to koreader/")
check(ctx.binary == A.rclone_dir .. "/rclone", "rclone in the rclone folder")
check(ctx.config == A.rclone_dir .. "/rclone.conf", "rclone.conf")
local remotes = Sync.remotes(ctx)
check(#remotes == 2 and remotes[1] == "Local" and remotes[2] == "Other", "remotes from rclone.conf")
check(assert(Sync.context({ root = opts.root })).remote == "Local", "first remote by default")

-- Jobs
local names = {}
for _, j in ipairs(Sync.jobs("push", false)) do table.insert(names, j.name) end
check(table.concat(names, ",") == "list,settings,plugins,patches,dict,styletweaks", "push skips fonts")
names = {}
for _, j in ipairs(Sync.jobs("pull", true)) do table.insert(names, j.name) end
check(table.concat(names, ",") == "list,styletweaks", "tweaks only")

-- Push from A
local result, out = run(ctx, "push", false)
local remote = cloud .. "/KOReader/Settings"
check(not result.failed, "push succeeds\n" .. out)
check(result.changes > 0, "push copies files")
check(read(remote .. "/settings/gestures.lua") == "return { a = 1 }\n", "listed setting pushed, rooted at settings/")
check(exists(remote .. "/settings/ZenOS/config.lua"), "listed folder pushed")
check(not exists(remote .. "/settings/unlisted.lua"), "unlisted setting not pushed")
check(not exists(remote .. "/settings/settings"), "no nested settings/")
check(exists(remote .. "/patches/2-mine.lua"), "listed patch pushed")
check(not exists(remote .. "/patches/2-a-only.lua"), "unlisted patch not pushed")
check(not exists(remote .. "/patches/1-knuthplass-engine.lua"), "Knuth–Plass patch not pushed")
check(exists(remote .. "/rclone/patches.txt"), "patch list pushed")
check(not exists(remote .. "/fonts"), "fonts not pushed")
check(exists(remote .. "/rclone/settings.txt"), "list pushed")
check(exists(remote .. "/dict/d.ifo"), "dict pushed")
check(not exists(remote .. "/icons"), "icons not synced")
check(exists(remote .. "/rclone/plugins.txt"), "plugin list pushed")
check(exists(remote .. "/plugins/shared.koplugin/main.lua"), "listed plugin pushed")
check(not exists(remote .. "/plugins/big.koplugin"), "unlisted plugin not pushed")

-- Fonts only ever go down: put some on the remote.
write(remote .. "/fonts/shared.ttf", "shared\n")

-- Pull to B, which has its own Knuth–Plass patch, a font of its own and no list yet.
current = B
write(B.kodir .. "/patches/1-knuthplass-engine.lua", "-- device B's\n")
write(B.kodir .. "/patches/2-b-only.lua", "-- B's\n")
write(B.kodir .. "/settings/gestures.lua", "return { b = 2 }\n")
write(B.kodir .. "/plugins/own.koplugin/main.lua", "-- B's own\n")
local bctx = assert(Sync.context(opts))
check(not Sync.isPending(bctx), "nothing pending at first")
result, out = run(bctx, "pull", false)
check(not result.failed, "pull succeeds\n" .. out)
check(exists(B.rclone_dir .. "/settings.txt"), "list pulled first")
check(result.jobs.settings and result.jobs.settings.differ, "settings differ")
check(result.pending and result.restart, "pull wants a restart")
check(read(B.kodir .. "/settings/gestures.lua") == "return { b = 2 }\n", "settings staged, not in place")
check(exists(B.kodir .. "/fonts/shared.ttf"), "fonts pulled")
check(read(B.kodir .. "/patches/1-knuthplass-engine.lua") == "-- device B's\n", "own Knuth–Plass patch kept")
check(exists(B.kodir .. "/patches/2-mine.lua"), "listed patch pulled")
check(exists(B.kodir .. "/patches/2-b-only.lua"), "B's unlisted patch kept")
check(not exists(B.kodir .. "/patches/2-a-only.lua"), "A's unlisted patch not pulled")
check(exists(B.rclone_dir .. "/plugins.txt"), "plugin list pulled")
check(read(B.kodir .. "/plugins/shared.koplugin/main.lua") == "-- shared\n", "listed plugin pulled")
check(read(B.kodir .. "/plugins/own.koplugin/main.lua") == "-- B's own\n", "unlisted plugin kept")
check(not exists(B.kodir .. "/icons"), "icons not pulled")

-- Put the staged settings in place, as at the next start.
Sync.setPending(bctx)
check(Sync.isPending(bctx), "pending")
local ok, apply_out = Sync.applyPending(bctx)
check(ok, "apply succeeds\n" .. apply_out)
check(not Sync.isPending(bctx), "not pending once applied")
check(read(B.kodir .. "/settings/gestures.lua") == "return { a = 1 }\n", "settings in place")
check(exists(B.kodir .. "/settings/ZenOS/config.lua"), "listed folder in place")

-- A settings file deleted on A goes from B too; files not listed stay.
write(B.kodir .. "/settings/unlisted.lua", "return {}\n")
current = A
os.remove(A.kodir .. "/settings/ZenOS/config.lua")
write(A.kodir .. "/settings/ZenOS/home.lua", "return {}\n")
check(not run(ctx, "push", false).failed, "push the deletion")
current = B
result = run(bctx, "pull", false)
check(result.pending, "deletion pulled")
check(Sync.applyPending(bctx), "deletion applied")
check(not exists(B.kodir .. "/settings/ZenOS/config.lua"), "deleted file removed")
check(exists(B.kodir .. "/settings/ZenOS/home.lua"), "new file in place")
check(exists(B.kodir .. "/settings/unlisted.lua"), "unlisted file kept")
check(exists(Sync.stagingDir(bctx) .. "/ZenOS/home.lua"), "staging kept")

-- Pulling again: nothing to do.
result, out = run(bctx, "pull", false)
check(not result.failed and result.changes == 0 and not result.pending and not result.restart,
    "second pull does nothing\n" .. out)

-- A font installed on B alone stays on B, and doesn't reach the remote.
write(B.kodir .. "/fonts/b-only.ttf", "b\n")
result = run(bctx, "push", false)
check(not result.failed, "push from B")
check(not exists(remote .. "/fonts/b-only.ttf"), "B's font not pushed")
write(remote .. "/fonts/shared.ttf", "shared, updated\n")
result = run(bctx, "pull", false)
check(not result.failed, "pull to B")
check(exists(B.kodir .. "/fonts/b-only.ttf"), "B's own font kept by a pull")
check(read(B.kodir .. "/fonts/shared.ttf") == "shared, updated\n", "changed font updated")
os.remove(remote .. "/fonts/shared.ttf")
run(bctx, "pull", false)
check(exists(B.kodir .. "/fonts/shared.ttf"), "font deleted from the remote kept on the device")

-- Dry run: reports, changes nothing.
write(B.kodir .. "/styletweaks/t.css", "p { margin: 0 }\n")
bctx.dry_run = true
result, out = run(bctx, "push", true)
check(not result.failed and result.changes == 1, "dry run counts the change\n" .. out)
check(read(remote .. "/styletweaks/t.css") == "p {}\n", "dry run changes nothing")
bctx.dry_run = false

-- A missing folder is skipped on push, not mirrored as empty.
os.execute("rm -rf " .. q(B.kodir .. "/data/dict"))
result, out = run(bctx, "push", false)
check(result.jobs.dict.skipped == "no folder", "missing folder skipped\n" .. out)
check(exists(remote .. "/dict/d.ifo"), "remote dict kept")

-- No plugins.txt: plugins skipped, the rest still runs.
local D = device("d")
current = D
write(D.rclone_dir .. "/settings.txt", "/gestures.lua\n")
write(D.kodir .. "/settings/gestures.lua", "return {}\n")
local dctx = assert(Sync.context({ remote = "Local", root = cloud .. "/other" }))
result, out = run(dctx, "push", false)
check(not result.failed and result.jobs.plugins.skipped == "no plugins.txt", "no plugin list: skipped\n" .. out)
check(exists(cloud .. "/other/settings/gestures.lua"), "settings still pushed")
check(result.jobs.patches.skipped == "no patches.txt", "no patch list: skipped")
current = B

-- A failing remote is reported.
local bad = assert(Sync.context({ remote = "Missing", root = opts.root }))
result = run(bad, "push", true)
check(result.failed and result.jobs.list.failed, "failure reported")

-- The plugin ---------------------------------------------------------------

local shown, notified, restarts, flushed, broadcast = {}, {}, {}, 0, {}
local saved = {}
_G.G_reader_settings = {
    readSetting = function(_, key) return saved[key] end,
    saveSetting = function(_, key, value) saved[key] = value end,
    flush = function() flushed = flushed + 1 end,
}
local function stub(name, value) package.loaded[name] = value end
stub("dispatcher", { registerAction = function() end })
stub("ui/event", { new = function(_, name) return { name = name } end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/textviewer", { new = function(_, o) o.viewer = true return o end })
stub("ui/network/manager", { runWhenOnline = function(_, fn) fn() end })
stub("ui/widget/notification", { notify = function(_, text) table.insert(notified, text) end })
stub("ui/trapper", {
    wrap = function(_, fn) fn() end,
    dismissablePopen = function(_, cmd) return true, sh(cmd) end,
})
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    nextTick = function(_, fn) fn() end,
    broadcastEvent = function(_, ev) table.insert(broadcast, ev.name) end,
    askForRestart = function(_, text) table.insert(restarts, text) end,
})
local WidgetContainer = {}
function WidgetContainer:extend(o) return setmetatable(o or {}, { __index = self }) end
function WidgetContainer:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
})

local function loadPlugin()
    return dofile("rclonesync.koplugin/main.lua")
end

-- A third device pulls through the plugin.
local C = device("c")
current = C
write(C.kodir .. "/settings/gestures.lua", "return { c = 3 }\n")
saved.rclonesync = { remote = "Local", root = opts.root }
local Plugin = loadPlugin()
local plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
local menu_items = {}
plugin:addToMainMenu(menu_items)
check(#menu_items.rclonesync.sub_item_table_func() >= 8, "menu")

plugin:onRcloneSyncPull()
local cctx = assert(Sync.context(saved.rclonesync))
check(Sync.isPending(cctx), "plugin pull leaves settings pending")
check(#restarts == 1, "plugin pull asks to restart")
check(read(C.kodir .. "/settings/gestures.lua") == "return { c = 3 }\n", "not in place before restart")
local discard_shown = false
for _, item in ipairs(plugin:menu()) do
    if item.text and item.text:find("^Discard") then discard_shown = true end
end
check(discard_shown, "menu offers to discard pending settings")

-- Pushing now would undo the pull.
plugin:onRcloneSyncPush()
check(#restarts == 2 and #broadcast == 0, "push refused while pending")

-- The next start puts them in place.
Plugin = loadPlugin()
plugin = Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
check(read(C.kodir .. "/settings/gestures.lua") == "return { a = 1 }\n", "applied at start")
check(not Sync.isPending(cctx), "nothing pending after start")
check(notified[#notified] == "Pulled settings applied.", "start reports it")

-- Push saves settings first.
plugin:onRcloneSyncPush()
check(broadcast[1] == "FlushSettings" and flushed == 1, "push flushes settings")
check(notified[#notified] == "Already up to date.", "push reports nothing to do: " .. tostring(notified[#notified]))

-- A failure shows the log.
saved.rclonesync.remote = "Missing"
plugin:onRcloneSyncPullTweaks()
check(shown[#shown] and shown[#shown].viewer and shown[#shown].title == "Sync failed", "failure shows log")

os.execute("rm -rf " .. q(base:match("^(.*)/[^/]+$")))
print(string.format("rclonesync: %d checks, %d failures", count, failures))
if failures > 0 then os.exit(1) end
