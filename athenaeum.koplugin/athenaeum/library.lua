--[[
Ties the pieces together: settings, the catalog store, syncing in a
subprocess, matching local files, and the virtual entries shown in the file
browser.

Settings (settings/athenaeum/settings.lua for the folder, shared.lua for
the rest; see settings.lua):
  server     { url, username } of one of KOReader's OPDS catalogs
  folder     library folder (default: KOReader's download folder, else home)
  quick_sync  automatic quick sync, when the file browser opens, on wake-up
             and when Wi-Fi connects (only while Wi-Fi is on): "never" turns
             it off; anything else (older versions' "1h"... too) is on
  full_sync  scheduled full sync: "daily", "weekly" (default) or "never"; a
             quick sync that finds the book count changed runs one anyway
  auto_sync  old on/off switch: false (and no quick_sync/full_sync) = never
  badge_cloud  cloud badge on cloud-only books (default true)
  badge_local  on-device badge on local catalog books (default false)
  badge_noncloud  badge on books in the folder not in the catalog (default false)
  search     cloud books in file search results (default true)

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

local Badge = require("athenaeum/badge")
local Covers = require("athenaeum/covers")
local Downloads = require("athenaeum/downloads")
local ZenSource = require("athenaeum/zenos_source")
local Guard = require("athenaeum/guard")
local History = require("athenaeum/history")
local Matcher = require("athenaeum/matcher")
local Names = require("athenaeum/names")
local Search = require("athenaeum/search")
local Settings = require("athenaeum/settings")
local Store = require("athenaeum/store")
local Timing = require("athenaeum/timing")
local Virtual = require("athenaeum/virtual")

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
local FULL_INTERVALS = { daily = 24 * HOUR, weekly = 7 * 24 * HOUR }
local FULL_SYNC_MODES = { "daily", "weekly", "never" }
local PREFETCH_COVERS = 300          -- covers a batch after each sync, newest first (all, in batches, on a first sync)
local PREFETCH_SECONDS = 180        -- (a batch, also for "Download missing covers")
local MAX_CRASHES = 3               -- cover jobs dying in a row before giving up
local CHECK_DELAY = 3                -- s after the file browser opens: let it draw first
local FULL_SYNC_DELAY = 120         -- s before an automatic full sync that's only due by time (see deferFullSync)
local FULL_SYNC_RETRY = 30          -- s to wait when another job is still running then

-- Settings ----------------------------------------------------------------------

-- In settings/athenaeum/settings.lua (see settings.lua).
function Library.settings()
    return Settings.all()
end

function Library.save(key, value)
    Settings.save(key, value)
end

--- Redraws the file browser after a badge setting changed (ZenOS repaints
-- its covers' badges).
function Library.repaint()
    ZenSource.badgesChanged()
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
    local dir = DataStorage:getSettingsDir() .. "/athenaeum"
    util.makePath(dir)
    return dir .. "/" .. serverKey(server) .. ".sqlite3"
end

function Library.coversDir(server)
    return DataStorage:getSettingsDir() .. "/athenaeum/" .. serverKey(server) .. "-covers"
end

local function openStore(server)
    return Store.open(Library.dbPath(server), Device:canUseWAL())
end

-- Loading into the file browser --------------------------------------------------

-- ZenOS redraws the folder only when cloud books shown in it changed
-- (Virtual.notifyChanged tells it which).
local function showCatalog(folder, cloud)
    Virtual.setCatalog(folder, cloud)
    -- A refetched cover keeps its file name: don't show the old image.
    Virtual.forgetDecodedCovers()
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

-- path -> catalog ID for the library's files of catalog books (matched files
-- and second copies), built when first needed from the matches it names;
-- nil after they change in place (unmatch, restoreMatched).
local path_ids, path_ids_of

--- The catalog ID of a file in the library folder, or nil.
local function catalogIdForFile(path)
    if not (Library.on_device and Library.on_device[path]) then return nil end
    if not path_ids or path_ids_of[1] ~= Library.matched or path_ids_of[2] ~= Library.copies then
        path_ids, path_ids_of = {}, { Library.matched, Library.copies }
        for p, id in pairs(Library.copies or {}) do path_ids[p] = id end
        for id, p in pairs(Library.matched or {}) do path_ids[p] = id end
    end
    return path_ids[path]
end

-- What a load depends on, besides the catalog and the folder's files.
local function loadKey(server, folder, s)
    return table.concat({ server and server.url or "", server and server.username or "",
        folder or "" }, "\0")
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
    if not server or not folder then
        Library.stats = {}
        Library.catalog = {}
        Library.matched, Library.on_device, Library.not_in_catalog = {}, {}, {}
        Library.copies = {}
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
    local unnamed = store:unnamedFormats()
    store:close()
    Timing.record("catalog: read database", Timing.since(t0), #books .. " books")
    t0 = Timing.start()
    local matched, unmatched, by_title, copies, file_names = Matcher.match(folder, files, books)
    Timing.record("catalog: match local files", Timing.since(t0))
    local renamed = Library.nameBooks(server, books, matched, file_names, unnamed)
    local cloud = {}
    for _i, b in ipairs(books) do
        if not matched[b.id] then table.insert(cloud, b) end
    end
    Library.catalog = books -- every catalog book, in the database's order
    Library.matched = matched
    Library.copies = copies or {}
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
    logger.info("Athenaeum: loaded", Library.stats)
    t0 = Timing.start()
    showCatalog(folder, cloud)
    Library.followRenames(folder, renamed)
    Guard.call("history", History.reconcile)
    Timing.record("catalog: show in folder", Timing.since(t0))
    Timing.record("catalog: load", Timing.since(t_load),
        string.format("%d cloud books, %d on this device", #cloud, #books - #cloud))
    Library.loaded_key = loadKey(server, folder, s)
    -- Downloaded books shown with the catalog's metadata (cached rows made
    -- before it was loaded, or before it changed).
    if not Library.fixture then Guard.call("metadata", Library.refreshCatalogMetadata) end
end

--- Gives catalog books their file names (names.lua) and stores the ones
-- that changed: new books, books on the device under another name, and
-- books whose name a file took. unnamed: { [id] = formats } of the books
-- without one. Returns the changes.
function Library.nameBooks(server, books, matched, file_names, unnamed)
    local t0 = Timing.start()
    local changes = Names.assign(books, matched, file_names, {
        base = Downloads.baseStem,
        suffix = function(book) return Downloads.defaultSuffix(unnamed[book.id]) end,
    })
    if #changes > 0 then
        local store = openStore(server)
        local ok, err = pcall(store.setFileNames, store, changes)
        store:close()
        if not ok then logger.warn("Athenaeum: storing file names:", err) end
        logger.info("Athenaeum: named", #changes, "books")
    end
    Timing.record("catalog: name books", Timing.since(t0), #changes .. " changed")
    return changes
end

--- Catalog books' paths changed (STABLE_PATHS_PLAN.md: another format
-- downloaded, a file renamed outside KOReader, one of two copies deleted,
-- a file taking a cloud book's name): { { old, new }, … }. Their history
-- and collection entries follow them, and ZenOS is told both paths
-- changed (its open views are rebuilt). Collections move only to a file:
-- KOReader's collections can't hold a path without one (they drop it when
-- read).
function Library.booksMoved(moves)
    if type(moves) ~= "table" or #moves == 0 then return end
    Guard.call("history", History.moved, moves)
    local lfs = require("libs/libkoreader-lfs")
    local ReadCollection = require("readcollection")
    local paths = {}
    for _i, m in ipairs(moves) do
        local old, new = m[1], m[2]
        if type(old) == "string" and type(new) == "string" and old ~= new then
            if lfs.attributes(new, "mode") == "file" then
                local ok, err = pcall(ReadCollection.updateItem, ReadCollection, old, new)
                if not ok then logger.warn("Athenaeum: moving collection entries:", err) end
            end
            paths[#paths + 1] = old
            paths[#paths + 1] = new
        end
    end
    if #paths > 0 then
        local ok, err = pcall(ZenSource.changed, paths)
        if not ok then logger.warn("Athenaeum: telling ZenOS books moved:", err) end
    end
end

--- The books nameBooks() gave another name (a file took a cloud book's
-- name, or a book's file has a new one): their entries follow them.
function Library.followRenames(folder, changes)
    local moves = {}
    for _i, c in ipairs(changes or {}) do
        if c.old_stem and c.old_ext then
            local old = folder .. "/" .. Names.join(c.old_stem, c.old_ext)
            local new = Library.matched[c.id] or folder .. "/" .. Names.join(c.stem, c.ext)
            if old ~= new then moves[#moves + 1] = { old, new } end
        end
    end
    Library.booksMoved(moves)
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

-- After a delete, ZenOS is told of the deleted files once the catalog is
-- reloaded. It redraws the library folder once more, after the redraw of
-- whoever deleted the file (scheduled before this runs): on a Kobo that
-- one could still show the folder without the book's cloud entry, which
-- only came back on leaving and reopening the folder. Home forgets them
-- too: its rows show the deleted file until then.
local reload_scheduled = false
local deleted_paths = {}
local function reloadSoon(after_delete, paths)
    if Library.fixture then return end
    for _i, path in ipairs(paths or {}) do deleted_paths[#deleted_paths + 1] = path end
    if reload_scheduled then return end
    reload_scheduled = true
    UIManager:nextTick(function()
        reload_scheduled = false
        Guard.call("jobs", Library.load)
        if after_delete then
            local home_paths = deleted_paths
            deleted_paths = {}
            local ok, err = pcall(ZenSource.changed, home_paths)
            if not ok then logger.warn("Athenaeum: telling ZenOS about a delete:", err) end
        end
    end)
end

-- After a delete: ZenOS's open views (Home, Authors, Series, ...) show the
-- deleted files' books as cloud books, at the same paths. Told before the
-- caller redraws: ZenOS takes a deleted file out of its open group views
-- otherwise, until it next rebuilds them.
local function tellDeleted(changed)
    local paths = {}
    for path in pairs(changed) do paths[#paths + 1] = path end
    if #paths == 0 then return paths end
    local ok, err = pcall(ZenSource.changed, paths)
    if not ok then logger.warn("Athenaeum: telling ZenOS about a delete:", err) end
    return paths
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
    path_ids = nil
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
    path_ids = nil
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
        Identity.onChanged("athenaeum", function() UIManager:nextTick(Library.redrawStates) end)
    end
    return Identity
end

--- Book states changed: redraw what's shown (the badges and the details
-- are drawn from them; nothing is laid out again).
function Library.redrawStates()
    if not next(Virtual.by_path) then return end
    -- ZenOS shows the statuses itself too (in its badges, filters, Home).
    local ok, err = pcall(ZenSource.statesChanged)
    if not ok then logger.warn("Athenaeum: telling ZenOS of new book states:", err) end
    for _i, w in ipairs(UIManager._window_stack or {}) do
        if w.widget then UIManager:setDirty(w.widget, "ui") end
    end
end

--- A cloud book's state from Concordance: { status, status_at, rating,
-- last_read, last_device }, or nil.
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
    if not ok then logger.warn("Athenaeum: reading the book's state from Concordance:", text) end
    return ok and text or nil
end
-- What Concordance knows of a cloud book, or of a catalog book's file in the
-- library folder. A Concordance error just leaves it out.
local function stateForPath(path)
    local book = Virtual.by_path[path]
    local id = book and book.id or catalogIdForFile(path)
    if not id then return nil end
    local ok, st = pcall(Library.bookState, id)
    if not ok then logger.warn("Athenaeum: reading the book's state from Concordance:", st) end
    return ok and type(st) == "table" and st or nil
end
-- For ZenOS: cloud books, and the library's files (ZenOS asks only about
-- books without a sidecar, so a book opened here keeps its own).
ZenSource.state = function(path)
    local st = stateForPath(path)
    if not st or not (st.status or st.rating) then return nil end
    -- A finished book's date counts it in ZenOS's books finished this month
    -- and year (0, not known, is left out by ZenOS).
    local finished_at = st.status == "complete" and tonumber(st.status_at) or nil
    return { status = st.status, rating = st.rating, finished_at = finished_at }
end

-- For ZenOS: books read elsewhere that Concordance will put into the
-- history once nothing is open (it keeps the list, so this is cheap).
ZenSource.history = function()
    local Identity = Library.identity()
    if not Identity or type(Identity.pendingHistory) ~= "function" then return {} end
    return Identity.pendingHistory()
end

function Library.installHistory()
    History.install{
        matched = function() return Library.matched end,
        save = Library.save,
        saved = function() return Library.settings().history_cloud end,
    }
end

function Library.installDeleteHooks()
    local FileManager = require("apps/filemanager/filemanager")
    -- The caller redraws the listing after deleteFile() returns: the book's
    -- cloud entry is back by then.
    -- The book keeps its history entry: it's a cloud entry again at the
    -- same path (History.keep, afterDelete), before the caller redraws, so a
    -- "last read" sort keeps the book in its place.
    Guard.hook("library", FileManager, "deleteFile", function(orig, self, file, ...)
        local path = libraryPath(file)
        local kept = path and idForPath(path) and History.keep({ path }) or {}
        local ok = orig(self, file, ...)
        if ok and path and not Virtual.isVirtual(path) then
            local changed = Library.unmatch({ path })
            Guard.call("history", History.afterDelete, kept)
            tellDeleted(changed)
            reloadSoon(true, { path })
        end
        return ok
    end, "FileManager:deleteFile")
    -- deleteSelectedFiles() redraws the listing itself, so the cloud entries
    -- go back first; those for files it couldn't delete are taken out again.
    Guard.hook("library", FileManager, "deleteSelectedFiles", function(orig, self, ...)
        local paths = {}
        for path in pairs(self.selected_files or {}) do
            if inLibrary(path) then paths[#paths + 1] = path end
        end
        local books = {}
        for _i, path in ipairs(paths) do
            if idForPath(path) then books[#books + 1] = path end
        end
        local kept = History.keep(books)
        local changed = #paths > 0 and Library.unmatch(paths) or {}
        local r = orig(self, ...)
        Library.restoreMatched(changed)
        if #paths > 0 then
            local gone = {}
            for path, id in pairs(changed) do
                if not Library.matched[id] then gone[path] = id end
            end
            Guard.call("history", History.afterDelete, kept)
            reloadSoon(true, tellDeleted(gone))
        end
        return r
    end, "FileManager:deleteSelectedFiles")
end

-- Catalog metadata for downloaded books ------------------------------------------
--
-- A book edited in the catalog (CWA) keeps its old metadata in the copy
-- already downloaded. Rather than rewrite the file (its MD5 would change,
-- unjoining it from its sidecar and other versions), the library's books
-- are shown with the catalog's title, authors, series and tags under any
-- override made on a device (custom metadata, which Concordance syncs):
-- override, then catalog, then the file's own. Not the language (the
-- reader picks hyphenation by it, and the catalog may spell it otherwise),
-- nor the description (the listing has none). A series number only when
-- the catalog has one (Calibre-Web's feed has none): else the file's.
--
-- KOReader merges a book's custom metadata over its own in one place,
-- FileManagerBookInfo.extendProps(): the reader, CoverBrowser's cache (and
-- so ZenOS's groupings), history and search all go through it. The catalog
-- goes in there, under the custom metadata. CoverBrowser's cached rows,
-- extracted before the catalog was loaded or before it changed, are
-- brought up to date after each load (Library.refreshCatalogMetadata).

local CATALOG_FIELDS = { "title", "authors", "series", "series_index", "keywords" }

local catalog_by_id, catalog_by_id_of
local function catalogBook(id)
    if catalog_by_id_of ~= Library.catalog then
        catalog_by_id, catalog_by_id_of = {}, Library.catalog
        for _i, b in ipairs(Library.catalog or {}) do catalog_by_id[b.id] = b end
    end
    return catalog_by_id[id]
end

local function joined(list)
    return type(list) == "table" and #list > 0 and table.concat(list, "\n") or nil
end

--- The catalog's metadata for a book file in the library folder, as
-- KOReader's book props: { title, authors, series, series_index, keywords },
-- only those the catalog has; nil for other files.
function Library.catalogProps(path)
    local id = type(path) == "string" and catalogIdForFile(path)
    local book = id and catalogBook(id)
    if not book then return nil end
    local props = {}
    local function set(key, value)
        if value ~= nil and value ~= "" then props[key] = value end
    end
    set("title", book.title)
    set("authors", joined(book.authors))
    set("series", book.series)
    if book.series then set("series_index", tonumber(book.series_index)) end
    set("keywords", joined(book.tags))
    return next(props) and props or nil
end

function Library.installCatalogMetadataHook()
    if not Guard.ok("metadata") then return end
    local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok or type(BookInfo) ~= "table" then return end
    Guard.hook("metadata", BookInfo, "extendProps", function(orig, original_props, filepath, ...)
        local catalog = Library.catalogProps(filepath)
        if not catalog then return orig(original_props, filepath, ...) end
        local props = {}
        for k, v in pairs(original_props or {}) do props[k] = v end
        for k, v in pairs(catalog) do props[k] = v end
        return orig(props, filepath, ...)
    end, "FileManagerBookInfo.extendProps")
end

-- A book's custom props (its overrides), or {}.
local function customProps(path)
    local DocSettings = require("docsettings")
    local file = DocSettings.findCustomMetadataFile and DocSettings:findCustomMetadataFile(path)
    if not file then return {} end
    local custom = DocSettings.openSettingsFile(file):readSetting("custom_props")
    return type(custom) == "table" and custom or {}
end

local function same(a, b)
    if type(a) == "number" or type(b) == "number" then return tonumber(a) == tonumber(b) end
    return a == b
end

--- Brings CoverBrowser's cached metadata of the library's books up to date
-- with the catalog (rows made before it was loaded, or before it changed),
-- and tells ZenOS of the books that changed. bim: BookInfoManager (tests).
-- Returns the paths updated.
function Library.refreshCatalogMetadata(bim)
    if not Guard.ok("metadata") then return {} end
    local folder = Library.folder()
    if not folder or not next(Library.on_device or {}) then return {} end
    -- CoverBrowser's, once it's loaded (it isn't loaded for us).
    bim = bim or package.loaded["bookinfomanager"]
    if type(bim) ~= "table" or type(bim.setBookInfoProperties) ~= "function" then return {} end
    bim:openDbConnection()
    -- One query for the folder, rather than one per book.
    local rows = {}
    local stmt = bim.db_conn:prepare([[SELECT directory, filename, title, authors, series,
        series_index, keywords FROM bookinfo WHERE in_progress = 0 AND substr(directory, 1, ?) = ?;]])
    local prefix = folder:gsub("/*$", "/")
    stmt:bind(#prefix, prefix)
    local row = {}
    while stmt:step(row) do
        rows[row[1] .. row[2]] = { title = row[3], authors = row[4], series = row[5],
            series_index = row[6], keywords = row[7] }
    end
    stmt:close()
    local updated = {}
    for path in pairs(Library.on_device) do
        local have = rows[path]
        local catalog = have and Library.catalogProps(path)
        if catalog then
            local custom = customProps(path)
            local set
            for _i, key in ipairs(CATALOG_FIELDS) do
                local want = custom[key] or catalog[key]
                if want ~= nil and not same(have[key], want) then
                    set = set or {}
                    set[key] = want
                end
            end
            if set then
                bim:setBookInfoProperties(path, set)
                updated[#updated + 1] = path
            end
        end
    end
    if #updated > 0 then
        table.sort(updated)
        logger.info("Athenaeum: catalog metadata applied to", #updated, "downloaded books")
        ZenSource.changed(updated)
    end
    return updated
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

--- Whether quick syncs run automatically (when the file browser opens, on
-- wake-up and when Wi-Fi connects). Off is saved as "never", which older
-- versions read as off too; they read on (no setting) as hourly.
function Library.quickSyncOn()
    local s = Library.settings()
    if s.quick_sync == nil then return not autoSyncOff(s) end
    return s.quick_sync ~= "never" and s.quick_sync ~= false
end

function Library.setQuickSync(on)
    Library.save("quick_sync", (not on) and "never" or nil)
    -- The old switch would otherwise turn it off again; full syncs stay as they were.
    if on and autoSyncOff(Library.settings()) then
        if Library.settings().full_sync == nil then Library.save("full_sync", Library.fullSyncMode()) end
        Library.save("auto_sync", nil)
    end
end

--- "daily", "weekly" or "never".
function Library.fullSyncMode()
    local s = Library.settings()
    if FULL_INTERVALS[s.full_sync] or s.full_sync == "never" then return s.full_sync end
    return autoSyncOff(s) and "never" or "weekly"
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
    local Sync = require("athenaeum/sync")
    local Http = require("athenaeum/http")
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
            local sync = Sync.new{ store = store, root = server.url, fetch = Http.retrying(Http.fetcher(server)) }
            local r, serr
            if mode == "full" then
                r, serr = sync:full()
            else
                r, serr = sync:quick()
                local last_full = tonumber(store:getMeta("last_full_sync")) or 0
                local interval = FULL_INTERVALS[Library.fullSyncMode()]
                local due = interval and os.time() - last_full > interval
                if r and not r.needs_full and due and opts.defer_full then
                    -- Only due by time: an automatic sync leaves it for later
                    -- (see Library.deferFullSync).
                    r.full_due = true
                elseif r and (r.needs_full or due) then
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
        return T(_("Athenæum: %1 failed: %2"), jobName(r.mode, r.sync and r.sync.escalated), r.error)
    end
    if r.mode == "covers" and r.covers then
        local n = r.covers.fetched_total or r.covers.fetched
        local same = r.covers.unchanged_total or r.covers.unchanged or 0
        if r.covers.network_error then
            return T(_("Athenæum: %1 covers downloaded, then the network was lost."), n)
        end
        if same > 0 then
            return T(_("Athenæum: %1 covers downloaded, %2 unchanged."), n, same)
        end
        return T(_("Athenæum: %1 covers downloaded."), n)
    end
    local s = r.sync
    if not s then return _("Athenæum: device books checked.") end
    if s.deleted ~= nil then
        return T(_("Athenæum: %1 books (%2 new, %3 removed)."), s.total, s.added, s.deleted)
    end
    if s.added > 0 then return T(_("Athenæum: %1 new books."), s.added) end
    return _("Athenæum is up to date.")
end

--- Starts a sync in a subprocess. mode: "quick", "full", "scan" (local
-- files only), "covers" (all missing covers) or "prefetch" (some). quiet: no notifications unless something changed or failed.
-- opts: carried from one cover batch to the next (see pollJob).
function Library.sync(mode, quiet, opts)
    if Library.job then
        if not quiet then
            notify(T(_("Athenæum: a %1 is already running."), jobName(Library.job.mode)))
        end
        return false
    end
    local server, folder = Library.server(), Library.folder()
    if not server then
        if not quiet then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Choose your library's OPDS catalog first: Athenæum → Catalog."),
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
        if not quiet then notify(T(_("Athenæum: %1 failed: %2"), jobName(mode), tostring(fd))) end
        return false
    end
    Library.job = { pid = pid, fd = fd, mode = mode, quiet = quiet, opts = opts, db_path = db_path,
        started = os.time(), t0 = Timing.start() }
    if not quiet and mode == "covers" then
        notify(_("Athenæum: downloading covers…"))
    elseif not quiet and mode == "full" then
        notify(_("Athenæum: full sync…"))
    elseif not quiet and mode ~= "scan" then
        notify(_("Athenæum: quick sync…"))
    end
    UIManager:scheduleIn(1, Library.poll)
    return true
end

-- A quick sync that found no new books, or a folder check that found no new,
-- changed or deleted files, or a cover download that got nothing, leaves the
-- listing as it is: skip reloading (quick syncs run on every wake-up).
local function listingMayHaveChanged(mode, r)
    if r.error then return true end
    if mode == "scan" then return (r.scanned or 0) > 0 or (r.removed or 0) > 0 end
    if mode == "quick" and r.sync and not r.sync.escalated then
        return (r.sync.added or 0) > 0 or (r.scanned or 0) > 0 or (r.removed or 0) > 0
    end
    if mode == "prefetch" or mode == "covers" then
        return not r.covers or (r.covers.fetched or 0) > 0 or (r.covers.failed or 0) > 0
    end
    return true
end

-- After a sync: whether a cover download might find something (new books,
-- a full sync's changes, or covers still missing or due a retry).
local function coversWanted(r)
    if r.sync.escalated or r.mode == "full" or (r.sync.added or 0) > 0 then return true end
    local st = Library.stats or {}
    if not st.covers_available then return true end
    return (st.covers or 0) < st.covers_available
end

Library._listingMayHaveChanged, Library._coversWanted = listingMayHaveChanged, coversWanted -- for tests

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
        logger.warn("Athenaeum: cover download stopped unexpectedly, on book", id, book and book.title)
        if id and crashes <= MAX_CRASHES then
            result = { mode = job.mode, covers = { fetched = 0, failed = 1, more = true } }
        else
            result = { mode = job.mode, error = _("it stopped unexpectedly") }
        end
    end
    result = result or { mode = job.mode, error = _("it stopped unexpectedly") }
    result.finished = os.time()
    Library.last_result = result
    logger.info("Athenaeum: sync done", result)
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
    if result.sync and result.sync.full_due and not result.error then Library.deferFullSync() end
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
    -- An automatic sync that couldn't reach the server (even after the
    -- retry in Http.retrying) says nothing: the next automatic one tries again.
    local offline = quiet and result.error and require("athenaeum/http").isNetworkError(result.error)
    if offline then
        logger.info("Athenaeum: automatic sync couldn't reach the server:", result.error)
    end
    if not more and not offline and (not quiet or result.error or changed) then
        if (job.mode ~= "scan" and job.mode ~= "prefetch") or result.error then
            notify(describeResult(result))
        end
    end
    if covers and covers.backfill_done then
        notify(T(_("Athenæum: all %1 covers downloaded."), Library.stats.covers or 0))
    end
    if more then
        Library.sync(job.mode, true, { manual = job.opts.manual, retry_before = job.opts.retry_before,
            fetched = covers.fetched_total, unchanged = covers.unchanged_total, crashes = crashes })
    elseif result.sync and not result.error and Covers.canFetch() and coversWanted(result) then
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
        notify(T(_("Athenæum: a %1 is already running."), jobName(Library.job.mode)))
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
            logger.info("Athenaeum: refreshing", n, "covers")
            Library.load()
            Library.sync("covers")
        end,
    })
end

--- Called when the file browser opens: load, then sync if it's due.
-- The automatic sync to run now: "quick" (each time, when they're on), "full"
-- or nil. A quick sync also runs a full sync when one is due, so "full" only
-- when quick syncs are off.
local function syncDue()
    local server = Library.server()
    if not server then return nil end
    local quick, full = Library.quickSyncOn(), FULL_INTERVALS[Library.fullSyncMode()]
    if not quick and not full then return nil end
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isConnected() then return nil end
    if quick then return "quick" end
    local store = openStore(server)
    local last_full = tonumber(store:getMeta("last_full_sync")) or 0
    store:close()
    if os.time() - last_full > full then return "full" end
    return nil
end

-- An automatic full sync that's only due by time (daily or weekly) waits
-- FULL_SYNC_DELAY seconds rather than running at once. It takes a minute
-- or more of a single-core Kobo's processor and disk, which right after
-- startup or waking up is when the device is busiest (the listing being
-- built, the book being opened). One the books count calls for (books
-- removed or changed) still runs at once, and so does one asked for.
local fullSyncTask
local function deferredFullSync()
    if Library.job then
        UIManager:scheduleIn(FULL_SYNC_RETRY, fullSyncTask)
        return
    end
    if not Library.server() or not require("ui/network/manager"):isConnected() then
        return -- the next automatic sync finds it still due
    end
    Library.sync("full", true)
end
fullSyncTask = Guard.task("jobs", deferredFullSync)

--- Runs an automatic full sync in FULL_SYNC_DELAY seconds (or a little
-- later, if another job is running then).
function Library.deferFullSync()
    UIManager:unschedule(fullSyncTask)
    UIManager:scheduleIn(FULL_SYNC_DELAY, fullSyncTask)
end
Library._deferredFullSync = deferredFullSync -- for tests

-- Starts an automatic sync: one due by time, later.
local function startAutomatic(mode)
    if mode == "full" then
        Library.deferFullSync()
        return false
    end
    return Library.sync(mode, true, mode == "quick" and { defer_full = true } or nil)
end

--- Starts the automatic sync, if one is to run now (none while offline).
function Library.syncIfDue()
    if Library.job then return false end
    local mode = syncDue()
    return mode ~= nil and startAutomatic(mode)
end

-- Even without syncing, check the folder for new or changed files.
local function backgroundCheck()
    if Library.job or not Library.server() then return end
    local mode = syncDue()
    if mode == "full" then
        Library.deferFullSync()
        mode = nil
    end
    startAutomatic(mode or "scan")
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
        notify(T(_("Athenæum: no downloadable format for %1."), book.title or id))
        return false
    end
    if Downloads.isQueued(id) then
        notify(T(_("Athenæum: already downloading %1."), book.title or id))
        return false
    end
    local url = require("athenaeum/sync").resolve(server.url, format.href)
    local function go()
        local name = Library.downloadName(id, book, format.ext, folder)
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

--- Where a download goes: the cloud entry's path, with the format's suffix
-- if it isn't the one the book's name has; else (a file there meanwhile,
-- or no name) a new name, as KOReader's OPDS downloads are named.
function Library.downloadName(id, book, ext, folder)
    local named = Virtual.by_id[id]
    if named and named.file_stem then
        local suffix = Downloads.suffix(ext)
        if named.file_ext and named.file_ext:lower() == suffix then suffix = named.file_ext end
        local name = Names.join(named.file_stem, suffix)
        if not require("libs/libkoreader-lfs").attributes(folder .. "/" .. name) then return name end
    end
    return Downloads.fileName(book, ext, folder)
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
    if cloud_path == result.path then
        -- Other views listing the book (Home, Authors, Series, ...) show the
        -- file. (At another path, when a file had the book's name: the load
        -- gave the book the file's name, and booksMoved told them.)
        local ok, err = pcall(ZenSource.changed, { cloud_path })
        if not ok then logger.warn("Athenaeum: redrawing views after a download:", err) end
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
-- "unread": no status (KOReader's "new"); setting it clears the status, on
-- every device (Concordance 0.3.4).
-- Each with ZenOS's icon for it, as its "Read status" menu shows them.
local STATUS_ORDER = { "unread", "reading", "abandoned", "complete" }
local STATUS_ICON = { unread = "status", reading = "reading", abandoned = "on_hold", complete = "finished" }

--- The rows of a cloud book's "Read status" menu, drawn like ZenOS's (one
-- status per row, the current one ticked and not choosable). Choosing one
-- closes the menu (close_menu) and sets it in Concordance
-- (Identity.setBookState, with the book's info). Nil without Concordance.
function Library.statusRows(id, full, close_menu)
    local Identity = Library.identity()
    if not (Identity and type(Identity.setBookState) == "function") then return nil end
    local Details = require("athenaeum/details")
    local check = Details.icon("check") or "✓"
    local st = Library.bookState(id) or {}
    local info = { title = full and full.title, authors = full and full.authors }
    local function set(values)
        if close_menu then close_menu() end
        local ok, n, err = pcall(Identity.setBookState, id, values, info)
        if not ok or n == nil then
            logger.warn("Athenaeum: setting the book's status in Concordance:", ok and err or n)
            notify(_("Couldn't save the book's status."))
        end
    end
    local rows = {}
    local shown = STATUS_TEXT[st.status] and st.status or "unread"
    for _i, status in ipairs(STATUS_ORDER) do
        local current = shown == status
        local label = status == "unread" and _("Unread") or STATUS_TEXT[status]
        rows[#rows + 1] = {{
            text = Details.label(STATUS_ICON[status], label) .. (current and "  " .. check or ""),
            align = "left",
            enabled = not current,
            callback = function() set({ status = status ~= "unread" and status or false }) end,
        }}
    end
    return rows
end

-- With Concordance: the details sheet's "Read status" row, as in ZenOS's
-- book menu: it closes the sheet (close) and opens the status menu. Nil
-- without Concordance.
local function statusRow(id, full, close)
    local Identity = Library.identity()
    if not (Identity and type(Identity.setBookState) == "function") then return nil end
    local Details = require("athenaeum/details")
    local arrow = Details.icon("arrow_right")
    return {{
        text = Details.label("read_status", _("Read status")) .. (arrow and "  " .. arrow or ""),
        align = "left",
        callback = function()
            close()
            local menu
            local rows = Library.statusRows(id, full, function() UIManager:close(menu) end)
            if rows then menu = Details.menu(_("Read status"), Guard.wrapCallbacks(rows)) end
        end,
    }}
end

--- The rows of a cloud book's "Download" menu, drawn like ZenOS's submenus:
-- one format per row, the preferred first (Downloads.choices). Choosing one
-- closes the menu (close_menu) and downloads that format.
function Library.formatRows(id, choices, close_menu)
    local Details = require("athenaeum/details")
    local busy = Downloads.isQueued(id)
    local rows = {}
    for _i, c in ipairs(choices) do
        rows[#rows + 1] = {{
            text = Details.label("download", c.ext:upper()),
            align = "left",
            enabled = not busy,
            callback = function()
                if close_menu then close_menu() end
                Library.download(id, { ext = c.ext })
            end,
        }}
    end
    return rows
end

--- The details sheet's buttons. close(): closes the sheet. A book in more
-- than one format has a "Download ›" row opening a menu of them, as ZenOS
-- puts choices behind a row; "Download & read" takes the preferred one.
function Library.detailsButtons(id, full, close)
    local Details = require("athenaeum/details")
    local choices = Downloads.choices(full and full.formats)
    local busy = Downloads.isQueued(id)
    local first = choices[1]
    local download
    if #choices > 1 then
        local arrow = Details.icon("arrow_right")
        download = {
            text = Details.label("download", _("Download")) .. (arrow and "  " .. arrow or ""),
            align = "left",
            enabled = not busy,
            callback = function()
                close()
                local menu
                local rows = Library.formatRows(id, choices, function() UIManager:close(menu) end)
                menu = Details.menu(_("Download"), Guard.wrapCallbacks(rows))
            end,
        }
    else
        download = {
            text = Details.label("download", _("Download")),
            align = "left",
            enabled = first ~= nil and not busy,
            callback = function()
                close()
                Library.download(id, { ext = first and first.ext })
            end,
        }
    end
    local rows = {
        { download },
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
    local status = statusRow(id, full, close)
    if status then table.insert(rows, status) end
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

--- Woken up, in the file browser: sync (if Wi-Fi is still on; otherwise
-- when it connects).
function Library.onResume()
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

--- The Status page's text: headed sections, laid out as Concordance's.
function Library.statusText()
    local server = Library.server()
    local lines = {}
    -- A heading, then its lines indented under it.
    local function section(heading, items)
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, heading)
        for _i, line in ipairs(items) do table.insert(lines, "   " .. line) end
    end
    local problems = {}
    local guard_text = Guard.statusText()
    for line in guard_text:gmatch("[^\n]+") do table.insert(problems, "• " .. line) end

    local overview = {}
    if server then
        local store = openStore(server)
        local last, last_full = store:getMeta("last_quick_sync"), store:getMeta("last_full_sync")
        store:close()
        table.insert(overview, T(_("Quick sync: last %1 (automatic %2)"), ago(last),
            Library.quickSyncOn() and _("on") or _("off")))
        table.insert(overview, T(_("Full sync: last %1 (%2)"), ago(last_full), fullSyncText(Library.fullSyncMode())))
        local r = Library.last_result
        table.insert(overview, T(_("Last error: %1"), r and r.error
            and T("%1 (%2)", r.error, jobName(r.mode, r.sync and r.sync.escalated)) or _("none")))
        if Library.job then
            table.insert(overview, ({ quick = _("Quick sync running…"), full = _("Full sync running…"),
                scan = _("Checking the folder…") })[Library.job.mode] or _("Downloading covers…"))
        end
    else
        table.insert(overview, _("No catalog chosen."))
    end
    if #problems == 0 then table.insert(overview, _("Problems since KOReader started: none")) end
    section(_("Overview"), overview)
    if #problems > 0 then
        section(_("Problems since KOReader started (often from a KOReader or ZenOS update)"), problems)
    end
    if not server then return table.concat(lines, "\n") end

    section(_("Catalog"), {
        T(_("Catalog: %1"), server.title or server.url),
        T(_("Folder: %1"), Library.folder() or "?"),
    })
    local st = Library.stats or {}
    if st.catalog then
        section(_("Books"), {
            T(_("In the catalog: %1"), st.catalog),
            T(_("On this device: %1"), st.on_device),
            T(_("Shown as cloud books: %1"), st.cloud),
            T(_("Files in the folder not in the catalog: %1"), st.unmatched_files),
        })
        local covers = { T(_("Downloaded: %1 of %2"), st.covers, st.covers_available) }
        if (st.covers_failed or 0) > 0 then
            table.insert(covers, T(_("The server couldn't provide: %1 (tried again daily)"), st.covers_failed))
        end
        section(_("Covers"), covers)
    end
    return table.concat(lines, "\n")
end

function Library.menuItems(plugin)
    return Guard.wrapCallbacks({ Library.menuEntry(plugin) })[1]
end

function Library.menuEntry(plugin)
    return {
        text = _("Athenæum"),
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
                    text = _("Quick sync automatically"),
                    help_text = _("Looks for new books when the file browser opens, on wake-up and when Wi-Fi connects (Wi-Fi isn't turned on for it)."),
                    checked_func = function() return Library.quickSyncOn() end,
                    callback = function() Library.setQuickSync(not Library.quickSyncOn()) end,
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
                    text = _("Mark cloud books"),
                    help_text = _("A cloud on the cover of books that are only in your online library."),
                    checked_func = function() return Library.settings().badge_cloud ~= false end,
                    callback = function()
                        Library.save("badge_cloud", Library.settings().badge_cloud == false)
                        Badge.cloud_enabled = Library.settings().badge_cloud ~= false
                        Library.repaint()
                    end,
                },
                {
                    text = _("Mark books on this device"),
                    help_text = _("A check mark on the cover of downloaded books that are in your online library."),
                    checked_func = function() return Library.settings().badge_local == true end,
                    callback = function()
                        Library.save("badge_local", Library.settings().badge_local ~= true)
                        Badge.local_enabled = Library.settings().badge_local == true
                        Library.repaint()
                    end,
                },
                {
                    text = _("Mark books not in the catalog"),
                    help_text = _("A crossed-out cloud on the cover of books in the library folder that aren't in your online library. Books in other folders aren't checked."),
                    checked_func = function() return Library.settings().badge_noncloud == true end,
                    callback = function()
                        Library.save("badge_noncloud", Library.settings().badge_noncloud ~= true)
                        Badge.noncloud_enabled = Library.settings().badge_noncloud == true
                        Library.repaint()
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
                    UIManager:show(require("ui/widget/textviewer"):new{
                        title = _("Athenæum status"),
                        text = Library.statusText(),
                        justified = false,
                    })
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
                                title = _("Athenæum timings"),
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
                local Updater = require("athenaeum/updater")
                local updates = Updater.menuItems(plugin)
                if Updater.combined() then
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
