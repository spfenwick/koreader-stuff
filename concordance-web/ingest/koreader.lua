--[[--
The few KOReader pieces the ingester needs, loaded without KOReader:
lua-ljsqlite3, and the statistics plugin's createDB (so the statistics
database has exactly KOReader's schema). Same approach as the plugin's
tests (tests/concordance/support.lua).

Paths come from the environment:
  CONCORDANCE_LIB    folder holding concordance/*.lua (the plugin's modules)
  KOREADER_BASE   koreader-base files: ffi/*.lua, thirdparty/lua-ljsqlite3/init.lua
  KOREADER_STATS  KOReader's plugins/statistics.koplugin/main.lua
--]]

local K = {}

local function env(name)
    local v = os.getenv(name)
    if not v or v == "" then error(name .. " is not set", 0) end
    return v
end

K.lib = env("CONCORDANCE_LIB")
K.base = env("KOREADER_BASE")
K.stats_main = env("KOREADER_STATS")

package.path = K.lib .. "/?.lua;" .. K.base .. "/?.lua;" .. package.path

local ffi = require("ffi")
-- What KOReader's ffi/loadlib sets up, enough for posix_h, ljsqlite3 and zstd.
ffi.libc = ffi.libc or "gnu"
ffi.loadlib = ffi.loadlib or function(name, ver)
    return ffi.load("lib" .. name .. ".so" .. (ver and ("." .. ver) or ""))
end
require("ffi/posix_h")

package.preload["lua-ljsqlite3/init"] = function()
    return dofile(K.base .. "/thirdparty/lua-ljsqlite3/init.lua")
end
K.SQ3 = require("lua-ljsqlite3/init")

-- Stand-ins for the KOReader modules statistics.koplugin/main.lua requires
-- at load time. createDB only needs Device:canUseWAL.
local function stub(name)
    local any
    any = setmetatable({}, {
        __index = function() return any end,
        __call = function() return any end,
        __concat = function(a, b) return tostring(a == any and "" or a) .. tostring(b == any and "" or b) end,
    })
    if name == "datastorage" then
        return { getDataDir = function() return "/nonexistent" end, getSettingsDir = function() return "/nonexistent" end }
    elseif name == "device" then
        return { canUseWAL = function() return true end, isAndroid = function() return false end }
    elseif name == "ui/widget/widget" then
        return { extend = function(_, o) o = o or {}; o.__index = o; return o end }
    elseif name == "gettext" then
        return setmetatable({ pgettext = function(_, s) return s end, ngettext = function(s) return s end },
            { __call = function(_, s) return s end })
    elseif name == "logger" then
        return { info = function() end, warn = function() end, dbg = function() end, err = function() end }
    elseif name == "lua-ljsqlite3/init" then
        return K.SQ3
    elseif name == "ffi/util" then
        return { template = function(s) return s end, copyFile = function() end }
    end
    return any
end

--- Creates KOReader's statistics tables in the database at `path` (if missing).
function K.createStatsDB(path)
    do
        local conn = K.SQ3.open(path)
        local n = conn:rowexec("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('book', 'page_stat_data');")
        conn:close()
        if tonumber(n) == 2 then return end
    end
    local chunk = assert(loadfile(K.stats_main))
    setfenv(chunk, setmetatable({ require = stub }, { __index = _G }))
    local RS = chunk()
    local stats = setmetatable({ settings = { is_enabled = true }, ui = {} }, { __index = RS })
    local conn = K.SQ3.open(path)
    stats:createDB(conn)
    conn:close()
end

return K
