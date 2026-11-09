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

local AnnStore = require("omnisync/annstore")
local AnnSync = require("omnisync/annsync")
local BookStore = require("omnisync/bookstore")
local BookSync = require("omnisync/booksync")
local CollSync = require("omnisync/collsync")
local HistSync = require("omnisync/histsync")
local Engine = require("omnisync/engine")
local IdScan = require("omnisync/idscan")
local IdStore = require("omnisync/idstore")
local Store = require("omnisync/store")

local Plugin = {}

-- Settings live in KOReader's settings folder, in settings/omnisync/:
--
--   settings.lua    the same on every device (fine to sync between devices
--                   with OmniSync's own settings sync): server ({name, type}
--                   of a Cloud storage server, no credentials), root,
--                   auto_stats and auto_annotations (on unless false),
--                   allow_wifi, time_limit
--   device.lua      this device's own: device_id, status, ann_scanned
--   state.sqlite3   what was sent and received, merged annotations and book data
--
-- omnisync/migrate.lua moves SuperSync's files here on first start.
Plugin.DIR = "omnisync"
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

--- Makes settings/omnisync/ if it isn't there; returns the settings folder.
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

function Plugin.resetDeviceId()
    Plugin.deviceState().device_id = nil
    return Plugin.deviceId()
end

--- Server types OmniSync can use (Dropbox and WebDAV). Settings sync works
-- with both; statistics and annotations need WebDAV.
Plugin.TYPES = require("omnisync/remote").TYPES

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

--- The Cloud storage server OmniSync uses: the one chosen (by name and
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

local function join(a, b) return require("omnisync/webdav").join(a, b) end

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
    local WebDav = require("omnisync/webdav")
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
    local work = DataStorage:getDataDir() .. "/cache/omnisync"
    return {
        stats = DataStorage:getSettingsDir() .. "/statistics.sqlite3",
        state = Plugin.ensureDir() .. "/" .. Plugin.STATE_FILE,
        work = work,
        tmp = work .. "/incoming",
    }
end

local function makeStore()
    local p = paths()
    return Store.new{ sq3 = require("lua-ljsqlite3/init"), stats_path = p.stats, state_path = p.state, logger = logger }
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
    if not ok then logger.warn("OmniSync: asking Cloud library failed:", path) end
    return ok and path or nil
end

--- After books read elsewhere went into the history: the file browser and,
-- under ZenOS, Home show the new order (Home rebuilds now if it's shown,
-- else when it's next opened).
local function refreshAfterHistory(paths)
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = type(FileManager) == "table" and FileManager.instance
    if not fm then return end
    if fm.file_chooser then fm.file_chooser:refreshPath() end
    local SharedState = package.loaded["common/shared_state"]
    local home = fm.zenos and type(SharedState) == "table" and type(SharedState.get) == "function"
        and SharedState.get(fm.zenos, "home")
    if type(home) == "table" and type(home.rebuildActive) == "function" then
        if type(home.invalidateBookCache) == "function" then
            for _, path in ipairs(paths or {}) do pcall(home.invalidateBookCache, path, true) end
        end
        local ok, err = pcall(home.rebuildActive)
        if not ok then logger.warn("OmniSync: rebuilding ZenOS Home failed:", err) end
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

--- Book files to read for book identity: the EPUBs book data knows about
-- (books opened on this device), with the sidecar's MD5.
function Plugin.identityFiles()
    local lfs = require("libs/libkoreader-lfs")
    local out = {}
    for path, f in pairs(Plugin.bookStore():files()) do
        if IdScan.handles(path) then
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                out[#out + 1] = { path = path, md5 = f.md5, size = attr.size, mtime = attr.modification }
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
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
        device_name = Device.model,
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
            local WebDav = require("omnisync/webdav")
            return WebDav.new{
                http = http, logger = logger,
                address = server.address, username = server.username, password = server.password,
                root = Plugin.remoteRoot(),
                random = randomId,
            }
        end,
        spawn = function(fn)
            local pid, err = ffiutil.runInSubProcess(fn)
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
            if stats and type(stats.insertDB) == "function" then stats:insertDB() end
        end,
        afterImport = function(ids)
            -- Imported events for the open book: refresh the cached totals
            -- the statistics plugin uses for its estimates (as initData does).
            local stats = statsPlugin()
            local id = stats and stats.id_curr_book
            if id and ids[id] and type(stats.getPageTimeTotalStats) == "function" then
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
                if not ok then logger.warn("OmniSync: recording collection changes failed:", err) end
                ok, err = pcall(function() Plugin.histSync():observe() end)
                if not ok then logger.warn("OmniSync: recording history changes failed:", err) end
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
            if Plugin.onDone then Plugin.onDone(status, run) end
        end,
    }
    return controller
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
