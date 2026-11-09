--[[
Cloud books as a ZenOS book source (ZenOS's common/book_sources.lua, where
it has one). ZenOS then shows them, without hooks into its internals, in:
  Authors, Series, Languages and Tags tabs (and what ZenOS builds from
  them: Home rows, end-of-book suggestions), via books()
  Home's reading history strip, book switcher, To Be Read, via owns()
  taps and long-presses there, via open() and showContextMenu()
  covers and metadata everywhere, via bookInfo(), answered inside ZenOS's
  own cover caches (changed(paths) drops their entries when a cover
  arrives), so the getBookInfo hook no longer has to stay outermost
  cached folder listings, via listingKey(), so the folder's timestamp
  needn't be touched when the catalog changes, and a listing saved before
  the plugin was removed isn't reused

Each part is feature-detected: a ZenOS whose book sources lack bookInfo or
listingKey gets the plugin's own hooks for that part. Without book sources
at all, zenos_groups.lua does the groups.
]]

local logger = require("logger")
local Guard = require("cloudlibrary/guard")

local ZenSource = {
    registered = false,
    book_info = false, -- ZenOS answers getBookInfo/getDocProps through bookInfo()
    listing = false,   -- ZenOS's listing cache asks listingKey()
    enabled = nil,     -- function() -> true to list cloud books in groups
    on_books = nil,    -- function() when ZenOS rebuilds a grouping
}

local MODULE = "common/book_sources"
local ID = "cloudlibrary"
local Virtual

local function module()
    local mod = package.loaded[MODULE]
    if mod == nil and package.searchpath and package.searchpath(MODULE, package.path) then
        local ok, res = pcall(require, MODULE)
        if ok then mod = res else logger.warn("CloudLibrary: can't load", MODULE, res) end
    end
    return type(mod) == "table" and type(mod.register) == "function" and mod or nil
end

--- True when this ZenOS has book sources (whether or not registered yet).
function ZenSource.available()
    return module() ~= nil
end

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

-- db_bookinfo rebuilds a grouping from this; rebuilt with the catalog.
local books_cache, books_gen
local function books()
    if ZenSource.on_books then ZenSource.on_books() end
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

local function owns(path)
    return Virtual.by_path[path] ~= nil
end

local function selecting()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    return fm and fm.selected_files ~= nil
end

local function show(path)
    if not Virtual.by_path[path] or selecting() then return false end
    Virtual.showDetails(path)
    return true
end

local function folderOf(path)
    return type(path) == "string" and (path:gsub("/+$", "")) or nil
end

-- The library folder's listing shows the cloud books; its parent folders
-- count them (and show them in flat view).
local function listingKey(folder)
    local lib = Virtual.folder
    folder = folderOf(folder)
    if not (lib and folder) then return nil end
    if folder ~= lib and lib:sub(1, #folder + 1) ~= folder .. "/" then
        return nil
    end
    return Virtual.listingKey()
end

--- Registers the source (once ZenOS is there; safe to call often).
-- Returns true when registered.
function ZenSource.install(virtual)
    if ZenSource.registered then return true end
    if not Guard.ok("library") then return false end
    local BookSources = module()
    if not BookSources then return false end
    Virtual = virtual
    local source = {
        books = protect("zenos_groups", "books", books),
        owns = protect("zenos_groups", "owns", owns),
        open = protect("zenos_groups", "open", function(path) return show(path) end),
        showContextMenu = protect("zenos_groups", "showContextMenu", function(_menu, item)
            return type(item) == "table" and show(item.path or item.file)
        end),
        invalidate = function() books_cache = nil end,
    }
    if type(BookSources.bookInfo) == "function"
            and type(BookSources.installMetadataIntegration) == "function" then
        source.bookInfo = protect("library", "bookInfo", function(path, get_cover)
            return Virtual.bookInfoFor(path, get_cover)
        end)
    end
    if type(BookSources.listingKey) == "function" then
        source.listingKey = protect("library", "listingKey", listingKey)
    end
    if not BookSources.register(ID, source) then
        Guard.problem("zenos_groups", "ZenOS refused the book source")
        return false
    end
    ZenSource.registered = true
    -- Turned off after an error: ZenOS rebuilds its groupings without them.
    if Guard.on_failure.zenos_groups == nil then
        Guard.on_failure.zenos_groups = function() ZenSource.changed() end
    end
    if source.bookInfo then
        -- ZenOS installs it when its file browser starts; plugins can start
        -- first. Installing it twice does nothing.
        local ok, res = pcall(BookSources.installMetadataIntegration)
        ZenSource.book_info = ok and res == true
        if not ZenSource.book_info then
            -- Back to the plugin's own getBookInfo hook.
            source.bookInfo = nil
            logger.warn("CloudLibrary: ZenOS metadata integration unavailable", res)
        end
    end
    ZenSource.listing = source.listingKey ~= nil
    logger.info("CloudLibrary: registered as a ZenOS book source",
        ZenSource.book_info and "(metadata)" or "", ZenSource.listing and "(listings)" or "")
    return true
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
