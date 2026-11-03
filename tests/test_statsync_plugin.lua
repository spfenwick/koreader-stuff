-- Exercises statsync.koplugin's KOReader glue (main.lua, statsync/plugin.lua)
-- with KOReader's UI modules stubbed, but the rest real: KOReader's
-- statistics plugin as the open book's, forked subprocesses, and a WebDAV
-- server (rclone). Checks the flush of unsaved page times, the server
-- taken from Cloud storage by name, the folder setting, the menu, and the
-- refresh of the open book's totals.

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
    delSetting = function(_, k) settings_data[k] = nil end,
}
-- Settings from earlier versions, copied on first use: this device's status
-- from settings.reader.lua, the shared ones from statsync.lua (written
-- below), which has a whole Cloud storage entry, password and all, synced to
-- its folder + /statsync. Both are left as they were, for older versions.
settings_data.statsync = { allow_wifi = true, status = { last_success = 5 } }
local OLD_SHARED = 'return { allow_wifi = false, time_limit = 120, server = { name = "My DAV", type = "webdav", '
    .. string.format("address = %q, ", server.url) .. 'username = "u", password = "p", url = "/books" } }\n'

-- The open book: KOReader's statistics plugin, with page times not yet written.
local dev = S.newDevice("reader", TMP .. "/settings")
S.writeFile(dev.dir .. "/statsync.lua", OLD_SHARED)
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
    close = function() end,
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
-- KOReader's LuaSettings, enough of it: dofile to read, a Lua table to write.
local function serialize(v, indent)
    indent = indent or ""
    if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
        local out = { "{\n" }
        for _, k in ipairs(keys) do
            out[#out + 1] = string.format("%s    [%q] = %s,\n", indent, k, serialize(v[k], indent .. "    "))
        end
        return table.concat(out) .. indent .. "}"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end
stub("luasettings", {
    open = function(_, path)
        local ok, data = pcall(dofile, path)
        return {
            file = path,
            data = ok and type(data) == "table" and data or {},
            flush = function(self) S.writeFile(self.file, "return " .. serialize(self.data) .. "\n") end,
        }
    end,
})
stub("socket.http", S.Http.new())
stub("apps/reader/readerui", { instance = { statistics = stats } })
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
local folder_input
stub("ui/widget/inputdialog", { new = function(_, o)
    o.getInputText = function() return folder_input end
    o.onShowKeyboard = function() end
    return o
end })
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
check(item("Check for updates") and item("Automatic updates"), "update items in the menu")

-- The old server entry became a reference by name, with the same folder.
local P0 = require("statsync/plugin")
local function fileData(name) return dofile(dev.dir .. "/" .. name) end
local saved = fileData("statsync_settings.lua")
check(saved.server and saved.server.name == "My DAV" and saved.server.password == nil and saved.server.address == nil,
    "statsync_settings.lua keeps the server's name only, no credentials")
check(saved.root == "/books/statsync", "same folder as before: " .. tostring(saved.root))
check(item("Folder on server: /books/statsync"), "folder shown in the menu")

-- Not (yet) in Cloud storage: told why
check(item("Server: My DAV (not in Cloud storage)"), "missing server shown")
item("Sync now").callback()
loop:run(10)
check(shown[#shown] and shown[#shown].text:find("not found in Cloud storage"), "manual sync without the server explains why")

-- Cloud storage's servers: only WebDAV ones offered, credentials from there.
local function writeCloudStorage(servers)
    local f = assert(io.open(dev.dir .. "/cloudstorage.lua", "w"))
    local parts = {}
    for _, sv in ipairs(servers) do
        local fields = {}
        for k, v in pairs(sv) do fields[#fields + 1] = string.format("[%q] = %q", k, v) end
        parts[#parts + 1] = "{ " .. table.concat(fields, ", ") .. " }"
    end
    f:write("return { cs_servers = { " .. table.concat(parts, ", ") .. " } }\n")
    f:close()
end
writeCloudStorage({
    { name = "Box", type = "dropbox", address = "x", password = "y" },
    { name = "My DAV", type = "webdav", address = server.url, username = "u", password = "p", url = "/elsewhere" },
})
S.mkdirp(server.dir .. "/books")
check(item("Server: My DAV") and not item("not in Cloud storage"), "server found in Cloud storage")
local sub = item("Server:").sub_item_table_func()
check(#sub == 1 and sub[1].text == "My DAV" and sub[1].checked_func(), "only WebDAV servers offered, chosen one checked")
check(P0.serverLocation() == server.url .. "/books/statsync/", "location: " .. tostring(P0.serverLocation()))
check(P0.serverLocation({ address = "https://me:secret@dav.example.com/dav/" })
    == "https://dav.example.com/dav/books/statsync/", "location shown without credentials")

-- Automatic sync is off by default: the start-up trigger does nothing
loop:run(30)
local P = require("statsync/plugin")
-- The old settings were copied: shared ones and this device's own apart,
-- statsync.lua's shared ones over settings.reader.lua's.
local shared, own = fileData("statsync_settings.lua"), fileData("statsync_device.lua")
check(shared.allow_wifi == false and shared.time_limit == 120 and shared.status == nil and shared.device_id == nil,
    "statsync_settings.lua: shared settings only")
check(S.readFile(dev.dir .. "/statsync.lua") == OLD_SHARED and settings_data.statsync.allow_wifi == true,
    "old settings left alone for older versions")
check(own.status and own.status.last_success == 5, "statsync_device.lua: this device's status")
check(not P.deviceState().status.last_attempt, "automatic sync off by default")

-- Turn it on; a network-connected trigger syncs, and flushes the open book first
item("Sync automatically").callback()
check(P.settings().enabled == true and fileData("statsync_settings.lua").enabled == true, "automatic sync turned on, saved to statsync_settings.lua")
plugin:onNetworkConnected()
loop:run(60)
local st = P.deviceState().status
check(st and st.last_success and not st.last_error, "automatic sync succeeded: " .. tostring(st and st.last_error))
check(st and st.uploaded_events == 3, "the unsaved page times were flushed and sent (" .. tostring(st and st.uploaded_events) .. ")")
local id = P.deviceState().device_id
check(fileData("statsync_device.lua").device_id == id and fileData("statsync_settings.lua").device_id == nil,
    "device ID saved in statsync_device.lua only")
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
check(P.deviceState().status.last_attempt == before, "offline: automatic sync skipped")
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
check(P.deviceState().status.imported_events == 2, "two events imported")
check(stats.book_read_time > time_before, "open book's cached totals refreshed ("
    .. tostring(time_before) .. " -> " .. tostring(stats.book_read_time) .. ")")
check(P.deviceState().status.devices == 2, "two devices seen")

-- Status, rebuild, reset device ID
item("Status").callback()
check(shown[#shown].text:find("Devices seen: 2", 1, true), "status shows devices seen")
check(shown[#shown].text:find("Folder: " .. server.url .. "/books/statsync/", 1, true), "status shows the folder")
item("Rebuild from cloud").callback()
shown[#shown].ok_callback()
loop:run(60)
check(P.deviceState().status.imported_events == 5, "rebuild re-imported both devices' segments (3 + 2 events, got "
    .. tostring(P.deviceState().status.imported_events) .. ")")
check(dev:totalsMatch(), "totals still match after rebuild")
item("Reset device ID").callback()
shown[#shown].ok_callback()
check(P.deviceState().device_id ~= id, "device ID reset")

-- Another folder: everything this device has is sent there.
folder_input = "/fresh"
item("Folder on server").callback()
shown[#shown].buttons[1][2].callback()
check(fileData("statsync_settings.lua").root == "/fresh", "folder saved to statsync_settings.lua")
check(P.serverLocation() == server.url .. "/fresh/", "new location")
item("Sync now").callback()
loop:run(60)
local st2 = P.deviceState().status
check(st2.uploaded_events == 5 and not st2.last_error,
    "all 5 entries sent to the new folder (" .. tostring(st2.uploaded_events) .. ", " .. tostring(st2.last_error) .. ")")
check(io.open(server.dir .. "/fresh/devices/" .. P.deviceState().device_id .. "/seg-0000000001.jsonl") ~= nil,
    "segment in the new folder")

-- No server chosen: the first WebDAV server in Cloud storage
P.settings().server = nil
check(P.server() and P.server().name == "My DAV", "first WebDAV server used when none chosen")
writeCloudStorage({ { name = "Box", type = "dropbox" } })
local none, why = P.server()
check(none == nil and why:find("no WebDAV server"), "no WebDAV server: told why")
check(item("Server: not set"), "server shown as not set")

server.stop()
S.finish("statsync plugin test")
