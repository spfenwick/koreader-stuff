--[[
Cloud books in ZenOS's Authors and Series tabs (and what ZenOS builds from
the same lists: its Home page author and series rows, end-of-book
suggestions).

ZenOS builds those from CoverBrowser's database, keeping only books whose
file exists (common/db_bookinfo.lua), so cloud books never appear. This
changes three of its functions, adding the cloud books to what they return:
  getGroupedByAuthor   { { author, files }, ... }
  getGroupedBySeries   { { series, items = { { file, series_index, filename } } } }
  getLightMetadata()   path -> { title, authors, series, series_index, keywords }
                       (sorting and series grouping in a group's book list)

Opening a book from those lists goes through filemanagerutil.openFile,
which ZenOS wraps to mark the book as being read, and long-press through
the file chooser's showFileDialog, which ZenOS replaces on the file
chooser itself. Both are wrapped (outermost, checked again each time the
lists are built) to show a cloud book's details instead.

This depends on ZenOS internals, so it's a stopgap until ZenOS offers a way
for plugins to add books to these lists (a PR to propose). If ZenOS changes
them, the hooks turn themselves off and the tabs show downloaded books only.
Setting "zenos_groups" (default true).
]]

local logger = require("logger")
local Guard = require("cloudlibrary/guard")

local ZenGroups = {
    enabled = true,
    installed = false,
}

local MODULE = "common/db_bookinfo"
local Virtual

-- As CoverBrowser stores them (ZenOS groups by the whole string).
local function joined(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    local s = table.concat(list, "\n"):match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function copyList(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v end
    return out
end

--- Adds the cloud books to ZenOS's author groups (returns a new list:
-- ZenOS caches the one it gives).
function ZenGroups.mergeAuthors(groups, books)
    local out, index, copied = {}, {}, {}
    for i, g in ipairs(groups or {}) do
        out[i] = g
        if type(g) == "table" and g.author then index[g.author] = i end
    end
    local added = false
    for _i, book in ipairs(books) do
        local name = joined(book.authors)
        if name then
            local i = index[name]
            if not i then
                table.insert(out, { author = name, files = {} })
                i = #out
                index[name] = i
                copied[i] = true
            elseif not copied[i] then
                out[i] = copy(out[i])
                out[i].files = copyList(out[i].files)
                copied[i] = true
            end
            table.insert(out[i].files, book.path)
            added = true
        end
    end
    if added then
        table.sort(out, function(a, b) return a.author < b.author end)
    end
    return out
end

local function bySeriesIndex(a, b)
    local ia, ib = a.series_index or 0, b.series_index or 0
    if ia ~= ib then return ia < ib end
    return (a.filename or "") < (b.filename or "")
end

--- Adds the cloud books to ZenOS's series groups (a new list).
function ZenGroups.mergeSeries(groups, books)
    local out, index, copied = {}, {}, {}
    for i, g in ipairs(groups or {}) do
        out[i] = g
        if type(g) == "table" and g.series then index[g.series] = i end
    end
    local added = false
    for _i, book in ipairs(books) do
        local name = type(book.series) == "string" and book.series ~= "" and book.series
        if name then
            local i = index[name]
            if not i then
                table.insert(out, { series = name, items = {} })
                i = #out
                index[name] = i
                copied[i] = true
            elseif not copied[i] then
                out[i] = copy(out[i])
                out[i].items = copyList(out[i].items)
                copied[i] = true
            end
            table.insert(out[i].items, {
                file = book.path,
                series_index = tonumber(book.series_index),
                filename = book.filename,
            })
            added = true
        end
    end
    if added then
        for i in pairs(copied) do table.sort(out[i].items, bySeriesIndex) end
        table.sort(out, function(a, b) return a.series < b.series end)
    end
    return out
end

--- Adds the cloud books to ZenOS's path -> metadata table (a new table).
function ZenGroups.mergeMetadata(metadata, books)
    if #books == 0 then return metadata end
    local out = copy(metadata or {})
    for _i, book in ipairs(books) do
        out[book.path] = {
            title = book.title,
            authors = joined(book.authors),
            series = book.series,
            series_index = tonumber(book.series_index),
            keywords = book.tags and table.concat(book.tags, "\n") or nil,
        }
    end
    return out
end

-- Merging is redone only when ZenOS's own list (it caches it) or the
-- catalog changes.
local function memo(merge)
    local last_in, last_gen, last_out
    return function(result)
        if result == last_in and last_gen == Virtual.generation and last_out then
            return last_out
        end
        last_out = merge(result, Virtual.books)
        last_in, last_gen = result, Virtual.generation
        return last_out
    end
end

local function active()
    return ZenGroups.enabled and Virtual.folder ~= nil and #Virtual.books > 0
        and Guard.ok("zenos_groups")
end

-- Opening and long-press ---------------------------------------------------

local fmu, our_openFile
local our_dialogs = setmetatable({}, { __mode = "k" }) -- file chooser -> our wrapper

local function selecting()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    return fm and fm.selected_files ~= nil
end

local function wrapOpenFile()
    our_openFile = Guard.hook("zenos_groups", fmu, "openFile", function(orig, ui, file, ...)
        if Virtual.by_path[file] and not selecting() then
            Virtual.showDetails(file)
            return
        end
        return orig(ui, file, ...)
    end, "filemanagerutil.openFile")
end

local function wrapFileDialog(fc)
    our_dialogs[fc] = Guard.hook("zenos_groups", fc, "showFileDialog", function(orig, self, item, ...)
        if type(item) == "table" and Virtual.by_path[item.path] and not selecting() then
            Virtual.showDetails(item.path)
            return true
        end
        return orig(self, item, ...)
    end, "FileChooser:showFileDialog")
end

--- Keeps the open and long-press hooks outside ZenOS's own wrappers.
function ZenGroups.ensureOutermost()
    if fmu and fmu.openFile ~= our_openFile then wrapOpenFile() end
    local FileManager = require("apps/filemanager/filemanager")
    local fc = FileManager.instance and FileManager.instance.file_chooser
    if fc and type(fc.showFileDialog) == "function" and fc.showFileDialog ~= our_dialogs[fc] then
        wrapFileDialog(fc)
    end
end

-- Install ------------------------------------------------------------------

--- Installs the hooks once ZenOS has loaded its module (safe to call often).
function ZenGroups.install(virtual)
    if ZenGroups.installed then return end
    local db = package.loaded[MODULE]
    -- ZenOS loads it when first needed, which can be after the plugin
    -- starts: load it now if ZenOS is there.
    if db == nil and package.searchpath and package.searchpath(MODULE, package.path) then
        local ok, mod = pcall(require, MODULE)
        if ok then db = mod else logger.warn("CloudLibrary: can't load", MODULE, mod) end
    end
    if type(db) ~= "table" then return end
    if not Guard.ok("library") then return end
    for _i, name in ipairs({ "getGroupedByAuthor", "getGroupedBySeries", "getLightMetadata" }) do
        if type(db[name]) ~= "function" then
            Guard.problem("zenos_groups", "ZenOS's " .. name .. " is missing")
            return
        end
    end
    Virtual = virtual
    ZenGroups.installed = true
    fmu = require("apps/filemanager/filemanagerutil")

    local authors, series, metadata =
        memo(ZenGroups.mergeAuthors), memo(ZenGroups.mergeSeries), memo(ZenGroups.mergeMetadata)

    Guard.hook("zenos_groups", db, "getGroupedByAuthor", function(orig, ...)
        local groups = orig(...)
        if not (active() and type(groups) == "table") then return groups end
        ZenGroups.ensureOutermost()
        Virtual.ensureOutermost()
        return authors(groups)
    end, "ZenOS getGroupedByAuthor")

    Guard.hook("zenos_groups", db, "getGroupedBySeries", function(orig, ...)
        local groups = orig(...)
        if not (active() and type(groups) == "table") then return groups end
        ZenGroups.ensureOutermost()
        Virtual.ensureOutermost()
        return series(groups)
    end, "ZenOS getGroupedBySeries")

    -- With a folder, ZenOS reads one folder's books (folder covers): left as is.
    Guard.hook("zenos_groups", db, "getLightMetadata", function(orig, directory, ...)
        local result = orig(directory, ...)
        if directory ~= nil or not (active() and type(result) == "table") then return result end
        return metadata(result)
    end, "ZenOS getLightMetadata")

    ZenGroups.ensureOutermost()
    logger.info("CloudLibrary: cloud books added to ZenOS's Authors and Series")
end

return ZenGroups
