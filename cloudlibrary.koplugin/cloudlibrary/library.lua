--[[
Ties the pieces together: settings, the catalog store, syncing in a
subprocess, matching local files, and the virtual entries shown in the file
browser.

Settings (G_reader_settings "cloudlibrary"):
  server     { url, username } of one of KOReader's OPDS catalogs
  folder     library folder (default: KOReader's download folder, else home)
  show       show cloud books (default true)
  auto_sync  sync when the file browser opens and Wi-Fi is on (default true)

The password stays in KOReader's OPDS settings and is read from there.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local Covers = require("cloudlibrary/covers")
local Matcher = require("cloudlibrary/matcher")
local Store = require("cloudlibrary/store")
local Timing = require("cloudlibrary/timing")
local Virtual = require("cloudlibrary/virtual")

Virtual.canFetchCovers = Covers.canFetch
Virtual.requestCovers = Covers.request
Virtual.coversBusy = Covers.busy

local Library = {
    job = nil,          -- running sync: { pid, fd, mode, started }
    last_result = nil,  -- last job's result table
    stats = {},         -- counts from the last load
}

local QUICK_INTERVAL = 60 * 60       -- auto sync at most hourly
local FULL_INTERVAL = 24 * 60 * 60   -- and a full sync daily
local PREFETCH_COVERS = 300          -- covers downloaded by each sync, newest first
local PREFETCH_SECONDS = 180

-- Settings ----------------------------------------------------------------------

function Library.settings()
    return G_reader_settings:readSetting("cloudlibrary", {})
end

function Library.save(key, value)
    local s = Library.settings()
    s[key] = value
    G_reader_settings:saveSetting("cloudlibrary", s)
end

function Library.opdsServers()
    local path = DataStorage:getSettingsDir() .. "/opds.lua"
    local servers = LuaSettings:open(path):readSetting("servers") or {}
    local out = {}
    for _i, s in ipairs(servers) do
        if type(s) == "table" and type(s.url) == "string" and s.url ~= "" then
            table.insert(out, s)
        end
    end
    return out
end

--- The chosen OPDS catalog, with its password, or nil.
function Library.server()
    local chosen = Library.settings().server
    if type(chosen) ~= "table" then return nil end
    for _i, s in ipairs(Library.opdsServers()) do
        if s.url == chosen.url and (s.username or "") == (chosen.username or "") then
            return s
        end
    end
end

function Library.folder()
    local folder = Library.settings().folder
        or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
    return folder and (folder:gsub("/+$", ""))
end

local function serverKey(server)
    return require("ffi/sha2").md5((server.url or "") .. "\0" .. (server.username or ""))
end

function Library.dbPath(server)
    local dir = DataStorage:getSettingsDir() .. "/cloudlibrary"
    util.makePath(dir)
    return dir .. "/" .. serverKey(server) .. ".sqlite3"
end

function Library.coversDir(server)
    return DataStorage:getSettingsDir() .. "/cloudlibrary/" .. serverKey(server) .. "-covers"
end

local function openStore(server)
    return Store.open(Library.dbPath(server), Device:canUseWAL())
end

-- Loading into the file browser --------------------------------------------------

-- Updating the folder's timestamp makes file browsers (ZenOS included) drop
-- their saved listing, so only do it when the cloud books shown changed.
local function showCatalog(folder, cloud)
    Virtual.setCatalog(folder, cloud)
    local ids = {}
    for _i, b in ipairs(cloud) do table.insert(ids, b.id .. "\t" .. (b.title or "")) end
    table.sort(ids)
    local sig = require("ffi/sha2").md5((folder or "") .. "\n" .. table.concat(ids, "\n"))
    if Library.settings().listing_sig ~= sig then
        Library.save("listing_sig", sig)
        Virtual.refresh()
    end
end

--- Reads the catalog, matches local files, and updates the cloud books shown.
function Library.load()
    local server, folder = Library.server(), Library.folder()
    local s = Library.settings()
    if not server or not folder or s.show == false then
        Library.stats = {}
        Covers.configure(nil)
        showCatalog(folder, {})
        return
    end
    local t_load = Timing.start()
    local covers_dir = Library.coversDir(server)
    Covers.configure{ server = server, db_path = Library.dbPath(server), dir = covers_dir,
        wal = Device:canUseWAL() }
    local t0 = Timing.start()
    local store = openStore(server)
    local books = store:listing()
    local with_cover, downloaded = store:coverCounts()
    for _i, b in ipairs(books) do
        if b.cover_file then b.cover = covers_dir .. "/" .. b.cover_file end
    end
    local files = store:localFiles()
    store:close()
    Timing.record("catalog: read database", Timing.since(t0), #books .. " books")
    t0 = Timing.start()
    local matched, unmatched = Matcher.match(folder, files, books)
    Timing.record("catalog: match local files", Timing.since(t0))
    local cloud = {}
    for _i, b in ipairs(books) do
        if not matched[b.id] then table.insert(cloud, b) end
    end
    Library.matched = matched
    Library.stats = {
        catalog = #books, cloud = #cloud, on_device = #books - #cloud,
        unmatched_files = #unmatched,
        covers = downloaded, covers_available = with_cover,
    }
    logger.info("CloudLibrary: loaded", Library.stats)
    t0 = Timing.start()
    showCatalog(folder, cloud)
    Timing.record("catalog: show in folder", Timing.since(t0))
    Timing.record("catalog: load", Timing.since(t_load),
        string.format("%d cloud books, %d on this device", #cloud, #books - #cloud))
end

--- Full details for the details sheet (summary, formats...).
function Library.bookDetails(id)
    local server = Library.server()
    if not server then return nil end
    local store = openStore(server)
    local book = store:getBook(id)
    store:close()
    return book
end

-- Syncing ----------------------------------------------------------------------

local function runJob(server, folder, mode, db_path, wal, covers_dir)
    local Sync = require("cloudlibrary/sync")
    local Http = require("cloudlibrary/http")
    local result = { mode = mode }
    local store = Store.open(db_path, wal)
    local ok, err = pcall(function()
        if mode == "covers" or mode == "prefetch" then
            util.makePath(covers_dir)
            local opts = mode == "prefetch"
                and { limit = PREFETCH_COVERS, deadline = os.time() + PREFETCH_SECONDS } or nil
            result.covers = Covers.downloadMissing(Http.fetcher(server), server.url, store, covers_dir, opts)
            result.covers.results = nil
            return
        end
        if mode ~= "scan" then
            local sync = Sync.new{ store = store, root = server.url, fetch = Http.fetcher(server) }
            local r, serr
            if mode == "full" then
                r, serr = sync:full()
            else
                r, serr = sync:quick()
                local last_full = tonumber(store:getMeta("last_full_sync")) or 0
                if r and (r.needs_full or os.time() - last_full > FULL_INTERVAL) then
                    r, serr = sync:full()
                    if r then r.escalated = true end
                end
            end
            result.sync, result.error = r, serr
            if r and r.deleted then Covers.cleanup(store, covers_dir) end
        end
        if folder then
            local t0 = Timing.start()
            result.scanned = Matcher.scan(folder, store)
            result.scan_ms = Timing.since(t0)
        end
    end)
    store:close()
    if not ok then result.error = tostring(err) end
    return result
end

function Library.isSyncing()
    return Library.job ~= nil
end

local function notify(text)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

local function describeResult(r)
    if r.error then return T(_("Cloud library sync failed: %1"), r.error) end
    if r.mode == "covers" and r.covers then
        return T(_("Cloud library: %1 covers downloaded."), r.covers.fetched)
    end
    local s = r.sync
    if not s then return _("Cloud library: device books checked.") end
    if s.deleted ~= nil then
        return T(_("Cloud library: %1 books (%2 new, %3 removed)."), s.total, s.added, s.deleted)
    end
    if s.added > 0 then return T(_("Cloud library: %1 new books."), s.added) end
    return _("Cloud library is up to date.")
end

--- Starts a sync in a subprocess. mode: "quick", "full", "scan" (local
-- files only), "covers" (all missing covers) or "prefetch" (some). quiet: no notifications unless something changed or failed.
function Library.sync(mode, quiet)
    if Library.job then
        if not quiet then notify(_("Cloud library: already syncing.")) end
        return false
    end
    local server, folder = Library.server(), Library.folder()
    if not server then
        if not quiet then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Choose your library's OPDS catalog first: Cloud library → Catalog."),
            })
        end
        return false
    end
    local db_path, wal, covers_dir = Library.dbPath(server), Device:canUseWAL(), Library.coversDir(server)
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local result = runJob(server, folder, mode, db_path, wal, covers_dir)
        ffiutil.writeToFD(child_fd, require("dump")(result), true)
    end, true)
    if not pid then
        if not quiet then notify(T(_("Cloud library sync failed: %1"), tostring(fd))) end
        return false
    end
    Library.job = { pid = pid, fd = fd, mode = mode, quiet = quiet, started = os.time(),
        t0 = Timing.start() }
    if not quiet and mode == "covers" then
        notify(_("Cloud library: downloading covers…"))
    elseif not quiet and mode ~= "scan" then
        notify(_("Cloud library: syncing…"))
    end
    UIManager:scheduleIn(1, Library.poll)
    return true
end

function Library.poll()
    local job = Library.job
    if not job then return end
    if not ffiutil.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(1, Library.poll)
        return
    end
    local data = ffiutil.readAllFromFD(job.fd)
    Library.job = nil
    local result
    local chunk = data and data ~= "" and loadstring("return " .. data, "sync result")
    if chunk then
        setfenv(chunk, {})
        local ok, res = pcall(chunk)
        result = ok and type(res) == "table" and res or nil
    end
    result = result or { error = _("the sync stopped unexpectedly") }
    result.finished = os.time()
    Library.last_result = result
    logger.info("CloudLibrary: sync done", result)
    local label = ({ quick = "sync (quick)", full = "sync (full)", scan = "folder check",
        covers = "covers (all)", prefetch = "covers (prefetch)" })[job.mode] or job.mode
    if result.sync and result.sync.escalated then label = "sync (full)" end
    Timing.record(label .. ": job", Timing.since(job.t0), "in the background, from start to result (checked every second)")
    if result.sync then Timing.recordAll(result.sync.timing, label .. ": ") end
    if result.covers then Timing.recordAll(result.covers.timing, label .. ": ") end
    if result.scan_ms then
        Timing.record("folder check: scan files", result.scan_ms,
            string.format("%d files read", result.scanned or 0))
    end
    Library.load()
    local changed = result.sync and ((result.sync.added or 0) > 0 or (result.sync.deleted or 0) > 0)
    if not job.quiet or result.error or changed then
        if (job.mode ~= "scan" and job.mode ~= "prefetch") or result.error then
            notify(describeResult(result))
        end
    end
    -- After a sync, download some missing covers (newest books first).
    if result.sync and not result.error and Covers.canFetch() then
        Library.sync("prefetch", true)
    end
end

--- Called when the file browser opens: load, then sync if it's due.
function Library.onFileManagerReady()
    local t_start = Timing.start()
    Library.load()
    local server = Library.server()
    if not server or Library.job then return end
    local s = Library.settings()
    local due = false
    if s.auto_sync ~= false then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isConnected() then
            local store = openStore(server)
            local last = tonumber(store:getMeta("last_sync")) or 0
            store:close()
            due = os.time() - last > QUICK_INTERVAL
        end
    end
    -- Even without syncing, check the folder for new or changed files.
    Library.sync(due and "quick" or "scan", true)
    Timing.record("startup: plugin", Timing.since(t_start), "catalog load and starting the background check")
end

-- Menu -------------------------------------------------------------------------

local function ago(t)
    t = tonumber(t)
    if not t then return _("never") end
    local d = os.time() - t
    if d < 90 then return _("just now") end
    if d < 90 * 60 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 36 * 3600 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return T(_("%1 days ago"), math.floor(d / 86400))
end

function Library.statusText()
    local server = Library.server()
    local lines = {}
    if not server then
        return _("No catalog chosen.")
    end
    table.insert(lines, T(_("Catalog: %1"), server.title or server.url))
    table.insert(lines, T(_("Folder: %1"), Library.folder() or "?"))
    local store = openStore(server)
    local last, last_full = store:getMeta("last_sync"), store:getMeta("last_full_sync")
    store:close()
    local st = Library.stats
    if st.catalog then
        table.insert(lines, T(_("Books in catalog: %1"), st.catalog))
        table.insert(lines, T(_("On this device: %1"), st.on_device))
        table.insert(lines, T(_("Shown as cloud books: %1"), st.cloud))
        table.insert(lines, T(_("Files in the folder not in the catalog: %1"), st.unmatched_files))
        table.insert(lines, T(_("Covers downloaded: %1 of %2"), st.covers, st.covers_available))
    end
    table.insert(lines, T(_("Last sync: %1"), ago(last)))
    table.insert(lines, T(_("Last full sync: %1"), ago(last_full)))
    local r = Library.last_result
    if r and r.error then table.insert(lines, T(_("Last error: %1"), r.error)) end
    if Library.job then table.insert(lines, _("Syncing now…")) end
    return table.concat(lines, "\n")
end

function Library.menuItems()
    return {
        text = _("Cloud library"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Sync now"),
                    enabled_func = function() return Library.server() ~= nil end,
                    callback = function() Library.sync("quick") end,
                },
                {
                    text = _("Full sync"),
                    help_text = _("Reads the whole catalog again: picks up edited and removed books, and series."),
                    enabled_func = function() return Library.server() ~= nil end,
                    callback = function() Library.sync("full") end,
                },
                {
                    text = _("Download all covers"),
                    help_text = _("Covers are otherwise downloaded as you browse, and some with each sync."),
                    enabled_func = function() return Library.server() ~= nil end,
                    callback = function() Library.sync("covers") end,
                },
                {
                    text = _("Timings"),
                    sub_item_table = {
                        {
                            text = _("Show timings"),
                            keep_menu_open = true,
                            callback = function()
                                local TextViewer = require("ui/widget/textviewer")
                                UIManager:show(TextViewer:new{
                                    title = _("Cloud library timings"),
                                    text = Timing.text(),
                                    monospace_font = false,
                                })
                            end,
                        },
                        {
                            text = _("Reset timings"),
                            keep_menu_open = true,
                            callback = function() Timing.reset() end,
                        },
                    },
                },
                {
                    text = _("Status"),
                    keep_menu_open = true,
                    callback = function()
                        UIManager:show(require("ui/widget/infomessage"):new{ text = Library.statusText() })
                    end,
                    separator = true,
                },
                {
                    text_func = function()
                        local s = Library.server()
                        return T(_("Catalog: %1"), s and (s.title or s.url) or _("none"))
                    end,
                    sub_item_table_func = Library.serverMenu,
                },
                {
                    text_func = function() return T(_("Folder: %1"), Library.folder() or "?") end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local PathChooser = require("ui/widget/pathchooser")
                        UIManager:show(PathChooser:new{
                            select_directory = true,
                            select_file = false,
                            path = Library.folder() or "/",
                            onConfirm = function(path)
                                local old = Library.folder()
                                showCatalog(old, {})
                                Library.save("folder", path)
                                Library.load()
                                Library.sync("scan", true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
                {
                    text = _("Show cloud books"),
                    help_text = _("Turn this off before removing the plugin, so the file browser forgets the cloud books."),
                    checked_func = function() return Library.settings().show ~= false end,
                    callback = function()
                        Library.save("show", Library.settings().show == false)
                        Library.load()
                    end,
                },
                {
                    text = _("Sync automatically"),
                    help_text = _("When the file browser opens and Wi-Fi is on: new books at most hourly, everything daily."),
                    checked_func = function() return Library.settings().auto_sync ~= false end,
                    callback = function()
                        Library.save("auto_sync", Library.settings().auto_sync == false)
                    end,
                },
            }
            return items
        end,
    }
end

function Library.serverMenu()
    local items = {}
    local chosen = Library.settings().server
    for _i, s in ipairs(Library.opdsServers()) do
        table.insert(items, {
            text = s.title or s.url,
            checked_func = function()
                return type(chosen) == "table" and chosen.url == s.url
                    and (chosen.username or "") == (s.username or "")
            end,
            callback = function()
                Library.save("server", { url = s.url, username = s.username })
                chosen = Library.settings().server
                Library.load()
                Library.sync("quick")
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("Add your catalog in the OPDS catalog plugin first."),
            enabled = false,
        })
    end
    return items
end

return Library
