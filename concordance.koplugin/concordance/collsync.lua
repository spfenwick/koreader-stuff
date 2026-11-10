--[[--
Collections and favorites sync inside KOReader. Synced with book data, in
its stream (see bookformat.lua and BOOKDATA.md):

- A book's membership of a collection is the book property coll.<id>
  (true, or cleared when it's taken out), under the book's partial MD5, so
  it doesn't matter where each device keeps the file. Versions of a book
  (IDENTITY.md) share it.
- Collections are properties of the "collections" record: coll.<id> ->
  { name }, cleared when the collection is removed.

KOReader keys collections by name, so the ID is kept in the collection's
settings in collection.lua (`concordance_id`), which KOReader carries over
when a collection is renamed. (OmniSync called it `omnisync_id`: read
when there's no `concordance_id`, and replaced by it.) A collection without one gets an ID from its
name ("favorites" for Favorites), so collections of the same name made on
two devices before they synced are one; if that ID is already a
collection of another name, it gets a random one.

Only membership and names are synced. Each device keeps its own order of
books and collections, sorting, filters and connected folders (their paths
are the device's own).

A book file that's gone from this device isn't taken as removed from its
collections (KOReader drops missing files): what this device saw of it is
forgotten, and the book is put back in its collections if it comes back.
--]]

local BookFormat = require("concordance/bookformat")

local CollSync = {}
CollSync.__index = CollSync

CollSync.CHUNK = 25          -- books per UI tick when finding MD5s
CollSync.RETRY_DELAY = 2     -- s between tries while the user is busy
CollSync.RETRY_TRIES = 90

local COLLS = BookFormat.COLLECTIONS
local FAV = BookFormat.FAVORITES

--- deps: store (BookStore), getDeviceId(), now(), logger, schedule(delay, fn),
-- enabled(), and optionally readcollection, docsettings, lfs, partial_md5(path),
-- realpath(path), idle() (no menu or dialog open), refresh_ui(), random_id()
function CollSync.new(deps)
    local self = setmetatable({ deps = deps }, CollSync)
    self.log = deps.logger
    return self
end

function CollSync:_mod(dep, name)
    if self.deps[dep] then return self.deps[dep] end
    return require(name)
end
function CollSync:_lfs() return self:_mod("lfs", "libs/libkoreader-lfs") end

--- KOReader's collections, read again if collection.lua changed.
function CollSync:_rc()
    local rc = self:_mod("readcollection", "readcollection")
    if rc._read then rc:_read() end
    return rc
end

function CollSync:_realpath(path)
    if self.deps.realpath then return self.deps.realpath(path) or path end
    local ok, ffiUtil = pcall(require, "ffi/util")
    return ok and ffiUtil.realpath(path) or path
end

function CollSync:_isFile(path)
    return self:_lfs().attributes(path, "mode") == "file"
end

local function propOf(id) return "coll." .. id end

-- IDs ------------------------------------------------------------------------------------

function CollSync:_randomId()
    if self.deps.random_id then return self.deps.random_id() end
    return self.deps.store.md5(table.concat({ self.deps.getDeviceId(), tostring(self.deps.now()),
        tostring(os.clock()), tostring(math.random()) }, "|")):sub(1, 16)
end

--- Gives every collection an ID. Returns { [id] = name } and whether
-- collection.lua needs writing.
function CollSync:_ids(rc, merged)
    local ids, dirty = {}, false
    local names = {}
    for name in pairs(rc.coll) do names[#names + 1] = name end
    table.sort(names) -- the same choices every time
    local todo = {}
    for _, name in ipairs(names) do
        local st = rc.coll_settings[name]
        if type(st) ~= "table" then
            st = { order = 1 }
            rc.coll_settings[name] = st
        end
        local id = name == FAV and FAV or st.concordance_id or st.omnisync_id
        if st.omnisync_id ~= nil then st.omnisync_id = nil; dirty = true end
        if type(id) ~= "string" or not BookFormat.collId(propOf(id)) or ids[id] then
            todo[#todo + 1] = name -- none yet, or a copy of another's
        else
            ids[id] = name
            if st.concordance_id ~= id then st.concordance_id = id; dirty = true end
        end
    end
    for _, name in ipairs(todo) do
        local id = self.deps.store.md5(name):sub(1, 16)
        local m = merged[id]
        if ids[id] or (m and not m.deleted and m.name ~= name) then id = self:_randomId() end
        ids[id] = name
        rc.coll_settings[name].concordance_id = id
        dirty = true
    end
    return ids, dirty
end

-- Where books are -------------------------------------------------------------------------

function CollSync:_sig(path)
    local a = self:_lfs().attributes(path)
    if not (a and a.mode == "file") then return nil end
    return tostring(a.size) .. "@" .. tostring(a.modification)
end

--- The book's partial MD5, as KOReader computes it: from its sidecar, or
-- from the file.
function CollSync:_findMd5(path)
    local DocSettings = self.deps.docsettings
    if DocSettings == nil then
        local ok, ds = pcall(require, "docsettings")
        DocSettings = ok and ds or false
    end
    if DocSettings and DocSettings.hasSidecarFile and DocSettings:hasSidecarFile(path) then
        local md5 = DocSettings:open(path):readSetting("partial_md5_checksum")
        if type(md5) == "string" and md5 ~= "" then return md5 end
    end
    if self.deps.partial_md5 then return self.deps.partial_md5(path) end
    return require("util").partialMD5(path)
end

--- The files in KOReader's collections: { path, … } (sorted, no repeats).
local function collectionFiles(rc)
    local seen, out = {}, {}
    for _, coll in pairs(rc.coll) do
        for file in pairs(coll) do
            if not seen[file] then
                seen[file] = true
                out[#out + 1] = file
            end
        end
    end
    table.sort(out)
    return out
end

--- path -> md5 for these files, from what's known, finding the rest.
-- Records what it found. Files that are gone are left out.
function CollSync:_md5s(paths)
    local store = self.deps.store
    local books, cached = store:files(), store:collFiles()
    local out, found = {}, {}
    for _, path in ipairs(paths) do
        local sig = self:_sig(path)
        if sig then
            local c = cached[path]
            if c and c.sig == sig then
                out[path] = c.md5
            elseif books[path] and not c then
                out[path] = books[path].md5
            else
                local md5 = self:_findMd5(path)
                if md5 then
                    out[path] = md5
                    found[#found + 1] = { path = path, md5 = md5, sig = sig }
                end
            end
        end
    end
    store:setCollFiles(found)
    return out
end

--- md5 -> { path, … }: every book file on this device known to the sync.
function CollSync:_paths()
    local out = {}
    local function add(path, md5)
        out[md5] = out[md5] or {}
        for _, p in ipairs(out[md5]) do if p == path then return end end
        table.insert(out[md5], path)
    end
    for path, f in pairs(self.deps.store:files()) do add(path, f.md5) end
    for path, f in pairs(self.deps.store:collFiles()) do add(path, f.md5) end
    return out
end

--- path -> md5 for these files (found now if not known: see findMd5s).
function CollSync:md5s(paths) return self:_md5s(paths) end

--- md5 -> { path, … } for every book file on this device known to the sync.
function CollSync:paths() return self:_paths() end

--- Before a sync: finds the MD5s of books in collections, a chunk per UI
-- tick (the first time can be many). done() when finished.
function CollSync:refresh(done)
    local ok, rc = pcall(self._rc, self)
    if not ok or not rc.coll then
        if not ok then self.log.warn("Concordance: reading collections failed:", rc) end
        if done then done() end
        return
    end
    self:findMd5s(collectionFiles(rc), done)
end

--- Finds the MD5s of these files that aren't known yet (or changed), a
-- chunk per UI tick. done() when finished.
function CollSync:findMd5s(paths, done)
    local cached = self.deps.store:collFiles()
    local books = self.deps.store:files()
    local todo = {}
    for _, path in ipairs(paths) do
        local c = cached[path]
        if not ((c and c.sig == self:_sig(path)) or (books[path] and not c)) then todo[#todo + 1] = path end
    end
    local i = 0
    local function step()
        local chunk = {}
        for _ = 1, CollSync.CHUNK do
            i = i + 1
            if not todo[i] then break end
            chunk[#chunk + 1] = todo[i]
        end
        local cok, err = pcall(self._md5s, self, chunk)
        if not cok then self.log.warn("Concordance: finding books in collections failed:", err) end
        if todo[i] then return self.deps.schedule(0, step) end
        if done then done() end
    end
    if #todo == 0 then
        if done then done() end
    else
        self.deps.schedule(0, step)
    end
end

-- Local changes ------------------------------------------------------------------------

--- Records changes to KOReader's collections (and gives new collections
-- their IDs). Returns the number of changes recorded.
function CollSync:observe()
    local store = self.deps.store
    local rc = self:_rc()
    if not rc.coll then return 0 end
    local ids, dirty = self:_ids(rc, store:collections())
    if dirty then rc:write() end
    local now, device = self.deps.now(), self.deps.getDeviceId()
    local loc = store:localColl()
    local seen_colls = loc[COLLS] or {}
    local looked_before = next(seen_colls) ~= nil

    -- The collections.
    local cvalues, ctimes = {}, {}
    for id, name in pairs(ids) do
        local prop = propOf(id)
        cvalues[prop] = { name = name }
        -- Made since this device last looked: now. The first time: as old as can be.
        if looked_before and seen_colls[prop] == nil then ctimes[prop] = now end
    end
    for prop, hash in pairs(seen_colls) do
        if cvalues[prop] == nil and hash ~= "" then cvalues[prop] = false end
    end
    local list = { { md5 = COLLS, values = cvalues, times = ctimes, now = now, device = device } }

    -- Memberships, by book.
    local md5s = self:_md5s(collectionFiles(rc))
    local books = {}
    for id, name in pairs(ids) do
        local prop = propOf(id)
        for file in pairs(rc.coll[name]) do
            local md5 = md5s[file]
            if md5 then
                local b = books[md5]
                if not b then
                    b = { md5 = md5, values = {}, times = {}, now = now, device = device }
                    books[md5] = b
                end
                b.values[prop] = true
                if seen_colls[prop] ~= nil then b.times[prop] = now end
            end
        end
    end
    -- Taken out, or the book is gone from this device.
    local paths
    for md5, props in pairs(loc) do
        if md5 ~= COLLS then
            for prop, hash in pairs(props) do
                if hash ~= "" and not (books[md5] and books[md5].values[prop]) then
                    paths = paths or self:_paths()
                    local here = false
                    for _, p in ipairs(paths[md5] or {}) do
                        if self:_isFile(p) then here = true; break end
                    end
                    if here then
                        local b = books[md5]
                        if not b then
                            b = { md5 = md5, values = {}, now = now, device = device }
                            books[md5] = b
                        end
                        b.values[prop] = false
                    else
                        store:forgetLocalColl(md5)
                        break
                    end
                end
            end
        end
    end
    local keys = {}
    for md5 in pairs(books) do keys[#keys + 1] = md5 end
    table.sort(keys)
    for _, md5 in ipairs(keys) do list[#list + 1] = books[md5] end
    local changed = 0
    for _, r in ipairs(store:observeMany(list)) do changed = changed + r.changed end
    if changed > 0 then self.log.dbg("Concordance: collections:", changed, "changes recorded") end
    return changed
end

-- Applying the merged state --------------------------------------------------------------

function CollSync:_idle()
    if self.deps.idle then return self.deps.idle() end
    local UIManager = require("ui/uimanager")
    local top = UIManager:getTopmostVisibleWidget()
    if not top then return true end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    return (ok_fm and top == FileManager.instance) or (ok_r and ReaderUI.instance
        and (top == ReaderUI.instance or top == ReaderUI.instance.dialog)) or false
end

function CollSync:_refreshUI()
    if self.deps.refresh_ui then return self.deps.refresh_ui() end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager.instance
    if fm and fm.file_chooser then fm.file_chooser:refreshPath() end
end

--- A name not used by another collection (mine: the collection's own name).
local function freeName(rc, name, mine)
    if not rc.coll[name] or name == mine then return name end
    local n = 2
    while rc.coll[name .. " (" .. n .. ")"] and name .. " (" .. n .. ")" ~= mine do n = n + 1 end
    return name .. " (" .. n .. ")"
end

--- Brings KOReader's collections in line with the merged state: collections
-- made, renamed and removed, books put in and taken out. only = { [md5] =
-- true } limits the books looked at. Records local changes first. Unless
-- `force`, does nothing while a menu or dialog is open (KOReader's
-- collection views write their own copy when closed). Returns the number
-- of changes made, or nil and why.
function CollSync:apply(force, only)
    if not force and not self:_idle() then return nil, "busy" end
    self:observe()
    local store = self.deps.store
    local rc = self:_rc()
    if not rc.coll then return 0 end
    local ids = self:_ids(rc, {})
    local names = {}
    for id, name in pairs(ids) do names[id] = name end
    local n = 0

    -- Removals, then renames, then new collections, so names freed are
    -- free for the others.
    local merged = store:collections()
    local order = {}
    for id in pairs(merged) do order[#order + 1] = id end
    table.sort(order)
    for pass = 1, 3 do
        for _, id in ipairs(order) do
            local m = merged[id]
            local cur = names[id]
            if pass == 1 and m.deleted then
                if cur and id ~= FAV then
                    rc:removeCollection(cur)
                    names[id] = nil
                    n = n + 1
                end
            elseif pass > 1 and not m.deleted and id ~= FAV and m.name and cur ~= m.name
                    and (cur ~= nil) == (pass == 2) then
                local name = freeName(rc, m.name, cur)
                if cur then
                    if name ~= cur then rc:renameCollection(cur, name) end
                else
                    rc:addCollection(name)
                end
                if name ~= cur then
                    rc.coll_settings[name].concordance_id = id
                    names[id] = name
                    n = n + 1
                end
            end
        end
    end

    local paths = self:_paths()
    local md5s = {}
    if only then
        for md5 in pairs(only) do md5s[md5] = true end
    else
        for md5 in pairs(paths) do md5s[md5] = true end
    end
    for md5, map in pairs(store:memberships(md5s)) do
        for _, path in ipairs(paths[md5] or {}) do
            if self:_isFile(path) then
                local file = self:_realpath(path)
                for id, want in pairs(map) do
                    local name = names[id]
                    local coll = name and rc.coll[name]
                    if coll then
                        if want and not coll[file] then
                            rc:addItem(file, name)
                            n = n + 1
                        elseif not want and coll[file] then
                            coll[file] = nil
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    if n > 0 then
        rc:write()
        self:observe() -- what's there now is this device's copy
        pcall(self._refreshUI, self)
        self.log.info("Concordance: applied", n, "collection changes")
    end
    return n
end

--- After a sync: apply, or retry while the user is busy.
function CollSync:afterSync()
    local ok, n, why = pcall(self.apply, self)
    if not ok then
        self.log.warn("Concordance: applying collections failed:", n)
    elseif not n and why == "busy" then
        self:_applyLater(0)
    end
end

function CollSync:_applyLater(tries)
    if self.retrying and tries == 0 then return end
    self.retrying = true
    self.deps.schedule(CollSync.RETRY_DELAY, function()
        if not self.deps.enabled() then
            self.retrying = false
            return
        end
        local ok, n, why = pcall(self.apply, self)
        if ok and not n and why == "busy" and tries + 1 < CollSync.RETRY_TRIES then
            return self:_applyLater(tries + 1)
        end
        if not ok then self.log.warn("Concordance: applying collections failed:", n) end
        self.retrying = false
    end)
end

--- A book was opened (book data has recorded where it is): put it in the
-- collections it belongs to here, in case it's new to this device.
function CollSync:onBookOpened(md5)
    if not self.deps.enabled() or type(md5) ~= "string" then return end
    local ok, err = pcall(self.apply, self, true, { [md5] = true })
    if not ok then self.log.warn("Concordance: collections on open failed:", err) end
end

return CollSync
