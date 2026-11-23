--[[
The plugin's ZenOS side: the cloud books are a ZenOS book source (ZenOS's
common/book_sources.lua, which the plugin requires). ZenOS then shows them:
  Authors, Series, Languages and Tags tabs (and what ZenOS builds from
  them: Home rows, end-of-book suggestions), via books()
  Home's reading history strip, book switcher, To Be Read, via owns()
  taps and long-presses everywhere ZenOS opens or long-presses a book (the
  file browser, Home, group views, To Be Read, collections, end-of-book
  suggestions), via open() and showContextMenu(): ZenOS asks the sources
  in its filemanagerutil.openFile and FileChooser:showFileDialog wrappers,
  and cancels its opening banner when a source opens a book
  covers and metadata everywhere, via bookInfo(), answered inside ZenOS's
  own cover caches (changed(paths) drops their entries when a cover
  arrives)
  cached folder listings, via listingKey(): a listing is rebuilt when the
  cloud books in it change, and one saved before the plugin was removed
  isn't reused
  downloads and deletes, via BookSources.moved(): ZenOS's open views list
  the book at its file (or back at its cloud entry), and after a download
  ZenOS edits its cached listing of the library folder instead of
  rebuilding it (ZENOS_PRS.md, #4)
  reading status, rating and the date a book was finished from other
  devices (from Concordance), via
  status(), for cloud books and for the library's downloaded books not
  opened here: ZenOS shows them as it does a local book's (read-only; ZenOS
  asks only about books without a sidecar, so a book opened here keeps its
  own)

  books read elsewhere that Concordance hasn't put into ReadHistory.hist
  yet (it waits while a menu or a book is open), via history(): Home and
  the book switcher show them meanwhile. Only those: once in the history,
  Concordance's entries (athenaeum/history.lua keeps cloud ones there)
  are what every history view reads, ZenOS's History tab included, and
  ZenOS skips a history() entry for a book already in it. See
  INFORMATION_ARCHITECTURE.md, #4.

Athenaeum used to hook filemanagerutil.openFile, the file chooser's
showFileDialog and the file browser's onMenuSelect/onMenuHold, for ZenOS
views that didn't ask the sources; it now needs a ZenOS that does
(ZENOS_PRS.md, #1). Until 0.9.14 getGroupedByTags was hooked too, to list
each book once per tag; ZenOS was never found adding a book twice, so it was
removed.
Setting "zenos_groups" (default true): cloud books in the groups.
]]

local logger = require("logger")
local Guard = require("athenaeum/guard")

local ZenSource = {
    registered = false,
    enabled = nil, -- function() -> true to list cloud books in groups
    state = nil,   -- function(path) -> { status, rating, finished_at } or nil
    history = nil, -- function() -> { { file, time }, … } waiting to go into the history
}

local MODULE = "common/book_sources"
local ID = "athenaeum"
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

-- Open and long-press -----------------------------------------------------------

-- Details for a book ZenOS shows from a history list (Home's Recently read
-- passes _zen_is_history): with "Remove from history", after which Home
-- forgets the entry and is redrawn.
local function historyOpts(item, path)
    if not item._zen_is_history then return nil end
    local history_path = item._zen_history_path or path
    return { extra_rows = require("athenaeum/history").removeRows(history_path, function()
        ZenSource.refreshHome({ history_path })
    end) }
end

-- The source ------------------------------------------------------------------

-- db_bookinfo rebuilds a grouping from this; rebuilt with the catalog.
local books_cache, books_gen
local function books()
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

local function show(path, opts)
    if not Virtual.by_path[path] or selecting() then return false end
    Virtual.showDetails(path, opts)
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

-- Cloud books and the library's files (see ZenSource.state).
local function status(path)
    local state = ZenSource.state and ZenSource.state(path)
    return type(state) == "table"
        and { status = state.status, rating = state.rating, finished_at = state.finished_at } or nil
end

-- Books read elsewhere waiting to go into the history (see ZenSource.history).
local function history()
    local list = ZenSource.history and ZenSource.history()
    return type(list) == "table" and list or {}
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
            if type(item) ~= "table" then return false end
            local path = item.path or item.file
            return show(path, historyOpts(item, path))
        end),
        invalidate = function() books_cache = nil end,
        bookInfo = protect("library", "bookInfo", function(path, get_cover)
            return Virtual.bookInfoFor(path, get_cover)
        end),
        listingKey = protect("library", "listingKey", listingKey),
        status = protect("library", "status", status),
        history = protect("zenos", "history", history),
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
    if not (ok_meta and res) then logger.warn("Athenaeum: ZenOS metadata integration unavailable", res) end
    -- Turned off after an error: ZenOS rebuilds its groupings without them.
    Guard.on_failure.zenos = function() ZenSource.changed() end
    logger.info("Athenaeum: registered as a ZenOS book source")
    return true
end

-- Moves ------------------------------------------------------------------------

--- A book moved between its cloud entry and its file (downloaded, or the
-- file deleted): ZenOS's open views (Authors, Series, Languages, Tags and
-- their book lists, To Be Read, history and search lists) list it at
-- new_path, and its cached listing of the library folder is edited rather
-- than rebuilt when new_path is a file (ZENOS_PRS.md, #4). Call it once the
-- catalog has been set (Virtual.listingKey() is the new one). False when
-- ZenOS has no BookSources.moved: the caller redraws the folder itself.
function ZenSource.moved(old_path, new_path)
    local BookSources = package.loaded[MODULE]
    if type(BookSources) ~= "table" or type(BookSources.moved) ~= "function" then return false end
    return BookSources.moved(old_path, new_path) == true
end

--- A cloud book was downloaded: open views, the library folder and Home
-- show the file. False when the folder wasn't redrawn (see moved()).
function ZenSource.downloaded(old_path, new_path)
    local told = ZenSource.moved(old_path, new_path)
    -- ZenOS edits its listing: no "Rebuilding library…" for this change.
    if told then Virtual.rebuild_pending = false end
    ZenSource.refreshHome({ old_path, new_path })
    return told
end

--- A book's file came or went (downloaded, or deleted and back to its
-- cloud entry): ZenOS's Home forgets what it cached for these paths and
-- rebuilds now if it's on top, else when it's next shown.
function ZenSource.refreshHome(paths)
    local FileManager = require("apps/filemanager/filemanager")
    local plugin = FileManager.instance and FileManager.instance.zenos
    local home = plugin and require("common/shared_state").get(plugin, "home")
    if type(home) ~= "table" then return end
    if type(home.invalidateBookCache) == "function" then
        for _i, path in ipairs(paths or {}) do home.invalidateBookCache(path, true) end
    end
    if type(home.rebuildActive) == "function" then home.rebuildActive() end
end

--- True when ZenOS's Home is on top of the file browser, or the file
-- browser is hidden behind it (ZenOS can start on Home with the file
-- browser not shown yet).
function ZenSource.homeOnTop()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not fm then return false end
    if fm.invisible == true then return true end
    local ok, home = pcall(function()
        return fm.zenos and require("common/shared_state").get(fm.zenos, "home")
    end)
    if not ok or type(home) ~= "table" or type(home.isActiveOnTop) ~= "function" then return false end
    local ok_top, top = pcall(home.isActiveOnTop)
    return ok_top and top == true
end

--- Cloud books' states (from Concordance) may have changed: ZenOS reads
-- their statuses again (keeping its groupings; a ZenOS without
-- statusChanged rebuilds those too), and the library folder and Home are
-- redrawn.
function ZenSource.statesChanged()
    if not ZenSource.registered then return end
    local BookSources = package.loaded[MODULE]
    if type(BookSources) == "table" and type(BookSources.statusChanged) == "function" then
        local ok, err = pcall(BookSources.statusChanged)
        if not ok then logger.warn("Athenaeum: ZenOS book sources statusChanged():", err) end
    else
        ZenSource.changed()
    end
    Virtual.refresh()
    ZenSource.refreshHome()
end

--- Tells ZenOS the cloud books changed; with paths, also that their covers
-- or metadata did (ZenOS drops its cached covers for them).
function ZenSource.changed(paths)
    if not ZenSource.registered then return end
    books_cache = nil
    local BookSources = package.loaded[MODULE]
    if type(BookSources) == "table" and type(BookSources.changed) == "function" then
        local ok, err = pcall(BookSources.changed, paths)
        if not ok then logger.warn("Athenaeum: ZenOS book sources changed():", err) end
    end
end

return ZenSource
