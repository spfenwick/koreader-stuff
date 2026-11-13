--[[--
Knuth–Plass plugin: a one-off diagnostic of which engine KOReader really runs.

Copy this file to koreader/patches/ and restart KOReader (fully: force stop
it on Android). It writes koreader/knuthplass-engine-diagnose.txt, and runs
again on each start until you delete this file. Nothing is changed.

It records: the engine state file before and after the engine loads, the
engine files (size, inode, SHA-256), what the early patch did, the build the
running engine reports, and which engine libraries the process has mapped
(/proc/self/maps).
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local lines = {}
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    table.insert(lines, table.concat(parts, " "))
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local ok_android, android = pcall(require, "android")
if not ok_android then android = nil end
local dir
if android then
    dir = android.dir:match("^(.*)/[^/]+$") .. "/knuthplass"
else
    dir = DataStorage:getDataDir() .. "/knuthplass"
end

local function describe(path)
    local attr = lfs.attributes(path)
    if not attr then
        say(path, ": missing")
        return
    end
    local data = readFile(path)
    local sha = "?"
    if data then
        local ok, sha2 = pcall(require, "ffi/sha2")
        if ok then sha = sha2.sha256(data) end
    end
    local builds = {}
    if data then
        for hex in data:gmatch("%z(%x%x%x%x%x%x%x%x%x%x%x%x)%z") do
            table.insert(builds, hex)
        end
    end
    say(path, ": size", attr.size, "ino", attr.ino, "mode", attr.permissions,
        "sha256", sha, "12-hex strings", table.concat(builds, ","))
end

local function maps()
    local data = readFile("/proc/self/maps") or ""
    local seen = {}
    for line in data:gmatch("[^\n]+") do
        local path = line:match("%s(/%S+)$")
        if path and (path:find("knuthplass", 1, true) or path:find("cre", 1, true)
                or path:find("monolibtic", 1, true)) and not seen[path] then
            seen[path] = true
            local inode = line:match("^%S+%s+%S+%s+%S+%s+%S+%s+(%d+)")
            say("  mapped:", path, "inode", inode)
        end
    end
end

say("KOReader:", require("version"):getCurrentRevision())
say("pid:", require("ffi/util").getpid and require("ffi/util").getpid() or "?")
say("engine folder:", dir)
say("")
say("== state before the engine loads")
say(readFile(dir .. "/engine.lua") or "(none)")
describe(dir .. "/libkoreader-cre.so")
describe(dir .. "/libkoreader-cre.good.so")
say("package.loaded[libs/libkoreader-cre] already:", package.loaded["libs/libkoreader-cre"] ~= nil)
say("package.preload set:", package.preload["libs/libkoreader-cre"] ~= nil)
local patch = package.loaded["knuthplass_loader.patch"]
say("early patch ran:", patch ~= nil, "applied:", patch and patch.applied, "active:", patch and patch.active)
say("maps before loading:")
maps()

local ok, err = pcall(function()
    local cre = require("document/credocument"):engineInit()
    local view = cre.newDocView(100, 100, 0)
    say("")
    say("== after loading")
    say("reported build:", view:getStringProperty("crengine.knuth.plass.build"))
    say("tolerance property:", view:getStringProperty("crengine.style.justify.tolerance"))
    if view.close then view:close() end
end)
if not ok then say("loading failed:", err) end
say("early patch active now:", patch and patch.active)
say("maps after loading:")
maps()
say("")
say("== state after the engine loads")
say(readFile(dir .. "/engine.lua") or "(none)")

local out = io.open(DataStorage:getDataDir() .. "/knuthplass-engine-diagnose.txt", "wb")
if out then
    out:write(table.concat(lines, "\n"), "\n")
    out:close()
end
