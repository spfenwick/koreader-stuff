--[[--
Makes KOReader load the Knuth–Plass CREngine from the plugin's own folder
(<KOReader data folder>/knuthplass/libkoreader-cre.so) instead of its own
libs/libkoreader-cre.so, which is never changed. (On Android, the engine is
in KOReader's library libkoreader-monolibtic.so, and the plugin's folder is
in the app's private storage: see Loader.dir.)

KOReader loads its engine with require("libs/libkoreader-cre"), so this sets
package.preload for that name. It has to run before the engine is first
loaded, so the plugin installs a copy of this file as an early user patch
(patches/1-knuthplass-engine.lua), which KOReader runs at the very start.
(The plugin also runs it as it loads, which is in time when KOReader starts
in the file browser, should patches be turned off.)

The engine was checked against the KOReader version it was installed for.
After a KOReader update, it's checked again before it's used: in child
processes, it must load, and provide every function KOReader's own engine
(which matches KOReader's Lua code) does. If it doesn't, KOReader's own
engine is used, and the plugin offers a matching build.

Until a book has opened with a newly installed (or re-checked) engine, or
KOReader has quit normally after loading it (the plugin then clears
"pending"), it counts the times the engine is loaded; if it fails to load,
or is loaded more than max_attempts times (KOReader crashed or was stopped
each time before either), it goes back to the last engine
known to work (the plugin keeps a copy when it installs a new one), or else
KOReader's own engine, and records why. A failed re-check after a KOReader
update does the same.

Forked child processes (CoverBrowser's, say, which open books for their
covers) load the engine as it's set up, but leave the counting, and falling
back, to KOReader's own process.

Keep it self-contained: it runs before most of KOReader is set up.
]]

local Loader = {
    module = "libs/libkoreader-cre",
    max_attempts = 2,
    -- Seconds a loading test may take.
    probe_timeout = 20,
}

local ffi = require("ffi")
pcall(ffi.cdef, "int getpid(void);")

local function getpid()
    local ok, pid = pcall(function() return ffi.C.getpid() end)
    return ok and tonumber(pid) or nil
end

--- Whether this runs in a child process forked after the engine was set
-- up (KOReader's process is the one that ran Loader.apply).
function Loader.isChild()
    local pid = getpid()
    return Loader.pid ~= nil and pid ~= nil and pid ~= Loader.pid
end

local function dataDir()
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir()
    if dir:sub(1, 1) ~= "/" then
        -- "." on e-readers: make it absolute, for dlopen.
        local lfs = require("libs/libkoreader-lfs")
        dir = lfs.currentdir() .. (dir == "." and "" or "/" .. dir:gsub("^%./", ""))
    end
    return dir
end

local function android()
    local ok, module = pcall(require, "android")
    return ok and type(module) == "table" and module.dir and module or nil
end

--- The plugin's folder for the engine.
function Loader.dir()
    local A = android()
    if A then
        -- Android loads libraries only from the app's private storage, not
        -- from KOReader's data folder (shared storage); and the launcher
        -- empties its own folder there (android.dir) when KOReader is
        -- updated. So next to that: /data/user/0/<app>/knuthplass.
        return A.dir:match("^(.*)/[^/]+$") .. "/knuthplass"
    end
    return dataDir() .. "/knuthplass"
end

function Loader.statePath()
    return Loader.dir() .. "/engine.lua"
end

function Loader.libPath()
    return Loader.dir() .. "/libkoreader-cre.so"
end

--- The copy of the last engine known to work (see state.good).
function Loader.goodPath()
    return Loader.dir() .. "/libkoreader-cre.good.so"
end

--- KOReader's own engine (a library with luaopen_cre).
function Loader.standardLibPath()
    local A = android()
    if A and A.nativeLibraryDir then
        local monolibtic = A.nativeLibraryDir .. "/libkoreader-monolibtic.so"
        local file = io.open(monolibtic, "rb")
        if file then
            file:close()
            return monolibtic
        end
        return A.nativeLibraryDir .. "/libkoreader-cre.so"
    end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.currentdir() .. "/libs/libkoreader-cre.so"
end

function Loader.revision()
    local ok, Version = pcall(require, "version")
    return ok and Version:getCurrentRevision() or nil
end

-- State ---------------------------------------------------------------------
--
-- knuthplass/engine.lua (a Lua table, as G_reader_settings isn't open yet):
--   enabled  = load the engine at lib
--   lib      = the library
--   commit   = its build commit
--   id       = its build id (see knuthplass_engine)
--   rev      = the KOReader version it's for
--   pending  = not seen working yet; attempts = engine loads since installed
--   failed   = why it was turned off (for the plugin to report)
--   unchecked_rev = a KOReader version it couldn't be checked against
--                   (not tried again for that version)
--   good     = the last engine known to work (a book opened with it), kept
--              at good.lib to go back to: { lib, commit, id, rev }
--   failed_commit, failed_id = the engine that failed, when it was replaced
--              by good (commit and id are then good's)

local function serialize(value, indent)
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "table" then
        local keys = {}
        for k in pairs(value) do
            if type(k) == "string" then table.insert(keys, k) end
        end
        table.sort(keys)
        local inner = indent .. "    "
        local lines = {}
        for _i, k in ipairs(keys) do
            local v = serialize(value[k], inner)
            if v then
                table.insert(lines, string.format("%s[%q] = %s,", inner, k, v))
            end
        end
        return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
    end
    return nil
end

function Loader.readState()
    local chunk = loadfile(Loader.statePath())
    if not chunk then return nil end
    -- Data only.
    setfenv(chunk, {})
    local ok, state = pcall(chunk)
    if ok and type(state) == "table" then
        return state
    end
    return nil
end

--- Write the state (through a temporary file, so it's never half written).
function Loader.writeState(state)
    local path = Loader.statePath()
    local tmp = path .. ".new"
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err end
    file:write("return ", serialize(state, ""), "\n")
    file:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, rename_err
    end
    return true
end

-- Checking --------------------------------------------------------------------

-- The Lua tables a library's luaopen_cre fills in: the module, and its
-- metatables in the registry (credocument, creimage, and any cre.cpp adds).
-- A table in the registry before it ran (another engine's, in a running
-- KOReader) is reused, so what changed is what it registered.

local function functionsOf(t)
    local functions = {}
    for name, value in pairs(t) do
        if type(name) == "string" and type(value) == "function" then
            functions[name] = value
        end
    end
    return functions
end

--- The registry's tables (string keys) and their functions.
function Loader.registrySnapshot(registry)
    local snapshot = {}
    for key, value in pairs(registry) do
        if type(key) == "string" and type(value) == "table" then
            snapshot[key] = functionsOf(value)
        end
    end
    return snapshot
end

--- The functions an engine provides (KOReader's Lua code calls them):
-- { ["cre.name"] = true, ["credocument:name"] = true, … }, from its module
-- and what it registered since the snapshot was taken.
function Loader.creApi(module, registry, snapshot)
    local api = {}
    if type(module) == "table" then
        for name in pairs(functionsOf(module)) do api["cre." .. name] = true end
    end
    for key, value in pairs(registry) do
        if type(key) == "string" and type(value) == "table" and key ~= "_LOADED" then
            local before = snapshot[key] or {}
            for name, fn in pairs(functionsOf(value)) do
                if before[name] ~= fn then api[key .. ":" .. name] = true end
            end
        end
    end
    return api
end

--- Load the library at path in a child process.
-- @return its API (see creApi), or nil and an error message
function Loader.probe(path)
    local ffiutil = require("ffi/util")
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local registry = debug.getregistry()
        local snapshot = Loader.registrySnapshot(registry)
        -- A running engine's module would hide what this one lacks.
        package.loaded.cre = nil
        rawset(_G, "cre", nil)
        -- Resolves every symbol now: fails if one is missing.
        local open, err = package.loadlib(path, "luaopen_cre")
        local out
        if not open then
            out = "ERR " .. tostring(err)
        else
            local ok, module = pcall(open)
            if not ok then
                out = "ERR " .. tostring(module)
            else
                if type(module) ~= "table" then module = package.loaded.cre end
                local names = {}
                for name in pairs(Loader.creApi(module, registry, snapshot)) do table.insert(names, name) end
                out = "OK\n" .. table.concat(names, "\n")
            end
        end
        ffiutil.writeToFD(write_fd, out, true)
    end, true)
    if not pid then
        return nil, tostring(read_fd)
    end
    local done = false
    for _i = 1, Loader.probe_timeout * 10 do
        if ffiutil.isSubProcessDone(pid) then
            done = true
            break
        end
        ffiutil.usleep(100000)
    end
    if not done then
        ffiutil.terminateSubProcess(pid)
        ffiutil.isSubProcessDone(pid, true)
        ffiutil.readAllFromFD(read_fd)
        return nil, "loading it took too long"
    end
    local out = ffiutil.readAllFromFD(read_fd)
    if out:sub(1, 3) == "OK\n" then
        local api = {}
        for name in out:sub(4):gmatch("[^\n]+") do api[name] = true end
        return api
    elseif out:sub(1, 4) == "ERR " then
        return nil, out:sub(5)
    end
    return nil, "it crashed when loaded"
end

--- The functions of api_required that api lacks (sorted), or nil.
function Loader.missing(api, api_required)
    local missing = {}
    for name in pairs(api_required) do
        if not api[name] then table.insert(missing, name) end
    end
    if #missing == 0 then return nil end
    table.sort(missing)
    return missing
end

--- Check the engine at lib against this KOReader: it must load, and have
-- every function KOReader's own engine (which matches its Lua code) has.
-- probe defaults to Loader.probe.
-- @return true; or nil, the reason, and whether it's worth trying again
-- (KOReader's own engine couldn't be checked) rather than a verdict
function Loader.check(lib, probe)
    probe = probe or Loader.probe
    local standard, err = probe(Loader.standardLibPath())
    if not standard then
        return nil, "KOReader's own engine couldn't be checked (" .. tostring(err) .. ")", true
    end
    local api
    api, err = probe(lib)
    if not api then
        return nil, "it doesn't load with this KOReader version (" .. tostring(err) .. ")"
    end
    local missing = Loader.missing(api, standard)
    if missing then
        return nil, "it lacks functions this KOReader version uses (" .. table.concat(missing, ", ") .. ")"
    end
    return true
end

-- Loading -------------------------------------------------------------------

local function exists(path)
    local file = type(path) == "string" and io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function disable(state, reason)
    state.enabled = false
    state.failed = reason
    Loader.writeState(state)
end

--- Replace the failed engine with the last one known to work, if there's
-- one; otherwise turn it off.
-- @return true if it's been replaced
local function fallBack(state, reason)
    local good = state.good
    state.good = nil
    if type(good) ~= "table" or not exists(good.lib) then
        disable(state, reason)
        return false
    end
    state.failed = reason
    state.failed_commit = state.commit
    state.failed_id = state.id
    local lib = good.lib
    if os.rename(lib, Loader.libPath()) then lib = Loader.libPath() end
    state.enabled = true
    state.lib = lib
    state.commit = good.commit
    state.id = good.id
    state.rev = good.rev
    state.pending = nil
    state.attempts = nil
    state.unchecked_rev = nil
    Loader.writeState(state)
    return true
end

-- KOReader's own engine: through the loaders after package.preload's (as
-- require would), or else straight from libs/.
function Loader.loadStandard(name)
    local ok, cre = pcall(function()
        local errors = {}
        for i = 1, #package.loaders do
            local found = package.loaders[i](name)
            if type(found) == "function" then
                return found(name)
            elseif type(found) == "string" then
                table.insert(errors, found)
            end
        end
        error("not found:" .. table.concat(errors))
    end)
    if ok and cre ~= nil then return cre end
    local open, err = package.loadlib(Loader.standardLibPath(), "luaopen_cre")
    if not open then
        error("cannot load KOReader's engine: " .. tostring(cre) .. "; " .. tostring(err))
    end
    return open()
end

local loadInstalled

--- The last engine known to work, in place of the failed one, if it's for
-- this KOReader version (otherwise it's checked at the next start).
local function loadFallback(state, reason)
    if fallBack(state, reason) and state.rev == Loader.revision() then
        return loadInstalled(state)
    end
    return nil
end

--- The engine at state.lib, or nil and why not.
loadInstalled = function(state)
    if state.pending then
        state.attempts = (state.attempts or 0) + 1
        if state.attempts > Loader.max_attempts then
            return loadFallback(state, "KOReader stopped without opening a book with it or quitting normally")
        end
        -- On disk before the engine runs, in case it crashes.
        Loader.writeState(state)
    end
    local open, err = package.loadlib(state.lib, "luaopen_cre")
    if open then
        local ok, cre = pcall(open)
        if ok and cre ~= nil then
            Loader.active = state.commit or true
            return cre
        end
        err = cre
    end
    return loadFallback(state, "it failed to load: " .. tostring(err))
end

--- In a forked child: the engine at state.lib as it is, or nil. (Its state
-- is KOReader's process's to change.)
local function loadInChild(state)
    local open = package.loadlib(state.lib, "luaopen_cre")
    if not open then return nil end
    local ok, cre = pcall(open)
    if ok and cre ~= nil then
        Loader.active = state.commit or true
        return cre
    end
    return nil
end

--- Load the engine at state.lib, or KOReader's own if that fails (in any
-- way: KOReader must always get an engine).
function Loader.load(name, state)
    package.preload[Loader.module] = nil
    if Loader.isChild() then
        local ok, cre = pcall(loadInChild, state)
        if ok and cre ~= nil then return cre end
        return Loader.loadStandard(name)
    end
    local ok, cre = pcall(loadInstalled, state)
    if ok and cre ~= nil then return cre end
    if not ok then
        -- An error rather than a failure it reported: turn it off too.
        -- (Not falling back: what failed may be the fallback.)
        pcall(disable, state, "it failed to load: " .. tostring(cre))
    end
    return Loader.loadStandard(name)
end

--- Set up the redirect, if there's an engine for this KOReader version and
-- the engine hasn't been loaded yet.
-- @return true if it's set up
function Loader.apply()
    if package.loaded[Loader.module] or package.preload[Loader.module] then
        return false
    end
    local state = Loader.readState()
    if not state or not state.enabled or type(state.lib) ~= "string" then
        return false
    end
    if not exists(state.lib) then return false end
    -- KOReader was updated (or downgraded): check the engine again.
    local rev = Loader.revision()
    if state.rev ~= rev then
        if state.unchecked_rev == rev then
            return false
        end
        local done, ok, reason, retry = pcall(Loader.check, state.lib)
        if not done then
            -- (KOReader's helpers changed, say.)
            ok, reason, retry = nil, tostring(ok), true
        end
        if not ok then
            if retry then
                -- KOReader's own engine for now; the plugin can check later.
                state.unchecked_rev = rev
                Loader.writeState(state)
            elseif fallBack(state, "after the KOReader update, " .. reason) then
                -- (Checked in turn, if it's for another KOReader version.)
                return Loader.apply()
            end
            return false
        end
        -- Proven again only once a book has opened with it.
        state.previous_rev = state.rev
        state.rev = rev
        state.unchecked_rev = nil
        state.pending = true
        state.attempts = 0
        Loader.writeState(state)
    end
    Loader.pid = getpid()
    package.preload[Loader.module] = function(name)
        return Loader.load(name, state)
    end
    Loader.applied = true
    return true
end

return Loader
