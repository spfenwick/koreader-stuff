--[[--
Moves Settings sync's (rclonesync.koplugin) and Statistics sync's
(statsync.koplugin) data on this device to SuperSync's, the first time
SuperSync starts, so nothing has to be synced again:

    koreader/rclonesync/            -> koreader/supersync/        (moved)
    settings/statsync.sqlite3       -> settings/supersync.sqlite3 (copied)
    settings/statsync_device.lua    -> settings/supersync_device.lua
                                       (device ID, status, reading history read)
    settings/statsync_settings.lua  -> settings/supersync_settings.lua
                                       (allow_wifi and time_limit only)
    statsync_updates / rclonesync_updates -> supersync_updates

The server and folder aren't taken over: SuperSync has one of each for
everything, set by hand. So the copied database forgets where it sent
statistics: the folder set next is taken as the same place, its files
copied there on the server, and nothing is sent again. (A device that
syncs to a folder without its files is stopped, see netjob.lua.)

Each step runs only while its SuperSync side doesn't exist yet. The old
plugins are turned off (plugins_disabled), so they don't sync alongside.
Statistics sync's files are copied rather than moved, as it may still be
running until the next restart.
--]]

local Migrate = {}

Migrate.OLD_PLUGINS = { "rclonesync", "statsync" }

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

local function isDir(path)
    return require("libs/libkoreader-lfs").attributes(path, "mode") == "directory"
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return nil, "can't read " .. from end
    local tmp = to .. ".part"
    local dst = io.open(tmp, "wb")
    if not dst then
        src:close()
        return nil, "can't write " .. tmp
    end
    while true do
        local chunk = src:read(1024 * 1024)
        if not chunk then break end
        dst:write(chunk)
    end
    src:close()
    dst:close()
    local ok, err = os.rename(tmp, to)
    if not ok then os.remove(tmp) end
    return ok, err
end

--- Copies keys from one LuaSettings file to a new one.
local function copySettings(LuaSettings, from, to, keys)
    local ok, old = pcall(LuaSettings.open, LuaSettings, from)
    if not ok or type(old.data) ~= "table" then return false end
    local new = LuaSettings:open(to)
    for _, k in ipairs(keys) do
        if old.data[k] ~= nil and new.data[k] == nil then new.data[k] = old.data[k] end
    end
    new:flush()
    return true
end

--- deps: kodir (KOReader's data folder, absolute), settings_dir,
-- plugins_dir (where the plugins are, for turning off the old ones),
-- LuaSettings, reader_settings (G_reader_settings), forgetLocation(state_path)
-- (makes the copied database forget where it sent statistics), logger.
-- Returns a list of what was done (empty if nothing).
function Migrate.run(deps)
    local done = {}
    local log = deps.logger or { info = function() end, warn = function() end }
    local function step(what, fn)
        local ok, err = pcall(fn)
        if ok then
            if err ~= false then
                table.insert(done, what)
                log.info("SuperSync: migrated", what)
            end
        else
            log.warn("SuperSync: migrating", what, "failed:", err)
        end
    end
    local sdir = deps.settings_dir

    -- Settings sync: its lists, state, pulled settings waiting for a
    -- restart, conflicts and logs. Moved whole.
    local old_dir, new_dir = deps.kodir .. "/rclonesync", deps.kodir .. "/supersync"
    if isDir(old_dir) and not isDir(new_dir) then
        step("settings sync's folder", function() assert(os.rename(old_dir, new_dir)) end)
    end

    -- Statistics sync: what was sent and received, and the annotations.
    local old_db, new_db = sdir .. "/statsync.sqlite3", sdir .. "/supersync.sqlite3"
    if exists(old_db) and not exists(new_db) then
        step("statistics sync's database", function()
            assert(copyFile(old_db, new_db))
            local ok, err = pcall(deps.forgetLocation, new_db)
            if not ok then
                os.remove(new_db) -- else everything would be sent again
                error(err, 0)
            end
        end)
    end
    local new_device = sdir .. "/supersync_device.lua"
    if exists(sdir .. "/statsync_device.lua") and not exists(new_device) then
        step("statistics sync's device ID", function()
            return copySettings(deps.LuaSettings, sdir .. "/statsync_device.lua", new_device,
                { "device_id", "status", "ann_scanned" })
        end)
    end
    local new_shared = sdir .. "/supersync_settings.lua"
    if exists(sdir .. "/statsync_settings.lua") and not exists(new_shared) then
        step("statistics sync's settings", function()
            return copySettings(deps.LuaSettings, sdir .. "/statsync_settings.lua", new_shared,
                { "allow_wifi", "time_limit" })
        end)
    end

    local rs = deps.reader_settings
    if rs and rs:readSetting("supersync_updates") == nil then
        local old = rs:readSetting("statsync_updates") or rs:readSetting("rclonesync_updates")
        if type(old) == "table" and old.mode then
            step("update settings", function()
                rs:saveSetting("supersync_updates", { mode = old.mode })
            end)
        end
    end

    -- The old plugins would carry on syncing next to SuperSync.
    if rs and deps.plugins_dir then
        local disabled = rs:readSetting("plugins_disabled") or {}
        local changed = false
        for _, name in ipairs(Migrate.OLD_PLUGINS) do
            if exists(deps.plugins_dir .. "/" .. name .. ".koplugin/main.lua") and not disabled[name] then
                disabled[name] = true
                changed = true
            end
        end
        if changed then
            step("turned off the old plugins", function() rs:saveSetting("plugins_disabled", disabled) end)
        end
    end
    return done
end

return Migrate
