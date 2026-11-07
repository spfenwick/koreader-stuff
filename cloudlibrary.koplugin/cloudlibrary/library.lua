--[[
Ties the pieces together: settings, the catalog store, syncing in a
subprocess, matching local files, and the virtual entries shown in the file
browser.

Settings (settings/cloudlibrary/settings.lua, see settings.lua):
  server     { url, username } of one of KOReader's OPDS catalogs
  folder     library folder (default: KOReader's download folder, else home)
  show       show cloud books (default true)
  auto_sync  sync when the file browser opens and Wi-Fi is on (default true)
  badge_cloud  cloud badge on cloud-only books (default true)
  badge_local  on-device badge on local catalog books (default false)
  search     cloud books in file search results (default true)
  keep_zenos_listing  experimental: keep ZenOS's cached library listing when
             the Library tab is opened from another tab (default true)
  zenos_groups  cloud books in ZenOS's Authors, Series and Tags tabs (default true)

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

local Badge = require("cloudlibrary/badge")
local Covers = require("cloudlibrary/covers")
local Downloads = require("cloudlibrary/downloads")
local ZenListing = require("cloudlibrary/zenos_listing")
local ZenGroups = require("cloudlibrary/zenos_groups")
local Guard = require("cloudlibrary/guard")
local Matcher = require("cloudlibrary/matcher")
local Search = require("cloudlibrary/search")
local Settings = require("cloudlibrary/settings")
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

Library.on_device = {} -- path -> true: local files that are catalog books
Badge.isOnDevice = function(path) return Library.on_device[path] == true end
Badge.isCloud = function(path) return Virtual.by_path[path] ~= nil end

local QUICK_INTERVAL = 60 * 60       -- auto sync at most hourly
local FULL_INTERVAL = 24 * 60 * 60   -- and a full sync daily
local PREFETCH_COVERS = 300          -- covers downloaded by each sync, newest first
local PREFETCH_SECONDS = 180

-- Settings ----------------------------------------------------------------------

-- In settings/cloudlibrary/settings.lua (see settings.lua).
function Library.settings()
    return Settings.all()
end

function Library.save(key, value)
    Settings.save(key, value)
end

--- Redraws the file browser after a badge setting changed (the listing is
-- rebuilt: plain list rows make room for the badge).
function Library.repaint()
    Virtual.refresh()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then UIManager:setDirty(FileManager.instance, "ui") end
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
    -- A refetched cover keeps its file name: don't show the old image.
    Virtual.forgetDecodedCovers()
    local ids = {}
    for _i, b in ipairs(cloud) do table.insert(ids, b.id .. "\t" .. (b.title or "")) end
    table.sort(ids)
    local sig = require("ffi/sha2").md5((folder or "") .. "\n" .. table.concat(ids, "\n"))
    if Library.settings().listing_sig ~= sig then
        Library.save("listing_sig", sig)
        Virtual.refresh()
    end
end

--- True when ZenOS is installed (its menu items only apply then).
function Library.hasZenOS()
    local module = "common/db_bookinfo"
    return package.loaded[module] ~= nil
        or (package.searchpath ~= nil and package.searchpath(module, package.path) ~= nil)
end

--- Library.load() with a message up, for when it's slow (many cloud books
-- to list): closes the menu first, so the screen doesn't look stuck.
function Library.loadShowingProgress(touchmenu_instance)
    if touchmenu_instance then touchmenu_instance:closeMenu() end
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Loading cloud books…"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, err = pcall(Library.load)
    UIManager:close(msg)
    if not ok then error(err, 0) end
end

--- Reads the catalog, matches local files, and updates the cloud books shown.
function Library.load()
    local server, folder = Library.server(), Library.folder()
    local s = Library.settings()
    Badge.cloud_enabled = s.badge_cloud ~= false
    Badge.local_enabled = s.badge_local == true
    Search.enabled = s.search ~= false
    ZenListing.enabled = s.keep_zenos_listing ~= false
    ZenGroups.enabled = s.zenos_groups ~= false
    ZenGroups.install(Virtual)
    if not server or not folder or s.show == false then
        Library.stats = {}
        Library.matched, Library.on_device = {}, {}
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
    local with_cover, downloaded, failed = store:coverCounts()
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
    Library.on_device = {}
    for _id, path in pairs(matched) do Library.on_device[path] = true end
    Library.stats = {
        catalog = #books, cloud = #cloud, on_device = #books - #cloud,
        unmatched_files = #unmatched,
        covers = downloaded, covers_available = with_cover, covers_failed = failed,
    }
    logger.info("CloudLibrary: loaded", Library.stats)
    t0 = Timing.start()
    showCatalog(folder, cloud)
    Timing.record("catalog: show in folder", Timing.since(t0))
    Timing.record("catalog: load", Timing.since(t_load),
        string.format("%d cloud books, %d on this device", #cloud, #books - #cloud))
end

-- Deleting a downloaded book makes it a cloud book again. KOReader sends no
-- event for deletions, so its two delete functions are wrapped; the catalog
-- is reloaded (matching looks at the files actually in the folder) after
-- KOReader's own refresh.
local function inLibrary(path)
    local folder = Library.folder()
    return type(path) == "string" and folder ~= nil
        and (path == folder or path:sub(1, #folder + 1) == folder .. "/")
end

local reload_scheduled = false
local function reloadSoon()
    if reload_scheduled or Library.fixture then return end
    reload_scheduled = true
    UIManager:nextTick(function()
        reload_scheduled = false
        Guard.call("jobs", Library.load)
    end)
end

function Library.installDeleteHooks()
    local FileManager = require("apps/filemanager/filemanager")
    Guard.hook("library", FileManager, "deleteFile", function(orig, self, file, ...)
        local ok = orig(self, file, ...)
        if ok and inLibrary(file) and not Virtual.isVirtual(file) then reloadSoon() end
        return ok
    end, "FileManager:deleteFile")
    Guard.hook("library", FileManager, "deleteSelectedFiles", function(orig, self, ...)
        local any = false
        for path in pairs(self.selected_files or {}) do
            if inLibrary(path) then any = true break end
        end
        local r = orig(self, ...)
        if any then reloadSoon() end
        return r
    end, "FileManager:deleteSelectedFiles")
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
                and { limit = PREFETCH_COVERS, deadline = os.time() + PREFETCH_SECONDS }
                or { retry_all = true } -- "Download missing covers": retry failed ones too
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
            -- Removed books, and covers replaced by a new link.
            if r then Covers.cleanup(store, covers_dir) end
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
        if r.covers.network_error then
            return T(_("Cloud library: %1 covers downloaded, then the network was lost."), r.covers.fetched)
        end
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

local function pollJob()
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
local function syncDue()
    local server = Library.server()
    if not server or Library.settings().auto_sync == false then return false end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return false end
    local store = openStore(server)
    local last = tonumber(store:getMeta("last_sync")) or 0
    store:close()
    return os.time() - last > QUICK_INTERVAL
end

--- Starts a quick sync if automatic syncing is on and one is due.
function Library.syncIfDue()
    if Library.job or not syncDue() then return false end
    return Library.sync("quick", true)
end

function Library.onFileManagerReady()
    local t_start = Timing.start()
    Library.load()
    local server = Library.server()
    if not server or Library.job then return end
    -- Even without syncing, check the folder for new or changed files.
    Library.sync(syncDue() and "quick" or "scan", true)
    Timing.record("startup: plugin", Timing.since(t_start), "catalog load and starting the background check")
end

function Library.poll()
    return Guard.call("jobs", pollJob)
end

-- Downloading --------------------------------------------------------------------

--- Downloads a cloud book into the library folder. opts: { ext = format to
-- use (default: the best one), open = open it when done }.
function Library.download(id, opts)
    opts = opts or {}
    local server, folder = Library.server(), Library.folder()
    local book = server and Library.bookDetails(id)
    if not (book and folder) then return false end
    local choices = Downloads.choices(book.formats)
    local format = choices[1]
    for _i, c in ipairs(choices) do
        if c.ext == opts.ext then format = c end
    end
    if not format then
        notify(T(_("Cloud library: no downloadable format for %1."), book.title or id))
        return false
    end
    if Downloads.isQueued(id) then
        notify(T(_("Cloud library: already downloading %1."), book.title or id))
        return false
    end
    local url = require("cloudlibrary/sync").resolve(server.url, format.href)
    local function go()
        local name = Downloads.fileName(book, format.ext, folder)
        local path = folder .. "/" .. name
        notify(T(_("Downloading %1…"), book.title or name))
        Downloads.start{
            server = server, url = url, path = path, book = book,
            on_done = function(result) Library.downloaded(book, result, opts) end,
        }
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(go)
    return true
end

function Library.downloaded(book, result, opts)
    if result.error then
        Timing.record("download: failed", result.ms or 0, book.title)
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Couldn't download %1:\n%2"), book.title or book.id, result.error),
        })
        return
    end
    local attr = Downloads.finish(result.path, book)
    Timing.record("download: book", result.ms or 0,
        string.format("%.1f MB, %s", (result.size or 0) / 1048576, result.path:match("[^/]+$")))
    -- Link the file to the catalog book now, rather than when the folder is
    -- next checked, so its cloud entry goes away at once.
    local server = Library.server()
    if server and attr then
        local store = openStore(server)
        store:setLocalFile(result.path, {
            mtime = attr.modification, size = attr.size, uuids = { book.id:lower() },
            title = book.title, authors = book.authors,
        })
        store:close()
    end
    Library.load()
    notify(T(_("Downloaded %1."), book.title or book.id))
    if opts.open then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            require("apps/filemanager/filemanagerutil").openFile(FileManager.instance, result.path)
        else
            require("apps/reader/readerui"):showReader(result.path)
        end
    end
end

--- Buttons for a cloud book's details sheet. close() closes the sheet.
function Library.detailsButtons(id, full, close)
    local choices = Downloads.choices(full and full.formats)
    local busy = Downloads.isQueued(id)
    local first = choices[1]
    local label = first and #choices > 1 and first.ext:upper() or nil
    local rows = {{
        { text = _("Close"), callback = close },
        {
            text = label and T(_("Download %1"), label) or _("Download"),
            enabled = first ~= nil and not busy,
            callback = function()
                close()
                Library.download(id, { ext = first and first.ext })
            end,
        },
        {
            text = _("Download & read"),
            enabled = first ~= nil and not busy,
            callback = function()
                close()
                Library.download(id, { ext = first and first.ext, open = true })
            end,
        },
    }}
    if #choices > 1 then
        local row = {}
        for i = 2, math.min(#choices, 4) do
            local c = choices[i]
            table.insert(row, {
                text = T(_("Download %1"), c.ext:upper()),
                enabled = not busy,
                callback = function()
                    close()
                    Library.download(id, { ext = c.ext })
                end,
            })
        end
        table.insert(rows, row)
    end
    return rows
end
Virtual.detailsButtons = function(...)
    return Guard.wrapCallbacks(Library.detailsButtons(...))
end

-- Network ----------------------------------------------------------------------

--- Wi-Fi connected: books drawn while offline got placeholder covers, so
-- redraw the library page (their covers are then asked for), and sync if
-- it's due.
function Library.onNetworkConnected()
    for _i, b in ipairs(Virtual.books) do b.cover_retry_at = nil end
    UIManager:scheduleIn(1, Guard.task("jobs", function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        if not (fc and Virtual.folder and fc.path) then return end
        if (fc.path:gsub("/+$", "")) ~= Virtual.folder then return end
        -- Only when the file browser is what's on screen (not ZenOS's Home
        -- page, a dialog's parent, or the reader).
        if UIManager:getTopmostVisibleWidget() ~= fm then return end
        Timing.record("network: redraw library", 0, "after Wi-Fi connected", true)
        fc:updateItems(1, true)
    end))
    Library.syncIfDue()
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
        local problems = Guard.statusText()
        return _("No catalog chosen.") .. (problems ~= "" and ("\n\n" .. problems) or "")
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
        if (st.covers_failed or 0) > 0 then
            table.insert(lines, T(_("Covers the server couldn't provide: %1 (tried again daily)"), st.covers_failed))
        end
    end
    table.insert(lines, T(_("Last sync: %1"), ago(last)))
    table.insert(lines, T(_("Last full sync: %1"), ago(last_full)))
    local r = Library.last_result
    if r and r.error then table.insert(lines, T(_("Last error: %1"), r.error)) end
    local problems = Guard.statusText()
    if problems ~= "" then
        table.insert(lines, "")
        table.insert(lines, _("Compatibility:"))
        table.insert(lines, problems)
    end
    if Library.job then table.insert(lines, _("Syncing now…")) end
    return table.concat(lines, "\n")
end

function Library.menuItems(plugin)
    return Guard.wrapCallbacks({ Library.menuEntry(plugin) })[1]
end

function Library.menuEntry(plugin)
    return {
        text = _("Cloud library"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local has_server = function() return Library.server() ~= nil end
            local items = {
                -- Syncing
                {
                    text = _("Sync now"),
                    help_text = _("Adds books new to the catalog since the last sync. If the last full sync was over a day ago, does a full sync instead."),
                    enabled_func = has_server,
                    callback = function() Library.sync("quick") end,
                },
                {
                    text = _("Full sync"),
                    help_text = _("Reads the whole catalog again: picks up edited and removed books, series, and changed covers."),
                    enabled_func = has_server,
                    callback = function() Library.sync("full") end,
                },
                {
                    text = _("Download missing covers"),
                    help_text = _("Downloads every cover not on this device yet, in the background, including covers a full sync found changed on the server. Covers are otherwise downloaded as you browse, and some after each sync."),
                    enabled_func = has_server,
                    callback = function() Library.sync("covers") end,
                },
                {
                    text = _("Sync automatically"),
                    help_text = _("When the file browser opens and Wi-Fi is on: new books at most hourly, everything daily."),
                    checked_func = function() return Library.settings().auto_sync ~= false end,
                    callback = function()
                        Library.save("auto_sync", Library.settings().auto_sync == false)
                    end,
                    separator = true,
                },
                -- Setup
                {
                    text_func = function()
                        local s = Library.server()
                        return T(_("Catalog: %1"), s and (s.title or s.url) or _("none"))
                    end,
                    help_text = _("Your library's catalog, from those added in KOReader's OPDS catalog plugin. Choosing one syncs it."),
                    sub_item_table_func = Library.serverMenu,
                },
                {
                    text_func = function() return T(_("Folder: %1"), Library.folder() or "?") end,
                    help_text = _("Where cloud books are listed and downloaded to. Books already in this folder (not its subfolders) are recognised as catalog books, so they aren't listed twice."),
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
                    separator = true,
                },
                -- Display
                {
                    text = _("Show cloud books"),
                    help_text = _("Lists catalog books that aren't on this device in the folder, ready to download. Turn this off before removing the plugin, so the file browser forgets the cloud books."),
                    checked_func = function() return Library.settings().show ~= false end,
                    check_callback_updates_menu = true,
                    callback = function(touchmenu_instance)
                        local show = Library.settings().show == false
                        Library.save("show", show)
                        if show then
                            Library.loadShowingProgress(touchmenu_instance)
                        else
                            Library.load()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end
                    end,
                },
                {
                    text = _("Mark cloud books"),
                    help_text = _("A cloud on the cover of books that are only in your cloud library."),
                    checked_func = function() return Library.settings().badge_cloud ~= false end,
                    callback = function()
                        Library.save("badge_cloud", Library.settings().badge_cloud == false)
                        Badge.cloud_enabled = Library.settings().badge_cloud ~= false
                        Library.repaint()
                    end,
                },
                {
                    text = _("Mark books on this device"),
                    help_text = _("A check mark on the cover of downloaded books that are in your cloud library."),
                    checked_func = function() return Library.settings().badge_local == true end,
                    callback = function()
                        Library.save("badge_local", Library.settings().badge_local ~= true)
                        Badge.local_enabled = Library.settings().badge_local == true
                        Library.repaint()
                    end,
                },
                {
                    text = _("Include cloud books in file search"),
                    help_text = _("KOReader's file search also finds cloud books, by title, author or series."),
                    checked_func = function() return Library.settings().search ~= false end,
                    callback = function()
                        Library.save("search", Library.settings().search == false)
                        Search.enabled = Library.settings().search ~= false
                    end,
                },
            }
            if Library.hasZenOS() then
                table.insert(items, {
                    text = _("ZenOS"),
                    sub_item_table = {
                        {
                            text = _("Cloud books in Authors, Series and Tags"),
                            help_text = _("Lists cloud books in ZenOS's Authors, Series and Tags tabs, as well as downloaded ones."),
                            checked_func = function() return Library.settings().zenos_groups ~= false end,
                            callback = function()
                                Library.save("zenos_groups", Library.settings().zenos_groups == false)
                                ZenGroups.enabled = Library.settings().zenos_groups ~= false
                            end,
                        },
                        {
                            text = _("Faster Library tab (experimental)"),
                            help_text = _("Opening the Library tab from another tab (Authors, Series…) reuses ZenOS's saved listing instead of listing the whole folder again."),
                            checked_func = function() return Library.settings().keep_zenos_listing ~= false end,
                            callback = function()
                                Library.save("keep_zenos_listing", Library.settings().keep_zenos_listing == false)
                                ZenListing.enabled = Library.settings().keep_zenos_listing ~= false
                            end,
                        },
                    },
                })
            end
            items[#items].separator = true
            -- Diagnostics
            table.insert(items, {
                text = _("Status"),
                help_text = _("Catalog, folder, book and cover counts, last syncs, and any problems."),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(require("ui/widget/infomessage"):new{ text = Library.statusText() })
                end,
            })
            table.insert(items, {
                text = _("Timings"),
                help_text = _("How long each step took on this device, for tracking down slowness."),
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
            })
            if plugin then
                items[#items].separator = true
                local Updater = require("cloudlibrary/updater")
                for _i, item in ipairs(Updater.menuItems(plugin)) do table.insert(items, item) end
            end
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
            check_callback_closes_menu = true,
            callback = function(touchmenu_instance)
                Library.save("server", { url = s.url, username = s.username })
                chosen = Library.settings().server
                Library.loadShowingProgress(touchmenu_instance)
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
