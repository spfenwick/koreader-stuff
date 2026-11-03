--[[--
Updates the plugin from its GitHub releases, with the updater shared by
this repository's plugins (knuthplass_updatecore.lua, a copy of
shared/updatecore.lua), and then checks the engine (knuthplass_engine.lua).
--]]

local _ = require("gettext")
-- Required while KOReader loads the plugin (its folder is on package.path
-- only then).
local Engine = require("knuthplass_engine")
local UpdateCore = require("knuthplass_updatecore")

return UpdateCore.new{
    name = "knuthplass",
    title = _("Knuth–Plass justification"),
    settings_key = "knuthplass_updates",
    log_prefix = "KnuthPlass:",
    -- Once the plugin is up to date: an engine build for this device.
    after_check = function(plugin, interactive, mode, fetch, report)
        return Engine.check(plugin, interactive, mode, fetch, report)
    end,
}
