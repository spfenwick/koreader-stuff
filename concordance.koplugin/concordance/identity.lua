--[[--
What Concordance tells other plugins about books, by book ID (a UUID the
book's files carry), and what they can tell it. Athenaeum uses it,
finding it as package.loaded["concordance/identity"] (nothing is shared when
Concordance isn't installed). See IDENTITY.md, "Athenaeum's side".

    Identity.available()        true once Concordance has set it up
    Identity.bookState(uuids)   { status, rating, last_read, last_device }
                                for the book with one of these UUIDs, from
                                every device's book data, or nil
    Identity.fileAdded(path)    a book file just arrived (a download): read
                                its identity now, so its versions' book data
                                and annotations apply when it's first opened
    Identity.onChanged(key, fn) fn() after book states may have changed
                                (a sync brought new data); one per key
    Identity.revision()         changes whenever states may have

last_device is the device's name when known, else nil; "this device" is
given as Identity.THIS_DEVICE.

Calls run in KOReader's main process and never raise: a failure is logged
and gives nil (or 0).

The other way round, Concordance asks Athenaeum (when it's there) for
the files in its folder (Library.localFiles, read for their identity like
books opened here) and for the files it matched to a catalog book without
the file naming the book's UUID (Library.links: by title, or a PDF): each
becomes a "link" fact (Identity.recordLinks, at the start of each sync).
A link this device made that Athenaeum no longer makes, for a file
still in its folder and a book still in its catalog, is withdrawn
(Identity.retractLinks, with Library.folderFiles and Library.inCatalog).
--]]

local Identity = {
    THIS_DEVICE = {},
}

local deps          -- set by setup()
local rev = 0
local states, states_rev
local listeners = {}

--- deps: id_store(), book_store() (opened when first needed), device_id(), device_names() -> { [id] = name },
-- files() -> { [path] = { md5 } } for books opened here (BookStore:files),
-- handles(path) -> true for files scan() reads, scan(path) -> IdScan
-- result or nil, refresh() -> changed md5s (the
-- engine's refreshIdentity), logger.
function Identity.setup(d)
    deps = d
    rev = rev + 1
end

function Identity.available()
    return deps ~= nil
end

function Identity.revision()
    return rev
end

local function warn(what, ...)
    if deps and deps.logger then deps.logger.warn("Concordance identity:", what, ...) end
    local n = select("#", ...)
    local detail = n > 0 and tostring((select(n, ...))) or nil
    require("concordance/problems").report("identity:" .. tostring(what),
        "Book identity (shared with Athenæum): " .. tostring(what):gsub(":$", ""), detail)
end

local function load()
    if states and states_rev == rev then return states end
    local IdStore = require("concordance/idstore")
    local ok, res = pcall(function()
        -- On a new device the identity tables may not exist yet: opening
        -- the identity store creates them.
        if deps.id_store then deps.id_store():open():close() end
        return deps.book_store():statesByUuid(IdStore.usedFacts)
    end)
    if not ok then
        warn("reading book states failed:", res)
        res = {}
    end
    states, states_rev = res, rev
    return states
end

function Identity.bookState(uuids)
    if not deps or type(uuids) ~= "table" then return nil end
    local all = load()
    local found
    for _, u in ipairs(uuids) do
        local st = type(u) == "string" and all[u:lower()]
        if st then found = st; break end
    end
    if not found then return nil end
    local out = { status = found.status, rating = found.rating, last_read = found.last_read }
    if found.last_device then
        if found.last_device == deps.device_id() then
            out.last_device = Identity.THIS_DEVICE
        else
            local names = deps.device_names() or {}
            local name = names[found.last_device]
            if type(name) == "string" and name ~= "" then out.last_device = name end
        end
    end
    return out
end

--- Records matches made outside the file: list = { { path, md5 (the
-- file's partial MD5), uuids, title, authors }, … }. Returns the number of
-- new facts (sent with the next sync; groups are updated at its end).
function Identity.recordLinks(list)
    if not deps or type(list) ~= "table" or #list == 0 then return 0 end
    local ok, n = pcall(function()
        local opened = deps.files()
        local recs = {}
        for _, l in ipairs(list) do
            -- The book's MD5 is its sidecar's once it has been opened here.
            local md5 = (type(l.path) == "string" and opened[l.path] and opened[l.path].md5) or l.md5
            if type(md5) == "string" and md5 ~= "" then
                recs[#recs + 1] = { md5 = md5, uuids = l.uuids, title = l.title, authors = l.authors }
            end
        end
        if #recs == 0 then return 0 end
        return deps.id_store():link(recs, deps.device_id())
    end)
    if not ok then
        warn("recording matches failed:", n)
        return 0
    end
    return n
end

--- Withdraws links this device made that the other plugin no longer
-- makes. links: its matches now (as for recordLinks); files = { { path,
-- md5 }, … }: every file it can speak for; known(uuid) -> true for a book
-- it still lists. Returns the number withdrawn.
function Identity.retractLinks(links, files, known)
    if not deps or type(links) ~= "table" or type(files) ~= "table" or type(known) ~= "function" then return 0 end
    local ok, n = pcall(function()
        local opened = deps.files()
        local IdFormat = require("concordance/idformat")
        -- A file's links are under its sidecar's MD5 or its own: both.
        local function md5s(item)
            local out = {}
            local side = type(item.path) == "string" and opened[item.path] and opened[item.path].md5
            if type(side) == "string" and side ~= "" then out[#out + 1] = side end
            if type(item.md5) == "string" and item.md5 ~= "" then out[#out + 1] = item.md5 end
            return out
        end
        local present, current = {}, {}
        for _, f in ipairs(files) do
            for _, md5 in ipairs(md5s(f)) do present[md5] = true end
        end
        for _, l in ipairs(links) do
            local uuids = {}
            for _, u in ipairs(type(l.uuids) == "table" and l.uuids or {}) do
                uuids[#uuids + 1] = IdFormat.normalizeUuid(u)
            end
            local key = table.concat(IdFormat.sortedUnique(uuids), "\n")
            for _, md5 in ipairs(md5s(l)) do
                current[md5] = current[md5] or {}
                current[md5][key] = true
            end
        end
        if next(present) == nil then return 0 end
        return deps.id_store():retract{
            device = deps.device_id(), present = present, current = current,
            known = function(u)
                local okk, res = pcall(known, u)
                return okk and res == true
            end,
        }
    end)
    if not ok then
        warn("withdrawing matches failed:", n)
        return 0
    end
    return n
end

function Identity.fileAdded(path)
    if not deps or type(path) ~= "string" then return 0 end
    local ok, n = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local attr = lfs.attributes(path)
        if not (attr and attr.mode == "file") or not deps.handles(path) then return 0 end
        local opened = deps.files()[path]
        local item = { path = path, md5 = opened and opened.md5, size = attr.size, mtime = attr.modification }
        local store = deps.id_store()
        if #store:toScan({ item }) == 0 then return 0 end
        return store:recordScan(item, deps.scan(path), deps.device_id())
    end)
    if not ok then
        warn("reading", path, "failed:", n)
        return 0
    end
    if n > 0 then deps.refresh() end
    return n
end

function Identity.onChanged(key, fn)
    listeners[key] = fn
end

--- Book states may have changed: drop what's cached and tell listeners.
function Identity.changed()
    rev = rev + 1
    for key, fn in pairs(listeners) do
        local ok, err = pcall(fn)
        if not ok then warn("listener", key, "failed:", err) end
    end
end

return Identity
