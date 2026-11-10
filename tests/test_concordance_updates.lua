-- Unit tests for Concordance's combined updates (concordance.koplugin/concordance/updates.lua)
-- and Cloud library's updater handing its checks to it. KOReader's UI is
-- stubbed; the updaters are the real shared updater with the network and
-- install steps stood in for. Run through scripts/test-concordance.sh.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local shown, restarts, online = {}, {}, true
local scheduled = {}
local function stub(name, value) package.loaded[name] = value end
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ffi/util", { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end })
stub("ui/uimanager", {
    show = function(_, w) shown[#shown + 1] = w end,
    close = function(_, w) w.closed = true end,
    forceRePaint = function() end,
    askForRestart = function(_, text) restarts[#restarts + 1] = text end,
    scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = fn end,
})
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/confirmbox", { new = function(_, o) o.confirm = true return o end })
stub("ui/network/manager", {
    runWhenOnline = function(_, cb) cb() end,
    isWifiOn = function() return online end,
    isConnected = function() return online end,
    isOnline = function() return online end,
})
-- Cloud library's settings: a LuaSettings-like store.
local cl_data = {}
stub("cloudlibrary/settings", {
    UPDATES_KEY = "updates",
    store = function()
        return { readSetting = function(_, k) return cl_data[k] end,
                 saveSetting = function(_, k, v) cl_data[k] = v end, flush = function() end }
    end,
})
local reader_data = {}
_G.G_reader_settings = {
    readSetting = function(_, k) return reader_data[k] end,
    saveSetting = function(_, k, v) reader_data[k] = v end,
}
package.path = "cloudlibrary.koplugin/?.lua;" .. package.path

local Updates = require("concordance/updates")
local OS = require("concordance/updatecore").new{ name = "concordance", title = "Concordance",
    settings_key = "concordance_updates", log_prefix = "Concordance:" }
local CL = require("cloudlibrary/updater")

-- The network and the install, stood in for.
local releases, fetches, installs, broken = {}, {}, {}, {}
for _, U in ipairs{ OS, CL } do
    U.fetchManifest = function()
        fetches[#fetches + 1] = U.name
        if broken[U.name] == "check" then return nil, "timeout" end
        return { version = releases[U.name], url = "https://x/" .. U.name .. ".zip", sha256 = string.rep("0", 64) }
    end
    U.fetch = function(url)
        if broken[U.name] == "download" then return nil, "404" end
        return "zip:" .. url
    end
    U.install = function(path, manifest)
        installs[#installs + 1] = U.name .. " " .. manifest.version
        return true
    end
end

local os_plugin = { path = "/p/concordance.koplugin", version = "0.7.0" }
local cl_plugin = { path = "/p/cloudlibrary.koplugin", version = "0.2.3" }
local with_cl = true
Updates.register(function()
    local e = { { updater = OS, plugin = os_plugin } }
    if with_cl then e[2] = { updater = CL, plugin = cl_plugin, own_automatic = not CL.defers_to_concordance } end
    return e
end)

local function reset()
    shown, restarts, fetches, installs, broken = {}, {}, {}, {}, {}
    OS.installed, CL.installed = nil, nil
    reader_data, cl_data = {}, {}
end
local function last() return shown[#shown] end
local function has(text, sub) return text and text:find(sub, 1, true) ~= nil end

-- Interactive -----------------------------------------------------------------------------

do
    reset()
    releases = { concordance = "0.7.0", cloudlibrary = "0.2.3" }
    Updates.check(true)
    local w = last()
    check(w and not w.confirm and has(w.text, "Concordance: up to date (0.7.0)")
        and has(w.text, "Cloud library: up to date (0.2.3)"), "both up to date: one message listing both")
    check(#fetches == 2 and shown[1].text == "Checking for updates…" and shown[1].closed, "one check, both plugins")

    reset()
    releases = { concordance = "0.7.1", cloudlibrary = "0.2.4" }
    Updates.check(true)
    w = last()
    check(w.confirm and w.ok_text == "Install all" and not w.other_buttons
        and has(w.text, "Concordance: 0.7.1 available (installed: 0.7.0)")
        and has(w.text, "Cloud library: 0.2.4 available (installed: 0.2.3)"), "both newer: one dialog, Install all")
    w.ok_callback()
    check(table.concat(installs, ",") == "concordance 0.7.1,cloudlibrary 0.2.4", "both installed")
    check(#restarts == 1 and has(restarts[1], "Concordance 0.7.1, Cloud library 0.2.4"), "one restart prompt for both")
    check(OS.installed == "0.7.1" and CL.installed == "0.2.4", "each updater knows its update is waiting")
    restarts = {}
    Updates.check(true)
    check(not last().confirm and has(last().text, "Concordance: 0.7.1 installed, used after KOReader restarts"),
        "after installing: waiting for a restart")

    reset()
    releases = { concordance = "0.7.0", cloudlibrary = "0.2.4" }
    broken = { concordance = "check" }
    Updates.check(true)
    w = last()
    check(w.confirm and w.ok_text == "Install" and has(w.text, "Concordance: couldn't check (timeout)"),
        "one newer, one failed: the failure listed in the dialog")
    w.cancel_callback()
    check(#installs == 0 and #restarts == 0, "Later: nothing installed")

    reset()
    releases = { concordance = "0.7.1", cloudlibrary = "0.2.4" }
    broken = { cloudlibrary = "download" }
    Updates.check(true)
    last().ok_callback()
    check(#restarts == 1 and has(restarts[1], "Updated: Concordance 0.7.1") and has(restarts[1], "Couldn't update:")
        and has(restarts[1], "Cloud library: 404"), "a failed download is reported with the restart prompt")
end

-- Automatic -------------------------------------------------------------------------------

do
    reset()
    releases = { concordance = "0.7.1", cloudlibrary = "0.2.4" }
    online = false
    Updates.check(false)
    check(#fetches == 0, "automatic: nothing when offline")
    online = true

    Updates.check(false)
    local w = last()
    check(w.confirm and w.other_buttons and w.other_buttons[1][1].text == "Skip these versions",
        "automatic, both notify: one dialog, with Skip")
    w.other_buttons[1][1].callback()
    check(reader_data.concordance_updates.skip == "0.7.1" and cl_data.updates.skip == "0.2.4", "both versions skipped")
    shown, fetches = {}, {}
    Updates.check(false)
    check(#fetches == 0, "automatic: not again within a day")
    reader_data.concordance_updates.last_check, cl_data.updates.last_check = 1, 1
    Updates.check(false)
    check(#fetches == 2 and #shown == 0, "a skipped version isn't offered again")

    reset()
    OS.setMode("install")
    CL.setMode("notify")
    Updates.check(false)
    check(table.concat(installs, ",") == "concordance 0.7.1", "install mode: installed without asking")
    w = last()
    check(w.confirm and has(w.text, "Cloud library: 0.2.4 available") and #restarts == 0,
        "notify mode: offered, restart prompt after the answer")
    w.cancel_callback()
    check(#restarts == 1 and has(restarts[1], "Concordance 0.7.1"), "one restart prompt, with the automatic install")

    reset()
    CL.setMode("off")
    Updates.check(false)
    check(table.concat(fetches, ",") == "concordance", "mode off: not checked automatically")

    -- A Cloud library that checks for itself isn't checked automatically here.
    reset()
    CL.defers_to_concordance = nil
    Updates.check(false)
    check(table.concat(fetches, ",") == "concordance", "older Cloud library: its own automatic check")
    CL.defers_to_concordance = true

    reset()
    with_cl = false
    releases = { concordance = "0.7.0" }
    Updates.check(true)
    check(#fetches == 1 and has(last().text, "Concordance: up to date") and not has(last().text, "Cloud"),
        "without Cloud library: Concordance only")
    with_cl = true
end

-- Cloud library's updater -------------------------------------------------------------------

do
    reset()
    releases = { concordance = "0.7.0", cloudlibrary = "0.2.3" }
    CL.check(cl_plugin, false)
    check(#fetches == 0, "Cloud library's automatic check left to Concordance")
    CL.check(cl_plugin, true)
    check(#fetches == 2 and has(last().text, "Concordance: up to date"), "its Check for updates runs the combined check")
    reset()
    local entries = Updates.entries
    Updates.entries = nil
    CL.check(cl_plugin, true)
    check(table.concat(fetches, ",") == "cloudlibrary", "without Concordance: its own check")
    Updates.entries = entries
end

-- Menu ------------------------------------------------------------------------------------

do
    OS.setMode("install")
    CL.setMode("off")
    local items = Updates.menuItems()
    check(items[1].text == "Check for updates" and has(items[1].help_text, "Concordance 0.7.0, Cloud library 0.2.3"),
        "menu: one check, versions in its help")
    local auto = items[2].sub_item_table
    check(items[2].text == "Automatic updates" and #auto == 2 and auto[1].text_func() == "Concordance: install"
        and auto[2].text_func() == "Cloud library: off", "menu: each plugin's automatic mode")
    auto[2].sub_item_table[2].callback()
    check(CL.getMode() == "notify", "menu: sets the plugin's own mode")
    with_cl = false
    items = Updates.menuItems()
    check(items[2].text_func() == "Automatic updates: install", "menu without Cloud library: as before")
    with_cl = true
end

S.finish("concordance update tests")
