--[[
Full and quick sync against a real catalog, with the plugin's own code, in
KOReader's LuaJIT. Read-only. Credentials from the environment:

    CL_URL=… CL_USER=… CL_PASS=… KOREADER_DIR=… \
        tests/cloudlibrary/live_sync.sh <database path>
]]
local REPO, DB = arg[1], arg[2]
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DB .. ".settings.lua")
package.path = REPO .. "/cloudlibrary.koplugin/?.lua;" .. package.path

local Store = require("cloudlibrary/store")
local Sync = require("cloudlibrary/sync")
local Http = require("cloudlibrary/http")
local time = require("ui/time")

local server = { url = os.getenv("CL_URL"), username = os.getenv("CL_USER"), password = os.getenv("CL_PASS") }
local out = io.stderr
local function report(label, r, err, started)
    local secs = time.to_s(time.now() - started)
    if not r then out:write(label, " FAILED: ", tostring(err), "\n") return end
    local parts = {}
    for k, v in pairs(r) do table.insert(parts, k .. "=" .. tostring(v)) end
    table.sort(parts)
    out:write(string.format("%s %.1fs %s\n", label, secs, table.concat(parts, " ")))
end

local store = Store.open(DB, true)
local function run(label, mode)
    local s = Sync.new{ store = store, root = server.url, fetch = Http.fetcher(server),
        progress = function(what, n, m) if what == "series" and n % 25 == 0 then out:write("  series ", n, "/", m, "\n") end end }
    local started = time.now()
    local r, err = s[mode](s)
    report(label, r, err, started)
end
run("full", "full")
run("quick", "quick")
run("full-again", "full")
local t = time.now()
local listing = store:listing()
out:write(string.format("listing %d books in %.0f ms\n", #listing, time.to_ms(time.now() - t)))
local in_series, with_pages = 0, 0
for _i, b in ipairs(listing) do
    if b.series then in_series = in_series + 1 end
    if b.pages then with_pages = with_pages + 1 end
end
out:write("in series ", in_series, ", with page counts ", with_pages, "\n")
store:close()
local f = io.open(DB); local size = f:seek("end"); f:close()
out:write(string.format("database %.1f MB\n", size / 1048576))
os.exit(0)
