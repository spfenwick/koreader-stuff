--[[--
Moves an installation from the plugin's old name, Cloud library
("cloudlibrary"), to Athenaeum ("athenaeum").

The old folder name, cloudlibrary.koplugin, is also used by another
KOReader plugin (gytwo/cloudlibrary.koplugin), and ZenPM identifies KOReader
plugins by their folder name, so the two clashed there.

Copies of Cloud library update from the rolling release "cloudlibrary" and
unpack the update into cloudlibrary.koplugin. Each Athenaeum release is
published there too (the same files, in a cloudlibrary.koplugin folder:
see RELEASING.md), so those copies update to Athenaeum, and this finishes
the move the next time KOReader starts:

- The plugin's folder: cloudlibrary.koplugin is renamed athenaeum.koplugin.
  If there's already an athenaeum.koplugin, the old folder is removed and
  this copy doesn't load.
- Started from athenaeum.koplugin, a cloudlibrary.koplugin next to it that
  is this plugin's (an old Cloud library, or a copy of Athenaeum) is
  removed, so it doesn't run as well. Another plugin's cloudlibrary.koplugin
  is left alone: only one whose updater updates from this repository is
  this plugin's.
- Settings, catalogs and covers: settings/cloudlibrary is renamed
  settings/athenaeum, unless that's already there.
- Gestures, profiles and keyboard shortcuts: the action "cloudlibrary_sync"
  becomes "athenaeum_sync".

main.lua runs this first, while KOReader loads the plugins: KOReader loads
every plugin's main.lua before starting any of them, so the gesture,
profile and shortcut settings aren't open yet. Plugins in one folder load
in the order of their paths, so athenaeum.koplugin loads before
cloudlibrary.koplugin and removes it before KOReader loads it.

Renaming its own folder while it loads: the rest of main.lua then loads the
plugin's modules from the new folder (fixPackagePath). KOReader still has
the old folder for this session (the plugin's `path`, and its search path
for the plugin's modules), so main.lua corrects both when the plugin
starts (fixLoadedPlugin).
]]

local logger = require("logger")

local Migrate = {
    OLD_NAME = "cloudlibrary",
    NEW_NAME = "athenaeum",
    OLD_ACTION = "cloudlibrary_sync",
    NEW_ACTION = "athenaeum_sync",
    REPO = "spfenwick/koreader-stuff",
    -- Set by atLoad:
    dir = nil,        -- the plugin's folder (after any move)
    moved_from = nil, -- the folder it was moved from, this session
}

local function lfs() return require("libs/libkoreader-lfs") end

local function exists(path) return lfs().attributes(path, "mode") ~= nil end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function removeDir(path)
    local ok, err = pcall(function() return require("ffi/util").purgeDir(path) end)
    if not ok or exists(path) then
        logger.warn("Athenaeum: can't remove", path, err)
        return false
    end
    logger.info("Athenaeum: removed", path)
    return true
end

--- Lua pattern matching s literally.
local function literal(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

--- The plugin's folder, from where this file is.
function Migrate.ownDir()
    local source = debug.getinfo(1, "S").source
    return source:match("^@(.*)/athenaeum/[^/]*$")
end

--- True if the plugin folder at path is this plugin (an old Cloud library,
-- or Athenaeum in the old folder): its updater updates from this repository.
-- gytwo's cloudlibrary.koplugin has no such file.
function Migrate.isOurs(path)
    for _i, module in ipairs({ "cloudlibrary/updatecore.lua", "athenaeum/updatecore.lua" }) do
        local code = read(path .. "/" .. module)
        if code and code:find('REPO = "' .. Migrate.REPO .. '"', 1, true) then return true end
    end
    return false
end

-- The plugin's folder ------------------------------------------------------------------------

--- Moves this copy out of the old folder, or removes an old copy next to
-- it. dir: the plugin's folder (default: from where this file is).
-- @return false if this copy shouldn't load (another copy is in the new
-- folder), else true
function Migrate.folder(dir)
    dir = dir or Migrate.ownDir()
    Migrate.dir = dir
    if not dir then return true end
    local parent, base = dir:match("^(.*)/([^/]+)$")
    if not parent then return true end
    local old_folder, new_folder = Migrate.OLD_NAME .. ".koplugin", Migrate.NEW_NAME .. ".koplugin"
    if base == old_folder then
        local target = parent .. "/" .. new_folder
        if exists(target) then
            logger.info("Athenaeum: already in", target, "- removing this copy")
            removeDir(dir)
            return false
        end
        local ok, err = os.rename(dir, target)
        if not ok then
            -- It works from here too; moved at the next start.
            logger.warn("Athenaeum: can't move", dir, "to", target, err)
            return true
        end
        logger.info("Athenaeum: moved", dir, "to", target)
        Migrate.dir, Migrate.moved_from = target, dir
    elseif base == new_folder then
        local old = parent .. "/" .. old_folder
        if exists(old) and Migrate.isOurs(old) then removeDir(old) end
    end
    return true
end

--- After a move: the rest of main.lua loads modules from the new folder.
function Migrate.fixPackagePath()
    if not Migrate.moved_from then return end
    package.path = Migrate.dir .. "/?.lua;" .. package.path
end

--- After a move this session, at the end of main.lua: KOReader reads
-- _meta.lua (version, fullname, description) from the old folder once
-- main.lua has run, finds nothing there and leaves it out, so it's added
-- here from the new folder. Without it, the plugin has no version this
-- session ("Check for updates (?)", and Concordance doesn't list it).
function Migrate.addMeta(plugin_class)
    if not Migrate.moved_from then return end
    local ok, meta = pcall(dofile, Migrate.dir .. "/_meta.lua")
    if not ok or type(meta) ~= "table" then
        logger.warn("Athenaeum: can't read _meta.lua after moving:", meta)
        return
    end
    for k, v in pairs(meta) do
        if k ~= "name" and plugin_class[k] == nil then plugin_class[k] = v end
    end
end

--- When the plugin starts, after a move this session: KOReader has the old
-- folder as the plugin's path and in its search path for modules.
-- plugin_class: the table main.lua returned (its instances inherit `path`).
function Migrate.fixLoadedPlugin(plugin_class)
    if not Migrate.moved_from then return end
    if plugin_class.path == Migrate.moved_from then plugin_class.path = Migrate.dir end
    local function replace(paths, suffix)
        local to = (Migrate.dir .. suffix):gsub("%%", "%%%%")
        return (paths:gsub(literal(Migrate.moved_from .. suffix), to))
    end
    package.path = replace(package.path, "/?.lua")
    package.cpath = replace(package.cpath, "/lib/?.so")
end

-- Settings -----------------------------------------------------------------------------------

--- settings/cloudlibrary → settings/athenaeum, unless that's already there.
function Migrate.settings(settings_dir)
    settings_dir = settings_dir or require("datastorage"):getSettingsDir()
    local old = settings_dir .. "/" .. Migrate.OLD_NAME
    local new = settings_dir .. "/" .. Migrate.NEW_NAME
    if lfs().attributes(old, "mode") ~= "directory" then return end
    if exists(new) then
        logger.info("Athenaeum: not moving", old, "-", new, "is already there")
        return
    end
    local ok, err = os.rename(old, new)
    if ok then
        logger.info("Athenaeum: settings moved to", new)
    else
        logger.warn("Athenaeum: can't move", old, "to", new, err)
    end
end

--- Renames the action in a table of gestures, profiles or shortcuts (to
-- any depth): keys, and values in lists (a gesture's order of actions).
-- @return true if anything changed
function Migrate.renameAction(t, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 6 then return false end
    local changed = false
    if t[Migrate.OLD_ACTION] ~= nil then
        if t[Migrate.NEW_ACTION] == nil then t[Migrate.NEW_ACTION] = t[Migrate.OLD_ACTION] end
        t[Migrate.OLD_ACTION] = nil
        changed = true
    end
    for i, v in ipairs(t) do
        if v == Migrate.OLD_ACTION then
            t[i] = Migrate.NEW_ACTION
            changed = true
        end
    end
    for _k, v in pairs(t) do
        if type(v) == "table" and Migrate.renameAction(v, depth + 1) then changed = true end
    end
    return changed
end

--- The action's new name in gestures.lua, profiles.lua and hotkeys.lua.
function Migrate.actions(settings_dir)
    settings_dir = settings_dir or require("datastorage"):getSettingsDir()
    for _i, name in ipairs({ "gestures.lua", "profiles.lua", "hotkeys.lua" }) do
        local path = settings_dir .. "/" .. name
        local code = read(path)
        if code and code:find(Migrate.OLD_ACTION, 1, true) then
            local ok, err = pcall(function()
                local s = require("luasettings"):open(path)
                if Migrate.renameAction(s.data) then
                    s:flush()
                    logger.info("Athenaeum: renamed the quick sync action in", path)
                end
            end)
            if not ok then logger.warn("Athenaeum: can't update", path, err) end
        end
    end
end

-- All of it ----------------------------------------------------------------------------------

--- At load (main.lua). Never fails: an error leaves things as they were
-- and the plugin loads.
-- @return false if this copy shouldn't load, else true
function Migrate.atLoad()
    local ok, load = pcall(Migrate.folder)
    if not ok then
        logger.warn("Athenaeum: moving from cloudlibrary.koplugin:", load)
        load = true
    end
    if not load then return false end
    Migrate.fixPackagePath()
    local ok_s, err_s = pcall(Migrate.settings)
    if not ok_s then logger.warn("Athenaeum: moving settings:", err_s) end
    local ok_a, err_a = pcall(Migrate.actions)
    if not ok_a then logger.warn("Athenaeum: renaming the gesture action:", err_a) end
    return true
end

return Migrate
