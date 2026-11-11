-- Convergence test for Concordance's highlights and book data: several
-- simulated devices, with clocks that disagree, make random additions,
-- edits and removals and sync in a random order (segments arriving in any
-- order). After everyone has synced, every device must hold the same
-- highlights and the same book data.
--
-- The stores are driven directly (concordance/annstore.lua,
-- concordance/bookstore.lua), as annsync.lua and booksync.lua drive them:
-- observe the local state, export, import, plan, apply, applied.
-- Run through scripts/test-concordance.sh, which sets KOREADER_SRC.
--
--   CONVERGE_RUNS=200 CONVERGE_SEED=7 luajit tests/test_concordance_converge.lua

local S = dofile("tests/concordance/support.lua")
local check = S.check

local AnnFormat = require("concordance/annformat")
local AnnStore = require("concordance/annstore")
local BookFormat = require("concordance/bookformat")
local BookStore = require("concordance/bookstore")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/converge"
S.rmrf(TMP)
S.mkdirp(TMP)

local RUNS = tonumber(os.getenv("CONVERGE_RUNS")) or 25
local SEED = tonumber(os.getenv("CONVERGE_SEED")) or 20261111
local STEPS = 60
local MD5 = string.rep("7", 32)
local KIND = "rolling"

-- Simple digest stand-in: any stable one will do.
local function digest(s)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c * 7) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function xp(n) return string.format("/body/DocFragment[%d]/body/p[%d]/text().%d", n % 7 + 1, n, 0) end
local function stamp(t) return os.date("%Y-%m-%d %H:%M:%S", t) end

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

local function run(seed)
    math.randomseed(seed)
    local dir = TMP .. "/" .. seed
    S.mkdirp(dir)
    local clock = 1800000000
    local seg_n, item_n = 0, 0
    local used_times = {}
    -- What's on the server: { from, name, path, size, stream }.
    local server = {}

    local devices = {}
    -- Clocks: right, well ahead, behind.
    for i, skew in ipairs({ 0, 90000, -4000 }) do
        local name = "dev" .. i
        devices[i] = {
            name = name, skew = skew, items = {}, values = { rating = false, note = false },
            ann = AnnStore.new{ sq3 = S.SQ3, state_path = dir .. "/" .. name .. ".sqlite3", md5 = digest },
            book = BookStore.new{ sq3 = S.SQ3, state_path = dir .. "/" .. name .. ".sqlite3", md5 = digest },
            got = {},
        }
    end
    local function now(d) return clock + d.skew end

    local function observe(d)
        d.ann:observe{ md5 = MD5, kind = KIND, items = d.items, now = now(d), device = d.name }
        d.book:observe{ md5 = MD5, values = d.values, now = now(d), device = d.name }
    end

    -- Local changes ---------------------------------------------------------------
    local function add(d)
        -- Creation times are the keys: two devices making different
        -- highlights in the same second is a known limit, kept out of this.
        local t = now(d)
        while used_times[t] do t = t + 1 end
        used_times[t] = true
        item_n = item_n + 1
        table.insert(d.items, {
            datetime = stamp(t), drawer = "lighten", color = "yellow", text = "text " .. item_n,
            page = xp(item_n), pos0 = xp(item_n), pos1 = xp(item_n + 1), chapter = "Chapter",
        })
    end
    local function edit(d)
        if #d.items == 0 then return add(d) end
        local item = d.items[math.random(#d.items)]
        item.note = "note " .. math.random(1000) .. " by " .. d.name
        item.datetime_updated = stamp(now(d))
    end
    local function remove(d)
        if #d.items == 0 then return end
        table.remove(d.items, math.random(#d.items))
    end
    local function rate(d)
        d.values.rating = math.random(4) == 1 and false or math.random(5)
    end
    local function review(d)
        d.values.note = math.random(4) == 1 and false or ("review " .. math.random(1000) .. " by " .. d.name)
    end

    -- Syncing -----------------------------------------------------------------------
    local function upload(d)
        for _, st in ipairs({ { d.ann, "ann", AnnFormat }, { d.book, "book", BookFormat } }) do
            local store, stream, fmt = st[1], st[2], st[3]
            seg_n = seg_n + 1
            local path = dir .. "/" .. stream .. "-" .. seg_n .. ".jsonl"
            local exp = store:export{ device_id = d.name, out_path = path, now = now(d), max_records = 1000 }
            if exp then
                local name = fmt.segmentName(seg_n)
                store:markExported(path, d.name, name, exp.size, nil, now(d))
                server[#server + 1] = { from = d.name, name = name, path = path, size = exp.size, stream = stream }
            end
        end
    end
    local function download(d)
        local todo = {}
        for _, seg in ipairs(server) do
            if seg.from ~= d.name and not d.got[seg.name] then todo[#todo + 1] = seg end
        end
        -- In any order.
        for i = #todo, 2, -1 do
            local j = math.random(i)
            todo[i], todo[j] = todo[j], todo[i]
        end
        for _, seg in ipairs(todo) do
            local store = seg.stream == "ann" and d.ann or d.book
            local res, err = store:importSegment(seg.path, seg.from, seg.name, seg.size, nil, now(d))
            if not res then error("import of " .. seg.name .. " into " .. d.name .. " failed: " .. tostring(err)) end
            d.got[seg.name] = true
        end
    end
    local function apply(d)
        local ops = d.ann:plan(MD5, KIND, d.items)
        local removals = {}
        for _, op in ipairs(ops) do
            if op.op == "replace" then
                d.items[op.index] = op.item
            elseif op.op == "remove" then
                removals[#removals + 1] = op.index
            end
        end
        table.sort(removals, function(a, b) return a > b end)
        for _, index in ipairs(removals) do table.remove(d.items, index) end
        for _, op in ipairs(ops) do
            if op.op == "add" then table.insert(d.items, op.item) end
        end
        d.ann:applied(MD5, KIND, d.items)
        for _, op in ipairs(d.book:plan(MD5, d.values)) do
            d.values[op.prop] = op.value == nil and false or op.value
        end
        d.book:applied(MD5, d.values)
    end
    local function sync(d)
        observe(d)
        upload(d)
        download(d)
        apply(d)
    end

    local actions = { add, add, edit, edit, remove, rate, review, sync, sync, sync }
    for _ = 1, STEPS do
        clock = clock + math.random(1, 600)
        local d = devices[math.random(#devices)]
        local action = actions[math.random(#actions)]
        action(d)
        -- As when the book is closed: what changed is recorded then.
        if action ~= sync then observe(d) end
    end
    -- Everyone syncs until nothing more is sent.
    for _ = 1, 3 do
        for _, d in ipairs(devices) do
            clock = clock + 60
            sync(d)
        end
    end

    local function state(d)
        local lines = {}
        for _, item in ipairs(d.items) do lines[#lines + 1] = item.datetime .. " " .. AnnFormat.fieldsJson(item) end
        table.sort(lines)
        return table.concat(lines, "\n") .. "\nrating=" .. tostring(d.values.rating) .. "\nnote=" .. tostring(d.values.note)
    end
    local first = state(devices[1])
    local same = true
    for i = 2, #devices do
        if state(devices[i]) ~= first then
            same = false
            print("seed " .. seed .. ": " .. devices[i].name .. " differs from dev1")
            print("--- dev1\n" .. first .. "\n--- " .. devices[i].name .. "\n" .. state(devices[i]))
        end
    end
    -- And nothing is left to send or apply.
    local settled = true
    for _, d in ipairs(devices) do
        observe(d)
        if d.ann:counts().outbox ~= 0 or d.book:counts().outbox ~= 0 or #d.ann:plan(MD5, KIND, d.items) ~= 0
                or #d.book:plan(MD5, d.values) ~= 0 then
            settled = false
        end
    end
    return same, settled, #devices[1].items, deepcopy(devices[1].values)
end

local all_same, all_settled, with_items = true, true, 0
for i = 1, RUNS do
    local same, settled, n = run(SEED + i)
    if not same then all_same = false end
    if not settled then
        all_settled = false
        print("seed " .. (SEED + i) .. ": something left to send or apply")
    end
    if n > 0 then with_items = with_items + 1 end
end
check(all_same, RUNS .. " random histories: every device ends with the same highlights and book data")
check(all_settled, "and nothing is left to send or apply")
check(with_items > RUNS / 2, "most histories end with highlights (the test does something): " .. with_items)

S.finish("concordance convergence test")
