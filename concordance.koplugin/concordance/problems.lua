--[[--
Problems the user should know about: something Concordance relies on in
KOReader or ZenOS is missing or failed (usually after an update), or a job
failed with an error. Callers log as before; Problems.report also

- keeps each problem (once per key per session) for Status, and
- shows a message, one for all the problems found in the same moment, and
  never twice for the same problem in a session.

Messages are shown only once Problems.enable() has run (KOReader's main
process, after start), never in a subprocess or in tests.
--]]

local Problems = {
    list = {},      -- key -> { text, detail, count, first, last }
    order = {},     -- keys, in the order first reported
    unshown = {},   -- keys not yet in a message
    enabled = false,
    scheduled = false,
}

local function tr(s)
    local ok, gettext = pcall(require, "gettext")
    return ok and gettext(s) or s
end

local function oneLine(s)
    s = tostring(s or "")
    s = s:gsub("\n.*", "")
    if #s > 200 then s = s:sub(1, 200) .. "…" end
    return s
end

local show

local function schedule()
    if not Problems.enabled or Problems.scheduled or #Problems.unshown == 0 then return end
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok then return end
    Problems.scheduled = true
    UIManager:nextTick(function()
        local sok, err = pcall(show)
        Problems.scheduled = false
        if not sok then
            local lok, logger = pcall(require, "logger")
            if lok then logger.warn("Concordance: showing a problem failed:", err) end
        end
    end)
end

--- From now on problems are shown (and any found before are, soon).
function Problems.enable()
    Problems.enabled = true
    schedule()
end
function Problems.disable() Problems.enabled = false end

--- Forgets everything (tests).
function Problems.reset()
    Problems.list, Problems.order, Problems.unshown = {}, {}, {}
    Problems.scheduled = false
end

function show()
    Problems.scheduled = false
    if not Problems.enabled or #Problems.unshown == 0 then return end
    local lines = {}
    for _, key in ipairs(Problems.unshown) do
        local p = Problems.list[key]
        if p then
            lines[#lines + 1] = "• " .. p.text .. (p.detail and (": " .. oneLine(p.detail)) or "")
        end
    end
    Problems.unshown = {}
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not (ok_ui and ok_im) then return end
    UIManager:show(InfoMessage:new{
        text = tr("Concordance ran into a problem, often caused by a KOReader or ZenOS update. Syncing goes on where it can.")
            .. "\n\n" .. table.concat(lines, "\n") .. "\n\n"
            .. tr("Details: Concordance → Status, and crash.log."),
    })
end

--- Records a problem and shows it (soon, once). key: stable for the
-- problem (the same problem again isn't shown again: a check and the code
-- that uses what it checks report under the same key, "check:<Module>.<name>");
-- text: what doesn't work, for the user; detail: the error or what changed
-- (optional); from_check: a start-up check's report, whose text never
-- replaces a report from the code (which says what stops working).
function Problems.report(key, text, detail, from_check)
    local now = os.time()
    local p = Problems.list[key]
    if p then
        p.count, p.last = p.count + 1, now
        if not from_check then
            if p.from_check then p.text, p.from_check = text, false end
            if detail ~= nil then p.detail = tostring(detail) end
        end
        return false
    end
    Problems.list[key] = { text = text, detail = detail ~= nil and tostring(detail) or nil,
                           count = 1, first = now, last = now, from_check = from_check == true }
    Problems.order[#Problems.order + 1] = key
    Problems.unshown[#Problems.unshown + 1] = key
    schedule()
    return true
end

--- Lines for the Status screen: { "text: detail (×n)", … }.
function Problems.statusLines()
    local out = {}
    for _, key in ipairs(Problems.order) do
        local p = Problems.list[key]
        out[#out + 1] = p.text .. (p.detail and (": " .. oneLine(p.detail)) or "")
            .. (p.count > 1 and (" (×" .. p.count .. ")") or "")
    end
    return out
end

--- Whether `key` was reported (tests).
function Problems.has(key) return Problems.list[key] ~= nil end

-- What Concordance relies on --------------------------------------------------------------

local function params(f)
    local ok, info = pcall(debug.getinfo, f, "u")
    if not ok or type(info) ~= "table" then return nil end
    return info.nparams, info.isvararg
end

--- Checks a loaded module (or table) for functions (name = minimum
-- parameter count including self, or true) and fields (name = Lua type).
-- Reports each one that's missing under key "check:<label>.<name>".
-- Returns the number of problems.
function Problems.requires(label, mod, functions, fields)
    local n = 0
    if type(mod) ~= "table" then
        Problems.report("check:" .. label, label .. " can't be loaded", tostring(mod), true)
        return 1
    end
    -- In name order, so reports (and Status) come out the same on every Lua.
    local function sorted(t)
        local names = {}
        for name in pairs(t or {}) do names[#names + 1] = name end
        table.sort(names)
        return names
    end
    for _, name in ipairs(sorted(functions)) do
        local min = functions[name]
        local f = mod[name]
        if type(f) ~= "function" then
            Problems.report("check:" .. label .. "." .. name, label .. "." .. name .. " is missing", nil, true)
            n = n + 1
        elseif type(min) == "number" then
            local np, vararg = params(f)
            if np and np < min and not vararg then
                Problems.report("check:" .. label .. "." .. name, label .. "." .. name .. " has changed",
                    string.format("takes %d parameters, expected %d", np, min), true)
                n = n + 1
            end
        end
    end
    for _, name in ipairs(sorted(fields)) do
        local want = fields[name]
        if type(mod[name]) ~= want then
            Problems.report("check:" .. label .. "." .. name, label .. "." .. name .. " is missing",
                "expected a " .. want .. ", found " .. type(mod[name]), true)
            n = n + 1
        end
    end
    return n
end

return Problems
