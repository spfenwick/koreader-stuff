--[[--
Moves OmniSync's (omnisync.koplugin, Concordance's old name) data on this
device to Concordance's, so nothing has to be synced again:

    settings/omnisync/     -> settings/concordance/ (settings, device ID,
                              sync database, settings sync's state)
    cache/omnisync/        -> cache/concordance/
    omnisync_updates       -> concordance_updates (mode only)
    gestures for OmniSync's syncs (gestures.lua, profiles.lua) -> Concordance's

Settings sync's own files move too: the list becomes
settings/concordance/sync.txt, and its lines naming settings/omnisync/ name
settings/concordance/. What settings sync remembers of settings/omnisync/
(state.tsv) is forgotten, so the list and settings.lua are sent again under
their new paths, rather than taken as deleted on the server (where nothing
has them yet). Pulled settings still waiting are put in place first, where
OmniSync would have put them.

OmniSync mustn't run while its files move. KOReader picks the plugins to
load before any of them starts, so if OmniSync is on, this turns it off
and does nothing else: Concordance waits for a restart (Migrate.run
returns { restart = true }). At the next start OmniSync isn't loaded and
the files are moved.

Each step runs only while its new side doesn't exist yet, so a second
start changes nothing.
--]]

local Migrate = {}

Migrate.OLD_PLUGIN = "omnisync"

-- Dispatcher actions (gestures), old name -> new name.
Migrate.ACTIONS = {
    omnisync_sync = "concordance_sync",
    omnisync_settings = "concordance_settings",
    omnisync_statistics = "concordance_statistics",
    omnisync_annotations = "concordance_annotations",
}

local OLD_DIR = "settings/omnisync"
local NEW_DIR = "settings/concordance"

local function lfs() return require("libs/libkoreader-lfs") end

local function exists(path)
    return lfs().attributes(path, "mode") ~= nil
end

local function isDir(path)
    return lfs().attributes(path, "mode") == "directory"
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

--- The list with its lines naming OmniSync's folders renamed.
function Migrate.convertList(text)
    return (text:gsub("([^\n]*)", function(line)
        if line:match("^%s*[#;]") then return line end
        return (line:gsub("/settings/omnisync/", "/settings/concordance/")
            :gsub("/plugins/omnisync%.koplugin", "/plugins/concordance.koplugin"))
    end))
end

--- Renames gestures for OmniSync's syncs in gestures.lua and profiles.lua.
-- Also run after pulled settings are put in place: a device not updated
-- yet can still send gestures with the old names. step(what, fn) as in run.
function Migrate.renameGestures(deps, step)
    if not deps.LuaSettings then return end
    for _, name in ipairs({ "gestures.lua", "profiles.lua" }) do
        local path = deps.settings_dir .. "/" .. name
        local text = exists(path) and io.open(path, "rb")
        local data = text and text:read("*a")
        if text then text:close() end
        -- Only opened (and so parsed) when an old name is in it.
        if data and data:find("omnisync_", 1, true) then
            step("gestures in " .. name, function()
                local s = deps.LuaSettings:open(path)
                if type(s.data) ~= "table" or not renameActions(s.data) then return false end
                s:flush()
            end)
        end
    end
end

--- Is OmniSync running in this KOReader process, or about to be loaded?
local function oldPluginOn(deps)
    if package.loaded[Migrate.OLD_PLUGIN .. "/plugin"] then return true end
    if not deps.plugins_dir then return false end
    if not exists(deps.plugins_dir .. "/" .. Migrate.OLD_PLUGIN .. ".koplugin/main.lua") then return false end
    local disabled = deps.reader_settings and deps.reader_settings:readSetting("plugins_disabled")
    return not (type(disabled) == "table" and disabled[Migrate.OLD_PLUGIN])
end

local function fromOmniSync(deps, step, done)
    local Engine = require("concordance/settings_engine")
    local rs = deps.reader_settings
    local old = deps.settings_dir .. "/omnisync"
    local new = deps.settings_dir .. "/concordance"
    if rs and rs:readSetting("concordance_updates") == nil then
        local updates = rs:readSetting("omnisync_updates")
        if type(updates) == "table" and updates.mode then
            rs:saveSetting("concordance_updates", { mode = updates.mode })
        end
    end
    if not isDir(old) or exists(new) then return end
    local before = #done

    -- Pulled settings still waiting go in place first, by OmniSync's paths.
    local p = Engine.paths(deps.kodir)
    local old_paths = {}
    for k, v in pairs(p) do
        old_paths[k] = type(v) == "string" and v:gsub("/" .. NEW_DIR .. "/", "/" .. OLD_DIR .. "/", 1) or v
    end
    if Engine.isPending(old_paths) then
        step("pulled settings", function() Engine.applyPending(old_paths) end)
    end

    step("settings, device ID and sync database", function() assert(os.rename(old, new)) end)
    if not isDir(new) then return end

    local old_cache = deps.kodir .. "/cache/omnisync"
    local new_cache = deps.kodir .. "/cache/concordance"
    if isDir(old_cache) and not exists(new_cache) then
        step("cache", function() assert(os.rename(old_cache, new_cache)) end)
    end

    if exists(p.state .. "/state.tsv") then
        step("settings sync's state", function()
            local state = Engine.loadState(p)
            local prefix = OLD_DIR .. "/"
            for _, kind in ipairs({ "sync", "pull" }) do
                for path in pairs(state[kind]) do
                    if path:sub(1, #prefix) == prefix then state[kind][path] = nil end
                end
            end
            assert(Engine.saveState(p, state))
        end)
    end

    if exists(p.list) then
        step("settings sync's list", function()
            local text = assert(Engine.readFile(p.list))
            local converted = Migrate.convertList(text)
            if converted == text then return false end
            assert(Engine.writeFile(p.list, converted))
        end)
    end

    -- Read here, before the gestures and profiles plugins open these files.
    Migrate.renameGestures(deps, step)
    if #done > before then done.omnisync = true end
end

--- deps: kodir (KOReader's data folder, absolute), settings_dir,
-- plugins_dir (where the plugins are, to find OmniSync), LuaSettings,
-- reader_settings (G_reader_settings), logger.
-- Returns a list of what was done (empty if nothing; .omnisync if
-- OmniSync's data was taken over), or { restart = true } if OmniSync was
-- on and has just been turned off.
function Migrate.run(deps)
    local done = {}
    local log = deps.logger or { info = function() end, warn = function() end }
    local rs = deps.reader_settings
    if oldPluginOn(deps) then
        if not rs then return done end
        local disabled = rs:readSetting("plugins_disabled") or {}
        disabled[Migrate.OLD_PLUGIN] = true
        rs:saveSetting("plugins_disabled", disabled)
        if rs.flush then rs:flush() end
        log.info("Concordance: turned OmniSync off; its data is taken over at the next start")
        return { restart = true }
    end
    fromOmniSync(deps, Migrate.stepper(done, log), done)
    return done
end

--- step(what, fn): runs fn, and records what in done unless fn returned
-- false (nothing to do) or failed (logged).
function Migrate.stepper(done, log)
    return function(what, fn)
        local ok, err = pcall(fn)
        if ok then
            if err ~= false then
                table.insert(done, what)
                log.info("Concordance: migrated", what)
            end
        else
            log.warn("Concordance: migrating", what, "failed:", err)
        end
    end
end

return Migrate
