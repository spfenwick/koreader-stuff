-- Tests for tools/concordance-dump.lua: segments of each stream, written by
-- the plugin's own code, printed with their tags spelled out.
-- Run through scripts/test-concordance.sh.

local S = dofile("tests/concordance/support.lua")
local check = S.check

local Codec = require("concordance/codec")
local AnnFormat = require("concordance/annformat")
local BookFormat = require("concordance/bookformat")
local IdFormat = require("concordance/idformat")
local Zstd = require("concordance/zstd")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/dump"
S.rmrf(TMP)
local DIR = TMP .. "/devices/dev1"
S.mkdirp(DIR)

local LUA = os.getenv("LUA") or "luajit"
local function dump(args)
    local p = io.popen(LUA .. " tools/concordance-dump.lua " .. args .. " 2>&1")
    local out = p:read("*a")
    local ok = p:close()
    return out, ok
end
local function lines(out)
    local t = {}
    for l in out:gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end
local function has(out, s) return out:find(s, 1, true) ~= nil end

-- The tool carries its own copy of codec.lua: it must be the plugin's.
do
    local tool = S.readFile("tools/concordance-dump.lua") or ""
    local copy = tool:match("\n%-%- BEGIN concordance/codec%.lua\n(.-)%-%- END concordance/codec%.lua\n")
    check(copy == S.readFile("concordance.koplugin/concordance/codec.lua"),
        "the tool's copy of codec.lua is current (run scripts/sync-dump-codec.sh)")
end

local MD5 = "0123456789abcdef0123456789abcdef"

-- Statistics, compressed as on the server.
local stats = table.concat({
    Codec.headerLine("dev1", 1700000000),
    Codec.bookLine{ md5 = MD5, title = "Dune", authors = "Frank Herbert", pages = 300 },
    Codec.eventLine(MD5, 12, 1700000100, 31, 300),
    Codec.trailerLine(1, 1),
}, "\n") .. "\n"
S.writeFile(DIR .. "/seg-0000000001.jsonl.zst", Zstd.compress(stats))

local out, ok = dump(DIR .. "/seg-0000000001.jsonl.zst")
local l = lines(out)
check(ok and #l == 4, "statistics: four records, no file heading for one file: " .. out)
check(l[1] == '{"type":"header","format":"statsync","version":1,"minor_version":0,"device":"dev1","created":1700000000}',
    "header spelled out: " .. tostring(l[1]))
check(l[2] == '{"type":"book","md5":"' .. MD5 .. '","title":"Dune","authors":"Frank Herbert","pages":300}',
    "book: " .. tostring(l[2]))
check(l[3] == '{"type":"event","md5":"' .. MD5 .. '","page":12,"start_time":1700000100,"duration":31,"total_pages":300}',
    "event: " .. tostring(l[3]))
check(l[4] == '{"type":"trailer","books":1,"events":1}', "trailer: " .. tostring(l[4]))

out = dump("--dates " .. DIR .. "/seg-0000000001.jsonl.zst")
check(has(out, '"start_time":"' .. os.date("%Y-%m-%d %H:%M:%S", 1700000100) .. '"'), "--dates: local dates")
out = dump("--pretty " .. DIR .. "/seg-0000000001.jsonl.zst")
check(has(out, '{\n  "type":"event",\n  "md5":'), "--pretty: a field per line")

-- Highlights, uncompressed; book data; identity.
S.writeFile(DIR .. "/ann-0000000001.jsonl", table.concat({
    AnnFormat.headerLine("dev1", 1700000000),
    AnnFormat.bookLine{ md5 = MD5, title = "Dune" },
    AnnFormat.recordLine{ md5 = MD5, kind = "rolling", key = "k1", updated = 1700000200, device = "dev1",
                          fields_json = '{"text":"Fear is the mind-killer"}' },
    AnnFormat.recordLine{ md5 = MD5, kind = "rolling", key = "k2", updated = 1700000300, device = "dev2" },
    AnnFormat.trailerLine(1, 2),
}, "\n") .. "\n")
S.writeFile(DIR .. "/book-0000000001.jsonl", table.concat({
    BookFormat.headerLine("dev1", 1700000000),
    BookFormat.bookLine{ md5 = MD5, title = "Dune" },
    BookFormat.recordLine{ md5 = MD5, prop = "status", updated = 1700000400, device = "dev1", value_json = '"complete"' },
    BookFormat.recordLine{ md5 = MD5, prop = "rating", updated = 1700000500, device = "dev1" },
    BookFormat.trailerLine(1, 2),
}, "\n") .. "\n")
S.writeFile(DIR .. "/id-0000000001.jsonl", table.concat({
    IdFormat.headerLine("dev1", 1700000000),
    IdFormat.recordLine{ md5 = MD5, src = "link", n = 2, uuids = { "u1" }, sig = "s1", ids = { "isbn:1" } },
    IdFormat.trailerLine(1),
}, "\n") .. "\n")
S.writeFile(DIR .. "/meta.json", '{"deviceId":"dev1"}')

out = dump(DIR .. "/ann-0000000001.jsonl")
check(has(out, '{"type":"annotation","md5":"' .. MD5 .. '","kind":"rolling","key":"k1","updated":1700000200,"device":"dev1","fields":{"text":"Fear is the mind-killer"}}'),
    "annotation: " .. out)
check(has(out, '"type":"annotation_deleted"') and has(out, '"key":"k2","updated":1700000300,"device":"dev2"}'),
    "annotation deleted")
out = dump(DIR .. "/book-0000000001.jsonl")
check(has(out, '{"type":"property_set","md5":"' .. MD5 .. '","property":"status","updated":1700000400,"device":"dev1","value":"complete"}'),
    "property set: " .. out)
check(has(out, '{"type":"property_cleared","md5":"' .. MD5 .. '","property":"rating"'), "property cleared")
out = dump(DIR .. "/id-0000000001.jsonl")
check(has(out, '{"type":"identity","md5":"' .. MD5 .. '","source":"link","round":2,"uuids":["u1"],"signature":"s1","other_ids":["isbn:1"]}'),
    "identity: " .. out)
check(has(out, '{"type":"trailer","records":1}'), "identity trailer")

-- A folder: every segment, by stream then number, each with a heading; meta.json left out.
S.writeFile(DIR .. "/seg-0000000002.jsonl", Codec.headerLine("dev1", 1700000000) .. "\n" .. Codec.trailerLine(0, 0) .. "\n")
out, ok = dump(DIR)
local headings = {}
for h in out:gmatch("# ([^\n]+)") do headings[#headings + 1] = h:match("([%w]+%-%d+)%.jsonl") end
check(ok and table.concat(headings, ",") == "ann-0000000001,book-0000000001,id-0000000001,seg-0000000001,seg-0000000002",
    "folder: each segment, in order: " .. table.concat(headings, ","))
check(not has(out, "deviceId"), "folder: meta.json not printed")

-- Unknown record types and fields pass through; problems go to stderr.
S.writeFile(TMP .. "/odd.jsonl", Codec.headerLine("dev1", 1) .. "\n" .. '{"t":"del","md5":"m","zz":1}' .. "\n")
out = dump(TMP .. "/odd.jsonl")
check(has(out, '{"type":"del","md5":"m","zz":1}'), "unknown record type kept as it is: " .. out)
check(has(out, "no trailer"), "no trailer: said")
out, ok = dump(TMP .. "/missing.jsonl")
check(not ok and has(out, "missing.jsonl"), "missing file: an error")

S.finish("concordance dump tool tests")
