-- Exercises concordance.koplugin's KOReader glue for statistics and
-- highlights (main.lua, concordance/plugin.lua) with
-- KOReader's UI modules stubbed, but the rest real: KOReader's statistics
-- plugin as the open book's, forked subprocesses, and a WebDAV server
-- (rclone). Checks the flush of unsaved page times, the server taken from
-- Cloud storage by name, separate syncs of statistics and highlights, the
-- automatic sync settings, and the
-- refresh of the open book's totals.

local S = dofile("tests/concordance/support.lua")
local check = S.check
local Codec = require("concordance/codec")

local TMP = assert(os.getenv("STATSYNC_TMP")) .. "/plugin"
S.rmrf(TMP)
S.mkdirp(TMP)
local server, serr = S.startWebDav(TMP .. "/server", "u", "p")
if not server then
    print("concordance plugin test: skipped (" .. serr .. ")")
    os.exit(0)
end

local loop = S.Loop.new()
local shown = {}
local closed = {}
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
-- Shared settings already saved on this device.
os.execute("mkdir -p '" .. dev.dir .. "/concordance'")
S.writeFile(dev.dir .. "/concordance/settings.lua", 'return { allow_wifi = false, time_limit = 120 }\n')
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
    runWhenOnline = function(_, cb) cb() end,
})
stub("ui/uimanager", {
    scheduleIn = function(_, delay, fn) loop:schedule(delay, fn) end,
    nextTick = function(_, fn) loop:schedule(0, fn) end,
    unschedule = function(_, fn) loop:unschedule(fn) end,
    preventStandby = function() end, allowStandby = function() end,
    show = function(_, w) table.insert(shown, w) end,
    close = function(_, w) closed[w] = true end,
    forceRePaint = function() end,
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
            readSetting = function(self, k) return self.data[k] end,
        }
    end,
})
stub("socket.http", S.Http.new())
stub("apps/reader/readerui", { instance = { statistics = stats } })
stub("ui/widget/confirmbox", { new = function(_, o) o.confirm = true; return o end })
stub("ui/widget/infomessage", { new = function(_, o) return o end })
stub("ui/widget/textviewer", { new = function(_, o) return o end })
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
-- Where KOReader changes a book's status without an event (see main.lua).
local fmu = { saveSummary = function(ds) return ds, "second" end }
stub("apps/filemanager/filemanagerutil", fmu)
local status_widget = { onClose = function() return true end }
stub("ui/widget/bookstatuswidget", status_widget)

package.path = "concordance.koplugin/?.lua;" .. package.path

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

local Concordance = dofile("concordance.koplugin/main.lua")
local menu_items = {}
local ui = { menu = { registerToMainMenu = function(_, p) p:addToMainMenu(menu_items) end } }
local plugin = setmetatable({ ui = ui }, Concordance)
plugin:init()
local function wasShown(text)
    for _, w in ipairs(shown) do
        if w.text and w.text:find(text, 1, true) then return true end
    end
end

local menu = menu_items.concordance
check(menu and menu.sorting_hint == "tools", "menu entry under Tools")
-- item("Folder on server") at the top; item("Statistics", "Sync now") in a submenu.
local function item(...)
    local path = { ... }
    local list = menu.sub_item_table_func()
    for i, text in ipairs(path) do
        local found
        for _, it in ipairs(list) do
            local t = it.text or (it.text_func and it.text_func())
            if t and t:find(text, 1, true) then found = it break end
        end
        if not found or i == #path then return found end
        list = found.sub_item_table or found.sub_item_table_func()
    end
end
check(item("Check for updates") and item("Automatic updates"), "update items in the menu")

-- Updates for both plugins are checked together (concordance/updates.lua,
-- tested in test_concordance_updates.lua): Athenaeum joins when loaded.
local Updates = require("concordance/updates")
check(Updates.active() and #plugin:updateEntries() == 1, "no Athenaeum: Concordance only")
local cl_updater = { check = function() end, defers_to_concordance = true }
package.loaded["athenaeum/updater"] = cl_updater
ui.athenaeum = { path = TMP .. "/plugins/athenaeum.koplugin", version = "0.3.0" }
local entries = plugin:updateEntries()
check(#entries == 2 and entries[2].updater == cl_updater and entries[2].plugin == ui.athenaeum
    and not entries[2].own_automatic, "Athenaeum checked with its own updater")
cl_updater.defers_to_concordance = nil
check(plugin:updateEntries()[2].own_automatic, "an older Athenaeum keeps its automatic check")
ui.athenaeum, package.loaded["athenaeum/updater"] = nil, nil
check(menu.sub_item_table_func()[1].text == "Sync now" and item("Statistics", "Sync now")
    and item("Highlights and books", "Sync now"), "a top-level Sync now and one per kind")

local P = require("concordance/plugin")
local function fileData(name) return dofile(dev.dir .. "/" .. name) end
local saved = fileData("concordance/settings.lua")
check(saved.allow_wifi == false and saved.time_limit == 120, "saved settings read")
check(item("Folder on server: /KOReader"), "default folder shown in the menu")
check(P.autoStats() and P.autoAnnotations(), "automatic syncs on by default")

-- The first server is Dropbox: fine for settings, not for statistics.
check(item("Server: Box (Dropbox)"), "first server used when none chosen")
item("Statistics", "Sync now").callback()
check(wasShown("need a WebDAV server"), "statistics on Dropbox: told why")
local sub = item("Server:").sub_item_table_func()
check(#sub == 2 and sub[1].checked_func() and not sub[2].checked_func(), "Dropbox and WebDAV servers offered")
sub[2].callback()
check(fileData("concordance/settings.lua").server.name == "My DAV" and fileData("concordance/settings.lua").server.password == nil,
    "chosen server kept by name, no credentials")
check(item("Server: My DAV (WebDAV)"), "chosen server shown")
check(P.serverLocation() == server.url .. "/KOReader/Reading/", "location: " .. tostring(P.serverLocation()))
check(P.serverLocation({ address = "https://me:secret@dav.example.com/dav/" })
    == "https://dav.example.com/dav/KOReader/Reading/", "location shown without credentials")

-- Automatic sync is on: the start-up trigger syncs both, flushing the open book first.
loop:run(60)
local st = P.deviceState().status
check(st and st.last_success and not st.last_error, "automatic sync at start succeeded: " .. tostring(st and st.last_error))
check(st and st.uploaded_events == 3, "the unsaved page times were flushed and sent (" .. tostring(st and st.uploaded_events) .. ")")
check(st.stats_last_success and st.ann_last_success and st.ann_uploaded == 1, "statistics and highlights both synced")
check(P.deviceState().ann_scanned ~= nil, "reading history read before the first sync of highlights")
local id = P.deviceState().device_id
check(fileData("concordance/device.lua").device_id == id and fileData("concordance/settings.lua").device_id == nil,
    "device ID saved in concordance/device.lua only")
check(id and #id == 16, "device ID created")
local function count(dir, pattern)
    local n = 0
    for name in io.popen("ls " .. S.q(dir) .. " 2>/dev/null"):lines() do
        if name:match(pattern) then n = n + 1 end
    end
    return n
end
local DAVDIR = server.dir .. "/KOReader/Reading/devices/"
check(count(DAVDIR .. id, "^seg%-") == 1 and count(DAVDIR .. id, "^ann%-") == 1 and count(DAVDIR .. id, "^book%-") == 1,
    "compressed segments on the server under KOReader/Reading")
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
local Store = require("concordance/store")
local WebDav = require("concordance/webdav")
local ost = Store.new{ sq3 = S.SQ3, stats_path = other.db, state_path = other.state }
local seg = TMP .. "/other.jsonl"
ost:export{ device_id = "otherdev", out_path = seg, now = 1, max_events = 1000 }
local dav = WebDav.new{ http = S.Http.new(), address = server.url, username = "u", password = "p", root = "KOReader/Reading" }
check(require("concordance/zstd").compressFile(seg, seg .. ".zst"), "other device's segment compressed")
dav:mkdir("devices/otherdev")
check(dav:put_new("devices/otherdev/seg-0000000001.jsonl.zst", seg .. ".zst"), "other device's segment uploaded")
local time_before = stats.book_read_time
stats.page_stat = {}
local ann_success = P.deviceState().status.ann_last_success
S.sleep(1.1)
item("Statistics", "Sync now").callback()
local syncing = shown[#shown]
check(syncing and syncing.text == "Syncing statistics…", "manual sync says it's syncing: " .. tostring(syncing and syncing.text))
loop:run(60)
check(closed[syncing], "syncing message closed when the result is shown")
check(shown[#shown] and shown[#shown].text:find("^Statistics synced") and not shown[#shown].text:find("Highlights"),
    "statistics sync reports statistics only: " .. tostring(shown[#shown] and shown[#shown].text))
check(P.deviceState().status.imported_events == 2, "two events imported")
check(shown[#shown].text == "Statistics synced.\nStatistics: received 2 entries from 1 files.",
    "only what changed is reported: " .. shown[#shown].text)
S.sleep(1.1)
item("Statistics", "Sync now").callback()
loop:run(60)
check(shown[#shown].text == "Statistics synced.\nNothing new to send or receive.",
    "nothing changed: " .. shown[#shown].text)
check(P.deviceState().status.ann_last_success == ann_success, "highlights not synced with statistics")
check(stats.book_read_time > time_before, "open book's cached totals refreshed ("
    .. tostring(time_before) .. " -> " .. tostring(stats.book_read_time) .. ")")
check(P.deviceState().status.devices == 2, "two devices seen")

-- Automatic statistics off: automatic syncs do highlights only.
item("Statistics", "Sync automatically").callback()
check(fileData("concordance/settings.lua").auto_stats == false, "automatic statistics off, saved")
local stats_success = P.deviceState().status.stats_last_success
S.sleep(1.1)
plugin:onNetworkConnected()
loop:run(60)
st = P.deviceState().status
check(st.stats_last_success == stats_success and st.ann_last_success > ann_success and not st.last_error,
    "automatic sync: highlights only")
item("Highlights and books", "Sync automatically").callback()
before = st.last_attempt
S.sleep(1.1)
plugin:onNetworkConnected()
loop:run(10)
check(P.deviceState().status.last_attempt == before, "both automatic syncs off: nothing synced")
item("Statistics", "Sync automatically").callback()
item("Highlights and books", "Sync automatically").callback()
check(P.autoStats() and P.autoAnnotations(), "both on again")

-- Status, rebuild
item("Status").callback()
check(shown[#shown].text:find("Devices seen: 2", 1, true), "status shows devices seen")
check(shown[#shown].title == "Concordance status" and shown[#shown].text:find("^Overview\n   Last attempt: "),
    "status opens with the overview")
check(shown[#shown].text:find("Statistics and highlights folder: " .. server.url .. "/KOReader/Reading/", 1, true),
    "status shows the folder")
item("Troubleshooting", "Rebuild from server").callback()
shown[#shown].ok_callback()
loop:run(60)
check(P.deviceState().status.imported_events == 5, "rebuild re-imported both devices' segments (3 + 2 events, got "
    .. tostring(P.deviceState().status.imported_events) .. ")")
check(dev:totalsMatch(), "totals still match after rebuild")

-- A database that doesn't know its folder (moved on the server, files and
-- all): the next folder with this device's files is taken as the same place.
Store.new{ sq3 = S.SQ3, stats_path = dev.db, state_path = dev.dir .. "/concordance/state.sqlite3" }:forgetLocation()
local function cp(from, to) os.execute("cp -r " .. S.q(from) .. " " .. S.q(to)) end
S.mkdirp(server.dir .. "/Moved")
cp(server.dir .. "/" .. (P.settings().root or "KOReader"):gsub("^/", "") .. "/Reading", server.dir .. "/Moved/Reading")
local own_files = count(server.dir .. "/Moved/Reading/devices/" .. id, "%.zst$")
-- First a folder without this device's files (the copy not made yet, or
-- the wrong folder): stopped before writing anything, and asked.
P.settings().root = "/Empty"
P.saveSettings()
item("Statistics", "Sync now").callback()
loop:run(60)
local q0 = shown[#shown]
check(q0 and q0.confirm and q0.text:find("files aren't in the folder"), "folder without this device's files: asked: "
    .. tostring(q0 and q0.text))
check(not io.open(server.dir .. "/Empty/Reading/devices/" .. id), "nothing written there")
-- Then the folder with the copied files.
P.settings().root = "/Moved"
P.saveSettings()
item("Statistics", "Sync now").callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.uploaded_events == 0, "nothing sent again to the copied folder: "
    .. tostring(st.uploaded_events) .. ", " .. tostring(st.last_error))
check(count(server.dir .. "/Moved/Reading/devices/" .. id, "%.zst$") == own_files, "no new files")
item("Highlights and books", "Sync now").callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.ann_uploaded == 0, "no highlights sent again either")

-- Asked again for another folder without its files, the user sends everything there.
Store.new{ sq3 = S.SQ3, stats_path = dev.db, state_path = dev.dir .. "/concordance/state.sqlite3" }:forgetLocation()
P.settings().root = "/Fresh"
P.saveSettings()
item("Statistics", "Sync now").callback()
loop:run(60)
q0 = shown[#shown]
check(q0 and q0.confirm and q0.ok_text == "Send everything", "asked again")
q0.ok_callback()
loop:run(60)
st = P.deviceState().status
check(not st.last_error and st.uploaded_events == 5, "send everything: all 5 entries sent ("
    .. tostring(st.uploaded_events) .. ", " .. tostring(st.last_error) .. ")")
check(io.open(server.dir .. "/Fresh/Reading/devices/" .. id .. "/seg-0000000001.jsonl.zst") ~= nil,
    "segment in the new folder")

-- Highlights and bookmarks ----------------------------------------------------------------
local FRESH = "Fresh/Reading"
local dev_id = id
local function annSegs() return count(server.dir .. "/" .. FRESH .. "/devices/" .. dev_id, "^ann%-%d+%.jsonl%.zst$") end
local segs0 = annSegs()
check(segs0 == 1, "highlights sent to the new folder (" .. segs0 .. ")")
check(not item("Removed highlights waiting"), "no held removals: no item")

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
local AnnFormat = require("concordance/annformat")
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
check(require("concordance/zstd").compressFile(other_seg, other_seg .. ".zst"), "other device's annotations compressed")
fresh:mkdir("devices/otherdev")
check(fresh:put_new("devices/otherdev/ann-0000000001.jsonl.zst", other_seg .. ".zst"), "other device's annotations uploaded")
item("Highlights and books", "Sync now").callback()
loop:run(60)
check(#reader.annotation.annotations == 2, "applied live to the open book (" .. #reader.annotation.annotations .. ")")
local ev = events[#events]
check(ev and ev.name == "AnnotationsModified" and ev.args.nb_highlights_added == 1, "AnnotationsModified sent")
check(shown[#shown].text:find("Highlights and bookmarks: received 1 changes.", 1, true)
    and not shown[#shown].text:find(" 0 ", 1, true), "manual sync reports annotations: " .. shown[#shown].text)
-- The reader plugin instance: a new highlight, then the book closes
local reader_plugin = setmetatable({ ui = reader }, Concordance)
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
check(item("Removed highlights waiting"), "held removals: menu item shown")
item("Status").callback()
check(shown[#shown].text:find("Books with removals waiting for you: 1", 1, true), "status shows the held book")
check(shown[#shown].text:find("Book status and details\n   Books: 1\n", 1, true),
    "status shows book data")
package.loaded["apps/reader/readerui"].instance = reader
q.choice1_callback() -- restore them here
check(#reader.annotation.annotations == 6, "restored in the open book")
check(not item("Removed highlights waiting"), "nothing held any more")
package.loaded["apps/reader/readerui"].instance = { statistics = stats }

-- Opening a book syncs, so other devices get it in their history: only
-- while Wi-Fi is on, and not if the book is closed first (closing syncs).
do
    local real, reasons = Concordance.trigger, {}
    Concordance.trigger = function(reason, what, interactive, scanned, refreshed)
        -- Not its own calls back into itself, after reading what changed.
        if not scanned and not refreshed then reasons[#reasons + 1] = reason end
        return real(reason, what, interactive, scanned, refreshed)
    end
    reader_plugin:onReaderReady()
    loop:run(60)
    check(#reasons == 1 and reasons[1] == "open", "opening a book syncs (" .. table.concat(reasons, ",") .. ")")
    local opened = P.deviceState().status
    check(opened.last_success and not opened.last_error, "sync on opening succeeded: " .. tostring(opened.last_error))
    connected = false
    reasons = {}
    reader_plugin:onReaderReady()
    loop:run(10)
    check(#reasons == 0 and not connected, "offline: opening a book doesn't sync or turn Wi-Fi on")
    connected = true
    reasons = {}
    reader_plugin:onReaderReady()
    -- The book is ready, the sync for opening it still waiting.
    loop:run(5, function() return reader_plugin.open_tick ~= nil end)
    check(reader_plugin.open_tick ~= nil, "sync for opening the book waiting")
    reader_plugin:onCloseDocument()
    loop:run(60)
    check(#reasons == 1 and reasons[1] == "close", "closed straight away: only the closing sync (" .. table.concat(reasons, ",") .. ")")
    Concordance.trigger = real
end

-- Athenaeum's files and matches.
S.writeFile(TMP .. "/cloud-book.epub", "not really an epub")
S.writeFile(TMP .. "/cloud-book.pdf", "%PDF")
local U = "00000000-0000-4000-8000-0000000000aa"
package.loaded["athenaeum/library"] = {
    localFiles = function() return { TMP .. "/cloud-book.epub", TMP .. "/cloud-book.pdf", TMP .. "/gone.epub" } end,
    links = function() return { { path = TMP .. "/cloud-book.pdf", md5 = "pdfmd5", uuids = { U }, title = "A PDF" } } end,
}
local files = {}
for _, f in ipairs(P.identityFiles()) do files[f.path] = f end
check(files[TMP .. "/cloud-book.epub"] and files[TMP .. "/cloud-book.epub"].md5 == nil
    and not files[TMP .. "/cloud-book.pdf"] and not files[TMP .. "/gone.epub"],
    "Athenaeum's EPUBs read for their identity, not yet opened")
check(select(2, P.identityFiles()) == true, "the list is complete")
-- Athenaeum hasn't read its catalog (KOReader started in a book): its
-- files aren't listed, and the list says it's incomplete.
package.loaded["athenaeum/library"].isLoaded = function() return false end
local partial, complete = P.identityFiles()
local n_cloud = 0
for _, f in ipairs(partial) do if f.path == TMP .. "/cloud-book.epub" then n_cloud = n_cloud + 1 end end
check(n_cloud == 0 and complete == false, "Athenaeum's catalog not read: list marked incomplete")
package.loaded["athenaeum/library"].isLoaded = function() return true end
check(select(2, P.identityFiles()) == true, "catalog read: complete again")
P.engine().deps.id.collect()
local Identity = require("concordance/identity")
check(Identity.available(), "identity set up for other plugins")
local iconn = P.idStore():open()
check(iconn:rowexec("SELECT count(*) FROM id_facts WHERE md5 = 'pdfmd5' AND src = 'link'") == 1,
    "Athenaeum's matches recorded as links")
iconn:close()
-- The match is no longer made (the file is still there, the book still in
-- the catalog): the next sync withdraws the link.
local cl = package.loaded["athenaeum/library"]
cl.links = function() return {} end
cl.folderFiles = function() return { { path = TMP .. "/cloud-book.pdf", md5 = "pdfmd5" } } end
cl.inCatalog = function(u) return u == U end
cl.isLoaded = function() return false end
P.engine().deps.id.collect()
iconn = P.idStore():open()
check(iconn:rowexec("SELECT count(*) FROM id_facts WHERE src = 'unlink'") == 0, "catalog not read: no link withdrawn")
iconn:close()
cl.isLoaded = function() return true end
P.engine().deps.id.collect()
iconn = P.idStore():open()
check(iconn:rowexec("SELECT count(*) FROM id_facts WHERE md5 = 'pdfmd5' AND src = 'unlink'") == 1,
    "a match Athenaeum no longer makes is withdrawn")
iconn:close()
package.loaded["athenaeum/library"] = nil

-- ZenOS's Home is a page over the file browser: history and collections
-- from other devices arrive while it's shown, but not under a menu.
do
    local um = package.loaded["ui/uimanager"]
    local old_top, old_fm = um.getTopmostVisibleWidget, package.loaded["apps/filemanager/filemanager"]
    local old_sources = package.loaded["common/book_sources"]
    -- ZenOS's real config: a features table, with no home_page in it (Home
    -- can't be turned off).
    local fm = { zenos = { config = { features = { history = true, navbar = true } } } }
    local home_widget, menu = {}, {}
    local top = menu
    um.getTopmostVisibleWidget = function() return top end
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    check(not P._uiIdle(), "busy under a menu")
    top = fm
    check(P._uiIdle(), "idle in the file browser")
    top = home_widget
    check(not P._uiIdle(), "busy under an unknown page without ZenOS")
    package.loaded["common/book_sources"] = { isHomeOnTop = function() return top == home_widget end }
    check(P._uiIdle(), "idle on ZenOS's Home")
    top = menu
    check(not P._uiIdle(), "busy under a menu over ZenOS's Home")
    um.getTopmostVisibleWidget = old_top
    package.loaded["apps/filemanager/filemanager"] = old_fm
    package.loaded["common/book_sources"] = old_sources
end

-- After books went into the history: ZenOS told first (it redraws the file
-- browser itself), else the file browser redrawn; an open History list
-- either way.
do
    local old_fm = package.loaded["apps/filemanager/filemanager"]
    local old_sources = package.loaded["common/book_sources"]
    local calls = {}
    local fm = {
        file_chooser = { refreshPath = function() calls[#calls + 1] = "refreshPath" end },
        history = { booklist_menu = {}, updateItemTable = function() calls[#calls + 1] = "history" end },
    }
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    package.loaded["common/book_sources"] = nil
    P._refreshAfterHistory({ "/b/one.epub" })
    check(table.concat(calls, ",") == "refreshPath,history", "no ZenOS: file browser and History redrawn: "
        .. table.concat(calls, ","))
    calls = {}
    local told
    package.loaded["common/book_sources"] = { historyChanged = function(paths)
        told = paths
        calls[#calls + 1] = "zenos"
    end }
    P._refreshAfterHistory({ "/b/one.epub" })
    check(table.concat(calls, ",") == "zenos,history" and told and told[1] == "/b/one.epub",
        "ZenOS: told first, redraws the file browser itself: " .. table.concat(calls, ","))
    calls = {}
    package.loaded["apps/filemanager/filemanager"] = { instance = nil }
    P._refreshAfterHistory({ "/b/one.epub" })
    check(table.concat(calls, ",") == "zenos", "ZenOS told even with no file browser (in the reader)")
    calls = {}
    package.loaded["apps/filemanager/filemanager"] = { instance = fm }
    package.loaded["common/book_sources"] = { historyChanged = function() error("boom") end }
    P._refreshAfterHistory({ "/b/one.epub" })
    check(table.concat(calls, ",") == "refreshPath,history", "ZenOS failing: file browser redrawn by us")
    package.loaded["apps/filemanager/filemanager"] = old_fm
    package.loaded["common/book_sources"] = old_sources
end

-- ZenOS's incognito mode: its shared config, or its plugin in the file browser or reader.
do
    local old_fm, old_rui = package.loaded["apps/filemanager/filemanager"], package.loaded["apps/reader/readerui"]
    local old_mgr = package.loaded["config/manager"]
    package.loaded["apps/filemanager/filemanager"] = nil
    package.loaded["config/manager"] = nil
    package.loaded["apps/reader/readerui"] = { instance = nil }
    check(P.incognito() == false, "no ZenOS: not incognito")
    local config = { features = { incognito_mode = false } }
    package.loaded["config/manager"] = { get = function() return config end }
    check(P.incognito() == false, "ZenOS, incognito off")
    config.features.incognito_mode = true
    check(P.incognito() == true, "incognito on (ZenOS's shared config)")
    package.loaded["config/manager"] = { get = function() error("boom") end }
    check(P.incognito() == false, "a failing config/manager: not incognito")
    package.loaded["apps/reader/readerui"] = { instance = { zenos = { config = config } } }
    check(P.incognito() == true, "incognito on (the reader's ZenOS)")
    package.loaded["apps/reader/readerui"] = { instance = nil }
    package.loaded["apps/filemanager/filemanager"] = { instance = { zenos = { config = config } } }
    check(P.incognito() == true, "incognito on (the file browser's ZenOS)")
    package.loaded["apps/filemanager/filemanager"] = { instance = { zenos = { config = { features = "?" } } } }
    check(P.incognito() == false, "an odd config: not incognito")
    package.loaded["apps/filemanager/filemanager"], package.loaded["apps/reader/readerui"] = old_fm, old_rui
    package.loaded["config/manager"] = old_mgr
end

-- Problems with what Concordance reads from ZenOS outside BookSources:
-- incognito mode's setting and the metadata service.
do
    local Problems = require("concordance/problems")
    local old_mgr = package.loaded["config/manager"]
    local old_service = package.loaded["modules/filebrowser/metadata/service"]
    local old_preload = package.preload["modules/filebrowser/metadata/service"]
    local function checkWith(installed, manager)
        Problems.reset()
        P._setZenosInstalled(installed)
        P._resetZenOSCheck()
        package.loaded["config/manager"] = manager
        return P.checkZenOS()
    end
    local function mgr(config) return { get = function() return config end } end

    check(checkWith(false, nil) == 0 and not Problems.has("zenos:incognito"), "no ZenOS: nothing to check")
    check(checkWith(true, mgr({ features = { incognito_mode = false } })) == 0
        and not Problems.has("zenos:incognito"), "ZenOS's config as expected: no problem")
    check(checkWith(true, nil) == 1 and Problems.has("zenos:incognito"), "ZenOS without config/manager: a problem")
    check(checkWith(true, mgr({ features = {} })) == 1 and Problems.has("zenos:incognito"),
        "incognito_mode renamed: a problem")
    check(checkWith(true, mgr({ features = "?" })) == 1, "no features table: a problem")
    check(checkWith(true, { get = function() error("boom") end }) == 1, "a failing get: a problem")
    Problems.reset()
    P._resetZenOSCheck()
    check(P.checkZenOS() == 1 and P.checkZenOS() == 0, "checked once per run")

    -- At run time: a get that fails is reported too.
    Problems.reset()
    package.loaded["config/manager"] = { get = function() error("boom") end }
    check(P.incognito() == false and Problems.has("zenos:incognito"), "incognito(): a failing get reported")

    -- The metadata service missing: reported only when ZenOS is installed.
    package.loaded["modules/filebrowser/metadata/service"] = nil
    package.preload["modules/filebrowser/metadata/service"] = function() error("moved") end
    Problems.reset()
    P._setZenosInstalled(false)
    check(P.installMetadataHook() == false and not Problems.has("zenos:editsEmbedded"),
        "no ZenOS: no metadata service, no problem")
    Problems.reset()
    P._setZenosInstalled(true)
    check(P.installMetadataHook() == false and Problems.has("zenos:editsEmbedded"),
        "ZenOS without its metadata service: a problem")

    package.preload["modules/filebrowser/metadata/service"] = old_preload
    package.loaded["modules/filebrowser/metadata/service"] = old_service
    package.loaded["config/manager"] = old_mgr
    P._setZenosInstalled(nil)
    P._resetZenOSCheck()
    Problems.reset()
end

-- The device's name: progress sync's "Device hostname", else the model.
do
    local kosync = dev.dir .. "/kosync.lua"
    os.remove(kosync)
    check(P.deviceName() == "Test device", "no progress sync settings: the device model")
    S.writeFile(kosync, 'return { settings = { kosync_hostname = "  Bedside Kobo " } }\n')
    check(P.deviceName() == "Bedside Kobo", "progress sync's device hostname, trimmed")
    S.writeFile(kosync, 'return { settings = { kosync_hostname = "   " } }\n')
    check(P.deviceName() == "Test device", "blank hostname: the device model")
    S.writeFile(kosync, 'return { settings = { auto_sync = true } }\n')
    check(P.deviceName() == "Test device", "no hostname set: the device model")
    os.remove(kosync)
end

-- Plugin versions, from the _meta.lua files.
do
    local function metaVersion(path)
        return S.readFile(path):match('version%s*=%s*"([^"]+)"')
    end
    local v = P.pluginVersions()
    check(v and v.concordance == metaVersion("concordance.koplugin/_meta.lua"), "Concordance's version")
    check(v.athenaeum == metaVersion("athenaeum.koplugin/_meta.lua"), "Athenaeum's version, when installed")
    settings_data.plugins_disabled = { athenaeum = true }
    check(P.pluginVersions().athenaeum == nil, "no Athenaeum version when it's turned off")
    settings_data.plugins_disabled = nil

    -- KOReader's version and ZenOS's.
    local old_version = package.loaded["version"]
    package.loaded["version"] = { getShortVersion = function() return "2025.10-58" end }
    local plugins = TMP .. "/versions-plugins"
    S.mkdirp(plugins .. "/zenos.koplugin")
    check(P.pluginVersions(plugins).zenos == nil, "no ZenOS version when it isn't installed")
    S.writeFile(plugins .. "/zenos.koplugin/_meta.lua",
        'return {\n    name = "zenos",\n    version = "4.3.1",\n    fullname = "ZenOS",\n}\n')
    v = P.pluginVersions(plugins)
    check(v.zenos == "4.3.1", "ZenOS's version: " .. tostring(v.zenos))
    check(v.koreader == "2025.10-58", "KOReader's version: " .. tostring(v.koreader))
    settings_data.plugins_disabled = { zenos = true }
    check(P.pluginVersions(plugins).zenos == nil, "no ZenOS version when it's turned off")
    settings_data.plugins_disabled = nil
    os.remove(plugins .. "/zenos.koplugin/_meta.lua")
    S.mkdirp(plugins .. "/zen_ui.koplugin")
    S.writeFile(plugins .. "/zen_ui.koplugin/_meta.lua", 'return { name = "zen_ui", version = "3.9.0" }\n')
    check(P.pluginVersions(plugins).zenos == "3.9.0", "ZenOS under its old folder name")
    package.loaded["version"] = { getShortVersion = function() return "unknown" end }
    check(P.pluginVersions(plugins).koreader == nil, "no KOReader version when it isn't known")
    package.loaded["version"] = { getShortVersion = function() error("no git-rev") end }
    check(P.pluginVersions(plugins).koreader == nil, "no KOReader version when reading it fails")
    package.loaded["version"] = old_version
end

-- A book's status, rating or metadata changed here: a sync soon.
do
    local Pl = package.loaded["concordance/plugin"]
    local triggered = {}
    local real_trigger = Concordance.trigger
    Concordance.trigger = function(reason, what) triggered[#triggered + 1] = { reason = reason, what = what } end
    -- main.lua was loaded twice above: the hooks call the latest one's.
    local real_changed = Pl.onBookChanged
    Pl.onBookChanged = Concordance.bookChanged
    local function newTask(n_before)
        return #loop.tasks > n_before and loop.tasks[#loop.tasks].fn or nil
    end
    local function due()
        local t = loop.tasks[#loop.tasks]
        loop:unschedule(t.fn)
        t.fn()
    end
    connected = true
    local n = #loop.tasks
    local a, b = fmu.saveSummary("ds", {})
    check(a == "ds" and b == "second", "saveSummary still returns what it did")
    check(newTask(n) and math.abs(loop:pending(newTask(n)) - 3) < 0.5, "status changed: a sync in 3 seconds")
    fmu.saveSummary("ds", {})
    check(#loop.tasks == n + 1, "changes together: one sync")
    due()
    check(#triggered == 1 and triggered[1].reason == "change" and triggered[1].what.ann
        and not triggered[1].what.stats, "highlights and books synced")
    status_widget.onClose({ updated = true })
    due()
    check(#triggered == 2, "the reader's book status page changed something: synced")
    n = #loop.tasks
    status_widget.onClose({ updated = false })
    check(#loop.tasks == n, "nothing changed there: no sync")
    plugin:onBookMetadataChanged()
    due()
    check(#triggered == 3, "metadata edited: synced")
    n = #loop.tasks
    local bs = Pl.bookSync()
    bs.broadcasting = true
    plugin:onBookMetadataChanged()
    bs.broadcasting = false
    check(#loop.tasks == n, "Concordance applying changes: no sync")
    Pl.onBookChanged()
    connected = false
    due()
    check(#triggered == 4 - 1, "Wi-Fi off: no sync (never turned on for this)")
    connected = true
    local auto = Pl.settings().auto_annotations
    Pl.settings().auto_annotations = false
    fmu.saveSummary("ds", {})
    check(#loop.tasks == n, "automatic syncs of highlights and books off: no sync")
    Pl.settings().auto_annotations = auto
    Concordance.trigger = real_trigger
    Pl.onBookChanged = real_changed
end

server.stop()
-- Reset device ID
item("Troubleshooting", "Reset device ID").callback()
shown[#shown].ok_callback()
check(P.deviceState().device_id ~= id, "device ID reset")

S.finish("concordance plugin test")
