-- Tests the updater the plugins share (shared/updatecore.lua): that every
-- plugin's copy matches it, versions, zip paths, release information, and
-- the check flow with the network faked. KOReader's modules are stubbed.

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

-- Copies ----------------------------------------------------------------------

local canonical = read("shared/updatecore.lua")
for _, copy in ipairs({
    "knuthplass.koplugin/knuthplass_updatecore.lua",
    "omnisync.koplugin/omnisync/updatecore.lua",
}) do
    check(read(copy) == canonical, copy .. " differs from shared/updatecore.lua (run scripts/sync-updatecore.sh)")
end

-- Every plugin has a release version.
local function stub(name, value) package.loaded[name] = value end
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
for _, name in ipairs({ "knuthplass", "omnisync" }) do
    local meta = dofile(name .. ".koplugin/_meta.lua")
    check(type(meta.version) == "string" and meta.version:match("^%d+%.%d+%.%d+$"), name .. " _meta.lua version")
end

-- Stubs -------------------------------------------------------------------------

local shown, scheduled, restarts, online = {}, {}, {}, false
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
})
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    close = function() end,
    forceRePaint = function() end,
    scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end,
    askForRestart = function(_, text) table.insert(restarts, text) end,
})
stub("ui/widget/infomessage", { new = function(_, o) o.kind = "info"; return o end })
stub("ui/widget/confirmbox", { new = function(_, o) o.kind = "confirm"; return o end })
stub("ui/network/manager", {
    runWhenOnline = function(_, fn) fn() end,
    isWifiOn = function() return online end,
    isConnected = function() return online end,
    isOnline = function() return online end,
})
local store = {}
G_reader_settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
}

local UpdateCore = dofile("shared/updatecore.lua")

-- Versions, paths, release information ------------------------------------------

check(UpdateCore.parseVersion("v1.2.3")[3] == 3 and UpdateCore.parseVersion("1.2") == nil, "parseVersion")
check(UpdateCore.isNewer("0.10.0", "0.9.9") and not UpdateCore.isNewer("0.1.0", "0.1.0")
    and not UpdateCore.isNewer("junk", "0.1.0"), "isNewer")

local U = UpdateCore.new{ name = "omnisync", title = "OmniSync", settings_key = "omnisync_updates" }
check(U.release_tag == "omnisync" and U.folder == "omnisync.koplugin", "release tag and folder from the name")
check(U.entryPath("omnisync.koplugin/main.lua") == "main.lua", "entry in the plugin folder")
check(U.entryPath("omnisync.koplugin/omnisync/store.lua") == "omnisync/store.lua", "entry in a subfolder")
check(U.entryPath("knuthplass.koplugin/main.lua") == nil, "another plugin's folder rejected")
check(U.entryPath("omnisync.koplugin/") == nil and U.entryPath("main.lua") == nil, "no file / no folder rejected")
check(U.entryPath("omnisync.koplugin/../evil.lua") == nil and U.entryPath("omnisync.koplugin/a/../../x") == nil,
    "path traversal rejected")

local good = { version = "1.0.0", url = "https://example.com/x.zip", sha256 = string.rep("a", 64) }
check(UpdateCore.validManifest(good) == good, "valid release information")
check(not UpdateCore.validManifest({ version = "1.0", url = good.url, sha256 = good.sha256 }), "bad version rejected")
check(not UpdateCore.validManifest({ version = "1.0.0", url = "http://x/x.zip", sha256 = good.sha256 }), "http rejected")
check(not UpdateCore.validManifest({ version = "1.0.0", url = good.url, sha256 = "abc" }), "short checksum rejected")

-- Settings and menu -------------------------------------------------------------

check(U.getMode() == "notify", "notify by default")
U.setMode("bogus")
check(U.getMode() == "notify", "unknown mode ignored")
local plugin = { version = "0.1.0", path = "/plugins/omnisync.koplugin" }
local items = U.menuItems(plugin)
check(items[1].text == "Check for updates (0.1.0)" and items[1].enabled_func(), "check item")
check(items[2].text_func() == "Automatic updates: notify", "mode item")
items[2].sub_item_table[3].callback()
check(U.getMode() == "install" and store.omnisync_updates.mode == "install", "mode saved under the plugin's key")
check(not U.menuItems({ version = "0.1.0" })[1].enabled_func(), "no path (not loaded by KOReader): can't update")

-- Each plugin's updater is separate.
local K = UpdateCore.new{ name = "knuthplass", title = "K", settings_key = "knuthplass_updates" }
check(K.getMode() == "notify", "another plugin's mode is its own")

-- Scheduled check ----------------------------------------------------------------

U.scheduleCheck({ version = "0.1.0" })
check(#scheduled == 0, "nothing scheduled without a path")
U.scheduleCheck(plugin)
U.scheduleCheck(plugin)
check(#scheduled == 1, "one automatic check per session")

-- Check flow (network faked) ------------------------------------------------------

local manifest_calls, downloads = 0, {}
local release = { version = "0.2.0", url = good.url, sha256 = good.sha256 }
U.fetchManifest = function() manifest_calls = manifest_calls + 1; return release end
U.fetch = function(url) table.insert(downloads, url); return "zipdata" end
U.install = function(path, m, data) return path == plugin.path and m == release and data == "zipdata" end

online = false
scheduled[1].fn()
check(manifest_calls == 0, "automatic check while offline: no network")

online = true
U.setMode("off")
U.check(plugin, false)
check(manifest_calls == 0, "automatic updates off: no network")

U.setMode("notify")
U.check(plugin, false)
check(manifest_calls == 1 and shown[#shown].kind == "confirm" and shown[#shown].text:find("0.2.0"),
    "notify: offers the new version")
U.check(plugin, false)
check(manifest_calls == 1, "automatic check at most once a day")

store.omnisync_updates.last_check = nil
U.setMode("install")
U.check(plugin, false)
check(#downloads == 1 and U.installed == "0.2.0" and #restarts == 1, "install: downloaded, installed, restart asked")
local n = #shown
U.check(plugin, true)
check(#shown == n + 1 and shown[#shown].text:find("after KOReader restarts"), "installed update waits for a restart")

-- Up to date: the plugin's extra check runs and adds to the report.
local extra = {}
local E = UpdateCore.new{ name = "knuthplass", title = "K", settings_key = "k2",
    after_check = function(_, interactive, mode, fetch, report)
        table.insert(extra, { interactive, mode, type(fetch) })
        table.insert(report, "Engine: fine.")
    end }
E.fetchManifest = function() return { version = "0.1.0", url = good.url, sha256 = good.sha256 } end
E.check(plugin, true)
check(extra[1] and extra[1][1] == true and extra[1][2] == "notify" and extra[1][3] == "function", "after_check called")
check(shown[#shown].text:find("up to date") and shown[#shown].text:find("Engine: fine."), "report includes both")

-- Failed check is reported, not thrown
E.fetchManifest = function() return nil, "no route" end
E.check(plugin, true)
check(shown[#shown].text:find("could not check %(no route%)"), "failed check reported")

print(string.format("updatecore: %d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
