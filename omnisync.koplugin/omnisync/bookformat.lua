--[[--
Book data records and segment files for OmniSync's third stream: things
about a book that the user sets by hand and that are the same on every
device. Each is a property of a book, identified by (md5, prop):

    status              "reading", "abandoned" (on hold) or "complete"
    rating              1 to 5
    note                the review text
    meta.<key>          custom metadata (title, authors, series,
                        series_index, keywords, language, description)
    toc.<kind>          handmade table of contents, { enabled, items }
    flows.<kind>        hidden flows, { enabled, items }
    coll.<id>           in collection <id> (favorites, or one of the user's): true
    hist                last opened (epoch seconds), from the reading history

Collections themselves are properties of a record that isn't a book, its
MD5 "collections" (BookFormat.COLLECTIONS): coll.<id> -> { name }. The ID
stays the same when a collection is renamed (see collsync.lua).

<kind> is "rolling" (CREngine, positions are XPointers) or "paging"
(PDF/DjVu, page numbers), as for annotations.

A segment is JSON Lines, compressed like the others:

    {"t":"h","format":"statsync-book","v":1,"minor":0,"device":"…","created":…}
    {"t":"b","md5":"…","title":"…","authors":"…"}
    {"t":"p","md5":"…","prop":"status","upd":…,"dev":"…","v":"complete"}
    {"t":"x","md5":"…","prop":"rating","upd":…,"dev":"…"}
    {"t":"end","books":n,"records":m}

"p" sets a property, "x" clears it. `upd` is when the change was made
(epoch seconds), `dev` the device that made it. Readers reject an unknown
major version and skip record types they don't know; properties they don't
know are kept and passed on, but never applied.
--]]

local AnnFormat = require("omnisync/annformat")
local Codec = require("omnisync/codec")

local BookFormat = {}

BookFormat.FORMAT = "statsync-book"
BookFormat.VERSION = 1
BookFormat.MINOR = 2
--- Version number recorded with bad segments (apart from the other streams').
BookFormat.BAD_VERSION = 200000 + BookFormat.VERSION * 1000 + BookFormat.MINOR

BookFormat.STATUSES = { reading = true, abandoned = true, complete = true }

--- Custom metadata keys (KOReader's BookInfo props that can be customized).
BookFormat.META_KEYS = { "title", "authors", "series", "series_index", "keywords", "language", "description" }

--- Properties kept in the sidecar's `summary`.
BookFormat.SUMMARY_PROPS = { "status", "rating", "note" }

--- Properties written into books that aren't open (the rest wait for the
-- book to be opened).
BookFormat.CLOSED_PROPS = { status = true, rating = true, note = true }
for _, k in ipairs(BookFormat.META_KEYS) do BookFormat.CLOSED_PROPS["meta." .. k] = true end

--- Properties about the book rather than places in it: every version of a
-- book (files sharing a UUID, see IDENTITY.md) shares them. The handmade
-- TOC and flows hold positions, so they stay with their own file.
-- Collection memberships are shared too (see isGroupProp), and so is
-- when the book was last opened.
BookFormat.GROUP_PROPS = { hist = true }
for prop in pairs(BookFormat.CLOSED_PROPS) do BookFormat.GROUP_PROPS[prop] = true end

--- The reading history property (see histsync.lua).
BookFormat.HISTORY = "hist"

--- The record holding the collections (not a book; not hex, so no MD5 clashes).
BookFormat.COLLECTIONS = "collections"

--- KOReader's own collection, which can't be renamed or removed.
BookFormat.FAVORITES = "favorites"

--- The collection ID of a property, or nil.
function BookFormat.collId(prop)
    local id = type(prop) == "string" and prop:match("^coll%.([%w_%-]+)$")
    if id and #id <= 40 then return id end
end

--- Is this property shared by every version of a book?
function BookFormat.isGroupProp(prop)
    return BookFormat.GROUP_PROPS[prop] or BookFormat.collId(prop) ~= nil
end

local META = {}
for _, k in ipairs(BookFormat.META_KEYS) do META["meta." .. k] = k end

--- The custom metadata key of a property, or nil.
function BookFormat.metaKey(prop) return META[prop] end

local function isInt(v, min, max)
    return type(v) == "number" and v % 1 == 0 and v >= (min or -2^53) and v < (max or 2^53)
end

local function isToken(v, max)
    return type(v) == "string" and #v > 0 and #v <= (max or 64) and not v:find("[%c\"\\]")
end

-- Handmade TOC and hidden flows items: the position is an XPointer
-- (rolling) or a page number (paging).
local function validItems(items, kind, what)
    if items == nil then return true end
    if type(items) ~= "table" then return nil, "bad " .. what .. " items" end
    for _, item in ipairs(items) do
        if type(item) ~= "table" then return nil, "bad " .. what .. " item" end
        if kind == "rolling" then
            if type(item.xpointer) ~= "string" or item.xpointer == "" then
                return nil, what .. " item without an XPointer"
            end
        elseif not isInt(item.page, 0) then
            return nil, what .. " item without a page number"
        end
    end
    return true
end

--- Checks a property's value (as Lua, after decoding). Unknown properties
-- are fine. Returns true or nil and an error.
function BookFormat.validValue(prop, v)
    if prop == "status" then
        if not BookFormat.STATUSES[v] then return nil, "bad status" end
    elseif prop == "rating" then
        if not isInt(v, 1, 6) then return nil, "bad rating" end
    elseif prop == "note" then
        if type(v) ~= "string" then return nil, "bad note" end
    elseif META[prop] then
        if type(v) ~= "string" and type(v) ~= "number" then return nil, "bad " .. prop end
    elseif prop == BookFormat.HISTORY then
        if not isInt(v, 0) then return nil, "bad hist" end
    elseif BookFormat.collId(prop) then
        -- A book's membership, or a collection (on the collections record).
        if v ~= true and not (type(v) == "table" and type(v.name) == "string" and v.name ~= "") then
            return nil, "bad " .. prop
        end
    else
        local what, kind = prop:match("^(%a+)%.(%a+)$")
        if (what == "toc" or what == "flows") and AnnFormat.KINDS[kind] then
            if type(v) ~= "table" then return nil, "bad " .. prop end
            if v.enabled ~= nil and type(v.enabled) ~= "boolean" then return nil, "bad " .. prop .. " enabled" end
            return validItems(v.items, kind, what)
        end
    end
    return true
end

--- Is this a property this version applies?
function BookFormat.known(prop)
    if prop == "status" or prop == "rating" or prop == "note" or META[prop] then return true end
    if prop == BookFormat.HISTORY then return true end
    if BookFormat.collId(prop) then return true end
    local what, kind = prop:match("^(%a+)%.(%a+)$")
    return (what == "toc" or what == "flows") and AnnFormat.KINDS[kind] or false
end

-- Segment lines -------------------------------------------------------------------

local enc = Codec.encodeString

function BookFormat.headerLine(device_id, created)
    return Codec.encode{
        t = "h", format = BookFormat.FORMAT, v = BookFormat.VERSION, minor = BookFormat.MINOR,
        device = device_id, created = created,
    }
end

BookFormat.bookLine = AnnFormat.bookLine

--- A set record (value_json from AnnFormat.encodeValue) or, with value_json
-- nil, a clear.
function BookFormat.recordLine(r)
    local head = string.format('{"t":"%s","md5":%s,"prop":%s,"upd":%d,"dev":%s',
        r.value_json and "p" or "x", enc(r.md5), enc(r.prop), r.updated, enc(r.device))
    if r.value_json then return head .. ',"v":' .. r.value_json .. "}" end
    return head .. "}"
end

function BookFormat.trailerLine(nbooks, nrecords)
    return string.format('{"t":"end","books":%d,"records":%d}', nbooks, nrecords)
end

local function validRecord(rec)
    if not isToken(rec.md5) then return nil, "bad md5" end
    if not isToken(rec.prop) then return nil, "bad prop" end
    if not isInt(rec.upd, 0) then return nil, "bad upd" end
    if rec.dev ~= nil and not isToken(rec.dev) then return nil, "bad dev" end
    if rec.t == "p" then
        if rec.v == nil then return nil, "set without a value" end
        local v = AnnFormat.fromJson(rec.v)
        if BookFormat.collId(rec.prop) and (rec.md5 == BookFormat.COLLECTIONS) ~= (type(v) == "table") then
            return nil, "bad " .. rec.prop
        end
        return BookFormat.validValue(rec.prop, v)
    end
    return true
end

--- Reads a book data segment. handlers.book(rec), handlers.record(rec)
-- (rec.t "p" or "x"; for "p", rec.value_json is the canonical JSON of rec.v)
-- are called in file order. Returns the header (with counts), or nil and an
-- error; callers must roll back what the callbacks did on error.
function BookFormat.readSegment(path, handlers)
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
            if t ~= "h" or rec.format ~= BookFormat.FORMAT then err = "missing header"; break end
            if rec.v ~= BookFormat.VERSION then err = "unsupported format version " .. tostring(rec.v); break end
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
        elseif t == "p" or t == "x" then
            local ok, verr = validRecord(rec)
            if not ok then err = verr; break end
            if not books_seen[rec.md5] then err = "record before its book record"; break end
            rec.dev = rec.dev or header.device
            if t == "p" then rec.value_json = Codec.encode(rec.v) end
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

--- Segment file names: book-<10-digit sequence>.jsonl.zst
function BookFormat.segmentName(seq)
    return string.format("book-%010d.jsonl.zst", seq)
end

function BookFormat.segmentSeq(name)
    local n = type(name) == "string" and name:match("^book%-(%d+)%.jsonl%.zst$")
    return n and tonumber(n)
end

return BookFormat
