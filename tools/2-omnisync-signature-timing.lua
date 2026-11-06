--[[--
OmniSync: a one-off timing of the body signature planned in
omnisync.koplugin/IDENTITY.md, on a real device.

1. Copy this file to koreader/patches/ and restart KOReader.
2. Ten seconds after start it times up to 30 EPUBs from the home folder
   (a spread of sizes, always including the largest), then shows a summary.
   KOReader is unresponsive while it runs (at most about 2 minutes).
3. The report goes to koreader/omnisync-signature-timing.txt. Delete the
   report to run it again; delete this file when you're done.

(Desktop check: OMNISYNC_TIMING_DIR=<folder> runs it at once on that
folder, prints each book's signature, and writes no report.)

Nothing is written except the report. The real thing would run in a
subprocess, once per file; the CPU time is the same.

Signature, per IDENTITY.md: for each spine item in order, the element tag
sequence and the whitespace-collapsed text of its <body>, hashed. The book
is read in one pass in storage order (reading out of order makes the
archiver reopen the file); per-file hashes are combined in spine order.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local test_dir = os.getenv("OMNISYNC_TIMING_DIR")
local data_dir = DataStorage:getFullDataDir() or DataStorage:getDataDir()
local report_path = data_dir .. "/omnisync-signature-timing.txt"
if not test_dir then
    local f = io.open(report_path, "rb")
    if f then f:close() return end
end

local MAX_BOOKS = 30
local TIME_BUDGET = 120

local function now()
    local time = require("ui/time")
    return time.to_s(time.now())
end

local function md5hex(s)
    local md5 = require("ffi/sha2").md5
    local h = md5()
    h(s)
    return h()
end

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function join(dir, href)
    href = href:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
    local parts = {}
    for p in ((dir ~= "" and dir .. "/" or "") .. href):gmatch("[^/]+") do
        if p == ".." then table.remove(parts) elseif p ~= "." then table.insert(parts, p) end
    end
    return table.concat(parts, "/")
end

local function bodyHash(data)
    local body = data:match("<body.*") or data
    local tags = {}
    for t in body:gmatch("<(/?[%w:]+)") do tags[#tags + 1] = t end
    local text = body:gsub("<[^>]+>", " "):gsub("%s+", " ")
    return md5hex(table.concat(tags, " ") .. "\0" .. text)
end

--- Returns signature, { open=, opf=, bodies=, files=, bytes= } or nil, err.
local function signature(path)
    local Archiver = require("ffi/archiver")
    local t0 = now()
    local arc = Archiver.Reader:new()
    if not arc:open(path) then return nil, "can't open" end
    for _entry in arc:iterate() do end -- index the entries
    local t1 = now()
    local container = arc:extractToMemory("META-INF/container.xml")
    local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
    local opf = opf_path and arc:extractToMemory(opf_path)
    if not opf then arc:close() return nil, "no package file" end
    local base = dirname(opf_path)
    local hrefs = {}
    for item in opf:gmatch("<[%w:]*item%s[^>]*>") do
        local id, href = item:match('%sid%s*=%s*"([^"]+)"'), item:match('%shref%s*=%s*"([^"]+)"')
        if id and href then hrefs[id] = join(base, href) end
    end
    local spine, wanted = {}, {}
    for ref in opf:gmatch("<[%w:]*itemref%s[^>]*>") do
        local file = hrefs[ref:match('idref%s*=%s*"([^"]+)"') or ""]
        if file then table.insert(spine, file); wanted[file] = true end
    end
    local t2 = now()
    local hashes, bytes = {}, 0
    for entry in arc:iterate() do
        if wanted[entry.path] then
            local data = arc:extractToMemory(entry.path)
            if data then
                bytes = bytes + #data
                hashes[entry.path] = bodyHash(data)
            end
        end
    end
    arc:close()
    local parts = {}
    for i, file in ipairs(spine) do parts[i] = hashes[file] or "-" end
    local sig = md5hex(table.concat(parts, "\n"))
    local t3 = now()
    return sig, { open = t1 - t0, opf = t2 - t1, bodies = t3 - t2, files = #spine, bytes = bytes }
end

local function findEpubs(dir, out, depth)
    if depth > 3 then return end
    local ok, iter, d = pcall(lfs.dir, dir)
    if not ok then return end
    for name in iter, d do
        if name:sub(1, 1) ~= "." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" and not name:match("%.sdr$") then
                findEpubs(path, out, depth + 1)
            elseif attr and attr.mode == "file" and name:lower():match("%.epub$") then
                table.insert(out, { path = path, size = attr.size })
            end
        end
    end
end

local function pick(books)
    table.sort(books, function(a, b) return a.size > b.size end)
    if #books <= MAX_BOOKS then return books end
    local out, step = {}, (#books - 1) / (MAX_BOOKS - 1)
    for i = 0, MAX_BOOKS - 1 do table.insert(out, books[math.floor(i * step + 0.5) + 1]) end
    return out
end

local function percentile(list, p)
    if #list == 0 then return 0 end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    return s[math.max(1, math.ceil(#s * p))]
end

local function run()
    local util = require("util")
    local Device = require("device")
    local home = test_dir or G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
    local all = {}
    findEpubs(home, all, 0)
    local books = pick(all)
    local lines = {
        "OmniSync body signature timing",
        "device: " .. tostring(Device.model) .. ", " .. os.date("%Y-%m-%d %H:%M"),
        "home: " .. home .. ", " .. #all .. " EPUBs, timing " .. #books,
        "",
        "seconds: total = index + package + bodies; partialMD5 for comparison",
        string.format("%-8s %-6s %7s %7s %7s %7s %8s  %s", "MB", "spine", "total", "index", "pkg", "bodies", "pmd5", "file"),
    }
    local totals, per_mb, failures = {}, {}, 0
    local started = now()
    for _i, b in ipairs(books) do
        if now() - started > TIME_BUDGET then
            table.insert(lines, "(stopped: time budget of " .. TIME_BUDGET .. " s reached)")
            break
        end
        local p0 = now()
        util.partialMD5(b.path)
        local pmd5 = now() - p0
        local ok, sig, info = pcall(signature, b.path)
        local name = b.path:match("[^/]+$")
        if ok and sig and test_dir then print(sig, name) end
        if ok and sig then
            local total = info.open + info.opf + info.bodies
            table.insert(totals, total)
            table.insert(per_mb, total / math.max(b.size / 1048576, 0.01))
            table.insert(lines, string.format("%-8.2f %-6d %7.3f %7.3f %7.3f %7.3f %8.4f  %s",
                b.size / 1048576, info.files, total, info.open, info.opf, info.bodies, pmd5, name))
        else
            failures = failures + 1
            table.insert(lines, string.format("%-8.2f failed: %s  %s", b.size / 1048576, tostring(ok and info or sig), name))
        end
        collectgarbage()
    end
    local sum = 0
    for _i, t in ipairs(totals) do sum = sum + t end
    local summary = string.format(
        "%d books timed, %d failed\nmedian %.2f s, 90th %.2f s, max %.2f s\nmedian %.2f s per MB\nall: %.1f s",
        #totals, failures, percentile(totals, 0.5), percentile(totals, 0.9),
        percentile(totals, 1), percentile(per_mb, 0.5), sum)
    table.insert(lines, "")
    table.insert(lines, summary)
    local f = not test_dir and io.open(report_path, "wb")
    if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
    logger.info("OmniSync timing:", (summary:gsub("\n", "; ")))
    return summary
end

if test_dir then
    print(run())
    return
end

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
UIManager:scheduleIn(10, function()
    local notice = InfoMessage:new{ text = "OmniSync: timing book signatures (up to 2 minutes)…" }
    UIManager:show(notice)
    UIManager:forceRePaint()
    local ok, summary = pcall(run)
    UIManager:close(notice)
    UIManager:show(InfoMessage:new{
        text = ok and ("OmniSync signature timing\n\n" .. summary .. "\n\nReport: " .. report_path)
            or ("OmniSync timing failed: " .. tostring(summary)),
    })
end)
