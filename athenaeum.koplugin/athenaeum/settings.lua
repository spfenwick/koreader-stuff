--[[
The plugin's settings, in two files in settings/athenaeum/ (with the
catalog databases and covers), not in KOReader's settings.reader.lua:

- shared.lua: what can be the same on every device: the catalog, the
  badges, search, ZenOS groups, showing cloud books, the sync schedule.
  The catalog is kept as its URL and username, looked up in each device's
  own OPDS catalogs (the password stays there), so a device whose OPDS
  catalog has a different URL or username finds no catalog.
  Concordance's settings sync can sync it: list
  /settings/athenaeum/shared.lua in settings/concordance/sync.txt.
- settings.lua: this device's own: the library folder (paths differ
  between devices), and "updates", the updater's state (updater.lua),
  which changes at each check.

(Cloud library's settings/cloudlibrary is renamed settings/athenaeum by
migrate.lua.)

Up to 0.8.1 everything was in settings.lua. The shared keys found there are
moved to shared.lua when it doesn't have them yet (so a shared.lua pulled
from another device wins), and removed from settings.lua.

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

--- The keys kept in shared.lua. Everything else is this device's own.
Settings.SHARED = {
    server = true, badge_cloud = true, badge_local = true, badge_noncloud = true,
    search = true, zenos_groups = true, show = true,
    quick_sync = true, full_sync = true, auto_sync = true,
}

local store, shared, merged

local function dir()
    return DataStorage:getSettingsDir() .. "/athenaeum"
end

function Settings.path()
    return dir() .. "/settings.lua"
end

function Settings.sharedPath()
    return dir() .. "/shared.lua"
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

-- Shared keys in settings.lua (from 0.8.1 or earlier, or just moved from
-- settings.reader.lua) go to shared.lua, unless it already has them.
local function split(s, sh)
    local found = false
    for k in pairs(Settings.SHARED) do
        if s.data[k] ~= nil then
            if sh.data[k] == nil then sh.data[k] = s.data[k] end
            s.data[k] = nil
            found = true
        end
    end
    if found then
        sh:flush()
        s:flush()
        logger.info("Athenaeum: shared settings moved to", Settings.sharedPath())
    end
end

local function open()
    if store then return end
    util.makePath(dir())
    store = LuaSettings:open(Settings.path())
    shared = LuaSettings:open(Settings.sharedPath())
    migrate(store)
    split(store, shared)
end

--- This device's settings file (a LuaSettings), opened once. The updater
-- keeps its state here.
function Settings.store()
    open()
    return store
end

--- The shared settings file (a LuaSettings), opened once.
function Settings.sharedStore()
    open()
    return shared
end

--- The plugin's settings, both files' keys in one table (read only: use
-- save()).
function Settings.all()
    open()
    if not merged then
        merged = {}
        for k, v in pairs(store.data) do
            if not Settings.SHARED[k] then merged[k] = v end
        end
        for k, v in pairs(shared.data) do
            if Settings.SHARED[k] then merged[k] = v end
        end
    end
    return merged
end

function Settings.save(key, value)
    open()
    local s = Settings.SHARED[key] and shared or store
    s:saveSetting(key, value)
    s:flush()
    merged = nil
end

--- For tests: forget the open files (and read them again next time).
function Settings.reset()
    store, shared, merged = nil, nil, nil
end

return Settings
