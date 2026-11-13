--[[--
Connects the statistics, annotations and book data sync engine to KOReader: settings,
the server, subprocesses, the network state and the running statistics
plugin. Also the settings and the server choice settings sync shares.

One controller per KOReader process (plugins are instantiated again for
every FileManager and ReaderUI, but package.loaded keeps this module), so a
sync carries on when the reader closes and the file browser opens.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local Problems = require("concordance/problems")

local AnnStore = require("concordance/annstore")
local AnnSync = require("concordance/annsync")
local BookStore = require("concordance/bookstore")
local BookSync = require("concordance/booksync")
local CollSync = require("concordance/collsync")
local HistSync = require("concordance/histsync")
local Engine = require("concordance/engine")
local IdScan = require("concordance/idscan")
local Identity = require("concordance/identity")
local IdStore = require("concordance/idstore")
local Store = require("concordance/store")

local Plugin = {}

-- Settings live in KOReader's settings folder, in settings/concordance/:
--
--   settings.lua    the same on every device (fine to sync between devices
--                   with Concordance's own settings sync): server ({name, type}
--                   of a Cloud storage server, no credentials), root,
--                   auto_stats and auto_annotations (on unless false),
--                   allow_wifi, time_limit
--   device.lua      this device's own: device_id, status, ann_scanned
--   state.sqlite3   what was sent and received, merged annotations and book data
--
-- concordance/migrate.lua moves OmniSync's files here on first start.
Plugin.DIR = "concordance"
Plugin.SHARED_FILE = Plugin.DIR .. "/settings.lua"
Plugin.DEVICE_FILE = Plugin.DIR .. "/device.lua"
Plugin.STATE_FILE = Plugin.DIR .. "/state.sqlite3"

--- Folder on the server when none is set. Settings sync uses its Files/
-- subfolder; statistics, highlights and book data its Reading/ subfolder
-- (Statistics/ until 0.5.0: see STATISTICS.md, "Moving from Statistics/").
Plugin.DEFAULT_ROOT = "/KOReader"
Plugin.SETTINGS_DIR = "Files"
Plugin.STATS_DIR = "Reading"
Plugin.OLD_STATS_DIR = "Statistics"

--- Makes settings/concordance/ if it isn't there; returns the settings folder.
function Plugin.ensureDir()
    local dir = DataStorage:getSettingsDir()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir .. "/" .. Plugin.DIR, "mode") ~= "directory" then
        lfs.mkdir(dir .. "/" .. Plugin.DIR)
    end
    return dir
end

local files -- { shared = LuaSettings, device = LuaSettings }, opened on first use

local function openFiles()
    if files then return files end
    local LuaSettings = require("luasettings")
    local dir = Plugin.ensureDir()
    files = {
        shared = LuaSettings:open(dir .. "/" .. Plugin.SHARED_FILE),
        device = LuaSettings:open(dir .. "/" .. Plugin.DEVICE_FILE),
    }
    return files
end

--- Forgets the open settings files (after migrate.lua wrote them, and in tests).
function Plugin.reload()
    files = nil
end

--- Settings shared by all devices (a live table; call saveSettings after changing it).
function Plugin.settings()
    return openFiles().shared.data
end

function Plugin.saveSettings()
    openFiles().shared:flush()
end

--- This device's own state (a live table; call saveDeviceState after changing it).
function Plugin.deviceState()
    return openFiles().device.data
end

function Plugin.saveDeviceState()
    openFiles().device:flush()
end

--- Automatic syncs of statistics, and of highlights and bookmarks: each on
-- unless turned off.
function Plugin.autoStats() return Plugin.settings().auto_stats ~= false end
function Plugin.autoAnnotations() return Plugin.settings().auto_annotations ~= false end

--- Minutes between automatic syncs while the file browser is shown (0: never).
Plugin.HOME_INTERVALS = { 5, 15, 30, 60 }
function Plugin.homeInterval()
    local m = Plugin.settings().home_interval
    for _, v in ipairs(Plugin.HOME_INTERVALS) do
        if m == v then return m end
    end
    return 0
end

local function randomId()
    local f = io.open("/dev/urandom", "rb")
    local bytes = f and f:read(8)
    if f then f:close() end
    if not bytes or #bytes < 8 then
        math.randomseed(os.time() + math.floor(os.clock() * 1e6))
        bytes = ""
        for _ = 1, 8 do bytes = bytes .. string.char(math.random(0, 255)) end
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function Plugin.deviceId()
    local d = Plugin.deviceState()
    if not d.device_id then
        d.device_id = randomId()
        Plugin.saveDeviceState()
        logger.info("StatSync: new device ID", d.device_id)
    end
    return d.device_id
end

--- This device's name: the "Device hostname" set in KOReader's progress sync
-- plugin, so it reads the same in both, else the device model. Read from
-- that plugin's settings file each time, so a change shows at the next sync.
function Plugin.deviceName()
    local ok, host = pcall(function()
        local s = require("luasettings"):open(DataStorage:getSettingsDir() .. "/kosync.lua"):readSetting("settings")
        return type(s) == "table" and s.kosync_hostname or nil
    end)
    if ok and type(host) == "string" then
        host = host:gsub("^%s+", ""):gsub("%s+$", "")
        if host ~= "" then return host:sub(1, 64) end
    end
    return Device.model
end

-- This plugin's folder (…/plugins/concordance.koplugin), from this file's path.
local function ownDir()
    local src = debug.getinfo(1, "S").source
    return type(src) == "string" and src:match("^@(.+)/concordance/plugin%.lua$") or nil
end

local function metaVersion(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text and text:match('version%s*=%s*"([%w%.%-%+]+)"')
end

--- Versions of Concordance and Cloud library (when installed and not turned
-- off) on this device, read from their _meta.lua, for meta.json.
-- Also KOReader's own version (its short form, such as "2025.10-58") and
-- ZenOS's, when installed and not turned off. plugins_dir: where to look for
-- the other plugins (tests); by default the folder Concordance is in.
--
-- ZenOS's folders: zenos.koplugin from its releases, zen_ui.koplugin from
-- before it was renamed (its plugin name then is zen_ui), and its source
-- folder's name.
local ZENOS_DIRS = { { "zenos.koplugin", "zenos" }, { "zen_ui.koplugin", "zen_ui" }, { "zen-os.koplugin", "zenos" } }

function Plugin.pluginVersions(plugins_dir)
    local own = ownDir()
    if not own then return nil end
    local dir = plugins_dir or own:match("^(.*)/[^/]+$") or "."
    local out = {}
    out.concordance = metaVersion(own .. "/_meta.lua")
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    disabled = type(disabled) == "table" and disabled or {}
    if not disabled.cloudlibrary then
        out.cloudlibrary = metaVersion(dir .. "/cloudlibrary.koplugin/_meta.lua")
    end
    for _, z in ipairs(ZENOS_DIRS) do
        local v = not disabled[z[2]] and metaVersion(dir .. "/" .. z[1] .. "/_meta.lua")
        if v then out.zenos = v break end
    end
    local ok, short = pcall(function() return require("version"):getShortVersion() end)
    if ok and type(short) == "string" and short ~= "" and short ~= "unknown" then out.koreader = short end
    return out
end

function Plugin.resetDeviceId()
    Plugin.deviceState().device_id = nil
    return Plugin.deviceId()
end

--- Server types Concordance can use (Dropbox and WebDAV). Settings sync works
-- with both; statistics and annotations need WebDAV.
Plugin.TYPES = require("concordance/remote").TYPES

--- The Dropbox and WebDAV servers set up in Cloud storage (with their credentials).
function Plugin.servers()
    local LuaSettings = require("luasettings")
    local ok, cs = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    local servers = {}
    local list = ok and cs and (cs.readSetting and cs:readSetting("cs_servers") or cs.data and cs.data.cs_servers)
    for _, server in ipairs(type(list) == "table" and list or {}) do
        if Plugin.TYPES[server.type] then table.insert(servers, server) end
    end
    return servers
end

--- The Cloud storage server Concordance uses: the one chosen (by name and
-- type), or with none chosen, the first Dropbox or WebDAV server. Returns
-- server, or nil and why.
function Plugin.server()
    local servers = Plugin.servers()
    local chosen = Plugin.settings().server
    if chosen then
        for _, server in ipairs(servers) do
            if server.name == chosen.name and (chosen.type == nil or server.type == chosen.type) then
                return server
            end
        end
        -- Not another server instead: it could be a different place.
        return nil, string.format("server \"%s\" not found in Cloud storage", tostring(chosen.name))
    end
    if servers[1] then return servers[1] end
    return nil, "no Dropbox or WebDAV server in Cloud storage"
end

--- The server for statistics and annotations: WebDAV only.
function Plugin.statsServer()
    local server, why = Plugin.server()
    if not server then return nil, why end
    if server.type ~= "webdav" then
        return nil, "statistics and highlights need a WebDAV server (not " .. tostring(Plugin.TYPES[server.type]) .. ")"
    end
    return server
end

--- The folder on the server, as set ("/KOReader" by default).
function Plugin.root()
    local root = Plugin.settings().root
    return (root and root ~= "") and root or Plugin.DEFAULT_ROOT
end

local function join(a, b) return require("concordance/webdav").join(a, b) end

--- Settings sync's folder: <root>/Files.
function Plugin.settingsRoot()
    return "/" .. join(Plugin.root(), Plugin.SETTINGS_DIR)
end

--- The folder for statistics and annotations, for the WebDAV client:
-- relative to the server's address. <root>/Reading (or `dir`).
function Plugin.remoteRoot(dir)
    return join(Plugin.root(), dir or Plugin.STATS_DIR)
end

--- Where statistics and annotations sync to, for showing and for noticing
-- a change: the server's address (without any user:password@) and the
-- folder. Nil without a WebDAV server.
function Plugin.serverLocation(server, dir)
    server = server or Plugin.statsServer()
    if not server or not server.address then return nil end
    local WebDav = require("concordance/webdav")
    local root = Plugin.remoteRoot(dir)
    return WebDav.redact(server.address):gsub("/+$", "") .. "/" .. (root ~= "" and root .. "/" or "")
end

function Plugin.serverProblem()
    local server, why = Plugin.statsServer()
    if not server then return why end
    if not server.address or server.address == "" then return "the WebDAV server has no address" end
end

local function statsPlugin()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI.instance
    return ui and ui.statistics
end

local function paths()
    local work = DataStorage:getDataDir() .. "/cache/concordance"
    return {
        stats = DataStorage:getSettingsDir() .. "/statistics.sqlite3",
        state = Plugin.ensureDir() .. "/" .. Plugin.STATE_FILE,
        work = work,
        tmp = work .. "/incoming",
    }
end

local function makeStore()
    local p = paths()
    return Store.new{ sq3 = require("lua-ljsqlite3/init"), stats_path = p.stats, state_path = p.state, logger = logger,
        -- The open book's statistics rows are KOReader's: never removed.
        open_md5 = function()
            local ok, ReaderUI = pcall(require, "apps/reader/readerui")
            local ui = ok and ReaderUI.instance
            return ui and ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
        end,
    }
end
Plugin.makeStore = makeStore

local ann_store, ann_sync

function Plugin.annStore()
    if not ann_store then
        ann_store = AnnStore.new{ sq3 = require("lua-ljsqlite3/init"), state_path = paths().state }
    end
    return ann_store
end

--- The reading history hasn't been read on this device yet (before the
-- first sync of annotations).
function Plugin.annotationsNeedScan()
    return not Plugin.deviceState().ann_scanned
end

--- The process-wide annotation sync (KOReader side).
function Plugin.annSync()
    if ann_sync then return ann_sync end
    ann_sync = AnnSync.new{
        store = Plugin.annStore(),
        getDeviceId = Plugin.deviceId,
        now = os.time,
        logger = logger,
        ui_manager = UIManager,
        enabled = function() return true end,
        schedule = function(delay, fn)
            if delay <= 0 then UIManager:nextTick(fn) else UIManager:scheduleIn(delay, fn) end
        end,
        saveScanned = function(t)
            Plugin.deviceState().ann_scanned = t
            Plugin.saveDeviceState()
        end,
    }
    return ann_sync
end

local book_store, book_sync

function Plugin.bookStore()
    if not book_store then
        book_store = BookStore.new{ sq3 = require("lua-ljsqlite3/init"), state_path = paths().state }
    end
    return book_store
end

--- The process-wide book data sync (KOReader side): status, rating,
-- review, custom metadata, handmade table of contents. Synced with
-- highlights and bookmarks.
function Plugin.bookSync()
    if book_sync then return book_sync end
    book_sync = BookSync.new{
        store = Plugin.bookStore(),
        getDeviceId = Plugin.deviceId,
        now = os.time,
        logger = logger,
        ui_manager = UIManager,
        enabled = function() return true end,
        schedule = function(delay, fn)
            if delay <= 0 then UIManager:nextTick(fn) else UIManager:scheduleIn(delay, fn) end
        end,
    }
    return book_sync
end

local coll_sync

--- The process-wide collections and favorites sync (synced with book data).
--- ZenOS's Home page module, when ZenOS is installed and the file browser
-- is running.
local function zenHome()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = type(FileManager) == "table" and FileManager.instance
    if not fm then return nil end
    local SharedState = package.loaded["common/shared_state"]
    -- ZenOS is there (its plugin or its shared state), but Home can't be found.
    local zen = fm.zenos ~= nil or SharedState ~= nil
    if not zen then return nil end
    local why
    -- (ZenOS always has Home: there's no setting that turns it off.)
    if fm.zenos == nil then
        why = "the file browser has no zenos field"
    elseif type(SharedState) ~= "table" or type(SharedState.get) ~= "function" then
        why = "common/shared_state.get is missing"
    else
        local ok, home = pcall(SharedState.get, fm.zenos, "home")
        if not ok then
            why = tostring(home)
        elseif type(home) ~= "table" then
            why = "no \"home\" in its shared state"
        else
            for _i, name in ipairs({ "isActiveOnTop", "rebuildActive", "invalidateBookCache" }) do
                if type(home[name]) ~= "function" then
                    why = "home." .. name .. " is missing"
                    break
                end
            end
            if not why then return home end
            -- Still use what's there.
            Problems.report("zenos:home", "ZenOS's Home may not update after a sync: ZenOS has changed", why)
            return home
        end
    end
    Problems.report("zenos:home", "ZenOS's Home may not update after a sync: ZenOS has changed", why)
    return nil
end

--- No menu or dialog is open, so collections and the history can be
-- changed. ZenOS's Home is a page of its own over the file browser, not a
-- menu: it counts as idle too, or nothing would arrive while it's shown.
local function uiIdle()
    local home = zenHome()
    if home and type(home.isActiveOnTop) == "function" then
        local ok, on_top = pcall(home.isActiveOnTop)
        if ok and on_top == true then return true end
        if not ok then
            logger.warn("Concordance: asking ZenOS's Home whether it's shown failed:", on_top)
            Problems.report("zenos:isActiveOnTop", "Syncs may wait while ZenOS's Home is shown", on_top)
        end
    end
    return CollSync.uiIdle()
end
Plugin._uiIdle = uiIdle

function Plugin.collSync()
    if coll_sync then return coll_sync end
    coll_sync = CollSync.new{
        store = Plugin.bookStore(),
        getDeviceId = Plugin.deviceId,
        now = os.time,
        logger = logger,
        enabled = function() return true end,
        schedule = function(delay, fn)
            if delay <= 0 then UIManager:nextTick(fn) else UIManager:scheduleIn(delay, fn) end
        end,
        idle = uiIdle,
        saved_ids = function()
            local data = require("luasettings"):open(DataStorage:getSettingsDir() .. "/collection.lua").data
            local out = {}
            for name, c in pairs(data or {}) do
                out[name] = type(c) == "table" and type(c.settings) == "table" and c.settings.concordance_id or nil
            end
            return out
        end,
    }
    return coll_sync
end

local hist_sync

--- Where Cloud library has a book with one of these UUIDs (its file, or
-- its cloud entry), when Cloud library is installed.
local function cloudPath(uuids)
    local CloudLibrary = package.loaded["cloudlibrary/library"]
    if type(CloudLibrary) ~= "table" or type(CloudLibrary.pathForUuids) ~= "function" then return nil end
    local ok, path = pcall(CloudLibrary.pathForUuids, uuids)
    if not ok then logger.warn("Concordance: asking Cloud library failed:", path) end
    return ok and path or nil
end

--- After books read elsewhere went into the history: the file browser, an
-- open History list and, under ZenOS, Home show the new order (Home rebuilds
-- now if it's shown, else when it's next opened).
local function refreshAfterHistory(paths)
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = type(FileManager) == "table" and FileManager.instance
    if not fm then return end
    if fm.file_chooser then
        if type(fm.file_chooser.refreshPath) == "function" then
            local ok, err = pcall(fm.file_chooser.refreshPath, fm.file_chooser)
            if not ok then
                logger.warn("Concordance: refreshing the file browser failed:", err)
                Problems.report("ui:refreshPath-failed", "Redrawing the file browser after a sync failed", err)
            end
        else
            Problems.report("check:FileChooser.refreshPath", "The file browser may not update after a sync: KOReader has changed",
                "FileChooser:refreshPath is missing")
        end
    end
    -- The History list builds its items once, when opened.
    local history = fm.history
    if type(history) == "table" and history.booklist_menu then
        if type(history.updateItemTable) == "function" then
            local ok, err = pcall(history.updateItemTable, history)
            if not ok then
                logger.warn("Concordance: refreshing the History list failed:", err)
                Problems.report("ui:history-failed", "Redrawing the open History list failed", err)
            end
        else
            Problems.report("check:FileManagerHistory.updateItemTable", "The open History list may not update after a sync: KOReader has changed",
                "FileManagerHistory:updateItemTable is missing")
        end
    end
    local home = zenHome()
    if home and type(home.rebuildActive) == "function" then
        if type(home.invalidateBookCache) == "function" then
            for _, path in ipairs(paths or {}) do
                local iok, ierr = pcall(home.invalidateBookCache, path, true)
                if not iok then
                    logger.warn("Concordance: telling ZenOS's Home about a book failed:", ierr)
                    Problems.report("zenos:invalidate", "ZenOS's Home may show old details of a book", ierr)
                    break
                end
            end
        end
        local ok, err = pcall(home.rebuildActive)
        if not ok then
            logger.warn("Concordance: rebuilding ZenOS Home failed:", err)
            Problems.report("zenos:rebuild", "Redrawing ZenOS's Home after a sync failed", err)
        end
    end
end

--- The process-wide reading history sync (synced with book data).
function Plugin.histSync()
    if hist_sync then return hist_sync end
    hist_sync = HistSync.new{
        store = Plugin.bookStore(),
        finder = Plugin.collSync(),
        getDeviceId = Plugin.deviceId,
        now = os.time,
        logger = logger,
        enabled = function() return true end,
        schedule = function(delay, fn)
            if delay <= 0 then UIManager:nextTick(fn) else UIManager:scheduleIn(delay, fn) end
        end,
        uuids = function(md5s) return Plugin.idStore():uuids(md5s) end,
        resolve = cloudPath,
        refresh_ui = refreshAfterHistory,
    }
    return hist_sync
end

local id_store

function Plugin.idStore()
    if not id_store then
        id_store = IdStore.new{ sq3 = require("lua-ljsqlite3/init"), state_path = paths().state }
    end
    return id_store
end

--- Lets KOReader's progress sync find a book's position under its other
-- versions (see concordance/progresshook.lua). Does nothing when the progress
-- sync plugin isn't enabled. Returns true if the hook is in place.
function Plugin.installProgressHook()
    local ok, Client = pcall(require, "KOSyncClient")
    if not ok or type(Client) ~= "table" then return false end -- progress sync not enabled
    if type(Client.get_progress) ~= "function" then
        logger.warn("Concordance: KOSyncClient.get_progress is missing, not finding other versions' positions")
        Problems.report("progress:signature", "Progress sync for other versions of a book is off: KOReader's progress sync has changed",
            "KOSyncClient.get_progress is missing")
        return false
    end
    return (require("concordance/progresshook").install(Client, {
        peers = function(md5) return Plugin.idStore():positionPeers(md5) end,
        schedule = function(fn) UIManager:nextTick(fn) end,
        logger = logger,
    }))
end

--- Checks, once per KOReader process, what Concordance relies on in KOReader
-- outside a book (concordance/problems.lua reports what's missing).
-- Parameter counts include self.
local checked_koreader = false
function Plugin.checkKOReader()
    if checked_koreader then return end
    checked_koreader = true
    local function mod(name)
        local ok, m = pcall(require, name)
        return ok and m or ("can't be loaded: " .. tostring(m))
    end
    local n = 0
    n = n + Problems.requires("ReadHistory", mod("readhistory"),
        { addItem = 4, reload = 2, _flush = 1, _reduce = 1, getIndexByFile = 2, getIndexByTime = 3,
          updateDateTimeString = 1 },
        { hist = "table" })
    n = n + Problems.requires("ReadCollection", mod("readcollection"),
        { _read = 1, write = 1, addCollection = 2, renameCollection = 3, removeCollection = 2, addItem = 3 },
        { coll = "table", coll_settings = "table" })
    n = n + Problems.requires("FileChooser", mod("ui/widget/filechooser"), { refreshPath = 1 })
    n = n + Problems.requires("FileManagerHistory", mod("apps/filemanager/filemanagerhistory"), { updateItemTable = 1 })
    n = n + Problems.requires("UIManager", mod("ui/uimanager"), { getTopmostVisibleWidget = 1 })
    n = n + Problems.requires("DocSettings", mod("docsettings"),
        { readSetting = 2, saveSetting = 3, getCustomMetadataFile = 1 })
    if n > 0 then logger.warn("Concordance:", n, "things it relies on in KOReader are missing or changed") end
end

--- The same for the reader, once, on the first book opened.
local checked_reader = false
function Plugin.checkReader(ui)
    if checked_reader or not (ui and ui.document) then return end
    checked_reader = true
    local n = 0
    n = n + Problems.requires("ReaderAnnotation", ui.annotation,
        { updateAnnotations = 3, setNeedsUpdateFlag = 1 }, { annotations = "table" })
    n = n + Problems.requires("ReaderView", ui.view, { resetHighlightBoxesCache = 1 })
    n = n + Problems.requires("ReaderFooter", ui.view and ui.view.footer, { maybeUpdateFooter = 1 })
    n = n + Problems.requires("ReaderHandMade", ui.handmade,
        { updateHandmagePages = 1, setupFlows = 2, setupToc = 2 })
    local stats = ui.statistics
    if stats then
        n = n + Problems.requires("ReaderStatistics", stats, { insertDB = 1, getPageTimeTotalStats = 2 },
            { settings = "table" })
    end
    if n > 0 then logger.warn("Concordance:", n, "things it relies on in KOReader's reader are missing or changed") end
end

--- Book files in Cloud library's folder that are catalog books, when
-- Cloud library is installed: { path, … }, and whether that's all of them
-- (false while Cloud library hasn't read its catalog, or couldn't say).
local function cloudFiles()
    local CloudLibrary = package.loaded["cloudlibrary/library"]
    if type(CloudLibrary) ~= "table" or type(CloudLibrary.localFiles) ~= "function" then return {}, true end
    if type(CloudLibrary.isLoaded) == "function" then
        local ok_l, loaded = pcall(CloudLibrary.isLoaded)
        if not (ok_l and loaded) then return {}, false end
    end
    local ok, list = pcall(CloudLibrary.localFiles)
    if not ok then logger.warn("Concordance: asking Cloud library failed:", list) end
    if ok and type(list) == "table" then return list, true end
    return {}, false
end

--- Files Cloud library matched to a catalog book without the file naming
-- the book's UUID (see concordance/identity.lua).
local function cloudLinks()
    local CloudLibrary = package.loaded["cloudlibrary/library"]
    if type(CloudLibrary) ~= "table" or type(CloudLibrary.links) ~= "function" then return {} end
    local ok, list = pcall(CloudLibrary.links)
    if not ok then logger.warn("Concordance: asking Cloud library failed:", list) end
    return ok and type(list) == "table" and list or {}
end

--- Before a sync: Cloud library's matches become links, and links this
-- device made that it no longer makes are withdrawn. Only once it has
-- read its catalog: before that it matches nothing, which says nothing.
local function collectLinks()
    local links = cloudLinks()
    Identity.recordLinks(links)
    local CloudLibrary = package.loaded["cloudlibrary/library"]
    if type(CloudLibrary) ~= "table" or type(CloudLibrary.isLoaded) ~= "function"
            or type(CloudLibrary.folderFiles) ~= "function" or type(CloudLibrary.inCatalog) ~= "function" then
        return
    end
    local ok, loaded = pcall(CloudLibrary.isLoaded)
    if not (ok and loaded) then return end
    local ok_f, files = pcall(CloudLibrary.folderFiles)
    if not ok_f or type(files) ~= "table" then
        logger.warn("Concordance: asking Cloud library failed:", files)
        return
    end
    local n = Identity.retractLinks(links, files, CloudLibrary.inCatalog)
    if n > 0 then logger.info("Concordance: withdrew", n, "matches Cloud library no longer makes") end
end

--- Book files to read for book identity: the EPUBs book data knows about
-- (books opened on this device), with the sidecar's MD5, and those in
-- Cloud library's folder (downloaded, maybe never opened: no MD5 yet).
-- Also returns whether the list is complete: false when Cloud library's
-- files aren't known just now, so files left out aren't taken as gone.
function Plugin.identityFiles()
    local lfs = require("libs/libkoreader-lfs")
    local out, seen = {}, {}
    local function add(path, md5)
        if seen[path] or not IdScan.handles(path) then return end
        seen[path] = true
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" then
            out[#out + 1] = { path = path, md5 = md5, size = attr.size, mtime = attr.modification }
        end
    end
    for path, f in pairs(Plugin.bookStore():files()) do add(path, f.md5) end
    local cloud, complete = cloudFiles()
    for _, path in ipairs(cloud) do
        if type(path) == "string" then add(path, nil) end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out, complete
end

local controller

--- The process-wide engine.
function Plugin.engine()
    if controller then return controller end
    local p = paths()
    local s = Plugin.settings()
    local store = makeStore()
    controller = Engine.new{
        store = store,
        logger = logger,
        status = Plugin.deviceState().status,
        device_name = Plugin.deviceName,
        plugin_versions = Plugin.pluginVersions,
        work_dir = p.work,
        tmp_dir = p.tmp,
        time_limit = s.time_limit,
        getDeviceId = Plugin.deviceId,
        now = os.time,
        schedule = function(delay, fn)
            if delay <= 0 then UIManager:nextTick(fn) else UIManager:scheduleIn(delay, fn) end
        end,
        canRun = function(reason, opts)
            local problem = Plugin.serverProblem()
            if problem then return false, problem end
            -- Another server or folder: send and import everything there.
            local location = Plugin.serverLocation()
            -- Statistics/ renamed Reading/ (0.5.0): the same place, not a new one.
            local mok, merr = pcall(store.moveLocation, store,
                Plugin.serverLocation(nil, Plugin.OLD_STATS_DIR), location)
            if not mok then return false, "state database: " .. tostring(merr) end
            local lok, changed = pcall(store.useLocation, store, location)
            if not lok then return false, "state database: " .. tostring(changed) end
            if changed then
                logger.info("StatSync: server or folder changed, syncing everything with", location)
                local aok, aerr = pcall(function()
                    Plugin.annStore():requeueAll()
                    Plugin.bookStore():requeueAll()
                    Plugin.idStore():requeueAll()
                end)
                if not aok then return false, "state database: " .. tostring(aerr) end
            end
            local stats_settings = G_reader_settings:readSetting("statistics")
            if opts.stats ~= false and stats_settings and stats_settings.is_enabled == false then
                if opts.ann == false then return false, "reading statistics are disabled" end
                opts.stats = false -- highlights and bookmarks only
            end
            local schema_problem = opts.stats ~= false and store:statsSchemaProblem()
            if schema_problem then
                if opts.ann == false then return false, schema_problem end
                opts.stats = false -- the statistics plugin changed its database: leave it alone
            end
            if not NetworkMgr:isConnected() then return false, "offline" end
            return true
        end,
        makeTransport = function()
            -- Runs in the subprocess: the server is read from settings as
            -- they were when it was forked.
            local server = Plugin.statsServer()
            local http = require("socket.http")
            local sok, socketutil = pcall(require, "socketutil")
            if sok then socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT) end
            local WebDav = require("concordance/webdav")
            return WebDav.new{
                http = http, logger = logger,
                address = server.address, username = server.username, password = server.password,
                root = Plugin.remoteRoot(),
                random = randomId,
            }
        end,
        spawn = function(fn)
            local pid, err = ffiutil.runInSubProcess(function(...)
                Problems.disable() -- no UI in the subprocess
                return fn(...)
            end)
            if not pid then return nil, err end
            UIManager:preventStandby()
            return { pid = pid }
        end,
        isDone = function(h)
            if h.done then return true end
            if ffiutil.isSubProcessDone(h.pid) then
                h.done = true
                UIManager:allowStandby()
                return true
            end
            return false
        end,
        kill = function(h) ffiutil.terminateSubProcess(h.pid) end,
        flush = function()
            -- Same call the statistics plugin makes on suspend and on its
            -- periodic save: writes the page times it holds in memory.
            local stats = statsPlugin()
            if not stats then return end
            if type(stats.insertDB) == "function" then
                stats:insertDB()
            else
                logger.warn("Concordance: the statistics plugin has no insertDB, the latest page times wait")
                Problems.report("check:ReaderStatistics.insertDB", "The latest reading times wait for the next sync: KOReader's statistics plugin has changed",
                    "ReaderStatistics:insertDB is missing")
            end
        end,
        afterImport = function(ids)
            -- Imported events for the open book: refresh the cached totals
            -- the statistics plugin uses for its estimates (as initData does).
            local stats = statsPlugin()
            if not stats then return end
            local enabled = type(stats.settings) == "table" and stats.settings.is_enabled
            local why
            if type(stats.getPageTimeTotalStats) ~= "function" then
                why = "ReaderStatistics:getPageTimeTotalStats is missing"
            elseif enabled and stats.is_doc and stats.id_curr_book == nil then
                why = "ReaderStatistics.id_curr_book is missing"
            end
            if why then
                logger.warn("Concordance: can't refresh the open book's statistics:", why)
                Problems.report(why:find("getPageTimeTotalStats", 1, true) and "check:ReaderStatistics.getPageTimeTotalStats"
                    or "stats:id_curr_book", "The open book's reading estimates miss time read elsewhere until it's reopened: KOReader's statistics plugin has changed",
                    why)
                return
            end
            local id = stats.id_curr_book
            if id and ids[id] then
                stats.book_read_pages, stats.book_read_time = stats:getPageTimeTotalStats(id)
                if stats.book_read_pages and stats.book_read_pages > 0 then
                    stats.avg_time = stats.book_read_time / stats.book_read_pages
                end
            end
        end,
        ann = {
            store = Plugin.annStore(),
            collect = function() Plugin.annSync():collect() end,
            afterSync = function(run) Plugin.annSync():afterSync(run) end,
        },
        book = {
            store = Plugin.bookStore(),
            collect = function()
                Plugin.bookSync():collect()
                local ok, err = pcall(function() Plugin.collSync():observe() end)
                if not ok then logger.warn("Concordance: recording collection changes failed:", err) end
                ok, err = pcall(function() Plugin.histSync():observe() end)
                if not ok then logger.warn("Concordance: recording history changes failed:", err) end
            end,
            afterSync = function(run)
                Plugin.bookSync():afterSync(run)
                Plugin.collSync():afterSync()
                Plugin.histSync():afterSync()
            end,
        },
        id = {
            store = Plugin.idStore(),
            files = Plugin.identityFiles,
            collect = collectLinks,
            scan = function(item)
                -- In the subprocess.
                return IdScan.scan(item.path, {
                    md5 = require("ffi/sha2").md5,
                    partialMD5 = require("util").partialMD5,
                })
            end,
        },
        saveStatus = function(status)
            Plugin.deviceState().status = status
            Plugin.saveDeviceState()
        end,
        onDone = function(status, run)
            if run and ((run.book_segments_imported or 0) > 0 or next(run.book_affected or {})
                    or (run.id_segments_imported or 0) > 0 or (run.id_new_facts or 0) > 0
                    or run.id_regrouped) then
                Identity.changed()
            end
            if Plugin.onDone then Plugin.onDone(status, run) end
        end,
    }
    return controller
end

--- Sets up what other plugins (Cloud library) are told about books, and
-- can tell Concordance (see concordance/identity.lua).
function Plugin.setupIdentity()
    Identity.setup{
        id_store = Plugin.idStore,
        book_store = Plugin.bookStore,
        device_id = Plugin.deviceId,
        device_names = function() return Plugin.engine().status.device_names end,
        files = function() return Plugin.bookStore():files() end,
        handles = IdScan.handles,
        scan = function(path)
            return IdScan.scan(path, { md5 = require("ffi/sha2").md5, partialMD5 = require("util").partialMD5 })
        end,
        refresh = function()
            Plugin.engine():refreshIdentity()
            Identity.changed()
        end,
        logger = logger,
    }
end

--- Clears the import record so the next sync imports every segment again.
function Plugin.rebuild()
    makeStore():forgetSeen()
end

--- The next sync sends everything this device has to the folder, and
-- imports everything there (as after choosing another folder).
function Plugin.sendEverythingAgain()
    makeStore():forgetLocation(true)
end

return Plugin
