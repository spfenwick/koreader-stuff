--[[
Cover images for cloud books, downloaded from the catalog and kept in a
folder next to the catalog database (the server's own files, mostly small
WebP thumbnails).

Covers.download(fetch, root, store, dir, books, opts)
    blocking: downloads covers for books ({ id, href }), records them in the
    store. Runs in a subprocess (on-demand jobs here, or the sync job).
Covers.request(books)
    asks for covers in the background (CoverBrowser and ZenOS ask through
    BookInfoManager:extractInBackground, see virtual.lua). Several requests
    while a download runs are batched into the next one.
Covers.busy()
    true while downloading, so file browsers keep polling for covers.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Covers = {
    config = nil,   -- { server, db_path, dir, wal }
    job = nil,      -- { pid, fd, books }
    pending = {},   -- id -> book, asked for while a job runs
    pending_count = 0,
    on_done = nil,  -- function(results) after each job, in the UI process
}

local RETRY_AFTER = 24 * 60 * 60 -- covers the server couldn't provide
local RETRY_SOON = 2 * 60        -- covers not attempted (network lost)

--- File extension from an image's first bytes.
function Covers.imageType(data)
    if type(data) ~= "string" or #data < 12 then return nil end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    return nil
end

local function imageSize(data)
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    bb:free()
    return w, h
end

--- Downloads covers, writing each file atomically and recording it in the
-- store. opts: { now = os.time, deadline = unix time to stop at,
-- image_size = function(data) -> w, h }. Returns { fetched, failed,
-- results = { [id] = { file, w, h } or false } }.
function Covers.download(fetch, root, store, dir, books, opts)
    opts = opts or {}
    local now = opts.now or os.time
    local measure = opts.image_size or imageSize
    local resolve = require("cloudlibrary/sync").resolve
    local clock = require("cloudlibrary/timing").clock
    local result = { fetched = 0, failed = 0, results = {} }
    local t_start = clock()
    local spent = { network = 0, reading = 0, saving = 0, bytes = 0 }
    for _i, book in ipairs(books) do
        if opts.deadline and now() >= opts.deadline then break end
        local t0 = clock()
        local data, err, kind = fetch(resolve(root, book.href))
        spent.network = spent.network + (clock() - t0)
        if data == nil and kind ~= "http" then
            -- Not reached (Wi-Fi off, device asleep...): stop here, and don't
            -- count it against the covers.
            result.network_error = err or "network error"
            break
        end
        spent.bytes = spent.bytes + (type(data) == "string" and #data or 0)
        local ext = Covers.imageType(data)
        local w, h
        if ext then
            t0 = clock()
            w, h = measure(data)
            spent.reading = spent.reading + (clock() - t0)
        end
        if w and h then
            t0 = clock()
            local file = book.id .. "." .. ext
            local tmp = dir .. "/" .. file .. ".part"
            local f = io.open(tmp, "wb")
            local written = f and f:write(data)
            if f then f:close() end
            local renamed = written and os.rename(tmp, dir .. "/" .. file)
            if renamed then store:setCover(book.id, file, w, h) end
            spent.saving = spent.saving + (clock() - t0)
            if renamed then
                result.fetched = result.fetched + 1
                result.results[book.id] = { file = file, w = w, h = h }
            else
                os.remove(tmp)
                w = nil
            end
        end
        if not w then
            store:setCoverFailed(book.id, now())
            result.failed = result.failed + 1
            result.results[book.id] = false
        end
    end
    local n = result.fetched + result.failed
    if n > 0 then
        result.timing = {
            total = { ms = clock() - t_start, note = string.format("%d covers, %.1f MB, %.0f ms a cover",
                n, spent.bytes / 1048576, (clock() - t_start) / n) },
            network = { ms = spent.network },
            ["reading images"] = { ms = spent.reading },
            saving = { ms = spent.saving },
        }
    end
    return result
end

--- Downloads missing covers, newest books first. opts as above, plus limit,
-- and retry_all (also covers that failed less than a day ago).
function Covers.downloadMissing(fetch, root, store, dir, opts)
    opts = opts or {}
    local now = (opts.now or os.time)()
    local books = store:missingCovers(opts.limit, opts.retry_all and now + 1 or now - RETRY_AFTER)
    return Covers.download(fetch, root, store, dir, books, opts)
end

--- The download after each sync: a batch of missing covers (opts as for
-- downloadMissing, with limit). When most covers are missing (a first sync),
-- it switches to backfilling, kept in the store until every cover is done:
-- result.more says to start the next batch at once, result.backfill_done
-- that the last one was fetched. A lost network leaves backfilling on, so
-- the next sync carries on.
function Covers.prefetch(fetch, root, store, dir, opts)
    opts = opts or {}
    local clock = opts.now or os.time
    local backfill = store:getMeta("covers_backfill") == "1"
    if not backfill then
        local with_cover, downloaded, failed = store:coverCounts()
        if with_cover - downloaded - failed > with_cover / 2 then
            backfill = true
            store:setMeta("covers_backfill", "1")
        end
    end
    local result = Covers.downloadMissing(fetch, root, store, dir, opts)
    result.backfill = backfill
    if backfill and not result.network_error then
        if #store:missingCovers(1, clock() - RETRY_AFTER) > 0 then
            result.more = result.fetched + result.failed > 0
        else
            store:setMeta("covers_backfill", nil)
            result.backfill_done = true
        end
    end
    return result
end

--- Removes cover files no book uses (books gone from the catalog).
function Covers.cleanup(store, dir)
    local used = store:coverFiles()
    local removed = 0
    local ok, iter, d = pcall(lfs.dir, dir)
    if not ok then return 0 end
    for name in iter, d do
        if name ~= "." and name ~= ".." and not used[name] then
            os.remove(dir .. "/" .. name)
            removed = removed + 1
        end
    end
    return removed
end

-- In the UI process -----------------------------------------------------------------

function Covers.configure(config)
    Covers.config = config
    if config and config.dir then require("util").makePath(config.dir) end
end

function Covers.canFetch()
    if not (Covers.config and Covers.config.server) then return false end
    local NetworkMgr = require("ui/network/manager")
    return NetworkMgr:isConnected() and true or false
end

function Covers.busy()
    return Covers.job ~= nil
end

local function start(books)
    local cfg = Covers.config
    if not cfg or #books == 0 then return false end
    local ffiutil = require("ffi/util")
    local list = {}
    for _i, b in ipairs(books) do table.insert(list, { id = b.id, href = b.cover_href }) end
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local Store = require("cloudlibrary/store")
        local Http = require("cloudlibrary/http")
        local result
        local ok, err = pcall(function()
            local store = Store.open(cfg.db_path, cfg.wal)
            result = Covers.download(Http.fetcher(cfg.server), cfg.server.url, store, cfg.dir, list)
            store:close()
        end)
        if not ok then result = { error = tostring(err), results = {} } end
        ffiutil.writeToFD(child_fd, require("dump")(result), true)
    end, true)
    if not pid then
        logger.warn("CloudLibrary: can't start cover download", fd)
        return false
    end
    Covers.job = { pid = pid, fd = fd, books = books, started = require("cloudlibrary/timing").start() }
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.5, Covers.poll)
    return true
end

--- Asks for covers of these books (Virtual book tables with id and
-- cover_href). Returns true if they'll be fetched.
function Covers.request(books)
    if not Covers.canFetch() then return false end
    local fresh = {}
    for _i, b in ipairs(books) do
        if b.cover_href and not b.cover_file and not b.cover_failed
                and not (b.cover_retry_at and b.cover_retry_at > os.time()) then
            if Covers.job then
                if not Covers.pending[b.id] then
                    Covers.pending[b.id] = b
                    Covers.pending_count = Covers.pending_count + 1
                end
            else
                table.insert(fresh, b)
            end
        end
    end
    if Covers.job then return true end
    return start(fresh) or #fresh == 0
end

local function pollCovers()
    local job = Covers.job
    if not job then return end
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    if not ffiutil.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(0.5, Covers.poll)
        return
    end
    -- Not busy any more, whatever happens below.
    Covers.job = nil
    local data = ffiutil.readAllFromFD(job.fd)
    local result
    local chunk = data and data ~= "" and loadstring("return " .. data, "covers result")
    if chunk then
        setfenv(chunk, {})
        local ok, res = pcall(chunk)
        result = ok and type(res) == "table" and res or nil
    end
    result = result or { error = "the cover download stopped unexpectedly", results = {} }
    if result.error then logger.warn("CloudLibrary: covers:", result.error) end
    local Timing = require("cloudlibrary/timing")
    Timing.recordAll(result.timing, "covers on demand: ")
    Timing.record("covers on demand: wait", Timing.since(job.started),
        string.format("%d covers, from asking to having them", #job.books))
    local cfg = Covers.config
    local now = os.time()
    local results = type(result.results) == "table" and result.results or {}
    for _i, b in ipairs(job.books) do
        local r = results[b.id]
        if r then
            b.cover_file, b.cover_w, b.cover_h = r.file, r.w, r.h
            b.cover = cfg.dir .. "/" .. r.file
            b.cover_failed, b.cover_retry_at = nil, nil
        elseif r == false then
            -- The server had no usable cover: the store retries it in a day.
            b.cover_failed = now
        else
            -- Not attempted (network lost, or the job died): try again soon,
            -- or when Wi-Fi reconnects.
            b.cover_retry_at = now + RETRY_SOON
        end
    end
    -- Start the next batch before reporting, so file browsers polling
    -- busy() keep waiting for it.
    local next_books = {}
    for _id, b in pairs(Covers.pending) do table.insert(next_books, b) end
    Covers.pending, Covers.pending_count = {}, 0
    if #next_books > 0 then start(next_books) end
    if Covers.on_done then Covers.on_done(result) end
end

function Covers.poll()
    return require("cloudlibrary/guard").call("jobs", pollCovers)
end

return Covers
