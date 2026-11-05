--[[--
The network part of a sync. Runs in a subprocess; doesn't touch any database.

With a transport (see webdav.lua) rooted at <configured folder>/Statistics:

1. List devices/ (PROPFIND, Depth 1). Create the folders on first use, and
   this device's meta.json.
2. On a full listing (first sync, "Sync now", rebuild, and once a day): list
   every device folder too. This also deletes this device's leftover
   temporary uploads and finds segments out of sequence.
3. Upload the new segment (if any) as the next sequence number, and check
   it's there with the right size.
4. Download segments not imported yet. On a full listing, every one listed
   that isn't seen or known bad; otherwise, for each device, the segment
   numbers from the first one not imported, skipping imported ones, until
   one isn't there (a 404). So an ordinary sync costs one small listing
   plus one request per device, however long the history.

Sequence numbers are kept contiguous: a device writes the first number not
in use, so readers can ask for "the next one" by name. Anything out of
sequence (a gap, a stray file) is picked up by the next full listing.

Downloads go to tmp_dir, each to a .part file renamed when complete.
`report(result)` is called after each step that changes the result, so the
caller can save it: if the subprocess is killed for taking too long, what
was done so far (complete downloads, a verified upload) is still used.

There are three streams of segments in each device folder: statistics
(seg-N), annotations (ann-N) and book data (book-N). Each has its own
numbering; steps 3 and 4 run for each stream the sync is for (params.stats
unless false, params.ann and params.book when given).

params.expect_own: this device has files in the folder already (it has
sent some). If its folder isn't there, the folder is a different one, for
example a new one the old files haven't been copied to yet: writing there
would start numbering from 1 again, and clash with the copies. So the step
stops with result.missing_own, before creating anything.

Result: { ok, error, stage, full_listed, uploaded = { name, size, etag,
          verified }, upload_error, ann_uploaded, ann_upload_error, book_uploaded,
          book_upload_error, missing_own,
          devices = { id, … }, downloads = { {stream, device, name, size,
          etag, path}, … }, remote_more, segment_errors, bytes_up,
          bytes_down, requests }
(stream is "stats", "ann" or "book").
--]]

local AnnFormat = require("supersync/annformat")
local BookFormat = require("supersync/bookformat")
local Codec = require("supersync/codec")

local NetJob = {}

NetJob.DEVICES = "devices"

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
}

--- The first segment number (from 1) for which used(name) is false.
local function firstFree(used, segmentName)
    local n = 1
    while used(segmentName(n)) do n = n + 1 end
    return n
end

local function listedNames(entries)
    local set = {}
    for _, e in ipairs(entries) do
        if not e.is_dir then set[e.name] = true end
    end
    return set
end

--- params: device_id, pending = { path, size } | nil, meta_path,
--  seen and bad ({ [device] = { [name] = { size, etag } } }), full_list (bool),
--  tmp_dir, max_download_bytes (optional), stats (false: annotations only),
--  expect_own, and for annotations
--  ann = { pending = { path, size } | nil, bad } (seen is shared: names differ),
--  and for book data, book (the same shape)
function NetJob.run(params, transport, report)
    report = report or function() end
    local result = { stage = "start", devices = {}, downloads = {}, segment_errors = {} }
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
    local ids, own_exists = {}, false
    for _, d in ipairs(dev_entries) do
        if d.is_dir and NetJob.validDeviceId(d.name) then
            ids[#ids + 1] = d.name
            if d.name == own_id then own_exists = true end
        end
    end
    table.sort(ids)
    result.devices = ids

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
    local own_listing = listings[own_id]
    if own_listing then
        local has_meta = false
        for _, e in ipairs(own_listing) do
            if e.name == "meta.json" then has_meta = true end
            if e.name:match("^%.upload%-.*%.part$") then transport:delete(own .. "/" .. e.name) end
        end
        if not has_meta and params.meta_path then
            local ok, perr = transport:put(own .. "/meta.json", params.meta_path)
            if not ok then segErr("writing meta.json: " .. tostring(perr)) end
        end
    end
    update("listed")

    -- 3. Upload
    local function upload(stream)
        local def = stream.def
        local used
        if listings[own_id] then
            local names = listedNames(listings[own_id])
            used = function(name) return names[name] end
        else
            used = known(own_id, stream) -- own uploads are recorded as seen
        end
        local next_seq = firstFree(used, def.name)
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
                next_seq = firstFree(function(n) return names[n] end, def.name)
            else
                up_err = tostring(uerr)
                break
            end
        end
        if not up and not up_err then up_err = "no free segment name" end
        result[def.result] = up
        result[def.err] = up_err
        stream.uploaded_name = up and up.name
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

    local function downloadStream(stream)
        local def = stream.def
        local up_name = stream.uploaded_name
        for _, id in ipairs(result.devices) do
            if downloaded >= budget then result.remote_more = true; break end
            local dev_seen, dev_bad = seen[id] or {}, stream.bad[id] or {}
            local entries = listings[id]
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
                table.sort(cands, function(a, b) return a.seq < b.seq end)
                for _, c in ipairs(cands) do
                    if downloaded >= budget then result.remote_more = true; break end
                    local ok, derr = download(stream, id, c.name, c.size, c.etag)
                    if not ok then segErr(id .. "/" .. c.name .. ": " .. tostring(derr)) end
                end
            else
                local is_known = known(id, stream)
                local seq = firstFree(is_known, def.name)
                while true do
                    if downloaded >= budget then result.remote_more = true; break end
                    local name = def.name(seq)
                    if not (is_known(name) or (id == own_id and name == up_name)) then
                        local ok, derr, dcode = download(stream, id, name)
                        if not ok then
                            if dcode ~= 404 then segErr(id .. "/" .. name .. ": " .. tostring(derr)) end
                            break
                        end
                    end
                    seq = seq + 1
                end
            end
        end
    end
    for _, stream in ipairs(streams) do downloadStream(stream) end

    result.full_listed = full_ok or nil
    result.ok = true
    update("done")
    return result
end

return NetJob
