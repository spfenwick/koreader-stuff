--[[--
Updates a plugin from this repository's GitHub releases.

Shared by the plugins in this repository. The canonical copy is
shared/updatecore.lua; each plugin carries an identical copy under its own
module name (plugins share package.loaded, so a common name would let one
plugin's copy stand in for another's). scripts/sync-updatecore.sh copies it,
and the tests check the copies match.

Each plugin has a rolling release, named after the plugin (e.g. "statsync"),
holding plugin.json for its newest version:

    { "version": "X.Y.Z", "file": "statsync.koplugin.zip",
      "url": "https://…/statsync-vX.Y.Z/statsync.koplugin.zip", "sha256": "…" }

The update is unpacked next to the plugin (as <name>.koplugin.new, which
KOReader doesn't load), checked (checksum, complete, advertised version),
and swapped in by renaming, so a failed download or unpack leaves the
installed plugin as it was. It takes effect after a restart.

    local Updater = require("<plugin>_updatecore").new{
        name = "statsync",                     -- folder <name>.koplugin, rolling release <name>
        title = _("Statistics sync"),          -- shown to the user
        settings_key = "statsync_updates",     -- in settings.reader.lua
        log_prefix = "StatSync:",
        after_check = nil,                     -- optional, see check()
    }
    Updater.check(plugin, interactive)         -- plugin.path, plugin.version (from _meta.lua)
    Updater.scheduleCheck(plugin)              -- once per session, automatic
    Updater.menuItems(plugin)                  -- "Check for updates", "Automatic updates"
]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local UpdateCore = {}

UpdateCore.REPO = "spfenwick/koreader-stuff"

-- Versions ------------------------------------------------------------------

--- "1.2.3" or "v1.2.3" → { 1, 2, 3 }, or nil.
function UpdateCore.parseVersion(version)
    if type(version) ~= "string" then return nil end
    local major, minor, patch = version:match("^v?(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- true if version a is newer than version b (false if either is invalid).
function UpdateCore.isNewer(a, b)
    local va, vb = UpdateCore.parseVersion(a), UpdateCore.parseVersion(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] > vb[i] end
    end
    return false
end

-- Network -------------------------------------------------------------------

local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--- GET url (following redirects, as GitHub's downloads do) into a string.
-- @return body, or nil and an error message
function UpdateCore.fetch(url, max_size, user_agent)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local body, err
    for _i = 1, 5 do
        local chunks, size, too_large = {}, 0, false
        local sink = function(chunk, sink_err)
            if chunk then
                size = size + #chunk
                if size > max_size then
                    too_large = true
                    return nil, "too large"
                end
                table.insert(chunks, chunk)
            end
            return 1, sink_err
        end
        local ok, code, headers, status = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = "GET",
                sink = sink,
                redirect = false,
                headers = { ["User-Agent"] = user_agent or "KOReader plugin updater" },
            })
        end)
        if not ok then
            err = tostring(code)
            break
        end
        local location = headers and headers.location
        if REDIRECTS[code] and location then
            local next_url = socket_url.absolute(url, location)
            if url:match("^https:") and not next_url:match("^https:") then
                err = "refusing to follow a redirect away from https"
                break
            end
            url = next_url
        elseif code == 200 and not too_large then
            body = table.concat(chunks)
            break
        else
            err = too_large and _("download too large") or tostring(status or code)
            break
        end
    end
    socketutil:reset_timeout()
    if not body and not err then
        err = "too many redirects"
    end
    return body, err
end

--- Checks a decoded plugin.json. Returns it, or nil and an error message.
function UpdateCore.validManifest(manifest)
    if type(manifest) ~= "table" or not UpdateCore.parseVersion(manifest.version)
            or type(manifest.url) ~= "string" or not manifest.url:match("^https://")
            or type(manifest.sha256) ~= "string" or not manifest.sha256:match("^%x+$")
            or #manifest.sha256 ~= 64 then
        return nil, _("invalid release information")
    end
    return manifest
end

-- Installing ----------------------------------------------------------------

local function writeFile(path, data)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(data)
    file:close()
    if not ok then return nil, write_err end
    return true
end

local function removeTree(path)
    local lfs = require("libs/libkoreader-lfs")
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        require("ffi/util").purgeDir(path)
    elseif mode then
        os.remove(path)
    end
end

--- A zip entry's path inside the plugin folder `folder` (e.g.
-- "statsync.koplugin"), or nil if it's outside it or unsafe.
function UpdateCore.entryPath(path, folder)
    local top, rel = path:match("^([^/]+)/(.*)$")
    if not top or top ~= folder or rel == "" then return nil end
    for component in rel:gmatch("[^/]+") do
        if component == ".." or component == "." then return nil end
    end
    if rel:sub(1, 1) == "/" or rel:find("\\", 1, true) then return nil end
    return rel
end

--- Unpack zip_path (one top-level `folder`) into the folder dest.
local function unpack(zip_path, dest, folder)
    local Archiver = require("ffi/archiver")
    local util = require("util")
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        return nil, reader.err or "cannot open the zip"
    end
    local files = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local rel = UpdateCore.entryPath(entry.path, folder)
            if not rel then
                reader:close()
                return nil, T("unexpected file in the zip: %1", entry.path)
            end
            table.insert(files, { path = entry.path, rel = rel })
        end
    end
    for _i, file in ipairs(files) do
        local data = reader:extractToMemory(file.path)
        if not data then
            reader:close()
            return nil, reader.err or file.path
        end
        local target = dest .. "/" .. file.rel
        local dir = target:match("^(.*)/[^/]+$")
        util.makePath(dir)
        local ok, err = writeFile(target, data)
        if not ok then
            reader:close()
            return nil, err
        end
    end
    reader:close()
    return true
end

--- Install the zip data (checked against manifest.sha256) over the plugin
-- at plugin_path, whose folder name is `folder`.
-- @return true, or nil and an error message
function UpdateCore.install(plugin_path, folder, manifest, zip_data)
    local sha2 = require("ffi/sha2")
    if sha2.sha256(zip_data):lower() ~= manifest.sha256:lower() then
        return nil, _("the download is damaged (checksum mismatch)")
    end
    local staging = plugin_path .. ".new"
    local old = plugin_path .. ".old"
    local zip_path = staging .. ".zip"
    removeTree(staging)
    removeTree(old)
    local ok, err = writeFile(zip_path, zip_data)
    if ok then
        ok, err = unpack(zip_path, staging, folder)
    end
    os.remove(zip_path)
    if ok then
        -- Make sure it's a complete plugin of the advertised version.
        local meta_ok, meta = pcall(dofile, staging .. "/_meta.lua")
        local main = io.open(staging .. "/main.lua", "rb")
        if main then main:close() end
        if not main or not meta_ok or type(meta) ~= "table" or meta.version ~= manifest.version then
            ok, err = nil, _("the download is not a complete plugin")
        end
    end
    if ok then
        ok, err = os.rename(plugin_path, old)
        if ok then
            ok, err = os.rename(staging, plugin_path)
            if not ok then
                os.rename(old, plugin_path)
            end
        end
    end
    removeTree(staging)
    if ok then
        -- The running code is already loaded, so the old files can go.
        removeTree(old)
        return true
    end
    return nil, err or "unknown error"
end

-- UI ------------------------------------------------------------------------

local function showInfo(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local widget = InfoMessage:new{ text = text, timeout = timeout }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function closeWidget(widget)
    if widget then
        require("ui/uimanager"):close(widget)
    end
end

-- One plugin's updater ------------------------------------------------------

--- cfg: name, title, settings_key, log_prefix, and optionally repo,
-- release_tag (default: name), max_zip_size, after_check.
function UpdateCore.new(cfg)
    local U = {
        name = assert(cfg.name),
        folder = cfg.name .. ".koplugin",
        title = assert(cfg.title),
        repo = cfg.repo or UpdateCore.REPO,
        release_tag = cfg.release_tag or cfg.name, -- rolling release holding plugin.json
        settings_key = assert(cfg.settings_key),
        log_prefix = cfg.log_prefix or (cfg.name .. ":"),
        check_interval = 24 * 60 * 60, -- automatic checks, seconds
        max_manifest_size = 64 * 1024,
        max_zip_size = cfg.max_zip_size or 4 * 1024 * 1024,
        -- What automatic checks do with an update.
        modes = { "off", "notify", "install" },
        default_mode = "notify",
        parseVersion = UpdateCore.parseVersion,
        isNewer = UpdateCore.isNewer,
        scheduled = nil, -- an automatic check is scheduled for this session
        installed = nil, -- version installed this session, waiting for a restart
    }
    local user_agent = "KOReader " .. U.folder

    function U.getSettings()
        return G_reader_settings:readSetting(U.settings_key) or {}
    end

    function U.saveSettings(settings)
        G_reader_settings:saveSetting(U.settings_key, settings)
    end

    function U.getMode()
        local mode = U.getSettings().mode
        for _i, m in ipairs(U.modes) do
            if m == mode then return mode end
        end
        return U.default_mode
    end

    function U.setMode(mode)
        local settings = U.getSettings()
        settings.mode = mode
        U.saveSettings(settings)
    end

    function U.modeText(mode)
        if mode == "off" then
            return _("off")
        elseif mode == "install" then
            return _("install")
        end
        return _("notify")
    end

    function U.entryPath(path) return UpdateCore.entryPath(path, U.folder) end

    function U.fetch(url, max_size) return UpdateCore.fetch(url, max_size, user_agent) end

    --- The newest release's plugin.json, or nil and an error message.
    function U.fetchManifest()
        local url = T("https://github.com/%1/releases/download/%2/plugin.json", U.repo, U.release_tag)
        local body, err = U.fetch(url, U.max_manifest_size)
        if not body then return nil, err end
        local json = require("json")
        local ok, manifest = pcall(json.decode, body)
        if not ok then return nil, _("invalid release information") end
        return UpdateCore.validManifest(manifest)
    end

    function U.install(plugin_path, manifest, zip_data)
        return UpdateCore.install(plugin_path, U.folder, manifest, zip_data)
    end

    --- Download and install manifest's version over plugin (needs plugin.path).
    function U.downloadAndInstall(plugin, manifest, quiet)
        local UIManager = require("ui/uimanager")
        local progress = not quiet and showInfo(T(_("Downloading %1 %2…"), U.title, manifest.version))
        local data, err = U.fetch(manifest.url, U.max_zip_size)
        local ok
        if data then
            ok, err = U.install(plugin.path, manifest, data)
        end
        closeWidget(progress)
        if not ok then
            logger.warn(U.log_prefix, "update failed:", err)
            if not quiet then
                showInfo(T(_("Could not update %1:\n%2"), U.title, err))
            end
            return false
        end
        logger.info(U.log_prefix, "updated to", manifest.version)
        -- For the rest of this session (any plugin instance).
        U.installed = manifest.version
        UIManager:askForRestart(T(_("%1 has been updated to %2. It will be used after KOReader restarts."), U.title, manifest.version))
        return true
    end

    local function offerUpdate(plugin, manifest, interactive)
        local ConfirmBox = require("ui/widget/confirmbox")
        local UIManager = require("ui/uimanager")
        local dialog
        dialog = ConfirmBox:new{
            text = T(_("%1 %2 is available (installed: %3)."), U.title, manifest.version, plugin.version),
            ok_text = _("Install"),
            cancel_text = _("Later"),
            ok_callback = function()
                U.downloadAndInstall(plugin, manifest)
            end,
            other_buttons = not interactive and {{
                {
                    text = _("Skip this version"),
                    callback = function()
                        local settings = U.getSettings()
                        settings.skip = manifest.version
                        U.saveSettings(settings)
                        UIManager:close(dialog)
                    end,
                },
            }} or nil,
        }
        UIManager:show(dialog)
    end

    --- Check for an update. Interactive checks (from the menu) connect if
    -- needed and always report; automatic ones only run when already online
    -- and at most once per check_interval, and stay quiet unless there is an
    -- update to offer.
    --
    -- When the plugin is up to date, cfg.after_check(plugin, interactive,
    -- mode, fetch, report) runs, for anything else to check (Knuth–Plass:
    -- its engine). It may add lines to `report` and returns true if it
    -- showed something itself.
    function U.check(plugin, interactive)
        if not plugin.path or not plugin.version then return end
        -- An update is already waiting for a restart.
        if U.installed then
            if interactive then
                showInfo(T(_("%1 %2 is installed and will be used after KOReader restarts."), U.title, U.installed))
            end
            return
        end
        local mode = U.getMode()
        local settings = U.getSettings()
        if not interactive then
            if mode == "off" then return end
            if settings.last_check and os.time() - settings.last_check < U.check_interval
                    and os.time() >= settings.last_check then
                return
            end
        end

        local function run()
            local progress = interactive and showInfo(_("Checking for updates…"))
            local manifest, err = U.fetchManifest()
            local report = {}
            if not manifest then
                logger.warn(U.log_prefix, "update check failed:", err)
                table.insert(report, T(_("Plugin: could not check (%1)."), tostring(err)))
            else
                settings = U.getSettings()
                settings.last_check = os.time()
                U.saveSettings(settings)
                if UpdateCore.isNewer(manifest.version, plugin.version)
                        and (interactive or settings.skip ~= manifest.version) then
                    closeWidget(progress)
                    if not interactive and mode == "install" then
                        U.downloadAndInstall(plugin, manifest, true)
                    else
                        offerUpdate(plugin, manifest, interactive)
                    end
                    -- Anything else is checked once the new plugin runs.
                    return
                end
                table.insert(report, T(_("Plugin: up to date (%1)."), plugin.version))
            end
            local offered = cfg.after_check and cfg.after_check(plugin, interactive, mode, U.fetch, report)
            closeWidget(progress)
            if interactive and not offered then
                showInfo(table.concat(report, "\n"))
            end
        end

        local NetworkMgr = require("ui/network/manager")
        if interactive then
            NetworkMgr:runWhenOnline(run)
        elseif NetworkMgr:isWifiOn() and NetworkMgr:isConnected() and NetworkMgr:isOnline() then
            run()
        end
    end

    --- Once per session, a little after the plugin starts. The check returns
    -- at once unless automatic updates are on, a day has passed and the
    -- device is online. Nothing to do for a plugin not loaded by KOReader
    -- (no path).
    function U.scheduleCheck(plugin, delay)
        if U.scheduled or not plugin.path then return end
        U.scheduled = true
        require("ui/uimanager"):scheduleIn(delay or 10, function()
            U.check(plugin, false)
        end)
    end

    --- Menu items: "Check for updates (version)" and "Automatic updates: mode".
    function U.menuItems(plugin)
        local modes = {}
        for _i, mode in ipairs(U.modes) do
            table.insert(modes, {
                text = U.modeText(mode),
                checked_func = function() return U.getMode() == mode end,
                radio = true,
                callback = function() U.setMode(mode) end,
            })
        end
        return {
            {
                text = T(_("Check for updates (%1)"), plugin.version or "?"),
                enabled_func = function() return plugin.path ~= nil end,
                keep_menu_open = true,
                callback = function() U.check(plugin, true) end,
            },
            {
                text_func = function()
                    return T(_("Automatic updates: %1"), U.modeText(U.getMode()))
                end,
                help_text = _("When KOReader is online, the plugin checks for a new version once a day.\n\noff: never\nnotify: ask before installing\ninstall: install it, ready for the next restart"),
                sub_item_table = modes,
            },
        }
    end

    return U
end

return UpdateCore
