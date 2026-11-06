--[[--
Updates the plugin from its GitHub releases, with the updater shared by
this repository's plugins (cloudlibrary/updatecore.lua, a copy of
shared/updatecore.lua; see RELEASING.md).
--]]

local _ = require("gettext")

return require("cloudlibrary/updatecore").new{
    name = "cloudlibrary",
    title = _("Cloud library"),
    -- In settings/cloudlibrary/settings.lua, with the plugin's settings.
    settings_key = require("cloudlibrary/settings").UPDATES_KEY,
    settings = function() return require("cloudlibrary/settings").store() end,
    log_prefix = "CloudLibrary:",
}
