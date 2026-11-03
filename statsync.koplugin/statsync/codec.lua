--[[--
JSON and segment-file encoding for statsync.

A small strict JSON reader and writer of its own, rather than KOReader's
`json` module: segment files are an interchange format other devices
read, so the exact output (integers written as integers, fixed key order
for event lines, UTF-8 passed through, control characters escaped) is
pinned down here, and the tests run without KOReader.

A segment is JSON Lines:

    {"t":"h","format":"statsync","v":1,"minor":0,"device":"…","created":…}
    {"t":"b","md5":"…","title":"…","authors":"…","series":"…","language":"…","pages":…,"last_open":…}
    …
    {"t":"e","md5":"…","page":…,"start":…,"dur":…,"tp":…}
    …
    {"t":"end","books":<count>,"events":<count>}

Book records come before the events that use them. The trailer makes a
truncated file detectable. Readers reject an unknown major version `v`,
and skip record types they don't know within a known major version, so
new record types (such as the planned "del") can be added as a minor
version.
--]]

local Codec = {}

Codec.FORMAT = "statsync"
Codec.VERSION = 1 -- major: readers reject other values
Codec.MINOR = 0

-- JSON writing -------------------------------------------------------------

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}
local function escapeChar(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
end

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', escapeChar) .. '"'
end
Codec.encodeString = encodeString

local function encodeNumber(n)
    if n ~= n or n == math.huge or n == -math.huge then
        error("statsync codec: cannot encode " .. tostring(n))
    end
    if n == math.floor(n) and n > -2^53 and n < 2^53 then
        return string.format("%d", n)
    end
    return string.format("%.17g", n)
end

local encode
local function isArray(t)
    local n = #t
    if n == 0 then return getmetatable(t) == Codec.array_mt end
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

encode = function(v, out)
    local tv = type(v)
    if v == nil or v == Codec.null then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        out[#out + 1] = encodeNumber(v)
    elseif tv == "string" then
        out[#out + 1] = encodeString(v)
    elseif tv == "cdata" then -- int64 from SQLite
        out[#out + 1] = encodeNumber(tonumber(v))
    elseif tv == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then error("statsync codec: non-string key") end
                keys[#keys + 1] = k
            end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = encodeString(k)
                out[#out + 1] = ":"
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        error("statsync codec: cannot encode a " .. tv)
    end
end

Codec.null = setmetatable({}, { __tostring = function() return "null" end })
Codec.array_mt = {}

--- Encodes a Lua value as JSON. Object keys are sorted.
function Codec.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- JSON reading -------------------------------------------------------------

local function decodeError(s, pos, msg)
    error({ statsync_json = true, msg = string.format("%s at character %d", msg, pos) }, 0)
end

local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local decodeValue

local function skip(s, pos)
    return s:find("[^ \t\r\n]", pos) or #s + 1
end

local function decodeString(s, pos)
    -- pos is at the opening quote
    local parts = {}
    local i = pos + 1
    while true do
        local j = s:find('["\\%c]', i)
        if not j then decodeError(s, pos, "unterminated string") end
        local c = s:sub(j, j)
        if c == '"' then
            parts[#parts + 1] = s:sub(i, j - 1)
            return table.concat(parts), j + 1
        elseif c == "\\" then
            parts[#parts + 1] = s:sub(i, j - 1)
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local hex = s:match("^%x%x%x%x", j + 2)
                if not hex then decodeError(s, j, "bad \\u escape") end
                local cp = tonumber(hex, 16)
                local nexti = j + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = s:match("^\\u(%x%x%x%x)", nexti)
                    lo = lo and tonumber(lo, 16)
                    if not lo or lo < 0xDC00 or lo > 0xDFFF then
                        decodeError(s, j, "unpaired surrogate")
                    end
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    nexti = nexti + 6
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    decodeError(s, j, "unpaired surrogate")
                end
                parts[#parts + 1] = utf8char(cp)
                i = nexti
            elseif unescapes[e] then
                parts[#parts + 1] = unescapes[e]
                i = j + 2
            else
                decodeError(s, j, "bad escape")
            end
        else
            decodeError(s, j, "control character in string")
        end
    end
end

local function decodeNumber(s, pos)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    -- Stricter than the pattern: no leading zeros, digits after "." and "e".
    if not num or not (num:match("^-?0$") or num:match("^-?0[.eE]") or num:match("^-?[1-9]"))
        or num:match("%.$") or num:match("%.[eE]") or num:match("[eE][-+]?$") then
        decodeError(s, pos, "bad number")
    end
    return tonumber(num), pos + #num
end

local literals = { ["true"] = true, ["false"] = false, ["null"] = Codec.null }

decodeValue = function(s, pos, depth)
    if depth > 32 then decodeError(s, pos, "too deeply nested") end
    pos = skip(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip(s, pos + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            if s:sub(pos, pos) ~= '"' then decodeError(s, pos, "expected a key") end
            local key
            key, pos = decodeString(s, pos)
            pos = skip(s, pos)
            if s:sub(pos, pos) ~= ":" then decodeError(s, pos, "expected ':'") end
            local val
            val, pos = decodeValue(s, pos + 1, depth + 1)
            if obj[key] ~= nil then decodeError(s, pos, "duplicate key " .. key) end
            if val ~= Codec.null then obj[key] = val end
            pos = skip(s, pos)
            local d = s:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then decodeError(s, pos, "expected ',' or '}'") end
            pos = skip(s, pos + 1)
        end
    elseif c == "[" then
        local arr = setmetatable({}, Codec.array_mt)
        pos = skip(s, pos + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local val
            val, pos = decodeValue(s, pos, depth + 1)
            arr[#arr + 1] = val
            pos = skip(s, pos)
            local d = s:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then decodeError(s, pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decodeString(s, pos)
    elseif c == "-" or c:match("%d") then
        return decodeNumber(s, pos)
    else
        for word, val in pairs(literals) do
            if s:sub(pos, pos + #word - 1) == word then return val, pos + #word end
        end
        decodeError(s, pos, "unexpected character")
    end
end

--- Decodes JSON text. Returns the value, or nil and an error message.
-- `null` inside objects drops the key; a top-level null gives Codec.null.
function Codec.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, val, pos = pcall(decodeValue, s, 1, 0)
    if not ok then
        if type(val) == "table" and val.statsync_json then return nil, val.msg end
        return nil, tostring(val)
    end
    if skip(s, pos) <= #s then return nil, "trailing characters at " .. pos end
    return val
end

-- Segment records -----------------------------------------------------------

local function isInt(v, min)
    return type(v) == "number" and v % 1 == 0 and v >= (min or -2^53) and v < 2^53
end

local function isMd5(v)
    -- KOReader's partial MD5 is 32 hex digits; allow any short token.
    return type(v) == "string" and #v > 0 and #v <= 64 and not v:find("[%c\"\\]")
end

--- The event line for (md5, page, start, dur, tp), in the fixed key order
-- the fast path of `parseLine` recognises.
function Codec.eventLine(md5, page, start, dur, tp)
    return string.format('{"t":"e","md5":%s,"page":%d,"start":%d,"dur":%d,"tp":%d}',
        encodeString(md5), page, start, dur, tp)
end

local BOOK_FIELDS = { "title", "authors", "series", "language", "pages", "last_open" }
Codec.BOOK_FIELDS = BOOK_FIELDS

function Codec.bookLine(b)
    local parts = { '{"t":"b","md5":', encodeString(b.md5) }
    for _, k in ipairs(BOOK_FIELDS) do
        local v = b[k]
        if v ~= nil then
            parts[#parts + 1] = ',"' .. k .. '":'
            parts[#parts + 1] = type(v) == "string" and encodeString(v) or encodeNumber(tonumber(v))
        end
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

function Codec.headerLine(device_id, created)
    return Codec.encode{
        t = "h", format = Codec.FORMAT, v = Codec.VERSION, minor = Codec.MINOR,
        device = device_id, created = created,
    }
end

function Codec.trailerLine(nbooks, nevents)
    return string.format('{"t":"end","books":%d,"events":%d}', nbooks, nevents)
end

local FAST_EVENT = '^{"t":"e","md5":"([%w_%-]+)","page":(%-?%d+),"start":(%-?%d+),"dur":(%-?%d+),"tp":(%-?%d+)}$'

--- Parses and validates one line. Returns a record table, or nil and an error.
-- Events come back as { t="e", md5, page, start, dur, tp }.
function Codec.parseLine(line)
    local md5, page, start, dur, tp = line:match(FAST_EVENT)
    local rec
    if md5 then
        rec = { t = "e", md5 = md5, page = tonumber(page), start = tonumber(start),
                dur = tonumber(dur), tp = tonumber(tp) }
    else
        local err
        rec, err = Codec.decode(line)
        if not rec then return nil, err end
        if type(rec) ~= "table" or type(rec.t) ~= "string" then return nil, "not a record" end
    end
    local t = rec.t
    if t == "e" then
        if not isMd5(rec.md5) then return nil, "bad md5" end
        if not (isInt(rec.page, 0) and isInt(rec.start, 0) and isInt(rec.dur, 0) and isInt(rec.tp, 0)) then
            return nil, "bad event fields"
        end
    elseif t == "b" then
        if not isMd5(rec.md5) then return nil, "bad md5" end
        for _, k in ipairs({ "title", "authors", "series", "language" }) do
            if rec[k] ~= nil and type(rec[k]) ~= "string" then return nil, "bad book " .. k end
        end
        for _, k in ipairs({ "pages", "last_open" }) do
            if rec[k] ~= nil and not isInt(rec[k]) then return nil, "bad book " .. k end
        end
    end
    return rec
end

--- Reads a segment file line by line.
-- `handlers.book(rec)` and `handlers.event(rec)` are called in file order
-- (either may be nil). Returns the header, or nil and an error; the
-- callbacks may already have been called for an invalid file, so callers
-- that write as they go must roll back on error.
function Codec.readSegment(path, handlers)
    handlers = handlers or {}
    local f, ferr = io.open(path, "rb")
    if not f then return nil, ferr end
    local header, trailer
    local nbooks, nevents, lineno = 0, 0, 0
    local books_seen = {}
    local err
    for line in f:lines() do
        lineno = lineno + 1
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if trailer then err = "data after trailer"; break end
        local rec, perr = Codec.parseLine(line)
        if not rec then err = perr; break end
        if lineno == 1 then
            if rec.t ~= "h" or rec.format ~= Codec.FORMAT then err = "missing header"; break end
            if rec.v ~= Codec.VERSION then err = "unsupported format version " .. tostring(rec.v); break end
            header = rec
        elseif rec.t == "b" then
            nbooks = nbooks + 1
            books_seen[rec.md5] = true
            if handlers.book then handlers.book(rec) end
        elseif rec.t == "e" then
            if not books_seen[rec.md5] then err = "event before its book record"; break end
            nevents = nevents + 1
            if handlers.event then handlers.event(rec) end
        elseif rec.t == "end" then
            if rec.books ~= nbooks or rec.events ~= nevents then err = "record counts don't match trailer"; break end
            trailer = rec
        elseif rec.t == "h" then
            err = "second header"; break
        end
        -- Other record types: newer minor version, skipped.
    end
    f:close()
    if err then return nil, string.format("line %d: %s", lineno, err) end
    if not header then return nil, "empty file" end
    if not trailer then return nil, "truncated (no trailer)" end
    header.books, header.events = nbooks, nevents
    return header
end

--- Segment file names: seg-<10-digit sequence>.jsonl
function Codec.segmentName(seq)
    return string.format("seg-%010d.jsonl", seq)
end

function Codec.segmentSeq(name)
    local n = type(name) == "string" and name:match("^seg%-(%d+)%.jsonl$")
    return n and tonumber(n)
end

return Codec
