--[[
Virtual entries: books in the online library that aren't on the device are
listed in the library folder as files that don't exist. Their metadata and
covers come from the catalog cache instead of the file.

A cloud book's path is where its file would be: the file name the catalog
gave it ("Author - Title.epub", names.lua, Library.nameBooks), which a
download uses. So downloading or deleting a book changes what's at its
path, never the path (STABLE_PATHS_PLAN.md). A real file at that name in
the listing (a book the matcher didn't recognise) hides the cloud entry
until the next load names the book again.

The plugin runs under ZenOS only: the cloud books are a ZenOS book source
(zenos_source.lua), so ZenOS answers CoverBrowser's getBookInfo and
getDocProps for them (from Virtual.bookInfoFor), sends taps and
long-presses to the source, and keys its cached listings on
Virtual.listingKey(). The KOReader and CoverBrowser functions changed here:
  FileChooser:getList              adds the entries to the library folder
                                   (and counts them in the folder above),
                                   with the "Rebuilding library..." message
  BookInfoManager:extractInBackground / :isExtractingInBackground
                                   covers not downloaded yet are fetched when
                                   CoverBrowser (or ZenOS) asks to extract
                                   them, and it waits while they download
  ReaderUI:showReader / :switchDocument
                                   any other route that opens a virtual book
  DocSettings:flush, :flushCustomCover, :flushCustomMetadata
                                   never write book settings for a virtual
                                   book (ZenOS marks a book "reading" as
                                   soon as it's opened, for example)

ZenOS shows an "Opening" banner as soon as a book is tapped and removes it
only when a reader opens. If its __ZEN_UI_CANCEL_OPENING_BANNER function
exists, it's called when the details are shown instead.
]]

local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Timing = require("athenaeum/timing")
local Guard = require("athenaeum/guard")
local Names = require("athenaeum/names")
local ZenSource = require("athenaeum/zenos_source")

local Virtual = {
    folder = nil, -- library folder, no trailing slash
    books = {},
    by_path = {},
    by_id = {},
    installed = false,
    generation = 0, -- changes with every setCatalog()
    catalog_sig = "", -- the books listed and what their list items show
}

local function normalize(path)
    if type(path) ~= "string" then return nil end
    return (path:gsub("/+$", ""))
end

function Virtual.isVirtual(path)
    return type(path) == "string" and Virtual.by_path[path] ~= nil
end

function Virtual.getBook(path)
    return Virtual.by_path[path]
end

local function signature(folder, books)
    local parts = { folder or "" }
    for i, b in ipairs(books) do
        parts[i + 1] = table.concat({ b.id, b.filename or "", b.title or "",
            type(b.authors) == "table" and table.concat(b.authors, "\31") or "",
            b.series or "", tostring(b.series_index or "") }, "\t")
    end
    return require("ffi/sha2").md5(table.concat(parts, "\n"))
end

-- The cloud books listed changed since the library folder was last listed
-- (not counting the first catalog loaded: ZenOS's saved listing has it).
local loaded_once = false

local function noteChange(before)
    if loaded_once and Virtual.catalog_sig ~= before then Virtual.rebuild_pending = true end
    loaded_once = true
end

function Virtual.setCatalog(folder, books)
    local old = Virtual.books
    local before = Virtual.catalog_sig
    Virtual.folder = normalize(folder)
    Virtual.books, Virtual.by_path, Virtual.by_id = {}, {}, {}
    Virtual.generation = Virtual.generation + 1
    -- Turned off (startup check or an error): no cloud books.
    if not Virtual.folder or not Guard.ok("library") then
        Virtual.catalog_sig = signature(Virtual.folder, {})
        noteChange(before)
        Virtual.notifyChanged(old)
        return
    end
    -- A book's entry is where its file would be: the file name the catalog
    -- gave it (Library.nameBooks). Books given without one (tests) are
    -- named here, like a download.
    local listed = {}
    for _i, book in ipairs(books or {}) do
        -- One entry per catalog book, however often the catalog lists it.
        if type(book.id) == "string" and book.id ~= "" and not Virtual.by_id[book.id] then
            listed[#listed + 1] = book
            Virtual.by_id[book.id] = book
        end
    end
    Names.assign(listed, {}, {}, {
        base = function(book) return require("athenaeum/downloads").baseStem(book) end,
        suffix = function() return "epub" end,
    })
    for _i, book in ipairs(listed) do
        book.filename = Names.join(book.file_stem, book.file_ext)
        book.path = Virtual.folder .. "/" .. book.filename
        table.insert(Virtual.books, book)
        Virtual.by_path[book.path] = book
    end
    Virtual.catalog_sig = signature(Virtual.folder, Virtual.books)
    noteChange(before)
    Virtual.notifyChanged(old)
end

-- What ZenOS shows of a cloud book (the stored columns, as loaded): when
-- it differs, ZenOS drops what it cached for the book. A refetched cover
-- keeps its file name, but not its download state.
local SHOWN_FIELDS = { "title", "authors", "tags", "language", "added", "size",
    "series", "series_index", "pages", "cover_href", "cover_file", "cover_w",
    "cover_h", "cover_failed", "cover_stale" }

local function shown(book)
    local parts = {}
    for i, key in ipairs(SHOWN_FIELDS) do
        -- A stored row keeps lists as text ("_authors"), split when first read.
        local value = rawget(book, "_" .. key)
        if value == nil then value = rawget(book, key) end
        if type(value) == "table" then value = table.concat(value, "\31") end
        parts[i] = tostring(value)
    end
    return table.concat(parts, "\t")
end

--- Tells ZenOS which cloud books changed since old_books (gone, changed,
-- then new ones), if any: groupings are rebuilt, its cached covers and
-- metadata for them dropped, and its open views refreshed (the file
-- browser when it shows the library folder or one above it).
function Virtual.notifyChanged(old_books)
    if not ZenSource.registered then return end
    local now = {}
    for _i, book in ipairs(Virtual.books) do now[book.path] = book end
    local paths, before = {}, {}
    for _i, book in ipairs(old_books or {}) do
        before[book.path] = true
        local current = now[book.path]
        if not current or shown(current) ~= shown(book) then paths[#paths + 1] = book.path end
    end
    for _i, book in ipairs(Virtual.books) do
        if not before[book.path] then paths[#paths + 1] = book.path end
    end
    if #paths > 0 then ZenSource.changed(paths) end
end

--- Key for ZenOS's cached listings that show the cloud books: changes with
-- the books, and is the same after a restart.
function Virtual.listingKey()
    return Virtual.catalog_sig
end

--- The library folder's listing is being built (FileChooser:getList, which
-- ZenOS calls only when its cached listing is out of date). After the
-- catalog changed, that can take seconds: "Rebuilding library…" is shown
-- until the folder is drawn. Not while ZenOS's Home is on top: the listing
-- is then rebuilt out of sight (and the Library tab opens without it).
-- True if the message was shown.
function Virtual.listingRebuilding()
    if not Virtual.rebuild_pending then return false end
    Virtual.rebuild_pending = false
    if ZenSource.homeOnTop() then return false end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Rebuilding library…"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()
    -- Tasks run before the next repaint, which draws the new listing.
    UIManager:nextTick(function() UIManager:close(msg) end)
    return true
end

local function attributes(book)
    local added = book.added or 0
    return {
        mode = "file",
        size = book.size or 0,
        modification = added,
        access = added,
        change = added,
    }
end

-- Covers ----------------------------------------------------------------------

-- Hooks set by the library (see library.lua and covers.lua).
Virtual.canFetchCovers = nil -- function() -> true if covers can be downloaded now
Virtual.requestCovers = nil  -- function(books) -> true if they'll be downloaded
Virtual.coversBusy = nil     -- function() -> true while downloading
Virtual.detailsButtons = nil -- function(id, full_book, close) -> ButtonDialog rows
Virtual.stateText = nil      -- function(id) -> a line on the book's status from other devices, or nil

--- "ready", "pending" (can be downloaded now) or "none".
function Virtual.coverState(book)
    if book.cover then
        if book.cover_w == nil then
            -- No size recorded (test catalogs): decode once to find it.
            local RenderImage = require("ui/renderimage")
            local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, book.cover, false)
            if ok and bb then
                book.cover_w, book.cover_h = bb:getWidth(), bb:getHeight()
                bb:free()
            else
                book.cover_w = false
            end
        end
        if book.cover_w then return "ready" end
    end
    if book.cover_href and not book.cover_failed and not book.cover
            and not (book.cover_retry_at and book.cover_retry_at > os.time())
            and Virtual.canFetchCovers and Virtual.canFetchCovers() then
        return "pending"
    end
    return "none"
end

-- Covers are decoded at most at half the screen (a cover is never shown
-- bigger), and the last few are kept decoded so paging back and forth
-- doesn't decode them again. Callers get a copy, which they own.
local DECODED_MAX = 18
local decoded, decoded_order = {}, {}

local function coverLimit()
    local Screen = require("device").screen
    return math.floor(Screen:getWidth() / 2), math.floor(Screen:getHeight() / 2)
end

local function fitted(book)
    local max_w, max_h = coverLimit()
    local w, h = book.cover_w, book.cover_h
    local scale = math.min(1, max_w / w, max_h / h)
    return math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5)), scale < 1
end

local function decodedCover(book)
    local bb = decoded[book.cover]
    if not bb then
        local w, h, scaled = fitted(book)
        local RenderImage = require("ui/renderimage")
        local t0 = Timing.start()
        local ok, res = pcall(RenderImage.renderImageFile, RenderImage, book.cover, false,
            scaled and w or nil, scaled and h or nil)
        Timing.record("covers: decode one", Timing.since(t0),
            string.format("%dx%d%s", w, h, scaled and ", scaled" or ""), true)
        if not (ok and res) then
            logger.warn("Athenaeum: can't decode cover", book.cover, res)
            book.cover, book.cover_w, book.cover_failed = nil, nil, os.time()
            return nil
        end
        bb = res
        decoded[book.cover] = bb
        table.insert(decoded_order, book.cover)
        while #decoded_order > DECODED_MAX do
            local old = table.remove(decoded_order, 1)
            if decoded[old] then decoded[old]:free() end
            decoded[old] = nil
        end
    end
    return bb:copy()
end

function Virtual.forgetDecodedCovers()
    for _path, bb in pairs(decoded) do bb:free() end
    decoded, decoded_order = {}, {}
end

local function docProps(book)
    return {
        pages = nil,
        title = book.title,
        authors = book.authors and table.concat(book.authors, "\n") or nil,
        series = book.series,
        series_index = book.series_index,
        language = book.language,
        keywords = book.tags and table.concat(book.tags, "\n") or nil,
        description = book.summary,
    }
end

-- Same shape as a bookinfo_cache row, so CoverBrowser and ZenOS draw it like
-- any other book. The size reported is the size the cover is decoded at, so
-- isCachedCoverInvalid() never asks for a bigger one. A cover that can be
-- downloaded now is reported as not fetched yet: CoverBrowser then asks for
-- it through extractInBackground(), which installBookInfo turns into a
-- download (Virtual.fetchCovers), and redraws the book when it's ready.
local function bookInfo(book, get_cover)
    local directory, filename = util.splitFilePathName(book.path)
    local info = docProps(book)
    info.directory = directory
    info.filename = filename
    info.filesize = book.size
    info.filemtime = book.added
    info.in_progress = 0
    info.has_meta = "Y"
    local state = Virtual.coverState(book)
    if state == "ready" then
        info.cover_fetched = "Y"
        info.has_cover = "Y"
        info.cover_w, info.cover_h = fitted(book)
        info.cover_sizetag = info.cover_w .. "x" .. info.cover_h
        if get_cover then info.cover_bb = decodedCover(book) end
        if get_cover and not info.cover_bb then info.has_cover = nil end
    elseif state == "none" then
        info.cover_fetched = "Y"
    end -- pending: cover_fetched stays nil
    return info
end

--- CoverBrowser metadata for a cloud book, or nil (ZenOS's book sources).
function Virtual.bookInfoFor(path, get_cover)
    local book = Virtual.by_path[path]
    return book and bookInfo(book, get_cover) or nil
end

local function cancelZenOSOpeningBanner()
    local cancel = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
    if type(cancel) == "function" then pcall(cancel) end
end

--- opts.extra_rows: optional function(close) -> more button rows, shown
-- after the book's own (e.g. "Remove from history" from a history list).
function Virtual.showDetails(path, opts)
    local book = Virtual.by_path[path]
    if not book then return end
    cancelZenOSOpeningBanner()
    rawset(_G, "__ATHENAEUM_LAST_DETAILS", path)
    local UIManager = require("ui/uimanager")
    -- Full record (summary, formats...) from the catalog, when available.
    local full = Virtual.details and Virtual.details(book.id) or book
    local series
    if full.series then
        local index = tonumber(full.series_index)
        series = index and string.format("%s #%.4g", full.series, index)
            or full.series_index and string.format("%s #%s", full.series, tostring(full.series_index))
            or full.series
    end
    local facts = {}
    if full.published then table.insert(facts, tostring(full.published)) end
    if full.pages then table.insert(facts, string.format(_("%d pages"), full.pages)) end
    local kinds = {}
    for _i, f in ipairs(full.formats or {}) do
        local kind = (f.type or ""):match("epub") and "EPUB" or (f.type or ""):match("pdf") and "PDF"
            or (f.type or ""):match("comicbook") and "CBZ" or (f.type or ""):match("mobi") and "MOBI"
            or (f.type or ""):match("([%w]+)$")
        if kind then table.insert(kinds, kind:upper()) end
    end
    if #kinds > 0 then table.insert(facts, table.concat(kinds, ", ")) end
    local summary
    if full.summary then
        summary = full.summary:gsub("%s+", " ")
        if #summary > 400 then
            summary = summary:sub(1, 400):gsub("[\128-\191]*$", ""):gsub("%s*%S*$", "") .. "…"
        end
    end
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = Virtual.detailsButtons and Virtual.detailsButtons(book.id, full, close)
        or {{ { text = _("Close"), callback = close } }}
    if type(opts) == "table" and type(opts.extra_rows) == "function" then
        for _i, row in ipairs(opts.extra_rows(close) or {}) do table.insert(buttons, row) end
    end
    dialog = require("athenaeum/details").show{
        path = path,
        cover_file = book.cover,
        title = full.title or book.title or book.id,
        authors = full.authors and #full.authors > 0 and table.concat(full.authors, ", ") or nil,
        series = series,
        facts = #facts > 0 and table.concat(facts, " · ") or nil,
        state = Virtual.stateText and Virtual.stateText(book.id) or nil,
        summary = summary,
        buttons = buttons,
    }
end

-- The book's metadata on its list item, as KOReader's title, authors and
-- series sorts leave it. Code that reads metadata from CoverBrowser's
-- database itself when an item has none (ZenOS's series grouping in the
-- Library view) would find nothing for a cloud book, so it's always set.
local function withProps(item, book)
    if type(item) == "table" and type(item.doc_props) ~= "table" then
        local props = docProps(book)
        props.display_title = book.title or (book.filename and book.filename:gsub("%.[^.]*$", ""))
        item.doc_props = props
    end
    return item
end

--- A file browser item for a virtual book (as in the library folder).
function Virtual.listItem(fc, book, collate)
    local dir = book.path:match("^(.*)/[^/]*$")
    return withProps(fc:getListItem(dir, book.filename, book.path, attributes(book), collate), book)
end

-- getDocProps() fields CoverBrowser keeps (ZenOS's book sources fill them).
local DOC_PROPS = { "pages", "title", "authors", "series", "series_index",
    "language", "keywords", "description" }

-- The title, author and series sorts look up each book's metadata through
-- FileManagerBookInfo:getDocProps(): for a cloud book that's CoverBrowser's
-- getDocProps(), which ZenOS answers from its book sources (Athenaeum's
-- metadata with the user's edits) after querying CoverBrowser's database,
-- which has no row for a path without a file. While fn lists the cloud
-- books, ui.bookinfo answers them from the book sources directly, with what
-- that chain gives: the same fields, and display_title as KOReader sets it.
-- Only with CoverBrowser (without it, KOReader looks elsewhere).
local function withCloudDocProps(ui, fn)
    local bookinfo = type(ui) == "table" and ui.coverbrowser and ui.bookinfo
    local BookSources = package.loaded["common/book_sources"]
    if type(bookinfo) ~= "table" or type(bookinfo.getDocProps) ~= "function"
            or type(BookSources) ~= "table" or type(BookSources.bookInfo) ~= "function" then
        return fn()
    end
    local splitFileNameType = require("apps/filemanager/filemanagerutil").splitFileNameType
    local own, getDocProps = rawget(bookinfo, "getDocProps"), bookinfo.getDocProps
    bookinfo.getDocProps = function(self, file, ...)
        local info = Virtual.by_path[file] and BookSources.bookInfo(file, false)
        if type(info) ~= "table" then return getDocProps(self, file, ...) end
        local props = {}
        for _i, key in ipairs(DOC_PROPS) do props[key] = info[key] end
        props.display_title = props.title or splitFileNameType(file)
        return props
    end
    local ok, err = pcall(fn)
    rawset(bookinfo, "getDocProps", own)
    if not ok then error(err, 0) end
end
Virtual._withCloudDocProps = withCloudDocProps -- for tests

-- True when the file browser's filters (its status filter, excluded and
-- unsupported files) let a cloud book through, as FileChooser:getList asks
-- of each file. A filter that fails lets it through.
local function passesFilter(fc, book)
    if type(fc) ~= "table" or type(fc.show_file) ~= "function" then return true end
    local ok, shown = pcall(fc.show_file, fc, book.filename, book.path)
    return not ok or not not shown
end
Virtual._passesFilter = passesFilter -- for tests

-- Adds the cloud books' items to a listing of the library folder (files:
-- the folder's own), those the browser's filters let through. A file that
-- turned up at a cloud book's name since the catalog was loaded is listed
-- as itself (the next load renames the book).
local function addCloudItems(fc, path, files, collate)
    local present = {}
    for _i, item in ipairs(files) do
        if type(item) == "table" and type(item.path) == "string" then
            present[item.path:match("[^/]*$")] = true
        end
    end
    for _i, book in ipairs(Virtual.books) do
        if not present[book.filename] and passesFilter(fc, book) then
            table.insert(files, withProps(fc:getListItem(path, book.filename,
                book.path, attributes(book), collate), book))
        end
    end
end
Virtual._addCloudItems = addCloudItems -- for tests

local function installListing()
    local FileChooser = require("ui/widget/filechooser")
    Guard.hook("library", FileChooser, "getList", function(orig, self, path, collate)
        local library = self.name == "filemanager" and Virtual.folder
            and normalize(path) == Virtual.folder
        if library and collate then
            -- Only a message: a failure mustn't turn the library off.
            local ok, err = pcall(Virtual.listingRebuilding)
            if not ok then logger.warn("Athenaeum: rebuilding message:", err) end
        end
        local dirs, files, readable = orig(self, path, collate)
        if library and not collate then
            for _i, book in ipairs(Virtual.books) do
                if passesFilter(self, book) then
                    table.insert(files, true) -- counting only, like FileChooser:getPathList()
                end
            end
        elseif library then
            -- Timed as a whole: timing each book's parts (wrapping three
            -- calls per book) cost more than some of the parts it measured.
            local t0 = Timing.start()
            withCloudDocProps(self.ui, function() addCloudItems(self, path, files, collate) end)
            Timing.record("listing: add cloud books", Timing.since(t0), #Virtual.books .. " books")
        end
        return dirs, files, readable
    end, "FileChooser:getList")
end

--- Downloads the covers of the cloud books among paths (they have no file
-- to extract them from). If they can't be now (Wi-Fi went off), they're
-- shown without a cover for now instead of waited for.
function Virtual.fetchCovers(paths)
    local wanted = {}
    for _i, path in ipairs(paths or {}) do
        local book = Virtual.by_path[path]
        if book then wanted[#wanted + 1] = book end
    end
    if #wanted == 0 then return end
    if not (Virtual.requestCovers and Virtual.requestCovers(wanted)) then
        local missed = {}
        for i, book in ipairs(wanted) do
            book.cover_retry_at = os.time() + 120
            missed[i] = book.path
        end
        ZenSource.changed(missed)
    end
end

-- Cloud books are never extracted by CoverBrowser: their covers are
-- downloaded (Virtual.fetchCovers), and it waits while they are.
local function installBookInfo()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.extractInBackground) ~= "function" then
        logger.warn("Athenaeum: CoverBrowser unavailable, no covers for cloud books")
        return false
    end
    Guard.hook("library", BookInfoManager, "extractInBackground", function(orig, self, files, ...)
        if type(files) ~= "table" then return orig(self, files, ...) end
        local real, wanted = {}, {}
        for _i, file in ipairs(files) do
            local path = type(file) == "table" and file.filepath or file
            if Virtual.by_path[path] then wanted[#wanted + 1] = path else real[#real + 1] = file end
        end
        if #wanted == 0 then return orig(self, files, ...) end
        Virtual.fetchCovers(wanted)
        if #real > 0 then return orig(self, real, ...) end
        -- Success, though nothing was extracted: CoverBrowser shows an
        -- error otherwise, and stops waiting once
        -- isExtractingInBackground() is false.
        return true
    end, "BookInfoManager:extractInBackground")
    Guard.hook("library", BookInfoManager, "isExtractingInBackground", function(orig, self, ...)
        return orig(self, ...) or (Virtual.coversBusy and Virtual.coversBusy()) or false
    end, "BookInfoManager:isExtractingInBackground")
    return true
end
Virtual._installBookInfo = installBookInfo -- for tests

local function installOpen()
    local ReaderUI = require("apps/reader/readerui")
    Guard.hook("library", ReaderUI, "showReader", function(orig, self, file, ...)
        if Virtual.by_path[file] then
            Virtual.showDetails(file)
            return
        end
        return orig(self, file, ...)
    end, "ReaderUI:showReader")
    if type(ReaderUI.switchDocument) == "function" then
        Guard.hook("library", ReaderUI, "switchDocument", function(orig, self, file, ...)
            if Virtual.by_path[file] then
                Virtual.showDetails(file)
                return
            end
            return orig(self, file, ...)
        end, "ReaderUI:switchDocument")
    end
end

local function installSettingsGuard()
    local DocSettings = require("docsettings")
    Guard.hook("library", DocSettings, "flush", function(orig, self, data, ...)
        local doc_path = type(data) == "table" and data.doc_path
            or type(self.data) == "table" and self.data.doc_path
        if Virtual.by_path[doc_path] then
            logger.dbg("Athenaeum: not writing settings for", doc_path)
            return
        end
        return orig(self, data, ...)
    end, "DocSettings:flush")
    for _i, name in ipairs({ "flushCustomCover", "flushCustomMetadata" }) do
        if type(DocSettings[name]) == "function" then
            Guard.hook("library", DocSettings, name, function(orig, self, doc_path, ...)
                if Virtual.by_path[doc_path] then return end
                return orig(self, doc_path, ...)
            end, "DocSettings:" .. name)
        end
    end
end

-- Listing a book asks whether it was opened (a stat for each place its
-- sidecar could be) and whether it's in a collection (a realpath() call,
-- with a 4 KB buffer each time). A cloud book has no file: KOReader never
-- writes its settings (installSettingsGuard), so it was never opened here,
-- and realpath() fails on it anyway, so its own path is what collections
-- are checked with. For 2,000 cloud books that saves 3 to 6 s a listing
-- on a Kobo, most of it when the disk is cold or busy.
-- Both are called for every book listed, so they're plain wrappers rather
-- than Guard.hook (whose pcall per call cost about as much as the checks
-- left over); the shortcuts are table lookups that can't fail.
-- The collections shortcut reads ReadCollection.coll directly (a table per
-- collection, keyed by file path), which is KOReader's own business. At
-- startup a throwaway collection is built with KOReader's own functions, on
-- a real file (this one), and checked to have that shape and to be found by
-- in_collections. Returns nil when all is well, else what's wrong.
local function checkCollections(ReadCollection, in_collections)
    local ok, problem = pcall(function()
        local source = debug.getinfo(1, "S").source
        local file = type(source) == "string" and source:match("^@(.+)$")
        file = file and require("ffi/util").realpath(file)
        if not file then return nil end -- nothing to check with: trust it
        local name = "athenaeum-check"
        local probe = setmetatable({ coll = {}, coll_settings = {} }, { __index = ReadCollection })
        ReadCollection.addCollection(probe, name)
        ReadCollection.addItem(probe, file, name)
        local coll = probe.coll[name]
        if type(coll) ~= "table" or not coll[file] then
            return "collections aren't tables keyed by file path"
        end
        if not in_collections(probe, file, true) then
            return "isFileInCollections doesn't find a file added to a collection"
        end
    end)
    if not ok then return "checking collections failed: " .. tostring(problem) end
    return problem
end
Virtual._checkCollections = checkCollections -- for tests

local function installCloudShortcuts()
    local BookList = require("ui/widget/booklist")
    local opened = BookList.hasBookBeenOpened
    if type(opened) ~= "function" then
        Guard.problem("library", "BookList.hasBookBeenOpened is missing")
    else
        BookList.hasBookBeenOpened = function(file, ...)
            if Virtual.by_path[file] and Guard.ok("library") then return false end
            return opened(file, ...)
        end
    end
    local ReadCollection = require("readcollection")
    local in_collections = ReadCollection.isFileInCollections
    if type(in_collections) ~= "function" then
        Guard.problem("library", "ReadCollection:isFileInCollections is missing")
        return
    end
    -- Only a shortcut: if collections changed shape, KOReader's own check
    -- answers for cloud books too (slower, but right).
    local problem = checkCollections(ReadCollection, in_collections)
    if problem then
        logger.warn("Athenaeum: collections shortcut not installed:", problem)
        Virtual.collections_problem = problem
        return
    end
    ReadCollection.isFileInCollections = function(self, file, ignore_mark, ...)
        if not (Virtual.by_path[file] and type(self) == "table" and type(self.coll) == "table"
                and Guard.ok("library")) then
            return in_collections(self, file, ignore_mark, ...)
        end
        if not (ignore_mark or G_reader_settings:nilOrTrue("collection_show_mark")) then return false end
        for _name, coll in pairs(self.coll) do
            if type(coll) == "table" and coll[file] then return true end
        end
        return false
    end
end
Virtual._installCloudShortcuts = installCloudShortcuts -- for tests

--- Installs the hooks. Returns false (and installs nothing) when the
-- startup check finds KOReader has changed in a way the plugin relies on.
function Virtual.install()
    if Virtual.installed then return Guard.ok("library") end
    Virtual.installed = true
    if not Guard.check() then
        logger.warn("Athenaeum: not installed:", Guard.statusText())
        return false
    end
    -- If a hook fails later: no more cloud books in the folder (ZenOS,
    -- told they're gone, redraws it).
    Guard.on_failure.library = function()
        local folder = Virtual.folder
        Virtual.setCatalog(folder, {})
        Virtual.forgetDecodedCovers()
    end
    -- Before the file browser lists the folder (plugins start first), so
    -- ZenOS's saved listing is used.
    if not ZenSource.install(Virtual) then
        logger.warn("Athenaeum: not installed:", Guard.statusText())
        return false
    end
    installListing()
    installBookInfo()
    installOpen()
    installSettingsGuard()
    installCloudShortcuts()
    logger.info("Athenaeum: installed,", #Virtual.books, "cloud books in", Virtual.folder)
    return true
end

return Virtual
