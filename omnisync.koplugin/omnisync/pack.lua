--[[--
Packs: one segment in place of a run of a device's small segments.

Most syncs upload a small segment (a reading session, a few highlights),
so a device's folder fills up with them: thousands a year. Listing them all
gets slower, and a new device downloads them one by one. So once a day each
device packs its own small segments: it downloads a run of them, writes
their records into one file, and uploads it as its next segment, like any
other (see netjob.lua, step 5). Every device imports it as it would any
segment, whatever its version: importing what it already has changes
nothing. A week later the owner deletes the segments the pack holds, so
devices that join later download the pack instead of all of them.

A pack holds exactly what importing its segments would leave in the
database, as merging is order independent and idempotent:

- statistics: every book record (they merge by last opened), and per
  reading (md5, page, start) the longest one;
- annotations and book data: per key the records with the highest
  (updated, device) (the importer breaks ties by content hash, so all
  tied ones are kept), and each book's first title record.

This runs in the network subprocess, without any database.
--]]

local AnnFormat = require("omnisync/annformat")
local BookFormat = require("omnisync/bookformat")
local IdFormat = require("omnisync/idformat")
local Codec = require("omnisync/codec")

local Pack = {}

--- Packs are made of at least MIN segments, at most MAX, each no bigger
-- than SMALL bytes (compressed): bigger ones, such as a first sync's, are
-- left as they are. A pack holds no more records than one upload (the
-- per-stream caps), so importing it blocks no longer than any segment.
Pack.MIN = 100
Pack.MAX = 500
Pack.SMALL = 64 * 1024
--- Seconds between making a pack and deleting the segments it holds, so
-- devices part way through a sync, or a day behind, aren't caught out.
Pack.GRACE = 7 * 24 * 3600

-- Builders: :read(path) -> segment or nil, err; :size(segment) -> records it
-- adds at most; :add(segment); :count(); :write(path, device_id, now).

local function writeLines(path, lines)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    for _, line in ipairs(lines) do f:write(line, "\n") end
    f:close()
    return true
end

local StatsBuilder = {}
StatsBuilder.__index = StatsBuilder

function StatsBuilder.new()
    return setmetatable({ books = {}, book_lines = {}, events = {}, n = 0 }, StatsBuilder)
end

function StatsBuilder:read(path)
    local seg = { books = {}, events = {} }
    local header, err = Codec.readSegment(path, {
        book = function(b) table.insert(seg.books, b) end,
        event = function(e) table.insert(seg.events, e) end,
    })
    if not header then return nil, err end
    return seg
end

function StatsBuilder:size(seg) return #seg.events end

function StatsBuilder:add(seg)
    for _, b in ipairs(seg.books) do
        local line = Codec.bookLine(b)
        if not self.books[line] then
            self.books[line] = true
            table.insert(self.book_lines, line)
        end
    end
    for _, e in ipairs(seg.events) do
        local k = e.md5 .. "\0" .. e.page .. "\0" .. e.start
        local cur = self.events[k]
        if not cur then
            self.events[k] = e
            self.n = self.n + 1
        elseif e.dur > cur.dur or (e.dur == cur.dur and e.tp > cur.tp) then
            self.events[k] = e
        end
    end
end

function StatsBuilder:count() return self.n end

function StatsBuilder:write(path, device_id, now)
    local events = {}
    for _, e in pairs(self.events) do table.insert(events, e) end
    table.sort(events, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        if a.md5 ~= b.md5 then return a.md5 < b.md5 end
        return a.page < b.page
    end)
    local lines = { Codec.headerLine(device_id, now) }
    for _, line in ipairs(self.book_lines) do table.insert(lines, line) end
    for _, e in ipairs(events) do table.insert(lines, Codec.eventLine(e.md5, e.page, e.start, e.dur, e.tp)) end
    table.insert(lines, Codec.trailerLine(#self.book_lines, #events))
    return writeLines(path, lines)
end

-- Annotations and book data: last-writer-wins records per key.
local LwwBuilder = {}
LwwBuilder.__index = LwwBuilder

local LWW = {
    ann = {
        format = AnnFormat,
        key = function(r) return r.md5 .. "\0" .. r.kind .. "\0" .. r.key end,
        line = function(r)
            return AnnFormat.recordLine{ md5 = r.md5, kind = r.kind, key = r.key, updated = r.upd, device = r.dev,
                                         fields_json = r.t == "a" and r.fields_json or nil }
        end,
    },
    book = {
        format = BookFormat,
        key = function(r) return r.md5 .. "\0" .. r.prop end,
        line = function(r)
            return BookFormat.recordLine{ md5 = r.md5, prop = r.prop, updated = r.upd, device = r.dev,
                                          value_json = r.t == "p" and r.value_json or nil }
        end,
    },
}

function LwwBuilder.new(stream)
    return setmetatable({ def = LWW[stream], books = {}, book_order = {}, keys = {}, n = 0 }, LwwBuilder)
end

function LwwBuilder:read(path)
    local seg = { books = {}, records = {} }
    local header, err = self.def.format.readSegment(path, {
        book = function(b) table.insert(seg.books, b) end,
        record = function(r) table.insert(seg.records, r) end,
    })
    if not header then return nil, err end
    return seg
end

function LwwBuilder:size(seg) return #seg.records end

function LwwBuilder:add(seg)
    for _, b in ipairs(seg.books) do
        if not self.books[b.md5] then
            self.books[b.md5] = self.def.format.bookLine(b)
            table.insert(self.book_order, b.md5)
        end
    end
    for _, r in ipairs(seg.records) do
        local k = self.def.key(r)
        local cur = self.keys[k]
        local line = self.def.line(r)
        if not cur or r.upd > cur.upd or (r.upd == cur.upd and r.dev > cur.dev) then
            self.n = self.n - (cur and #cur.lines or 0) + 1
            self.keys[k] = { upd = r.upd, dev = r.dev, lines = { line }, set = { [line] = true } }
        elseif r.upd == cur.upd and r.dev == cur.dev and not cur.set[line] then
            cur.set[line] = true
            table.insert(cur.lines, line)
            self.n = self.n + 1
        end
    end
end

function LwwBuilder:count() return self.n end

function LwwBuilder:write(path, device_id, now)
    local fmt = self.def.format
    local lines = { fmt.headerLine(device_id, now) }
    for _, md5 in ipairs(self.book_order) do table.insert(lines, self.books[md5]) end
    local keys = {}
    for k in pairs(self.keys) do table.insert(keys, k) end
    table.sort(keys)
    local n = 0
    for _, k in ipairs(keys) do
        for _, line in ipairs(self.keys[k].lines) do
            table.insert(lines, line)
            n = n + 1
        end
    end
    table.insert(lines, fmt.trailerLine(#self.book_order, n))
    return writeLines(path, lines)
end

-- Book identity: a set of facts; each distinct record once.
local IdBuilder = {}
IdBuilder.__index = IdBuilder

function IdBuilder.new()
    return setmetatable({ lines = {}, n = 0 }, IdBuilder)
end

function IdBuilder:read(path)
    local seg = { records = {} }
    local header, err = IdFormat.readSegment(path, {
        record = function(r) table.insert(seg.records, r) end,
    })
    if not header then return nil, err end
    return seg
end

function IdBuilder:size(seg) return #seg.records end

function IdBuilder:add(seg)
    for _, r in ipairs(seg.records) do
        local line = IdFormat.recordLine(r)
        if not self.lines[line] then
            self.lines[line] = true
            self.n = self.n + 1
        end
    end
end

function IdBuilder:count() return self.n end

function IdBuilder:write(path, device_id, now)
    local sorted = {}
    for line in pairs(self.lines) do sorted[#sorted + 1] = line end
    table.sort(sorted)
    local lines = { IdFormat.headerLine(device_id, now) }
    for _, line in ipairs(sorted) do lines[#lines + 1] = line end
    lines[#lines + 1] = IdFormat.trailerLine(#sorted)
    return writeLines(path, lines)
end

--- A builder for a stream ("stats", "ann", "book" or "id").
function Pack.builder(stream)
    if stream == "stats" then return StatsBuilder.new() end
    if stream == "id" then return IdBuilder.new() end
    return LwwBuilder.new(stream)
end

return Pack
