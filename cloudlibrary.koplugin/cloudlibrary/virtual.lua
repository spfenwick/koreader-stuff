--[[
Virtual entries: books in the cloud library that aren't on the device are
listed in the library folder as files that don't exist. Their metadata and
covers come from the catalog cache instead of the file.

Everything here changes KOReader and CoverBrowser functions only:
  FileChooser:getList              adds the entries to the library folder
  BookInfoManager:getBookInfo      metadata and cover for a virtual path
  BookInfoManager:getDocProps      metadata for sorting and book info
  BookInfoManager:extractInBackground / :isExtractingInBackground
                                   covers not downloaded yet are fetched when
                                   CoverBrowser (or ZenOS) asks to extract
                                   them, and it redraws them as they arrive
  FileChooser:onMenuSelect         tapping a virtual book shows its details
  FileChooser:onMenuHold           long-press on a virtual book
  ReaderUI:showReader / :switchDocument
                                   any other route that opens a virtual book
  DocSettings:flush, :flushCustomCover, :flushCustomMetadata
                                   never write book settings for a virtual
                                   book (ZenOS marks a book "reading" as
                                   soon as it's opened, for example)

Optional ZenOS dependencies:
  ZenOS shows an "Opening" banner as soon as a book is tapped and removes it
  only when a reader opens. If its __ZEN_UI_CANCEL_OPENING_BANNER function
  exists, it's called when the details are shown instead.
  Where ZenOS has book sources (zenos_source.lua), the cloud books are one:
  ZenOS then answers getBookInfo for them inside its own cover caches, and
  keys its cached listings on Virtual.listingKey() instead of the folder's
  timestamp.
]]

local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Timing = require("cloudlibrary/timing")
local Guard = require("cloudlibrary/guard")
local ZenSource = require("cloudlibrary/zenos_source")

local Virtual = {
    folder = nil, -- library folder, no trailing slash
    books = {},
    by_path = {},
    installed = false,
    has_bookinfo = false,
    generation = 0, -- changes with every setCatalog()
    catalog_sig = "", -- the books listed and what their list items show
    listingExtra = nil, -- function() -> string: other settings list items show
}

local PREFIX = "cloud-"

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
        parts[i + 1] = table.concat({ b.id, b.title or "",
            type(b.authors) == "table" and table.concat(b.authors, "\31") or "",
            b.series or "", tostring(b.series_index or "") }, "\t")
    end
    return require("ffi/sha2").md5(table.concat(parts, "\n"))
end

function Virtual.setCatalog(folder, books)
    local old = Virtual.books
    Virtual.folder = normalize(folder)
    Virtual.books, Virtual.by_path = {}, {}
    Virtual.generation = Virtual.generation + 1
    -- Turned off (startup check or an error): no cloud books.
    if not Virtual.folder or not Guard.ok("library") then
        Virtual.catalog_sig = signature(Virtual.folder, {})
        Virtual.notifyChanged(old)
        return
    end
    for _i, book in ipairs(books or {}) do
        local path = type(book.id) == "string" and book.id ~= ""
            and Virtual.folder .. "/" .. PREFIX .. book.id .. ".epub"
        -- One entry per catalog book, however often the catalog lists it.
        if path and not Virtual.by_path[path] then
            book.path = path
            book.filename = (book.title or book.id) .. ".epub"
            table.insert(Virtual.books, book)
            Virtual.by_path[book.path] = book
        end
    end
    Virtual.catalog_sig = signature(Virtual.folder, Virtual.books)
    Virtual.notifyChanged(old)
end

--- Tells ZenOS the cloud books changed: groupings are rebuilt, and its
-- cached covers and metadata for these books (and the current ones)
-- dropped. A refetched cover keeps its file name.
function Virtual.notifyChanged(old_books)
    if not ZenSource.registered then return end
    local paths = {}
    for _i, list in ipairs({ old_books or {}, Virtual.books }) do
        for _j, book in ipairs(list) do paths[#paths + 1] = book.path end
    end
    ZenSource.changed(paths)
end

--- Key for cached listings that show the cloud books (ZenOS's book
-- sources): changes with the books and how their items are drawn, and is
-- the same after a restart.
function Virtual.listingKey()
    local extra = Virtual.listingExtra and Virtual.listingExtra() or ""
    return Virtual.catalog_sig .. "/" .. extra
end

-- Call after the catalog changes. File browsers (ZenOS's included) cache a
-- folder's listing until the folder's timestamp changes, so update it; the
-- new timestamp is on disk, so cached listings saved before a restart are
-- also seen as stale. Timestamps on FAT have a 2 s resolution, hence +2.
-- Not needed where ZenOS keys its listings on Virtual.listingKey().
function Virtual.refresh()
    if not Virtual.folder then return end
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(Virtual.folder)
    if not ZenSource.listing and type(attr) == "table" and attr.mode == "directory" then
        local stamp = math.max(os.time(), (attr.modification or 0) + 2)
        local ok, err = lfs.touch(Virtual.folder, stamp, stamp)
        if not ok then logger.warn("CloudLibrary: can't update folder timestamp", err) end
    end
    local FileManager = require("apps/filemanager/filemanager")
    local fc = FileManager.instance and FileManager.instance.file_chooser
    if fc and normalize(fc.path) == Virtual.folder then fc:refreshPath() end
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
            logger.warn("CloudLibrary: can't decode cover", book.cover, res)
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
-- it through extractInBackground(), and redraws the book when it's ready.
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

function Virtual.showDetails(path)
    local book = Virtual.by_path[path]
    if not book then return end
    cancelZenOSOpeningBanner()
    rawset(_G, "__CLOUDLIBRARY_LAST_DETAILS", path)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    -- Full record (summary, formats...) from the catalog, when available.
    local full = Virtual.details and Virtual.details(book.id) or book
    local lines = { full.title or book.title or book.id }
    if full.authors and #full.authors > 0 then table.insert(lines, table.concat(full.authors, ", ")) end
    if full.series then
        table.insert(lines, full.series_index
            and string.format("%s #%s", full.series, tostring(full.series_index)) or full.series)
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
    if #facts > 0 then table.insert(lines, table.concat(facts, " · ")) end
    if full.summary then
        local summary = full.summary:gsub("%s+", " ")
        if #summary > 400 then
            summary = summary:sub(1, 400):gsub("[\128-\191]*$", ""):gsub("%s*%S*$", "") .. "…"
        end
        table.insert(lines, "")
        table.insert(lines, summary)
    end
    table.insert(lines, "")
    table.insert(lines, _("In your cloud library, not on this device."))
    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = Virtual.detailsButtons and Virtual.detailsButtons(book.id, full, close)
        or {{ { text = _("Close"), callback = close } }}
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- A file browser item for a virtual book (as in the library folder).
-- Optional: decorate(item) adjusts a listed item (the badge reserves room
-- for itself in plain list rows).
Virtual.decorate = nil

local function decorate(item)
    if Virtual.decorate and type(item) == "table" then Virtual.decorate(item) end
    return item
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

function Virtual.listItem(fc, book, collate)
    local dir = book.path:match("^(.*)/[^/]*$")
    return decorate(withProps(fc:getListItem(dir, book.filename, book.path, attributes(book), collate), book))
end

local function installListing()
    local FileChooser = require("ui/widget/filechooser")
    Guard.hook("library", FileChooser, "getList", function(orig, self, path, collate)
        local dirs, files, readable = orig(self, path, collate)
        if self.name == "filemanager" and Virtual.folder
                and normalize(path) == Virtual.folder then
            Virtual.ensureOutermost()
            require("cloudlibrary/zenos_listing").install(function() return Virtual.folder end)
            ZenSource.install(Virtual)
            require("cloudlibrary/zenos_groups").install(Virtual)
            local t0 = Timing.start()
            for _i, book in ipairs(Virtual.books) do
                if collate then
                    table.insert(files, withProps(self:getListItem(path, book.filename,
                        book.path, attributes(book), collate), book))
                else -- counting only, like FileChooser:getPathList()
                    table.insert(files, true)
                end
            end
            if collate then
                for _i, item in ipairs(files) do decorate(item) end
                Timing.record("listing: add cloud books", Timing.since(t0), #Virtual.books .. " books")
            end
        end
        return dirs, files, readable
    end, "FileChooser:getList")
end

-- The getBookInfo hook stays the outermost one: other plugins (ZenOS) wrap
-- it with caches of their own, which would keep "cover not fetched yet"
-- after the cover arrives. Virtual books are answered here directly; this is
-- re-checked whenever the library folder is listed. Where ZenOS answers
-- for the cloud books itself (book sources) and drops its cached entries
-- when told, the hook stays where it is (inside ZenOS's, answering only
-- if ZenOS doesn't).
local BookInfoManager
local our_getBookInfo

local function wrapBookInfo()
    our_getBookInfo = Guard.hook("library", BookInfoManager, "getBookInfo",
        function(orig, self, filepath, get_cover)
            local book = Virtual.by_path[filepath]
            if book then return bookInfo(book, get_cover) end
            return orig(self, filepath, get_cover)
        end, "BookInfoManager:getBookInfo")
    if type(BookInfoManager.getDocProps) == "function" then
        Guard.hook("library", BookInfoManager, "getDocProps", function(orig, self, filepath)
            local book = Virtual.by_path[filepath]
            if book then return docProps(book) end
            return orig(self, filepath)
        end, "BookInfoManager:getDocProps")
    end
end

function Virtual.ensureOutermost()
    if ZenSource.book_info then return end
    if BookInfoManager and BookInfoManager.getBookInfo ~= our_getBookInfo then
        wrapBookInfo()
    end
end

-- Times building the library folder's listing (when it's built: file
-- browsers that cache listings, like ZenOS, skip this when they can).
local function installListingTimer()
    local FileChooser = require("ui/widget/filechooser")
    Guard.hook("library", FileChooser, "genItemTableFromPath", function(orig, self, path, ...)
        if not (Virtual.folder and self.name == "filemanager" and normalize(path) == Virtual.folder) then
            return orig(self, path, ...)
        end
        local t0 = Timing.start()
        local results = Timing.pack(orig(self, path, ...))
        Timing.record("listing: build library folder", Timing.since(t0),
            #(results[1] or {}) .. " entries, sorted")
        return unpack(results, 1, results.n)
    end, "FileChooser:genItemTableFromPath")
end

local function installBookInfo()
    local ok, bim = pcall(require, "bookinfomanager")
    if not ok or type(bim) ~= "table" or type(bim.getBookInfo) ~= "function" then
        logger.warn("CloudLibrary: CoverBrowser unavailable, no covers for cloud books")
        return false
    end
    BookInfoManager = bim
    wrapBookInfo()
    -- Virtual books are never extracted from a file: their covers are
    -- downloaded instead.
    Guard.hook("library", BookInfoManager, "extractInBackground", function(orig, self, files, ...)
        if type(files) ~= "table" then return orig(self, files, ...) end
        local real, wanted = {}, {}
        for _i, file in ipairs(files) do
            local filepath = type(file) == "table" and file.filepath or file
            local book = Virtual.by_path[filepath]
            if book then table.insert(wanted, book) else table.insert(real, file) end
        end
        if #wanted == 0 then return orig(self, files, ...) end
        if not (Virtual.requestCovers and Virtual.requestCovers(wanted)) then
            -- Can't download now (Wi-Fi went off): show them without a
            -- cover for now instead of waiting.
            for _i, book in ipairs(wanted) do book.cover_retry_at = os.time() + 120 end
            local paths = {}
            for i, book in ipairs(wanted) do paths[i] = book.path end
            ZenSource.changed(paths)
        end
        if #real > 0 then return orig(self, real, ...) end
        -- Report success even when nothing was started: CoverBrowser
        -- shows an error otherwise. It stops waiting once
        -- isExtractingInBackground() is false.
        return true
    end, "BookInfoManager:extractInBackground")
    Guard.hook("library", BookInfoManager, "isExtractingInBackground", function(orig, self, ...)
        return orig(self, ...) or (Virtual.coversBusy and Virtual.coversBusy()) or false
    end, "BookInfoManager:isExtractingInBackground")
    return true
end

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

local function isVirtualItem(chooser, item)
    return chooser.name == "filemanager" and type(item) == "table"
        and Virtual.by_path[item.path] ~= nil
        and not (chooser.ui and chooser.ui.selected_files)
end

-- Taps are caught here, before KOReader's open path starts: ZenOS wraps
-- filemanagerutil.openFile to mark the book as being read. Long-press: the
-- file browser's own menu (and ZenOS's) offers rename, delete, edit
-- metadata, read status..., which would act on a file that doesn't exist;
-- show the book's details instead.
local function installSelectAndHold()
    local FileChooser = require("ui/widget/filechooser")
    for _i, name in ipairs({ "onMenuSelect", "onMenuHold" }) do
        Guard.hook("library", FileChooser, name, function(orig, self, item, ...)
            if isVirtualItem(self, item) then
                Virtual.showDetails(item.path)
                return true
            end
            return orig(self, item, ...)
        end, "FileChooser:" .. name)
    end
end

local function installSettingsGuard()
    local DocSettings = require("docsettings")
    Guard.hook("library", DocSettings, "flush", function(orig, self, data, ...)
        local doc_path = type(data) == "table" and data.doc_path
            or type(self.data) == "table" and self.data.doc_path
        if Virtual.by_path[doc_path] then
            logger.dbg("CloudLibrary: not writing settings for", doc_path)
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

--- Installs the hooks. Returns false (and installs nothing) when the
-- startup check finds KOReader has changed in a way the plugin relies on.
function Virtual.install()
    if Virtual.installed then return Guard.ok("library") end
    Virtual.installed = true
    if not Guard.check() then
        logger.warn("CloudLibrary: not installed:", Guard.statusText())
        return false
    end
    -- If a hook fails later: no more cloud books in the folder.
    Guard.on_failure.library = function()
        local folder = Virtual.folder
        Virtual.setCatalog(folder, {})
        Virtual.forgetDecodedCovers()
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() pcall(Virtual.refresh) end)
    end
    -- Before the getBookInfo hook, and before the file browser lists the
    -- folder (plugins start first), so ZenOS's saved listing is used.
    ZenSource.install(Virtual)
    installListing()
    installListingTimer()
    Virtual.has_bookinfo = installBookInfo()
    installSelectAndHold()
    installOpen()
    installSettingsGuard()
    logger.info("CloudLibrary: installed,", #Virtual.books, "cloud books in", Virtual.folder)
    return true
end

return Virtual
