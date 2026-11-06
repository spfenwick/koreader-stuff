--[[
Experimental, for testing a ZenOS change before proposing it: keep ZenOS's
cached library listing when the Library tab is opened from another tab.

ZenOS's onTabBooks (modules/filebrowser/patches/navbar.lua) calls
_refresh_library_path(fc, home_dir, true) when the Library tab is opened
from a tab other than Home while the library folder is the current folder.
The `true` drops the cached listing (in memory and on disk), so the whole
folder is listed and sorted again: several seconds with a large library on
a Kobo. Its cache already checks the folder's timestamp, so this skips that
one drop. Every other drop still happens: ZenOS's own check for changes,
metadata edits, the context menu...

The caller is recognised by its source line, so if ZenOS changes that line
nothing is skipped. Setting "keep_zenos_listing" (default true).
]]

local logger = require("logger")
local Guard = require("cloudlibrary/guard")

local ZenListing = {
    enabled = true,
    installed = false,
    skipped = 0,
}

local CALL = "_refresh_library_path(fc, home_dir, true)"

local line_cache = {}

local function sourceLine(source, line)
    local key = source .. ":" .. line
    local text = line_cache[key]
    if text == nil then
        text = false
        local f = source:sub(1, 1) == "@" and io.open(source:sub(2), "r")
        if f then
            local n = 0
            for l in f:lines() do
                n = n + 1
                if n == line then text = l break end
            end
            f:close()
        end
        line_cache[key] = text
    end
    return text or nil
end

-- True when the call comes from the line in onTabBooks: the second frame up
-- the stack in navbar.lua (the first is _refresh_library_path itself).
local function fromLibraryTab()
    local seen = 0
    for level = 3, 12 do
        local info = debug.getinfo(level, "Sl")
        if not info then return false end
        if type(info.source) == "string" and info.source:match("/navbar%.lua$") then
            seen = seen + 1
            if seen == 2 then
                local text = sourceLine(info.source, info.currentline)
                return text ~= nil and text:find(CALL, 1, true) ~= nil
            end
        end
    end
    return false
end

--- Installs the hook once ZenOS has added its cache (call when listing).
function ZenListing.install(library_folder)
    if ZenListing.installed then return end
    local FileChooser = require("ui/widget/filechooser")
    if type(FileChooser._zen_invalidate_item_table_path) ~= "function" then return end
    ZenListing.installed = true
    Guard.hook("zenos_listing", FileChooser, "_zen_invalidate_item_table_path",
        function(orig, self, path, ...)
            local folder = library_folder()
            if ZenListing.enabled and folder and type(path) == "string"
                    and path:gsub("/+$", "") == folder and fromLibraryTab() then
                ZenListing.skipped = ZenListing.skipped + 1
                logger.dbg("CloudLibrary: kept ZenOS's library listing")
                return false
            end
            return orig(self, path, ...)
        end, "FileChooser:_zen_invalidate_item_table_path")
end

return ZenListing
