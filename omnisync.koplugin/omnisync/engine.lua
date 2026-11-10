--[[--
The sync cycle, and making sure only one runs at a time.

    flush -> export -> network (subprocess) -> mark exported -> import -> refresh

At most one cycle runs at a time. A request while one runs is remembered,
and exactly one more cycle runs after it (however many requests came), for
everything they asked for.

A request is for statistics, annotations or both (opts.stats, opts.ann:
each on unless false; annotations only with deps.ann). Book data (deps.book)
is synced whenever annotations are.

Everything KOReader-specific is passed in (`deps`), so tests can drive it:

    store                 omnisync/store instance (joinVersions after the
                          book identity's groups change)
    makeTransport()       -> transport (called in the subprocess)
    spawn(fn)             -> handle | nil, err     run fn in a subprocess
    isDone(handle)        -> bool                  (reaps it when done)
    kill(handle)
    schedule(delay, fn)   run fn later on the UI loop
    now()                 -> seconds
    canRun(reason, opts)  -> bool, why             e.g. network is up (may
                                                   set opts.stats = false)
    flush()               make the statistics plugin write its pending data
    afterImport(ids)      refresh what's shown for these book ids
    getDeviceId()         -> id
    device_name, work_dir, tmp_dir
    saveStatus(status)    persist the status table
    onDone(status, run)   optional, after every cycle (e.g. tell the user)
    logger, time_limit, poll_interval, max_events, max_download_bytes
    zstd                  optional, omnisync/zstd by default
    ann                   optional, annotation sync: { store (omnisync/annstore),
                          enabled() -> bool (optional), collect() (record the open book's
                          changes), afterSync(run), max_records }
    book                  optional, book data sync, synced with annotations:
                          { store (omnisync/bookstore), collect(), afterSync(run),
                          max_records }
    id                    optional, book identity, synced with annotations:
                          { store (omnisync/idstore), files() -> { { path, md5,
                          size, mtime }, … } (book files to read, main process),
                          scan(item) -> info | nil, why (reads one, in the
                          subprocess), max_records }
    id_scan_seconds       seconds the subprocess may spend reading book files
                          after the network step (id_scan_seconds_interactive
                          when a user asked)

Segments are written and read as plain .jsonl here; they're compressed
just before upload and decompressed just before import.
--]]

local AnnFormat = require("omnisync/annformat")
local BookFormat = require("omnisync/bookformat")
local IdFormat = require("omnisync/idformat")
local Codec = require("omnisync/codec")
local NetJob = require("omnisync/netjob")
local Pack = require("omnisync/pack")

local Engine = {}
Engine.__index = Engine

local DEFAULTS = {
    time_limit = 180,          -- seconds for the whole network step
    poll_interval = 1,         -- seconds between subprocess checks
    max_events = 20000,        -- events per uploaded segment (~2 MB)
    max_ann_records = 5000,    -- annotation records per uploaded segment
    max_book_records = 5000,   -- book data records per uploaded segment
    max_download_bytes = 32 * 1024 * 1024, -- per cycle
    full_list_interval = 24 * 3600, -- seconds between full listings of every device folder
    pack_grace = Pack.GRACE,   -- seconds between a pack appearing and its segments being deleted
    pack = true,               -- pack this device's small segments (see pack.lua)
    max_id_records = 5000,     -- identity records per uploaded segment
    id_scan_seconds = 60,      -- reading book files after the network step
    id_scan_seconds_interactive = 5,
}

function Engine.new(deps)
    local self = setmetatable({ deps = deps }, Engine)
    for k, v in pairs(DEFAULTS) do
        if deps[k] == nil then deps[k] = v end
    end
    self.log = deps.logger or { info = print, warn = print, dbg = function() end, err = print }
    self.running = false
    self.rerun = nil
    self.status = deps.status or {}
    return self
end

--- Which streams opts asks for: stats, ann (booleans).
function Engine:_wants(opts)
    local a = self.deps.ann
    return opts.stats ~= false,
        opts.ann ~= false and a ~= nil and (a.enabled == nil or a.enabled()) or false
end

--- Asks for a sync. opts.interactive: a user asked (shown in onDone);
-- opts.stats, opts.ann: what to sync (both unless false).
-- Returns "started", "queued" or "skipped".
function Engine:request(reason, opts)
    opts = opts or {}
    if self.running then
        local r = self.rerun or { reasons = {} }
        table.insert(r.reasons, reason)
        r.interactive = r.interactive or opts.interactive
        local stats, ann = self:_wants(opts)
        r.stats, r.ann = r.stats or stats, r.ann or ann
        self.rerun = r
        self.log.dbg("StatSync: sync running, queued one more for", reason)
        return "queued"
    end
    local ok, why = self.deps.canRun(reason, opts)
    local stats, ann = self:_wants(opts)
    if ok and not stats and not ann then ok, why = false, "nothing to sync" end
    if not ok then
        self.log.info("StatSync: not syncing (" .. reason .. "):", why)
        if opts.interactive and self.deps.onDone then
            self.deps.onDone({ last_error = why },
                { interactive = true, skipped = true, stats = stats, ann = ann, error = why })
        end
        return "skipped"
    end
    self.running = true
    local run = { reason = reason, interactive = opts.interactive, started = self.deps.now(),
                  stats = stats, ann = ann,
                  imported_events = 0, inserted = 0, updated = 0, uploaded_events = 0,
                  segments_imported = 0, segments_bad = 0, affected = {},
                  ann_uploaded_records = 0, ann_imported_records = 0, ann_applied = 0,
                  ann_segments_imported = 0, ann_affected = {},
                  book_uploaded_records = 0, book_imported_records = 0, book_applied = 0,
                  book_segments_imported = 0, book_affected = {},
                  id_uploaded_records = 0, id_imported_records = 0, id_applied = 0,
                  id_segments_imported = 0, id_scanned = 0, id_new_facts = 0 }
    self.current = run
    self.deps.schedule(0, function() self:_step(run, "export") end)
    return "started"
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFileAtomic(path, data)
    local tmp = path .. ".tmp"
    local f = assert(io.open(tmp, "wb"))
    f:write(data)
    f:close()
    assert(os.rename(tmp, path))
end
Engine.writeFileAtomic = writeFileAtomic

local function listDir(dir)
    local names = {}
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    if ok and lfs.attributes(dir, "mode") == "directory" then
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
    end
    return names, ok and lfs
end

local function ensureDir(dir)
    local _, lfs = listDir(dir)
    if lfs and lfs.attributes(dir, "mode") ~= "directory" then
        local path = ""
        for part in dir:gmatch("[^/]+") do
            path = (path == "" and dir:sub(1, 1) ~= "/") and part or path .. "/" .. part
            if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
        end
    end
end

function Engine:_fail(run, msg)
    run.error = msg
    self.log.warn("StatSync: sync failed:", msg)
    self:_finish(run)
end

function Engine:_step(run, stage)
    local ok, err = pcall(self["_" .. stage], self, run)
    if not ok then
        self:_fail(run, stage .. ": " .. tostring(err))
    end
end

function Engine:_zstd()
    if not self.deps.zstd then self.deps.zstd = require("omnisync/zstd") end
    return self.deps.zstd
end

function Engine:_export(run)
    local d = self.deps
    if run.stats then
        local fok, ferr = pcall(d.flush)
        if not fok then self.log.warn("StatSync: flushing statistics failed:", ferr) end
    end

    ensureDir(d.work_dir)
    ensureDir(d.tmp_dir)
    for _, name in ipairs((listDir(d.tmp_dir))) do os.remove(d.tmp_dir .. "/" .. name) end
    run.device_id = d.getDeviceId()
    run.pending_path = d.work_dir .. "/pending.jsonl"
    run.packed_path = run.pending_path .. ".zst"
    run.result_path = d.work_dir .. "/result.json"
    os.remove(run.pending_path)
    os.remove(run.packed_path)
    os.remove(run.result_path)

    -- Listing every device folder costs more as segments accumulate, so
    -- ordinary syncs ask for each device's next segments by name instead.
    -- Each stream keeps its own time of its last full listing.
    local function due(key)
        local last = self.status[key]
        return not last or d.now() - last >= d.full_list_interval
    end
    run.full_list = run.interactive or (run.stats and due("last_full_list"))
        or (run.ann and due("ann_last_full_list")) or nil
    local t0 = os.clock()
    local exp
    if run.stats then
        local eerr, why
        exp, eerr, why = d.store:export{
            device_id = run.device_id, out_path = run.pending_path, now = d.now(), max_events = d.max_events,
            force_diff = run.full_list,
        }
        if eerr then return self:_fail(run, "export: " .. tostring(eerr)) end
        run.export_skipped = why
        run.export = exp
    end
    if exp then
        local packed, perr = self:_zstd().compressFile(run.pending_path, run.packed_path)
        if not packed then return self:_fail(run, "compressing: " .. tostring(perr)) end
        exp.plain_size, exp.size = exp.size, packed
    end
    run.export_cpu = os.clock() - t0

    local ann_params
    if run.ann then
        local cok, cerr = pcall(d.ann.collect)
        if not cok then self.log.warn("StatSync: recording annotation changes failed:", cerr) end
        run.ann_pending_path = d.work_dir .. "/ann-pending.jsonl"
        run.ann_packed_path = run.ann_pending_path .. ".zst"
        os.remove(run.ann_pending_path)
        os.remove(run.ann_packed_path)
        local aexp = d.ann.store:export{ device_id = run.device_id, out_path = run.ann_pending_path, now = d.now(),
                                         max_records = d.ann.max_records or d.max_ann_records }
        run.ann_export = aexp
        if aexp then
            local packed, perr = self:_zstd().compressFile(run.ann_pending_path, run.ann_packed_path)
            if not packed then return self:_fail(run, "compressing annotations: " .. tostring(perr)) end
            aexp.plain_size, aexp.size = aexp.size, packed
        end
        ann_params = {
            pending = aexp and { path = run.ann_packed_path, size = aexp.size } or nil,
            bad = d.store:badSegments(AnnFormat.BAD_VERSION),
        }
    end

    -- Book data goes with annotations.
    local book_params
    if run.ann and d.book then
        run.book = true
        local cok, cerr = pcall(d.book.collect)
        if not cok then self.log.warn("StatSync: recording book data changes failed:", cerr) end
        run.book_pending_path = d.work_dir .. "/book-pending.jsonl"
        run.book_packed_path = run.book_pending_path .. ".zst"
        os.remove(run.book_pending_path)
        os.remove(run.book_packed_path)
        local bexp = d.book.store:export{ device_id = run.device_id, out_path = run.book_pending_path, now = d.now(),
                                          max_records = d.book.max_records or d.max_book_records }
        run.book_export = bexp
        if bexp then
            local packed, perr = self:_zstd().compressFile(run.book_pending_path, run.book_packed_path)
            if not packed then return self:_fail(run, "compressing book data: " .. tostring(perr)) end
            bexp.plain_size, bexp.size = bexp.size, packed
        end
        book_params = {
            pending = bexp and { path = run.book_packed_path, size = bexp.size } or nil,
            bad = d.store:badSegments(BookFormat.BAD_VERSION),
        }
    end

    -- Book identity goes with annotations too.
    local id_params, scan_items, scan_seconds
    if run.ann and d.id then
        run.id = true
        run.id_pending_path = d.work_dir .. "/id-pending.jsonl"
        run.id_packed_path = run.id_pending_path .. ".zst"
        os.remove(run.id_pending_path)
        os.remove(run.id_packed_path)
        local iexp = d.id.store:export{ device_id = run.device_id, out_path = run.id_pending_path, now = d.now(),
                                        max_records = d.id.max_records or d.max_id_records }
        run.id_export = iexp
        if iexp then
            local packed, perr = self:_zstd().compressFile(run.id_pending_path, run.id_packed_path)
            if not packed then return self:_fail(run, "compressing book identity: " .. tostring(perr)) end
            iexp.plain_size, iexp.size = iexp.size, packed
        end
        id_params = {
            pending = iexp and { path = run.id_packed_path, size = iexp.size } or nil,
            bad = d.store:badSegments(IdFormat.BAD_VERSION),
        }
        -- Book files to read in the subprocess, after the network step.
        local fok, files = pcall(d.id.files)
        if fok and files then
            local present = {}
            for _, f in ipairs(files) do present[f.path] = true end
            pcall(d.id.store.keepScanned, d.id.store, present)
            local tok, todo = pcall(d.id.store.toScan, d.id.store, files)
            if tok and #todo > 0 then
                scan_items = todo
                scan_seconds = run.interactive and d.id_scan_seconds_interactive or d.id_scan_seconds
            elseif not tok then
                self.log.warn("StatSync: book identity: choosing files to read failed:", todo)
            end
        elseif not fok then
            self.log.warn("StatSync: book identity: listing book files failed:", files)
        end
        run.scan_items = scan_items
    end

    local meta_path = d.work_dir .. "/meta.json"
    -- meta.json says the highest number each stream's packs took, so a copy
    -- of this device restored from an old backup doesn't use numbers whose
    -- segments are packed and gone.
    local packed = {}
    for name, p in pairs(self.status.packs or {}) do
        local seq = NetJob.STREAMS[p.stream].seq(name)
        if seq and seq > (packed[p.stream] or 0) then packed[p.stream] = seq end
    end
    local packed_key = next(packed) and Codec.encode(packed) or nil
    writeFileAtomic(meta_path, Codec.encode{
        deviceId = run.device_id, deviceName = d.device_name or "", schema = Codec.VERSION,
        createdAt = d.now(), packed = next(packed) and packed or nil,
    })
    run.meta_key = packed_key
    -- Packing, on full listings (see netjob.lua and pack.lua).
    local pack_params
    if run.full_list and d.pack then
        pack_params = self:_packParams()
        pack_params.deadline = os.time() + math.floor(d.time_limit / 2)
        pack_params.caps = { stats = d.max_events, ann = d.ann and d.ann.max_records or d.max_ann_records,
                             book = d.book and d.book.max_records or d.max_book_records,
                             id = d.id and d.id.max_records or d.max_id_records }
    end
    -- Folders are skipped only once this server's folder dates are known
    -- to follow changes (see netjob.lua).
    local dates_known = self.status.folder_dates == "reliable"
    local dates_ok = self.status.folder_dates ~= "unreliable"
    -- This device has sent files to the folder before: they must be there.
    local seen = d.store:seenSegments()
    -- About to upload with no record of its own segments (a new device, or
    -- its state database deleted): list everything first, so it doesn't
    -- reuse a number.
    if not next(seen[run.device_id] or {}) and (exp or (ann_params and ann_params.pending)
            or (book_params and book_params.pending) or (id_params and id_params.pending)) then
        run.full_list = true
    end
    local params = {
        stats = run.stats,
        expect_own = next(seen[run.device_id] or {}) ~= nil,
        device_id = run.device_id,
        pending = exp and { path = run.packed_path, size = exp.size } or nil,
        meta_path = meta_path,
        seen = seen,
        bad = d.store:badSegments(),
        full_list = run.full_list,
        tmp_dir = d.tmp_dir,
        max_download_bytes = d.max_download_bytes,
        ann = ann_params,
        book = book_params,
        id = id_params,
        pack = pack_params,
        rewrite_meta = run.meta_key ~= nil and self.status.meta_key ~= run.meta_key,
        folders = dates_known and self.status.folders or nil,
        own_check = dates_ok and self.status.own_check or nil,
    }
    local result_path = run.result_path
    local makeTransport = d.makeTransport
    local scan = d.id and d.id.scan
    -- Reading book files stops in time for the network step's time limit.
    local scan_limit = math.floor(d.time_limit * 0.75)
    local handle, serr = d.spawn(function()
        -- In the subprocess. Our database connections are all closed by
        -- now, so nothing of ours is left for the garbage collector to close.
        local started = os.time()
        local last
        local function save(r) last = r; writeFileAtomic(result_path, Codec.encode(r)) end
        local tok, transport = pcall(makeTransport)
        if not tok or not transport then
            save({ ok = false, error = "no transport: " .. tostring(transport), downloads = {} })
        else
            local rok, rerr = pcall(NetJob.run, params, transport, save)
            if not rok then
                local r = Codec.decode(readFile(result_path) or "") or { downloads = {} }
                r.ok, r.error = false, "network step crashed: " .. tostring(rerr)
                save(r)
            end
        end
        if scan_items and scan then
            local r = last or Codec.decode(readFile(result_path) or "") or { ok = false, downloads = {} }
            r.scans = {}
            local deadline = math.min(os.time() + scan_seconds, started + scan_limit)
            for i, item in ipairs(scan_items) do
                if os.time() >= deadline then break end
                local ok, info, why = pcall(scan, item)
                if not ok then info, why = nil, tostring(info) end
                table.insert(r.scans, { i = i, info = info or nil, why = why })
                save(r)
            end
        end
    end)
    if not handle then return self:_fail(run, "starting subprocess: " .. tostring(serr)) end
    run.handle = handle
    run.net_started = d.now()
    d.schedule(d.poll_interval, function() self:_step(run, "poll") end)
end

function Engine:_poll(run)
    local d = self.deps
    if d.isDone(run.handle) then
        return self:_step(run, "collect")
    end
    if not run.killed and d.now() - run.net_started > d.time_limit then
        self.log.warn("StatSync: network step took longer than", d.time_limit, "s, stopping it")
        d.kill(run.handle)
        run.killed = true
    end
    d.schedule(d.poll_interval, function() self:_step(run, "poll") end)
end

function Engine:_collect(run)
    local d = self.deps
    local result = Codec.decode(readFile(run.result_path) or "")
    if type(result) ~= "table" then
        result = { ok = false, error = run.killed and "timed out before any result" or "no result from network step", downloads = {} }
    end
    run.result = result
    run.net_time = d.now() - run.net_started
    if run.killed then
        run.error = "network step timed out (stage: " .. tostring(result.stage) .. ")"
    elseif not result.ok then
        run.error = result.error or "network step failed"
    end
    run.devices = result.devices and #result.devices or nil
    run.missing_own = result.missing_own
    if result.full_listed and not run.killed then run.full_listed = d.now() end
    for _, e in ipairs(result.segment_errors or {}) do self.log.warn("StatSync:", e) end

    local up = result.uploaded
    if up and up.verified then
        local n, merr = d.store:markExported(run.pending_path, run.device_id, up.name, up.size, up.etag, d.now())
        if n then
            run.uploaded_events = n
            run.uploaded = up.name
            if not run.export.more then d.store:markClean(run.export.fp) end
        else
            self.log.warn("StatSync: recording the upload failed:", merr)
        end
    elseif run.export and not run.error then
        run.upload_error = result.upload_error or "upload didn't finish"
        self.log.warn("StatSync: upload failed:", run.upload_error)
    end
    os.remove(run.pending_path)
    os.remove(run.packed_path)

    if run.ann then
        local aup = result.ann_uploaded
        if aup and aup.verified then
            local ok, n = pcall(d.ann.store.markExported, d.ann.store, run.ann_pending_path, run.device_id,
                aup.name, aup.size, aup.etag, d.now())
            if ok then
                run.ann_uploaded_records = n
                run.ann_uploaded = aup.name
            else
                self.log.warn("StatSync: recording the annotation upload failed:", n)
            end
        elseif run.ann_export and not run.error then
            run.ann_upload_error = result.ann_upload_error or "upload didn't finish"
            self.log.warn("StatSync: annotation upload failed:", run.ann_upload_error)
        end
        os.remove(run.ann_pending_path)
        os.remove(run.ann_packed_path)
    end

    if run.book then
        local bup = result.book_uploaded
        if bup and bup.verified then
            local ok, n = pcall(d.book.store.markExported, d.book.store, run.book_pending_path, run.device_id,
                bup.name, bup.size, bup.etag, d.now())
            if ok then
                run.book_uploaded_records = n
                run.book_uploaded = bup.name
            else
                self.log.warn("StatSync: recording the book data upload failed:", n)
            end
        elseif run.book_export and not run.error then
            run.book_upload_error = result.book_upload_error or "upload didn't finish"
            self.log.warn("StatSync: book data upload failed:", run.book_upload_error)
        end
        os.remove(run.book_pending_path)
        os.remove(run.book_packed_path)
    end

    if run.id then
        local iup = result.id_uploaded
        if iup and iup.verified then
            local ok, n = pcall(d.id.store.markExported, d.id.store, run.id_pending_path, run.device_id,
                iup.name, iup.size, iup.etag, d.now())
            if ok then
                run.id_uploaded_records = n
                run.id_uploaded = iup.name
            else
                self.log.warn("StatSync: recording the book identity upload failed:", n)
            end
        elseif run.id_export and not run.error then
            run.id_upload_error = result.id_upload_error or "upload didn't finish"
            self.log.warn("StatSync: book identity upload failed:", run.id_upload_error)
        end
        os.remove(run.id_pending_path)
        os.remove(run.id_packed_path)
        -- What reading book files found (sent with the next sync).
        for _, sc in ipairs(type(result.scans) == "table" and result.scans or {}) do
            local item = run.scan_items and run.scan_items[sc.i]
            if item then
                local ok, n = pcall(d.id.store.recordScan, d.id.store, item, sc.info, run.device_id)
                if ok then
                    run.id_scanned = run.id_scanned + 1
                    run.id_new_facts = run.id_new_facts + n
                else
                    self.log.warn("StatSync: book identity of", item.path, "not recorded:", n)
                end
                if sc.why then self.log.dbg("StatSync: book identity of", item.path, "not read:", sc.why) end
            end
        end
        run.id_scan_left = run.scan_items and (#run.scan_items - run.id_scanned) or 0
    end

    self:_packs(run, result)

    run.queue = result.downloads or {}
    run.qi = 1
    d.schedule(0, function() self:_step(run, "import") end)
end

--- This device's packs (status.packs: name -> { stream, first, last, t,
-- done }) as the network step wants them: where the next pack starts, and
-- which packs' segments may go. A pack is "held" while its own file, or a
-- later pack it went into, is on the server.
function Engine:_packParams()
    local d = self.deps
    local packs = self.status.packs or {}
    local after, delete = {}, {}
    for _, p in pairs(packs) do
        if p.last > (after[p.stream] or 0) then after[p.stream] = p.last end
    end
    for name, p in pairs(packs) do
        if not p.done and d.now() - p.t >= d.pack_grace then
            local holders, current = { name }, name
            for _ = 1, 64 do
                local seq = NetJob.STREAMS[p.stream].seq(current)
                local next_holder
                for other, q in pairs(packs) do
                    if q.stream == p.stream and seq and q.first <= seq and seq <= q.last then next_holder = other end
                end
                if not next_holder then break end
                holders[#holders + 1] = next_holder
                current = next_holder
            end
            delete[#delete + 1] = { stream = p.stream, name = name, first = p.first, last = p.last, holders = holders }
        end
    end
    return { after = after, delete = delete }
end

--- What the network step did with packs and folder dates (folder dates are
-- recorded in _finish, once the downloads are imported).
function Engine:_packs(run, result)
    local d = self.deps
    local packs = self.status.packs or {}
    for _, p in ipairs(result.packed or {}) do
        packs[p.name] = { stream = p.stream, first = p.first, last = p.last, t = d.now() }
        -- Its records are this device's own: nothing to import.
        local ok, err = pcall(d.store.markSeen, d.store, run.device_id,
            { { name = p.name, size = p.size, etag = p.etag, exact = true } }, d.now())
        if not ok then self.log.warn("StatSync: recording pack", p.name, "failed:", err) end
        self.log.info("StatSync: packed segments", p.first, "to", p.last, "into", p.name)
    end
    local deleted = 0
    for name, n in pairs(result.deleted or {}) do deleted = deleted + n end
    for name, left in pairs(result.left or {}) do
        if packs[name] and left == 0 then packs[name].done = true end
    end
    -- Done ones can go after a while, but not the last of each stream:
    -- it says where the next pack starts.
    local last = {}
    for name, p in pairs(packs) do
        if not last[p.stream] or p.last > packs[last[p.stream]].last then last[p.stream] = name end
    end
    for name, p in pairs(packs) do
        if p.done and d.now() - p.t > 4 * d.pack_grace and last[p.stream] ~= name then packs[name] = nil end
    end
    self.status.packs = next(packs) and packs or nil
    run.packed = #(result.packed or {})
    run.deleted_originals = deleted
    if deleted > 0 then self.log.info("StatSync: deleted", deleted, "segments now in packs") end

    -- This device's own folder must change date with its upload.
    if result.ok then
        local uploaded = (result.uploaded and result.uploaded.verified) or (result.ann_uploaded and result.ann_uploaded.verified)
            or (result.book_uploaded and result.book_uploaded.verified)
            or (result.id_uploaded and result.id_uploaded.verified)
        self.status.own_check = uploaded and result.own_reliable and result.own_modified or nil
    end
    run.folders = result.folders
    run.dates_unreliable = result.dates_unreliable
    if result.dates_confirmed and not result.dates_unreliable and self.status.folder_dates == nil then
        self.status.folder_dates = "reliable"
        self.log.info("StatSync: this server's folder dates follow changes: unchanged folders are skipped")
    end
    if result.meta_written then self.status.meta_key = run.meta_key end
end

-- One segment per UI tick, so a big first import doesn't freeze the screen.
function Engine:_import(run)
    local d = self.deps
    local item = run.queue[run.qi]
    if not item then return self:_finish(run) end
    run.qi = run.qi + 1
    local t0 = os.clock()
    local plain = item.path .. ".jsonl"
    local summary, err, kind
    local is_ann = item.stream == "ann"
    local is_book = item.stream == "book"
    local is_id = item.stream == "id"
    local uok, uerr = self:_zstd().decompressFile(item.path, plain)
    if uok and is_id then
        if run.id then
            summary, err, kind = d.id.store:importSegment(plain, item.device, item.name, item.size, item.etag, d.now())
        else
            err, kind = "book identity sync is off", "skip"
        end
    elseif uok and is_book then
        if run.book then
            summary, err, kind = d.book.store:importSegment(plain, item.device, item.name, item.size, item.etag, d.now())
        else
            err, kind = "book data sync is off", "skip"
        end
    elseif uok and is_ann then
        if run.ann then
            summary, err, kind = d.ann.store:importSegment(plain, item.device, item.name, item.size, item.etag, d.now())
        else
            err, kind = "annotation sync is off", "skip"
        end
    elseif uok then
        summary, err, kind = d.store:importSegment(plain, item.device, item.name, item.size, item.etag, d.now())
    else
        err, kind = "can't decompress: " .. tostring(uerr), "format"
    end
    run.import_cpu = (run.import_cpu or 0) + (os.clock() - t0)
    os.remove(item.path)
    os.remove(plain)

    if summary and is_id then
        run.id_segments_imported = run.id_segments_imported + 1
        run.id_imported_records = run.id_imported_records + summary.records
        run.id_applied = run.id_applied + summary.applied
    elseif summary and is_book then
        run.book_segments_imported = run.book_segments_imported + 1
        run.book_imported_records = run.book_imported_records + summary.records
        run.book_applied = run.book_applied + summary.applied
        for md5 in pairs(summary.affected) do run.book_affected[md5] = true end
    elseif summary and is_ann then
        run.ann_segments_imported = run.ann_segments_imported + 1
        run.ann_imported_records = run.ann_imported_records + summary.records
        run.ann_applied = run.ann_applied + summary.applied
        for id, a in pairs(summary.affected) do run.ann_affected[id] = a end
    elseif kind == "skip" then
        self.log.dbg("StatSync: skipping", item.name, err)
    elseif summary then
        run.segments_imported = run.segments_imported + 1
        run.imported_events = run.imported_events + summary.events
        run.inserted = run.inserted + summary.inserted
        run.updated = run.updated + summary.updated
        for id in pairs(summary.affected) do run.affected[id] = true end
    elseif kind == "format" then
        run.segments_bad = run.segments_bad + 1
        self.log.warn("StatSync: skipping bad segment", item.device .. "/" .. item.name .. ":", err)
        pcall(d.store.recordBad, d.store, item.device, item.name, item.size, item.etag, err,
            is_id and IdFormat.BAD_VERSION or is_book and BookFormat.BAD_VERSION
            or is_ann and AnnFormat.BAD_VERSION or nil)
    else
        -- Database trouble: stop; nothing is marked, the next sync retries.
        for i = run.qi, #run.queue do os.remove(run.queue[i].path) end
        return self:_fail(run, "import: " .. tostring(err))
    end
    d.schedule(0, function() self:_step(run, "import") end)
end

function Engine:_finish(run)
    if run.finished then return end
    run.finished = true
    local d = self.deps
    if run.handle and not d.isDone(run.handle) then
        -- Only after an unexpected error: don't leave the subprocess behind.
        d.kill(run.handle)
        local function reap()
            if not d.isDone(run.handle) then d.schedule(d.poll_interval, reap) end
        end
        d.schedule(d.poll_interval, reap)
    end
    if next(run.affected) and d.afterImport then
        local ok, err = pcall(d.afterImport, run.affected)
        if not ok then self.log.warn("StatSync: refreshing statistics failed:", err) end
    end
    if run.id and d.id.store.refreshGroups then
        -- Versions of a book joined or parted: their book data applies anew.
        local ok, changed = pcall(d.id.store.refreshGroups, d.id.store)
        if not ok then
            self.log.warn("StatSync: updating book versions failed:", changed)
        elseif next(changed) then
            run.id_regrouped = 0
            for _ in pairs(changed) do run.id_regrouped = run.id_regrouped + 1 end
            if run.book and d.book.store.regroup then
                local rok, all = pcall(d.book.store.regroup, d.book.store, changed)
                if rok then
                    for md5 in pairs(all) do run.book_affected[md5] = true end
                else
                    self.log.warn("StatSync: applying book data to new versions failed:", all)
                end
            end
            if run.ann and d.ann.store.regroup then
                local aok, pending = pcall(d.ann.store.regroup, d.ann.store, changed)
                if aok then
                    for id, a in pairs(pending) do run.ann_affected[id] = a end
                else
                    self.log.warn("StatSync: applying annotations to new versions failed:", pending)
                end
            end
        end
    end
    local join_rules = d.store.JOIN_RULES or 1
    if run.id and d.store.joinVersions and (run.id_regrouped or self.status.versions_joined ~= join_rules) then
        -- Readings of a book's versions into one row: after the groups
        -- changed, and once when the rules for joining change (versions
        -- before them joined by other rules, or not at all).
        local ok, res, err = pcall(d.store.joinVersions, d.store)
        if ok and res then
            self.status.versions_joined = join_rules
            run.stats_joined = res.removed
            if next(res.affected) and d.afterImport then
                local aok, aerr = pcall(d.afterImport, res.affected)
                if not aok then self.log.warn("StatSync: refreshing statistics failed:", aerr) end
            end
        else
            self.log.warn("StatSync: joining the statistics of book versions failed:", ok and err or res)
        end
    end
    if run.ann and d.ann.afterSync then
        local ok, err = pcall(d.ann.afterSync, run)
        if not ok then self.log.warn("StatSync: applying annotations failed:", err) end
    end
    if run.book and d.book.afterSync then
        local ok, err = pcall(d.book.afterSync, run)
        if not ok then self.log.warn("StatSync: applying book data failed:", err) end
    end
    if run.missing_own then
        -- Not this device's folder after all (see netjob.lua): don't take it
        -- as where segments go, so the right one, once set, isn't new.
        local ok, err = pcall(d.store.forgetLocation, d.store)
        if not ok then self.log.warn("StatSync: forgetting the folder failed:", err) end
    end
    local st = self.status
    if run.dates_unreliable then
        if st.folder_dates ~= "unreliable" then
            self.log.warn("StatSync: this server's folder dates don't follow changes: every folder is checked from now on")
        end
        st.folder_dates, st.folders, st.own_check = "unreliable", nil, nil
    elseif run.folders and not run.error and st.folder_dates ~= "unreliable" then
        -- Folders gone through completely, now that their segments are
        -- imported: skipped while their date stays the same.
        local folders = {}
        for _, id in ipairs(run.result and run.result.devices or {}) do
            local now, rec = run.folders[id], (st.folders or {})[id]
            if now and now.reliable then
                local streams = {}
                if rec and rec.modified == now.modified then
                    for k, v in pairs(rec.streams or {}) do streams[k] = v end
                end
                for k in pairs(now.complete or {}) do streams[k] = true end
                if next(streams) then folders[id] = { modified = now.modified, streams = streams } end
            elseif rec and now and rec.modified == now.modified then
                folders[id] = rec
            end
        end
        st.folders = next(folders) and folders or nil
    end
    st.last_attempt = run.started
    st.last_error = run.error or run.upload_error or run.ann_upload_error or run.book_upload_error
        or run.id_upload_error
    if run.full_listed then
        if run.stats then st.last_full_list = run.full_listed end
        if run.ann then st.ann_last_full_list = run.full_listed end
    end
    if not run.error then
        st.last_success = d.now()
        st.devices = run.devices
        if run.stats then
            st.stats_last_success = st.last_success
            st.imported_events = run.imported_events
            st.uploaded_events = run.uploaded_events
        end
        if run.ann then
            st.ann_last_success = st.last_success
            st.ann_imported = run.ann_imported_records
            st.ann_uploaded = run.ann_uploaded_records
        end
        if run.book then
            st.book_uploaded = run.book_uploaded_records
            st.book_imported = run.book_imported_records
        end
        if run.id then
            st.id_uploaded = run.id_uploaded_records
            st.id_imported = run.id_imported_records
        end
    end
    st.bytes_up = run.result and run.result.bytes_up
    st.bytes_down = run.result and run.result.bytes_down
    pcall(d.saveStatus, st)
    self.log.info(string.format("StatSync: sync (%s%s) %s: uploaded %d events, imported %d segments (%d events: %d new, %d longer), %d bad",
        run.reason, run.stats and "" or ", annotations only", run.error and ("failed: " .. run.error) or "done",
        run.uploaded_events, run.segments_imported, run.imported_events, run.inserted, run.updated, run.segments_bad))
    if run.ann then
        self.log.info(string.format("StatSync: annotations: sent %d changes, imported %d segments (%d changes, %d new here)",
            run.ann_uploaded_records, run.ann_segments_imported, run.ann_imported_records, run.ann_applied))
    end
    if run.book then
        self.log.info(string.format("StatSync: book data: sent %d changes, imported %d segments (%d changes, %d new here)",
            run.book_uploaded_records, run.book_segments_imported, run.book_imported_records, run.book_applied))
    end
    if run.id then
        self.log.info(string.format("StatSync: book identity: sent %d facts, imported %d segments (%d facts, %d new here), read %d book files (%d new facts, %d still to read), %d files joined or parted, %d statistics rows joined",
            run.id_uploaded_records, run.id_segments_imported, run.id_imported_records, run.id_applied,
            run.id_scanned, run.id_new_facts, run.id_scan_left or 0, run.id_regrouped or 0, run.stats_joined or 0))
    end
    self.running = false
    self.current = nil
    if d.onDone then pcall(d.onDone, st, run) end

    -- Exactly one more run if anything asked meanwhile, or if this run
    -- stopped early (segment cap, download budget, time limit) having made
    -- progress, so a big first sync carries on by itself.
    local again = self.rerun
    self.rerun = nil
    local progressed = run.uploaded or run.segments_imported > 0 or run.ann_uploaded or run.ann_segments_imported > 0
        or run.book_uploaded or run.book_segments_imported > 0 or run.id_uploaded or run.id_segments_imported > 0
        or run.id_scanned > 0
    -- Book files left to read are read by the next automatic sync, not
    -- straight away: reading them keeps the device busy.
    local unfinished = (run.export and run.export.more) or (run.ann_export and run.ann_export.more)
        or (run.book_export and run.book_export.more) or (run.id_export and run.id_export.more)
        or (run.result and run.result.remote_more) or run.killed
    if again or (progressed and unfinished) then
        local reason = again and table.concat(again.reasons, ",") or "continue"
        local opts = { interactive = again and again.interactive,
                       stats = run.stats or (again and again.stats) or false,
                       ann = run.ann or (again and again.ann) or false }
        if again and not (progressed and unfinished) then
            opts.stats, opts.ann = again.stats or false, again.ann or false
        end
        d.schedule(0, function() self:request(reason, opts) end)
    end
end

return Engine
