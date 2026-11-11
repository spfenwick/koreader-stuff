--[[
Ties the pieces together: settings, the catalog store, syncing in a
subprocess, matching local files, and the virtual entries shown in the file
browser.

Settings (settings/cloudlibrary/settings.lua, see settings.lua):
  server     { url, username } of one of KOReader's OPDS catalogs
  folder     library folder (default: KOReader's download folder, else home)
  show       show cloud books (default true)
  quick_sync  automatic quick sync, when the file browser opens and Wi-Fi is
             on: "1h" (default), "3h", "6h", "12h", "daily" or "never"
  full_sync  scheduled full sync: "daily", "weekly" (default) or "never"; a
             quick sync that finds the book count changed runs one anyway
  auto_sync  old on/off switch: false (and no quick_sync/full_sync) = never
  badge_cloud  cloud badge on cloud-only books (default true)
  badge_local  on-device badge on local catalog books (default false)
  badge_noncloud  badge on books in the folder not in the catalog (default false)
  search     cloud books in file search results (default true)
  zenos_groups  cloud books in ZenOS's Authors, Series and Tags tabs (default true)

The password stays in KOReader's OPDS settings and is read from there.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local Badge = require("cloudlibrary/badge")
local Covers = require("cloudlibrary/covers")
local Downloads = require("cloudlibrary/downloads")
local ZenSource = require("cloudlibrary/zenos_source")
local Guard = require("cloudlibrary/guard")
local History = require("cloudlibrary/history")
local Matcher = require("cloudlibrary/matcher")
local Search = require("cloudlibrary/search")
local Settings = require("cloudlibrary/settings")
local Store = require("cloudlibrary/store")
local Timing = require("cloudlibrary/timing")
local Virtual = require("cloudlibrary/virtual")

Virtual.canFetchCovers = Covers.canFetch
Virtual.requestCovers = Covers.request
Virtual.coversBusy = Covers.busy
-- ZenOS's cached covers for these books are stale once theirs arrive.
Covers.on_arrived = function(books)
    local paths = {}
    for _i, b in ipairs(books) do
        if b.path then paths[#paths + 1] = b.path end
    end
    if #paths > 0 then ZenSource.changed(paths) end
end
-- Cloud books in ZenOS's groups (setting zenos_groups).
ZenSource.enabled = function()
    return Settings.all().zenos_groups ~= false and Guard.ok("zenos")
end
-- Badges change how listed items are laid out (see Badge.decorate).
Virtual.listingExtra = function()
    return table.concat({ tostring(Guard.ok("badge")), tostring(Badge.cloud_enabled),
        tostring(Badge.local_enabled), tostring(Badge.noncloud_enabled) }, ",")
end

local Library = {
    job = nil,          -- running sync: { pid, fd, mode, started }
    last_result = nil,  -- last job's result table
    stats = {},         -- counts from the last load
}

Library.on_device = {} -- path -> true: local files that are catalog books
Badge.isOnDevice = function(path) return Library.on_device[path] == true end
Library.not_in_catalog = {} -- path -> true: local files in the folder that aren't catalog books
Badge.isNonCloud = function(path) return Library.not_in_catalog[path] == true end
Badge.isCloud = function(path) return Virtual.by_path[path] ~= nil end

-- Automatic quick and full syncs (settings quick_sync, full_sync); a quick
-- sync that finds the book count changed runs a full sync anyway.
local HOUR = 60 * 60
local QUICK_INTERVALS = { ["1h"] = HOUR, ["3h"] = 3 * HOUR, ["6h"] = 6 * HOUR, ["12h"] = 12 * HOUR,
    daily = 24 * HOUR }
local QUICK_SYNC_MODES = { "1h", "3h", "6h", "12h", "daily", "never" }
local FULL_INTERVALS = { daily = 24 * HOUR, weekly = 7 * 24 * HOUR }
local FULL_SYNC_MODES = { "daily", "weekly", "never" }
local PREFETCH_COVERS = 300          -- covers a batch after each sync, newest first (all, in batches, on a first sync)
local PREFETCH_SECONDS = 180        -- (a batch, also for "Download missing covers")
local MAX_CRASHES = 3               -- cover jobs dying in a row before giving up
local CHECK_DELAY = 3                -- s after the file browser opens: let it draw first

-- Settings ----------------------------------------------------------------------

-- In settings/cloudlibrary/settings.lua (see settings.lua).
function Library.settings()
    return Settings.all()
end

function Library.save(key, value)
    Settings.save(key, value)
end

--- Redraws the file browser after a badge setting changed (the listing is
-- rebuilt: plain list rows make room for the badge).
function Library.repaint()
    Virtual.refresh()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then UIManager:setDirty(FileManager.instance, "ui") end
end

function Library.opdsServers()
    local path = DataStorage:getSettingsDir() .. "/opds.lua"
    local servers = LuaSettings:open(path):readSetting("servers") or {}
    local out = {}
    for _i, s in ipairs(servers) do
        if type(s) == "table" and type(s.url) == "string" and s.url ~= "" then
            table.insert(out, s)
        end
    end
    return out
end

--- The chosen OPDS catalog, with its password, or nil.
function Library.server()
    local chosen = Library.settings().server
    if type(chosen) ~= "table" then return nil end
    for _i, s in ipairs(Library.opdsServers()) do
        if s.url == chosen.url and (s.username or "") == (chosen.username or "") then
            return s
        end
    end
end

function Library.folder()
    local folder = Library.settings().folder
        or G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("home_dir")
    return folder and (folder:gsub("/+$", ""))
end

local function serverKey(server)
    return require("ffi/sha2").md5((server.url or "") .. "\0" .. (server.username or ""))
end

function Library.dbPath(server)
    local dir = DataStorage:getSettingsDir() .. "/cloudlibrary"
    util.makePath(dir)
    return dir .. "/" .. serverKey(server) .. ".sqlite3"
end

function Library.coversDir(server)
    return DataStorage:getSettingsDir() .. "/cloudlibrary/" .. serverKey(server) .. "-covers"
end

local function openStore(server)
    return Store.open(Library.dbPath(server), Device:canUseWAL())
end

-- Loading into the file browser --------------------------------------------------

-- The folder is redrawn only when the cloud books shown changed (ZenOS's
-- cached listing is keyed on the same signature, Virtual.listingKey()).
local function showCatalog(folder, cloud)
    local before = Virtual.catalog_sig
    Virtual.setCatalog(folder, cloud)
    -- A refetched cover keeps its file name: don't show the old image.
    Virtual.forgetDecodedCovers()
    if Virtual.catalog_sig ~= before then Virtual.refresh() end
end

--- Library.load() with a message up, for when it's slow (many cloud books
-- to list): closes the menu first, so the screen doesn't look stuck.
function Library.loadShowingProgress(touchmenu_instance)
    if touchmenu_instance then touchmenu_instance:closeMenu() end
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Loading cloud books…"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, err = pcall(Library.load)
    UIManager:close(msg)
    if not ok then error(err, 0) end
end

-- What a load depends on, besides the catalog and the folder's files.
local function loadKey(server, folder, s)
    return table.concat({ server and server.url or "", server and server.username or "",
        folder or "", tostring(s.show ~= false) }, "\0")
end

--- Reads the catalog, matches local files, and updates the cloud books shown.
function Library.load()
    local server, folder = Library.server(), Library.folder()
    local s = Library.settings()
    Library.loaded_key = nil -- set once loaded
    Badge.cloud_enabled = s.badge_cloud ~= false
    Badge.local_enabled = s.badge_local == true
    Badge.noncloud_enabled = s.badge_noncloud == true
    Search.enabled = s.search ~= false
    if not server or not folder or s.show == false then
        Library.stats = {}
        Library.catalog = {}
        Library.matched, Library.on_device, Library.not_in_catalog = {}, {}, {}
        Library.by_title, Library.file_info = {}, {}
        Covers.configure(nil)
        showCatalog(folder, {})
        Guard.call("history", History.reconcile)
        Library.loaded_key = loadKey(server, folder, s)
        return
    end
    local t_load = Timing.start()
    local covers_dir = Library.coversDir(server)
    Covers.configure{ server = server, db_path = Library.dbPath(server), dir = covers_dir,
        wal = Device:canUseWAL() }
    local t0 = Timing.start()
    local store = openStore(server)
    local books, counts = store:listing()
    for _i, b in ipairs(books) do
        if b.cover_file then b.cover = covers_dir .. "/" .. b.cover_file end
    end
    local files = store:localFiles()
    store:close()
    Timing.record("catalog: read database", Timing.since(t0), #books .. " books")
    t0 = Timing.start()
    local matched, unmatched, by_title, copies = Matcher.match(folder, files, books)
    Timing.record("catalog: match local files", Timing.since(t0))
    local cloud = {}
    for _i, b in ipairs(books) do
        if not matched[b.id] then table.insert(cloud, b) end
    end
    Library.catalog = books -- every catalog book, in the database's order
    Library.matched = matched
    Library.by_title = by_title
    Library.file_info = files
    Library.on_device = {}
    for _id, path in pairs(matched) do Library.on_device[path] = true end
    -- A second copy of a catalog book is a catalog book's file too.
    for path in pairs(copies or {}) do Library.on_device[path] = true end
    Library.not_in_catalog = {}
    for _i, path in ipairs(unmatched) do Library.not_in_catalog[path] = true end
    Library.stats = {
        catalog = #books, cloud = #cloud, on_device = #books - #cloud,
        unmatched_files = #unmatched,
        covers = counts.downloaded, covers_available = counts.with_cover, covers_failed = counts.failed,
    }
    logger.info("CloudLibrary: loaded", Library.stats)
    t0 = Timing.start()
    showCatalog(folder, cloud)
    Guard.call("history", History.reconcile)
    Timing.record("catalog: show in folder", Timing.since(t0))
    Timing.record("catalog: load", Timing.since(t_load),
        string.format("%d cloud books, %d on this device", #cloud, #books - #cloud))
    Library.loaded_key = loadKey(server, folder, s)
end

-- Deleting a downloaded book makes it a cloud book again. KOReader sends no
-- event for deletions, so its two delete functions are wrapped; the catalog
-- is reloaded (matching looks at the files actually in the folder) after
-- KOReader's own refresh.
local function under(path, folder)
    return path == folder or path:sub(1, #folder + 1) == folder .. "/"
end

local function inLibrary(path)
    local folder = Library.folder()
    return type(path) == "string" and folder ~= nil and under(path, folder)
end

-- KOReader's delete dialog passes the file's real path, which can be
-- spelled differently from the library folder setting (a symlink, a
-- doubled slash). The path spelled as the library has it, or nil.
local function libraryPath(path)
    if type(path) ~= "string" then return nil end
    if inLibrary(path) then return path end
    local folder = Library.folder()
    local real = folder and ffiutil.realpath(folder)
    if real and real ~= folder and under(path, real) then
        return folder .. path:sub(#real + 1)
    end
end

-- After a delete, the library folder is also redrawn once more, after the
-- redraw of whoever deleted the file (scheduled before this runs): on a
-- Kobo that one could still show the folder without the book's cloud
-- entry, which only came back on leaving and reopening the folder.
-- ZenOS's Home is rebuilt too: its rows show the deleted file until then.
local reload_scheduled = false
local deleted_paths = {}
local function reloadSoon(after_delete, paths)
    if Library.fixture then return end
    for _i, path in ipairs(paths or {}) do deleted_paths[#deleted_paths + 1] = path end
    if reload_scheduled then return end
    reload_scheduled = true
    UIManager:nextTick(function()
        reload_scheduled = false
        local before = Virtual.catalog_sig
        Guard.call("jobs", Library.load)
        -- Library.load() redraws when the cloud books changed.
        if after_delete and Virtual.catalog_sig == before then
            UIManager:nextTick(function() Guard.call("jobs", Virtual.refresh) end)
        end
        if after_delete then
            local home_paths = deleted_paths
            deleted_paths = {}
            local ok, err = pcall(ZenSource.refreshHome, home_paths)
            if not ok then logger.warn("CloudLibrary: rebuilding Home after a delete:", err) end
        end
    end)
end

local function cloudPathFor(id)
    for _i, b in ipairs(Virtual.books) do
        if b.id == id then return b.path end
    end
end

-- The deleted files and their books' cloud entries ({ path = id } from
-- unmatch()), for Home to forget.
local function homePaths(changed)
    local out = {}
    for path, id in pairs(changed) do
        out[#out + 1] = path
        out[#out + 1] = cloudPathFor(id)
    end
    return out
end

-- Open ZenOS views list the deleted files' cloud entries instead. Done
-- before the caller redraws: ZenOS then takes a deleted file out of its
-- open Authors/Series/... lists, which would leave its book out.
local function showCloudInViews(changed)
    for path, id in pairs(changed) do
        local cloud = cloudPathFor(id)
        if cloud then
            local ok, err = pcall(ZenSource.replaceInViews, path, cloud)
            if not ok then logger.warn("CloudLibrary: redrawing views after a delete:", err) end
        end
    end
end

--- The catalog ID of a downloaded book's file, or nil.
local function idForPath(path)
    for id, p in pairs(Library.matched or {}) do
        if p == path then return id end
    end
end

--- Shows these deleted files' catalog books as cloud books straight away,
-- before the file browser lists the folder again, so they don't vanish
-- until the reload after the delete puts them back. The listing isn't
-- redrawn here: whoever deleted the files does that. Returns the
-- { path = id } changed, for undoing with restoreMatched().
function Library.unmatch(paths)
    local changed = {}
    for _i, path in ipairs(paths) do
        local id = idForPath(path)
        if id then
            Library.matched[id] = nil
            Library.on_device[path] = nil
            changed[path] = id
        end
    end
    if next(changed) == nil or not Library.catalog then return changed end
    -- As Library.load() builds it, so the reload finds nothing new to show.
    local cloud = {}
    for _i, b in ipairs(Library.catalog) do
        if not Library.matched[b.id] then cloud[#cloud + 1] = b end
    end
    Virtual.setCatalog(Library.folder(), cloud)
    return changed
end

--- Undoes unmatch() for files that weren't deleted after all.
function Library.restoreMatched(changed)
    local any = false
    for path, id in pairs(changed) do
        if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
            Library.matched[id] = path
            Library.on_device[path] = true
            any = true
        end
    end
    if any then
        local cloud = {}
        for _i, b in ipairs(Library.catalog or {}) do
            if not Library.matched[b.id] then cloud[#cloud + 1] = b end
        end
        Virtual.setCatalog(Library.folder(), cloud)
    end
end

--- Where this device has the catalog book with one of these UUIDs (its
-- file, or its cloud entry), or nil. Used by Concordance for the history.
function Library.pathForUuids(uuids)
    return History.pathForUuids(uuids)
end

-- Concordance ------------------------------------------------------------------------
--
-- When Concordance is installed, it tells us what other devices know about
-- catalog books (status, rating, last read: shown for cloud books), and we
-- tell it which files here are which catalog book. See Concordance's
-- IDENTITY.md and concordance/identity.lua.

local identity_listening = false

--- Concordance's identity module, once Concordance has set it up, else nil.
function Library.identity()
    local Identity = package.loaded["concordance/identity"]
    if type(Identity) ~= "table" or type(Identity.available) ~= "function" or not Identity.available() then
        return nil
    end
    if not identity_listening and type(Identity.onChanged) == "function" then
        identity_listening = true
        Identity.onChanged("cloudlibrary", function() UIManager:nextTick(Library.redrawStates) end)
    end
    return Identity
end

--- Book states changed: redraw what's shown (the badges and the details
-- are drawn from them; nothing is laid out again).
function Library.redrawStates()
    if not next(Virtual.by_path) then return end
    for _i, w in ipairs(UIManager._window_stack or {}) do
        if w.widget then UIManager:setDirty(w.widget, "ui") end
    end
end

--- A cloud book's state from Concordance: { status, rating, last_read,
-- last_device }, or nil.
function Library.bookState(id)
    local Identity = type(id) == "string" and Library.identity()
    if not Identity or type(Identity.bookState) ~= "function" then return nil end
    return Identity.bookState({ id })
end

--- Whether the catalog has been read since KOReader started (it isn't when
-- KOReader starts in a book): until then localFiles() and links() are
-- empty, which doesn't mean the files are gone.
function Library.isLoaded()
    return Library.loaded_key ~= nil
end

--- The catalog books' files in the library folder (for Concordance to read
-- their identity, opened or not): { path, … }, sorted.
function Library.localFiles()
    local out = {}
    for path in pairs(Library.on_device or {}) do out[#out + 1] = path end
    table.sort(out)
    return out
end

--- Files matched to a catalog book without naming its UUID themselves (by
-- title, or not an EPUB): { { path, md5, uuids = { id }, title, authors }, … }.
-- Files whose partial MD5 isn't known yet are left out until it is.
function Library.links()
    local by_id = {}
    for _i, b in ipairs(Library.catalog or {}) do by_id[b.id] = b end
    local out = {}
    for id, path in pairs(Library.matched or {}) do
        local info = Library.file_info and Library.file_info[path]
        local book = by_id[id]
        if book and info and info.md5 and ((Library.by_title or {})[id] or not path:lower():match("%.epub$")) then
            out[#out + 1] = {
                path = path, md5 = info.md5, uuids = { id:lower() }, title = book.title,
                authors = book.authors and #book.authors > 0 and table.concat(book.authors, "\n") or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- Every book file in the library folder whose partial MD5 is known:
-- { { path, md5 }, … }, sorted. With links() and inCatalog(), it lets
-- Concordance withdraw a link for a file that's no longer matched.
function Library.folderFiles()
    local out = {}
    for path, info in pairs(Library.file_info or {}) do
        if type(info) == "table" and info.md5 then out[#out + 1] = { path = path, md5 = info.md5 } end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

--- Whether the catalog (as last read) has a book with this ID.
function Library.inCatalog(id)
    if type(id) ~= "string" then return false end
    id = id:lower()
    if Library.catalog_ids_of ~= Library.catalog then
        local set = {}
        for _i, b in ipairs(Library.catalog or {}) do set[b.id:lower()] = true end
        Library.catalog_ids, Library.catalog_ids_of = set, Library.catalog
    end
    return Library.catalog_ids[id] == true
end

local STATUS_TEXT = { complete = _("Finished"), reading = _("Reading"), abandoned = _("On hold") }

--- A line for a cloud book's details sheet: "Finished · ★★★★☆ · Last read
-- 12 Oct 2026 on Kobo Forma", or nil when Concordance knows nothing of it.
function Library.stateText(id)
    local st = Library.bookState(id)
    if not st then return nil end
    local parts = {}
    if st.status and STATUS_TEXT[st.status] then parts[#parts + 1] = STATUS_TEXT[st.status] end
    local rating = tonumber(st.rating)
    if rating and rating >= 1 and rating <= 5 then
        rating = math.floor(rating)
        parts[#parts + 1] = string.rep("★", rating) .. string.rep("☆", 5 - rating)
    end
    if st.last_read then
        local when = os.date("%d %b %Y", st.last_read):gsub("^0", "")
        local Identity = Library.identity()
        if Identity and st.last_device == Identity.THIS_DEVICE then
            parts[#parts + 1] = T(_("Last read %1 on this device"), when)
        elseif type(st.last_device) == "string" then
            parts[#parts + 1] = T(_("Last read %1 on %2"), when, st.last_device)
        else
            parts[#parts + 1] = T(_("Last read %1"), when)
        end
    end
    return #parts > 0 and table.concat(parts, " · ") or nil
end
Virtual.stateText = function(id)
    local ok, text = pcall(Library.stateText, id)
    if not ok then logger.warn("CloudLibrary: reading the book's state from Concordance:", text) end
    return ok and text or nil
end
Badge.cloudState = function(path)
    local book = Virtual.by_path[path]
    local st = book and Library.bookState(book.id)
    return st and st.status
end

function Library.installHistory()
    History.install{
        folder = Library.folder,
        matched = function() return Library.matched end,
        save = Library.save,
        saved = function() return Library.settings().history_cloud end,
    }
end

function Library.installDeleteHooks()
    local FileManager = require("apps/filemanager/filemanager")
    -- The caller redraws the listing after deleteFile() returns: the book's
    -- cloud entry is back by then.
    Guard.hook("library", FileManager, "deleteFile", function(orig, self, file, ...)
        local path = libraryPath(file)
        if path then History.deleting(path, idForPath(path)) end
        local ok = orig(self, file, ...)
        if ok and path and not Virtual.isVirtual(path) then
            local changed = Library.unmatch({ path })
            -- The history entry moves to the cloud entry before the caller
            -- redraws, so a "last read" sort keeps the book in its place.
            Guard.call("history", History.reconcile)
            showCloudInViews(changed)
            reloadSoon(true, next(changed) and homePaths(changed) or { path })
        end
        return ok
    end, "FileManager:deleteFile")
    -- deleteSelectedFiles() redraws the listing itself, so the cloud entries
    -- go back first; those for files it couldn't delete are taken out again.
    Guard.hook("library", FileManager, "deleteSelectedFiles", function(orig, self, ...)
        local paths = {}
        for path in pairs(self.selected_files or {}) do
            if inLibrary(path) then
                paths[#paths + 1] = path
                History.deleting(path, idForPath(path))
            end
        end
        local changed = #paths > 0 and Library.unmatch(paths) or {}
        local r = orig(self, ...)
        Library.restoreMatched(changed)
        if #paths > 0 then
            local gone = {}
            for path, id in pairs(changed) do
                if not Library.matched[id] then gone[path] = id end
            end
            showCloudInViews(gone)
            reloadSoon(true, homePaths(gone))
        end
        return r
    end, "FileManager:deleteSelectedFiles")
end

--- Full details for the details sheet (summary, formats...).
function Library.bookDetails(id)
    local server = Library.server()
    if not server then return nil end
    local store = openStore(server)
    local book = store:getBook(id)
    store:close()
    return book
end

-- Syncing ----------------------------------------------------------------------

-- Automatic sync turned off with the old switch: both schedules "never".
local function autoSyncOff(s)
    return s.auto_sync == false
end

--- "1h", "3h", "6h", "12h", "daily" or "never".
function Library.quickSyncMode()
    local s = Library.settings()
    if QUICK_INTERVALS[s.quick_sync] or s.quick_sync == "never" then return s.quick_sync end
    return autoSyncOff(s) and "never" or "1h"
end

--- "daily", "weekly" or "never".
function Library.fullSyncMode()
    local s = Library.settings()
    if FULL_INTERVALS[s.full_sync] or s.full_sync == "never" then return s.full_sync end
    return autoSyncOff(s) and "never" or "weekly"
end

local function quickSyncText(mode)
    return ({ ["1h"] = _("every hour"), ["3h"] = _("every 3 hours"), ["6h"] = _("every 6 hours"),
        ["12h"] = _("every 12 hours"), daily = _("daily"), never = _("never") })[mode]
end

local function fullSyncText(mode)
    return ({ daily = _("daily"), weekly = _("weekly"), never = _("never") })[mode]
end

-- What a job is called in messages ("Quick sync", "Full sync"...).
local function jobName(mode, escalated)
    if escalated then mode = "full" end
    return ({ quick = _("quick sync"), full = _("full sync"), scan = _("folder check"),
        covers = _("cover download"), prefetch = _("cover download") })[mode] or mode
end

local function runJob(server, folder, mode, db_path, wal, covers_dir, opts)
    local Sync = require("cloudlibrary/sync")
    local Http = require("cloudlibrary/http")
    local result = { mode = mode }
    local store = Store.open(db_path, wal)
    local ok, err = pcall(function()
        store:fillMatchKeys() -- once, after the upgrade to schema 5
        if mode == "covers" or mode == "prefetch" then
            util.makePath(covers_dir)
            -- In batches: if a job dies, only its batch is cut short.
            local batch = { limit = PREFETCH_COVERS, deadline = os.time() + PREFETCH_SECONDS, track = true }
            if mode == "prefetch" then
                result.covers = Covers.prefetch(Http.fetcher(server), server.url, store, covers_dir, batch)
            else
                -- "Download missing covers": also retry covers that failed
                -- before it started.
                batch.retry_before = opts.retry_before
                result.covers = Covers.downloadMissing(Http.fetcher(server), server.url, store, covers_dir, batch)
            end
            result.covers.results = nil
            return
        end
        if mode ~= "scan" then
            local sync = Sync.new{ store = store, root = server.url, fetch = Http.fetcher(server) }
            local r, serr
            if mode == "full" then
                r, serr = sync:full()
            else
                r, serr = sync:quick()
                local last_full = tonumber(store:getMeta("last_full_sync")) or 0
                local interval = FULL_INTERVALS[Library.fullSyncMode()]
                if r and (r.needs_full or (interval and os.time() - last_full > interval)) then
                    r, serr = sync:full()
                    if r then r.escalated = true end
                end
            end
            result.sync, result.error = r, serr
            -- Removed books, and covers replaced by a new link.
            if r then Covers.cleanup(store, covers_dir) end
        end
        if folder then
            local t0 = Timing.start()
            result.scanned, result.removed = Matcher.scan(folder, store)
            result.scan_ms = Timing.since(t0)
        end
    end)
    store:close()
    if not ok then result.error = tostring(err) end
    return result
end

function Library.isSyncing()
    return Library.job ~= nil
end

local function notify(text)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

local function describeResult(r)
    if r.error then
        return T(_("Cloud library: %1 failed: %2"), jobName(r.mode, r.sync and r.sync.escalated), r.error)
    end
    if r.mode == "covers" and r.covers then
        local n = r.covers.fetched_total or r.covers.fetched
        local same = r.covers.unchanged_total or r.covers.unchanged or 0
        if r.covers.network_error then
            return T(_("Cloud library: %1 covers downloaded, then the network was lost."), n)
        end
        if same > 0 then
            return T(_("Cloud library: %1 covers downloaded, %2 unchanged."), n, same)
        end
        return T(_("Cloud library: %1 covers downloaded."), n)
    end
    local s = r.sync
    if not s then return _("Cloud library: device books checked.") end
    if s.deleted ~= nil then
        return T(_("Cloud library: %1 books (%2 new, %3 removed)."), s.total, s.added, s.deleted)
    end
    if s.added > 0 then return T(_("Cloud library: %1 new books."), s.added) end
    return _("Cloud library is up to date.")
end

--- Starts a sync in a subprocess. mode: "quick", "full", "scan" (local
-- files only), "covers" (all missing covers) or "prefetch" (some). quiet: no notifications unless something changed or failed.
-- opts: carried from one cover batch to the next (see pollJob).
function Library.sync(mode, quiet, opts)
    if Library.job then
        if not quiet then
            notify(T(_("Cloud library: a %1 is already running."), jobName(Library.job.mode)))
        end
        return false
    end
    local server, folder = Library.server(), Library.folder()
    if not server then
        if not quiet then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Choose your library's OPDS catalog first: Cloud library → Catalog."),
            })
        end
        return false
    end
    opts = opts or {}
    if mode == "covers" and not opts.retry_before then
        opts.retry_before, opts.manual = os.time(), not quiet
    end
    local db_path, wal, covers_dir = Library.dbPath(server), Device:canUseWAL(), Library.coversDir(server)
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local result = runJob(server, folder, mode, db_path, wal, covers_dir, opts)
        ffiutil.writeToFD(child_fd, require("dump")(result), true)
    end, true)
    if not pid then
        if not quiet then notify(T(_("Cloud library: %1 failed: %2"), jobName(mode), tostring(fd))) end
        return false
    end
    Library.job = { pid = pid, fd = fd, mode = mode, quiet = quiet, opts = opts, db_path = db_path,
        started = os.time(), t0 = Timing.start() }
    if not quiet and mode == "covers" then
        notify(_("Cloud library: downloading covers…"))
    elseif not quiet and mode == "full" then
        notify(_("Cloud library: full sync…"))
    elseif not quiet and mode ~= "scan" then
        notify(_("Cloud library: quick sync…"))
    end
    UIManager:scheduleIn(1, Library.poll)
    return true
end

-- A folder check that found no new, changed or deleted files, or a cover
-- download that got nothing, leaves the listing as it is: skip reloading.
local function listingMayHaveChanged(mode, r)
    if r.error then return true end
    if mode == "scan" then return (r.scanned or 0) > 0 or (r.removed or 0) > 0 end
    if mode == "prefetch" or mode == "covers" then
        return not r.covers or (r.covers.fetched or 0) > 0 or (r.covers.failed or 0) > 0
    end
    return true
end

local function pollJob()
    local job = Library.job
    if not job then return end
    if not ffiutil.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(1, Library.poll)
        return
    end
    local data = ffiutil.readAllFromFD(job.fd)
    Library.job = nil
    local result
    local chunk = data and data ~= "" and loadstring("return " .. data, "sync result")
    if chunk then
        setfenv(chunk, {})
        local ok, res = pcall(chunk)
        result = ok and type(res) == "table" and res or nil
    end
    local is_covers = job.mode == "covers" or job.mode == "prefetch"
    local crashes = 0
    if not result and is_covers then
        -- The job died (an image that crashes the decoder, or killed):
        -- skip the cover it was on and carry on, unless that keeps happening.
        local store = Store.open(job.db_path, Device:canUseWAL())
        local id = Covers.recoverCrash(store)
        local book = id and store:getBook(id)
        store:close()
        crashes = (job.opts.crashes or 0) + 1
        logger.warn("CloudLibrary: cover download stopped unexpectedly, on book", id, book and book.title)
        if id and crashes <= MAX_CRASHES then
            result = { mode = job.mode, covers = { fetched = 0, failed = 1, more = true } }
        else
            result = { mode = job.mode, error = _("it stopped unexpectedly") }
        end
    end
    result = result or { mode = job.mode, error = _("it stopped unexpectedly") }
    result.finished = os.time()
    Library.last_result = result
    logger.info("CloudLibrary: sync done", result)
    local label = ({ quick = "sync (quick)", full = "sync (full)", scan = "folder check",
        covers = "covers (all)", prefetch = "covers (prefetch)" })[job.mode] or job.mode
    if result.sync and result.sync.escalated then label = "sync (full)" end
    Timing.record(label .. ": job", Timing.since(job.t0), "in the background, from start to result (checked every second)")
    if result.sync then Timing.recordAll(result.sync.timing, label .. ": ") end
    if result.covers then Timing.recordAll(result.covers.timing, label .. ": ") end
    if result.scan_ms then
        Timing.record("folder check: scan files", result.scan_ms,
            string.format("%d files read", result.scanned or 0))
    end
    if listingMayHaveChanged(job.mode, result) then Library.load() end
    local changed = result.sync and ((result.sync.added or 0) > 0 or (result.sync.deleted or 0) > 0)
    -- Cover downloads go in batches: "Download missing covers" until done,
    -- and after a sync while backfilling (most covers were missing).
    local covers = is_covers and result.covers
    if covers then
        covers.fetched_total = (job.opts.fetched or 0) + (covers.fetched or 0)
        covers.unchanged_total = (job.opts.unchanged or 0) + (covers.unchanged or 0)
    end
    local more = covers and covers.more and not result.error and Covers.canFetch()
    local quiet = job.quiet and not job.opts.manual
    if not more and (not quiet or result.error or changed) then
        if (job.mode ~= "scan" and job.mode ~= "prefetch") or result.error then
            notify(describeResult(result))
        end
    end
    if covers and covers.backfill_done then
        notify(T(_("Cloud library: all %1 covers downloaded."), Library.stats.covers or 0))
    end
    if more then
        Library.sync(job.mode, true, { manual = job.opts.manual, retry_before = job.opts.retry_before,
            fetched = covers.fetched_total, unchanged = covers.unchanged_total, crashes = crashes })
    elseif result.sync and not result.error and Covers.canFetch() then
        -- After a sync, download some missing covers (newest books first).
        Library.sync("prefetch", true)
    end
end

--- Marks every downloaded cover out of date and downloads them all again
-- (after a confirmation).
function Library.refreshCovers()
    local server = Library.server()
    if not server then return end
    if Library.job then
        notify(T(_("Cloud library: a %1 is already running."), jobName(Library.job.mode)))
        return
    end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("Check all %1 covers for changes?\n\nThis runs in the background and can take a while."),
            Library.stats and Library.stats.covers or 0),
        ok_text = _("Refresh"),
        ok_callback = function()
            local store = openStore(server)
            local n = store:markCoversStale()
            store:close()
            logger.info("CloudLibrary: refreshing", n, "covers")
            Library.load()
            Library.sync("covers")
        end,
    })
end

--- Called when the file browser opens: load, then sync if it's due.
-- The automatic sync due now: "quick", "full" or nil. A quick sync also
-- runs a full sync when one is due, so "full" only when quick syncs are off.
local function syncDue()
    local server = Library.server()
    if not server then return nil end
    local quick, full = QUICK_INTERVALS[Library.quickSyncMode()], FULL_INTERVALS[Library.fullSyncMode()]
    if not quick and not full then return nil end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return nil end
    local store = openStore(server)
    local last = tonumber(store:getMeta("last_sync")) or 0
    local last_full = tonumber(store:getMeta("last_full_sync")) or 0
    store:close()
    local now = os.time()
    if quick and now - last > quick then return "quick" end
    if full and now - last_full > full then return quick and "quick" or "full" end
    return nil
end

--- Starts the automatic sync that's due, if any.
function Library.syncIfDue()
    if Library.job then return false end
    local mode = syncDue()
    return mode ~= nil and Library.sync(mode, true)
end

-- Even without syncing, check the folder for new or changed files.
local function backgroundCheck()
    if Library.job or not Library.server() then return end
    Library.sync(syncDue() or "scan", true)
end
local scheduledCheck = Guard.task("jobs", backgroundCheck)

--- The file browser opened: at startup, and again each time a book is closed.
function Library.onFileManagerReady()
    local t_start = Timing.start()
    Library.identity() -- listens for Concordance's changes, once it's there
    local server, folder = Library.server(), Library.folder()
    -- Reopened (after reading): the cloud books are still loaded. The
    -- background check below reloads them if files changed.
    local reopened = Library.loaded_key ~= nil
        and Library.loaded_key == loadKey(server, folder, Library.settings())
    if not reopened then Library.load() end
    if server then
        UIManager:unschedule(scheduledCheck)
        UIManager:scheduleIn(CHECK_DELAY, scheduledCheck)
    end
    Timing.record(reopened and "startup: plugin (reopened)" or "startup: plugin", Timing.since(t_start),
        reopened and "catalog already loaded" or "catalog load")
end

function Library.poll()
    return Guard.call("jobs", pollJob)
end

-- Downloading --------------------------------------------------------------------

--- Downloads a cloud book into the library folder. opts: { ext = format to
-- use (default: the best one), open = open it when done }.
function Library.download(id, opts)
    opts = opts or {}
    local server, folder = Library.server(), Library.folder()
    local book = server and Library.bookDetails(id)
    if not (book and folder) then return false end
    local choices = Downloads.choices(book.formats)
    local format = choices[1]
    for _i, c in ipairs(choices) do
        if c.ext == opts.ext then format = c end
    end
    if not format then
        notify(T(_("Cloud library: no downloadable format for %1."), book.title or id))
        return false
    end
    if Downloads.isQueued(id) then
        notify(T(_("Cloud library: already downloading %1."), book.title or id))
        return false
    end
    local url = require("cloudlibrary/sync").resolve(server.url, format.href)
    local function go()
        local name = Downloads.fileName(book, format.ext, folder)
        local path = folder .. "/" .. name
        notify(T(_("Downloading %1…"), book.title or name))
        Downloads.start{
            server = server, url = url, path = path, book = book,
            on_done = function(result) Library.downloaded(book, result, opts) end,
        }
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(go)
    return true
end

function Library.downloaded(book, result, opts)
    if result.error then
        Timing.record("download: failed", result.ms or 0, book.title)
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Couldn't download %1:\n%2"), book.title or book.id, result.error),
        })
        return
    end
    local attr = Downloads.finish(result.path, book)
    Timing.record("download: book", result.ms or 0,
        string.format("%.1f MB, %s", (result.size or 0) / 1048576, result.path:match("[^/]+$")))
    -- Link the file to the catalog book now, rather than when the folder is
    -- next checked, so its cloud entry goes away at once.
    local server = Library.server()
    if server and attr then
        local store = openStore(server)
        store:setLocalFile(result.path, {
            mtime = attr.modification, size = attr.size, uuids = { book.id:lower() },
            title = book.title, authors = book.authors, md5 = Matcher.partialMD5(result.path),
        })
        -- The file has the server's current cover; the cover kept for the
        -- cloud entry (shown again if the book is deleted) may be older.
        store:markCoversStale({ book.id })
        store:close()
    end
    local cloud_path
    for _i, b in ipairs(Virtual.books) do
        if b.id == book.id then cloud_path = b.path; break end
    end
    Library.load() -- redraws the library folder if it's shown
    for _i, b in ipairs(Library.catalog or {}) do
        if b.id == book.id then
            if b.cover_stale then Covers.request({ b }) end
            break
        end
    end
    if cloud_path then
        -- Other views listing the book (Home, Authors, Series, ...) show the file.
        local ok, err = pcall(ZenSource.downloaded, cloud_path, result.path)
        if not ok then logger.warn("CloudLibrary: redrawing views after a download:", err) end
    end
    -- Concordance reads the new file's identity before it's first opened, so
    -- other versions' highlights, status... apply at once.
    local Identity = Library.identity()
    if Identity and type(Identity.fileAdded) == "function" then
        local t0 = Timing.start()
        Identity.fileAdded(result.path)
        Timing.record("download: book identity", Timing.since(t0), result.path:match("[^/]+$"))
    end
    notify(T(_("Downloaded %1."), book.title or book.id))
    if opts.open then
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            require("apps/filemanager/filemanagerutil").openFile(FileManager.instance, result.path)
        else
            require("apps/reader/readerui"):showReader(result.path)
        end
    end
end

--- Buttons for a cloud book's details sheet, one action per row as in
-- ZenOS's book menu (tapping outside closes it). close() closes the sheet.
function Library.detailsButtons(id, full, close)
    local Details = require("cloudlibrary/details")
    local choices = Downloads.choices(full and full.formats)
    local busy = Downloads.isQueued(id)
    local first = choices[1]
    local label = first and #choices > 1 and first.ext:upper() or nil
    local rows = {
        {{
            text = Details.label("download", label and T(_("Download %1"), label) or _("Download")),
            align = "left",
            enabled = first ~= nil and not busy,
            callback = function()
                close()
                Library.download(id, { ext = first and first.ext })
            end,
        }},
        {{
            text = Details.label("reading", _("Download & read")),
            align = "left",
            enabled = first ~= nil and not busy,
            callback = function()
                close()
                Library.download(id, { ext = first and first.ext, open = true })
            end,
        }},
    }
    for i = 2, math.min(#choices, 4) do
        local c = choices[i]
        table.insert(rows, {{
            text = Details.label("download", T(_("Download %1"), c.ext:upper())),
            align = "left",
            enabled = not busy,
            callback = function()
                close()
                Library.download(id, { ext = c.ext })
            end,
        }})
    end
    return rows
end
Virtual.detailsButtons = function(...)
    return Guard.wrapCallbacks(Library.detailsButtons(...))
end

-- Network ----------------------------------------------------------------------

--- Wi-Fi connected: books drawn while offline got placeholder covers, so
-- redraw the library page (their covers are then asked for), and sync if
-- it's due.
function Library.onNetworkConnected()
    for _i, b in ipairs(Virtual.books) do b.cover_retry_at = nil end
    UIManager:scheduleIn(1, Guard.task("jobs", function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        if not (fc and Virtual.folder and fc.path) then return end
        if (fc.path:gsub("/+$", "")) ~= Virtual.folder then return end
        -- Only when the file browser is what's on screen (not ZenOS's Home
        -- page, a dialog's parent, or the reader).
        if UIManager:getTopmostVisibleWidget() ~= fm then return end
        Timing.record("network: redraw library", 0, "after Wi-Fi connected", true)
        fc:updateItems(1, true)
    end))
    Library.syncIfDue()
end

-- Menu -------------------------------------------------------------------------

local function ago(t)
    t = tonumber(t)
    if not t then return _("never") end
    local d = os.time() - t
    if d < 90 then return _("just now") end
    if d < 90 * 60 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 36 * 3600 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return T(_("%1 days ago"), math.floor(d / 86400))
end

function Library.statusText()
    local server = Library.server()
    local lines = {}
    if not server then
        local problems = Guard.statusText()
        return _("No catalog chosen.") .. (problems ~= "" and ("\n\n" .. problems) or "")
    end
    table.insert(lines, T(_("Catalog: %1"), server.title or server.url))
    table.insert(lines, T(_("Folder: %1"), Library.folder() or "?"))
    local store = openStore(server)
    local last, last_full = store:getMeta("last_quick_sync"), store:getMeta("last_full_sync")
    store:close()
    local st = Library.stats
    if st.catalog then
        table.insert(lines, T(_("Books in catalog: %1"), st.catalog))
        table.insert(lines, T(_("On this device: %1"), st.on_device))
        table.insert(lines, T(_("Shown as cloud books: %1"), st.cloud))
        table.insert(lines, T(_("Files in the folder not in the catalog: %1"), st.unmatched_files))
        table.insert(lines, T(_("Covers downloaded: %1 of %2"), st.covers, st.covers_available))
        if (st.covers_failed or 0) > 0 then
            table.insert(lines, T(_("Covers the server couldn't provide: %1 (tried again daily)"), st.covers_failed))
        end
    end
    table.insert(lines, T(_("Last quick sync: %1"), ago(last)))
    table.insert(lines, T(_("Last full sync: %1"), ago(last_full)))
    table.insert(lines, T(_("Quick sync: %1"), quickSyncText(Library.quickSyncMode())))
    table.insert(lines, T(_("Full sync: %1"), fullSyncText(Library.fullSyncMode())))
    local r = Library.last_result
    if r and r.error then
        table.insert(lines, T(_("Last error (%1): %2"), jobName(r.mode, r.sync and r.sync.escalated), r.error))
    end
    local problems = Guard.statusText()
    if problems ~= "" then
        table.insert(lines, "")
        table.insert(lines, _("Compatibility:"))
        table.insert(lines, problems)
    end
    if Library.job then
        local mode = Library.job.mode
        table.insert(lines, ({ quick = _("Quick sync running…"), full = _("Full sync running…"),
            scan = _("Checking the folder…") })[mode] or _("Downloading covers…"))
    end
    return table.concat(lines, "\n")
end

function Library.menuItems(plugin)
    return Guard.wrapCallbacks({ Library.menuEntry(plugin) })[1]
end

function Library.menuEntry(plugin)
    return {
        text = _("Cloud library"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local has_server = function() return Library.server() ~= nil end
            local items = {
                -- Syncing
                {
                    text = _("Quick sync now"),
                    help_text = _("Adds books new to the catalog since the last quick sync. Runs a full sync instead if the number of books changed or a scheduled full sync is due."),
                    enabled_func = has_server,
                    callback = function() Library.sync("quick") end,
                },
                {
                    text = _("Full sync now"),
                    help_text = _("Reads the whole catalog again: picks up edited and removed books and series. A book whose file changed on the server (as a new cover does) gets its cover downloaded again."),
                    enabled_func = has_server,
                    callback = function() Library.sync("full") end,
                },
                {
                    text = _("Download missing covers"),
                    help_text = _("Downloads every cover not on this device yet, in the background, including covers found changed on the server. Covers are otherwise downloaded as you browse, and some after each quick or full sync."),
                    enabled_func = has_server,
                    callback = function() Library.sync("covers") end,
                },
                {
                    text = _("Refresh all covers"),
                    help_text = _("Checks every cover with the server now and downloads the ones that changed (the first time, every cover is downloaded again). Use it if some cloud books show an old cover. The old covers stay until their new ones arrive."),
                    enabled_func = has_server,
                    callback = function() Library.refreshCovers() end,
                },
                {
                    text_func = function()
                        return T(_("Quick sync: %1"), quickSyncText(Library.quickSyncMode()))
                    end,
                    help_text = _("How often a quick sync looks for new books, when the file browser opens or Wi-Fi connects (Wi-Fi isn't turned on for it)."),
                    sub_item_table_func = function()
                        local modes = {}
                        for _i, mode in ipairs(QUICK_SYNC_MODES) do
                            table.insert(modes, {
                                text = quickSyncText(mode),
                                checked_func = function() return Library.quickSyncMode() == mode end,
                                radio = true,
                                callback = function() Library.save("quick_sync", mode) end,
                            })
                        end
                        return modes
                    end,
                },
                {
                    text_func = function()
                        return T(_("Full sync: %1"), fullSyncText(Library.fullSyncMode()))
                    end,
                    help_text = _("How often a full sync rereads the whole catalog, picking up books edited on the server (titles, series, covers). A quick sync that finds the number of books changed runs a full sync anyway."),
                    sub_item_table_func = function()
                        local modes = {}
                        for _i, mode in ipairs(FULL_SYNC_MODES) do
                            table.insert(modes, {
                                text = fullSyncText(mode),
                                checked_func = function() return Library.fullSyncMode() == mode end,
                                radio = true,
                                callback = function() Library.save("full_sync", mode) end,
                            })
                        end
                        return modes
                    end,
                    separator = true,
                },
                -- Setup
                {
                    text_func = function()
                        local s = Library.server()
                        return T(_("Catalog: %1"), s and (s.title or s.url) or _("none"))
                    end,
                    help_text = _("Your library's catalog, from those added in KOReader's OPDS catalog plugin. Choosing one runs a full sync."),
                    sub_item_table_func = Library.serverMenu,
                },
                {
                    text_func = function() return T(_("Folder: %1"), Library.folder() or "?") end,
                    help_text = _("Where cloud books are listed and downloaded to. Books already in this folder (not its subfolders) are recognised as catalog books, so they aren't listed twice."),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local PathChooser = require("ui/widget/pathchooser")
                        UIManager:show(PathChooser:new{
                            select_directory = true,
                            select_file = false,
                            path = Library.folder() or "/",
                            onConfirm = function(path)
                                local old = Library.folder()
                                showCatalog(old, {})
                                Library.save("folder", path)
                                Library.load()
                                Library.sync("scan", true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                    separator = true,
                },
                -- Display
                {
                    text = _("Show cloud books"),
                    help_text = _("Lists catalog books that aren't on this device in the folder, ready to download. Turn this off before removing the plugin, so the file browser forgets the cloud books."),
                    checked_func = function() return Library.settings().show ~= false end,
                    check_callback_updates_menu = true,
                    callback = function(touchmenu_instance)
                        local show = Library.settings().show == false
                        Library.save("show", show)
                        if show then
                            Library.loadShowingProgress(touchmenu_instance)
                        else
                            Library.load()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end
                    end,
                },
                {
                    text = _("Mark cloud books"),
                    help_text = _("A cloud on the cover of books that are only in your cloud library."),
                    checked_func = function() return Library.settings().badge_cloud ~= false end,
                    callback = function()
                        Library.save("badge_cloud", Library.settings().badge_cloud == false)
                        Badge.cloud_enabled = Library.settings().badge_cloud ~= false
                        Library.repaint()
                    end,
                },
                {
                    text = _("Mark books on this device"),
                    help_text = _("A check mark on the cover of downloaded books that are in your cloud library."),
                    checked_func = function() return Library.settings().badge_local == true end,
                    callback = function()
                        Library.save("badge_local", Library.settings().badge_local ~= true)
                        Badge.local_enabled = Library.settings().badge_local == true
                        Library.repaint()
                    end,
                },
                {
                    text = _("Mark books not in the cloud library"),
                    help_text = _("A crossed-out cloud on the cover of books in the library folder that aren't in your cloud library. Books in other folders aren't checked."),
                    checked_func = function() return Library.settings().badge_noncloud == true end,
                    callback = function()
                        Library.save("badge_noncloud", Library.settings().badge_noncloud ~= true)
                        Badge.noncloud_enabled = Library.settings().badge_noncloud == true
                        Library.repaint()
                    end,
                },
                {
                    text = _("Include cloud books in Authors, Series and Tags"),
                    help_text = _("Lists cloud books in ZenOS's Authors, Series and Tags tabs, as well as downloaded ones."),
                    checked_func = function() return Library.settings().zenos_groups ~= false end,
                    callback = function()
                        Library.save("zenos_groups", Library.settings().zenos_groups == false)
                        ZenSource.changed()
                    end,
                },
                {
                    text = _("Include cloud books in file search"),
                    help_text = _("KOReader's file search also finds cloud books, by title, author or series."),
                    checked_func = function() return Library.settings().search ~= false end,
                    callback = function()
                        Library.save("search", Library.settings().search == false)
                        Search.enabled = Library.settings().search ~= false
                    end,
                },
            }
            items[#items].separator = true
            -- Diagnostics
            table.insert(items, {
                text = _("Status"),
                help_text = _("Catalog, folder, book and cover counts, last quick and full syncs, and any problems."),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(require("ui/widget/infomessage"):new{ text = Library.statusText() })
                end,
            })
            table.insert(items, {
                text = _("Timings"),
                help_text = _("How long each step took on this device, for tracking down slowness."),
                sub_item_table = {
                    {
                        text = _("Show timings"),
                        keep_menu_open = true,
                        callback = function()
                            local TextViewer = require("ui/widget/textviewer")
                            UIManager:show(TextViewer:new{
                                title = _("Cloud library timings"),
                                text = Timing.text(),
                                monospace_font = false,
                            })
                        end,
                    },
                    {
                        text = _("Reset timings"),
                        keep_menu_open = true,
                        callback = function() Timing.reset() end,
                    },
                },
            })
            if plugin then
                items[#items].separator = true
                local Updater = require("cloudlibrary/updater")
                local updates = Updater.menuItems(plugin)
                local combined = package.loaded["concordance/updates"]
                if type(combined) == "table" and combined.active and combined.active() then
                    updates[1].help_text = _("Checks Concordance too, with Concordance's updater.")
                end
                for _i, item in ipairs(updates) do table.insert(items, item) end
            end
            return items
        end,
    }
end

function Library.serverMenu()
    local items = {}
    local chosen = Library.settings().server
    for _i, s in ipairs(Library.opdsServers()) do
        table.insert(items, {
            text = s.title or s.url,
            checked_func = function()
                return type(chosen) == "table" and chosen.url == s.url
                    and (chosen.username or "") == (s.username or "")
            end,
            check_callback_closes_menu = true,
            callback = function(touchmenu_instance)
                Library.save("server", { url = s.url, username = s.username })
                chosen = Library.settings().server
                Library.loadShowingProgress(touchmenu_instance)
                Library.sync("quick")
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("Add your catalog in the OPDS catalog plugin first."),
            enabled = false,
        })
    end
    return items
end

return Library
