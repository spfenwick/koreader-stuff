--[[--
Updates the plugin from its GitHub releases, with the updater shared by
this repository's plugins (cloudlibrary/updatecore.lua, a copy of
shared/updatecore.lua; see RELEASING.md).

With OmniSync running, updates for both plugins are checked together
there (omnisync/updates.lua): "Check for updates" runs that combined
check, and the automatic check is left to OmniSync's.
--]]

local _ = require("gettext")

local Updater = require("cloudlibrary/updatecore").new{
    name = "cloudlibrary",
    title = _("Cloud library"),
    -- In settings/cloudlibrary/settings.lua, with the plugin's settings.
    settings_key = require("cloudlibrary/settings").UPDATES_KEY,
    settings = function() return require("cloudlibrary/settings").store() end,
    log_prefix = "CloudLibrary:",
}

--- Tells OmniSync it may run this plugin's automatic check.
Updater.defers_to_omnisync = true

local own_check = Updater.check

function Updater.check(plugin, interactive)
    local combined = package.loaded["omnisync/updates"]
    if type(combined) == "table" and combined.active and combined.active() then
        if interactive then combined.check(true) end
        return
    end
    return own_check(plugin, interactive)
end

return Updater
