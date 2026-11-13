--[[--
Reading history sync inside KOReader. Synced with book data, in its stream
(see bookformat.lua and BOOKDATA.md):

- When a book was last opened is the book property `hist` (epoch seconds),
  under the book's partial MD5, so it doesn't matter where each device
  keeps the file. The latest time wins. Versions of a book (IDENTITY.md)
  share it.
- Only openings are synced, never removals: an entry removed here (by
  hand, by KOReader's size limit, or because the file is gone) stays
  removed until the book is opened again, here or elsewhere.

A book read elsewhere is put into this device's history at the time it was
read, so the latest book read on any device is at the top (and is the one
KOReader reopens on startup). The book is found:

1. among the files on this device that the sync knows (books opened here,
   books in collections or in the history), its versions' files included;
2. through Cloud library, when it's installed: the book's UUIDs (from book
   identity) are a catalog book, either downloaded (its file) or not (its
   cloud entry, which Cloud library keeps in the history).

A book found neither way is left until it is: it's looked for again after
every sync.

While a book is open, nothing is put above it in the history (KOReader
takes the top entry for the open book when it closes it); those wait for
the next sync, which closing the book starts.
--]]

local BookFormat = require("concordance/bookformat")
local Problems = require("concordance/problems")

local HistSync = {}
HistSync.__index = HistSync

HistSync.RETRY_DELAY = 2     -- s between tries while the user is busy
HistSync.RETRY_TRIES = 90

local HIST = BookFormat.HISTORY

--- deps: store (BookStore), finder (CollSync: md5s, paths, findMd5s),
-- getDeviceId(), now(), logger, schedule(delay, fn), enabled(), and
-- optionally readhistory, lfs, realpath(path), uuids(md5s) -> { [md5] =
-- { uuid, … } }, resolve(uuids) -> path or nil, idle(), open_book() ->
-- path or nil, refresh_ui(paths) (paths: books put into the history)
function HistSync.new(deps)
    local self = setmetatable({ deps = deps }, HistSync)
    self.log = deps.logger
    return self
end

function HistSync:_lfs() return self.deps.lfs or require("libs/libkoreader-lfs") end

function HistSync:_isFile(path)
    return type(path) == "string" and self:_lfs().attributes(path, "mode") == "file"
end

function HistSync:_realpath(path)
    if self.deps.realpath then return self.deps.realpath(path) or path end
    local ok, ffiUtil = pcall(require, "ffi/util")
    return ok and ffiUtil.realpath(path) or path
end

--- KOReader's history, read again if history.lua changed.
function HistSync:_rh()
    local rh = self.deps.readhistory or require("readhistory")
    if rh.reload then rh:reload() end
    return rh
end

function HistSync:_idle()
    if self.deps.idle then return self.deps.idle() end
    return self.deps.finder:_idle()
end

--- The open book's file, or nil.
function HistSync:_openBook()
    if self.deps.open_book then return self.deps.open_book() end
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local doc = ok and ReaderUI.instance and ReaderUI.instance.document
    return doc and doc.file or nil
end

--- The history's files on this device, newest time for each: { path, … },
-- { [path] = time }.
function HistSync:_files(rh)
    local paths, times = {}, {}
    for _, e in ipairs(rh.hist or {}) do
        local f, t = e.file, tonumber(e.time)
        if t and not times[f] and self:_isFile(f) then
            times[f] = math.floor(t)
            paths[#paths + 1] = f
        end
    end
    return paths, times
end

--- Before a sync: finds the MD5s of the books in the history, a chunk per
-- UI tick (the first time can be many). done() when finished.
function HistSync:refresh(done)
    local ok, rh = pcall(self._rh, self)
    if not ok then
        self.log.warn("Concordance: reading the history failed:", rh)
        Problems.report("hist:read", "Reading KOReader's history failed", rh)
        if done then done() end
        return
    end
    self.deps.finder:findMd5s((self:_files(rh)), done)
end

-- Local changes ------------------------------------------------------------------------

--- Records when this device last opened each book in its history. Returns
-- the number of changes recorded.
function HistSync:observe()
    local rh = self:_rh()
    local paths, times = self:_files(rh)
    local md5s = self.deps.finder:md5s(paths)
    local by = {}
    for _, path in ipairs(paths) do
        local md5 = md5s[path]
        if md5 and (not by[md5] or times[path] > by[md5]) then by[md5] = times[path] end
    end
    local keys = {}
    for md5 in pairs(by) do keys[#keys + 1] = md5 end
    table.sort(keys)
    local device, list = self.deps.getDeviceId(), {}
    for _, md5 in ipairs(keys) do
        local t = by[md5]
        -- Dated when the book was opened, whether it's new to the sync or not.
        list[#list + 1] = { md5 = md5, values = { [HIST] = t }, times = { [HIST] = t }, now = t, device = device }
    end
    local changed = 0
    for _, r in ipairs(self.deps.store:observeMany(list)) do changed = changed + r.changed end
    if changed > 0 then self.log.dbg("Concordance: history:", changed, "changes recorded") end
    return changed
end

-- Applying the merged state --------------------------------------------------------------

--- Where this device has the book (any of its versions): a file, a cloud
-- entry, or nil.
function HistSync:_target(rec, paths, uuids)
    for _, md5 in ipairs(rec.group) do
        for _, p in ipairs(paths[md5] or {}) do
            if self:_isFile(p) then return self:_realpath(p) end
        end
    end
    if not self.deps.resolve then return nil end
    local list, seen = {}, {}
    for _, md5 in ipairs(rec.group) do
        for _, u in ipairs(uuids[md5] or {}) do
            if not seen[u] then seen[u] = true; list[#list + 1] = u end
        end
    end
    if #list == 0 then return nil end
    local path = self.deps.resolve(list)
    if type(path) == "string" and path ~= "" then
        if self:_isFile(path) then return self:_realpath(path) end
        return path
    end
end

-- A target that isn't a file is a cloud entry: shown like a book, but not
-- one KOReader picks to reopen (select_enabled), since there's no file.
local function entryFor(path, time, exists)
    return {
        time = time, file = path, text = (path:gsub(".*/", "")),
        dim = false, select_enabled = exists,
    }
end

--- Puts books read elsewhere into KOReader's history, at the time they
-- were read. Records local changes first. Unless `force`, does nothing
-- while a menu or dialog is open (KOReader's History view keeps its own
-- copy). Returns the number of entries changed, or nil and why.
function HistSync:apply(force)
    if not force and not self:_idle() then return nil, "busy" end
    self:observe()
    local store = self.deps.store
    local merged = store:history()
    local todo = {}
    for md5, rec in pairs(merged) do
        if rec.hash ~= rec.seen then todo[md5] = rec end
    end
    if next(todo) == nil then return 0 end

    local paths = self.deps.finder:paths()
    local uuids = {}
    if self.deps.resolve and self.deps.uuids then
        local all = {}
        for _, rec in pairs(todo) do
            for _, m in ipairs(rec.group) do all[m] = true end
        end
        uuids = self.deps.uuids(all) or {}
    end

    -- The newest time for each place, and the books it's for.
    local want, order = {}, {}
    for md5, rec in pairs(todo) do
        local path = self:_target(rec, paths, uuids)
        if path then
            local w = want[path]
            if not w then
                w = { path = path, time = rec.time, md5s = {} }
                want[path] = w
                order[#order + 1] = w
            elseif rec.time > w.time then
                w.time = rec.time
            end
            table.insert(w.md5s, md5)
        end
    end
    table.sort(order, function(a, b) return a.path < b.path end)

    local rh = self:_rh()
    if type(rh.hist) ~= "table" then
        self.log.warn("Concordance: KOReader's history has no list of books (ReadHistory.hist)")
        Problems.report("check:ReadHistory.hist", "The reading history isn't synced: KOReader's history has changed",
            "ReadHistory.hist is missing")
        return nil, "no history"
    end
    local open = self:_openBook()
    local top = rh.hist[1]
    local cap = open and top and top.file == open and top.time or nil
    local lfs = self:_lfs()
    local n, seen, moved = 0, {}, {}
    local function markSeen(w)
        for _, md5 in ipairs(w.md5s) do seen[#seen + 1] = { md5 = md5, values = { [HIST] = todo[md5].time } } end
    end
    local function indexOf(path)
        local idx = rh.getIndexByFile and rh:getIndexByFile(path)
        if not idx then
            for i, e in ipairs(rh.hist) do if e.file == path then idx = i; break end end
        end
        return idx
    end
    -- Books on this device go in through ReadHistory:addItem, as KOReader
    -- puts in books it opens (at the time given, access time touched); cloud
    -- entries, which addItem won't take (no file), by hand.
    local files, entries = {}, {}
    for _, w in ipairs(order) do
        local idx = indexOf(w.path)
        local have = idx and tonumber(rh.hist[idx].time)
        if have and have >= w.time then
            markSeen(w) -- already there, as new or newer
        elseif w.path == open or (cap and w.time >= cap) then
            -- after the open book is closed
        elseif rh.addItem and self:_isFile(w.path) then
            files[#files + 1] = w
        elseif not rh.addItem and self:_isFile(w.path) then
            self.log.warn("Concordance: ReadHistory:addItem is missing, adding books by hand")
            Problems.report("check:ReadHistory.addItem", "KOReader's history has changed (ReadHistory:addItem is missing)",
                "books are added by hand")
            entries[#entries + 1] = w
        else
            entries[#entries + 1] = w
        end
    end
    local manual = false
    for _, w in ipairs(entries) do
        local exists = self:_isFile(w.path)
        local idx = indexOf(w.path)
        if idx then table.remove(rh.hist, idx) end
        local at = rh.getIndexByTime and rh:getIndexByTime(w.time, (w.path:gsub(".*/", ""))) or 1
        if not rh.getIndexByTime then
            while rh.hist[at] and (tonumber(rh.hist[at].time) or 0) >= w.time do at = at + 1 end
        end
        table.insert(rh.hist, at, entryFor(w.path, w.time, exists))
        if exists then
            -- The access time, for sorting by last read (as KOReader does).
            local a = lfs.attributes(w.path)
            if a and lfs.touch and (a.access or 0) < w.time then
                pcall(lfs.touch, w.path, w.time, a.modification)
            end
        end
        moved[#moved + 1] = w.path
        markSeen(w)
        manual = true
        n = n + 1
    end
    -- The last one saves the history (trimmed to its size, as KOReader does).
    local flushed = false
    for i, w in ipairs(files) do
        local last = i == #files
        local ok, added = pcall(rh.addItem, rh, w.path, w.time, not last)
        if not ok then
            self.log.warn("Concordance: adding to the history failed:", added)
            Problems.report("hist:add", "Putting books read elsewhere into the history failed", added)
        elseif not added then
            -- Not taken (ZenOS's incognito mode): tried again next sync.
            self.log.dbg("Concordance: history: not taken now:", w.path)
        else
            moved[#moved + 1] = w.path
            markSeen(w)
            n = n + 1
            if last then flushed = true end
        end
    end
    if n > 0 then
        if manual and rh.updateDateTimeString then rh:updateDateTimeString() end
        -- Only cloud entries changed, or the last addItem didn't save: there's
        -- no public call that only saves the history.
        if not flushed then
            if rh._reduce then rh:_reduce() end
            if rh._flush then
                rh:_flush()
            else
                self.log.warn("Concordance: ReadHistory:_flush is missing, the history isn't saved")
                Problems.report("check:ReadHistory._flush", "Books read elsewhere can't be saved into the history: KOReader's history has changed",
                    "ReadHistory:_flush is missing")
            end
        end
        -- Read back from the file just saved, so every entry is a new table.
        -- ZenOS's "last read" order is cached while the history's length and
        -- first and last entries (the tables) stay the same, so a book moved
        -- in the middle went unnoticed. (Cloud library's hooks keep cloud
        -- entries as they are through the re-read.)
        if rh.reload then
            local ok, err = pcall(rh.reload, rh, true)
            if not ok then
                self.log.warn("Concordance: re-reading the history failed:", err)
                Problems.report("hist:reload", "Re-reading KOReader's history failed", err)
            end
        end
        local rok, rerr = pcall(self.deps.refresh_ui or function() self.deps.finder:_refreshUI() end, moved)
        if not rok then
            self.log.warn("Concordance: redrawing after the history changed failed:", rerr)
            Problems.report("hist:redraw", "Redrawing the file browser after the history changed failed", rerr)
        end
        self.log.info("Concordance: put", n, "books read elsewhere into the history")
    end
    store:appliedMany(seen)
    if n > 0 then self:observe() end -- what's there now is this device's copy
    return n
end

--- After a sync: apply, or retry while the user is busy.
function HistSync:afterSync()
    local ok, n, why = pcall(self.apply, self)
    if not ok then
        self.log.warn("Concordance: applying the history failed:", n)
        Problems.report("hist:apply", "Applying the reading history failed", n)
    elseif not n and why == "busy" then
        self:_applyLater(0)
    end
end

function HistSync:_applyLater(tries)
    if self.retrying and tries == 0 then return end
    self.retrying = true
    self.deps.schedule(HistSync.RETRY_DELAY, function()
        if not self.deps.enabled() then
            self.retrying = false
            return
        end
        local ok, n, why = pcall(self.apply, self)
        if ok and not n and why == "busy" and tries + 1 < HistSync.RETRY_TRIES then
            return self:_applyLater(tries + 1)
        end
        if not ok then
            self.log.warn("Concordance: applying the history failed:", n)
            Problems.report("hist:apply", "Applying the reading history failed", n)
        end
        self.retrying = false
    end)
end

return HistSync
