--[[
Cloud books in KOReader's reading history.

Concordance puts books read on other devices into the history. For a book
that isn't on this device it asks Library.pathForUuids, which gives the
downloaded file or the book's cloud entry (its virtual path). This module
keeps those entries working:

  ReadHistory:_read         cloud entries aren't greyed out like missing files
                            (their select_enabled stays false, so KOReader
                            never reopens one on startup)
  ReadHistory:clearMissing  with "auto-remove deleted files" on, cloud
                            entries are kept
  ReadHistory:_flush        remembers the cloud entries: KOReader reads the
                            history (and, with auto-remove on, drops
                            missing files) before plugins load, so they're
                            put back at startup
  FileManagerHistory:onShowHist
                            tapping or long-pressing a cloud entry shows
                            the book's details

After each catalog load (History.reconcile): a downloaded book's entry
becomes its file, a deleted book's entry its cloud entry, and entries for
books gone from the catalog are greyed out.
]]

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local Guard = require("cloudlibrary/guard")
local Virtual = require("cloudlibrary/virtual")

local History = {
    installed = false,
    folder = nil,       -- function() -> library folder
    matched = nil,      -- function() -> { [id] = path }
    save = nil,         -- function(key, value)
    saved = nil,        -- function() -> saved cloud entries
    deleted = {},       -- path -> id: downloaded books being deleted
}

local PREFIX = "cloud-"

local function isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

--- Is this a cloud entry's path (whether or not the catalog is loaded)?
function History.isCloudPath(path)
    if type(path) ~= "string" then return false end
    if Virtual.by_path[path] then return true end
    local folder = History.folder and History.folder()
    if not folder then return false end
    folder = folder:gsub("/+$", "")
    local dir, name = path:match("^(.*)/([^/]+)$")
    return dir == folder and name:sub(1, #PREFIX) == PREFIX and name:match("%.epub$") ~= nil
        and not isFile(path)
end

local function idOf(path)
    local name = path:match("([^/]+)$") or ""
    return name:sub(#PREFIX + 1):gsub("%.epub$", "")
end

local function cloudPathFor(id)
    local folder = Virtual.folder or (History.folder and History.folder())
    return folder and (folder:gsub("/+$", "") .. "/" .. PREFIX .. id .. ".epub")
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
            local path = cloudPathFor(id)
            if path and Virtual.by_path[path] then return path end
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
        if History.isCloudPath(v.file) then out[#out + 1] = { file = v.file, time = v.time } end
    end
    return out
end

local function signature(list)
    local parts = {}
    for i, e in ipairs(list) do parts[i] = tostring(e.time) .. "\t" .. e.file end
    return table.concat(parts, "\n")
end

local function remember(rh)
    if not History.save then return end
    local list = cloudEntries(rh)
    local old = History.saved and History.saved() or {}
    if signature(list) ~= signature(old) then History.save("history_cloud", list) end
end

--- Inserts an entry at its time position (the history is newest first).
local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- ZenOS's "last read" sort keeps its own index of the history while the
-- history's length and first and last entries (the tables) stay the same,
-- so an entry changed in the middle went unnoticed: a deleted book's cloud
-- entry sorted by date added until the history was next reloaded. A new
-- first entry (same contents) makes ZenOS build its index again.
local function historyChanged(rh)
    if rh.hist[1] then rh.hist[1] = copy(rh.hist[1]) end
end

local function insertAt(rh, file, time)
    local at = rh.getIndexByTime and rh:getIndexByTime(time, (file:gsub(".*/", ""))) or 1
    table.insert(rh.hist, at, {
        time = time, file = file, text = (file:gsub(".*/", "")),
        dim = false, select_enabled = isFile(file),
    })
end

--- With auto-remove on, KOReader dropped the cloud entries at startup:
-- put back the ones there were.
function History.restore(rh)
    if not G_reader_settings:isTrue("autoremove_deleted_items_from_history") then return end
    local saved = History.saved and History.saved() or {}
    local n = 0
    for _i, e in ipairs(saved) do
        if type(e) == "table" and type(e.file) == "string" and tonumber(e.time)
                and History.isCloudPath(e.file) and not rh:getIndexByFile(e.file) then
            insertAt(rh, e.file, tonumber(e.time))
            n = n + 1
        end
    end
    if n > 0 then
        logger.info("CloudLibrary: put back", n, "cloud books in the history")
        rh:_flush()
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
                    local ok, err = pcall(Virtual.showDetails, item.file)
                    if ok then return true end
                    Guard.fail("history", "history " .. name, err)
                end
                return orig(m, item, ...)
            end
        end
    end
end

--- Installs the hooks. opts: folder(), matched(), save(key, value), saved().
function History.install(opts)
    if History.installed then return end
    History.installed = true
    History.folder, History.matched = opts.folder, opts.matched
    History.save, History.saved = opts.save, opts.saved
    if not Guard.ok("history") then return end
    local ReadHistory = require("readhistory")
    Guard.hook("history", ReadHistory, "_read", function(orig, self, ...)
        local r = orig(self, ...)
        if r then undim(self) end
        return r
    end, "ReadHistory:_read")
    Guard.hook("history", ReadHistory, "clearMissing", function(_orig, self)
        -- KOReader's, keeping cloud entries.
        local updated = false
        for i = #self.hist, 1, -1 do
            local file = self.hist[i].file
            if not History.isCloudPath(file) and (file == nil or not isFile(file)) then
                self:removeItem(self.hist[i], i, true)
                updated = true
            end
        end
        if updated then self:_flush() end
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

-- After a catalog load ------------------------------------------------------------

--- A downloaded book is about to be deleted: its entry becomes its cloud
-- entry again (see reconcile).
function History.deleting(path, id)
    if type(path) == "string" and type(id) == "string" then History.deleted[path] = id end
end

--- Brings the history in line with the catalog just loaded.
function History.reconcile()
    if not History.installed or not Guard.ok("history") then return end
    local ReadHistory = require("readhistory")
    local rh = ReadHistory
    local matched = History.matched and History.matched() or {}
    local changed = false

    -- Deleted books: back to their cloud entries.
    for path, id in pairs(History.deleted) do
        local i = rh:getIndexByFile(path)
        local cloud = cloudPathFor(id)
        if i and cloud and Virtual.by_path[cloud] and not isFile(path) then
            if rh:getIndexByFile(cloud) then
                table.remove(rh.hist, i)
            else
                local e = copy(rh.hist[i])
                e.file, e.text = cloud, (cloud:gsub(".*/", ""))
                e.dim, e.select_enabled = false, false
                rh.hist[i] = e
            end
            changed = true
        end
    end
    History.deleted = {}

    local downloaded = {}
    for _i, e in ipairs(rh.hist) do
        if History.isCloudPath(e.file) then
            local path = matched[idOf(e.file)]
            if path and isFile(path) then
                downloaded[#downloaded + 1] = { cloud = e.file, path = path }
            else
                -- Gone from the catalog: greyed out, like a missing file.
                local gone = Virtual.folder ~= nil and not Virtual.by_path[e.file]
                if e.dim ~= gone then
                    e.dim = gone
                    changed = true
                end
            end
        end
    end
    -- Downloaded: the entry is the file (the newer of the two, if both).
    for _i, d in ipairs(downloaded) do
        local i = rh:getIndexByFile(d.cloud)
        local time = rh.hist[i].time or 0
        table.remove(rh.hist, i)
        local j = rh:getIndexByFile(d.path)
        if j then
            time = math.max(time, rh.hist[j].time or 0)
            table.remove(rh.hist, j)
        end
        insertAt(rh, d.path, time)
        changed = true
    end
    if changed then
        historyChanged(rh)
        rh:_flush()
    end
end

return History
