--[[--
Updates for Concordance and Cloud library together: one check, one dialog
listing both, one restart prompt.

Each plugin keeps its own updater (concordance/updatecore.lua and Cloud
library's cloudlibrary/updater.lua, both copies of shared/updatecore.lua)
with its own settings (automatic mode, skipped version, last check). This
only drives them together, through the parts of their interface that do no
UI: fetchManifest, fetch, install, getMode, getSettings, saveSettings and
`installed`.

Cloud library's updater looks for this module (package.loaded
"concordance/updates") and, while it's active, hands its own checks here: its
menu's "Check for updates" runs the combined check, and its automatic check
is left to Concordance's. Its updater says so with `defers_to_concordance`;
without that (an older Cloud library), its automatic check is its own and
isn't repeated here.

    Updates.register(fn)          fn() -> { { updater = U, plugin = { path, version } }, … }
    Updates.check(interactive)    the combined check
    Updates.scheduleCheck(delay)  once per session, automatic
    Updates.menuItems()           "Check for updates", "Automatic updates"
--]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Updates = {
    entries = nil,   -- function() -> entries, set by register()
    scheduled = nil, -- an automatic check is scheduled for this session
}

function Updates.register(fn) Updates.entries = fn end

--- True while Concordance is running and checks for both plugins.
function Updates.active() return Updates.entries ~= nil end

--- The plugins, or only those that can be updated (loaded by KOReader
-- from a folder, with a version).
local function list(installed_only)
    local out = {}
    for _i, e in ipairs(Updates.entries and Updates.entries() or {}) do
        if e.updater and e.plugin and (not installed_only or (e.plugin.path and e.plugin.version)) then
            out[#out + 1] = e
        end
    end
    return out
end

-- UI helpers -----------------------------------------------------------------------------

local function UI() return require("ui/uimanager") end

local function showInfo(text, timeout)
    local w = require("ui/widget/infomessage"):new{ text = text, timeout = timeout }
    UI():show(w)
    UI():forceRePaint()
    return w
end

local function close(w) if w then UI():close(w) end end

-- Checking ---------------------------------------------------------------------------------

--- Looks at each plugin. Returns { { entry, state, manifest, err }, … }, in
-- the entries' order, state being:
--   "pending"  an update was installed this session (manifest.version)
--   "newer"    an update to offer or install
--   "current"  up to date (or, automatic, a skipped version)
--   "failed"   couldn't check (err)
-- Automatic checks leave out plugins whose mode is off, checked less than a
-- day ago, or whose own updater checks for itself.
function Updates.gather(entries, interactive, now)
    now = now or os.time()
    local out = {}
    for _i, e in ipairs(entries) do
        local U = e.updater
        local r = { entry = e }
        local settings = U.getSettings()
        if U.installed then
            r.state, r.manifest = "pending", { version = U.installed }
        elseif not interactive and (U.getMode() == "off" or e.own_automatic
                or (settings.last_check and now >= settings.last_check
                    and now - settings.last_check < U.check_interval)) then
            r = nil
        else
            local manifest, err = U.fetchManifest()
            if not manifest then
                logger.warn(U.log_prefix, "update check failed:", err)
                r.state, r.err = "failed", tostring(err)
            else
                settings = U.getSettings()
                settings.last_check = now
                U.saveSettings(settings)
                r.manifest = manifest
                local newer = U.isNewer(manifest.version, e.plugin.version)
                r.state = newer and (interactive or settings.skip ~= manifest.version) and "newer" or "current"
            end
        end
        if r then out[#out + 1] = r end
    end
    return out
end

--- One line per plugin.
function Updates.summary(results)
    local lines = {}
    for _i, r in ipairs(results) do
        local U, version = r.entry.updater, r.entry.plugin.version
        local line
        if r.state == "pending" then
            line = T(_("%1: %2 installed, used after KOReader restarts"), U.title, r.manifest.version)
        elseif r.state == "newer" then
            line = T(_("%1: %2 available (installed: %3)"), U.title, r.manifest.version, version)
        elseif r.state == "failed" then
            line = T(_("%1: couldn't check (%2)"), U.title, r.err)
        else
            line = T(_("%1: up to date (%2)"), U.title, version)
        end
        lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
end

-- Installing -------------------------------------------------------------------------------

--- Downloads and installs each result's manifest. quiet: no messages
-- (automatic installs). Returns installed, failed: lists of lines.
function Updates.install(results, quiet)
    local installed, failed = {}, {}
    for _i, r in ipairs(results) do
        local U, plugin, manifest = r.entry.updater, r.entry.plugin, r.manifest
        local progress = not quiet and showInfo(T(_("Downloading %1 %2…"), U.title, manifest.version))
        local data, err = U.fetch(manifest.url, U.max_zip_size)
        local ok
        if data then ok, err = U.install(plugin.path, manifest, data) end
        close(progress)
        if ok then
            logger.info(U.log_prefix, "updated to", manifest.version)
            U.installed = manifest.version
            installed[#installed + 1] = T(_("%1 %2"), U.title, manifest.version)
        else
            logger.warn(U.log_prefix, "update failed:", err)
            failed[#failed + 1] = T(_("%1: %2"), U.title, tostring(err))
        end
    end
    return installed, failed
end

--- What happened, once: a restart prompt if anything was installed.
local function report(installed, failed)
    local text = {}
    if #installed > 0 then
        text[#text + 1] = T(_("Updated: %1. Used after KOReader restarts."), table.concat(installed, ", "))
    end
    if #failed > 0 then
        text[#text + 1] = _("Couldn't update:") .. "\n" .. table.concat(failed, "\n")
    end
    if #installed > 0 then
        UI():askForRestart(table.concat(text, "\n\n"))
    elseif #failed > 0 then
        showInfo(table.concat(text, "\n\n"))
    end
end

local function append(a, b) for _i, x in ipairs(b) do a[#a + 1] = x end return a end

--- The dialog offering the updates in `offer`. done: installed and failed
-- so far (automatic installs), reported with the outcome.
local function offerUpdates(results, offer, interactive, done)
    local ConfirmBox = require("ui/widget/confirmbox")
    local function finish(installed, failed)
        report(append(done.installed, installed), append(done.failed, failed))
    end
    -- Every way out (a button, or tapping outside: Later) calls finish once.
    UI():show(ConfirmBox:new{
        text = (#offer > 1 and _("Updates available:") or _("Update available:")) .. "\n\n" .. Updates.summary(results),
        ok_text = #offer > 1 and _("Install all") or _("Install"),
        cancel_text = _("Later"),
        ok_callback = function() finish(Updates.install(offer)) end,
        cancel_callback = function() finish({}, {}) end,
        other_buttons = not interactive and { {
            {
                text = #offer > 1 and _("Skip these versions") or _("Skip this version"),
                callback = function()
                    for _i, r in ipairs(offer) do
                        local U = r.entry.updater
                        local settings = U.getSettings()
                        settings.skip = r.manifest.version
                        U.saveSettings(settings)
                    end
                    finish({}, {})
                end,
            },
        } } or nil,
    })
end

--- The combined check. Interactive (from a menu): connects if needed, and
-- always shows the outcome. Automatic: only when already online; installs
-- what's set to install, offers what's set to notify, says nothing else.
function Updates.check(interactive)
    local entries = list(true)
    if #entries == 0 then return end

    local function run()
        local progress = interactive and showInfo(_("Checking for updates…"))
        local results = Updates.gather(entries, interactive)
        close(progress)
        local offer, auto = {}, {}
        for _i, r in ipairs(results) do
            if r.state == "newer" then
                if not interactive and r.entry.updater.getMode() == "install" then
                    auto[#auto + 1] = r
                else
                    offer[#offer + 1] = r
                end
            end
        end
        local done = { installed = {}, failed = {} }
        if #auto > 0 then done.installed, done.failed = Updates.install(auto, true) end
        if #offer > 0 then
            offerUpdates(results, offer, interactive, done)
        elseif #auto > 0 then
            -- Failed quiet installs are only logged.
            if #done.installed > 0 then report(done.installed, {}) end
        elseif interactive then
            showInfo(Updates.summary(results))
        end
    end

    local NetworkMgr = require("ui/network/manager")
    if interactive then
        NetworkMgr:runWhenOnline(run)
    elseif NetworkMgr:isWifiOn() and NetworkMgr:isConnected() and NetworkMgr:isOnline() then
        run()
    end
end

--- Once per session, a little after start.
function Updates.scheduleCheck(delay)
    if Updates.scheduled then return end
    Updates.scheduled = true
    UI():scheduleIn(delay or 10, function() Updates.check(false) end)
end

-- Menu -------------------------------------------------------------------------------------

local function modeItems(U)
    local items = {}
    for _i, mode in ipairs(U.modes) do
        items[#items + 1] = {
            text = U.modeText(mode),
            checked_func = function() return U.getMode() == mode end,
            radio = true,
            callback = function() U.setMode(mode) end,
        }
    end
    return items
end

local MODES_HELP = _("When KOReader is online, Concordance checks for new versions once a day.\n\noff: never\nnotify: ask before installing\ninstall: install it, ready for the next restart")

--- "Check for updates" and "Automatic updates" (one setting per plugin).
function Updates.menuItems()
    local entries = list()
    local versions = {}
    for _i, e in ipairs(entries) do versions[#versions + 1] = T(_("%1 %2"), e.updater.title, e.plugin.version or "?") end
    local items = {
        {
            text = _("Check for updates"),
            help_text = T(_("Checks for new versions of Concordance and Cloud library (if it's installed).\n\nInstalled: %1"),
                table.concat(versions, ", ")),
            enabled_func = function() return #list(true) > 0 end,
            keep_menu_open = true,
            callback = function() Updates.check(true) end,
        },
    }
    if #entries == 1 then
        local U = entries[1].updater
        items[2] = {
            text_func = function() return T(_("Automatic updates: %1"), U.modeText(U.getMode())) end,
            help_text = MODES_HELP,
            sub_item_table = modeItems(U),
        }
    elseif #entries > 1 then
        local sub = {}
        for _i, e in ipairs(entries) do
            local U = e.updater
            sub[#sub + 1] = {
                text_func = function() return T(_("%1: %2"), U.title, U.modeText(U.getMode())) end,
                sub_item_table = modeItems(U),
            }
        end
        items[2] = {
            text = _("Automatic updates"),
            help_text = MODES_HELP,
            sub_item_table = sub,
        }
    end
    return items
end

return Updates
