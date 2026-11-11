--[[--
Book identity records and segment files for Concordance's fourth stream: which
book files carry which book IDs, so different files of the same book (a
copy rewritten by Calibre after a metadata or cover edit) can be told
apart from different books. See IDENTITY.md.

A record is a fact about a file, identified by its partial MD5:

    uuids    the UUIDs among its dc:identifiers (lowercase, no "urn:uuid:"
             or "uuid:")
    sig      its body signature (see idscan.lua), or absent: positions
             unknown
    src      where the fact comes from: "file" (read from the file with
             this MD5), "sidecar" (this MD5 is a sidecar's, and the file now
             at its path is another one: UUIDs from that file, no sig),
             "link" (from another plugin: Cloud library matching a file
             without the catalog book's UUID by its title). A link only
             counts for an MD5 no file fact names, and when every link for
             it names the same UUIDs (see idstore.lua); "unlink" (the
             device that made a link withdraws it: the match no longer
             holds)
    n        for a link or an unlink, which time round (absent: 0). An
             unlink numbered n withdraws the links for its MD5 and UUIDs
             numbered n or less; a link made after that is numbered n + 1.
             So a link counts while its number is above every unlink's,
             on every device, whatever order the records arrive in
    title, authors, ids (other identifiers: ISBN, calibre:<n>…): for
             display only

A segment is JSON Lines, compressed like the others:

    {"t":"h","format":"statsync-id","v":1,"minor":0,"device":"…","created":…}
    {"t":"i","md5":"…","src":"file","uuids":["…"],"sig":"…","title":"…","authors":"…","ids":["…"]}
    {"t":"end","records":n}

Facts don't change, so there are no times and no clears: the merged state
is the union of every record. Readers reject an unknown major version and
skip record types they don't know.

Version 2 added unlinks and numbered links. A segment holding either says
"v":2, so that a device still on version 1 (which would take an unlink for
a fact read from a file) rejects it, and reads it once it's updated; other
segments still say "v":1.
--]]

local Codec = require("concordance/codec")

local IdFormat = {}

IdFormat.FORMAT = "statsync-id"
IdFormat.VERSION = 2 -- the newest this reads; segments are written as 1 when that's enough
IdFormat.MINOR = 0
--- Version number recorded with bad segments (apart from the other streams').
IdFormat.BAD_VERSION = 300000 + IdFormat.VERSION * 1000 + IdFormat.MINOR

--- The highest number a link or unlink can have: a match made and withdrawn
-- this often (devices that disagree about it) stays withdrawn.
IdFormat.MAX_N = 8

IdFormat.MAX_UUIDS = 16
IdFormat.MAX_IDS = 32

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

--- A UUID as records hold it (lowercase, no prefix), or nil.
function IdFormat.normalizeUuid(s)
    if type(s) ~= "string" then return nil end
    s = s:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("^urn:", ""):gsub("^uuid:", "")
    if s:match(UUID) then return s end
    return nil
end

function IdFormat.isUuid(s)
    return type(s) == "string" and s:match(UUID) ~= nil
end

local function isToken(v, max)
    return type(v) == "string" and #v > 0 and #v <= (max or 64) and not v:find("[%c\"\\]")
end

local function isText(v, max)
    return v == nil or (type(v) == "string" and #v <= max)
end

local function isList(v, max, item_ok)
    if v == nil then return true end
    if type(v) ~= "table" or #v > max then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v then return false end
    for _, x in ipairs(v) do
        if not item_ok(x) then return false end
    end
    return true
end

--- Checks a record (as decoded). Returns true or nil and an error.
function IdFormat.validRecord(r)
    if not isToken(r.md5) then return nil, "bad md5" end
    if not isToken(r.src, 16) then return nil, "bad src" end
    if type(r.uuids) ~= "table" or #r.uuids == 0 then return nil, "no uuids" end
    if not isList(r.uuids, IdFormat.MAX_UUIDS, IdFormat.isUuid) then return nil, "bad uuids" end
    if r.sig ~= nil and not isToken(r.sig) then return nil, "bad sig" end
    if r.n ~= nil then
        if type(r.n) ~= "number" or r.n % 1 ~= 0 or r.n < 0 or r.n > IdFormat.MAX_N then return nil, "bad n" end
        if r.src ~= "link" and r.src ~= "unlink" then return nil, "n on a fact that isn't a link" end
    end
    if r.src == "unlink" and r.sig ~= nil then return nil, "sig on an unlink" end
    if not isText(r.title, 1024) or not isText(r.authors, 1024) then return nil, "bad title or authors" end
    if not isList(r.ids, IdFormat.MAX_IDS, function(x) return isText(x, 256) and x ~= "" end) then
        return nil, "bad ids"
    end
    return true
end

-- Segment lines -------------------------------------------------------------------

local enc = Codec.encodeString

--- Does a segment holding this record need to say version 2?
function IdFormat.needsV2(r)
    return r.src == "unlink" or (r.n or 0) > 0
end

--- version: 2 when any record needs it (see needsV2), else 1.
function IdFormat.headerLine(device_id, created, version)
    return Codec.encode{
        t = "h", format = IdFormat.FORMAT, v = version or 1, minor = IdFormat.MINOR,
        device = device_id, created = created,
    }
end

local function list(items)
    local out = {}
    for i, s in ipairs(items) do out[i] = enc(s) end
    return "[" .. table.concat(out, ",") .. "]"
end

--- A copy of the UUID list, sorted and without repeats.
function IdFormat.sortedUnique(items)
    local seen, out = {}, {}
    for _, s in ipairs(items or {}) do
        if not seen[s] then seen[s] = true; out[#out + 1] = s end
    end
    table.sort(out)
    return out
end

--- The part of a record that identifies the fact (md5, src, uuids, sig,
-- and n when it isn't 0), in a fixed form: the same fact always gives the
-- same key.
function IdFormat.factKey(r)
    local key = table.concat({ r.md5, r.src, table.concat(IdFormat.sortedUnique(r.uuids), ","), r.sig or "" }, "|")
    if (r.n or 0) > 0 then key = key .. "|" .. string.format("%d", r.n) end
    return key
end

--- A record line (fixed key order; uuids sorted).
function IdFormat.recordLine(r)
    local parts = { string.format('{"t":"i","md5":%s,"src":%s,"uuids":%s', enc(r.md5), enc(r.src),
        list(IdFormat.sortedUnique(r.uuids))) }
    if r.sig then parts[#parts + 1] = ',"sig":' .. enc(r.sig) end
    if (r.n or 0) > 0 then parts[#parts + 1] = string.format(',"n":%d', r.n) end
    if r.title then parts[#parts + 1] = ',"title":' .. enc(r.title) end
    if r.authors then parts[#parts + 1] = ',"authors":' .. enc(r.authors) end
    if r.ids and #r.ids > 0 then parts[#parts + 1] = ',"ids":' .. list(r.ids) end
    return table.concat(parts) .. "}"
end

function IdFormat.trailerLine(nrecords)
    return string.format('{"t":"end","records":%d}', nrecords)
end

--- Reads an identity segment. handlers.record(rec) is called in file
-- order. Returns the header (with header.records), or nil and an error;
-- callers must roll back what the callback did on error.
function IdFormat.readSegment(path, handlers)
    handlers = handlers or {}
    local f, ferr = io.open(path, "rb")
    if not f then return nil, ferr end
    local header, trailer, err
    local nrecords, lineno = 0, 0
    for line in f:lines() do
        lineno = lineno + 1
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if trailer then err = "data after trailer"; break end
        local rec, derr = Codec.decode(line)
        if type(rec) ~= "table" or type(rec.t) ~= "string" then err = derr or "not a record"; break end
        local t = rec.t
        if lineno == 1 then
            if t ~= "h" or rec.format ~= IdFormat.FORMAT then err = "missing header"; break end
            if rec.v ~= 1 and rec.v ~= IdFormat.VERSION then err = "unsupported format version " .. tostring(rec.v); break end
            if not isToken(rec.device) then err = "bad device in header"; break end
            header = rec
            header.needs_v2 = false
        elseif t == "h" then
            err = "second header"; break
        elseif t == "i" then
            local ok, verr = IdFormat.validRecord(rec)
            if not ok then err = verr; break end
            rec.uuids = IdFormat.sortedUnique(rec.uuids)
            rec.dev = header.device
            if IdFormat.needsV2(rec) then header.needs_v2 = true end
            nrecords = nrecords + 1
            if handlers.record then handlers.record(rec) end
        elseif t == "end" then
            if rec.records ~= nrecords then err = "record count doesn't match trailer"; break end
            trailer = rec
        end
        -- Other record types: a newer minor version, skipped.
    end
    f:close()
    if err then return nil, string.format("line %d: %s", lineno, err) end
    if not header then return nil, "empty file" end
    if not trailer then return nil, "truncated (no trailer)" end
    header.records = nrecords
    return header
end

--- Segment file names: id-<10-digit sequence>.jsonl.zst
function IdFormat.segmentName(seq)
    return string.format("id-%010d.jsonl.zst", seq)
end

function IdFormat.segmentSeq(name)
    local n = type(name) == "string" and name:match("^id%-(%d+)%.jsonl%.zst$")
    return n and tonumber(n)
end

return IdFormat
