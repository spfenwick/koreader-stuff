--[[--
Updates the plugin from its GitHub releases, with the updater shared by
this repository's plugins (athenaeum/updatecore.lua, a copy of
shared/updatecore.lua; see RELEASING.md).

With Concordance running, updates for both plugins are checked together
there (concordance/updates.lua): "Check for updates" runs that combined
check, and the automatic check is left to Concordance's. Only with a
Concordance that knows this plugin as Athenaeum (handles("athenaeum")): an
older one looks for Cloud library's updater, doesn't find it, and would
never check this plugin.
--]]

local _ = require("gettext")

local Updater = require("athenaeum/updatecore").new{
    name = "athenaeum",
    title = _("Athenaeum"),
    -- In settings/athenaeum/settings.lua, with the plugin's settings.
    settings_key = require("athenaeum/settings").UPDATES_KEY,
    settings = function() return require("athenaeum/settings").store() end,
    log_prefix = "Athenaeum:",
}

--- Tells Concordance it may run this plugin's automatic check.
Updater.defers_to_concordance = true

local own_check = Updater.check

--- Concordance's combined updater, when it's running and checks this plugin.
function Updater.combined()
    local combined = package.loaded["concordance/updates"]
    if type(combined) == "table" and type(combined.active) == "function" and combined.active()
            and type(combined.handles) == "function" and combined.handles("athenaeum") then
        return combined
    end
end

function Updater.check(plugin, interactive)
    local combined = Updater.combined()
    if combined then
        if interactive then combined.check(true) end
        return
    end
    return own_check(plugin, interactive)
end

return Updater
