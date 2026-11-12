--[[--
Book data sync inside KOReader: reading a book's status, rating, review,
custom metadata, handmade table of contents and hidden flows, from the open
book or from a closed book's sidecar, and putting merged changes back. The
data side is concordance/bookstore.lua.

- The open book: its changes are recorded when it opens and closes, and
  before each sync; merged changes are applied when it opens and after a
  sync.
- Closed books: before each sync, sidecars that changed since they were
  last read (by size and time) are read again, so changes made in the file
  browser are sent. After a sync, merged changes to status, rating, review
  and custom metadata are written into them, the way KOReader's file
  browser does it. The handmade table of contents and hidden flows wait
  until the book is opened.
- A book whose settings were reset (KOReader's "Reset settings", or a
  missing sidecar) is looked at as if for the first time, so that doesn't
  clear anything on other devices; the merged values are put back instead.
--]]

local BookFormat = require("concordance/bookformat")
local Problems = require("concordance/problems")

local BookSync = {}
BookSync.__index = BookSync

BookSync.CHUNK = 25          -- books per UI tick when reading or writing sidecars
BookSync.RETRY_DELAY = 2     -- s between tries while the user is busy
BookSync.RETRY_TRIES = 90

--- deps: store (BookStore), getDeviceId(), now(), logger, schedule(delay, fn),
-- enabled(), ui_manager, and optionally readerUI(), docsettings, readhistory,
-- lfs, booklist, event, global_settings (G_reader_settings)
function BookSync.new(deps)
    local self = setmetatable({ deps = deps }, BookSync)
    self.log = deps.logger
    return self
end

function BookSync:_mod(dep, name)
    if self.deps[dep] then return self.deps[dep] end
    return require(name)
end
function BookSync:_DocSettings() return self:_mod("docsettings", "docsettings") end
function BookSync:_lfs() return self:_mod("lfs", "libs/libkoreader-lfs") end

function BookSync:_readerUI()
    if self.deps.readerUI then return self.deps.readerUI() end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

function BookSync:_broadcast(name, arg)
    local um = self.deps.ui_manager
    if not (um and um.broadcastEvent) then return end
    local Event = self:_mod("event", "ui/event")
    um:broadcastEvent(Event:new(name, arg))
end

function BookSync:_bookList()
    if self.deps.booklist then return self.deps.booklist end
    local ok, BookList = pcall(require, "ui/widget/booklist")
    return ok and BookList or nil
end

-- Reading values ---------------------------------------------------------------------

local function copyItems(items, kind)
    local out = {}
    for i, item in ipairs(items) do
        local c = {}
        for k, v in pairs(item) do
            -- In a reflowable book the page depends on the layout: recomputed.
            if type(k) == "string" and not (kind == "rolling" and k == "page") then c[k] = v end
        end
        out[i] = c
    end
    return out
end

--- A handmade list's kind, from its items ("rolling" has XPointers).
local function listKind(items)
    local first = type(items) == "table" and items[1]
    if type(first) ~= "table" then return nil end
    return first.xpointer ~= nil and "rolling" or "paging"
end

local function dateTime(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    -- KOReader keeps the day only. The start of it: a change another
    -- device timed to the second that day is the later one, as far as
    -- anyone can tell.
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 }
end

local function summaryValues(values, times, summary)
    summary = type(summary) == "table" and summary or {}
    values.status = BookFormat.STATUSES[summary.status] and summary.status or false
    values.rating = type(summary.rating) == "number" and summary.rating >= 1 and summary.rating <= 5
        and summary.rating or false
    values.note = type(summary.note) == "string" and summary.note ~= "" and summary.note or false
    local t = dateTime(summary.modified)
    if t then
        for _, prop in ipairs(BookFormat.SUMMARY_PROPS) do times[prop] = t end
    end
end

--- The custom metadata file of a book and its custom props (or nil).
function BookSync:_customMeta(path)
    local DocSettings = self:_DocSettings()
    local file = DocSettings.findCustomMetadataFile and DocSettings:findCustomMetadataFile(path)
    if not file then return nil end
    local cds = DocSettings.openSettingsFile(file)
    return file, cds, cds:readSetting("custom_props")
end

function BookSync:_metaValues(values, times, path)
    local file, _, custom = self:_customMeta(path)
    custom = type(custom) == "table" and custom or {}
    local t = file and self:_lfs().attributes(file, "modification")
    for _, k in ipairs(BookFormat.META_KEYS) do
        local v = custom[k]
        values["meta." .. k] = (type(v) == "string" or type(v) == "number") and v or false
        if t then times["meta." .. k] = t end
    end
end

local function handmadeValue(items, enabled, kind)
    if type(items) ~= "table" or #items == 0 then return false end
    return { enabled = enabled and true or false, items = copyItems(items, kind) }
end

--- The open book: { md5, path, kind, title, authors }, or nil and why.
function BookSync:bookOf(ui)
    if not (ui and ui.document and ui.doc_settings) then return nil, "no book open" end
    local md5 = ui.doc_settings:readSetting("partial_md5_checksum")
    if type(md5) ~= "string" or md5 == "" then return nil, "book has no MD5" end
    local props = ui.doc_props or {}
    return { md5 = md5, path = ui.document.file, kind = ui.rolling and "rolling" or ui.paging and "paging" or nil,
             title = props.display_title or props.title, authors = props.authors }
end

--- The open book's current values and their old times.
function BookSync:readOpen(ui, book)
    local values, times = {}, {}
    summaryValues(values, times, ui.doc_settings:readSetting("summary"))
    self:_metaValues(values, times, book.path)
    local hm = ui.handmade
    if hm and book.kind then
        values["toc." .. book.kind] = handmadeValue(hm.toc, hm.toc_enabled, book.kind)
        values["flows." .. book.kind] = handmadeValue(hm.flow_points, hm.flows_enabled, book.kind)
    end
    return values, times
end

--- A closed book's sidecar: { md5, title, authors }, values, times, fresh;
-- or nil when it has none or no MD5.
function BookSync:readClosed(path, ds)
    local DocSettings = self:_DocSettings()
    ds = ds or DocSettings:open(path)
    local md5 = ds:readSetting("partial_md5_checksum")
    if type(md5) ~= "string" or md5 == "" then return nil end
    local props = ds:readSetting("doc_props") or {}
    local values, times = {}, {}
    local summary = ds:readSetting("summary")
    summaryValues(values, times, summary)
    self:_metaValues(values, times, path)
    local toc = ds:readSetting("handmade_toc")
    local kind = listKind(toc)
    if kind then values["toc." .. kind] = handmadeValue(toc, ds:readSetting("handmade_toc_enabled") == true, kind) end
    local flows = ds:readSetting("handmade_flow_points")
    kind = listKind(flows)
    if kind then
        local enabled = ds:readSetting("handmade_flows_enabled")
        if enabled == nil then
            local gs = self.deps.global_settings or rawget(_G, "G_reader_settings")
            enabled = gs and gs:readSetting("handmade_flows_enabled") == true
        end
        values["flows." .. kind] = handmadeValue(flows, enabled, kind)
    end
    -- No status: a new or reset sidecar.
    local fresh = values.status == false or ds:readSetting("docsettings_reset_done") == true
    return { md5 = md5, title = props.display_title or props.title, authors = props.authors }, values, times, fresh, ds
end

--- The sidecar's and custom metadata file's size and time, or nil without a sidecar.
function BookSync:signature(path)
    local DocSettings = self:_DocSettings()
    local lfs = self:_lfs()
    local sidecar = DocSettings.findSidecarFile and DocSettings:findSidecarFile(path)
    if not sidecar then return nil end
    local function attrs(f)
        local a = f and lfs.attributes(f)
        return a and (tostring(a.size) .. "@" .. tostring(a.modification)) or "-"
    end
    local meta = DocSettings.findCustomMetadataFile and DocSettings:findCustomMetadataFile(path)
    return attrs(sidecar) .. "|" .. attrs(meta)
end

-- The open book -----------------------------------------------------------------------

--- KOReader read the book's settings (before it sets a missing status to
-- "reading" and clears its reset marker): note whether they were new or reset.
function BookSync:onReadSettings(ui, config)
    local summary = config and config:readSetting("summary")
    local status = type(summary) == "table" and summary.status
    self.loaded = { ui = ui, fresh = not BookFormat.STATUSES[status]
        or config:readSetting("docsettings_reset_done") == true }
end

--- Records the open book's changes. Returns the summary (see
-- BookStore:observe) and the book, or nil and why.
function BookSync:observe(ui)
    local book, why = self:bookOf(ui)
    if not book then return nil, why end
    local values, times = self:readOpen(ui, book)
    local fresh = self.loaded and self.loaded.ui == ui and self.loaded.fresh
    if fresh then
        -- KOReader filled in "reading": not the user's.
        values.status = false
    end
    local res = self.deps.store:observe{
        md5 = book.md5, values = values, times = times, fresh = fresh, now = self.deps.now(),
        device = self.deps.getDeviceId(), title = book.title, authors = book.authors, path = book.path,
    }
    if fresh then self.loaded.fresh = false end
    if res.skipped > 0 then self.log.warn("Concordance:", res.skipped, "book properties of", book.path, "can't be synced") end
    return res, book
end

function BookSync:_busy(ui)
    local um = self.deps.ui_manager
    if um and um.getTopmostVisibleWidget and um:getTopmostVisibleWidget() ~= (ui.dialog or ui) then return true end
    local hl = ui.highlight
    return hl ~= nil and (hl.selected_text ~= nil or hl.hold_pos ~= nil)
end

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

--- Puts summary ops (status, rating, note) into a summary table. Returns
-- whether it changed.
local function applySummary(summary, ops, now)
    local changed = false
    for _, op in ipairs(ops) do
        if op.prop == "status" then
            if op.value ~= nil then -- a status is never removed
                summary.status = op.value
                summary.modified = os.date("%Y-%m-%d", op.updated > 0 and op.updated or now)
                changed = true
            end
        elseif op.prop == "rating" or op.prop == "note" then
            summary[op.prop] = op.value
            changed = true
        end
    end
    return changed
end

--- Writes custom metadata ops into a book's custom metadata file, as
-- KOReader's book info does. ds: the book's settings (for the original
-- props, when there's no file yet). ui: the open book's, to update it too.
-- Returns whether anything was written.
function BookSync:_writeMeta(path, ds, ops, ui)
    local DocSettings = self:_DocSettings()
    local file, cds, custom = self:_customMeta(path)
    if not cds then
        local props = ds:readSetting("doc_props")
        if type(props) ~= "table" then props = ui and ui.doc_props end
        if type(props) ~= "table" then return false end -- no original props to keep
        local copy = deepcopy(props)
        copy.display_title = nil
        cds = DocSettings.openSettingsFile()
        cds:saveSetting("doc_props", copy)
    end
    custom = type(custom) == "table" and custom or {}
    for _, op in ipairs(ops) do custom[BookFormat.metaKey(op.prop)] = op.value end
    if next(custom) == nil then
        if file then
            os.remove(file)
            if DocSettings.removeSidecarDir then DocSettings.removeSidecarDir((file:gsub("/[^/]*$", ""))) end
        end
    else
        cds:saveSetting("custom_props", custom)
        cds:flushCustomMetadata(path)
    end
    if ui and ui.doc_props then
        local original = cds:readSetting("doc_props") or {}
        for _, op in ipairs(ops) do
            local key = BookFormat.metaKey(op.prop)
            ui.doc_props[key] = op.value or original[key]
            if key == "title" then
                ui.doc_props.display_title = ui.doc_props.title or (path:match("([^/]+)%.[^./]*$") or path)
            end
        end
        if ui.doc_settings.getCustomMetadataFile then
            ui.doc_settings:getCustomMetadataFile(true)
        else
            Problems.report("book:getCustomMetadataFile", "Book details received may not show until the book is reopened: KOReader has changed",
                "DocSettings:getCustomMetadataFile is missing")
        end
    end
    self:_broadcast("InvalidateMetadataCache", path)
    return true
end

--- Puts the handmade TOC or hidden flows ops into the open book.
function BookSync:_applyHandmade(ui, ops)
    local hm = ui.handmade
    if not hm then
        Problems.report("book:handmade-missing", "Handmade tables of contents aren't applied: KOReader has changed",
            "ReaderUI.handmade is missing")
        return false
    end
    local toc, flows = false, false
    for _, op in ipairs(ops) do
        local what = op.prop:match("^(%a+)%.")
        local v = op.value
        if what == "toc" then
            hm.toc = v and deepcopy(v.items or {}) or {}
            hm.toc_enabled = v and v.enabled or false
            toc = true
        elseif what == "flows" then
            hm.flow_points = v and deepcopy(v.items or {}) or {}
            if v then hm.flows_enabled = v.enabled end
            flows = true
        end
    end
    if not (toc or flows) then return false end
    -- What KOReader does once the book is ready.
    local ok, err = pcall(function()
        for _i, name in ipairs({ "updateHandmagePages", "setupFlows", "setupToc" }) do
            if type(hm[name]) ~= "function" then
                Problems.report("book:handmade-" .. name, "A handmade table of contents received may not show until the book is reopened: KOReader has changed",
                    "ReaderHandMade:" .. name .. " is missing")
            end
        end
        if hm.updateHandmagePages then hm:updateHandmagePages() end
        if hm.setupFlows then hm:setupFlows(true) end
        if hm.setupToc then hm:setupToc(true) end
        if ui.handleEvent then
            local Event = self:_mod("event", "ui/event")
            ui:handleEvent(Event:new("UpdateToc"))
            if flows then ui:handleEvent(Event:new("InitScrollPageStates")) end
        end
        if flows and ui.annotation then
            if ui.annotation.setNeedsUpdateFlag then
                ui.annotation:setNeedsUpdateFlag()
            else
                Problems.report("book:setNeedsUpdateFlag", "Hidden flows received may show wrong page numbers in highlights until the book is reopened: KOReader has changed",
                    "ReaderAnnotation:setNeedsUpdateFlag is missing")
            end
        end
        if ui.view and ui.view.footer then
            if ui.view.footer.maybeUpdateFooter then
                ui.view.footer:maybeUpdateFooter()
            else
                Problems.report("book:maybeUpdateFooter", "The status bar may not update after a handmade table of contents is received: KOReader has changed",
                    "ReaderFooter:maybeUpdateFooter is missing")
            end
        end
    end)
    if not ok then
        self.log.warn("Concordance: updating the handmade table of contents failed:", err)
        Problems.report("book:handmade", "Updating the open book's handmade table of contents failed", err)
    end
    return true
end

--- Brings the open book in line with the merged state. Call observe()
-- first. Unless `force`, does nothing while the user is busy. Returns the
-- number of changes made, or nil and why.
function BookSync:apply(ui, force)
    local book, why = self:bookOf(ui)
    if not book then return nil, why end
    if not force and self:_busy(ui) then return nil, "busy" end
    local store = self.deps.store
    local values = self:readOpen(ui, book)
    local ops = store:plan(book.md5, values)
    if #ops == 0 then return 0 end
    local summary_ops, meta_ops, hm_ops = {}, {}, {}
    for _, op in ipairs(ops) do
        if BookFormat.metaKey(op.prop) then table.insert(meta_ops, op)
        elseif op.prop:match("^toc%.") or op.prop:match("^flows%.") then table.insert(hm_ops, op)
        else table.insert(summary_ops, op) end
    end
    if #summary_ops > 0 then
        local summary = ui.doc_settings:readSetting("summary")
        if type(summary) ~= "table" then
            summary = {}
            ui.doc_settings:saveSetting("summary", summary)
        end
        applySummary(summary, summary_ops, self.deps.now())
        local BookList = self:_bookList()
        if BookList and BookList.setBookInfoCacheProperty then
            BookList.setBookInfoCacheProperty(book.path, "status", summary.status)
            BookList.setBookInfoCacheProperty(book.path, "rating", summary.rating)
        end
    end
    if #meta_ops > 0 then self:_writeMeta(book.path, ui.doc_settings, meta_ops, ui) end
    if #hm_ops > 0 and self:_applyHandmade(ui, hm_ops) then
        local um = self.deps.ui_manager
        if um and um.setDirty then um:setDirty(ui.dialog or ui, "ui") end
    end
    if #meta_ops > 0 or #summary_ops > 0 then self:_broadcast("BookMetadataChanged") end
    store:applied(book.md5, (self:readOpen(ui, book)))
    self.log.info("Concordance: applied", #ops, "book data changes to", book.path)
    return #ops
end

-- Closed books --------------------------------------------------------------------------

--- Reads a closed book's sidecar and records its changes. Returns the
-- book, values, settings, or nil.
function BookSync:_observeClosed(path, sig)
    local book, values, times, fresh, ds = self:readClosed(path)
    if not book then return nil end
    self.deps.store:observe{
        md5 = book.md5, values = values, times = times, fresh = fresh, now = self.deps.now(),
        device = self.deps.getDeviceId(), title = book.title, authors = book.authors, path = path, sig = sig,
    }
    return book, values, ds
end

--- Writes the merged status, rating, review and custom metadata into a
-- closed book. Returns the number of changes written.
function BookSync:writeClosed(path)
    local store = self.deps.store
    local book, values, ds = self:_observeClosed(path, self:signature(path))
    if not book then return 0 end
    local closed = {}
    for prop, v in pairs(values) do
        if BookFormat.CLOSED_PROPS[prop] then closed[prop] = v end
    end
    local ops = store:plan(book.md5, closed)
    local summary_ops, meta_ops = {}, {}
    for _, op in ipairs(ops) do
        table.insert(BookFormat.metaKey(op.prop) and meta_ops or summary_ops, op)
    end
    local n = 0
    if #summary_ops > 0 then
        local summary = ds:readSetting("summary")
        summary = type(summary) == "table" and summary or {}
        if applySummary(summary, summary_ops, self.deps.now()) then
            ds:saveSetting("summary", summary)
            ds:flush()
            n = n + #summary_ops
        end
    end
    if #meta_ops > 0 and self:_writeMeta(path, ds, meta_ops) then n = n + #meta_ops end
    if n > 0 then
        local BookList = self:_bookList()
        if BookList and BookList.resetBookInfoCache then BookList.resetBookInfoCache(path) end
        self.log.info("Concordance: wrote", n, "book data changes into", path)
    end
    -- What's there now (a value that couldn't be written stays to do).
    local book2, values2 = self:readClosed(path)
    if book2 then store:applied(book2.md5, values2, path, self:signature(path)) end
    return n
end

--- Runs fn(path, known) for each book file, a chunk per UI tick, then done().
function BookSync:_eachFile(paths, fn, done)
    local i = 0
    local function step()
        for _ = 1, BookSync.CHUNK do
            i = i + 1
            local p = paths[i]
            if not p then
                if done then done() end
                return
            end
            local ok, err = pcall(fn, p)
            if not ok then
                self.log.warn("Concordance: book data of", p, "failed:", err)
                Problems.report("book:write", "Writing book status and details into a book that isn't open failed", err)
            end
        end
        self.deps.schedule(0, step)
    end
    self.deps.schedule(0, step)
end

--- Reads again the sidecars of books in the reading history (and books
-- seen before) that changed since they were last read, and records their
-- changes. done(stats) when finished. Returns false if already running.
function BookSync:refresh(done)
    if self.refreshing then return false end
    self.refreshing = true
    local store = self.deps.store
    local lfs = self:_lfs()
    local known = store:files()
    local hist = (self.deps.readhistory or require("readhistory")).hist or {}
    local paths, listed = {}, {}
    for _, h in ipairs(hist) do
        if type(h.file) == "string" and not listed[h.file] then
            listed[h.file] = true
            paths[#paths + 1] = h.file
        end
    end
    for p in pairs(known) do
        if not listed[p] then paths[#paths + 1] = p end
    end
    local ui = self:_readerUI()
    local open_file = ui and ui.document and ui.document.file
    local stats = { read = 0, gone = 0 }
    self:_eachFile(paths, function(path)
        if path == open_file then return end
        if lfs.attributes(path, "mode") ~= "file" then
            if known[path] then
                store:forgetFile(path)
                stats.gone = stats.gone + 1
            end
            return
        end
        local sig = self:signature(path)
        if not sig or (known[path] and known[path].sig == sig) then return end
        if self:_observeClosed(path, sig) then stats.read = stats.read + 1 end
    end, function()
        self.refreshing = false
        self.log.dbg("Concordance: book data: read", stats.read, "changed sidecars,", stats.gone, "books gone")
        if done then done(stats) end
    end)
    return true
end

--- Writes merged changes into every closed book that needs them. done(n).
function BookSync:writeAll(done)
    if self.writing then return false end
    self.writing = true
    local ui = self:_readerUI()
    local open_file = ui and ui.document and ui.document.file
    local lfs = self:_lfs()
    local DocSettings = self:_DocSettings()
    local list = self.deps.store:toWrite()
    local paths = {}
    for _, w in ipairs(list) do
        if w.path ~= open_file then paths[#paths + 1] = w.path end
    end
    local total = 0
    self:_eachFile(paths, function(path)
        if lfs.attributes(path, "mode") ~= "file" then
            self.deps.store:forgetFile(path)
        elseif DocSettings:hasSidecarFile(path) then
            total = total + self:writeClosed(path)
        end
    end, function()
        self.writing = false
        if total > 0 then self:_broadcast("BookMetadataChanged") end
        if done then done(total) end
    end)
    return true
end

-- Hooks -------------------------------------------------------------------------------

--- A book was opened (after KOReader has finished loading it).
function BookSync:onReaderReady(ui)
    if not self.deps.enabled() then return end
    local ok, err = pcall(function()
        local res, why = self:observe(ui)
        if not res then
            self.log.dbg("Concordance: book data not synced for this book:", why)
            return
        end
        self:apply(ui, true)
    end)
    if not ok then
        self.log.warn("Concordance: book data on open failed:", err)
        Problems.report("book:open", "Bringing an opened book's status and details up to date failed", err)
    end
end

--- The book is closing (KOReader has saved its settings).
function BookSync:onClose(ui)
    if not self.deps.enabled() then return end
    local ok, err = pcall(self.observe, self, ui)
    if not ok then
        self.log.warn("Concordance: recording book data on close failed:", err)
        Problems.report("book:close", "Recording a book's status and details on closing failed", err)
    end
    if self.loaded and self.loaded.ui == ui then self.loaded = nil end
end

--- Before a sync: the open book's changes.
function BookSync:collect()
    local ui = self:_readerUI()
    if ui and ui.document then self:observe(ui) end
end

--- After a sync: apply what came in to the open book, then write closed books.
function BookSync:afterSync(run)
    local ui = self:_readerUI()
    local book = ui and self:bookOf(ui)
    if book and (not run or not run.book_affected or run.book_affected[book.md5]) then
        self:observe(ui)
        local n, why = self:apply(ui)
        if not n and why == "busy" then self:_applyLater(0) end
    end
    self:writeAll()
end

function BookSync:_applyLater(tries)
    if self.retrying and tries == 0 then return end
    self.retrying = true
    self.deps.schedule(BookSync.RETRY_DELAY, function()
        local ui = self:_readerUI()
        if not (ui and self:bookOf(ui)) or not self.deps.enabled() then
            self.retrying = false
            return
        end
        local ok, n, why = pcall(function()
            self:observe(ui)
            return self:apply(ui)
        end)
        if ok and not n and why == "busy" and tries + 1 < BookSync.RETRY_TRIES then
            return self:_applyLater(tries + 1)
        end
        if not ok then
            self.log.warn("Concordance: applying book data failed:", n)
            Problems.report("book:apply", "Applying book status and details failed", n)
        end
        self.retrying = false
    end)
end

return BookSync
