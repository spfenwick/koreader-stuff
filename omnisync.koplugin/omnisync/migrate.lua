--[[--
Moves SuperSync's (supersync.koplugin) data on this device to OmniSync's,
so nothing has to be synced again:

    settings/supersync_settings.lua -> settings/omnisync/settings.lua
    settings/supersync_device.lua   -> settings/omnisync/device.lua
    settings/supersync.sqlite3      -> settings/omnisync/state.sqlite3
    koreader/supersync/             -> koreader/omnisync/ (then as below)
    supersync_updates               -> omnisync_updates (mode only)
    gestures for SuperSync's syncs (gestures.lua, profiles.lua) -> OmniSync's

SuperSync mustn't run while its files move. KOReader picks the plugins to
load before any of them starts, so if SuperSync is on, this turns it off
and does nothing else: OmniSync waits for a restart (Migrate.run returns
{ restart = true }). At the next start SuperSync isn't loaded and the
files are moved.

Then settings sync's old layout, koreader/omnisync/, becomes the new one
(see settings_engine.lua):

    settings.txt, plugins.txt,      -> settings/omnisync/sync.txt, one list
    patches.txt                        from KOReader's folder (the same as
                                       the server's copy, made by the same
                                       conversion: see Migrate.convertLists)
    state.tsv (by folder)           -> settings/omnisync/settings-sync/state.tsv
                                       (by path in KOReader's folder)
    conflicts/, last.log, apply.log -> settings/omnisync/settings-sync/
    cache.tsv                       -> cache/omnisync/settings-cache.tsv
    pending.tsv, staging/           put in place first, as at any start

and the old lists are kept in settings-sync/old-lists/.

Each step runs only while its new side doesn't exist yet, so a second
start changes nothing.
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

-- SuperSync's data. step(what, fn) runs a step and records it.
local function fromSuperSync(deps, step, done)
    local rs = deps.reader_settings
    local sdir = deps.settings_dir
    local old = {
        shared = sdir .. "/supersync_settings.lua",
        device = sdir .. "/supersync_device.lua",
        state = sdir .. "/supersync.sqlite3",
        lists = deps.kodir .. "/supersync",
    }
    local has_old = exists(old.shared) or exists(old.device) or exists(old.state) or isDir(old.lists)
    if rs and rs:readSetting("omnisync_updates") == nil then
        local updates = rs:readSetting("supersync_updates")
        if type(updates) == "table" and updates.mode then
            rs:saveSetting("omnisync_updates", { mode = updates.mode })
        end
    end
    if not has_old then return end
    local before = #done
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
    -- (Not once settings sync has its new layout: see newLayout.)
    if isDir(old.lists) and not isDir(new_lists)
            and not exists(sdir .. "/omnisync/settings-sync/state.tsv") then
        -- Its settings.txt's /supersync_settings.lua line is taken care of
        -- by convertLists.
        step("settings sync's folder", function() assert(os.rename(old.lists, new_lists)) end)
    end

    -- Gestures assigned to SuperSync's syncs. Read here, before the
    -- gestures and profiles plugins open these files.
    if deps.LuaSettings and #done > before then
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
    if #done > before then done.supersync = true end
end

-- Settings sync's old layout -------------------------------------------------

local LIST_HEADER = "# What OmniSync syncs: one pattern per line, from KOReader's folder.\n"
    .. "# A line starting with < is only ever pulled from the server.\n\n"
local LIST_FOOTER = "# Synced in every folder before\n< /fonts/**\n/data/dict/**\n/styletweaks/**\n"
local OLD_LISTS = { { "settings.txt", "settings" }, { "plugins.txt", "plugins" }, { "patches.txt", "patches" } }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- The one list from the three old ones ({ ["settings.txt"] = text, … },
-- missing ones nil). Byte for byte what the server's conversion script
-- makes, so devices and server agree without sending anything: comments
-- kept, /x becomes /<folder>/x, an unanchored x both /<folder>/x and
-- /<folder>/**/x, and settings.txt's //x becomes /x. The folders that were
-- always synced are added at the end.
function Migrate.convertLists(texts)
    local out = { LIST_HEADER }
    for _, l in ipairs(OLD_LISTS) do
        local name, folder = l[1], l[2]
        local text = texts[name]
        if text then
            table.insert(out, "# From " .. name .. "\n")
            text = text:gsub("\r", "")
            if text ~= "" and text:sub(-1) ~= "\n" then text = text .. "\n" end
            for line in text:gmatch("([^\n]*)\n") do
                local t = trim(line)
                if t == "" or t:match("^[#;]") then
                    table.insert(out, line .. "\n")
                elseif t == "/supersync_settings.lua" then
                    if folder == "settings" then table.insert(out, "/settings/omnisync/settings.lua\n") end
                elseif t:sub(1, 2) == "//" then
                    if folder == "settings" then table.insert(out, t:sub(2) .. "\n") end
                elseif t:sub(1, 1) == "/" then
                    table.insert(out, "/" .. folder .. t .. "\n")
                else
                    table.insert(out, "/" .. folder .. "/" .. t .. "\n/" .. folder .. "/**/" .. t .. "\n")
                end
            end
        end
    end
    table.insert(out, LIST_FOOTER)
    return table.concat(out)
end

-- Old state areas: the folder in KOReader's folder each was for.
local AREA_PREFIX = {
    settings = "settings/", plugins = "plugins/", patches = "patches/",
    fonts = "fonts/", dict = "data/dict/", styletweaks = "styletweaks/",
}

--- A path in an old area, as a path in KOReader's folder (nil for the lists).
function Migrate.newPath(area, path)
    if area == "settings" and path:sub(1, 10) == "@koreader/" then return path:sub(11) end
    local prefix = AREA_PREFIX[area]
    return prefix and prefix .. path or nil
end

local function rmTree(path)
    if isDir(path) then
        for name in lfs().dir(path) do
            if name ~= "." and name ~= ".." then rmTree(path .. "/" .. name) end
        end
        lfs().rmdir(path)
    else
        os.remove(path)
    end
end

local function readTsv(path)
    local rows = {}
    for line in (readFile(path) or ""):gmatch("[^\n]+") do
        local row = {}
        for value in (line .. "\t"):gmatch("([^\t]*)\t") do table.insert(row, value) end
        table.insert(rows, row)
    end
    return rows
end

local function moveOrCopy(from, to)
    if os.rename(from, to) then return true end
    local data = readFile(from)
    if not data then return false end
    writeFile(to, data)
    os.remove(from)
    return true
end

local function newLayout(deps, step, done)
    local Engine = require("omnisync/settings_engine")
    local old = deps.kodir .. "/omnisync"
    local p = Engine.paths(deps.kodir)
    if not isDir(old) or exists(p.state .. "/state.tsv") then return end
    step("settings sync's lists and state", function()
        assert(Engine.mkdirs(p.state))
        -- Pulled settings still waiting go in place first, where they went
        -- before: settings/, or KOReader's folder for @koreader/ ones.
        for _, row in ipairs(readTsv(old .. "/pending.tsv")) do
            local op, path = row[1], row[2] or ""
            local dest = path:sub(1, 10) == "@koreader/" and deps.kodir .. "/" .. path:sub(11)
                or deps.kodir .. "/settings/" .. path
            if op == "copy" then
                Engine.mkdirs(dest:match("^(.*)/[^/]+$"))
                moveOrCopy(old .. "/staging/" .. path, dest)
            elseif op == "delete" then
                os.remove(dest)
            end
        end

        -- The old state, by folder; whether the lists are as last synced.
        local old_state = {}
        for _, row in ipairs(readTsv(old .. "/state.tsv")) do
            if row[1] and row[2] and row[3] then
                old_state[row[1]] = old_state[row[1]] or {}
                old_state[row[1]][row[2]] = row[3]
            end
        end
        local texts, lists_synced, as_synced = {}, false, true
        for _, l in ipairs(OLD_LISTS) do
            local path = old .. "/" .. l[1]
            texts[l[1]] = readFile(path)
            local was = old_state.lists and old_state.lists[l[1]]
            if was then lists_synced = true end
            local now = texts[l[1]] and Engine.md5Files({ path })[path]
            if now ~= was then as_synced = false end
        end

        local wrote_list = false
        if not exists(p.list) and (texts["settings.txt"] or texts["plugins.txt"] or texts["patches.txt"]) then
            assert(Engine.writeFile(p.list, Migrate.convertLists(texts)))
            wrote_list = true
        end

        for _, name in ipairs({ "conflicts", "last.log", "apply.log" }) do
            if exists(old .. "/" .. name) and not exists(p.state .. "/" .. name) then
                os.rename(old .. "/" .. name, p.state .. "/" .. name)
            end
        end
        if exists(old .. "/cache.tsv") and not exists(p.cache) then
            Engine.mkdirs(p.cache:match("^(.*)/[^/]+$"))
            os.rename(old .. "/cache.tsv", p.cache) -- only hashes: fine to lose
        end

        local state = { sync = {}, pull = {} }
        for area, files in pairs(old_state) do
            for path, h in pairs(files) do
                local new = Migrate.newPath(area, path)
                if new then state[area == "fonts" and "pull" or "sync"][new] = h end
            end
        end
        -- Lists unchanged since this device last synced them: the new list
        -- is as synced, so the server's, as new or newer, wins. (Lists
        -- changed here since: the newer of the two is kept, the other saved
        -- in conflicts/.)
        if wrote_list and lists_synced and as_synced then
            state.sync[Engine.LIST] = Engine.md5Files({ p.list })[p.list]
        end
        assert(Engine.saveState(p, state))

        Engine.mkdirs(p.state .. "/old-lists")
        for _, l in ipairs(OLD_LISTS) do
            if exists(old .. "/" .. l[1]) then os.rename(old .. "/" .. l[1], p.state .. "/old-lists/" .. l[1]) end
        end
        rmTree(old)
    end)
    if done[#done] == "settings sync's lists and state" then done.layout = true end
end

--- deps: kodir (KOReader's data folder, absolute), settings_dir,
-- plugins_dir (where the plugins are, to find SuperSync), LuaSettings,
-- reader_settings (G_reader_settings), logger.
-- Returns a list of what was done (empty if nothing; .supersync if
-- SuperSync's data was taken over, .layout if settings sync's lists were
-- merged), or { restart = true } if SuperSync was on and has just been
-- turned off.
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
        log.info("OmniSync: turned SuperSync off; its data is taken over at the next start")
        return { restart = true }
    end
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
    fromSuperSync(deps, step, done)
    newLayout(deps, step, done)
    return done
end

return Migrate
