--[[
Cover images for cloud books, downloaded from the catalog and kept in a
folder next to the catalog database (the server's own files, mostly small
WebP thumbnails). Files go in subfolders named after the first two
characters of the book's UUID ("0f/0f3c….webp"): on FAT32 (Kobo and Kindle
user storage) one folder holds only about 13,000 files with names this long.

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
    on_arrived = nil, -- function(books) whose cover state a job changed, before on_done
}

local RETRY_AFTER = 24 * 60 * 60 -- covers the server couldn't provide
local RETRY_SOON = 2 * 60        -- covers not attempted (network lost)
-- Store key naming the cover a background job is on: if the job dies (a
-- crash decoding an image, or killed), that cover is skipped afterwards.
Covers.PROGRESS_KEY = "cover_in_progress"

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

--- Cover file name for a book, relative to the covers folder: in a
-- subfolder named after the first two characters of its id.
function Covers.fileFor(id, ext)
    local bucket = tostring(id):sub(1, 2):lower()
    if not bucket:match("^%w%w$") then bucket = "_" end
    return bucket .. "/" .. id .. "." .. ext
end

--- Downloads covers, writing each file atomically and recording it in the
-- store. books: { id, href, etag, modified }; with etag or modified (the
-- cover kept here), it's asked for only if it changed. opts: { now =
-- os.time, deadline = unix time to stop at, image_size = function(data) ->
-- w, h, track = true to record the cover being worked on under
-- PROGRESS_KEY }. Returns { fetched, failed, unchanged, results = { [id] =
-- { file, w, h }, { unchanged = true } or false } }.
function Covers.download(fetch, root, store, dir, books, opts)
    opts = opts or {}
    local now = opts.now or os.time
    local measure = opts.image_size or imageSize
    local resolve = require("athenaeum/sync").resolve
    local clock = require("athenaeum/timing").clock
    local result = { fetched = 0, failed = 0, unchanged = 0, results = {} }
    local t_start = clock()
    local spent = { network = 0, reading = 0, saving = 0, bytes = 0 }
    -- Keeps a downloaded image, or marks the cover failed.
    local function save(book, data, headers)
        spent.bytes = spent.bytes + (type(data) == "string" and #data or 0)
        local ext = Covers.imageType(data)
        local w, h, t0
        if ext then
            t0 = clock()
            w, h = measure(data)
            spent.reading = spent.reading + (clock() - t0)
        end
        if w and h then
            t0 = clock()
            local file = Covers.fileFor(book.id, ext)
            lfs.mkdir(dir .. "/" .. file:match("^[^/]+")) -- fails harmlessly if it exists
            local tmp = dir .. "/" .. file .. ".part"
            local f = io.open(tmp, "wb")
            local written = f and f:write(data)
            if f then f:close() end
            local renamed = written and os.rename(tmp, dir .. "/" .. file)
            if renamed then
                headers = type(headers) == "table" and headers or {}
                store:setCover(book.id, file, w, h,
                    { etag = headers["etag"], modified = headers["last-modified"], checked = now() })
            end
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
    for _i, book in ipairs(books) do
        if opts.deadline and now() >= opts.deadline then break end
        if opts.track then store:setMeta(Covers.PROGRESS_KEY, book.id) end
        local t0 = clock()
        local conditional
        if book.etag or book.modified then
            conditional = { ["If-None-Match"] = book.etag, ["If-Modified-Since"] = book.modified }
        end
        local data, err, kind, headers = fetch(resolve(root, book.href), conditional)
        spent.network = spent.network + (clock() - t0)
        if kind == "not_modified" then
            store:setCoverUnchanged(book.id, now())
            result.unchanged = result.unchanged + 1
            result.results[book.id] = { unchanged = true }
        elseif data == nil and kind ~= "http" then
            -- Not reached (Wi-Fi off, device asleep...): stop here, and don't
            -- count it against the covers.
            result.network_error = err or "network error"
            break
        else
            save(book, data, headers)
        end
    end
    if opts.track then store:setMeta(Covers.PROGRESS_KEY, nil) end
    local n = result.fetched + result.failed + result.unchanged
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

--- Downloads missing covers, newest books first. opts as above, plus
-- limit (a batch: result.more then says whether to start another) and
-- retry_before (also retry covers that failed before this time; by default
-- those that failed more than a day ago; retry_all: all of them).
function Covers.downloadMissing(fetch, root, store, dir, opts)
    opts = opts or {}
    local clock = opts.now or os.time
    local function retryBefore()
        if opts.retry_before then return opts.retry_before end
        return opts.retry_all and clock() + 1 or clock() - RETRY_AFTER
    end
    local books = store:missingCovers(opts.limit, retryBefore())
    local result = Covers.download(fetch, root, store, dir, books, opts)
    if opts.limit and not result.network_error then
        result.left = #store:missingCovers(1, retryBefore()) > 0
        result.more = result.left and result.fetched + result.failed + result.unchanged > 0
    end
    return result
end

--- After a job died: marks the cover it was on as failed (retried like any
-- failed cover). Returns that book's id, or nil.
function Covers.recoverCrash(store, now)
    local id = store:getMeta(Covers.PROGRESS_KEY)
    if not id then return nil end
    store:setCoverFailed(id, now or os.time())
    store:setMeta(Covers.PROGRESS_KEY, nil)
    return id
end

--- The download after each sync: a batch of missing covers (opts as for
-- downloadMissing, with limit). When most covers are missing (a first sync),
-- it switches to backfilling, kept in the store until every cover is done:
-- result.more says to start the next batch at once, result.backfill_done
-- that the last one was fetched. A lost network leaves backfilling on, so
-- the next sync carries on.
function Covers.prefetch(fetch, root, store, dir, opts)
    opts = opts or {}
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
    if not backfill then
        result.more = nil
    elseif result.left == false then
        store:setMeta("covers_backfill", nil)
        result.backfill_done = true
    end
    return result
end

--- Removes cover files no book uses (books gone from the catalog), and moves
-- covers saved before subfolders were used into their subfolder. Returns the
-- number of files removed and the number moved.
function Covers.cleanup(store, dir)
    local used = store:coverFiles()
    local removed, moved = 0, 0
    local ok, iter, d = pcall(lfs.dir, dir)
    if not ok then return 0, 0 end
    local names = {}
    for name in iter, d do
        if name ~= "." and name ~= ".." then table.insert(names, name) end
    end
    for _i, name in ipairs(names) do
        local path = dir .. "/" .. name
        if lfs.attributes(path, "mode") == "directory" then
            for sub in lfs.dir(path) do
                if sub ~= "." and sub ~= ".." and not used[name .. "/" .. sub] then
                    os.remove(path .. "/" .. sub)
                    removed = removed + 1
                end
            end
        elseif used[name] then
            local id, ext = name:match("^(.+)%.(%w+)$")
            local file = id and Covers.fileFor(id, ext)
            if file then
                lfs.mkdir(dir .. "/" .. file:match("^[^/]+"))
                if os.rename(path, dir .. "/" .. file) then
                    store:moveCoverFile(name, file)
                    used[file] = true -- its subfolder may not be cleaned yet
                    moved = moved + 1
                end
            end
        else
            os.remove(path)
            removed = removed + 1
        end
    end
    return removed, moved
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
        local Store = require("athenaeum/store")
        local Http = require("athenaeum/http")
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
        logger.warn("Athenaeum: can't start cover download", fd)
        return false
    end
    Covers.job = { pid = pid, fd = fd, books = books, started = require("athenaeum/timing").start() }
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
        if b.cover_href and (not b.cover_file or b.cover_stale) and not b.cover_failed
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
    if result.error then logger.warn("Athenaeum: covers:", result.error) end
    local Timing = require("athenaeum/timing")
    Timing.recordAll(result.timing, "covers on demand: ")
    Timing.record("covers on demand: wait", Timing.since(job.started),
        string.format("%d covers, from asking to having them", #job.books))
    local cfg = Covers.config
    local now = os.time()
    local results = type(result.results) == "table" and result.results or {}
    for _i, b in ipairs(job.books) do
        local r = results[b.id]
        if r and r.unchanged then
            b.cover_stale = nil
        elseif r then
            b.cover_file, b.cover_w, b.cover_h = r.file, r.w, r.h
            b.cover = cfg.dir .. "/" .. r.file
            b.cover_failed, b.cover_retry_at, b.cover_stale = nil, nil, nil
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
    -- Every book asked for changed state (cover, none, or retry later).
    if Covers.on_arrived and #job.books > 0 then
        local ok, err = pcall(Covers.on_arrived, job.books)
        if not ok then logger.warn("Athenaeum: covers: on_arrived:", err) end
    end
    if Covers.on_done then Covers.on_done(result) end
end

function Covers.poll()
    return require("athenaeum/guard").call("jobs", pollCovers)
end

return Covers
