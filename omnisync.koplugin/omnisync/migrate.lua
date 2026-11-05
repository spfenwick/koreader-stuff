--[[--
Moves SuperSync's (supersync.koplugin) data on this device to OmniSync's,
so nothing has to be synced again:

    settings/supersync_settings.lua -> settings/omnisync/settings.lua
    settings/supersync_device.lua   -> settings/omnisync/device.lua
    settings/supersync.sqlite3      -> settings/omnisync/state.sqlite3
    koreader/supersync/             -> koreader/omnisync/
                                       (settings.txt's /supersync_settings.lua
                                       line becomes /omnisync/settings.lua)
    supersync_updates               -> omnisync_updates (mode only)
    gestures for SuperSync's syncs (gestures.lua, profiles.lua) -> OmniSync's

SuperSync mustn't run while its files move. KOReader picks the plugins to
load before any of them starts, so if SuperSync is on, this turns it off
and does nothing else: OmniSync waits for a restart (Migrate.run returns
{ restart = true }). At the next start SuperSync isn't loaded and the
files are moved.

Each step runs only while its OmniSync side doesn't exist yet, so a
second start changes nothing.
--]]

local Migrate = {}

Migrate.OLD_PLUGIN = "supersync"

-- Dispatcher actions (gestures), old name -> new name.
Migrate.ACTIONS = {
    supersync_settings = "omnisync_settings",
    supersync_statistics = "omnisync_statistics",
    supersync_annotations = "omnisync_annotations",
}

local function lfs() return require("libs/libkoreader-lfs") end

local function exists(path)
    return lfs().attributes(path, "mode") ~= nil
end

local function isDir(path)
    return lfs().attributes(path, "mode") == "directory"
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local tmp = path .. ".part"
    local f = assert(io.open(tmp, "wb"))
    f:write(data)
    f:close()
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        error(err, 0)
    end
end

--- Renames the dispatcher actions in a table from gestures.lua or
-- profiles.lua: as keys (gesture -> { action = true, settings = { order } })
-- and as strings in lists (the order of a gesture's actions). Returns
-- whether anything changed.
local function renameActions(t, seen)
    seen = seen or {}
    if seen[t] then return false end
    seen[t] = true
    local changed = false
    local renames = {}
    for k, v in pairs(t) do
        local new = type(k) == "string" and Migrate.ACTIONS[k]
        if new then
            table.insert(renames, k)
        elseif type(v) == "string" and type(k) == "number" and Migrate.ACTIONS[v] then
            t[k] = Migrate.ACTIONS[v]
            changed = true
        end
        if type(v) == "table" and renameActions(v, seen) then changed = true end
    end
    for _, k in ipairs(renames) do
        local new = Migrate.ACTIONS[k]
        if t[new] == nil then t[new] = t[k] end
        t[k] = nil
        changed = true
    end
    return changed
end
Migrate.renameActions = renameActions

--- Is SuperSync running in this KOReader process, or about to be loaded?
local function oldPluginOn(deps)
    if package.loaded[Migrate.OLD_PLUGIN .. "/plugin"] then return true end
    if not deps.plugins_dir then return false end
    if not exists(deps.plugins_dir .. "/" .. Migrate.OLD_PLUGIN .. ".koplugin/main.lua") then return false end
    local disabled = deps.reader_settings and deps.reader_settings:readSetting("plugins_disabled")
    return not (type(disabled) == "table" and disabled[Migrate.OLD_PLUGIN])
end

--- deps: kodir (KOReader's data folder, absolute), settings_dir,
-- plugins_dir (where the plugins are, to find SuperSync), LuaSettings,
-- reader_settings (G_reader_settings), logger.
-- Returns a list of what was moved (empty if nothing), or { restart = true }
-- if SuperSync was on and has just been turned off.
function Migrate.run(deps)
    local done = {}
    local log = deps.logger or { info = function() end, warn = function() end }
    local rs = deps.reader_settings
    local sdir = deps.settings_dir
    local old = {
        shared = sdir .. "/supersync_settings.lua",
        device = sdir .. "/supersync_device.lua",
        state = sdir .. "/supersync.sqlite3",
        lists = deps.kodir .. "/supersync",
    }
    local has_old = exists(old.shared) or exists(old.device) or exists(old.state) or isDir(old.lists)

    if oldPluginOn(deps) then
        if not rs then return done end
        local disabled = rs:readSetting("plugins_disabled") or {}
        disabled[Migrate.OLD_PLUGIN] = true
        rs:saveSetting("plugins_disabled", disabled)
        if rs.flush then rs:flush() end
        log.info("OmniSync: turned SuperSync off; its data is taken over at the next start")
        return { restart = true }
    end

    if rs and rs:readSetting("omnisync_updates") == nil then
        local updates = rs:readSetting("supersync_updates")
        if type(updates) == "table" and updates.mode then
            rs:saveSetting("omnisync_updates", { mode = updates.mode })
        end
    end
    if not has_old then return done end

    local function step(what, fn)
        local ok, err = pcall(fn)
        if ok then
            if err ~= false then
                table.insert(done, what)
                log.info("OmniSync: migrated", what)
            end
        else
            log.warn("OmniSync: migrating", what, "failed:", err)
        end
    end
    local new_dir = sdir .. "/omnisync"
    if not isDir(new_dir) then lfs().mkdir(new_dir) end

    local function move(what, from, to)
        if exists(from) and not exists(to) then
            step(what, function() assert(os.rename(from, to)) end)
        end
    end
    move("settings", old.shared, new_dir .. "/settings.lua")
    move("device ID and status", old.device, new_dir .. "/device.lua")
    -- SQLite's side files go with the database (moved first: the database
    -- itself being there is what says it's done).
    local new_state = new_dir .. "/state.sqlite3"
    if exists(old.state) and not exists(new_state) then
        for _, suffix in ipairs({ "-wal", "-shm", "-journal" }) do
            if exists(old.state .. suffix) then os.rename(old.state .. suffix, new_state .. suffix) end
        end
    end
    move("sync database", old.state, new_state)

    local new_lists = deps.kodir .. "/omnisync"
    if isDir(old.lists) and not isDir(new_lists) then
        step("settings sync's folder", function()
            assert(os.rename(old.lists, new_lists))
            local list = new_lists .. "/settings.txt"
            local data = readFile(list)
            if not data then return end
            local lines, changed = {}, false
            for line in (data .. "\n"):gmatch("([^\n]*)\n") do
                if line:match("^%s*/supersync_settings%.lua%s*$") then
                    line = "/omnisync/settings.lua"
                    changed = true
                end
                table.insert(lines, line)
            end
            -- (data .. "\n") adds an empty last line when data ends with one
            if data:sub(-1) == "\n" then table.remove(lines) end
            if changed then writeFile(list, table.concat(lines, "\n") .. (data:sub(-1) == "\n" and "\n" or "")) end
        end)
    end

    -- Gestures assigned to SuperSync's syncs. Read here, before the
    -- gestures and profiles plugins open these files.
    if deps.LuaSettings and #done > 0 then
        for _, name in ipairs({ "gestures.lua", "profiles.lua" }) do
            local path = sdir .. "/" .. name
            if exists(path) then
                step("gestures in " .. name, function()
                    local s = deps.LuaSettings:open(path)
                    if type(s.data) ~= "table" or not renameActions(s.data) then return false end
                    s:flush()
                end)
            end
        end
    end
    return done
end

return Migrate
