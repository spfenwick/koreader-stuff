--[[--
The network part of a sync. Runs in a subprocess; doesn't touch any database.

With a transport (see webdav.lua) rooted at <configured folder>/Reading:

1. List devices/ (PROPFIND, Depth 1). Create the folders on first use, and
   this device's meta.json; write it again when it changed (params.rewrite_meta),
   on any sync.
2. On a full listing (first sync, "Sync now", rebuild, and once a day, or
   once a week on a device that has sent nothing: see engine.lua): list
   every device folder too. This also deletes this device's leftover
   temporary uploads and finds segments out of sequence.
3. Upload the new segment (if any) as the next sequence number, and check
   it's there with the right size.
4. Download segments not imported yet. On a full listing, every one listed
   that isn't seen or known bad; otherwise, for each device, the segment
   numbers from the first one not imported, skipping imported ones, until
   one isn't there (a 404). So an ordinary sync costs one small listing
   plus one request per device, however long the history; and on servers
   whose folder dates can be trusted, nothing for a device folder that
   hasn't changed since this device last went through it (see below).
5. On a full listing with params.pack: pack this device's own small
   segments into one (see pack.lua), and delete the segments of packs made
   long enough ago (params.pack.delete).

A device writes the first number not in use above the highest one it has
used itself (seen here, or, for a device restored from a backup, the
highest packed one its meta.json gives): never a lower free one, as a
number once used may have been imported by others even if its segment has
since gone into a pack (and been deleted). So numbers stay contiguous, and
readers can ask for "the next one" by name; a reader that finds a gap (the
segments of a pack, deleted) carries on after the highest number it has.
Anything else out of sequence (a stray file) is picked up by the next full
listing.

Folder dates: the listing of devices/ gives each device folder's last
modified date, which changes whenever a segment is moved in or deleted (on
most servers: rclone, for one, keeps reporting the date it first saw).
params.folders says, per device folder, the date it had when this device
last went through it completely (and for which streams). An ordinary sync
skips a folder whose date hasn't changed since; the caller passes folders
only once this device's own folder has been seen to change date after an
upload (params.own_check: its date before the last upload; a changed date
sets result.dates_confirmed, the same one result.dates_unreliable). Full
listings still list every folder, and check: a folder whose date didn't
change but that holds segments this device hasn't seen also means the
server's dates can't be trusted.
result.folders gives each folder's date (and whether it's old enough to
rely on: a few seconds older than the server's clock) and the streams gone
through completely, for the caller to record once the downloads are
imported.

params.named: { [device id] = name } of the devices already named, and
params.meta_tags: { [device id] = tag } of the meta.json each was read from
(NetJob.metaTag). Up to MAX_NAME_FETCHES others have their meta.json read: a
device not read yet, or on a full listing, one whose meta.json changed
(result.device_names, result.device_meta_tags).

Downloads go to tmp_dir, each to a .part file renamed when complete.
`report(result)` is called after each step that changes the result, so the
caller can save it: if the subprocess is killed for taking too long, what
was done so far (complete downloads, a verified upload) is still used.

There are four streams of segments in each device folder: statistics
(seg-N), annotations (ann-N), book data (book-N) and book identity (id-N).
Each has its own numbering; steps 3 to 5 run for each stream the sync is
for (params.stats unless false, params.ann, params.book and params.id when
given).

params.expect_own: this device has files in the folder already (it has
sent some). If its folder isn't there, the folder is a different one, for
example a new one the old files haven't been copied to yet: writing there
would start numbering from 1 again, and clash with the copies. So the step
stops with result.missing_own, before creating anything.

Result: { ok, error, stage, full_listed, uploaded = { name, size, etag,
          verified }, upload_error, ann_uploaded, ann_upload_error, book_uploaded,
          book_upload_error, id_uploaded, id_upload_error, missing_own,
          devices = { id, … }, downloads = { {stream, device, name, size,
          etag, path}, … }, remote_more, segment_errors,
          packed = { {stream, name, first, last, size, etag}, … },
          deleted = { [pack name] = segments deleted }, left = { [pack name]
          = its segments still there },
          folders = { [id] = { modified, reliable, complete = { [stream] = true } } },
          device_names = { [id] = name } and device_meta_tags = { [id] = tag }
          (the meta.json files read),
          own_modified, own_reliable, dates_confirmed, dates_unreliable,
          bytes_up, bytes_down, requests }
(stream is "stats", "ann", "book" or "id").
--]]

local AnnFormat = require("concordance/annformat")
local BookFormat = require("concordance/bookformat")
local IdFormat = require("concordance/idformat")
local Codec = require("concordance/codec")
local Pack = require("concordance/pack")

local NetJob = {}

NetJob.DEVICES = "devices"
--- Other devices' meta.json read per sync for their names.
NetJob.MAX_NAME_FETCHES = 4

--- What tells one version of a listed (or fetched) file from another: its
-- etag, else its size and date; nil when the server gives none of them.
function NetJob.metaTag(e)
    if type(e) ~= "table" then return nil end
    if type(e.etag) == "string" and e.etag ~= "" then return "e:" .. e.etag end
    if e.size or e.modified then return "s:" .. tostring(e.size) .. "@" .. tostring(e.modified) end
    return nil
end

--- A folder date is relied on only when it's at least this many seconds
-- older than the server's clock: a segment moved in during the same second
-- wouldn't change it.
NetJob.DATE_MARGIN = 2

function NetJob.validDeviceId(id)
    return type(id) == "string" and #id >= 4 and #id <= 64 and not id:find("[^%w%-_]")
end

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

NetJob.STREAMS = {
    stats = { name = Codec.segmentName, seq = Codec.segmentSeq, result = "uploaded", err = "upload_error" },
    ann = { name = AnnFormat.segmentName, seq = AnnFormat.segmentSeq, result = "ann_uploaded",
            err = "ann_upload_error" },
    book = { name = BookFormat.segmentName, seq = BookFormat.segmentSeq, result = "book_uploaded",
             err = "book_upload_error" },
    id = { name = IdFormat.segmentName, seq = IdFormat.segmentSeq, result = "id_uploaded",
           err = "id_upload_error" },
}

--- The first segment number (from 1) for which used(name) is false.
local function firstFree(used, segmentName)
    local n = 1
    while used(segmentName(n)) do n = n + 1 end
    return n
end

--- The highest segment number among these names (0 if none).
local function highest(def, names)
    local top = 0
    for name in pairs(names) do
        local s = def.seq(name)
        if s and s > top then top = s end
    end
    return top
end

local function listedNames(entries)
    local set = {}
    for _, e in ipairs(entries) do
        if not e.is_dir then set[e.name] = true end
    end
    return set
end

--- An HTTP date (RFC 1123, as WebDAV servers give them) in seconds since
-- the epoch, or nil.
function NetJob.parseHttpDate(s)
    if type(s) ~= "string" then return nil end
    local d, mon, y, h, mi, sec = s:match("(%d+) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d)")
    local months = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
    local m = months[mon or ""]
    if not m then return nil end
    y, d = tonumber(y), tonumber(d)
    -- Days from the civil date (no time zones: the dates are GMT).
    local yy = m <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
end

--- params: device_id, pending = { path, size } | nil, meta_path,
--  seen and bad ({ [device] = { [name] = { size, etag } } }), full_list (bool),
--  tmp_dir, max_download_bytes (optional), stats (false: annotations only),
--  expect_own, and for annotations
--  ann = { pending = { path, size } | nil, bad } (seen is shared: names differ),
--  and for book data and book identity, book and id (the same shape); rewrite_meta (this device's
--  meta.json on the server is out of date: written on this sync);
--  folders ({ [id] = { modified,
--  streams = { [stream] = true } } }, nil when the server's dates can't be
--  trusted) and own_check (see above); and pack = { after = { [stream] =
--  last segment number packed }, delete = { { stream, name, first, last,
--  holders = { name, … } }, … }, deadline (os.time() after which no more
--  segments are gathered for a pack), caps = { stats, ann, book, id } (records
--  at most), zstd (optional) }
function NetJob.run(params, transport, report)
    report = report or function() end
    local result = { stage = "start", devices = {}, downloads = {}, segment_errors = {},
                     packed = {}, deleted = {}, left = {}, folders = {} }
    local function update(stage)
        result.stage = stage
        result.bytes_up, result.bytes_down, result.requests = transport.bytes_up, transport.bytes_down, transport.requests
        report(result)
    end
    local function failed(msg)
        result.ok = false
        result.error = msg
        update("failed")
        return result
    end
    local function segErr(msg) table.insert(result.segment_errors, msg) end

    local own_id = params.device_id
    local own = NetJob.DEVICES .. "/" .. own_id
    local seen = params.seen or {}
    local streams = {}
    if params.stats ~= false then
        table.insert(streams, { id = "stats", def = NetJob.STREAMS.stats, pending = params.pending, bad = params.bad or {} })
    end
    if params.ann then
        table.insert(streams, { id = "ann", def = NetJob.STREAMS.ann, pending = params.ann.pending, bad = params.ann.bad or {} })
    end
    if params.book then
        table.insert(streams, { id = "book", def = NetJob.STREAMS.book, pending = params.book.pending,
                                bad = params.book.bad or {} })
    end
    if params.id then
        table.insert(streams, { id = "id", def = NetJob.STREAMS.id, pending = params.id.pending,
                                bad = params.id.bad or {} })
    end
    local function known(id, stream)
        local s, b = seen[id] or {}, stream.bad[id] or {}
        return function(name) return s[name] ~= nil or b[name] ~= nil end
    end

    -- 1. Devices
    local function missingOwn()
        result.missing_own = true
        return failed("this device's earlier files aren't in this folder on the server")
    end
    local dev_entries, err, code = transport:list(NetJob.DEVICES)
    if not dev_entries then
        if code ~= 404 and code ~= 409 then return failed("listing devices: " .. tostring(err)) end
        if params.expect_own then return missingOwn() end
        for _, dir in ipairs({ "", NetJob.DEVICES }) do
            local ok, merr
            if dir == "" and transport.mkdir_root then ok, merr = transport:mkdir_root()
            else ok, merr = transport:mkdir(dir) end
            if not ok then return failed("creating " .. (dir == "" and "sync folder" or dir) .. ": " .. tostring(merr)) end
        end
        dev_entries = {}
    end
    local server_time = NetJob.parseHttpDate(dev_entries.server_date)
    local ids, own_exists = {}, false
    local dates = {} -- id -> { modified, reliable }
    for _, d in ipairs(dev_entries) do
        if d.is_dir and NetJob.validDeviceId(d.name) then
            ids[#ids + 1] = d.name
            if d.name == own_id then own_exists = true end
            local t = NetJob.parseHttpDate(d.modified)
            dates[d.name] = { modified = d.modified,
                              reliable = t and server_time and t <= server_time - NetJob.DATE_MARGIN or false }
        end
    end
    table.sort(ids)
    result.devices = ids

    -- This device's own folder kept its date across the upload last time:
    -- dates on this server don't follow changes.
    local own_date = dates[own_id]
    if params.own_check and own_date then
        if own_date.modified == params.own_check then
            result.dates_unreliable = true
        elseif own_date.modified then
            result.dates_confirmed = true
        end
    end
    result.own_modified = own_date and own_date.modified
    result.own_reliable = own_date and own_date.reliable or false

    -- Unchanged since this device last went through it, for this stream?
    local folders = (not result.dates_unreliable) and params.folders or nil
    local function unchanged(id, stream_id)
        local rec, now = folders and folders[id], dates[id]
        return rec ~= nil and now ~= nil and now.modified ~= nil and rec.modified == now.modified
            and rec.streams ~= nil and rec.streams[stream_id] == true and next(seen[id] or {}) ~= nil
    end

    local listings = {} -- device id -> entries, when listed
    if not own_exists then
        if params.expect_own then return missingOwn() end
        local ok, merr = transport:mkdir(own)
        if not ok then return failed("creating own folder: " .. tostring(merr)) end
        listings[own_id] = {}
        table.insert(result.devices, own_id)
        table.sort(result.devices)
    end

    -- 2. Full listing
    local full_ok = params.full_list
    if params.full_list then
        for _, id in ipairs(ids) do
            local entries, lerr = transport:list(NetJob.DEVICES .. "/" .. id)
            if entries then
                listings[id] = entries
            else
                full_ok = false
                segErr("listing " .. id .. ": " .. tostring(lerr))
            end
        end
    end
    -- Other devices' names, from their meta.json (a few per sync): to say
    -- where a book was last read. Each is read once, then again when a full
    -- listing shows its meta.json changed (a new name or plugin version).
    if params.named then
        local named, tags = params.named, params.meta_tags or {}
        local asked = 0
        for _, id in ipairs(ids) do
            if id ~= own_id and asked < NetJob.MAX_NAME_FETCHES then
                local listed, listed_tag = listings[id], nil
                if listed then
                    for _, e in ipairs(listed) do
                        if e.name == "meta.json" and not e.is_dir then listed_tag = NetJob.metaTag(e) or "?"; break end
                    end
                end
                local known = named[id] ~= nil or tags[id] ~= nil
                local want
                if listed then
                    -- No meta.json there: nothing to read. A server that gives
                    -- nothing to tell versions apart ("?"): read every full listing.
                    want = listed_tag ~= nil and (not known or listed_tag == "?" or listed_tag ~= tags[id])
                else
                    want = not known
                end
                if want then
                    asked = asked + 1
                    local path = params.tmp_dir .. "/name-meta.json.part"
                    local ok, info, code = transport:get(NetJob.DEVICES .. "/" .. id .. "/meta.json", path)
                    local f = ok and io.open(path, "rb")
                    local meta = f and Codec.decode(f:read("*a"))
                    if f then f:close() end
                    os.remove(path)
                    if ok or code == 404 then
                        -- "-": none there yet (read when a full listing shows one).
                        result.device_meta_tags = result.device_meta_tags or {}
                        result.device_meta_tags[id] = not ok and "-" or listed_tag
                            or (type(info) == "table" and NetJob.metaTag(info)) or "?"
                    end
                    if type(meta) == "table" and type(meta.deviceName) == "string" and meta.deviceName ~= "" then
                        result.device_names = result.device_names or {}
                        result.device_names[id] = meta.deviceName:sub(1, 64)
                    end
                end
            end
        end
    end

    local own_listing = listings[own_id]
    local packed_floor = {} -- stream -> highest packed number, from meta.json on the server
    local function readOwnMeta()
        local path = params.tmp_dir .. "/own-meta.json.part"
        local ok = transport:get(own .. "/meta.json", path)
        local f = ok and io.open(path, "rb")
        local meta = f and Codec.decode(f:read("*a"))
        if f then f:close() end
        os.remove(path)
        if type(meta) == "table" and type(meta.packed) == "table" then
            for k, v in pairs(meta.packed) do
                if type(v) == "number" then packed_floor[k] = v end
            end
        end
    end
    -- Writes this device's meta.json, keeping any higher packed number the
    -- server's copy gave (a device restored from an old backup knows fewer
    -- packs than it made).
    local function writeOwnMeta()
        local path = params.meta_path
        local f = io.open(path, "rb")
        local meta = f and Codec.decode(f:read("*a"))
        if f then f:close() end
        if type(meta) == "table" then
            local raised = false
            for k, v in pairs(packed_floor) do
                meta.packed = meta.packed or {}
                if v > (tonumber(meta.packed[k]) or 0) then meta.packed[k] = v; raised = true end
            end
            if raised then
                path = params.tmp_dir .. "/own-meta.json.new"
                local out = io.open(path, "wb")
                if out then out:write(Codec.encode(meta)); out:close() else path = params.meta_path end
            end
        end
        local ok, perr = transport:put(own .. "/meta.json", path)
        if path ~= params.meta_path then os.remove(path) end
        if ok then result.meta_written = true else segErr("writing meta.json: " .. tostring(perr)) end
    end
    if own_listing then
        local has_meta = false
        for _, e in ipairs(own_listing) do
            if e.name == "meta.json" then has_meta = true end
            if e.name:match("^%.upload%-.*%.part$") then transport:delete(own .. "/" .. e.name) end
        end
        if has_meta then readOwnMeta() end
        if (not has_meta or params.rewrite_meta) and params.meta_path then writeOwnMeta() end
    elseif params.rewrite_meta and params.meta_path then
        -- An ordinary sync, and the name, plugin versions or packs changed:
        -- written now rather than at the next full listing (two requests).
        readOwnMeta()
        writeOwnMeta()
    end
    update("listed")

    -- The highest number this device has used in a stream: what it has seen
    -- of its own (its uploads and packs), or its meta.json's highest pack.
    local function floorOf(stream)
        return math.max(highest(stream.def, seen[own_id] or {}), packed_floor[stream.id] or 0)
    end

    -- 3. Upload, as the first free number above the highest used.
    local function freeAbove(floor, used, def)
        local n = floor + 1
        while used(def.name(n)) do n = n + 1 end
        return n
    end
    local function upload(stream)
        local def = stream.def
        local used
        if listings[own_id] then
            local names = listedNames(listings[own_id])
            used = function(name) return names[name] end
        else
            used = known(own_id, stream)
        end
        local floor = floorOf(stream)
        local next_seq = freeAbove(floor, used, def)
        local up, up_err
        for _ = 1, 3 do
            local name = def.name(next_seq)
            local ok, uerr = transport:put_new(own .. "/" .. name, stream.pending.path)
            if ok then
                up = { name = name, size = stream.pending.size, verified = false }
                local st = transport:stat(own .. "/" .. name)
                if st and (st.size == nil or st.size == stream.pending.size) then
                    up.verified = true
                    up.etag = st.etag
                    -- The server gave no size: found, but not compared.
                    if st.size == nil then up.unchecked = true end
                else
                    up_err = "upload not found with the right size"
                end
                break
            elseif ok == false then
                -- Name taken: this device's record of its own segments is
                -- behind (restored from a backup, or an ID shared with another
                -- device). Find the real highest number.
                local entries, lerr = transport:list(own)
                if not entries then
                    up_err = "listing own folder: " .. tostring(lerr)
                    break
                end
                listings[own_id] = entries
                local names = listedNames(entries)
                next_seq = freeAbove(math.max(floor, next_seq), function(n) return names[n] end, def)
            else
                up_err = tostring(uerr)
                break
            end
        end
        if not up and not up_err then up_err = "no free segment name" end
        result[def.result] = up
        result[def.err] = up_err
        stream.uploaded_name = up and up.name
        stream.uploaded_seq = up and next_seq
    end
    for _, stream in ipairs(streams) do
        if stream.pending then
            upload(stream)
            update("uploaded")
        end
    end

    -- 4. Downloads, oldest first per device
    local budget = params.max_download_bytes or math.huge
    local downloaded = 0
    local function download(stream, id, name, size, etag)
        local final = params.tmp_dir .. "/" .. id .. "__" .. name
        local part = final .. ".part"
        local ok, info, gcode = transport:get(NetJob.DEVICES .. "/" .. id .. "/" .. name, part)
        if not ok then
            os.remove(part)
            return nil, info, gcode
        end
        local got = fileSize(part)
        if (size and got ~= size) or not os.rename(part, final) then
            os.remove(part)
            return nil, "size mismatch"
        end
        downloaded = downloaded + got
        table.insert(result.downloads, { stream = stream.id, device = id, name = name, size = got,
                                         etag = etag or (type(info) == "table" and info.etag) or nil, path = final })
        update("downloading")
        return true
    end

    local complete = {} -- id -> { [stream] = true }: gone through, nothing left behind
    local function done(id, stream_id)
        complete[id] = complete[id] or {}
        complete[id][stream_id] = true
    end

    local function downloadStream(stream)
        local def = stream.def
        local up_name = stream.uploaded_name
        for _, id in ipairs(result.devices) do
            if downloaded >= budget then result.remote_more = true; break end
            local dev_seen, dev_bad = seen[id] or {}, stream.bad[id] or {}
            local entries = listings[id]
            local whole = true -- nothing failed or was put off for this folder
            if entries then
                local cands = {}
                for _, e in ipairs(entries) do
                    local seq = not e.is_dir and def.seq(e.name)
                    if seq and not (id == own_id and e.name == up_name) then
                        local s, b = dev_seen[e.name], dev_bad[e.name]
                        if s then
                            if s.size and e.size and s.size ~= e.size then
                                segErr(id .. "/" .. e.name .. " changed size since it was imported")
                            end
                        elseif not (b and b.size == e.size and (b.etag == nil or b.etag == e.etag)) then
                            cands[#cands + 1] = { name = e.name, seq = seq, size = e.size, etag = e.etag }
                        end
                    end
                end
                -- The folder's date says nothing changed since this device
                -- went through it, yet there's something new: the dates
                -- can't be trusted.
                if #cands > 0 and unchanged(id, stream.id) then result.dates_unreliable = true end
                table.sort(cands, function(a, b) return a.seq < b.seq end)
                for _, c in ipairs(cands) do
                    if downloaded >= budget then result.remote_more = true; whole = false; break end
                    local ok, derr = download(stream, id, c.name, c.size, c.etag)
                    if not ok then
                        whole = false
                        segErr(id .. "/" .. c.name .. ": " .. tostring(derr))
                    end
                end
            elseif unchanged(id, stream.id) then
                -- Skipped: nothing changed in this folder.
                whole = true
            else
                local is_known = known(id, stream)
                local seq = firstFree(is_known, def.name)
                -- A gap below numbers already seen (a pack's segments,
                -- deleted): carry on once after the highest seen.
                local top = highest(def, dev_seen)
                if id == own_id and stream.uploaded_seq and stream.uploaded_seq > top then top = stream.uploaded_seq end
                while true do
                    if downloaded >= budget then result.remote_more = true; whole = false; break end
                    local name = def.name(seq)
                    if not (is_known(name) or (id == own_id and name == up_name)) then
                        local ok, derr, dcode = download(stream, id, name)
                        if not ok then
                            if dcode ~= 404 then
                                whole = false
                                segErr(id .. "/" .. name .. ": " .. tostring(derr))
                                break
                            end
                            if seq >= top then break end
                            seq = top
                        end
                    end
                    seq = seq + 1
                end
            end
            if whole then done(id, stream.id) end
        end
    end
    for _, stream in ipairs(streams) do downloadStream(stream) end

    for _, id in ipairs(result.devices) do
        local d = dates[id]
        -- This device's own folder changes with its own upload: its date
        -- from before it is no use for the next sync.
        local changed_own = id == own_id and (result.uploaded or result.ann_uploaded or result.book_uploaded
            or result.id_uploaded)
        if d and d.modified and not changed_own then
            result.folders[id] = { modified = d.modified, reliable = d.reliable, complete = complete[id] or {} }
        end
    end

    -- 5. Packing this device's own small segments
    if params.pack and full_ok and listings[own_id] then
        NetJob.pack(params, transport, result, streams, listings[own_id], update, floorOf)
    end

    result.full_listed = full_ok or nil
    result.ok = true
    update("done")
    return result
end

-- Packing ---------------------------------------------------------------------------

--- Step 5 (on a full listing): for each stream, delete the segments of
-- packs made long enough ago (as long as the pack, or a later pack holding
-- it, is there), then pack the next run of small segments if there are
-- enough.
function NetJob.pack(params, transport, result, streams, own_listing, update, floorOf)
    local P = params.pack
    local own = NetJob.DEVICES .. "/" .. params.device_id
    local zstd = P.zstd or require("concordance/zstd")
    local listed = listedNames(own_listing)
    for _, stream in ipairs(streams) do
        local def = stream.def
        local segs = {}
        local top = (P.after and P.after[stream.id]) or 0
        for _, e in ipairs(own_listing) do
            local s = not e.is_dir and def.seq(e.name)
            if s then
                segs[s] = e
                if s > top then top = s end
            end
        end

        -- Segments of packs made long enough ago.
        for _, p in ipairs(P.delete or {}) do
            if p.stream == stream.id then
                local held = false
                for _, h in ipairs(p.holders or { p.name }) do
                    if listed[h] then held = true end
                end
                local left = 0
                for n = p.first, p.last do
                    if segs[n] then
                        if held and transport:delete(own .. "/" .. segs[n].name) then
                            segs[n] = nil
                            result.deleted[p.name] = (result.deleted[p.name] or 0) + 1
                        else
                            left = left + 1
                        end
                    end
                end
                result.left[p.name] = left
            end
        end

        -- The next run of small segments after the last packed one: big
        -- ones (a first sync's) are left as they are, and so are gaps. A
        -- run too short to pack that a big segment or a gap ends will never
        -- grow, so it's left as it is too, and the search goes on past it;
        -- only the last run waits for more.
        local small = function(n) return segs[n] and (segs[n].size or 0) <= Pack.SMALL end
        local first = ((P.after and P.after[stream.id]) or 0) + 1
        local run
        while true do
            while first <= top and not small(first) do first = first + 1 end
            run = {}
            local n = first
            while small(n) and #run < Pack.MAX do
                table.insert(run, n)
                n = n + 1
            end
            if #run >= Pack.MIN or n > top then break end
            first = n
        end
        if #run >= Pack.MIN then
            local builder = Pack.builder(stream.id)
            local cap = (P.caps and P.caps[stream.id]) or 5000
            local last, full
            for _, seq in ipairs(run) do
                if P.deadline and os.time() > P.deadline then break end
                local name = def.name(seq)
                local part = params.tmp_dir .. "/pack__" .. name
                local plain = part .. ".jsonl"
                local ok, gerr = transport:get(own .. "/" .. name, part)
                local seg, rerr
                if ok then
                    local dok, derr = zstd.decompressFile(part, plain)
                    if dok then seg, rerr = builder:read(plain) else rerr = derr end
                end
                os.remove(part)
                os.remove(plain)
                if not ok then
                    -- Couldn't download it: stop here, pack what came before.
                    result.segment_errors[#result.segment_errors + 1] = "packing " .. name .. ": " .. tostring(gerr)
                    break
                end
                if seg then
                    if last and builder:count() + builder:size(seg) > cap then
                        full = true
                        break
                    end
                    builder:add(seg)
                else
                    -- A bad segment: nothing in it can be imported, so the
                    -- pack holds nothing of it.
                    result.segment_errors[#result.segment_errors + 1] = "packing: skipping bad " .. name .. ": " .. tostring(rerr)
                end
                last = seq
            end
            -- A full pack is made however few segments it holds: the next
            -- one starts where it ends, so a run of busy segments is packed
            -- in parts rather than never.
            if last and (full or last - first + 1 >= Pack.MIN) then
                -- The pack is this device's next segment.
                local floor = math.max(floorOf(stream), stream.uploaded_seq or 0, (P.after and P.after[stream.id]) or 0)
                local seq = floor + 1
                while segs[seq] or listed[def.name(seq)] do seq = seq + 1 end
                local pname = def.name(seq)
                local plain = params.tmp_dir .. "/" .. pname .. ".jsonl"
                local packed = params.tmp_dir .. "/" .. pname
                local wok, werr = builder:write(plain, params.device_id, os.time())
                local size = wok and zstd.compressFile(plain, packed)
                os.remove(plain)
                local up_ok, up_err = false, werr
                if size then up_ok, up_err = transport:put_new(own .. "/" .. pname, packed) end
                if up_ok then
                    local st = transport:stat(own .. "/" .. pname)
                    if st and (st.size == nil or st.size == size) then
                        table.insert(result.packed, { stream = stream.id, name = pname, first = first, last = last,
                                                      size = size, etag = st.etag })
                    else
                        up_err = "pack not found with the right size"
                        up_ok = false
                    end
                elseif up_ok == false then
                    up_err = "name taken"
                end
                if not up_ok then
                    result.segment_errors[#result.segment_errors + 1] = "packing " .. pname .. ": " .. tostring(up_err)
                end
                os.remove(packed)
                update("packed")
            end
        end
    end
end

return NetJob
