-- Exercises statsync.koplugin's KOReader glue (main.lua, statsync/plugin.lua)
-- with KOReader's UI modules stubbed, but the rest real: KOReader's
-- statistics plugin as the open book's, forked subprocesses, and a WebDAV
-- server (rclone). Checks the flush of unsaved page times, the server
-- fallback to Reading statistics' one, the menu, and the refresh of the
-- open book's totals.

local S = dofile("tests/statsync/support.lua")
local check = S.check
local Codec = require("statsync/codec")

local TMP = assert(os.getenv("STATSYNC_TMP")) .. "/plugin"
S.rmrf(TMP)
S.mkdirp(TMP)
local server, serr = S.startWebDav(TMP .. "/server", "u", "p")
if not server then
    print("statsync plugin test: skipped (" .. serr .. ")")
    os.exit(0)
end

local loop = S.Loop.new()
local shown = {}
local connected = true

-- KOReader's settings: readSetting(key, default) stores the default.
local settings_data = {}
_G.G_reader_settings = {
    readSetting = function(_, k, default)
        if settings_data[k] == nil and default ~= nil then settings_data[k] = default end
        return settings_data[k]
    end,
    saveSetting = function(_, k, v) settings_data[k] = v end,
}

-- The open book: KOReader's statistics plugin, with page times not yet written.
local dev = S.newDevice("reader", TMP .. "/settings")
local book = { md5 = string.rep("c", 32), title = "Open book", authors = "Someone", pages = 200 }
dev:read(book, { { 1, 1000, 30 } })
local stats = dev.stats
stats.page_stat = { [2] = { { 2000, 45 } }, [3] = { { 2045, 50 } } } -- in memory only
stats.curr_page = 4

local function stub(name, value) package.loaded[name] = value end
stub("datastorage", { getDataDir = function() return TMP .. "/data" end, getSettingsDir = function() return dev.dir end })
stub("device", { model = "Test device" })
stub("logger", { info = function() end, warn = function(...) if os.getenv("STATSYNC_VERBOSE") then print(...) end end,
                 dbg = function() end, err = print })
stub("ui/network/manager", {
    isConnected = function() return connected end,
    runWhenConnected = function(_, cb) connected = true; cb() end,
})
stub("ui/uimanager", {
    scheduleIn = function(_, delay, fn) loop:schedule(delay, fn) end,
    nextTick = function(_, fn) loop:schedule(0, fn) end,
    preventStandby = function() end, allowStandby = function() end,
    show = function(_, w) table.insert(shown, w) end,
})
stub("ffi/util", {
    template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
    runInSubProcess = function(fn) local h = S.Fork.spawn(fn); return h and h.pid end,
    isSubProcessDone = function(pid) return S.Fork.isDone({ pid = pid }) end,
    terminateSubProcess = function(pid) S.Fork.kill({ pid = pid }) end,
})
stub("lua-ljsqlite3/init", S.SQ3)
stub("socket.http", S.Http.new())
stub("apps/reader/readerui", { instance = { statistics = stats } })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("dispatcher", { registerAction = function() end })
stub("datetime", { secondsToDateTime = function(t) return os.date("!%Y-%m-%d %H:%M:%S", t) end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ui/widget/container/widgetcontainer", {
    extend = function(_, o) o.__index = o; return o end,
})
package.path = "statsync.koplugin/?.lua;" .. package.path

local StatSync = dofile("statsync.koplugin/main.lua")
local menu_items = {}
local ui = { menu = { registerToMainMenu = function(_, p) p:addToMainMenu(menu_items) end } }
local plugin = setmetatable({ ui = ui }, StatSync)
plugin:init()

local menu = menu_items.statsync
check(menu and menu.sorting_hint == "tools", "menu entry under Tools")
local function item(text)
    for _, it in ipairs(menu.sub_item_table) do
        local t = it.text or (it.text_func and it.text_func())
        if t and t:find(text, 1, true) then return it end
    end
end
check(item("Server: not set"), "server shown as not set")

-- Sync now without a server: told why
item("Sync now").callback()
loop:run(10)
check(shown[#shown] and shown[#shown].text:find("no server set"), "manual sync without a server explains why")

-- Reading statistics' Cloud sync server is used when statsync has none
settings_data.statistics = { is_enabled = true, sync_server = {
    name = "My DAV", type = "webdav", address = server.url, username = "u", password = "p", url = "/books" } }
S.mkdirp(server.dir .. "/books")
check(item("from Reading statistics"), "server taken from Reading statistics")

-- Automatic sync is off by default: the start-up trigger does nothing
loop:run(30)
check(not settings_data.statsync.status or not settings_data.statsync.status.last_attempt, "automatic sync off by default")

-- Turn it on; a network-connected trigger syncs, and flushes the open book first
item("Sync automatically").callback()
check(settings_data.statsync.enabled == true, "automatic sync turned on")
plugin:onNetworkConnected()
loop:run(60)
local st = settings_data.statsync.status
check(st and st.last_success and not st.last_error, "automatic sync succeeded: " .. tostring(st and st.last_error))
check(st and st.uploaded_events == 3, "the unsaved page times were flushed and sent (" .. tostring(st and st.uploaded_events) .. ")")
local id = settings_data.statsync.device_id
check(id and #id == 16, "device ID created")
local segs = 0
for name in io.popen("ls " .. S.q(server.dir .. "/books/statsync/devices/" .. id)):lines() do
    if Codec.segmentSeq(name) then segs = segs + 1 end
end
check(segs == 1, "segment on the server under books/statsync")

-- Offline: automatic triggers skip quietly
connected = false
local before = st.last_attempt
plugin:onResume()
loop:run(10)
check(settings_data.statsync.status.last_attempt == before, "offline: automatic sync skipped")
connected = true

-- Another device's reading of the open book shows up in the open book's totals
local other = S.newDevice("other", TMP .. "/other")
other:read(book, { { 10, 5000, 100 }, { 11, 5100, 100 } })
local Store = require("statsync/store")
local WebDav = require("statsync/webdav")
local ost = Store.new{ sq3 = S.SQ3, stats_path = other.db, state_path = other.state }
local seg = TMP .. "/other.jsonl"
ost:export{ device_id = "otherdev", out_path = seg, now = 1, max_events = 1000 }
local dav = WebDav.new{ http = S.Http.new(), address = server.url, username = "u", password = "p", root = "books/statsync" }
dav:mkdir("devices/otherdev")
check(dav:put_new("devices/otherdev/seg-0000000001.jsonl", seg), "other device's segment uploaded")
local time_before = stats.book_read_time
stats.page_stat = {}
item("Sync now").callback()
loop:run(60)
check(shown[#shown] and shown[#shown].text:find("Statistics synced"), "manual sync reports success")
check(settings_data.statsync.status.imported_events == 2, "two events imported")
check(stats.book_read_time > time_before, "open book's cached totals refreshed ("
    .. tostring(time_before) .. " -> " .. tostring(stats.book_read_time) .. ")")
check(settings_data.statsync.status.devices == 2, "two devices seen")

-- Status, rebuild, reset device ID
item("Status").callback()
check(shown[#shown].text:find("Devices seen: 2", 1, true), "status shows devices seen")
item("Rebuild from cloud").callback()
shown[#shown].ok_callback()
loop:run(60)
check(settings_data.statsync.status.imported_events == 5, "rebuild re-imported both devices' segments (3 + 2 events, got "
    .. tostring(settings_data.statsync.status.imported_events) .. ")")
check(dev:totalsMatch(), "totals still match after rebuild")
item("Reset device ID").callback()
shown[#shown].ok_callback()
check(settings_data.statsync.device_id ~= id, "device ID reset")

server.stop()
S.finish("statsync plugin test")
