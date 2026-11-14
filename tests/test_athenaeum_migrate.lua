-- Tests athenaeum.koplugin/athenaeum/migrate.lua: moving an installation of
-- Cloud library (cloudlibrary.koplugin) to Athenaeum, in a temporary folder
-- with real files. KOReader's modules are stubbed. Needs LuaFileSystem.

local lfs = require("lfs")

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function stub(name, value) package.loaded[name] = value end

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function mkdirs(path)
    local cur = ""
    for part in path:gmatch("[^/]+") do
        cur = cur .. "/" .. part
        if not exists(cur) then lfs.mkdir(cur) end
    end
end

local function purge(path)
    if lfs.attributes(path, "mode") == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then purge(path .. "/" .. entry) end
        end
        lfs.rmdir(path)
    elseif exists(path) then
        os.remove(path)
    end
end

local TMP = os.tmpname()
os.remove(TMP)
mkdirs(TMP)

local logged = {}
stub("logger", {
    info = function(...) table.insert(logged, table.concat({ ... }, " ")) end,
    warn = function(...) table.insert(logged, "WARN " .. table.concat({ ... }, " ")) end,
    dbg = function() end,
})
stub("libs/libkoreader-lfs", lfs)
stub("ffi/util", { purgeDir = function(path) purge(path) return true end })
stub("datastorage", { getSettingsDir = function() return TMP .. "/settings" end })

-- A minimal LuaSettings: the file returns a table; flush writes it back.
local function serialize(v, indent)
    indent = indent or ""
    if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = { "{\n" }
        for _, k in ipairs(keys) do
            local key = type(k) == "number" and ("[" .. k .. "]") or string.format("[%q]", k)
            table.insert(out, indent .. "  " .. key .. " = " .. serialize(v[k], indent .. "  ") .. ",\n")
        end
        table.insert(out, indent .. "}")
        return table.concat(out)
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end
local flushed = {}
stub("luasettings", {
    open = function(_, path)
        local ok, data = pcall(dofile, path)
        local s = { file = path, data = ok and type(data) == "table" and data or {} }
        function s:flush()
            table.insert(flushed, self.file)
            write(self.file, "return " .. serialize(self.data) .. "\n")
        end
        return s
    end,
})

local function fresh()
    package.loaded["athenaeum.koplugin/athenaeum/migrate"] = nil
    return dofile("athenaeum.koplugin/athenaeum/migrate.lua")
end

local OURS = 'local UpdateCore = {}\nUpdateCore.REPO = "spfenwick/koreader-stuff"\n'

--- A plugin folder: files { relative path = contents }.
local function plugin(dir, files)
    for rel, data in pairs(files) do
        local path = dir .. "/" .. rel
        mkdirs(path:match("^(.*)/[^/]+$"))
        write(path, data)
    end
end

local PLUGINS = TMP .. "/plugins"

-- The module's own folder, from its path ------------------------------------------------------

do
    local M = fresh()
    check(M.ownDir() == "athenaeum.koplugin", "ownDir: the plugin folder of migrate.lua (" .. tostring(M.ownDir()) .. ")")
end

-- Which cloudlibrary.koplugin is this plugin's ----------------------------------------------

do
    local M = fresh()
    plugin(PLUGINS .. "/old", { ["cloudlibrary/updatecore.lua"] = OURS, ["main.lua"] = "" })
    plugin(PLUGINS .. "/bridge", { ["athenaeum/updatecore.lua"] = OURS, ["main.lua"] = "" })
    plugin(PLUGINS .. "/other", { ["main.lua"] = "", ["update.lua"] = "-- gytwo", ["_meta.lua"] = "" })
    plugin(PLUGINS .. "/fork", { ["cloudlibrary/updatecore.lua"] = 'UpdateCore.REPO = "someone/else"' })
    check(M.isOurs(PLUGINS .. "/old"), "an old Cloud library is ours")
    check(M.isOurs(PLUGINS .. "/bridge"), "Athenaeum in the old folder is ours")
    check(not M.isOurs(PLUGINS .. "/other"), "another plugin's cloudlibrary.koplugin isn't ours")
    check(not M.isOurs(PLUGINS .. "/fork"), "a copy updating from another repository isn't ours")
    purge(PLUGINS)
end

-- Updated as Cloud library: Athenaeum in cloudlibrary.koplugin moves itself -----------------

do
    local M = fresh()
    local old, new = PLUGINS .. "/cloudlibrary.koplugin", PLUGINS .. "/athenaeum.koplugin"
    plugin(old, { ["main.lua"] = "-- athenaeum", ["athenaeum/updatecore.lua"] = OURS })
    local saved_path, saved_cpath = package.path, package.cpath
    check(M.folder(old) == true, "moving: loads")
    check(not exists(old) and read(new .. "/main.lua") == "-- athenaeum", "moving: renamed athenaeum.koplugin")
    check(M.dir == new and M.moved_from == old, "moving: remembers both folders")
    M.fixPackagePath()
    check(package.path:sub(1, #new + 7) == new .. "/?.lua;", "moving: the rest of main.lua loads from the new folder")
    -- What KOReader does after loading the plugins: the old folder.
    package.path = saved_path .. ";" .. old .. "/?.lua"
    package.cpath = saved_cpath .. ";" .. old .. "/lib/?.so"
    local class = { path = old }
    M.fixLoadedPlugin(class)
    check(class.path == new, "started: the plugin's path is the new folder")
    check(package.path == saved_path .. ";" .. new .. "/?.lua", "started: modules found in the new folder")
    check(package.cpath == saved_cpath .. ";" .. new .. "/lib/?.so", "started: libraries found in the new folder")
    package.path, package.cpath = saved_path, saved_cpath
    purge(PLUGINS)
end

do -- A path with characters special in Lua patterns.
    local M = fresh()
    local base = TMP .. "/odd-dir (1)%/plugins"
    local old, new = base .. "/cloudlibrary.koplugin", base .. "/athenaeum.koplugin"
    plugin(old, { ["main.lua"] = "" })
    check(M.folder(old) and exists(new), "odd path: moved")
    local saved = package.path
    package.path = "./?.lua;" .. old .. "/?.lua"
    M.fixLoadedPlugin({})
    check(package.path == "./?.lua;" .. new .. "/?.lua", "odd path: search path fixed (" .. package.path .. ")")
    package.path = saved
    purge(TMP .. "/odd-dir (1)%")
end

do -- Already in athenaeum.koplugin: the copy in the old folder goes.
    local M = fresh()
    local old, new = PLUGINS .. "/cloudlibrary.koplugin", PLUGINS .. "/athenaeum.koplugin"
    plugin(old, { ["main.lua"] = "-- bridge", ["athenaeum/updatecore.lua"] = OURS })
    plugin(new, { ["main.lua"] = "-- installed" })
    check(M.folder(old) == false, "both: the old copy doesn't load")
    check(not exists(old) and read(new .. "/main.lua") == "-- installed", "both: old folder removed, new one kept")
    check(M.moved_from == nil, "both: nothing moved")
    purge(PLUGINS)
end

do -- Can't rename: works from the old folder this time.
    local M = fresh()
    local old = PLUGINS .. "/cloudlibrary.koplugin"
    plugin(old, { ["main.lua"] = "" })
    local rename = os.rename
    os.rename = function() return nil, "read-only" end -- luacheck: ignore
    check(M.folder(old) == true and exists(old) and M.moved_from == nil, "rename fails: loads from where it is")
    os.rename = rename -- luacheck: ignore
    purge(PLUGINS)
end

-- Installed as Athenaeum, with an old Cloud library still there ---------------------------

do
    local M = fresh()
    local old, new = PLUGINS .. "/cloudlibrary.koplugin", PLUGINS .. "/athenaeum.koplugin"
    plugin(old, { ["main.lua"] = "", ["cloudlibrary/updatecore.lua"] = OURS })
    plugin(new, { ["main.lua"] = "" })
    check(M.folder(new) == true and not exists(old) and exists(new), "old Cloud library next to it: removed")
    purge(PLUGINS)
end

do
    local M = fresh()
    local old, new = PLUGINS .. "/cloudlibrary.koplugin", PLUGINS .. "/athenaeum.koplugin"
    plugin(old, { ["main.lua"] = "", ["update.lua"] = "" })
    plugin(new, { ["main.lua"] = "" })
    check(M.folder(new) == true and exists(old), "another plugin's cloudlibrary.koplugin: left alone")
    purge(PLUGINS)
end

do
    local M = fresh()
    local new = PLUGINS .. "/athenaeum.koplugin"
    plugin(new, { ["main.lua"] = "" })
    check(M.folder(new) == true and M.moved_from == nil, "nothing to move")
    check(M.folder(nil) == true, "no folder known: loads")
    purge(PLUGINS)
end

-- Settings ----------------------------------------------------------------------------------

do
    local M = fresh()
    local settings = TMP .. "/settings"
    plugin(settings .. "/cloudlibrary", { ["settings.lua"] = "return { folder = '/books' }", ["ab.sqlite3"] = "db",
        ["ab-covers/1.jpg"] = "jpg" })
    M.settings()
    check(not exists(settings .. "/cloudlibrary") and read(settings .. "/athenaeum/ab.sqlite3") == "db"
        and read(settings .. "/athenaeum/ab-covers/1.jpg") == "jpg", "settings, catalogs and covers moved")
    M.settings()
    check(exists(settings .. "/athenaeum/settings.lua"), "moving again: nothing to do")
    plugin(settings .. "/cloudlibrary", { ["settings.lua"] = "return {}" })
    M.settings()
    check(exists(settings .. "/cloudlibrary") and read(settings .. "/athenaeum/ab.sqlite3") == "db",
        "settings/athenaeum already there: neither touched")
    purge(settings)
end

-- Gestures, profiles and shortcuts ------------------------------------------------------------

do
    local M = fresh()
    local t = {
        gesture_fm = {
            tap_left_bottom_corner = { cloudlibrary_sync = true, toggle_wifi = true,
                settings = { order = { "toggle_wifi", "cloudlibrary_sync" } } },
            swipe_east = { athenaeum_sync = true },
        },
        gesture_reader = { two_finger_tap = { cloudlibrary_sync = true } },
        cloudlibrary_quick_actions_holder = { cloudlibrary_quick_actions = true },
    }
    check(M.renameAction(t), "renamed: changed")
    local g = t.gesture_fm.tap_left_bottom_corner
    check(g.athenaeum_sync == true and g.cloudlibrary_sync == nil and g.toggle_wifi == true, "renamed: the action")
    check(g.settings.order[2] == "athenaeum_sync" and g.settings.order[1] == "toggle_wifi", "renamed: in the order")
    check(t.gesture_reader.two_finger_tap.athenaeum_sync == true, "renamed: reader gestures too")
    check(t.cloudlibrary_quick_actions_holder.cloudlibrary_quick_actions == true,
        "another plugin's cloudlibrary_* actions left alone")
    check(not M.renameAction(t), "renamed again: nothing to change")
end

do
    local M = fresh()
    local settings = TMP .. "/settings"
    mkdirs(settings)
    write(settings .. "/gestures.lua", 'return { gesture_fm = { tap = { cloudlibrary_sync = true, settings = { order = { "cloudlibrary_sync" } } } } }')
    write(settings .. "/profiles.lua", 'return { ["Night"] = { cloudlibrary_sync = true, settings = { name = "Night" } } }')
    write(settings .. "/hotkeys.lua", 'return { hotkeys_fm = { alt_s = { toggle_wifi = true } } }')
    flushed = {}
    M.actions()
    local g = dofile(settings .. "/gestures.lua")
    local p = dofile(settings .. "/profiles.lua")
    check(g.gesture_fm.tap.athenaeum_sync == true and g.gesture_fm.tap.cloudlibrary_sync == nil
        and g.gesture_fm.tap.settings.order[1] == "athenaeum_sync", "gestures.lua updated")
    check(p.Night.athenaeum_sync == true and p.Night.settings.name == "Night", "profiles.lua updated")
    check(#flushed == 2, "hotkeys.lua without the action isn't rewritten")
    flushed = {}
    M.actions()
    check(#flushed == 0, "nothing rewritten the second time")
    purge(settings)
end

-- All of it, at load ----------------------------------------------------------------------------

do
    local M = fresh()
    M.folder = function() error("boom") end
    check(M.atLoad() == true, "an error moving the folder: the plugin still loads")
    local M2 = fresh()
    M2.folder = function() return false end
    check(M2.atLoad() == false, "another copy in athenaeum.koplugin: this one doesn't load")
end

purge(TMP)
print(string.format("athenaeum migrate: %d checks, %d failures", count, failures))
if failures > 0 then os.exit(1) end
