#!/usr/bin/env luajit
--[[--
Concordance: prints segment files with descriptive names, for reading by hand.

    luajit tools/concordance-dump.lua [--pretty] [--dates] <file or folder>…

Takes the files of a device folder on the server (seg-, ann-, book- and
id-N.jsonl.zst: statistics, highlights and bookmarks, book data, book
identity), compressed or not, or folders of them (in number order). Each
record is printed as one JSON line, its short tags spelled out:

    {"t":"e","md5":"…","page":12,"start":…,"dur":31,"tp":300}
becomes
    {"type":"event","md5":"…","page":12,"start_time":…,"duration":31,"total_pages":300}

--pretty   one field per line
--dates    times (start_time, updated, created, last_open) as local dates

Only the names change: values are as in the file, and nothing is written.
The files themselves keep their short tags (see codec.lua, annformat.lua,
bookformat.lua and idformat.lua for the formats). Record types and fields
this doesn't know are printed under their own names.

Needs LuaJIT with libzstd (or the zstd command) for compressed files.
--]]

-- The plugin's concordance/codec.lua (its JSON reader and writer), embedded
-- so this file runs on its own. Don't edit it here:
-- scripts/sync-dump-codec.sh copies it in, and the tests fail if it differs.
package.preload["concordance/codec"] = function(...)
-- BEGIN concordance/codec.lua
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

--- Segment file names: seg-<10-digit sequence>.jsonl.zst (zstd-compressed;
-- uncompressed .jsonl segments were 0.2.2's, in another folder).
function Codec.segmentName(seq)
    return string.format("seg-%010d.jsonl.zst", seq)
end

function Codec.segmentSeq(name)
    local n = type(name) == "string" and name:match("^seg%-(%d+)%.jsonl%.zst$")
    return n and tonumber(n)
end

return Codec
-- END concordance/codec.lua
end
local Codec = require("concordance/codec")

-- Formats ----------------------------------------------------------------------

-- Per record type: its name, then its fields in order, as { tag, name }.
-- The header and trailer are the same in every format.
local HEADER = { "header", { { "format" }, { "v", "version" }, { "minor", "minor_version" },
                             { "device" }, { "created" } } }
local function book(extra)
    local fields = { { "md5" }, { "title" }, { "authors" } }
    for _, f in ipairs(extra or {}) do fields[#fields + 1] = f end
    return { "book", fields }
end

local FORMATS = {
    statsync = {
        name = "statistics",
        h = HEADER,
        b = book{ { "series" }, { "language" }, { "pages" }, { "last_open" } },
        e = { "event", { { "md5" }, { "page" }, { "start", "start_time" }, { "dur", "duration" },
                         { "tp", "total_pages" } } },
        ["end"] = { "trailer", { { "books" }, { "events" } } },
    },
    ["statsync-ann"] = {
        name = "highlights and bookmarks",
        h = HEADER,
        b = book(),
        a = { "annotation", { { "md5" }, { "kind" }, { "key" }, { "upd", "updated" }, { "dev", "device" },
                              { "f", "fields" } } },
        x = { "annotation_deleted", { { "md5" }, { "kind" }, { "key" }, { "upd", "updated" }, { "dev", "device" } } },
        ["end"] = { "trailer", { { "books" }, { "records" } } },
    },
    ["statsync-book"] = {
        name = "book data",
        h = HEADER,
        b = book(),
        p = { "property_set", { { "md5" }, { "prop", "property" }, { "upd", "updated" }, { "dev", "device" },
                                { "v", "value" } } },
        x = { "property_cleared", { { "md5" }, { "prop", "property" }, { "upd", "updated" }, { "dev", "device" } } },
        ["end"] = { "trailer", { { "books" }, { "records" } } },
    },
    ["statsync-id"] = {
        name = "book identity",
        h = HEADER,
        i = { "identity", { { "md5" }, { "src", "source" }, { "n", "round" }, { "uuids" }, { "sig", "signature" },
                            { "title" }, { "authors" }, { "ids", "other_ids" } } },
        ["end"] = { "trailer", { { "records" } } },
    },
}

local TIMES = { start_time = true, updated = true, created = true, last_open = true }

-- Reading ----------------------------------------------------------------------

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

local zstd_lib
local function zstdLib()
    if zstd_lib ~= nil then return zstd_lib end
    zstd_lib = false
    local ok, ffi = pcall(require, "ffi")
    if not ok then return false end
    pcall(ffi.cdef, [[
        unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);
        size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t compressedSize);
        unsigned ZSTD_isError(size_t code);
        const char *ZSTD_getErrorName(size_t code);
    ]])
    for _, name in ipairs({ "zstd", "libzstd.so.1", "libzstd.1.dylib" }) do
        local lok, lib = pcall(ffi.load, name)
        if lok then zstd_lib = { ffi = ffi, lib = lib }; break end
    end
    return zstd_lib
end

local function shellQuote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function decompress(path, data)
    local z = zstdLib()
    if z then
        local size = z.lib.ZSTD_getFrameContentSize(data, #data)
        if size < 0xFFFFFFFFFFFFFFFEULL then
            local n = tonumber(size)
            local buf = z.ffi.new("uint8_t[?]", math.max(n, 1))
            local got = z.lib.ZSTD_decompress(buf, n, data, #data)
            if z.lib.ZSTD_isError(got) ~= 0 then
                return nil, "zstd: " .. z.ffi.string(z.lib.ZSTD_getErrorName(got))
            end
            return z.ffi.string(buf, tonumber(got))
        end
    end
    -- No libzstd, or a frame that doesn't say its size: the zstd command.
    local p = io.popen("zstd -dcq -- " .. shellQuote(path) .. " 2>/dev/null")
    local out = p and p:read("*a")
    local ok = p and p:close()
    if not out or out == "" or not ok then return nil, "can't decompress (no libzstd or zstd command?)" end
    return out
end

local function isZstd(data) return data:sub(1, 4) == "\40\181\47\253" end

-- Writing ----------------------------------------------------------------------

local function enc(v) return Codec.encode(v) end

local function dateOf(v)
    if type(v) ~= "number" then return v end
    return os.date("%Y-%m-%d %H:%M:%S", v)
end

--- The record with its fields renamed, as { { name, value }, … } in order.
local function describe(rec, format, opts)
    local spec = format and format[rec.t]
    local out, used = {}, { t = true }
    out[1] = { "type", spec and spec[1] or rec.t }
    for _, f in ipairs(spec and spec[2] or {}) do
        local tag, name = f[1], f[2] or f[1]
        if rec[tag] ~= nil then
            local v = rec[tag]
            if opts.dates and TIMES[name] then v = dateOf(v) end
            out[#out + 1] = { name, v }
        end
        used[tag] = true
    end
    local rest = {}
    for k in pairs(rec) do
        if not used[k] then rest[#rest + 1] = k end
    end
    table.sort(rest)
    for _, k in ipairs(rest) do out[#out + 1] = { k, rec[k] } end
    return out
end

local function render(fields, pretty)
    local parts = {}
    for i, kv in ipairs(fields) do parts[i] = enc(kv[1]) .. ":" .. enc(kv[2]) end
    if pretty then return "{\n  " .. table.concat(parts, ",\n  ") .. "\n}" end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Files ------------------------------------------------------------------------

local function dumpFile(path, opts)
    local data, err = readFile(path)
    if not data then return nil, err end
    if isZstd(data) then
        data, err = decompress(path, data)
        if not data then return nil, err end
    end
    local format
    local lineno, trailer = 0, false
    for line in data:gmatch("[^\n]+") do
        lineno = lineno + 1
        line = line:gsub("\r$", "")
        local rec, perr = Codec.decode(line)
        if type(rec) ~= "table" or type(rec.t) ~= "string" then
            io.stderr:write(string.format("%s: line %d: not a record: %s\n", path, lineno, tostring(perr or line:sub(1, 60))))
        else
            if lineno == 1 then
                format = rec.t == "h" and FORMATS[rec.format] or nil
                if opts.many then
                    print(string.format("# %s (%s)", path, format and format.name or tostring(rec.format)))
                end
                if not format then
                    io.stderr:write(string.format("%s: unknown format %s: tags printed as they are\n",
                        path, tostring(rec.format)))
                end
            end
            if rec.t == "end" then trailer = true end
            print(render(describe(rec, format, opts), opts.pretty))
        end
    end
    if lineno == 0 then return nil, "empty file" end
    if not trailer then io.stderr:write(path .. ": no trailer (truncated?)\n") end
    return true
end

local function segmentFiles(dir)
    local p = io.popen("ls -1 -- " .. shellQuote(dir) .. " 2>/dev/null")
    local names = {}
    for name in (p and p:read("*a") or ""):gmatch("[^\n]+") do
        local prefix, n = name:match("^(%a+)%-(%d+)%.jsonl")
        if prefix and not name:match("%.part$") then names[#names + 1] = { name = name, prefix = prefix, n = tonumber(n) } end
    end
    if p then p:close() end
    table.sort(names, function(a, b)
        if a.prefix ~= b.prefix then return a.prefix < b.prefix end
        return a.n < b.n
    end)
    local out = {}
    for i, e in ipairs(names) do out[i] = dir .. "/" .. e.name end
    return out
end

local function isDir(path)
    local p = io.popen("test -d " .. shellQuote(path) .. " && echo d")
    local r = p and p:read("*a")
    if p then p:close() end
    return r and r:match("^d") ~= nil
end

-- Main -------------------------------------------------------------------------

local opts, paths = {}, {}
for _, a in ipairs(arg or {}) do
    if a == "--pretty" then opts.pretty = true
    elseif a == "--dates" then opts.dates = true
    elseif a == "-h" or a == "--help" then paths = nil; break
    elseif a:sub(1, 2) == "--" then io.stderr:write("unknown option " .. a .. "\n"); os.exit(2)
    else paths[#paths + 1] = a end
end
if not paths or #paths == 0 then
    io.stderr:write("usage: luajit tools/concordance-dump.lua [--pretty] [--dates] <file or folder>…\n")
    os.exit(paths and 2 or 0)
end

local files = {}
for _, p in ipairs(paths) do
    if isDir(p) then
        for _, f in ipairs(segmentFiles(p)) do files[#files + 1] = f end
    else
        files[#files + 1] = p
    end
end
opts.many = #files > 1
local failed = false
for _, f in ipairs(files) do
    local ok, err = dumpFile(f, opts)
    if not ok then io.stderr:write(f .. ": " .. tostring(err) .. "\n"); failed = true end
end
os.exit(failed and 1 or 0)
