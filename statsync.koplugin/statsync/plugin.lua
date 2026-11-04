--[[--
Connects the sync engine to KOReader: settings, the server, subprocesses,
the network state and the running statistics plugin.

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

local Engine = require("statsync/engine")
local Store = require("statsync/store")

local Plugin = {}

-- Settings live in KOReader's settings folder, in two files:
--
--   statsync_settings.lua  the same on every device (fine to sync between
--                          devices, e.g. with Settings sync): enabled,
--                          allow_wifi, server ({name, type} of a Cloud
--                          storage server, no credentials), root, time_limit
--   statsync_device.lua    this device's own: device_id, status
--
-- Earlier versions kept the shared settings in statsync.lua with the whole
-- server entry (password included), and before that everything under
-- "statsync" in settings.reader.lua. They're copied the first time, and the
-- old places left alone, so a device still on an older version that gets
-- the shared file synced to it isn't handed settings it can't read.
Plugin.SHARED_FILE = "statsync_settings.lua"
Plugin.DEVICE_FILE = "statsync_device.lua"
local OLD_SHARED_FILE = "statsync.lua"
local LEGACY_KEY = "statsync"
local DEVICE_KEYS = { device_id = true, status = true }

--- Folder on the server when none is set, like Settings sync's /KOReader/Settings.
Plugin.DEFAULT_ROOT = "/KOReader/Statistics"

local files -- { shared = LuaSettings, device = LuaSettings }, opened on first use

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

--- Settings from before statsync_settings.lua: statsync.lua, else
-- settings.reader.lua's "statsync". Returns shared, device (tables).
local function oldSettings(dir, LuaSettings)
    local shared, device = {}, {}
    local legacy = G_reader_settings:readSetting(LEGACY_KEY)
    if type(legacy) == "table" then
        for k, v in pairs(legacy) do
            if DEVICE_KEYS[k] then device[k] = v else shared[k] = v end
        end
    end
    if exists(dir .. "/" .. OLD_SHARED_FILE) then
        local ok, old = pcall(LuaSettings.open, LuaSettings, dir .. "/" .. OLD_SHARED_FILE)
        if ok and old and type(old.data) == "table" then
            shared = {}
            for k, v in pairs(old.data) do
                if not DEVICE_KEYS[k] then shared[k] = v end
            end
        end
    end
    -- The old server entry was a copy of Cloud storage's, password and all,
    -- synced to <its folder>/statsync. Keep only the name, and the folder.
    if type(shared.server) == "table" and shared.server.address then
        local old = shared.server
        shared.server = { name = old.name, type = old.type }
        if shared.root == nil then
            shared.root = "/" .. require("statsync/webdav").join(old.url or "", "statsync")
        end
    end
    return shared, device
end

local function openFiles()
    if files then return files end
    local LuaSettings = require("luasettings")
    local dir = DataStorage:getSettingsDir()
    local fresh = not exists(dir .. "/" .. Plugin.SHARED_FILE)
    files = {
        shared = LuaSettings:open(dir .. "/" .. Plugin.SHARED_FILE),
        device = LuaSettings:open(dir .. "/" .. Plugin.DEVICE_FILE),
    }
    if fresh then
        local shared, device = oldSettings(dir, LuaSettings)
        for k, v in pairs(shared) do
            if files.shared.data[k] == nil then files.shared.data[k] = v end
        end
        for k, v in pairs(device) do
            if files.device.data[k] == nil then files.device.data[k] = v end
        end
        if next(shared) or next(device) then
            files.shared:flush()
            files.device:flush()
            logger.info("StatSync: copied earlier settings to", Plugin.SHARED_FILE, "and", Plugin.DEVICE_FILE)
        end
    end
    return files
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

--- The WebDAV servers set up in Cloud storage (with their credentials).
function Plugin.servers()
    local LuaSettings = require("luasettings")
    local ok, cs = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    local servers = {}
    local list = ok and cs and (cs.readSetting and cs:readSetting("cs_servers") or cs.data and cs.data.cs_servers)
    for _, server in ipairs(type(list) == "table" and list or {}) do
        if server.type == "webdav" then table.insert(servers, server) end
    end
    return servers
end

--- The Cloud storage server statsync uses: the one chosen (by name), or with
-- none chosen, the first WebDAV server. Returns server, or nil and why.
function Plugin.server()
    local servers = Plugin.servers()
    local chosen = Plugin.settings().server
    if chosen then
        for _, server in ipairs(servers) do
            if server.name == chosen.name then return server end
        end
        -- Not another server instead: it could be a different place.
        return nil, string.format("WebDAV server \"%s\" not found in Cloud storage", tostring(chosen.name))
    end
    if servers[1] then return servers[1] end
    return nil, "no WebDAV server in Cloud storage"
end

--- The folder on the server, as set ("/KOReader/Statistics" by default).
function Plugin.root()
    local root = Plugin.settings().root
    return (root and root ~= "") and root or Plugin.DEFAULT_ROOT
end

--- Subfolder of the folder for this version's (compressed) segments. 0.2.2
-- wrote uncompressed ones straight into the folder; devices still on it
-- carry on there undisturbed, and an updated device sends everything it has
-- to the new subfolder (a new location, see Store:useLocation).
Plugin.FORMAT_DIR = "v2"

--- The folder for the WebDAV client: relative to the server's address.
function Plugin.remoteRoot()
    return require("statsync/webdav").join(Plugin.root(), Plugin.FORMAT_DIR)
end

--- Where statsync syncs to, for showing and for noticing a change: the
-- server's address (without any user:password@) and the folder. Nil without
-- a server.
function Plugin.serverLocation(server)
    server = server or Plugin.server()
    if not server or not server.address then return nil end
    local WebDav = require("statsync/webdav")
    local root = Plugin.remoteRoot()
    return WebDav.redact(server.address):gsub("/+$", "") .. "/" .. (root ~= "" and root .. "/" or "")
end

function Plugin.serverProblem()
    local server, why = Plugin.server()
    if not server then return why end
    if not server.address or server.address == "" then return "the WebDAV server has no address" end
end

local function statsPlugin()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI.instance
    return ui and ui.statistics
end

local function paths()
    local work = DataStorage:getDataDir() .. "/cache/statsync"
    return {
        stats = DataStorage:getSettingsDir() .. "/statistics.sqlite3",
        state = DataStorage:getSettingsDir() .. "/statsync.sqlite3",
        work = work,
        tmp = work .. "/incoming",
    }
end

local function makeStore()
    local p = paths()
    return Store.new{ sq3 = require("lua-ljsqlite3/init"), stats_path = p.stats, state_path = p.state, logger = logger }
end
Plugin.makeStore = makeStore

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
            local st = Plugin.settings()
            if not opts.interactive and not st.enabled then return false, "automatic sync is off" end
            local problem = Plugin.serverProblem()
            if problem then return false, problem end
            -- Another server or folder: send and import everything there.
            local location = Plugin.serverLocation()
            local lok, changed = pcall(store.useLocation, store, location)
            if not lok then return false, "state database: " .. tostring(changed) end
            if changed then logger.info("StatSync: server or folder changed, syncing everything with", location) end
            local stats_settings = G_reader_settings:readSetting("statistics")
            if stats_settings and stats_settings.is_enabled == false then
                return false, "reading statistics are disabled"
            end
            if not NetworkMgr:isConnected() then return false, "offline" end
            return true
        end,
        makeTransport = function()
            -- Runs in the subprocess: the server is read from settings as
            -- they were when it was forked.
            local server = Plugin.server()
            local http = require("socket.http")
            local sok, socketutil = pcall(require, "socketutil")
            if sok then socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT) end
            local WebDav = require("statsync/webdav")
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

return Plugin
