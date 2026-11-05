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

The one optional ZenOS dependency: ZenOS shows an "Opening" banner as soon
as a book is tapped and removes it only when a reader opens. If its
__ZEN_UI_CANCEL_OPENING_BANNER function exists, it's called when the
details are shown instead. Without it, nothing else changes.
]]

local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Timing = require("cloudlibrary/timing")

local Virtual = {
    folder = nil, -- library folder, no trailing slash
    books = {},
    by_path = {},
    installed = false,
    has_bookinfo = false,
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

function Virtual.setCatalog(folder, books)
    Virtual.folder = normalize(folder)
    Virtual.books, Virtual.by_path = {}, {}
    if not Virtual.folder then return end
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
end

-- Call after the catalog changes. File browsers (ZenOS's included) cache a
-- folder's listing until the folder's timestamp changes, so update it; the
-- new timestamp is on disk, so cached listings saved before a restart are
-- also seen as stale. Timestamps on FAT have a 2 s resolution, hence +2.
function Virtual.refresh()
    if not Virtual.folder then return end
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(Virtual.folder)
    if type(attr) == "table" and attr.mode == "directory" then
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
    if book.cover_href and not book.cover_failed and not book.cover_offline and not book.cover
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

local function installListing()
    local FileChooser = require("ui/widget/filechooser")
    local orig_getList = FileChooser.getList
    FileChooser.getList = function(self, path, collate)
        local dirs, files, readable = orig_getList(self, path, collate)
        if self.name == "filemanager" and Virtual.folder
                and normalize(path) == Virtual.folder then
            Virtual.ensureOutermost()
            local t0 = Timing.start()
            for _i, book in ipairs(Virtual.books) do
                if collate then
                    table.insert(files, self:getListItem(path, book.filename,
                        book.path, attributes(book), collate))
                else -- counting only, like FileChooser:getPathList()
                    table.insert(files, true)
                end
            end
            if collate then
                Timing.record("listing: add cloud books", Timing.since(t0), #Virtual.books .. " books")
            end
        end
        return dirs, files, readable
    end
end

-- The getBookInfo hook stays the outermost one: other plugins (ZenOS) wrap
-- it with caches of their own, which would keep "cover not fetched yet"
-- after the cover arrives. Virtual books are answered here directly; this is
-- re-checked whenever the library folder is listed.
local BookInfoManager
local our_getBookInfo, our_getDocProps

local function wrapBookInfo()
    local inner = BookInfoManager.getBookInfo
    our_getBookInfo = function(self, filepath, get_cover)
        local book = Virtual.by_path[filepath]
        if book then return bookInfo(book, get_cover) end
        return inner(self, filepath, get_cover)
    end
    BookInfoManager.getBookInfo = our_getBookInfo
    if type(BookInfoManager.getDocProps) == "function" then
        local inner_props = BookInfoManager.getDocProps
        our_getDocProps = function(self, filepath)
            local book = Virtual.by_path[filepath]
            if book then return docProps(book) end
            return inner_props(self, filepath)
        end
        BookInfoManager.getDocProps = our_getDocProps
    end
end

function Virtual.ensureOutermost()
    if BookInfoManager and BookInfoManager.getBookInfo ~= our_getBookInfo then
        wrapBookInfo()
    end
end

-- Times building the library folder's listing (when it's built: file
-- browsers that cache listings, like ZenOS, skip this when they can).
local function installListingTimer()
    local FileChooser = require("ui/widget/filechooser")
    local orig = FileChooser.genItemTableFromPath
    FileChooser.genItemTableFromPath = function(self, path, ...)
        if not (Virtual.folder and self.name == "filemanager" and normalize(path) == Virtual.folder) then
            return orig(self, path, ...)
        end
        local t0 = Timing.start()
        local results = { orig(self, path, ...) }
        Timing.record("listing: build library folder", Timing.since(t0),
            #(results[1] or {}) .. " entries, sorted")
        return unpack(results)
    end
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
    if type(BookInfoManager.extractInBackground) == "function" then
        local orig_extract = BookInfoManager.extractInBackground
        BookInfoManager.extractInBackground = function(self, files, ...)
            if type(files) ~= "table" then return orig_extract(self, files, ...) end
            local real, wanted = {}, {}
            for _i, file in ipairs(files) do
                local filepath = type(file) == "table" and file.filepath or file
                local book = Virtual.by_path[filepath]
                if book then table.insert(wanted, book) else table.insert(real, file) end
            end
            if #wanted > 0 and not (Virtual.requestCovers and Virtual.requestCovers(wanted)) then
                -- Can't download now (Wi-Fi went off): show them without a
                -- cover for this session instead of waiting.
                for _i, book in ipairs(wanted) do book.cover_offline = true end
            end
            if #real > 0 then return orig_extract(self, real, ...) end
            -- Report success even when nothing was started: CoverBrowser
            -- shows an error otherwise. It stops waiting once
            -- isExtractingInBackground() is false.
            return true
        end
    end
    if type(BookInfoManager.isExtractingInBackground) == "function" then
        local orig_busy = BookInfoManager.isExtractingInBackground
        BookInfoManager.isExtractingInBackground = function(self, ...)
            return orig_busy(self, ...) or (Virtual.coversBusy and Virtual.coversBusy()) or false
        end
    end
    return true
end

local function installOpen()
    local ReaderUI = require("apps/reader/readerui")
    local orig_showReader = ReaderUI.showReader
    ReaderUI.showReader = function(self, file, ...)
        if Virtual.by_path[file] then
            Virtual.showDetails(file)
            return
        end
        return orig_showReader(self, file, ...)
    end
    local orig_switchDocument = ReaderUI.switchDocument
    if type(orig_switchDocument) == "function" then
        ReaderUI.switchDocument = function(self, file, ...)
            if Virtual.by_path[file] then
                Virtual.showDetails(file)
                return
            end
            return orig_switchDocument(self, file, ...)
        end
    end
end

-- Long-press on a virtual book: the file browser's own menu (and ZenOS's)
-- offers actions like rename, delete, edit metadata and read status, which
-- would act on a file that doesn't exist. Show the book's details instead.
-- Taps are caught here, before KOReader's open path starts: ZenOS wraps
-- filemanagerutil.openFile to mark the book as being read.
local function installSelect()
    local FileChooser = require("ui/widget/filechooser")
    local orig_onMenuSelect = FileChooser.onMenuSelect
    FileChooser.onMenuSelect = function(self, item, ...)
        if self.name == "filemanager" and type(item) == "table"
                and Virtual.by_path[item.path]
                and not (self.ui and self.ui.selected_files) then
            Virtual.showDetails(item.path)
            return true
        end
        return orig_onMenuSelect(self, item, ...)
    end
end

local function installSettingsGuard()
    local DocSettings = require("docsettings")
    local orig_flush = DocSettings.flush
    DocSettings.flush = function(self, data, ...)
        local doc_path = type(data) == "table" and data.doc_path
            or type(self.data) == "table" and self.data.doc_path
        if Virtual.by_path[doc_path] then
            logger.dbg("CloudLibrary: not writing settings for", doc_path)
            return
        end
        return orig_flush(self, data, ...)
    end
    for _i, name in ipairs({ "flushCustomCover", "flushCustomMetadata" }) do
        local orig = DocSettings[name]
        if type(orig) == "function" then
            DocSettings[name] = function(self, doc_path, ...)
                if Virtual.by_path[doc_path] then return end
                return orig(self, doc_path, ...)
            end
        end
    end
end

local function installHold()
    local FileChooser = require("ui/widget/filechooser")
    local orig_onMenuHold = FileChooser.onMenuHold
    FileChooser.onMenuHold = function(self, item, ...)
        if self.name == "filemanager" and type(item) == "table"
                and Virtual.by_path[item.path]
                and not (self.ui and self.ui.selected_files) then
            Virtual.showDetails(item.path)
            return true
        end
        return orig_onMenuHold(self, item, ...)
    end
end

function Virtual.install()
    if Virtual.installed then return end
    Virtual.installed = true
    installListing()
    installListingTimer()
    Virtual.has_bookinfo = installBookInfo()
    installSelect()
    installHold()
    installOpen()
    installSettingsGuard()
    logger.info("CloudLibrary: installed,", #Virtual.books, "cloud books in", Virtual.folder)
end

return Virtual
