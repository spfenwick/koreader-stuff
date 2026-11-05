-- Exercises supersync.koplugin's KOReader glue for statistics and
-- highlights (main.lua, supersync/plugin.lua, supersync/migrate.lua) with
-- KOReader's UI modules stubbed, but the rest real: KOReader's statistics
-- plugin as the open book's, forked subprocesses, and a WebDAV server
-- (rclone). Checks the flush of unsaved page times, the server taken from
-- Cloud storage by name, separate syncs of statistics and highlights, the
-- automatic sync settings, taking over Statistics sync's data, and the
-- refresh of the open book's totals.

local S = dofile("tests/supersync/support.lua")
local check = S.check
local Codec = require("supersync/codec")

local TMP = assert(os.getenv("STATSYNC_TMP")) .. "/plugin"
S.rmrf(TMP)
S.mkdirp(TMP)
local server, serr = S.startWebDav(TMP .. "/server", "u", "p")
if not server then
    print("supersync plugin test: skipped (" .. serr .. ")")
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

-- The open book: KOReader's statistics plugin, with page times not yet written.
local dev = S.newDevice("reader", TMP .. "/settings")
-- Statistics sync's shared settings: some are taken over.
S.writeFile(dev.dir .. "/statsync_settings.lua", 'return { allow_wifi = false, time_limit = 120, enabled = false, root = "/x" }\n')
local book = { md5 = string.rep("c", 32), title = "Open book", authors = "Someone", pages = 200 }
dev:read(book, { { 1, 1000, 30 } })
local stats = dev.stats
stats.page_stat = { [2] = { { 2000, 45 } }, [3] = { { 2045, 50 } } } -- in memory only
stats.curr_page = 4

local function stub(name, value) package.loaded[name] = value end
stub("datastorage", { getDataDir = function() return TMP .. "/data" end, getSettingsDir = function() return dev.dir end })
S.mkdirp(TMP .. "/data")
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
stub("ui/widget/confirmbox", { new = function(_, o) o.confirm = true; return o end })
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
-- Reading history and book settings, for the highlights scan.
local MD5 = string.rep("d", 32)
local XP = "/body/DocFragment[2]/body/p[3]/text().0"
local sidecar = { partial_md5_checksum = MD5, doc_props = { title = "Annotated" },
                  summary = { status = "complete", modified = "2026-01-01" },
                  annotations = { { datetime = "2026-02-02 02:02:02", drawer = "lighten", text = "from history",
                                    page = XP, pos0 = XP, pos1 = "/body/DocFragment[2]/body/p[3]/text().9" } } }
stub("readhistory", { hist = { { file = TMP .. "/annotated.epub" } } })
S.writeFile(TMP .. "/annotated.epub", "book")
stub("docsettings", {
    hasSidecarFile = function(_, p) return p == TMP .. "/annotated.epub" end,
    findSidecarFile = function(_, p) return p == TMP .. "/annotated.epub" and TMP .. "/annotated.sdr/metadata.epub.lua" or nil end,
    findCustomMetadataFile = function() return nil end,
    open = function() return { readSetting = function(_, k) return sidecar[k] end } end,
})
stub("libs/libkoreader-lfs", require("lfs"))
stub("ui/event", { new = function(_, name, args) return { name = name, args = args } end })
stub("ui/widget/multiconfirmbox", { new = function(_, o) o.multi = true; return o end })

package.path = "supersync.koplugin/?.lua;" .. package.path

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

local SuperSync = dofile("supersync.koplugin/main.lua")
local menu_items = {}
local ui = { menu = { registerToMainMenu = function(_, p) p:addToMainMenu(menu_items) end } }
local plugin = setmetatable({ ui = ui }, SuperSync)
plugin:init()
local function wasShown(text)
    for _, w in ipairs(shown) do
        if w.text and w.text:find(text, 1, true) then return true end
    end
end

local menu = menu_items.supersync
check(menu and menu.sorting_hint == "tools", "menu entry under Tools")
local function item(text)
    for _, it in ipairs(menu.sub_item_table_func()) do
        local t = it.text or (it.text_func and it.text_func())
        if t and t:find(text, 1, true) then return it end
    end
end
check(item("Check for updates") and item("Automatic updates"), "update items in the menu")

local P = require("supersync/plugin")
local function fileData(name) return dofile(dev.dir .. "/" .. name) end
local saved = fileData("supersync_settings.lua")
check(saved.allow_wifi == false and saved.time_limit == 120 and saved.enabled == nil and saved.root == nil,
    "Statistics sync's Wi-Fi and time limit taken over, not its folder or automatic sync")
check(item("Folder on server: /KOReader"), "default folder shown in the menu")
check(P.autoStats() and P.autoAnnotations(), "automatic syncs on by default")

-- The first server is Dropbox: fine for settings, not for statistics.
check(item("Server: Box (Dropbox)"), "first server used when none chosen")
item("Sync statistics").callback()
check(wasShown("need a WebDAV server"), "statistics on Dropbox: told why")
local sub = item("Server:").sub_item_table_func()
check(#sub == 2 and sub[1].checked_func() and not sub[2].checked_func(), "Dropbox and WebDAV servers offered")
sub[2].callback()
check(fileData("supersync_settings.lua").server.name == "My DAV" and fileData("supersync_settings.lua").server.password == nil,
    "chosen server kept by name, no credentials")
check(item("Server: My DAV (WebDAV)"), "chosen server shown")
check(P.serverLocation() == server.url .. "/KOReader/Statistics/", "location: " .. tostring(P.serverLocation()))
check(P.serverLocation({ address = "https://me:secret@dav.example.com/dav/" })
    == "https://dav.example.com/dav/KOReader/Statistics/", "location shown without credentials")

-- Automatic sync is on: the start-up trigger syncs both, flushing the open book first.
loop:run(60)
check(wasShown("took over"), "taking over Statistics sync's data reported")
local st = P.deviceState().status
check(st and st.last_success and not st.last_error, "automatic sync at start succeeded: " .. tostring(st and st.last_error))
check(st and st.uploaded_events == 3, "the unsaved page times were flushed and sent (" .. tostring(st and st.uploaded_events) .. ")")
check(st.stats_last_success and st.ann_last_success and st.ann_uploaded == 1, "statistics and highlights both synced")
check(P.deviceState().ann_scanned ~= nil, "reading history read before the first sync of highlights")
local id = P.deviceState().device_id
check(fileData("supersync_device.lua").device_id == id and fileData("supersync_settings.lua").device_id == nil,
    "device ID saved in supersync_device.lua only")
check(id and #id == 16, "device ID created")
local function count(dir, pattern)
    local n = 0
    for name in io.popen("ls " .. S.q(dir) .. " 2>/dev/null"):lines() do
        if name:match(pattern) then n = n + 1 end
    end
    return n
end
local DAVDIR = server.dir .. "/KOReader/Statistics/devices/"
check(count(DAVDIR .. id, "^seg%-") == 1 and count(DAVDIR .. id, "^ann%-") == 1 and count(DAVDIR .. id, "^book%-") == 1,
    "compressed segments on the server under KOReader/Statistics")
check(st.book_uploaded == 1, "book status from the reading history sent with highlights (" .. tostring(st.book_uploaded) .. ")")

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
local Store = require("supersync/store")
local WebDav = require("supersync/webdav")
local ost = Store.new{ sq3 = S.SQ3, stats_path = other.db, state_path = other.state }
local seg = TMP .. "/other.jsonl"
ost:export{ device_id = "otherdev", out_path = seg, now = 1, max_events = 1000 }
local dav = WebDav.new{ http = S.Http.new(), address = server.url, username = "u", password = "p", root = "KOReader/Statistics" }
check(require("supersync/zstd").compressFile(seg, seg .. ".zst"), "other device's segment compressed")
dav:mkdir("devices/otherdev")
check(dav:put_new("devices/otherdev/seg-0000000001.jsonl.zst", seg .. ".zst"), "other device's segment uploaded")
local time_before = stats.book_read_time
stats.page_stat = {}
local ann_success = P.deviceState().status.ann_last_success
S.sleep(1.1)
item("Sync statistics").callback()
loop:run(60)
check(shown[#shown] and shown[#shown].text:find("^Statistics synced") and not shown[#shown].text:find("Highlights"),
    "statistics sync reports statistics only: " .. tostring(shown[#shown] and shown[#shown].text))
check(P.deviceState().status.imported_events == 2, "two events imported")
check(P.deviceState().status.ann_last_success == ann_success, "highlights not synced with statistics")
check(stats.book_read_time > time_before, "open book's cached totals refreshed ("
    .. tostring(time_before) .. " -> " .. tostring(stats.book_read_time) .. ")")
check(P.deviceState().status.devices == 2, "two devices seen")

-- Automatic statistics off: automatic syncs do highlights only.
item("Sync statistics automatically").callback()
check(fileData("supersync_settings.lua").auto_stats == false, "automatic statistics off, saved")
local stats_success = P.deviceState().status.stats_last_success
S.sleep(1.1)
plugin:onNetworkConnected()
loop:run(60)
st = P.deviceState().status
check(st.stats_last_success == stats_success and st.ann_last_success > ann_success and not st.last_error,
    "automatic sync: highlights only")
item("Sync highlights and bookmarks automatically").callback()
before = st.last_attempt
S.sleep(1.1)
plugin:onNetworkConnected()
loop:run(10)
check(P.deviceState().status.last_attempt == before, "both automatic syncs off: nothing synced")
item("Sync statistics automatically").callback()
item("Sync highlights and bookmarks automatically").callback()
check(P.autoStats() and P.autoAnnotations(), "both on again")

-- Status, rebuild
item("Status").callback()
check(shown[#shown].text:find("Devices seen: 2", 1, true), "status shows devices seen")
check(shown[#shown].text:find("Statistics folder: " .. server.url .. "/KOReader/Statistics/", 1, true),
    "status shows the folder")
item("Rebuild statistics and highlights from cloud").callback()
shown[#shown].ok_callback()
loop:run(60)
check(P.deviceState().status.imported_events == 5, "rebuild re-imported both devices' segments (3 + 2 events, got "
    .. tostring(P.deviceState().status.imported_events) .. ")")
check(dev:totalsMatch(), "totals still match after rebuild")

-- Taking over Statistics sync's data -----------------------------------------------
-- As if this device had used Statistics sync: its database and device ID
-- in its files, and its server folder copied by hand to SuperSync's.
local function cp(from, to) os.execute("cp -r " .. S.q(from) .. " " .. S.q(to)) end
cp(dev.dir .. "/supersync.sqlite3", dev.dir .. "/statsync.sqlite3")
cp(dev.dir .. "/supersync_device.lua", dev.dir .. "/statsync_device.lua")
os.remove(dev.dir .. "/supersync.sqlite3")
os.remove(dev.dir .. "/supersync_device.lua")
S.mkdirp(server.dir .. "/Moved")
cp(server.dir .. "/KOReader/Statistics", server.dir .. "/Moved/Statistics")
local own_files = count(server.dir .. "/Moved/Statistics/devices/" .. id, "%.zst$")
dofile("supersync.koplugin/main.lua") -- KOReader starting
check(S.readFile(dev.dir .. "/supersync.sqlite3") and P.deviceState().device_id == id
    and P.deviceState().ann_scanned ~= nil, "database and device ID taken over")
check(S.readFile(dev.dir .. "/statsync.sqlite3"), "Statistics sync's database left alone")
-- First a folder without this device's files (the copy not made yet, or
-- the wrong folder): stopped before writing anything, and asked.
P.settings().root = "/Empty"
P.saveSettings()
item("Sync statistics").callback()
loop:run(60)
local q0 = shown[#shown]
check(q0 and q0.confirm and q0.text:find("files aren't in the folder"), "folder without this device's files: asked: "
    .. tostring(q0 and q0.text))
check(not io.open(server.dir .. "/Empty/Statistics/devices/" .. id), "nothing written there")
-- Then the folder with the copied files.
P.settings().root = "/Moved"
P.saveSettings()
item("Sync statistics").callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.uploaded_events == 0, "nothing sent again to the copied folder: "
    .. tostring(st.uploaded_events) .. ", " .. tostring(st.last_error))
check(count(server.dir .. "/Moved/Statistics/devices/" .. id, "%.zst$") == own_files, "no new files")
item("Sync highlights and bookmarks").callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.ann_uploaded == 0, "no highlights sent again either")

-- Asked again for another folder without its files, the user sends everything there.
Store.new{ sq3 = S.SQ3, stats_path = dev.db, state_path = dev.dir .. "/supersync.sqlite3" }:forgetLocation()
P.settings().root = "/Fresh"
P.saveSettings()
item("Sync statistics").callback()
loop:run(60)
q0 = shown[#shown]
check(q0 and q0.confirm and q0.ok_text == "Send everything", "asked again")
q0.ok_callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.uploaded_events == 5, "send everything: all 5 entries sent ("
    .. tostring(st.uploaded_events) .. ", " .. tostring(st.last_error) .. ")")
check(io.open(server.dir .. "/Fresh/Statistics/devices/" .. id .. "/seg-0000000001.jsonl.zst") ~= nil,
    "segment in the new folder")

-- Highlights and bookmarks ----------------------------------------------------------------
local FRESH = "Fresh/Statistics"
local dev_id = id
local function annSegs() return count(server.dir .. "/" .. FRESH .. "/devices/" .. dev_id, "^ann%-%d+%.jsonl%.zst$") end
local segs0 = annSegs()
check(segs0 == 1, "highlights sent to the new folder (" .. segs0 .. ")")
check(not item("Removed highlights waiting").enabled_func(), "no held removals: item disabled")

-- A book open in the reader: changes from another device applied on open,
-- the user's own sent on close.
local events = {}
local reader = {
    rolling = true, statistics = stats,
    document = { file = TMP .. "/annotated.epub" },
    doc_settings = { readSetting = function(_, k) return k == "partial_md5_checksum" and MD5 or nil end },
    doc_props = { display_title = "Annotated" },
    annotation = { annotations = {}, updateAnnotations = function() end,
                   getNumberOfHighlightsAndNotes = function(a) return #a.annotations, 0 end },
    handleEvent = function(_, ev) table.insert(events, ev) end,
}
reader.dialog = reader
reader.annotation.annotations = { sidecar.annotations[1] }
package.loaded["apps/reader/readerui"].instance = reader
local other_seg = TMP .. "/other-ann.jsonl"
local AnnFormat = require("supersync/annformat")
local XP2 = "/body/DocFragment[5]/body/p[1]/text().0"
S.writeFile(other_seg, table.concat({
    AnnFormat.headerLine("otherdev", 1),
    AnnFormat.bookLine{ md5 = MD5, title = "Annotated" },
    AnnFormat.recordLine{ md5 = MD5, kind = "rolling", key = "2026-03-03 03:03:03", updated = 1772500000, device = "otherdev",
                          fields_json = AnnFormat.fieldsJson{ datetime = "2026-03-03 03:03:03", drawer = "underscore",
                                                              text = "from the other device", page = XP2, pos0 = XP2, pos1 = XP2 } },
    AnnFormat.trailerLine(1, 1),
}, "\n") .. "\n")
local fresh = WebDav.new{ http = S.Http.new(), address = server.url, username = "u", password = "p", root = FRESH }
check(require("supersync/zstd").compressFile(other_seg, other_seg .. ".zst"), "other device's annotations compressed")
fresh:mkdir("devices/otherdev")
check(fresh:put_new("devices/otherdev/ann-0000000001.jsonl.zst", other_seg .. ".zst"), "other device's annotations uploaded")
item("Sync highlights and bookmarks").callback()
loop:run(60)
check(#reader.annotation.annotations == 2, "applied live to the open book (" .. #reader.annotation.annotations .. ")")
local ev = events[#events]
check(ev and ev.name == "AnnotationsModified" and ev.args.nb_highlights_added == 1, "AnnotationsModified sent")
check(shown[#shown].text:find("received 1", 1, true), "manual sync reports annotations: " .. shown[#shown].text)
-- The reader plugin instance: a new highlight, then the book closes
local reader_plugin = setmetatable({ ui = reader }, SuperSync)
local XP3 = "/body/DocFragment[7]/body/p[1]/text().0"
table.insert(reader.annotation.annotations, { datetime = "2026-04-04 04:04:04", drawer = "lighten", text = "new",
                                              page = XP3, pos0 = XP3, pos1 = XP3 })
reader_plugin:onCloseDocument()
package.loaded["apps/reader/readerui"].instance = { statistics = stats }
loop:run(60)
check(annSegs() == segs0 + 1 and P.deviceState().status.ann_uploaded == 1, "new highlight sent after closing the book")

-- Three more highlights, so the book has 6
for i = 1, 3 do
    local xp = "/body/DocFragment[8]/body/p[" .. i .. "]/text().0"
    table.insert(reader.annotation.annotations, { datetime = "2026-05-05 05:05:0" .. i, drawer = "lighten",
                                                  text = "more " .. i, page = xp, pos0 = xp, pos1 = xp })
end
package.loaded["apps/reader/readerui"].instance = reader
reader_plugin:onCloseDocument()
package.loaded["apps/reader/readerui"].instance = { statistics = stats }
loop:run(60)

-- Opening it again with its annotations gone (book settings reset): more
-- than 5 at once, so it asks
reader.annotation.annotations = {}
reader_plugin.ui.registerPostReaderReadyCallback = nil
reader_plugin:onReaderReady()
loop:run(5, function() return shown[#shown].multi end)
local q = shown[#shown]
check(q.multi and q.text:find("6 of 6", 1, true) and q.text:find("Annotated", 1, true), "asked about the removed highlights: " .. tostring(q.text))
check(item("Removed highlights waiting").enabled_func(), "held removals: menu item enabled")
item("Status").callback()
check(shown[#shown].text:find("Books with removals waiting for you: 1", 1, true), "status shows the held book")
check(shown[#shown].text:find("Book status and details (synced with highlights): 1 books", 1, true),
    "status shows book data")
package.loaded["apps/reader/readerui"].instance = reader
q.choice1_callback() -- restore them here
check(#reader.annotation.annotations == 6, "restored in the open book")
check(not item("Removed highlights waiting").enabled_func(), "nothing held any more")
package.loaded["apps/reader/readerui"].instance = { statistics = stats }

server.stop()
-- Reset device ID
item("Reset device ID").callback()
shown[#shown].ok_callback()
check(P.deviceState().device_id ~= id, "device ID reset")

S.finish("supersync plugin test")
