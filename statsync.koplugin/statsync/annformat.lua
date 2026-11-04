--[[--
Annotation records and segment files for statsync's annotation stream.

An annotation is one item of KOReader's `annotations` list (a page
bookmark, a highlight or a note). Here it's identified by
(md5, kind, key): the book's partial MD5, "rolling" (CREngine, positions are
XPointers) or "paging" (PDF/DjVu, page coordinates), and a key made from its
creation time (see AnnFormat.keys). Its content is every field except the
ones that depend on this device's layout (pageno, pageref).

A segment is JSON Lines, compressed like the statistics segments:

    {"t":"h","format":"statsync-ann","v":1,"minor":0,"device":"…","created":…}
    {"t":"b","md5":"…","title":"…","authors":"…"}
    {"t":"a","md5":"…","kind":"rolling","key":"…","upd":…,"dev":"…","f":{…}}
    {"t":"x","md5":"…","kind":"rolling","key":"…","upd":…,"dev":"…"}
    {"t":"end","books":n,"records":m}

"a" is an annotation as added or edited, "x" a deletion. `upd` is when the
change was made (epoch seconds), `dev` the device that made it (it can
differ from the segment's device when a device republishes, e.g. after a
change of server). Readers reject an unknown major version and skip record
types they don't know.
--]]

local Codec = require("statsync/codec")

local AnnFormat = {}

AnnFormat.FORMAT = "statsync-ann"
AnnFormat.VERSION = 1
AnnFormat.MINOR = 0
--- Version number recorded with bad segments (apart from the statistics').
AnnFormat.BAD_VERSION = 100000 + AnnFormat.VERSION * 1000 + AnnFormat.MINOR

AnnFormat.KINDS = { rolling = true, paging = true }

--- Fields that depend on this device's layout: recomputed, never sent.
AnnFormat.LOCAL_FIELDS = { pageno = true, pageref = true }

-- Lua values <-> JSON values -------------------------------------------------
-- Annotation fields are plain Lua data, but not always JSON-shaped: a
-- multi-page PDF highlight's `ext` is keyed by page number. Tables with
-- keys other than 1..n or strings are written as {"~lua":[[k,v],…]}.

local LUA_TAG = "~lua"

local function keyOrder(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "number" end
    return a < b
end

local toJson
toJson = function(v, depth)
    local tv = type(v)
    if tv == "string" or tv == "boolean" then return v end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("can't sync a number like " .. tostring(v)) end
        return v
    end
    if tv ~= "table" then error("can't sync a " .. tv) end
    if depth > 12 then error("annotation nested too deeply") end
    local n, all_strings, count = #v, true, 0
    for k in pairs(v) do
        count = count + 1
        if type(k) ~= "string" then all_strings = false end
    end
    if count == 0 then return {} end
    if n == count then
        local arr = setmetatable({}, Codec.array_mt)
        for i = 1, n do arr[i] = toJson(v[i], depth + 1) end
        return arr
    end
    if all_strings then
        local obj = {}
        for k, x in pairs(v) do obj[k] = toJson(x, depth + 1) end
        return obj
    end
    local keys = {}
    for k in pairs(v) do
        local tk = type(k)
        if tk ~= "string" and tk ~= "number" then error("can't sync a " .. tk .. " key") end
        keys[#keys + 1] = k
    end
    table.sort(keys, keyOrder)
    local pairs_out = setmetatable({}, Codec.array_mt)
    for i, k in ipairs(keys) do
        pairs_out[i] = setmetatable({ k, toJson(v[k], depth + 1) }, Codec.array_mt)
    end
    return { [LUA_TAG] = pairs_out }
end

local fromJson
fromJson = function(v)
    if type(v) ~= "table" then return v end
    local tagged = v[LUA_TAG]
    if type(tagged) == "table" and next(v, next(v)) == nil then
        local out = {}
        for _, kv in ipairs(tagged) do
            if type(kv) == "table" and kv[1] ~= nil then out[kv[1]] = fromJson(kv[2]) end
        end
        return out
    end
    local out = {}
    for k, x in pairs(v) do out[k] = fromJson(x) end
    return out
end
AnnFormat.fromJson = fromJson

--- The fields of a KOReader annotation that are synced, as canonical JSON
-- text (sorted keys), or nil and an error.
function AnnFormat.fieldsJson(item)
    local copy = {}
    for k, v in pairs(item) do
        if type(k) == "string" and not AnnFormat.LOCAL_FIELDS[k] then copy[k] = v end
    end
    local ok, res = pcall(function() return Codec.encode(toJson(copy, 0)) end)
    if not ok then return nil, tostring(res) end
    return res
end

--- Can this item be sent as an annotation of this kind? (What readers check.)
function AnnFormat.validItem(item, kind)
    if type(item) ~= "table" then return false end
    local page = item.page
    if kind == "rolling" then
        if type(page) ~= "string" or page == "" then return false end
    elseif type(page) ~= "number" or page % 1 ~= 0 or page < 0 or page >= 2^53 then
        return false
    end
    return item.datetime == nil or type(item.datetime) == "string"
end

--- A KOReader annotation (a new table) from fields JSON.
function AnnFormat.itemFromJson(json)
    local v = Codec.decode(json)
    if type(v) ~= "table" then return nil end
    local item = fromJson(v)
    for k in pairs(AnnFormat.LOCAL_FIELDS) do item[k] = nil end
    return item
end

-- Times -----------------------------------------------------------------------

--- KOReader's "%Y-%m-%d %H:%M:%S" (this device's local time) as epoch seconds.
function AnnFormat.parseTime(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) }
end

--- When an item was last changed, by its own timestamps (nil if it has none).
function AnnFormat.itemTime(item)
    return AnnFormat.parseTime(item.datetime_updated) or AnnFormat.parseTime(item.datetime)
end

-- Keys --------------------------------------------------------------------------

local function posText(p)
    if type(p) == "table" then
        return string.format("%.3f,%.3f", tonumber(p.x) or 0, tonumber(p.y) or 0)
    end
    return p == nil and "" or tostring(p)
end

local function positionKey(item, kind)
    if kind == "paging" then
        return tostring(item.page) .. "|" .. posText(item.pos0) .. "|" .. posText(item.pos1)
    end
    return posText(item.pos0 or item.page) .. "|" .. posText(item.pos1)
end

--- Keys for the items of one list (same order). An item's key is its
-- creation time; items sharing a creation time get their position added
-- (KOReader's own match rule), and exact duplicates a counter.
function AnnFormat.keys(items, kind)
    local per_time = {}
    for _, item in ipairs(items) do
        local dt = type(item.datetime) == "string" and item.datetime or ""
        per_time[dt] = (per_time[dt] or 0) + 1
    end
    local keys, used = {}, {}
    for i, item in ipairs(items) do
        local dt = type(item.datetime) == "string" and item.datetime or ""
        local key = dt
        if per_time[dt] > 1 or dt == "" then key = dt .. "|" .. positionKey(item, kind) end
        if used[key] then
            local n = 2
            while used[key .. "#" .. n] do n = n + 1 end
            key = key .. "#" .. n
        end
        used[key] = true
        keys[i] = key
    end
    return keys
end

--- "rolling" or "paging" for a non-empty list from a sidecar, by its items.
function AnnFormat.listKind(list)
    local first = type(list) == "table" and list[1]
    if type(first) ~= "table" then return nil end
    if type(first.page) == "string" then return "rolling" end
    if type(first.page) == "number" then return "paging" end
end

-- Segment lines -------------------------------------------------------------------

local enc = Codec.encodeString

function AnnFormat.headerLine(device_id, created)
    return Codec.encode{
        t = "h", format = AnnFormat.FORMAT, v = AnnFormat.VERSION, minor = AnnFormat.MINOR,
        device = device_id, created = created,
    }
end

function AnnFormat.bookLine(b)
    local parts = { '{"t":"b","md5":', enc(b.md5) }
    if b.title then parts[#parts + 1] = ',"title":' .. enc(b.title) end
    if b.authors then parts[#parts + 1] = ',"authors":' .. enc(b.authors) end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

--- An add/edit record (fields_json from fieldsJson) or, with fields_json
-- nil, a deletion.
function AnnFormat.recordLine(r)
    local head = string.format('{"t":"%s","md5":%s,"kind":%s,"key":%s,"upd":%d,"dev":%s',
        r.fields_json and "a" or "x", enc(r.md5), enc(r.kind), enc(r.key), r.updated, enc(r.device))
    if r.fields_json then return head .. ',"f":' .. r.fields_json .. "}" end
    return head .. "}"
end

function AnnFormat.trailerLine(nbooks, nrecords)
    return string.format('{"t":"end","books":%d,"records":%d}', nbooks, nrecords)
end

local function isInt(v, min)
    return type(v) == "number" and v % 1 == 0 and v >= (min or -2^53) and v < 2^53
end

local function isToken(v, max)
    return type(v) == "string" and #v > 0 and #v <= (max or 64) and not v:find("[%c\"\\]")
end

--- Checks one record (already decoded). Returns true or nil and an error.
local function validRecord(rec)
    if not isToken(rec.md5) then return nil, "bad md5" end
    if not AnnFormat.KINDS[rec.kind] then return nil, "bad kind" end
    if type(rec.key) ~= "string" or #rec.key == 0 or #rec.key > 4096 then return nil, "bad key" end
    if not isInt(rec.upd, 0) then return nil, "bad upd" end
    if rec.dev ~= nil and not isToken(rec.dev) then return nil, "bad dev" end
    if rec.t == "a" then
        local f = rec.f
        if type(f) ~= "table" or getmetatable(f) == Codec.array_mt then return nil, "bad fields" end
        local page = f.page
        if rec.kind == "rolling" and type(page) ~= "string" then return nil, "rolling annotation without an XPointer" end
        if rec.kind == "paging" and not isInt(page, 0) then return nil, "paging annotation without a page number" end
        if f.datetime ~= nil and type(f.datetime) ~= "string" then return nil, "bad datetime" end
    end
    return true
end

--- Reads an annotation segment. handlers.book(rec), handlers.record(rec)
-- (rec.t "a" or "x"; for "a", rec.fields_json is the canonical JSON of
-- rec.f) are called in file order. Returns the header (with counts), or nil
-- and an error; callers must roll back what the callbacks did on error.
function AnnFormat.readSegment(path, handlers)
    handlers = handlers or {}
    local f, ferr = io.open(path, "rb")
    if not f then return nil, ferr end
    local header, trailer, err
    local nbooks, nrecords, lineno = 0, 0, 0
    local books_seen = {}
    for line in f:lines() do
        lineno = lineno + 1
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if trailer then err = "data after trailer"; break end
        local rec, derr = Codec.decode(line)
        if type(rec) ~= "table" or type(rec.t) ~= "string" then err = derr or "not a record"; break end
        local t = rec.t
        if lineno == 1 then
            if t ~= "h" or rec.format ~= AnnFormat.FORMAT then err = "missing header"; break end
            if rec.v ~= AnnFormat.VERSION then err = "unsupported format version " .. tostring(rec.v); break end
            if not isToken(rec.device) then err = "bad device in header"; break end
            header = rec
        elseif t == "h" then
            err = "second header"; break
        elseif t == "b" then
            if not isToken(rec.md5) then err = "bad md5"; break end
            if (rec.title ~= nil and type(rec.title) ~= "string") or (rec.authors ~= nil and type(rec.authors) ~= "string") then
                err = "bad book record"; break
            end
            nbooks = nbooks + 1
            books_seen[rec.md5] = true
            if handlers.book then handlers.book(rec) end
        elseif t == "a" or t == "x" then
            local ok, verr = validRecord(rec)
            if not ok then err = verr; break end
            if not books_seen[rec.md5] then err = "record before its book record"; break end
            rec.dev = rec.dev or header.device
            if t == "a" then rec.fields_json = Codec.encode(rec.f) end
            nrecords = nrecords + 1
            if handlers.record then handlers.record(rec) end
        elseif t == "end" then
            if rec.books ~= nbooks or rec.records ~= nrecords then err = "record counts don't match trailer"; break end
            trailer = rec
        end
        -- Other record types: a newer minor version, skipped.
    end
    f:close()
    if err then return nil, string.format("line %d: %s", lineno, err) end
    if not header then return nil, "empty file" end
    if not trailer then return nil, "truncated (no trailer)" end
    header.books, header.records = nbooks, nrecords
    return header
end

--- Segment file names: ann-<10-digit sequence>.jsonl.zst
function AnnFormat.segmentName(seq)
    return string.format("ann-%010d.jsonl.zst", seq)
end

function AnnFormat.segmentSeq(name)
    local n = type(name) == "string" and name:match("^ann%-(%d+)%.jsonl%.zst$")
    return n and tonumber(n)
end

return AnnFormat
