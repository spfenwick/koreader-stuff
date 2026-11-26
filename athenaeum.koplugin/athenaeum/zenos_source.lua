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
  cover badges (cloud, on this device, not in the catalog) on every cover
  ZenOS draws, via badge(): ZenOS paints the icon (athenaeum/badge.lua)
  covers and metadata everywhere, via bookInfo(), answered inside ZenOS's
  own cover caches (changed(paths) drops their entries when a cover
  arrives, or a book is downloaded or deleted: its path stays the same,
  what's behind it doesn't)
  the library folder's listing, the counts in the folders above it, folder
  covers and ZenOS's flat view, via fileless and books() (with attr for the
  date and size sorts): ZenOS lists the books without a file that their
  source owns (BookSources.booksWithoutFile)
  cached folder listings, via listingKey(): a listing is rebuilt when the
  cloud books in it change, and one saved before the plugin was removed
  isn't reused
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
removed. There's no setting to leave cloud books out of the groups (the
old "zenos_groups"): they're in the library folder, so they're in the
groups too.
]]

local logger = require("logger")
local Guard = require("athenaeum/guard")

local ZenSource = {
    registered = false,
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
        ZenSource.historyChanged({ history_path })
    end) }
end

-- The source ------------------------------------------------------------------

-- db_bookinfo rebuilds a grouping from this; rebuilt with the catalog.
local books_cache, books_gen
local function books()
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
        },
        -- Size and dates (the date added) for the date and size sorts, where
        -- ZenOS lists the book itself (its flat view).
        attr = Virtual.attributes(book) }
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

-- The cover badge's icon (athenaeum/badge.lua decides which badge a path gets).
local function badge(path)
    local Badge = require("athenaeum/badge")
    local kind = Badge.kind(path)
    return kind and { icon = Badge.icon(kind) } or nil
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
        -- books() has only cloud books (no file here): ZenOS lists them in
        -- the library folder, its folder cover and the counts above it.
        fileless = true,
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
        badge = protect("badge", "badge", badge),
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
    -- Badges turned off after an error: ZenOS repaints without them.
    Guard.on_failure.badge = function() ZenSource.badgesChanged() end
    logger.info("Athenaeum: registered as a ZenOS book source")
    return true
end

local function bookSources()
    local BookSources = package.loaded[MODULE]
    return type(BookSources) == "table" and BookSources or nil
end

--- True when ZenOS's Home is shown, or about to be (ZenOS can start on
-- Home with the file browser hidden behind it).
function ZenSource.homeOnTop()
    local BookSources = bookSources()
    if not (BookSources and type(BookSources.isHomeOnTop) == "function") then return false end
    local ok, top = pcall(BookSources.isHomeOnTop)
    return ok and top == true
end

--- This device's reading history changed (an entry was removed): ZenOS's
-- Home reads it again and forgets what it cached for these paths.
function ZenSource.historyChanged(paths)
    local BookSources = bookSources()
    if not (BookSources and type(BookSources.historyChanged) == "function") then return end
    local ok, err = pcall(BookSources.historyChanged, paths)
    if not ok then logger.warn("Athenaeum: ZenOS book sources historyChanged():", err) end
end

--- Cloud books' states (from Concordance) may have changed: ZenOS reads
-- their statuses again (keeping its groupings) and refreshes its open
-- views (the file browser when it lists cloud books).
function ZenSource.statesChanged()
    if not ZenSource.registered then return end
    local BookSources = bookSources()
    if not (BookSources and type(BookSources.statusChanged) == "function") then return end
    local ok, err = pcall(BookSources.statusChanged)
    if not ok then logger.warn("Athenaeum: ZenOS book sources statusChanged():", err) end
end

--- Which books get a badge, or which badge, changed (a badge setting):
-- ZenOS repaints its covers (and redraws the file browser when it lists
-- cloud books).
function ZenSource.badgesChanged()
    if not ZenSource.registered then return end
    local BookSources = bookSources()
    if not (BookSources and type(BookSources.statusChanged) == "function") then return end
    local ok, err = pcall(BookSources.statusChanged)
    if not ok then logger.warn("Athenaeum: ZenOS book sources statusChanged():", err) end
end

--- Tells ZenOS the cloud books changed; with paths, also that their covers,
-- metadata or files did (ZenOS drops its cached covers and Home's details
-- for them). ZenOS's open views are refreshed.
function ZenSource.changed(paths)
    if not ZenSource.registered then return end
    books_cache = nil
    local BookSources = bookSources()
    if BookSources and type(BookSources.changed) == "function" then
        local ok, err = pcall(BookSources.changed, paths)
        if not ok then logger.warn("Athenaeum: ZenOS book sources changed():", err) end
    end
end

return ZenSource
