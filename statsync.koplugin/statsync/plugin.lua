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
--   statsync.lua         the same on every device (fine to sync between
--                        devices, e.g. with Settings sync): enabled,
--                        allow_wifi, server, time_limit
--   statsync_device.lua  this device's own: device_id, status
--
-- Earlier versions kept both under "statsync" in settings.reader.lua; that
-- is moved here the first time.
Plugin.SHARED_FILE = "statsync.lua"
Plugin.DEVICE_FILE = "statsync_device.lua"
local LEGACY_KEY = "statsync"
local DEVICE_KEYS = { device_id = true, status = true }

local files -- { shared = LuaSettings, device = LuaSettings }, opened on first use

local function openFiles()
    if files then return files end
    local LuaSettings = require("luasettings")
    local dir = DataStorage:getSettingsDir()
    files = {
        shared = LuaSettings:open(dir .. "/" .. Plugin.SHARED_FILE),
        device = LuaSettings:open(dir .. "/" .. Plugin.DEVICE_FILE),
    }
    local legacy = G_reader_settings:readSetting(LEGACY_KEY)
    if type(legacy) == "table" then
        for k, v in pairs(legacy) do
            local target = DEVICE_KEYS[k] and files.device or files.shared
            if target.data[k] == nil then target.data[k] = v end
        end
        files.shared:flush()
        files.device:flush()
        G_reader_settings:delSetting(LEGACY_KEY)
        logger.info("StatSync: moved settings to", Plugin.SHARED_FILE, "and", Plugin.DEVICE_FILE)
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

--- The server statsync uses: its own choice, else Reading statistics' Cloud sync server.
-- Returns server, source ("own" | "statistics") or nil.
function Plugin.server()
    local s = Plugin.settings()
    if s.server then return s.server, "own" end
    local stats = G_reader_settings:readSetting("statistics")
    if stats and stats.sync_server then return stats.sync_server, "statistics" end
end

--- The folder on the server statsync uses, relative to the server's address:
-- the folder chosen for the server, then "statsync".
function Plugin.remoteRoot(server)
    return require("statsync/webdav").join(server.url or "", "statsync")
end

--- Where statsync syncs to, for showing: the server's address (without any
-- user:password@), the folder, and "statsync/". Nil without a server.
function Plugin.serverLocation(server)
    server = server or Plugin.server()
    if not server or not server.address then return nil end
    local WebDav = require("statsync/webdav")
    return WebDav.redact(server.address):gsub("/+$", "") .. "/" .. Plugin.remoteRoot(server) .. "/"
end

function Plugin.serverProblem()
    local server = Plugin.server()
    if not server then return "no server set" end
    if server.type ~= "webdav" then return "only WebDAV servers are supported for now" end
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
    controller = Engine.new{
        store = makeStore(),
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
                root = Plugin.remoteRoot(server),
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
