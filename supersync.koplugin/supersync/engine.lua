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

    store                 supersync/store instance
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
    zstd                  optional, supersync/zstd by default
    ann                   optional, annotation sync: { store (supersync/annstore),
                          enabled() -> bool (optional), collect() (record the open book's
                          changes), afterSync(run), max_records }
    book                  optional, book data sync, synced with annotations:
                          { store (supersync/bookstore), collect(), afterSync(run),
                          max_records }

Segments are written and read as plain .jsonl here; they're compressed
just before upload and decompressed just before import.
--]]

local AnnFormat = require("supersync/annformat")
local BookFormat = require("supersync/bookformat")
local Codec = require("supersync/codec")
local NetJob = require("supersync/netjob")

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
                  book_segments_imported = 0, book_affected = {} }
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
    if not self.deps.zstd then self.deps.zstd = require("supersync/zstd") end
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

    local meta_path = d.work_dir .. "/meta.json"
    writeFileAtomic(meta_path, Codec.encode{
        deviceId = run.device_id, deviceName = d.device_name or "", schema = Codec.VERSION,
        createdAt = d.now(),
    })
    -- This device has sent files to the folder before: they must be there.
    local seen = d.store:seenSegments()
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
    }
    local result_path = run.result_path
    local makeTransport = d.makeTransport
    local handle, serr = d.spawn(function()
        -- In the subprocess. Our database connections are all closed by
        -- now, so nothing of ours is left for the garbage collector to close.
        local function save(r) writeFileAtomic(result_path, Codec.encode(r)) end
        local tok, transport = pcall(makeTransport)
        if not tok or not transport then
            save({ ok = false, error = "no transport: " .. tostring(transport), downloads = {} })
            return
        end
        local rok, rerr = pcall(NetJob.run, params, transport, save)
        if not rok then
            local r = Codec.decode(readFile(result_path) or "") or { downloads = {} }
            r.ok, r.error = false, "network step crashed: " .. tostring(rerr)
            save(r)
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

    run.queue = result.downloads or {}
    run.qi = 1
    d.schedule(0, function() self:_step(run, "import") end)
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
    local uok, uerr = self:_zstd().decompressFile(item.path, plain)
    if uok and is_book then
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
    if summary and is_book then
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
            is_book and BookFormat.BAD_VERSION or is_ann and AnnFormat.BAD_VERSION or nil)
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
    st.last_attempt = run.started
    st.last_error = run.error or run.upload_error or run.ann_upload_error or run.book_upload_error
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
    self.running = false
    self.current = nil
    if d.onDone then pcall(d.onDone, st, run) end

    -- Exactly one more run if anything asked meanwhile, or if this run
    -- stopped early (segment cap, download budget, time limit) having made
    -- progress, so a big first sync carries on by itself.
    local again = self.rerun
    self.rerun = nil
    local progressed = run.uploaded or run.segments_imported > 0 or run.ann_uploaded or run.ann_segments_imported > 0
        or run.book_uploaded or run.book_segments_imported > 0
    local unfinished = (run.export and run.export.more) or (run.ann_export and run.ann_export.more)
        or (run.book_export and run.book_export.more)
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
