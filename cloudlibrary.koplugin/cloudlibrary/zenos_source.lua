--[[
The plugin's ZenOS side: the cloud books are a ZenOS book source (ZenOS's
common/book_sources.lua, which the plugin requires). ZenOS then shows them:
  Authors, Series, Languages and Tags tabs (and what ZenOS builds from
  them: Home rows, end-of-book suggestions), via books()
  Home's reading history strip, book switcher, To Be Read, via owns()
  taps and long-presses there, via open() and showContextMenu()
  covers and metadata everywhere, via bookInfo(), answered inside ZenOS's
  own cover caches (changed(paths) drops their entries when a cover
  arrives)
  cached folder listings, via listingKey(): a listing is rebuilt when the
  cloud books in it change, and one saved before the plugin was removed
  isn't reused

Also, until ZenOS does these itself:
  getGroupedByTags     each book once per tag (ZenOS adds a book again for
                       each time a tag appears in its keywords)
  filemanagerutil.openFile, the file chooser's showFileDialog
                       for ZenOS views that don't ask the book sources yet
                       (To Be Read, end-of-book "next in series"): a cloud
                       book shows its details. ZenOS wraps both after the
                       plugin starts, so they're re-wrapped outermost
                       whenever ZenOS rebuilds a grouping.
If those change, the hooks turn themselves off (feature "zenos").
Setting "zenos_groups" (default true): cloud books in the groups.
]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Guard = require("cloudlibrary/guard")

local ZenSource = {
    registered = false,
    enabled = nil, -- function() -> true to list cloud books in groups
}

local MODULE = "common/book_sources"
local ID = "cloudlibrary"
local Virtual

-- An error turns the feature off (as Guard.hook does) instead of ZenOS
-- just logging it each time.
local function protect(feature, name, fn)
    return function(...)
        if not Guard.ok(feature) then return nil end
        local ok, a, b = pcall(fn, ...)
        if ok then return a, b end
        Guard.fail(feature, "ZenOS book source " .. name, a)
        return nil
    end
end

local function joined(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local s = table.concat(list, "\n"):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

local function selecting()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    return fm and fm.selected_files ~= nil
end

-- Open and long-press backstops ----------------------------------------------

local fmu, our_openFile
local our_dialogs = setmetatable({}, { __mode = "k" }) -- file chooser -> our wrapper

local function wrapOpenFile()
    our_openFile = Guard.hook("zenos", fmu, "openFile", function(orig, ui, file, ...)
        if Virtual.by_path[file] and not selecting() then
            Virtual.showDetails(file)
            return
        end
        return orig(ui, file, ...)
    end, "filemanagerutil.openFile")
end

local function wrapFileDialog(fc)
    our_dialogs[fc] = Guard.hook("zenos", fc, "showFileDialog", function(orig, self, item, ...)
        if type(item) == "table" and Virtual.by_path[item.path] and not selecting() then
            Virtual.showDetails(item.path)
            return true
        end
        return orig(self, item, ...)
    end, "FileChooser:showFileDialog")
end

--- Keeps the open and long-press hooks outside ZenOS's own wrappers.
function ZenSource.ensureOutermost()
    if not (fmu and Guard.ok("zenos")) then return end
    if fmu.openFile ~= our_openFile then wrapOpenFile() end
    local FileManager = require("apps/filemanager/filemanager")
    local fc = FileManager.instance and FileManager.instance.file_chooser
    if fc and type(fc.showFileDialog) == "function" and fc.showFileDialog ~= our_dialogs[fc] then
        wrapFileDialog(fc)
    end
end

-- Tags ------------------------------------------------------------------------

--- ZenOS's tag groups with each book listed once per tag (a new list when
-- one changes; ZenOS caches the one it gives).
function ZenSource.dedupeTags(groups)
    local out = {}
    for i, g in ipairs(groups or {}) do
        if type(g) == "table" and type(g.files) == "table" then
            local files, seen = {}, {}
            for _j, file in ipairs(g.files) do
                if not seen[file] then
                    seen[file] = true
                    files[#files + 1] = file
                end
            end
            if #files ~= #g.files then
                local copy = {}
                for k, v in pairs(g) do copy[k] = v end
                copy.files = files
                g = copy
            end
        end
        out[i] = g
    end
    return out
end

local function hookTags()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok or type(db) ~= "table" or type(db.getGroupedByTags) ~= "function" then return end
    local last_in, last_out
    Guard.hook("zenos", db, "getGroupedByTags", function(orig, ...)
        local groups = orig(...)
        if type(groups) ~= "table" then return groups end
        if groups ~= last_in then last_in, last_out = groups, ZenSource.dedupeTags(groups) end
        return last_out
    end, "ZenOS getGroupedByTags")
end

-- The source ------------------------------------------------------------------

-- db_bookinfo rebuilds a grouping from this; rebuilt with the catalog.
local books_cache, books_gen
local function books()
    ZenSource.ensureOutermost()
    if not (ZenSource.enabled and ZenSource.enabled()) then return {} end
    if books_cache and books_gen == Virtual.generation then return books_cache end
    local out = {}
    for i, book in ipairs(Virtual.books) do
        out[i] = { file = book.path, info = {
            title = book.title,
            authors = joined(book.authors),
            series = book.series,
            series_index = tonumber(book.series_index),
            language = book.language,
            keywords = type(book.tags) == "table" and #book.tags > 0
                and table.concat(book.tags, "\n") or nil,
        } }
    end
    books_cache, books_gen = out, Virtual.generation
    return out
end

local function show(path)
    if not Virtual.by_path[path] or selecting() then return false end
    Virtual.showDetails(path)
    return true
end

-- The library folder's listing shows the cloud books; its parent folders
-- count them (and show them in flat view).
local function listingKey(folder)
    local lib = Virtual.folder
    folder = type(folder) == "string" and folder:gsub("/+$", "") or nil
    if not (lib and folder) then return nil end
    if folder ~= lib and lib:sub(1, #folder + 1) ~= folder .. "/" then return nil end
    return Virtual.listingKey()
end

--- Registers the source. Returns false when ZenOS refuses it (the startup
-- check has already made sure ZenOS has book sources).
function ZenSource.install(virtual)
    if ZenSource.registered then return true end
    local ok, BookSources = pcall(require, MODULE)
    if not ok or type(BookSources) ~= "table" then
        Guard.problem("library", "ZenOS's book sources can't be loaded")
        return false
    end
    Virtual = virtual
    local source = {
        books = protect("zenos", "books", books),
        owns = protect("library", "owns", function(path) return Virtual.by_path[path] ~= nil end),
        open = protect("library", "open", function(path) return show(path) end),
        showContextMenu = protect("library", "showContextMenu", function(_menu, item)
            return type(item) == "table" and show(item.path or item.file)
        end),
        invalidate = function() books_cache = nil end,
        bookInfo = protect("library", "bookInfo", function(path, get_cover)
            return Virtual.bookInfoFor(path, get_cover)
        end),
        listingKey = protect("library", "listingKey", listingKey),
    }
    if not BookSources.register(ID, source) then
        Guard.problem("library", "ZenOS refused the book source")
        return false
    end
    ZenSource.registered = true
    -- ZenOS installs it when its file browser starts; plugins start first.
    -- Installing it twice does nothing. False: no CoverBrowser, so no
    -- covers or metadata for any book.
    local ok_meta, res = pcall(BookSources.installMetadataIntegration)
    if not (ok_meta and res) then logger.warn("CloudLibrary: ZenOS metadata integration unavailable", res) end
    -- Turned off after an error: ZenOS rebuilds its groupings without them.
    Guard.on_failure.zenos = function() ZenSource.changed() end
    fmu = require("apps/filemanager/filemanagerutil")
    ZenSource.ensureOutermost()
    hookTags()
    logger.info("CloudLibrary: registered as a ZenOS book source")
    return true
end

-- Redrawing after a download ---------------------------------------------------

local function swapInList(list, old, new)
    local found = false
    for i, v in ipairs(list) do
        if v == old then list[i], found = new, true end
    end
    return found
end

-- Points a list item (and the series groups and file lists in it) at the
-- downloaded file. True if anything changed.
local function swapInItem(item, old, new)
    if type(item) ~= "table" then return false end
    local found = false
    for _i, key in ipairs({ "path", "filepath", "file" }) do
        if item[key] == old then item[key], found = new, true end
    end
    if found and item.text == (old:match("([^/]+)$") or ""):gsub("%.[^%.]+$", "") then
        item.text = (new:match("([^/]+)$") or new):gsub("%.[^%.]+$", "")
    end
    -- ZenOS group items share their file list with the book list opened
    -- from them, so a later rebuild of that list sees the file too.
    if type(item._zen_files) == "table" and swapInList(item._zen_files, old, new) then found = true end
    if type(item.series_items) == "table" then
        for _i, sub in ipairs(item.series_items) do
            if swapInItem(sub, old, new) then found = true end
        end
    end
    return found
end

--- A cloud book was downloaded: every open ZenOS view that lists it (Home,
-- Authors/Series/Languages/Tags and their book lists, To Be Read,
-- history and search lists) now shows the file, and is redrawn. The
-- library folder itself is redrawn by Virtual.refresh().
function ZenSource.downloaded(old_path, new_path)
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if type(w) == "table" and type(w.item_table) == "table" then
            if type(w._zen_tbr_refresh) == "function" then
                -- To Be Read reloads its list itself.
                w._zen_tbr_refresh()
            else
                local found = false
                for _j, item in ipairs(w.item_table) do
                    if swapInItem(item, old_path, new_path) then found = true end
                end
                if found and type(w.updateItems) == "function" then w:updateItems() end
            end
        end
    end
    -- Home rebuilds now if it's on top, else when it's next shown.
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.zenos
    local home = plugin and require("common/shared_state").get(plugin, "home")
    if type(home) == "table" and type(home.rebuildActive) == "function" then home.rebuildActive() end
end

--- Tells ZenOS the cloud books changed; with paths, also that their covers
-- or metadata did (ZenOS drops its cached covers for them).
function ZenSource.changed(paths)
    if not ZenSource.registered then return end
    books_cache = nil
    local BookSources = package.loaded[MODULE]
    if type(BookSources) == "table" and type(BookSources.changed) == "function" then
        local ok, err = pcall(BookSources.changed, paths)
        if not ok then logger.warn("CloudLibrary: ZenOS book sources changed():", err) end
    end
end

return ZenSource
