--[[--
Updates the plugin from its GitHub releases, with the updater shared by
this repository's plugins (cloudlibrary/updatecore.lua, a copy of
shared/updatecore.lua; see RELEASING.md).
--]]

local _ = require("gettext")

return require("cloudlibrary/updatecore").new{
    name = "cloudlibrary",
    title = _("Cloud library"),
    settings_key = "cloudlibrary_updates",
    log_prefix = "CloudLibrary:",
}
