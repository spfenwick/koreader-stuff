--[[
Timings: how long each step takes on this device. Every measurement is
logged ("CloudLibrary timing: …" in crash.log) and kept, summarised, for
Tools → Cloud library → Timings.

    local t = Timing.start()
    ...
    Timing.record("catalog: load", Timing.since(t), "2154 books")

Times are milliseconds (with fractions).
]]

local logger = require("logger")

local Timing = {
    stats = {},     -- name -> { count, total, max, last, note, at }
    started = os.time(),
}

local clock
do
    local ok, time = pcall(require, "ui/time")
    if ok and time.monotonic then
        clock = function() return time.to_us(time.monotonic()) / 1000 end
    else
        clock = function() return os.clock() * 1000 end
    end
end
Timing.clock = clock

function Timing.start()
    return clock()
end

function Timing.since(t0)
    return clock() - t0
end

--- Records a measurement. quiet: log at debug level only (frequent ones).
function Timing.record(name, ms, note, quiet)
    if type(ms) ~= "number" then return end
    local s = Timing.stats[name]
    if not s then
        s = { count = 0, total = 0, max = 0 }
        Timing.stats[name] = s
    end
    s.count = s.count + 1
    s.total = s.total + ms
    if ms > s.max then s.max = ms end
    s.last, s.note, s.at = ms, note, os.time()
    local line = string.format("CloudLibrary timing: %s %.0f ms%s", name, ms, note and (" (" .. note .. ")") or "")
    if quiet then logger.dbg(line) else logger.info(line) end
end

--- Records the timings a subprocess sent back: { name = { ms, note } }.
function Timing.recordAll(timings, prefix)
    if type(timings) ~= "table" then return end
    local names = {}
    for name in pairs(timings) do table.insert(names, name) end
    table.sort(names)
    for _i, name in ipairs(names) do
        local t = timings[name]
        if type(t) == "table" then
            Timing.record((prefix or "") .. name, t.ms, t.note)
        end
    end
end

function Timing.reset()
    Timing.stats = {}
    Timing.started = os.time()
end

local function fmt(ms)
    if ms >= 10000 then return string.format("%.1f s", ms / 1000) end
    if ms >= 100 then return string.format("%.0f ms", ms) end
    return string.format("%.1f ms", ms)
end

--- Text for the Timings screen.
function Timing.text()
    local names = {}
    for name in pairs(Timing.stats) do table.insert(names, name) end
    if #names == 0 then
        return "No timings yet. Open your library folder, or sync."
    end
    table.sort(names)
    local lines = {}
    local group
    for _i, name in ipairs(names) do
        local s = Timing.stats[name]
        local g = name:match("^([^:]+):") or name
        if g ~= group then
            if group then table.insert(lines, "") end
            table.insert(lines, g:upper())
            group = g
        end
        local label = name:match("^[^:]+:%s*(.+)$") or name
        local line = string.format("%s: %s", label, fmt(s.last))
        if s.count > 1 then
            line = line .. string.format("  (avg %s, max %s, %d×)", fmt(s.total / s.count), fmt(s.max), s.count)
        end
        if s.note then line = line .. "\n    " .. s.note end
        table.insert(lines, line)
    end
    table.insert(lines, "")
    table.insert(lines, "Since " .. os.date("%H:%M", Timing.started) .. ". Also in crash.log (\"CloudLibrary timing\").")
    return table.concat(lines, "\n")
end

--- Collects timings in a subprocess, to send back with its result.
function Timing.collector()
    local c = { timings = {} }
    function c.add(name, ms, note)
        local t = c.timings[name]
        if t then
            t.ms = t.ms + ms
            t.note = note or t.note
        else
            c.timings[name] = { ms = ms, note = note }
        end
    end
    function c.measure(name, fn, ...)
        local t0 = clock()
        local results = { fn(...) }
        c.add(name, clock() - t0)
        return unpack(results)
    end
    return c
end

return Timing
