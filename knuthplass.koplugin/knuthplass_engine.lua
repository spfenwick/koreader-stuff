--[[--
Installs the Knuth–Plass CREngine built by the plugin repository's "Build
engine" workflow.

The library only has to agree with the rest of KOReader where they meet
(cre.cpp's Lua API and the shared libraries it links), so the manifest lists
builds by a fingerprint of those parts of koreader-base, and maps each
koreader-base it has seen to one. A device finds its koreader-base from the
commit in its version string through the GitHub API. If the manifest has no
entry for it, the newest build is offered instead. Either way, before
installing, the library is loaded in a child process (which fails if a
library or symbol it needs is missing), and must provide every function of
the running engine (which KOReader's Lua code may call).

KOReader's own libs/libkoreader-cre.so is never changed: the engine is kept
in <data folder>/knuthplass/, and an early user patch (knuthplass_loader.lua)
makes KOReader load it from there, for the KOReader version it was installed
for, and goes back to KOReader's own engine if it fails.
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Loader = require("knuthplass_loader")

local Engine = {
    manifest_url = "https://github.com/spfenwick/koreader-stuff/releases/download/engine/manifest.json",
    base_api_url = "https://api.github.com/repos/koreader/koreader/contents/base?ref=%1",
    settings_key = "knuthplass_engine",
    build_property = "crengine.knuth.plass.build",
    -- A Knuth–Plass engine fills in a default for this property.
    capability_property = "crengine.style.justify.tolerance",
    max_manifest_size = 256 * 1024,
    max_lib_size = 16 * 1024 * 1024,
    -- The early user patch: a copy of knuthplass_loader.lua.
    patch_name = "1-knuthplass-engine.lua",
}

-- State ---------------------------------------------------------------------
--
-- The installed engine's state is in knuthplass/engine.lua (see
-- knuthplass_loader.lua), as the early patch reads it before
-- G_reader_settings is open. G_reader_settings[settings_key] has:
--   bad         = { [build id @ revision] = true }: builds that failed with
--                 this KOReader version, not offered again
--   skip        = a build the user chose to skip
--   base_cache  = { rev, base }: this KOReader's koreader-base commit
-- (and, from before the engine had its own folder: pending, stock_rev.)

function Engine.getState()
    return G_reader_settings:readSetting(Engine.settings_key) or {}
end

--- Save, and write to disk at once (the engine may be about to crash).
function Engine.saveState(state)
    G_reader_settings:saveSetting(Engine.settings_key, state)
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

-- Device and version ----------------------------------------------------------

function Engine.revision()
    return Loader.revision()
end

--- The git ref of this KOReader's koreader repository commit: the commit in
-- a nightly's version (v2026.07.2-299-g8012773_2026-10-30 → 8012773), or a
-- release's tag (v2026.07.1).
function Engine.koreaderRef(rev)
    if type(rev) ~= "string" then return nil end
    local commit = rev:match("%-%d+%-g(%x+)")
    if commit then return commit end
    return rev:match("^(v%d+%.%d+[%.%d]*)$") or rev:match("^(v%d+%.%d+[%.%d]*)_")
end

local linux_arch = { x64 = "x86_64", arm64 = "aarch64", arm = "armhf" }

--- KOReader's name for this device's builds (kobo, kindlehf, linux-x86_64, …).
function Engine.target()
    local ok, Device = pcall(require, "device")
    if not ok then return nil end
    if Device.otaModel then
        local ok_model, model = pcall(Device.otaModel, Device)
        if ok_model and type(model) == "string" then
            -- An AppImage is KOReader's Linux build, packaged.
            return (model:gsub("^appimage%-", "linux-"))
        end
    end
    -- KOReader's Linux packages (.deb, tarball) have no updater, so no name.
    -- (Not the Flatpak, which is built separately.)
    local function is(flag)
        return type(Device[flag]) == "function" and Device[flag](Device) == true
    end
    if jit.os == "Linux" and (is("isDesktop") or is("isEmulator")) and Device.model ~= "Flatpak"
            and linux_arch[jit.arch] then
        return "linux-" .. linux_arch[jit.arch]
    end
    return nil
end

--- KOReader's own engine (which the plugin no longer changes).
function Engine.standardLibPath()
    local lfs = require("libs/libkoreader-lfs")
    return lfs.currentdir() .. "/libs/libkoreader-cre.so"
end

--- The running engine's string properties { [name] = value } ("" for one
-- it doesn't have).
--
-- Read from a new, empty document view (which loads the engine if it isn't
-- yet), never from an open book: when KOReader opens a book, it loads its
-- saved defaults (data/cr3.ini) over the engine's properties, and that file
-- holds every property of the engine that wrote it, so a book can report
-- the build or the settings of an earlier engine. A new view has only the
-- engine's own defaults.
-- @return the table, or nil if the engine can't be read
function Engine.properties(names)
    local ok, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if not ok or type(cre) ~= "table" or not cre.newDocView then
        logger.warn("KnuthPlass: cannot load the engine:", cre)
        return nil
    end
    local view
    ok, view = pcall(cre.newDocView, 100, 100, 0)
    if not ok or type(view) ~= "table" and type(view) ~= "userdata" then
        logger.warn("KnuthPlass: cannot make a document view:", view)
        return nil
    end
    local values = {}
    for _i, name in ipairs(names) do
        local got, value = pcall(view.getStringProperty, view, name)
        values[name] = got and type(value) == "string" and value or ""
    end
    if view.close then
        pcall(view.close, view)
    end
    return values
end

--- The running engine: its build ("" if it doesn't report one), and
-- whether it has the Knuth–Plass settings (see Engine.properties).
-- @return build, supported; or nil if it can't be read
function Engine.runningEngine()
    local values = Engine.properties({ Engine.build_property, Engine.capability_property })
    if not values then return nil end
    return values[Engine.build_property], values[Engine.capability_property] ~= ""
end

--- The build commit the running engine reports: "" for an engine without
-- it (the standard one, or an early Knuth–Plass build), nil if it can't be
-- read. (See runningEngine for why not from the open book.)
function Engine.installedBuild()
    return (Engine.runningEngine())
end

-- Network ---------------------------------------------------------------------

--- This KOReader's koreader-base commit (cached per version).
function Engine.baseCommit(fetch)
    local rev = Engine.revision()
    local state = Engine.getState()
    if state.base_cache and state.base_cache.rev == rev then
        return state.base_cache.base
    end
    local ref = Engine.koreaderRef(rev)
    if not ref then
        return nil, T(_("unknown KOReader version: %1"), tostring(rev))
    end
    local body, err = fetch(T(Engine.base_api_url, ref), 64 * 1024)
    if not body then
        return nil, T(_("looking up KOReader %1 on GitHub: %2"), ref, tostring(err))
    end
    local ok, info = pcall(require("json").decode, body)
    if not ok or type(info) ~= "table" or type(info.sha) ~= "string" or not info.sha:match("^%x+$") then
        return nil, _("could not find this KOReader's koreader-base")
    end
    state = Engine.getState()
    state.base_cache = { rev = rev, base = info.sha }
    Engine.saveState(state)
    return info.sha
end

local function validBuild(build)
    return type(build) == "table" and type(build.url) == "string" and build.url:match("^https://")
        and type(build.sha256) == "string" and #build.sha256 == 64 and build.sha256:match("^%x+$")
        and type(build.commit) == "string" and build.commit ~= ""
        and true or false
end

--- The manifest's build for this koreader-base and target, and true; or,
-- with no build listed for this koreader-base, the newest one for target
-- and false; or nil.
function Engine.findBuild(manifest, base, target)
    if type(manifest) ~= "table" or manifest.schema ~= 2 or type(manifest.builds) ~= "table" then
        return nil
    end
    local fingerprint = type(manifest.bases) == "table" and manifest.bases[base]
    local builds = fingerprint and manifest.builds[fingerprint]
    local build = type(builds) == "table" and builds[target]
    if validBuild(build) then
        return build, true
    end
    local newest
    for _fp, per_target in pairs(manifest.builds) do
        build = type(per_target) == "table" and per_target[target]
        if validBuild(build) and (not newest or tostring(build.built) > tostring(newest.built)) then
            newest = build
        end
    end
    if newest then
        return newest, false
    end
    return nil
end

--- What identifies a build (the same crengine commit is built per fingerprint).
function Engine.buildId(build)
    return build.commit .. "/" .. tostring(build.file)
end

local function badKey(id)
    return id .. "@" .. tostring(Engine.revision())
end

function Engine.fetchManifest(fetch)
    local body, err = fetch(Engine.manifest_url, Engine.max_manifest_size)
    if not body then return nil, err end
    local ok, manifest = pcall(require("json").decode, body)
    if not ok or type(manifest) ~= "table" then
        return nil, _("invalid engine information")
    end
    return manifest
end

-- Files -----------------------------------------------------------------------

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local ffi = require("ffi")
pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")

--- Make a library read-only (Android 14 wants loaded code to be; harmless
-- elsewhere).
local function readOnly(path)
    pcall(function() return ffi.C.chmod(path, 292) end) -- 0444
end

--- Write a new file at path (replacing any, even read-only).
local function writeFile(path, data)
    os.remove(path)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    local closed, close_err = file:close()
    if not ok or not closed then
        os.remove(path)
        return nil, write_err or close_err
    end
    return true
end

--- Put data at path by writing a temporary file and renaming it over path
-- (a running KOReader keeps the old library it has loaded).
local function replaceFile(path, data, read_only)
    local tmp = path .. ".new"
    local ok, err = writeFile(tmp, data)
    if not ok then return nil, err end
    if read_only then readOnly(tmp) end
    ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, err
    end
    return true
end

-- The early patch ------------------------------------------------------------

local function patchPath()
    local DataStorage = require("datastorage")
    return DataStorage:getPatchesDir() .. "/" .. Engine.patch_name
end

--- The patch's contents: knuthplass_loader.lua, run.
function Engine.patchSource(plugin_path)
    local loader = readFile(plugin_path .. "/knuthplass_loader.lua")
    if not loader then return nil end
    return table.concat({
        "-- Knuth–Plass justification plugin: loads its CREngine build",
        "-- (koreader/knuthplass/) instead of KOReader's own, which it leaves",
        "-- as it is. Written by the plugin; delete the plugin's engine with its",
        "-- \"Restore standard engine\" rather than this file.",
        "local Loader = (function()",
        loader,
        "end)()",
        "package.loaded[\"knuthplass_loader.patch\"] = Loader",
        "Loader.apply()",
        "",
    }, "\n")
end

--- Write the patch if it's missing or out of date.
-- @return true, or nil and an error message
function Engine.installPatch(plugin_path)
    local source = Engine.patchSource(plugin_path)
    if not source then return nil, "knuthplass_loader.lua is missing" end
    local path = patchPath()
    if readFile(path) == source then return true end
    require("util").makePath(path:match("^(.*)/[^/]+$"))
    return replaceFile(path, source)
end

function Engine.removePatch()
    os.remove(patchPath())
end

--- Whether KOReader runs user patches (they can be turned off).
function Engine.patchesEnabled()
    local ok, userpatch = pcall(require, "userpatch")
    return ok and not (userpatch.arePatchesDisabled and userpatch.arePatchesDisabled())
end

--- Called as KOReader loads the plugin: keep the patch current and, if it
-- didn't run (patches off), set up the redirect now, which is in time when
-- KOReader starts in the file browser.
function Engine.setUp(plugin_path)
    Engine.plugin_path = plugin_path
    local state = Loader.readState()
    if state and state.enabled then
        local ok, err = Engine.installPatch(plugin_path)
        if not ok then logger.warn("KnuthPlass: cannot write the engine patch:", err) end
    end
    Loader.apply()
end

-- From before the engine had its own folder ------------------------------------

--- Earlier versions replaced libs/libkoreader-cre.so (keeping KOReader's
-- own as libkoreader-cre.so.stock). Put KOReader's own back, and keep using
-- the Knuth–Plass engine from the plugin's folder.
function Engine.migrate(plugin_path)
    local state = Engine.getState()
    if not state.stock_rev and not state.pending then return end
    local lib = Engine.standardLibPath()
    local stock = lib .. ".stock"
    local rev = Engine.revision()
    if state.pending and state.pending.start_with
            and G_reader_settings:readSetting("start_with") == "filemanager" then
        G_reader_settings:saveSetting("start_with", state.pending.start_with.value)
    end
    if state.stock_rev == rev and readFile(stock) then
        -- libs/libkoreader-cre.so is the Knuth–Plass engine.
        local knuth = readFile(lib)
        require("util").makePath(Loader.dir())
        if knuth and replaceFile(Loader.libPath(), knuth, true) then
            Loader.writeState({
                enabled = true,
                lib = Loader.libPath(),
                commit = state.pending and state.pending.commit or nil,
                id = state.pending and state.pending.id or nil,
                rev = rev,
                -- It was in use already, unless it was still being tried.
                pending = state.pending and true or nil,
                attempts = 0,
            })
            Engine.installPatch(plugin_path)
        end
        local ok, err = replaceFile(lib, readFile(stock))
        if not ok then
            logger.warn("KnuthPlass: cannot restore KOReader's engine:", err)
            return
        end
    end
    -- (After a KOReader update, libs/ has KOReader's engine already.)
    os.remove(stock)
    state.stock_rev = nil
    state.pending = nil
    Engine.saveState(state)
    logger.info("KnuthPlass: moved the engine to", Loader.dir())
end

-- Installed engine ------------------------------------------------------------

--- The installed engine (Loader's state), if it's in use.
function Engine.installed()
    local state = Loader.readState()
    if state and state.enabled then return state end
    return nil
end

--- Go back to KOReader's own engine (from the next start).
-- @return true, or nil and an error message
function Engine.restoreStock()
    local state = Loader.readState() or {}
    state.enabled = false
    state.pending = nil
    local ok, err = Loader.writeState(state)
    if not ok then return nil, err end
    os.remove(Loader.libPath())
    os.remove(Loader.goodPath())
    Engine.removePatch()
    logger.info("KnuthPlass: back to KOReader's engine")
    return true
end

--- Whether there's a Knuth–Plass engine to switch off.
function Engine.hasStock()
    return Engine.installed() ~= nil
end

--- Whether this session runs the plugin's engine (loaded by the early
-- patch's copy of the loader, or the plugin's).
function Engine.redirected()
    local patch = package.loaded["knuthplass_loader.patch"]
    return (type(patch) == "table" and patch.active) or Loader.active or false
end

--- The commit of the engine this session loaded from the plugin's folder,
-- or true if it isn't known; nil if it runs KOReader's own.
function Engine.loadedCommit()
    local patch = package.loaded["knuthplass_loader.patch"]
    local active = type(patch) == "table" and patch.active or nil
    return active or Loader.active
end

--- End a pending engine's trial: it's running, for this KOReader version.
local function proven(state, why)
    logger.info("KnuthPlass: engine", state.commit, "works:", why)
    state.pending = nil
    state.attempts = nil
    Loader.writeState(state)
end

--- Called when a book has opened: a pending engine that is running (and
-- reports its build, if it's known) has proved itself.
function Engine.verify(build)
    local state = Loader.readState()
    if state and state.enabled and state.pending and Engine.redirected()
            and (state.commit == nil or build == state.commit)
            and state.rev == Engine.revision() then
        proven(state, "a book opened")
    end
end

--- Called as KOReader quits normally: a pending engine this session loaded
-- didn't crash it, so it has proved itself too (starts that open no book,
-- in the file browser, then don't count against it). Not on a crash or a
-- forced stop, which don't get here.
function Engine.verifyOnExit()
    local state = Loader.readState()
    local loaded = Engine.loadedCommit()
    if state and state.enabled and state.pending and loaded
            and (state.commit == nil or loaded == true or loaded == state.commit)
            and state.rev == Engine.revision() then
        proven(state, "KOReader quit normally")
    end
end

--- Run verifyOnExit when KOReader quits (UIManager:quit: the Exit menu,
-- restarts and power off all go through it). Once per session.
function Engine.hookExit()
    local UIManager = require("ui/uimanager")
    if UIManager._knuthplass_exit_hooked then return end
    UIManager._knuthplass_exit_hooked = true
    local quit = UIManager.quit
    UIManager.quit = function(...)
        pcall(Engine.verifyOnExit)
        return quit(...)
    end
end

local function markBad(ids)
    local settings = Engine.getState()
    settings.bad = settings.bad or {}
    for _i, id in ipairs(ids) do
        settings.bad[badKey(id)] = true
    end
    Engine.saveState(settings)
end

--- A failed engine to tell the user about (once): { commit, reason,
-- fallback = the commit of the previous engine used instead, if any }.
function Engine.takeRollback()
    local state = Loader.readState()
    if not state or not state.failed then return nil end
    local rolled_back = { reason = state.failed }
    -- Not offered again for this KOReader version.
    local bad = { state.failed_id }
    if state.enabled then
        -- Replaced by the previous engine.
        rolled_back.commit = state.failed_commit or "?"
        rolled_back.fallback = state.commit or "?"
    else
        rolled_back.commit = state.commit or "?"
        table.insert(bad, state.id)
    end
    markBad(bad)
    state.failed = nil
    state.failed_commit = nil
    state.failed_id = nil
    Loader.writeState(state)
    return rolled_back
end

--- The previous engine kept to go back to ({ lib, commit, id, rev }), if
-- the installed one is in use.
function Engine.previous()
    local state = Engine.installed()
    local good = state and state.good
    if type(good) == "table" and type(good.lib) == "string" and readFile(good.lib) ~= nil then
        return good
    end
    return nil
end

--- Go back to the previous engine (from the next start). The installed
-- one isn't offered again for this KOReader version.
-- @return true, or nil and an error message
function Engine.rollBack()
    local state = Engine.installed()
    local good = Engine.previous()
    if not good then return nil, _("there's no previous engine") end
    -- (Renaming over the library KOReader has loaded leaves that in place.)
    local ok, err = os.rename(good.lib, Loader.libPath())
    if not ok then return nil, err end
    local bad_id = state.id
    ok, err = Loader.writeState({
        enabled = true,
        lib = Loader.libPath(),
        commit = good.commit,
        id = good.id,
        rev = good.rev,
    })
    if not ok then return nil, err end
    if bad_id then markBad({ bad_id }) end
    logger.info("KnuthPlass: rolled back from", state.commit, "to", good.commit)
    return true
end

-- Installing ------------------------------------------------------------------

--- Check the downloaded library against the manifest.
function Engine.verifyDownload(build, data)
    local sha2 = require("ffi/sha2")
    if (build.size and #data ~= build.size) or sha2.sha256(data):lower() ~= build.sha256:lower() then
        return nil, _("the download is damaged (checksum mismatch)")
    end
    -- An ELF shared library, not an error page.
    if data:sub(1, 4) ~= "\127ELF" then
        return nil, _("the download is not a library")
    end
    return true
end

--- The installed library, if it's this build (to use it again, say after
-- a KOReader update, without downloading it).
function Engine.existingLibrary(build)
    local data = readFile(Loader.libPath())
    if data and Engine.verifyDownload(build, data) then
        return data
    end
    return nil
end

--- The engine to go back to if the one replacing the installed one fails:
-- the installed one, if a book has opened with it (copied to a temporary
-- file, which takes the place of the old copy once the new engine is
-- installed); otherwise the one kept before.
-- @return it, and the temporary copy if there is one
local function keepGood(state, id)
    if not state or not state.enabled then return nil end
    if not state.pending and not state.failed and state.id ~= id and type(state.lib) == "string" then
        local data = readFile(state.lib)
        local copy = Loader.goodPath() .. ".new"
        if data and writeFile(copy, data) then
            readOnly(copy)
            return { lib = Loader.goodPath(), commit = state.commit, id = state.id, rev = state.rev }, copy
        end
    end
    local good = state.good
    if type(good) == "table" and good.id ~= id and good.lib == Loader.goodPath()
            and readFile(good.lib) ~= nil then
        return good
    end
    return nil
end

--- Install build (data is the library) in the plugin's folder, for this
-- KOReader version, from the next start. The engine it replaces is kept,
-- if a book has opened with it (see keepGood).
-- @return true, or nil and an error message
function Engine.install(build, data, plugin_path)
    local ok, err = Engine.verifyDownload(build, data)
    if not ok then return nil, err end
    require("util").makePath(Loader.dir())
    local good, copy = keepGood(Loader.readState(), Engine.buildId(build))
    if readFile(Loader.libPath()) ~= data then
        ok, err = replaceFile(Loader.libPath(), data, true)
        if not ok then
            if copy then os.remove(copy) end
            return nil, err
        end
    end
    ok, err = Loader.writeState({
        enabled = true,
        lib = Loader.libPath(),
        commit = build.commit,
        id = Engine.buildId(build),
        rev = Engine.revision(),
        pending = true,
        attempts = 0,
        good = good,
    })
    if not ok then
        if copy then os.remove(copy) end
        return nil, err
    end
    if copy then
        ok, err = os.rename(copy, Loader.goodPath())
        if not ok then
            -- Not kept, then.
            os.remove(copy)
            local state = Loader.readState()
            if state then
                state.good = nil
                Loader.writeState(state)
            end
        end
    elseif not good then
        os.remove(Loader.goodPath())
    end
    if plugin_path then
        ok, err = Engine.installPatch(plugin_path)
        if not ok then return nil, err end
    end
    logger.info("KnuthPlass: installed engine", build.commit)
    return true
end

-- Compatibility ---------------------------------------------------------------
-- (The loading test is in knuthplass_loader.lua, which the early patch also
-- uses to check the engine again after a KOReader update.)

--- Load the library at path in a child process.
-- @return its API (see Loader.creApi), or nil and an error message
function Engine.probeLibrary(path)
    return Loader.probe(path)
end

--- Check that the library (data) works with this KOReader: it loads, and
-- has every function KOReader's own engine has (the same check the early
-- patch makes after a KOReader update).
-- @return true, or nil and an error message
function Engine.checkCompatible(data)
    -- Where it would be installed. (Its libraries are found through
    -- luajit's rpath, $ORIGIN/libs.)
    require("util").makePath(Loader.dir())
    local probe = Loader.dir() .. "/probe.so"
    local ok, err = writeFile(probe, data)
    if not ok then return nil, err end
    ok, err = Loader.check(probe, Engine.probeLibrary)
    os.remove(probe)
    if not ok then return nil, err end
    return true
end

-- UI --------------------------------------------------------------------------

local function showInfo(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local widget = InfoMessage:new{ text = text, timeout = timeout }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then require("ui/uimanager"):close(widget) end
end

function Engine.buildText(build)
    if build == nil then return _("unknown") end
    if build == "" then return _("standard") end
    return build
end

function Engine.downloadAndInstall(build, current_build, supported, fetch, quiet)
    local UIManager = require("ui/uimanager")
    -- Already here (installed for an earlier KOReader version, say)?
    local data, err = Engine.existingLibrary(build)
    local progress
    if not data then
        progress = not quiet and showInfo(T(_("Downloading the Knuth–Plass engine %1…"), build.commit))
        data, err = fetch(build.url, Engine.max_lib_size)
    end
    local ok
    if data then
        ok, err = Engine.verifyDownload(build, data)
    end
    if ok then
        ok, err = Engine.checkCompatible(data)
        if not ok then
            -- Don't offer it again with this KOReader version.
            local state = Engine.getState()
            state.bad = state.bad or {}
            state.bad[badKey(Engine.buildId(build))] = true
            Engine.saveState(state)
        end
    end
    if ok then
        ok, err = Engine.install(build, data, Engine.plugin_path)
    end
    closeWidget(progress)
    if not ok then
        logger.warn("KnuthPlass: engine install failed:", err)
        if not quiet then
            showInfo(T(_("Could not install the Knuth–Plass engine:\n%1"), err))
        end
        return false
    end
    -- For the rest of this session (the file browser and the reader each
    -- have their own plugin instance).
    Engine.installed_this_session = build.commit
    local text = T(_("The Knuth–Plass engine %1 has been installed. It will be used after KOReader restarts.\n\nKOReader's own engine is left as it is, and is used again if this one fails."), build.commit)
    if not Engine.patchesEnabled() then
        text = text .. "\n\n" .. _("User patches are turned off, so it's only used when KOReader starts in the file browser.")
    end
    UIManager:askForRestart(text)
    return true
end

local function offerInstall(build, exact, current_build, supported, fetch, interactive)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local text
    if current_build == "" and not supported then
        text = T(_("This KOReader's engine has no Knuth–Plass line breaking. Install the Knuth–Plass engine %1?"), build.commit)
    else
        text = T(_("Knuth–Plass engine %1 is available (installed: %2)."), build.commit, Engine.buildText(current_build))
    end
    if not exact then
        text = text .. "\n\n" .. T(_("It was built for another KOReader version (%1). It will be checked against this one before it's installed."), tostring(build.koreader))
    end
    local dialog
    dialog = ConfirmBox:new{
        text = text,
        ok_text = _("Install"),
        cancel_text = _("Later"),
        ok_callback = function()
            Engine.downloadAndInstall(build, current_build, supported, fetch)
        end,
        other_buttons = not interactive and {{
            {
                text = _("Skip this build"),
                callback = function()
                    local state = Engine.getState()
                    state.skip = build.commit
                    Engine.saveState(state)
                    UIManager:close(dialog)
                end,
            },
        }} or nil,
    }
    UIManager:show(dialog)
end

--- Check for an engine build for this device and KOReader version.
-- Appends status lines to report (for interactive checks).
-- @return true if it offered or installed an update
function Engine.check(plugin, interactive, mode, fetch, report)
    if Engine.installed_this_session then
        table.insert(report, T(_("Engine: %1 is installed and will be used after KOReader restarts."), Engine.installed_this_session))
        return false
    end
    local document = plugin.ui and plugin.ui.document
    -- Automatic checks don't load the engine just to look (in the file
    -- browser); they check it when a book is open.
    if not document and not interactive then return false end
    local current_build, supported = Engine.runningEngine()
    if current_build == nil then
        table.insert(report, _("Engine: cannot read which engine is running."))
        return false
    end
    -- Which devices have builds is up to the manifest.
    local target = Engine.target()
    if not target then
        table.insert(report, _("Engine: no builds for this device."))
        return false
    end
    -- Without its koreader-base (a KOReader built from a commit GitHub's
    -- koreader repository doesn't have, say), the newest build is offered:
    -- it's checked against the running engine before it's installed.
    local base, base_err = Engine.baseCommit(fetch)
    if not base then
        logger.warn("KnuthPlass: cannot find koreader-base:", base_err)
    end
    local manifest, err = Engine.fetchManifest(fetch)
    if not manifest then
        logger.warn("KnuthPlass: engine check failed:", err)
        table.insert(report, T(_("Engine: could not download the list of builds (%1)."), tostring(err)))
        return false
    end
    local build, exact = Engine.findBuild(manifest, base or "", target)
    if not build then
        table.insert(report, T(_("Engine: no builds for this device (%1)."), target))
        return false
    end
    if build.commit == current_build then
        table.insert(report, T(_("Engine: up to date (%1)."), current_build))
        return false
    end
    local state = Engine.getState()
    if state.bad and state.bad[badKey(Engine.buildId(build))] then
        table.insert(report, T(_("Engine: build %1 didn't work with this KOReader version, so it isn't offered again."), build.commit))
        return false
    end
    if not interactive and state.skip == build.commit then
        return false
    end
    if not interactive and mode == "install" then
        return Engine.downloadAndInstall(build, current_build, supported, fetch, true)
    end
    offerInstall(build, exact, current_build, supported, fetch, interactive)
    return true
end

return Engine
