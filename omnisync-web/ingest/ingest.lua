--[[--
Imports new OmniSync segments from the server's Reading/ folder into the
web app's own copy of the merged data, using the plugin's own stores, so the
result is what a device would hold.

    luajit ingest.lua <Reading folder> <data folder>

Reads only. It never writes to the Reading folder and never appears there as
a device. In <data folder> it keeps:
  statistics.sqlite3  KOReader's statistics schema, every device's readings
  state.sqlite3       the plugin's merged state (annotations, book data, identity)
  devices.json        what each device folder holds
Prints one JSON line summing up the run. Exit status 1 on errors that stopped it.
--]]

local script_dir = (arg[0]:match("^(.*)/") or ".")
package.path = script_dir .. "/?.lua;" .. package.path

local K = require("koreader")
local lfs = require("lfs")
local Codec = require("omnisync/codec")
local AnnFormat = require("omnisync/annformat")
local BookFormat = require("omnisync/bookformat")
local IdFormat = require("omnisync/idformat")
local Store = require("omnisync/store")
local AnnStore = require("omnisync/annstore")
local BookStore = require("omnisync/bookstore")
local IdStore = require("omnisync/idstore")
local Zstd = require("omnisync/zstd")
local md5 = require("ffi/sha2").md5

local reading_dir, data_dir = arg[1], arg[2]
if not reading_dir or not data_dir then
    io.stderr:write("usage: luajit ingest.lua <Reading folder> <data folder>\n")
    os.exit(2)
end

local function isDir(p) return lfs.attributes(p, "mode") == "directory" end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function writeAtomic(p, data)
    local tmp = p .. ".part"
    local f = assert(io.open(tmp, "wb"))
    f:write(data)
    f:close()
    assert(os.rename(tmp, p))
end

local summary = { ok = true, started = os.time(), imported = {}, records = {}, bad = {}, errors = {} }

local function finish(code)
    summary.finished = os.time()
    io.stdout:write(Codec.encode(summary), "\n")
    os.exit(code)
end

if not isDir(reading_dir) then
    summary.ok = false
    summary.errors[1] = "Reading folder not found: " .. reading_dir
    finish(1)
end
lfs.mkdir(data_dir)
do
    -- The usual setup mistake: a host folder for the data that this user can't write.
    local probe = data_dir .. "/.write-test"
    local f = io.open(probe, "wb")
    if f then f:close(); os.remove(probe) end
    if not f then
        local p = io.popen("id -u")
        local uid = p and p:read("*l") or "?"
        if p then p:close() end
        summary.ok = false
        summary.errors[1] = string.format("Can't write to the data folder %s (running as user ID %s). "
            .. "Make it writable by that user (e.g. chown -R %s on the host folder), or use a named volume.",
            data_dir, uid, uid)
        finish(1)
    end
end

local stats_path = data_dir .. "/statistics.sqlite3"
local state_path = data_dir .. "/state.sqlite3"
local tmp_path = data_dir .. "/segment.tmp"

local function main()

-- Databases ---------------------------------------------------------------------------

K.createStatsDB(stats_path)

local stores = {
    -- A row per file: the web app gathers a book's versions itself, and shows each file's time.
    stats = Store.new{ sq3 = K.SQ3, stats_path = stats_path, state_path = state_path, join_versions = false },
    ann = AnnStore.new{ sq3 = K.SQ3, state_path = state_path, md5 = md5 },
    book = BookStore.new{ sq3 = K.SQ3, state_path = state_path, md5 = md5 },
    id = IdStore.new{ sq3 = K.SQ3, state_path = state_path },
}
-- Create every store's tables, and use WAL so the web app can read during imports.
stores.stats:openState():close()
for _, s in ipairs({ stores.ann, stores.book, stores.id }) do s:open():close() end
do
    local conn = K.SQ3.open(state_path)
    conn:exec("PRAGMA journal_mode=WAL;")
    conn:close()
end

-- Streams, in import order: identity first, so groups are known before the rest.
local STREAMS = {
    { name = "id", prefix = "id", store = stores.id, seq = IdFormat.segmentSeq, bad_version = IdFormat.BAD_VERSION },
    { name = "book", prefix = "book", store = stores.book, seq = BookFormat.segmentSeq, bad_version = BookFormat.BAD_VERSION },
    { name = "ann", prefix = "ann", store = stores.ann, seq = AnnFormat.segmentSeq, bad_version = AnnFormat.BAD_VERSION },
    { name = "stats", prefix = "seg", store = stores.stats, seq = Codec.segmentSeq, bad_version = nil },
}

-- What's on the server ----------------------------------------------------------------

local devices_dir = reading_dir .. "/devices"
local devices = {} -- id -> { id, name, files = { [stream] = { {name, seq, size, mtime}, ... } }, newest }

if isDir(devices_dir) then
    for id in lfs.dir(devices_dir) do
        local dir = devices_dir .. "/" .. id
        if id:sub(1, 1) ~= "." and isDir(dir) then
            local dev = { id = id, files = {}, newest = 0, counts = {} }
            local meta = readFile(dir .. "/meta.json")
            local ok, m = pcall(Codec.decode, meta or "")
            if ok and type(m) == "table" then
                dev.name = type(m.deviceName) == "string" and m.deviceName or nil
                dev.meta_written = tonumber(m.createdAt)
            end
            for name in lfs.dir(dir) do
                local attr = name:sub(1, 1) ~= "." and lfs.attributes(dir .. "/" .. name)
                if attr and attr.mode == "file" then
                    for _, st in ipairs(STREAMS) do
                        local seq = st.seq(name)
                        if seq then
                            dev.files[st.name] = dev.files[st.name] or {}
                            table.insert(dev.files[st.name], { name = name, seq = seq, size = attr.size, mtime = attr.modification })
                            dev.counts[st.name] = (dev.counts[st.name] or 0) + 1
                            if attr.modification > dev.newest then dev.newest = attr.modification end
                            break
                        end
                    end
                end
            end
            for _, list in pairs(dev.files) do
                table.sort(list, function(a, b) return a.seq < b.seq end)
            end
            devices[id] = dev
        end
    end
end

-- Import ------------------------------------------------------------------------------

local seen = stores.stats:seenSegments() -- one table, shared by every stream
local id_changed = false

for _, st in ipairs(STREAMS) do
    local bad = stores.stats:badSegments(st.bad_version)
    local n_imported, n_records = 0, 0
    for id, dev in pairs(devices) do
        for _, file in ipairs(dev.files[st.name] or {}) do
            local s = seen[id] and seen[id][file.name]
            local b = bad[id] and bad[id][file.name]
            if not s and not (b and b.size == file.size) then
                local path = devices_dir .. "/" .. id .. "/" .. file.name
                local etag = tostring(file.mtime)
                local res, err, kind
                local uok, uerr = Zstd.decompressFile(path, tmp_path)
                if uok then
                    res, err, kind = st.store:importSegment(tmp_path, id, file.name, file.size, etag, os.time())
                else
                    err, kind = "can't decompress: " .. tostring(uerr), "format"
                end
                os.remove(tmp_path)
                if res then
                    n_imported = n_imported + 1
                    n_records = n_records + (res.records or res.events or 0)
                    if st.name == "id" and (res.applied or 0) > 0 then id_changed = true end
                elseif kind == "format" then
                    stores.stats:recordBad(id, file.name, file.size, etag, err, st.bad_version)
                    table.insert(summary.bad, { device = id, name = file.name, reason = err })
                else
                    summary.ok = false
                    table.insert(summary.errors, id .. "/" .. file.name .. ": " .. tostring(err))
                    finish(1)
                end
            end
        end
    end
    summary.imported[st.name] = n_imported
    summary.records[st.name] = n_records
end

if id_changed then
    local changed = stores.id:refreshGroups()
    if next(changed) then stores.book:regroup(changed) end
end

-- What each device folder holds, for the status page.
local list = {}
for _, dev in pairs(devices) do
    list[#list + 1] = { id = dev.id, name = dev.name, newest = dev.newest, meta_written = dev.meta_written,
                        counts = dev.counts }
end
table.sort(list, function(a, b) return a.id < b.id end)
writeAtomic(data_dir .. "/devices.json", Codec.encode(list))

local total = 0
for _, n in pairs(summary.imported) do total = total + n end
summary.changed = total > 0
finish(0)
end

local ok, err = xpcall(main, function(e) io.stderr:write(debug.traceback(tostring(e), 2), "\n"); return e end)
if not ok then
    summary.ok = false
    -- Just the message: its first line, without the "file:line:" it starts with.
    local msg = tostring(err):match("^[^\n]*"):gsub("^[^:]*%.lua:%d+: ", "")
    table.insert(summary.errors, msg)
    finish(1)
end
