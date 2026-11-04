--[[--
Annotation sync inside KOReader: reading the open book's annotations,
applying merged changes to it, scanning the reading history, and asking the
user about held deletions. The data side is supersync/annstore.lua.

Changes reach a book only while it's open: live for the open book after a
sync, otherwise when it's next opened. Sidecars of closed books are only
read (by the history scan), never written.
--]]

local AnnFormat = require("supersync/annformat")

local AnnSync = {}
AnnSync.__index = AnnSync

--- First CREngine DOM version with normalised XPointers; books on an older
-- one are left out (their XPointers don't transfer).
AnnSync.MIN_DOM_VERSION = 20200223
AnnSync.SCAN_CHUNK = 20

--- deps: store (AnnStore), getDeviceId(), now(), logger, schedule(delay, fn),
-- enabled(), ui_manager (UIManager), and optionally readerUI() (the open
-- ReaderUI or nil), event (ui/event), docsettings, readhistory, lfs,
-- confirm(opts) (shows the held-deletion question), saveScanned(time)
function AnnSync.new(deps)
    local self = setmetatable({ deps = deps }, AnnSync)
    self.log = deps.logger
    return self
end

function AnnSync:_readerUI()
    if self.deps.readerUI then return self.deps.readerUI() end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

--- The open book's identity: { md5, kind, title, authors, path }, or nil and why.
function AnnSync:bookOf(ui)
    if not (ui and ui.document and ui.annotation and type(ui.annotation.annotations) == "table") then
        return nil, "no book with annotations open"
    end
    local ds = ui.doc_settings
    local md5 = ds and ds:readSetting("partial_md5_checksum")
    if type(md5) ~= "string" or md5 == "" then return nil, "book has no MD5" end
    local kind = ui.rolling and "rolling" or ui.paging and "paging"
    if not kind then return nil, "unknown document type" end
    if kind == "rolling" then
        local dom = ds:readSetting("cre_dom_version")
        if type(dom) == "number" and dom < AnnSync.MIN_DOM_VERSION then
            return nil, "book uses an old rendering (DOM version " .. dom .. ")"
        end
    end
    local props = ui.doc_props or {}
    return { md5 = md5, kind = kind, path = ui.document.file,
             title = props.display_title or props.title, authors = props.authors }
end

--- Records the open book's changes since last time. Returns the summary
-- (see AnnStore:observe) and the book, or nil and why.
function AnnSync:observe(ui)
    local book, why = self:bookOf(ui)
    if not book then return nil, why end
    local res = self.deps.store:observe{
        md5 = book.md5, kind = book.kind, items = ui.annotation.annotations, now = self.deps.now(),
        device = self.deps.getDeviceId(), title = book.title, authors = book.authors, path = book.path,
    }
    if res.skipped > 0 then
        self.log.warn("StatSync:", res.skipped, "annotations in", book.path, "can't be synced")
    end
    return res, book
end

--- Is the user in the middle of something with the reader (a dialog, a selection)?
function AnnSync:_busy(ui)
    local um = self.deps.ui_manager
    if um and um.getTopmostVisibleWidget and um:getTopmostVisibleWidget() ~= (ui.dialog or ui) then return true end
    local hl = ui.highlight
    return hl ~= nil and (hl.selected_text ~= nil or hl.hold_pos ~= nil)
end

local function counts(annotation)
    if annotation.getNumberOfHighlightsAndNotes then return annotation:getNumberOfHighlightsAndNotes() end
    return 0, 0
end

--- Brings the open book's list in line with the merged state. Call
-- observe() first. Unless `force`, does nothing while the user is busy.
-- Returns the number of changes made, or nil and why.
function AnnSync:apply(ui, force)
    local book, why = self:bookOf(ui)
    if not book then return nil, why end
    if not force and self:_busy(ui) then return nil, "busy" end
    local store = self.deps.store
    local list = ui.annotation.annotations
    local ops = store:plan(book.md5, book.kind, list)
    if #ops == 0 then
        store:applied(book.md5, book.kind, list)
        return 0
    end
    local hl0, notes0 = counts(ui.annotation)
    local touched = {}
    local removals = {}
    for _, op in ipairs(ops) do
        if op.op == "replace" then
            local item = list[op.index]
            local old = {}
            for k, v in pairs(item) do old[k] = v end
            touched[#touched + 1] = old
            -- In place, so anything holding the item sees the new version.
            for k in pairs(item) do
                if not AnnFormat.LOCAL_FIELDS[k] then item[k] = nil end
            end
            for k, v in pairs(op.item) do item[k] = v end
            touched[#touched + 1] = item
        elseif op.op == "remove" then
            removals[#removals + 1] = op.index
        end
    end
    table.sort(removals, function(a, b) return a > b end)
    for _, index in ipairs(removals) do
        touched[#touched + 1] = table.remove(list, index)
    end
    for _, op in ipairs(ops) do
        if op.op == "add" then
            table.insert(list, op.item)
            touched[#touched + 1] = op.item
        end
    end
    -- KOReader's own refresh after outside changes: page numbers, then sort.
    if ui.annotation.updateAnnotations then ui.annotation:updateAnnotations(true, true) end
    local hl1, notes1 = counts(ui.annotation)
    -- index_modified: not an edit (KOReader would stamp datetime_updated),
    -- and the file browser's "has annotations" is refreshed.
    touched.index_modified = true
    touched.nb_highlights_added = hl1 - hl0
    touched.nb_notes_added = notes1 - notes0
    if ui.handleEvent then
        local Event = self.deps.event or require("ui/event")
        ui:handleEvent(Event:new("AnnotationsModified", touched))
    end
    local um = self.deps.ui_manager
    if um and um.setDirty then um:setDirty(ui.dialog or ui, "ui") end
    store:applied(book.md5, book.kind, list)
    self.log.info("StatSync: applied", #ops, "annotation changes to", book.path)
    return #ops
end

-- Hooks -------------------------------------------------------------------------------

--- A book was opened (after KOReader has loaded its annotations). Returns
-- the number of deletions newly held (e.g. its sidecar was reset).
function AnnSync:onReaderReady(ui)
    if not self.deps.enabled() then return 0 end
    local ok, held = pcall(function()
        local res, why = self:observe(ui)
        if not res then
            self.log.dbg("StatSync: annotations not synced for this book:", why)
            return 0
        end
        self:apply(ui, true)
        return res.held
    end)
    if not ok then
        self.log.warn("StatSync: annotations on open failed:", held)
        return 0
    end
    return held
end

--- The book is closing (KOReader has saved its annotations). Returns the
-- number of deletions newly held for the user.
function AnnSync:onClose(ui)
    if not self.deps.enabled() then return 0 end
    local ok, res = pcall(self.observe, self, ui)
    if not ok then
        self.log.warn("StatSync: recording annotation changes on close failed:", res)
        return 0
    end
    return res and res.held or 0
end

--- Before a sync: the open book's changes.
function AnnSync:collect()
    local ui = self:_readerUI()
    if ui then self:observe(ui) end
end

--- After a sync: apply what came in to the open book, then ask about held deletions.
function AnnSync:afterSync(run)
    local ui = self:_readerUI()
    local book = ui and self:bookOf(ui)
    if book then
        local id = book.md5 .. "\0" .. book.kind
        if (run.ann_affected and run.ann_affected[id]) or self.deps.store:isPending(book.md5, book.kind) then
            self:observe(ui)
            local n, why = self:apply(ui)
            if not n and why == "busy" then self:_applyLater(0) end
        end
    end
    self:askHeld()
end

AnnSync.RETRY_DELAY = 2   -- s between tries while the user is busy (a menu, a dialog)
AnnSync.RETRY_TRIES = 90  -- then leave it for the next sync, close or open

--- Applies to the open book once the user isn't busy any more.
function AnnSync:_applyLater(tries)
    if self.retrying and tries == 0 then return end
    self.retrying = true
    self.deps.schedule(AnnSync.RETRY_DELAY, function()
        local ui = self:_readerUI()
        local book = ui and self:bookOf(ui)
        if not book or not self.deps.enabled() or not self.deps.store:isPending(book.md5, book.kind) then
            self.retrying = false
            return
        end
        local ok, n, why = pcall(function()
            self:observe(ui)
            return self:apply(ui)
        end)
        if ok and not n and why == "busy" and tries + 1 < AnnSync.RETRY_TRIES then
            return self:_applyLater(tries + 1)
        end
        if not ok then self.log.warn("StatSync: applying annotations failed:", n) end
        self.retrying = false
    end)
end

-- Held deletions ------------------------------------------------------------------------

local function gettext(s)
    local ok, _ = pcall(require, "gettext")
    return ok and _(s) or s
end

-- ffi/util's template, for "%1"-style placeholders.
local function T(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

function AnnSync:heldText(h)
    local _ = gettext
    return T(_("%1 of %2 highlights and bookmarks in \"%3\" were removed on this device. Remove them on your other devices too?"),
        h.count, h.total, h.title or h.md5)
end

--- Asks about each book with held deletions in turn. "Ask later" leaves the
-- rest for the next close or sync.
function AnnSync:askHeld()
    if self.asking or not self.deps.enabled() then return end
    local held = self.deps.store:held()
    if #held == 0 then return end
    self.asking = true
    local i = 0
    local function nextOne()
        i = i + 1
        local h = held[i]
        if not h then self.asking = false; return end
        self:_ask(h, function(answer)
            if answer then
                self:resolve(h, answer)
                nextOne()
            else
                self.asking = false
            end
        end)
    end
    nextOne()
end

--- Shows the question for one held book; done(answer) with "restore",
-- "remove", or nil (ask later).
function AnnSync:_ask(h, done)
    if self.deps.confirm then return self.deps.confirm(h, self:heldText(h), done) end
    local _ = gettext
    local MultiConfirmBox = require("ui/widget/multiconfirmbox")
    self.deps.ui_manager:show(MultiConfirmBox:new{
        text = self:heldText(h),
        choice1_text = _("Restore them here"),
        choice1_callback = function() done("restore") end,
        choice2_text = _("Remove everywhere"),
        choice2_callback = function() done("remove") end,
        cancel_text = _("Ask later"),
        cancel_callback = function() done(nil) end,
    })
end

--- Carries out an answer. A restore of the open book is applied at once.
function AnnSync:resolve(h, answer)
    local n = self.deps.store:resolveHeld(h.md5, h.kind, answer, self.deps.now(), self.deps.getDeviceId())
    self.log.info("StatSync: held deletions in", h.title or h.md5, answer == "remove"
        and ("removed everywhere (" .. n .. ")") or "restored")
    if answer == "restore" then
        local ui = self:_readerUI()
        local book = ui and self:bookOf(ui)
        if book and book.md5 == h.md5 and book.kind == h.kind then
            self:observe(ui)
            self:apply(ui, true)
        end
    end
end

-- History scan -----------------------------------------------------------------------------

--- Reads the annotations of every book in the reading history (except the
-- open one), a few books per UI tick, and records them like changes seen on
-- close. done({ books, lists, held }) when finished.
function AnnSync:scan(done)
    if self.scanning then return false end
    self.scanning = true
    local deps = self.deps
    local DocSettings = deps.docsettings or require("docsettings")
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local hist = (deps.readhistory or require("readhistory")).hist or {}
    local files = {}
    for _, h in ipairs(hist) do
        if type(h.file) == "string" then files[#files + 1] = h.file end
    end
    local ui = self:_readerUI()
    local open_file = ui and ui.document and ui.document.file
    local stats = { books = 0, lists = 0, held = 0 }
    local i = 0

    local function scanFile(path)
        if path == open_file or lfs.attributes(path, "mode") ~= "file" then return end
        if not DocSettings:hasSidecarFile(path) then return end
        local ds = DocSettings:open(path)
        local md5 = ds:readSetting("partial_md5_checksum")
        if type(md5) ~= "string" or md5 == "" then return end
        local props = ds:readSetting("doc_props") or {}
        local dom = ds:readSetting("cre_dom_version")
        local seen_kind, counted = {}, false
        for _, setting in ipairs({ "annotations", "annotations_rolling", "annotations_paging" }) do
            local list = ds:readSetting(setting)
            local kind = AnnFormat.listKind(list)
            if kind and not seen_kind[kind]
                    and not (kind == "rolling" and type(dom) == "number" and dom < AnnSync.MIN_DOM_VERSION) then
                seen_kind[kind] = true
                local res = deps.store:observe{
                    md5 = md5, kind = kind, items = list, now = deps.now(), device = deps.getDeviceId(),
                    title = props.display_title or props.title, authors = props.authors, path = path,
                }
                stats.lists = stats.lists + 1
                stats.held = stats.held + res.held
                if not counted then stats.books = stats.books + 1; counted = true end
            end
        end
    end

    local function step()
        local ok, err = pcall(function()
            for _ = 1, AnnSync.SCAN_CHUNK do
                i = i + 1
                if not files[i] then return end
                local fok, ferr = pcall(scanFile, files[i])
                if not fok then self.log.warn("StatSync: reading annotations of", files[i], "failed:", ferr) end
            end
        end)
        if not ok then self.log.warn("StatSync: annotation scan failed:", err) end
        if ok and files[i] then
            deps.schedule(0, step)
            return
        end
        self.scanning = false
        if ok and deps.saveScanned then deps.saveScanned(deps.now()) end
        self.log.info(string.format("StatSync: annotation scan: %d books, %d lists, %d deletions held",
            stats.books, stats.lists, stats.held))
        if done then done(stats, not ok and err or nil) end
    end
    deps.schedule(0, step)
    return true
end

return AnnSync
