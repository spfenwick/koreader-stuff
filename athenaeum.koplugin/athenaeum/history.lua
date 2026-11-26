--[[
Cloud books in KOReader's reading history.

Concordance puts books read on other devices into the history. For a book
that isn't on this device it asks Library.pathForUuids, which gives the
downloaded file or the book's cloud entry (where its file would be). This module
keeps those entries working:

  ReadHistory:_read         cloud entries aren't greyed out like missing files
                            (their select_enabled stays false, so KOReader
                            never reopens one on startup)
  ReadHistory:clearMissing  cloud entries are set aside while KOReader's
                            own clearMissing runs (at startup with
                            "auto-remove deleted files" on, or "Clear
                            history of deleted files"), then put back
  ReadHistory:_flush        remembers the cloud entries: KOReader reads the
                            history (and, with auto-remove on, drops
                            missing files) before plugins load, so they're
                            put back at startup. If one flush drops many of
                            them at once (something other than the hooks
                            above removed them, e.g. after a KOReader
                            change), the saved copy isn't trusted to
                            follow: those are kept aside and put back at
                            the next startup
  FileManagerHistory:onShowHist
                            tapping or long-pressing a cloud entry shows
                            the book's details (long-press adds "Remove
                            from history")

A book's entry is at its path whether it's downloaded or not: where its
file is, or would be ("Author - Title.epub", STABLE_PATHS_PLAN.md). So a
download or a delete changes only whether the entry opens a file.

After each catalog load (History.reconcile): entries with a file open it,
the catalog's cloud entries are shown (not greyed out), and entries for
books gone from the catalog are greyed out. Deleting a downloaded book
keeps its entry (History.keep, History.afterDelete): KOReader greys it
out, or removes it.
]]

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local Guard = require("athenaeum/guard")
local Virtual = require("athenaeum/virtual")
local ZenSource = require("athenaeum/zenos_source")

local History = {
    installed = false,
    matched = nil,      -- function() -> { [id] = path }
    save = nil,         -- function(key, value)
    saved = nil,        -- function() -> saved cloud entries
    set_aside = nil,    -- function() -> entries kept aside (SHARP_DROP)
}

-- A flush that drops at least this many saved cloud entries at once, and at
-- least half of them, isn't a person removing entries (KOReader removes them
-- one at a time; cloud books can't be selected for a bulk delete).
History.SHARP_DROP = 10

local function isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

-- The saved cloud entries by path, rebuilt when the saved list changes.
local saved_by_path, saved_of
local function savedEntry(path)
    local saved = History.saved and History.saved() or {}
    if saved ~= saved_of then
        saved_by_path, saved_of = {}, saved
        for _i, e in ipairs(saved) do
            if type(e) == "table" and type(e.file) == "string" then saved_by_path[e.file] = e end
        end
    end
    return saved_by_path[path]
end

--- Is this a cloud entry's path (whether or not the catalog is loaded)? A
-- catalog book's entry, else one saved as a cloud entry (with its catalog
-- ID) that still has no file.
function History.isCloudPath(path)
    if type(path) ~= "string" then return false end
    if Virtual.by_path[path] then return true end
    if not savedEntry(path) then return false end
    return not isFile(path)
end

local function idOf(path)
    local book = Virtual.by_path[path]
    if book then return book.id end
    local e = savedEntry(path)
    return e and e.id
end

-- An entry's name, as KOReader gives it: the file's (a cloud entry's path
-- is its book's file name).
local function nameOf(file)
    return (file:gsub(".*/", ""))
end

-- Catalog IDs by lowercase UUID, rebuilt when the catalog changes.
local index, index_gen
local function catalogIds()
    if index and index_gen == Virtual.generation then return index end
    index, index_gen = {}, Virtual.generation
    for _i, book in ipairs(Virtual.books) do
        if type(book.id) == "string" then index[book.id:lower()] = book.id end
    end
    for id in pairs(History.matched and History.matched() or {}) do
        if type(id) == "string" then index[id:lower()] = id end
    end
    return index
end

--- Where this device has the catalog book with one of these UUIDs: its
-- downloaded file, or its cloud entry. nil if none (or the catalog isn't
-- loaded). For Concordance.
function History.pathForUuids(uuids)
    if type(uuids) ~= "table" or not History.installed or not Guard.ok("history") then return nil end
    local ids = catalogIds()
    local matched = History.matched and History.matched() or {}
    for _i, u in ipairs(uuids) do
        local id = type(u) == "string" and ids[u:lower()]
        if id then
            if matched[id] then return matched[id] end
            local book = Virtual.by_id[id]
            if book then return book.path end
        end
    end
    return nil
end

-- Hooks -------------------------------------------------------------------------

-- Before the catalog is loaded, any cloud entry; after, the catalog's.
local function undim(rh)
    local changed = false
    for _i, v in ipairs(rh.hist or {}) do
        if v.dim and (Virtual.by_path[v.file] or (Virtual.folder == nil and History.isCloudPath(v.file))) then
            v.dim = false
            changed = true
        end
    end
    return changed
end

local function cloudEntries(rh)
    local out = {}
    for _i, v in ipairs(rh.hist or {}) do
        if History.isCloudPath(v.file) then out[#out + 1] = { file = v.file, time = v.time, id = idOf(v.file) } end
    end
    return out
end

local function signature(list)
    local parts = {}
    for i, e in ipairs(list) do parts[i] = tostring(e.time) .. "\t" .. e.file .. "\t" .. tostring(e.id) end
    return table.concat(parts, "\n")
end

-- While KOReader's clearMissing runs with the cloud entries set aside, its
-- flush mustn't be remembered: it would be without them.
local hiding, flushed_while_hiding = false, false
-- While Athenaeum itself moves entries (History.moved): what leaves the
-- saved list then isn't a sharp drop.
local moving = false

local function remember(rh)
    if not History.save then return end
    if hiding then
        flushed_while_hiding = true
        return
    end
    local list = cloudEntries(rh)
    local old = History.saved and History.saved() or {}
    if signature(list) == signature(old) then return end
    -- Saved entries gone from the history whose books are still cloud books
    -- (a downloaded book's entry leaves the cloud list by itself).
    local now = {}
    for _i, e in ipairs(list) do now[e.file] = true end
    local dropped = {}
    for _i, e in ipairs(old) do
        if type(e) == "table" and type(e.file) == "string" and not now[e.file]
                and History.isCloudPath(e.file) then
            dropped[#dropped + 1] = e
        end
    end
    if not moving and #dropped >= History.SHARP_DROP and #dropped * 2 >= #old
            and #(rh.hist or {}) > 0 then
        logger.warn("Athenaeum:", #dropped, "of", #old,
            "cloud books left the history at once; keeping them to put back at startup")
        local aside = {}
        for _i, e in ipairs(History.set_aside and History.set_aside() or {}) do aside[#aside + 1] = e end
        for _i, e in ipairs(dropped) do aside[#aside + 1] = e end
        History.save("history_cloud_set_aside", aside)
    end
    History.save("history_cloud", list)
end

local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

--- Inserts an entry at its time position (the history is newest first).
local function insertAt(rh, file, time)
    local at = rh.getIndexByTime and rh:getIndexByTime(time, nameOf(file)) or 1
    table.insert(rh.hist, at, {
        time = time, file = file, text = nameOf(file),
        dim = false, select_enabled = isFile(file),
    })
end

--- With auto-remove on, KOReader dropped the cloud entries at startup:
-- put back the ones there were.
function History.restore(rh)
    local n = 0
    local function putBack(list, any)
        for _i, e in ipairs(list) do
            if type(e) == "table" and type(e.file) == "string" and tonumber(e.time)
                    and (any or History.isCloudPath(e.file)) and not rh:getIndexByFile(e.file) then
                insertAt(rh, e.file, tonumber(e.time))
                n = n + 1
            end
        end
    end
    if G_reader_settings:isTrue("autoremove_deleted_items_from_history") then
        putBack(History.saved and History.saved() or {})
    end
    -- Entries a sharp drop kept aside (remember): put back once. They were
    -- cloud entries then; they're no longer in the saved list, which is how
    -- isCloudPath knows one before the catalog is loaded.
    local aside = History.set_aside and History.set_aside()
    if type(aside) == "table" and #aside > 0 then
        -- Back in the saved list too, so later startups keep them.
        local merged, seen = {}, {}
        for _i, e in ipairs(History.saved and History.saved() or {}) do
            if type(e) == "table" and type(e.file) == "string" and not seen[e.file] then
                merged[#merged + 1], seen[e.file] = e, true
            end
        end
        for _i, e in ipairs(aside) do
            if type(e) == "table" and type(e.file) == "string" and not seen[e.file] then
                merged[#merged + 1], seen[e.file] = e, true
            end
        end
        History.save("history_cloud", merged)
        putBack(aside, true)
        History.save("history_cloud_set_aside", nil)
    end
    if n > 0 then
        logger.info("Athenaeum: put back", n, "cloud books in the history")
        rh:_flush()
    end
end

--- For Virtual.showDetails's extra_rows: a "Remove from history" row for
-- the entry at path. after() runs once it's removed.
function History.removeRows(path, after)
    return function(close)
        local Details = require("athenaeum/details")
        return Guard.wrapCallbacks({{{
            text = Details.label("delete", _("Remove from history")),
            align = "left",
            callback = function()
                close()
                require("readhistory"):removeItemByPath(path)
                if after then after() end
            end,
        }}}, "history")
    end
end

function History.wrapHistoryMenu(manager)
    local menu = manager and manager.booklist_menu
    if type(menu) ~= "table" then return end
    for _i, name in ipairs({ "onMenuSelect", "onMenuHold" }) do
        local orig = menu[name]
        if type(orig) == "function" then
            menu[name] = function(m, item, ...)
                if Guard.ok("history") and type(item) == "table" and Virtual.by_path[item.file] then
                    local opts = name == "onMenuHold" and { extra_rows = History.removeRows(item.file,
                        function() if manager.updateItemTable then manager:updateItemTable() end end) } or nil
                    local ok, err = pcall(Virtual.showDetails, item.file, opts)
                    if ok then return true end
                    Guard.fail("history", "history " .. name, err)
                end
                return orig(m, item, ...)
            end
        end
    end
end

--- Installs the hooks. opts: matched(), save(key, value), saved().
function History.install(opts)
    if History.installed then return end
    History.installed = true
    History.matched = opts.matched
    History.save, History.saved, History.set_aside = opts.save, opts.saved, opts.set_aside
    if not Guard.ok("history") then return end
    local ReadHistory = require("readhistory")
    Guard.hook("history", ReadHistory, "_read", function(orig, self, ...)
        local r = orig(self, ...)
        if r then undim(self) end
        return r
    end, "ReadHistory:_read")
    Guard.hook("history", ReadHistory, "clearMissing", function(orig, self, ...)
        -- KOReader's own, with the cloud entries set aside (it would drop
        -- them: they have no file), then put back where they were by time.
        local aside = {}
        for i = #self.hist, 1, -1 do
            if History.isCloudPath(self.hist[i].file) then
                table.insert(aside, 1, table.remove(self.hist, i))
            end
        end
        if #aside == 0 then return orig(self, ...) end
        hiding, flushed_while_hiding = true, false
        local ok, err = pcall(orig, self, ...)
        hiding = false
        for _i, e in ipairs(aside) do
            table.insert(self.hist, self:getIndexByTime(e.time, nameOf(e.file)) or (#self.hist + 1), e)
        end
        if flushed_while_hiding then self:_flush() end
        if not ok then error(err, 0) end
    end, "ReadHistory:clearMissing")
    Guard.hook("history", ReadHistory, "_flush", function(orig, self, ...)
        local r = orig(self, ...)
        remember(self)
        return r
    end, "ReadHistory:_flush")
    local ok_fmh, FileManagerHistory = pcall(require, "apps/filemanager/filemanagerhistory")
    if ok_fmh and type(FileManagerHistory) == "table" then
        Guard.hook("history", FileManagerHistory, "onShowHist", function(orig, self, ...)
            local r = orig(self, ...)
            History.wrapHistoryMenu(self)
            return r
        end, "FileManagerHistory:onShowHist")
    end
    Guard.call("history", function()
        undim(ReadHistory)
        History.restore(ReadHistory)
    end)
end

-- A book moved ------------------------------------------------------------------

--- Catalog books' paths changed (Library.booksMoved): { { old, new }, … }.
-- Each history entry moves with its book, keeping its place by time (the
-- newer time if both paths had an entry), and so does its saved cloud
-- entry. One save for them all. Returns true if the history changed.
function History.moved(moves)
    if type(moves) ~= "table" or not Guard.ok("history") then return false end
    local rh = require("readhistory")
    -- The saved list as it was: saving the history below rewrites it from
    -- the entries it can tell are cloud ones.
    local list = {}
    for _i, e in ipairs(History.saved and History.saved() or {}) do list[#list + 1] = e end
    local changed, saved_changed = {}, false
    for _i, m in ipairs(moves) do
        local old, new = m[1], m[2]
        if type(old) == "string" and type(new) == "string" and old ~= new then
            local i = rh:getIndexByFile(old)
            if i then
                local time = rh.hist[i].time or 0
                table.remove(rh.hist, i)
                local j = rh:getIndexByFile(new)
                if j then
                    time = math.max(time, rh.hist[j].time or 0)
                    table.remove(rh.hist, j)
                end
                insertAt(rh, new, time)
                changed[#changed + 1] = old
                changed[#changed + 1] = new
            end
            local kept, time, id, moved = {}, nil, nil, false
            for _j, e in ipairs(list) do
                if type(e) == "table" and (e.file == old or e.file == new) then
                    moved = moved or e.file == old
                    time = math.max(time or 0, tonumber(e.time) or 0)
                    id = id or e.id
                else
                    kept[#kept + 1] = e
                end
            end
            if moved then
                -- A file now: KOReader keeps its entry itself.
                if not isFile(new) then table.insert(kept, { file = new, time = time, id = id }) end
                list, saved_changed = kept, true
            end
        end
    end
    if #changed > 0 then
        moving = true
        local ok, err = pcall(rh._flush, rh)
        moving = false
        if not ok then error(err, 0) end
        ZenSource.historyChanged(changed) -- see reconcile
    end
    if saved_changed and History.save then History.save("history_cloud", list) end
    return #changed > 0
end

-- After a catalog load, and after a delete ---------------------------------------

--- Brings the history in line with the files and the catalog: an entry
-- with a file opens it (a book downloaded to its cloud entry's path); a
-- catalog book's cloud entry is shown and doesn't open (a book deleted,
-- greyed out by KOReader); an entry for a book gone from the catalog is
-- greyed out. changed: paths whose entries were changed already (the
-- history is saved then), or nil.
local function reconcile(changed)
    changed = changed or {}
    local rh = require("readhistory")
    for i, e in ipairs(rh.hist) do
        local cloud = Virtual.by_path[e.file] ~= nil
        if cloud then
            if e.dim or e.select_enabled then
                rh.hist[i] = copy(e)
                rh.hist[i].dim, rh.hist[i].select_enabled = false, false
                changed[#changed + 1] = e.file
            end
        elseif not e.select_enabled and isFile(e.file) then
            rh.hist[i] = copy(e)
            rh.hist[i].dim, rh.hist[i].select_enabled = false, true
            changed[#changed + 1] = e.file
        elseif History.isCloudPath(e.file) then
            -- Not the catalog's: gone from it, greyed out like a missing
            -- file (once the catalog is known). (A book on the device under
            -- another name has its entry moved there by Library.booksMoved.)
            local matched = History.matched and History.matched() or {}
            local gone = Virtual.folder ~= nil and not matched[idOf(e.file) or false]
            if e.dim ~= gone then
                e.dim = gone
                changed[#changed + 1] = e.file
            end
        end
    end
    if #changed > 0 then
        rh:_flush()
        -- ZenOS's "last read" sort keeps its own index of the history, which
        -- can't see an entry changed in the middle (a deleted book's cloud
        -- entry put back would sort by date added): telling it drops the
        -- index at once, before the caller's redraw, and refreshes Home.
        ZenSource.historyChanged(changed)
    end
end

function History.reconcile()
    if not History.installed or not Guard.ok("history") then return end
    reconcile(nil)
end

--- Before KOReader deletes catalog books' files: their history entries'
-- times, { [path] = time }, for afterDelete. (KOReader greys a deleted
-- file's entry out, or removes it with "auto-remove deleted files" on.)
function History.keep(paths)
    local kept = {}
    if not History.installed or not Guard.ok("history") then return kept end
    local rh = require("readhistory")
    for _i, path in ipairs(paths or {}) do
        local i = rh:getIndexByFile(path)
        if i then kept[path] = rh.hist[i].time end
    end
    return kept
end

--- After the delete (the books are cloud books again, Library.unmatch):
-- the entries KOReader removed are put back at their times, and the ones
-- it greyed out are cloud entries again. Files still there (not deleted
-- after all) keep their entries as they are.
function History.afterDelete(kept)
    if not History.installed or not Guard.ok("history") or next(kept or {}) == nil then return end
    local rh = require("readhistory")
    local changed = {}
    for path, time in pairs(kept) do
        if not isFile(path) and not rh:getIndexByFile(path) then
            insertAt(rh, path, time)
            changed[#changed + 1] = path
        end
    end
    reconcile(changed)
end

return History
