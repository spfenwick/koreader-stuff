--[[--
Reads what identifies a book file: the UUIDs in its package file, and its
body signature. EPUB only. Runs in the sync's subprocess (a few tenths of a
second per book on a Kobo; see IDENTITY.md).

The body signature: for each spine item in order, the element tag sequence
and the whitespace-collapsed text of its <body>, hashed; the per-item
hashes are hashed together in spine order. Attributes, <head>, the package
file and navigation files aren't part of it, so a copy Calibre rewrote
after a metadata or cover edit has the same signature, and positions
(XPointers) made in one point at the same text in the other.

IdScan.scan(path, deps) -> info or nil, why
    deps.md5(s)            hex digest of a string
    deps.partialMD5(path)  KOReader's file fingerprint
    deps.openArchive(path) optional (default: KOReader's ffi/archiver):
                           -> archive | nil; archive:read(name) -> data,
                           archive:each(set, fn(name, data)) reads the
                           named entries in storage order, archive:close()
info = { md5 (the file's own partial MD5), uuids, ids, title, authors, sig }
--]]

local IdFormat = require("concordance/idformat")

local IdScan = {}

IdScan.EXTENSIONS = { epub = true }

--- Is this a file the scanner reads?
function IdScan.handles(path)
    local ext = type(path) == "string" and path:match("%.([^./]+)$")
    return ext ~= nil and IdScan.EXTENSIONS[ext:lower()] == true
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function utf8char(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40) end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    if n < 0x110000 then
        return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
            0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    return ""
end

local function unescape(s)
    return (s:gsub("&(#?[xX]?)(%w+);", function(kind, v)
        if kind == "" then return ENTITIES[v] end
        local n = tonumber(v, (kind == "#x" or kind == "#X") and 16 or 10)
        return n and utf8char(n) or nil
    end))
end

local function clean(s)
    if not s then return nil end
    s = unescape(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    return s
end

--- What the package file says: { uuids, ids, title, authors }.
function IdScan.parseOpf(opf)
    local info = { uuids = {}, ids = {} }
    local seen = {}
    for attrs, value in opf:gmatch("<[%w]*:?identifier([^>]*)>%s*([^<]-)%s*</[%w]*:?identifier>") do
        value = unescape(value)
        local uuid = IdFormat.normalizeUuid(value)
        if uuid then
            if not seen[uuid] then seen[uuid] = true; table.insert(info.uuids, uuid) end
        elseif value ~= "" and #info.ids < IdFormat.MAX_IDS then
            -- Calibre 6: <dc:identifier opf:scheme="ISBN">…; Calibre 9: isbn:…
            local scheme = attrs:match('scheme%s*=%s*"([^"]+)"')
            local id = (scheme and not value:find(":", 1, true)) and (scheme:lower() .. ":" .. value) or value
            id = id:sub(1, 256)
            if not seen[id] then seen[id] = true; table.insert(info.ids, id) end
        end
    end
    info.uuids = IdFormat.sortedUnique(info.uuids)
    for i = IdFormat.MAX_UUIDS + 1, #info.uuids do info.uuids[i] = nil end
    info.title = clean(opf:match("<[%w]*:?title[^>]*>([^<]-)</[%w]*:?title>"))
    local authors = {}
    for creator in opf:gmatch("<[%w]*:?creator[^>]*>([^<]-)</[%w]*:?creator>") do
        local a = clean(creator)
        if a then authors[#authors + 1] = a end
    end
    info.authors = #authors > 0 and table.concat(authors, "\n") or nil
    if info.title then info.title = info.title:sub(1, 1024) end
    if info.authors then info.authors = info.authors:sub(1, 1024) end
    return info
end

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function join(dir, href)
    href = href:gsub("#.*$", ""):gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
    local parts = {}
    for p in ((dir ~= "" and dir .. "/" or "") .. href):gmatch("[^/]+") do
        if p == ".." then table.remove(parts) elseif p ~= "." then table.insert(parts, p) end
    end
    return table.concat(parts, "/")
end

--- The spine's files (archive paths), in reading order.
function IdScan.spine(opf, opf_path)
    local base = dirname(opf_path)
    local hrefs = {}
    for item in opf:gmatch("<[%w:]*item%s[^>]*>") do
        local id, href = item:match('%sid%s*=%s*"([^"]+)"'), item:match('%shref%s*=%s*"([^"]+)"')
        if id and href then hrefs[id] = join(base, href) end
    end
    local files = {}
    for ref in opf:gmatch("<[%w:]*itemref%s[^>]*>") do
        local file = hrefs[ref:match('idref%s*=%s*"([^"]+)"') or ""]
        if file then files[#files + 1] = file end
    end
    return files
end

--- One spine item's part of the signature.
function IdScan.bodyHash(data, md5)
    local body = data:match("<body.*") or data
    local tags = {}
    for t in body:gmatch("<(/?[%w:]+)") do tags[#tags + 1] = t end
    local text = body:gsub("<[^>]+>", " "):gsub("%s+", " ")
    return md5(table.concat(tags, " ") .. "\0" .. text)
end

--- The signature from the spine's files and their per-item hashes.
function IdScan.combine(files, hashes, md5)
    local parts = {}
    for i, file in ipairs(files) do parts[i] = hashes[file] or "-" end
    return md5(table.concat(parts, "\n"))
end

--- KOReader's archive reader, wrapped.
function IdScan.ffiArchive(path)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(path) then return nil end
    for _entry in arc:iterate() do end -- index the entries
    return {
        read = function(_, name) return arc:extractToMemory(name) end,
        each = function(_, set, fn)
            for entry in arc:iterate() do
                if set[entry.path] then
                    local data = arc:extractToMemory(entry.path)
                    if data then fn(entry.path, data) end
                end
            end
        end,
        close = function() arc:close() end,
    }
end

function IdScan.scan(path, deps)
    local md5 = deps.md5
    local fingerprint = deps.partialMD5(path)
    if not fingerprint then return nil, "can't read the file" end
    local arc = (deps.openArchive or IdScan.ffiArchive)(path)
    if not arc then return nil, "not an archive" end
    local ok, res, why = pcall(function()
        local container = arc:read("META-INF/container.xml")
        local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
        local opf = opf_path and arc:read(opf_path)
        if not opf then return nil, "no package file" end
        local info = IdScan.parseOpf(opf)
        info.md5 = fingerprint
        local files = IdScan.spine(opf, opf_path)
        if #files > 0 then
            local wanted, hashes = {}, {}
            for _, f in ipairs(files) do wanted[f] = true end
            arc:each(wanted, function(name, data) hashes[name] = IdScan.bodyHash(data, md5) end)
            -- No signature unless every spine file was read: with one
            -- left out, two different books could get the same one, and
            -- their highlights and positions cross.
            local whole = true
            for _, f in ipairs(files) do if not hashes[f] then whole = false end end
            if whole then info.sig = IdScan.combine(files, hashes, md5) end
        end
        return info
    end)
    arc:close()
    if not ok then return nil, tostring(res) end
    return res, why
end

return IdScan
