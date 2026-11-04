-- Benchmark for supersync.koplugin: three devices with about five years of
-- synthetic history each (~100k page_stat_data rows), against a local
-- WebDAV server (rclone). Reports time and data moved for:
--   1. a device publishing its whole history for the first time,
--   2. a new device joining and importing everyone's history,
--   3. an incremental sync after one reading session.
-- Run with scripts/test-statsync.sh bench. Desktop timings: an e-reader's
-- CPU and storage are several times slower.

local S = dofile("tests/supersync/support.lua")

local Engine = require("supersync/engine")
local Store = require("supersync/store")
local WebDav = require("supersync/webdav")

local TMP = assert(os.getenv("STATSYNC_TMP")) .. "/bench"
S.rmrf(TMP)
S.mkdirp(TMP)
local EVENTS = tonumber(os.getenv("STATSYNC_BENCH_EVENTS")) or 100000

local server = assert(S.startWebDav(TMP .. "/server", "u", "p"))
local loop = S.Loop.new()
local quiet = { info = function() end, warn = print, dbg = function() end, err = print }

local function newSim(name)
    local d = S.newDevice(name, TMP .. "/" .. name)
    d.id = "bench" .. name
    d.runs = {}
    d.store = Store.new{ sq3 = S.SQ3, stats_path = d.db, state_path = d.state }
    d.engine = Engine.new{
        store = d.store, logger = quiet,
        work_dir = d.dir .. "/work", tmp_dir = d.dir .. "/work/incoming",
        getDeviceId = function() return d.id end, now = os.time,
        schedule = function(delay, fn) loop:schedule(delay, fn) end, poll_interval = 0.02,
        canRun = function() return true end, flush = function() end,
        spawn = S.Fork.spawn, isDone = S.Fork.isDone, kill = S.Fork.kill,
        time_limit = 600,
        makeTransport = function()
            return WebDav.new{ http = S.Http.new(), address = server.url, username = "u", password = "p", root = "statsync" }
        end,
        saveStatus = function() end,
        onDone = function(_, run) table.insert(d.runs, run) end,
    }
    return d
end

-- ~100k events over 5 years: 40 books, reading sessions of 20-60 pages.
local function fillHistory(d, seed)
    math.randomseed(seed)
    local t0 = S.now()
    local start = 1600000000
    local n, book_i = 0, 0
    while n < EVENTS do
        book_i = book_i + 1
        local book = { md5 = string.format("%032x", (seed * 1000 + book_i % 40) * 104729),
                       title = "Book " .. (book_i % 40), authors = "Author", pages = 300 }
        local sessions = {}
        for _ = 1, 50 do
            local t = start + math.random(0, 5 * 365 * 86400)
            local page = math.random(1, 250)
            for p = 1, math.random(20, 60) do
                sessions[#sessions + 1] = { page + p, t, math.random(10, 90) }
                t = t + 60
            end
        end
        d:read(book, sessions)
        n = d:count("SELECT count(*) FROM page_stat_data")
    end
    return n, S.now() - t0
end

local function syncUntilIdle(list)
    for _, d in ipairs(list) do d.runs = {} end
    local t0 = S.now()
    for _, d in ipairs(list) do d.engine:request("bench") end
    loop:run(1200)
    local wall = S.now() - t0
    local out = {}
    for _, d in ipairs(list) do
        local r = { wall = wall, runs = #d.runs, up = 0, down = 0, requests = 0, export_cpu = 0, import_cpu = 0,
                    net = 0, uploaded = 0, imported = 0 }
        for _, run in ipairs(d.runs) do
            assert(not run.error, run.error)
            local res = run.result or {}
            r.up = r.up + (res.bytes_up or 0)
            r.down = r.down + (res.bytes_down or 0)
            r.requests = r.requests + (res.requests or 0)
            r.export_cpu = r.export_cpu + (run.export_cpu or 0)
            r.import_cpu = r.import_cpu + (run.import_cpu or 0)
            r.net = r.net + (run.net_time or 0)
            r.uploaded = r.uploaded + run.uploaded_events
            r.imported = r.imported + run.imported_events
        end
        out[d.name] = r
    end
    return out
end

local function report(label, r)
    print(string.format("%-34s %2d cycles  up %8.1f KB  down %8.1f KB  %4d requests  export %.2fs  import %.2fs  sent %6d  received %6d  (wall %.1fs)",
        label, r.runs, r.up / 1024, r.down / 1024, r.requests, r.export_cpu, r.import_cpu, r.uploaded, r.imported, r.wall))
end

local A, B, C = newSim("A"), newSim("B"), newSim("C")
for i, d in ipairs({ A, B, C }) do
    local n, t = fillHistory(d, i)
    print(string.format("device %s: %d events of history (written by KOReader's insertDB in %.1fs), db %.1f MB",
        d.name, n, t, (io.open(d.db, "rb"):seek("end")) / 1048576))
end

print("\n1. First sync of a device with 5 years of history (empty server):")
report("   A publishes its history", syncUntilIdle({ A }).A)
local r = syncUntilIdle({ B, C })
report("   B (at the same time as C)", r.B)
report("   C (at the same time as B)", r.C)
syncUntilIdle({ A, B, C }) -- everyone up to date

print("\n2. A new device joins:")
local D = newSim("D")
report("   D imports all three histories", syncUntilIdle({ D }).D)
local total = D:count("SELECT count(*) FROM page_stat_data")
print(string.format("   D now has %d events; same as A: %s", total, tostring(D:dump() == A:dump())))

print("\n3. Incremental sync after one reading session:")
A:read({ md5 = string.format("%032x", 1000 * 104729), title = "Book 0", authors = "Author", pages = 300 },
    (function() local s = {} for p = 1, 30 do s[p] = { p, 1800000000 + p * 60, 45 } end return s end)())
report("   A uploads the session", syncUntilIdle({ A }).A)
report("   B gets it", syncUntilIdle({ B }).B)
report("   C, nothing new anywhere", (function() syncUntilIdle({ C }) return syncUntilIdle({ C }).C end)())

-- Main-process cost of the export step with nothing new
local t0 = os.clock()
local _, _, why = D.store:export{ device_id = "x", out_path = TMP .. "/none.jsonl", now = 0, max_events = 20000, force_diff = true }
local t1 = os.clock()
local _, _, why2 = D.store:export{ device_id = "x", out_path = TMP .. "/none.jsonl", now = 0, max_events = 20000 }
print(string.format("\nExport step over %d events, nothing new: full diff %.3fs CPU (%s), fingerprint only %.3fs CPU (%s)",
    total, t1 - t0, why, os.clock() - t1, why2))

server.stop()
