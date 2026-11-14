--[[
The plugin's settings, in settings/athenaeum/settings.lua (with the
catalog databases and covers), not in KOReader's settings.reader.lua.
(Cloud library's settings/cloudlibrary is renamed settings/athenaeum by
migrate.lua.)

Keys: the plugin's settings (see library.lua), and "updates" for the
updater (updater.lua).

Earlier versions (as Cloud library) kept them in settings.reader.lua,
under "cloudlibrary" and "cloudlibrary_updates". Those are moved here when
found (each time, so a copy written by an older version of the plugin isn't
lost) and removed from settings.reader.lua.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")

local Settings = {}

local OLD_PLUGIN_KEY = "cloudlibrary"
local OLD_UPDATES_KEY = "cloudlibrary_updates"
Settings.UPDATES_KEY = "updates"

local store

function Settings.path()
    return DataStorage:getSettingsDir() .. "/athenaeum/settings.lua"
end

local function migrate(s)
    local moved = false
    local old = G_reader_settings:readSetting(OLD_PLUGIN_KEY)
    if type(old) == "table" then
        for k, v in pairs(old) do s.data[k] = v end
        moved = true
    end
    local old_updates = G_reader_settings:readSetting(OLD_UPDATES_KEY)
    if type(old_updates) == "table" then
        s.data[Settings.UPDATES_KEY] = old_updates
        moved = true
    end
    if moved then
        s:flush()
        G_reader_settings:delSetting(OLD_PLUGIN_KEY)
        G_reader_settings:delSetting(OLD_UPDATES_KEY)
        logger.info("Athenaeum: settings moved to", Settings.path())
    end
end

--- The settings file (a LuaSettings), opened once.
function Settings.store()
    if not store then
        util.makePath(DataStorage:getSettingsDir() .. "/athenaeum")
        store = LuaSettings:open(Settings.path())
        migrate(store)
    end
    return store
end

--- The plugin's settings, as a table of keys (read only: use save()).
function Settings.all()
    return Settings.store().data
end

function Settings.save(key, value)
    local s = Settings.store()
    s:saveSetting(key, value)
    s:flush()
end

--- For tests: forget the open file (and read it again next time).
function Settings.reset()
    store = nil
end

return Settings
