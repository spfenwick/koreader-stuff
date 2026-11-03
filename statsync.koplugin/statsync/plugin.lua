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

local SETTINGS_KEY = "statsync"

local Plugin = {}

function Plugin.settings()
    return G_reader_settings:readSetting(SETTINGS_KEY, {})
end

function Plugin.saveSettings(s)
    G_reader_settings:saveSetting(SETTINGS_KEY, s or Plugin.settings())
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
    local s = Plugin.settings()
    if not s.device_id then
        s.device_id = randomId()
        Plugin.saveSettings(s)
        logger.info("StatSync: new device ID", s.device_id)
    end
    return s.device_id
end

function Plugin.resetDeviceId()
    local s = Plugin.settings()
    s.device_id = nil
    Plugin.saveSettings(s)
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
        status = s.status,
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
                root = WebDav.join(server.url or "", "statsync"),
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
            local st = Plugin.settings()
            st.status = status
            Plugin.saveSettings(st)
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
