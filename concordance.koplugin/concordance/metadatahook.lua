--[[--
Edits made in ZenOS's metadata editor, kept where Concordance syncs them
(see BOOKDATA.md, "Edits in ZenOS's metadata editor").

ZenOS writes an edit to an EPUB into the file itself, then removes every
title, author, series... override from the book's custom metadata. Concordance
would send that as clears of all of them, so the other devices lose their
overrides, and the edit itself never syncs (the file's text isn't synced).
This wraps ZenOS's metadata service's editsEmbedded: while book data can
sync, it answers false, and ZenOS keeps the edit in custom metadata, as
KOReader's book information dialog does. Other times ZenOS decides.

Main process.
--]]

local Problems = require("concordance/problems")

local MetadataHook = {}

--- Wraps Service.editsEmbedded (once). deps: active() -> whether book data
-- can sync now, logger. Returns true if it's in place now, else false and why.
function MetadataHook.install(Service, deps)
    if type(Service) ~= "table" then return false, "no metadata service" end
    if Service._concordance_edits_embedded then return false, "already installed" end
    local orig = Service.editsEmbedded
    if type(orig) ~= "function" then
        if deps.logger then deps.logger.warn("Concordance: ZenOS's metadata service has no editsEmbedded") end
        Problems.report("zenos:editsEmbedded",
            "Edits in ZenOS's metadata editor may not sync: ZenOS has changed", "editsEmbedded is missing")
        return false, "no editsEmbedded"
    end
    Service._concordance_edits_embedded = orig
    Service.editsEmbedded = function(file, ...)
        local ok, active = pcall(deps.active)
        if ok and active then return false end
        if not ok and deps.logger then
            deps.logger.warn("Concordance: deciding where a metadata edit goes failed:", active)
        end
        return orig(file, ...)
    end
    return true
end

--- Puts ZenOS's own editsEmbedded back (tests).
function MetadataHook.uninstall(Service)
    if type(Service) == "table" and Service._concordance_edits_embedded then
        Service.editsEmbedded = Service._concordance_edits_embedded
        Service._concordance_edits_embedded = nil
    end
end

return MetadataHook
