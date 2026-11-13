-- Exercises knuthplass.koplugin against stubbed KOReader modules.

-- KOReader puts the plugin's folder on package.path while loading it.
package.path = "knuthplass.koplugin/?.lua;" .. package.path

local function stub(name, value)
    package.loaded[name] = value
end

local registered_actions = {}
stub("dispatcher", {
    registerAction = function(_, name, value)
        registered_actions[name] = value
    end,
})
stub("ui/event", {
    new = function(_, name, ...)
        return { name = name, args = { ... } }
    end,
})
local notifications = {}
stub("ui/widget/notification", {
    notify = function(_, text)
        table.insert(notifications, text)
    end,
})
local shown = {}
local scheduled = {}
stub("ui/uimanager", {
    show = function(_, widget) table.insert(shown, widget) end,
    setDirty = function() end,
    scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end,
    nextTick = function(_, fn) fn() end,
})
stub("ffi/blitbuffer", { COLOR_LIGHT_GRAY = "lightgray" })
local ButtonDialog = {}
function ButtonDialog:extend(o)
    return setmetatable(o or {}, { __index = self })
end
function ButtonDialog:new(o)
    o.reinits = 0
    return setmetatable(o, { __index = self })
end
function ButtonDialog:reinit() self.reinits = self.reinits + 1 end
function ButtonDialog:getAddedWidgetAvailableWidth() return 500 end
function ButtonDialog:addWidget(widget) self.added = widget end
function ButtonDialog:onClose()
    if self.tap_close_callback then self.tap_close_callback() end
    self.closed = true
end
stub("device", { screen = { getWidth = function() return 1000 end } })
stub("ui/size", { padding = { large = 10 } })
stub("ui/widget/titlebar", { new = function(_, o) return o end })
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
stub("ui/widget/textwidget", {
    new = function(_, o)
        return setmetatable(o, { __index = {
            getSize = function(self) return { w = 10, h = self.face.size + 6 } end,
            isTruncated = function() return false end,
            free = function() end,
        } })
    end,
})
function ButtonDialog:getScrolledOffset() return "offset" end
function ButtonDialog:setScrolledOffset(offset) self.offset = offset end
stub("ui/widget/buttondialog", ButtonDialog)
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("logger", { info = function() end, dbg = function() end, warn = function() end })
-- The engine module's files: a folder with no libs/libkoreader-cre.so.stock.
local test_dir = os.getenv("TMPDIR") or "/tmp"
stub("libs/libkoreader-lfs", { currentdir = function() return test_dir end })
local koreader_rev = "v2026.07.2-299-g8012773_2026-10-30"
stub("version", { getCurrentRevision = function() return koreader_rev end })
stub("datastorage", {
    getDataDir = function() return test_dir end,
    getPatchesDir = function() return test_dir .. "/patches" end,
})
stub("userpatch", { arePatchesDisabled = function() return false end })
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
    -- A "child process" that runs at once, here, writing to a table.
    runInSubProcess = function(func)
        local pipe = {}
        func(1, pipe)
        return 1, pipe
    end,
    writeToFD = function(pipe, data) table.insert(pipe, data) end,
    isSubProcessDone = function() return true end,
    readAllFromFD = function(pipe) return table.concat(pipe) end,
    usleep = function() end,
    terminateSubProcess = function() end,
})

local function deepcopy(o)
    if type(o) ~= "table" then return o end
    local c = {}
    for k, v in pairs(o) do c[k] = deepcopy(v) end
    return c
end
local function equals(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equals(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
stub("util", {
    makePath = function(path) return os.execute("mkdir -p '" .. path .. "'") end,
    tableDeepCopy = deepcopy,
    tableEquals = equals,
    arrayContains = function(t, v)
        for i, x in ipairs(t) do if x == v then return i end end
        return false
    end,
})
local gettext = setmetatable({ pgettext = function(_, s) return s end }, {
    __call = function(_, s) return s end,
})
stub("gettext", gettext)

local WidgetContainer = {}
function WidgetContainer:extend(o)
    o = o or {}
    setmetatable(o, { __index = self })
    return o
end
function WidgetContainer:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)

local function settings(values)
    local store = values or {}
    return {
        store = store,
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
        delSetting = function(_, key) store[key] = nil end,
    }
end

-- probe: what the engine returns for the Knuth–Plass capability property;
-- ragged: whether it also has the ragged text properties.
local function makeUI(probe, ragged)
    local cre = { props = {} }
    function cre:getStringProperty(name)
        if name == "crengine.style.justify.tolerance" then
            return probe
        end
        if ragged and name == "crengine.style.ragged.width.percent" then
            return "15"
        end
        return ""
    end
    function cre:setIntProperty(name, value)
        assert(type(value) == "number", name)
        self.props[name] = value
    end
    local events = {}
    local menu_registered = false
    local ui = {
        rolling = {},
        document = { _document = cre, configurable = {} },
        doc_settings = settings(),
        menu = { registerToMainMenu = function() menu_registered = true end },
        handleEvent = function(_, event) table.insert(events, event.name) end,
    }
    return ui, cre, events, function() return menu_registered end
end

local Plugin = dofile("knuthplass.koplugin/main.lua")

-- Stock engine: inactive, nothing applied, events ignored.
G_reader_settings = settings()
do
    local ui, cre = makeUI("")
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active == false)
    assert(next(cre.props) == nil)
    assert(plugin:onSetLineBreakingMode(1) == nil)
    assert(next(cre.props) == nil)
end

-- Knuth engine: defaults applied before rendering.
do
    local ui, cre, _, menu_registered = makeUI("200")
    local plugin = Plugin:new{ ui = ui }
    assert(menu_registered())
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active)
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(cre.props["crengine.style.justify.space.shrink.percent"] == 25)
    assert(cre.props["crengine.style.justify.space.stretch.percent"] == 35)
    assert(cre.props["crengine.style.justify.hyphen.penalty"] == 3000)
    assert(cre.props["crengine.style.justify.explicit.hyphen.penalty"] == 3000)
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 36000000)
    assert(cre.props["crengine.style.justify.final.hyphen.demerits"] == 18000000)
    assert(cre.props["crengine.style.justify.tracking.delta.max.bp"] == 50)
    -- Page-level and kerning settings belong to other builds.
    assert(cre.props["crengine.style.justify.refinement.passes"] == nil)
    assert(cre.props["crengine.page.center.nearly.full"] == nil)
    assert(cre.props["font.fractional.positioning"] == nil)
    -- Every engine property the plugin owns.
    local count = 0
    for _ in pairs(cre.props) do count = count + 1 end
    assert(count == 16, count)
    assert(equals(ui.document.configurable.justification_tolerance, { 100, 200 }))
end

-- Per-book values beat global defaults; invalid values fall back.
G_reader_settings = settings{
    copt_justification_tolerance = { 50, 100 },
    copt_line_breaking_mode = 0,
}
do
    local ui, cre = makeUI("200")
    ui.doc_settings = settings{
        copt_line_breaking_mode = 1,
        copt_justification_hyphen_penalty = { 500, 300 },
        copt_justification_word_spacing = "garbage",
    }
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(cre.props["crengine.style.justify.pretolerance"] == 50)
    assert(cre.props["crengine.style.justify.hyphen.penalty"] == 500)
    assert(cre.props["crengine.style.justify.explicit.hyphen.penalty"] == 300)
    assert(cre.props["crengine.style.justify.space.shrink.percent"] == 25)
end

-- Changing a setting stores it with the book, applies it, and re-renders.
G_reader_settings = settings()
do
    local ui, cre, events = makeUI("200")
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    -- (The strong preset needs an engine whose cap is 1000000000.)
    assert(plugin:onSetJustificationHyphenDemerits({ 400000000, 200000000 }))
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 400000000)
    assert(plugin:onSetJustificationHyphenDemerits({ 10000, 5000 }))
    assert(cre.props["crengine.style.justify.double.hyphen.demerits"] == 10000)
    assert(cre.props["crengine.style.justify.final.hyphen.demerits"] == 5000)
    assert(equals(ui.doc_settings.store.copt_justification_hyphen_demerits, { 10000, 5000 }))
    assert(events[#events] == "UpdatePos")
    assert(plugin:onSetJustificationWordSpacing({ 40, 75 }))
    assert(cre.props["crengine.style.justify.space.stretch.percent"] == 75)
    assert(plugin:onSetLineBreakingMode("bad") == nil)
    assert(plugin:onSetLineBreakingMode(0))
    assert(cre.props["crengine.style.line.breaking.mode"] == 0)
    assert(#notifications > 0)

    -- Set as default goes to the global settings only.
    plugin:makeDefault("justification_hyphen_penalty", { 50, 50 })
    assert(equals(G_reader_settings.store.copt_justification_hyphen_penalty, { 50, 50 }))
    assert(ui.doc_settings.store.copt_justification_hyphen_penalty == nil)

    -- The menu entry opens the dialog.
    local items = {}
    plugin:addToMainMenu(items)
    local entry = items.knuth_plass
    assert(entry.text_func() == "Line breaking: greedy")
    assert(entry.sub_item_table_func == nil)
    entry.callback()
    local dialog = shown[#shown]
    assert(dialog == plugin.dialog)

    -- One row per setting, as in the bottom menu: its name in a left
    -- column, then its presets (and "…"). findRow returns the presets.
    local function findRow(buttons, heading)
        for _, row in ipairs(buttons) do
            if row[1].text == heading then
                return { select(2, unpack(row)) }
            end
        end
    end
    assert(#dialog.buttons == 13, #dialog.buttons)
    assert(dialog.width_factor == 0.95)
    -- Every button of a setting row has the same height (one line of a
    -- name) and its own id; names share one column width, without a
    -- separator before the presets.
    local ids = {}
    for i = 1, 9 do
        local name = dialog.buttons[i][1]
        assert(name.setting_name and name.width == 237 and name.no_vertical_sep, i)
        for _, button in ipairs(dialog.buttons[i]) do
            assert(button.id and not ids[button.id], button.id)
            ids[button.id] = true
            assert(button.height == 20 + 6)
            assert(button.numbers == nil and not button.two_line)
        end
    end
    for i, row in ipairs(dialog.buttons) do
        for _, button in ipairs(row) do
            assert(type(button.text) == "string" and button.callback, i)
        end
    end
    -- In greedy mode only the mode row is enabled.
    assert(findRow(dialog.buttons, "Line breaking")[2].enabled == true)
    assert(findRow(dialog.buttons, "Fit tolerance")[1].enabled == false)
    -- (Names of disabled settings are grayed but still open their help.)
    assert(dialog.buttons[2][1].text == "Word-space limits" and dialog.buttons[2][1].dimmed)
    assert(not dialog.buttons[1][1].dimmed)
    -- The current preset is highlighted.
    local mode_row = findRow(dialog.buttons, "Line breaking")
    assert(mode_row[1].background and not mode_row[2].background)
    local ws = findRow(dialog.buttons, "Word-space limits") -- {40, 75} is the "loose" preset
    assert(ws[3].background and not ws[#ws].background)

    -- Tapping a preset applies it and refreshes the dialog in place.
    local count = #notifications
    mode_row[2].callback()
    assert(cre.props["crengine.style.line.breaking.mode"] == 1)
    assert(#notifications == count) -- the dialog shows the change itself
    assert(dialog.reinits == 1 and dialog.offset == "offset")
    assert(findRow(dialog.buttons, "Fit tolerance")[1].enabled == true)
    assert(findRow(dialog.buttons, "Line breaking")[2].background)
    assert(entry.text_func() == "Line breaking: Knuth–Plass")

    plugin:setValue("justification_tolerance", { 70, 300 }, true)
    local tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(tol_row and tol_row[#tol_row].text == "…" and tol_row[#tol_row].background)

    -- Each preset shows just its name, the default marked with a star.
    local function texts(row)
        local t = {}
        for i, button in ipairs(row) do
            t[i] = button.text
        end
        return table.concat(t, "|")
    end
    assert(texts(findRow(dialog.buttons, "Line breaking")) == "greedy|Knuth–Plass ★")
    assert(texts(tol_row) == "strict|balanced ★|forgiving|…", texts(tol_row))
    assert(texts(findRow(dialog.buttons, "Word-space limits"))
        == "tight ★|balanced|loose|…")
    -- A custom default marks "…".
    local hyph_row = findRow(dialog.buttons, "Hyphen penalties")
    assert(hyph_row and texts(hyph_row) == "free|light|moderate|strong|… ★", texts(hyph_row))
    assert(texts(findRow(dialog.buttons, "Repeated-hyphen penalties"))
        == "free|light|moderate ★|strong|…")
    assert(texts(findRow(dialog.buttons, "Letter-space smoothness"))
        == "off|strict|smooth ★|relaxed|…")
    assert(texts(findRow(dialog.buttons, "Letter-space limits"))
        == "off|fallback ★|…")

    -- Long-press makes a preset the default and refreshes the dialog.
    local reinits = dialog.reinits
    tol_row[1].hold_callback()
    assert(equals(G_reader_settings.store.copt_justification_tolerance, { 50, 100 }))
    assert(dialog.reinits == reinits + 1)
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict ★|balanced|forgiving|…", texts(tol_row))
    -- Long-press on "…" makes the current custom value the default.
    tol_row[#tol_row].hold_callback()
    assert(equals(G_reader_settings.store.copt_justification_tolerance, { 70, 300 }))
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict|balanced|forgiving|… ★", texts(tol_row))
    -- "…" has no long-press when the current value is a preset.
    assert(findRow(dialog.buttons, "Line breaking")[1].hold_callback ~= nil)
    local ws_row = findRow(dialog.buttons, "Word-space limits")
    assert(ws_row[#ws_row].hold_callback == nil)

    -- Long-press on a name restores the built-in default.
    for _, row in ipairs(dialog.buttons) do
        if row[1].text == "Fit tolerance" then row[1].hold_callback() break end
    end
    assert(G_reader_settings.store.copt_justification_tolerance == nil)
    tol_row = findRow(dialog.buttons, "Fit tolerance")
    assert(texts(tol_row) == "strict|balanced ★|forgiving|…", texts(tol_row))

    -- "Reset all defaults" asks first, then clears every default.
    local reset = dialog.buttons[#dialog.buttons][1]
    assert(reset.text == "Reset all defaults" and reset.enabled)
    reset.callback()
    local confirm = shown[#shown]
    assert(confirm.ok_callback)
    assert(G_reader_settings.store.copt_justification_hyphen_penalty ~= nil)
    confirm.ok_callback()
    assert(next(G_reader_settings.store) == nil)
    assert(findRow(dialog.buttons, "Hyphen penalties") ~= nil)
    assert(dialog.buttons[#dialog.buttons][1].enabled == false)

    -- The title bar has a ✕ that closes the dialog.
    local title_bar = dialog.added
    assert(title_bar.title == "Knuth–Plass justification" and title_bar.width == 500)
    assert(title_bar.parent == dialog)
    title_bar.close_callback()
    assert(dialog.closed and plugin.dialog == nil)
    assert(plugin:onShowKnuthPlassDialog())
    assert(plugin.dialog and shown[#shown] == plugin.dialog)

    -- Profiles: captured settings are appended to the stock list.
    ui.profiles = {
        ui = ui,
        getProfileFromCurrentBookSettings = function(_, name)
            return { settings = { name = name, order = { "font_size" } }, font_size = 22 }
        end,
    }
    plugin:onReaderReady()
    local profile = ui.profiles:getProfileFromCurrentBookSettings("test")
    assert(profile.font_size == 22)
    assert(profile.line_breaking_mode == 1)
    assert(equals(profile.justification_word_spacing, { 40, 75 }))
    assert(equals(profile.justification_hyphen_demerits, { 10000, 5000 }))
    -- Hooking twice must not wrap twice.
    plugin:onReaderReady()
    assert(#ui.profiles:getProfileFromCurrentBookSettings("again").settings.order == #profile.settings.order)
end

-- Every setting is a Dispatcher action whose event the plugin handles.
local action_count = 0
for name, action in pairs(registered_actions) do
    action_count = action_count + 1
    assert(type(Plugin["on" .. action.event]) == "function", name)
    assert(action.rolling, name)
    if name == "knuth_plass_dialog" then
        assert(action.category == "none")
    else
        assert(action.category == "string", name)
        assert(#action.args == #action.toggle, name)
        if name == "justification_hyphen_penalty" then
            assert(action.toggle[1] == "free" and action.toggle[3] == "moderate (3k/3k)", action.toggle[3])
        end
    end
end
assert(action_count == 11, action_count)

-- Ragged text: only offered by engines that have it.
G_reader_settings = settings()
do
    -- A Knuth engine without it (above, too): not applied, not shown.
    local ui, cre = makeUI("200", false)
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    assert(plugin.active)
    assert(cre.props["crengine.style.ragged.width.percent"] == nil)
    assert(plugin:onSetRaggedText({ 10, 100 }) == nil)
    assert(cre.props["crengine.style.ragged.width.percent"] == nil)
    assert(ui.doc_settings.store.copt_ragged_text == nil)
    assert(ui.document.configurable.ragged_text == nil)
    for _, row in ipairs(plugin:getDialogButtons()) do
        assert(not row[1].text:find("Ragged text", 1, true), row[1].text)
    end
end
do
    local ui, cre = makeUI("200", true)
    ui.doc_settings = settings{ copt_ragged_text = { 12, 300 } }
    local plugin = Plugin:new{ ui = ui }
    plugin:onReadSettings(ui.doc_settings)
    -- Every engine property the plugin owns, now with ragged text.
    local count = 0
    for _ in pairs(cre.props) do count = count + 1 end
    assert(count == 18, count)
    assert(cre.props["crengine.style.ragged.width.percent"] == 12)
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 300)
    -- Its row comes last among the settings, with "…" selected.
    local buttons = plugin:getDialogButtons()
    assert(#buttons == 14, #buttons)
    assert(buttons[10][1].text == "Ragged text", buttons[10][1].text)
    local labels = {}
    for i, button in ipairs(buttons[10]) do labels[i] = button.text end
    assert(table.concat(labels, "|") == "Ragged text|greedy|even|balanced ★|fewer hyphens|…",
        table.concat(labels, "|"))
    assert(buttons[10][#buttons[10]].background) -- {12, 300} is custom
    -- Presets apply both properties and are saved with the book.
    buttons[10][2].callback()
    assert(cre.props["crengine.style.ragged.width.percent"] == 0)
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 100)
    assert(equals(ui.doc_settings.store.copt_ragged_text, { 0, 100 }))
    assert(plugin:onSetRaggedText({ 15, 200 }))
    assert(cre.props["crengine.style.ragged.hyphen.penalty"] == 200)
    assert(notifications[#notifications] == "Ragged text: fewer hyphens (15%/200)", notifications[#notifications])
    -- Profiles capture it.
    ui.profiles = {
        ui = ui,
        getProfileFromCurrentBookSettings = function(_, name)
            return { settings = { name = name, order = {} } }
        end,
    }
    plugin:onReaderReady()
    local profile = ui.profiles:getProfileFromCurrentBookSettings("ragged")
    assert(equals(profile.ragged_text, { 15, 200 }))
end

do
    -- The release workflow and the updater read the version from _meta.lua.
    stub("gettext", function(s) return s end)
    local meta = dofile("knuthplass.koplugin/_meta.lua")
    assert(type(meta.version) == "string" and meta.version:match("^%d+%.%d+%.%d+$"), tostring(meta.version))
end

-- Updater: versions, zip paths, the dialog row and the automatic check.
do
    local Updater = require("knuthplass_updater")
    assert(Updater.parseVersion("v1.2.3")[3] == 3)
    assert(Updater.parseVersion("1.2") == nil and Updater.parseVersion(nil) == nil)
    assert(Updater.isNewer("0.10.0", "0.9.9"))
    assert(Updater.isNewer("v1.0.0", "0.9.9"))
    assert(not Updater.isNewer("0.1.0", "0.1.0"))
    assert(not Updater.isNewer("0.1.0", "0.2.0"))
    assert(not Updater.isNewer("junk", "0.1.0"))

    assert(Updater.entryPath("knuthplass.koplugin/main.lua") == "main.lua")
    assert(Updater.entryPath("knuthplass.koplugin/sub/x.lua") == "sub/x.lua")
    assert(Updater.entryPath("knuthplass.koplugin/") == nil)
    assert(Updater.entryPath("main.lua") == nil)
    assert(Updater.entryPath("knuthplass.koplugin/../evil.lua") == nil)
    assert(Updater.entryPath("knuthplass.koplugin/a/../../evil.lua") == nil)

    G_reader_settings = settings()
    assert(Updater.getMode() == "notify")
    Updater.setMode("bogus")
    assert(Updater.getMode() == "notify")

    -- The dialog row cycles the mode.
    local ui = makeUI("200")
    local plugin = Plugin:new{ ui = ui, version = "0.1.0", path = "/plugins/knuthplass.koplugin" }
    plugin:onReadSettings(ui.doc_settings)
    plugin:showDialog()
    local rows = plugin.dialog.buttons
    local row = rows[#rows - 2]
    assert(row[1].text == "Check for updates (0.1.0)", row[1].text)
    assert(row[2].text == "Automatic updates: notify", row[2].text)
    row[2].callback()
    assert(Updater.getMode() == "install")
    rows = plugin.dialog.buttons
    assert(rows[#rows - 2][2].text == "Automatic updates: install", rows[#rows - 2][2].text)
    rows[#rows - 2][2].callback()
    assert(Updater.getMode() == "off")

    -- Opening a book schedules one automatic check per session; with
    -- automatic updates off it returns without touching the network.
    scheduled = {}
    Updater.scheduled = nil
    plugin:onReaderReady()
    plugin:onReaderReady()
    assert(#scheduled == 1, #scheduled)
    scheduled[1].fn()
    assert(G_reader_settings.store.knuthplass_updates.last_check == nil)
end

-- Engine: versions, manifest lookup, install, the start-up guard and rollback.
do
    local Engine = require("knuthplass_engine")
    assert(Engine.koreaderRef("v2026.07.2-299-g8012773_2026-10-30") == "8012773")
    assert(Engine.koreaderRef("v2026.07.2-270-g426e93297_2026-10-20_emulator") == "426e93297")
    assert(Engine.koreaderRef("v2026.07.1") == "v2026.07.1")
    assert(Engine.koreaderRef(nil) == nil and Engine.koreaderRef("junk") == nil)

    local sha = string.rep("a", 64)
    local function entry(commit, built, url)
        return { kobo = { url = url or "https://x/lib.so", sha256 = sha, commit = commit, built = built,
                          file = "lib-" .. commit .. ".so" } }
    end
    local manifest = {
        schema = 2,
        builds = { fpA = entry("abc", "2026-10-01T00:00:00Z"), fpB = entry("def", "2026-10-20T00:00:00Z") },
        bases = { base1 = "fpA", base2 = "fpB" },
    }
    -- The build for this koreader-base…
    local b, exact = Engine.findBuild(manifest, "base1", "kobo")
    assert(b.commit == "abc" and exact == true)
    -- …or else the newest.
    b, exact = Engine.findBuild(manifest, "base9", "kobo")
    assert(b.commit == "def" and exact == false)
    assert(Engine.findBuild(manifest, "base1", "kobov5") == nil)
    -- Not https, or the old manifest format: nothing.
    assert(Engine.findBuild({ schema = 2, builds = { fpA = entry("abc", "x", "http://x") }, bases = { base1 = "fpA" } }, "base1", "kobo") == nil)
    assert(Engine.findBuild({ builds = { base1 = entry("abc") } }, "base1", "kobo") == nil)
    assert(Engine.buildId(manifest.builds.fpA.kobo) == "abc/lib-abc.so")

    -- The running engine's build comes from a new view, not the open book
    -- (whose properties KOReader's saved defaults, data/cr3.ini, may have
    -- set to an earlier engine's).
    do
        local saved = package.loaded["document/credocument"]
        local closed = false
        local view = {
            getStringProperty = function(_, name)
                if name == "crengine.knuth.plass.build" then return "newbuild" end
                if name == "crengine.style.justify.tolerance" then return "200" end
                return ""
            end,
            close = function() closed = true end,
        }
        package.loaded["document/credocument"] = {
            engineInit = function() return { newDocView = function() return view end } end,
        }
        local build, supported = Engine.runningEngine()
        assert(build == "newbuild" and supported == true and closed)
        assert(Engine.installedBuild() == "newbuild")
        -- No engine to read: unknown.
        package.loaded["document/credocument"] = {
            engineInit = function() error("no engine") end,
        }
        assert(Engine.runningEngine() == nil and Engine.installedBuild() == nil)
        package.loaded["document/credocument"] = saved
    end

    -- A KOReader folder of our own, with KOReader's engine.
    local Loader = require("knuthplass_loader")
    local dir = os.tmpname()
    os.remove(dir)
    assert(os.execute("mkdir -p '" .. dir .. "/libs'"))
    test_dir = dir
    local plugin_path = "knuthplass.koplugin"
    local standard = dir .. "/libs/libkoreader-cre.so"
    local lib = dir .. "/knuthplass/libkoreader-cre.so"
    local patch = dir .. "/patches/1-knuthplass-engine.lua"
    local function read(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local d = f:read("*a"); f:close(); return d
    end
    local function write(path, d) local f = assert(io.open(path, "wb")); f:write(d); f:close() end
    write(standard, "\127ELF standard")
    -- Checksums: the builds below hash to their own names.
    stub("ffi/sha2", { sha256 = function(d) return (d:match("^\127ELF (%w+)") or "x"):rep(64):sub(1, 64) end })
    local function build(name)
        local data = "\127ELF " .. name
        return { commit = name, url = "https://x", sha256 = name:rep(64):sub(1, 64), size = #data,
                 file = "lib-" .. name .. ".so" }, data
    end
    -- Loading libraries: the Knuth–Plass engine fails to load when it's
    -- "bad"; KOReader's comes from its usual loaders.
    local real_loadlib = package.loadlib
    -- Like luaopen_cre: a module, and methods in registry metatables.
    -- KOReader's own engine has cre.newDocView, cre.getVersion,
    -- credocument:getStringProperty and credocument:close (and, when
    -- standard_highlight is set, a crehighlight metatable). A "lacking"
    -- engine lacks cre.getVersion, a "nomethod" one credocument:close; an
    -- "explode" one raises an error as it loads.
    local standard_broken = false
    local standard_highlight = false
    package.loadlib = function(path)
        local data = read(path) or ""
        if data:find("bad", 1, true) then return nil, "undefined symbol: FT_Bad" end
        if data:find("explode", 1, true) then error("boom") end
        if standard_broken and path == standard then return nil, "cannot open" end
        return function()
            local registry = debug.getregistry()
            registry.credocument = registry.credocument or {}
            registry.credocument.__index = registry.credocument
            registry.credocument.getStringProperty = function() end
            registry.credocument.close = not data:find("nomethod", 1, true) and function() end or nil
            if path == standard and standard_highlight then
                registry.crehighlight = { get = function() end }
            end
            return { engine = data, newDocView = function() end,
                     getVersion = not data:find("lacking", 1, true) and function() end or nil }
        end
    end
    local function standardLoader(name)
        if name == "libs/libkoreader-cre" then
            return function() return { engine = "standard" } end
        end
    end
    table.insert(package.loaders, standardLoader)
    -- A KOReader start: the early patch runs, then something loads the engine.
    local function start()
        package.loaded["libs/libkoreader-cre"] = nil
        package.preload["libs/libkoreader-cre"] = nil
        if read(patch) then dofile(patch) end
        return require("libs/libkoreader-cre").engine
    end

    G_reader_settings = settings{ start_with = "last" }
    G_reader_settings.flush = function() end
    Engine.setUp(plugin_path)

    -- Damaged downloads are refused.
    local b, data = build("good")
    assert(not Engine.install(b, data .. "x", plugin_path))
    assert(not Engine.install(b, "\127ELF other", plugin_path))
    assert(not read(lib) and not read(patch))

    -- Installing puts the engine and the patch in place, and nothing else.
    assert(Engine.install(b, data, plugin_path))
    assert(read(lib) == data and read(standard) == "\127ELF standard")
    assert(read(patch) == Engine.patchSource(plugin_path))
    local state = Loader.readState()
    assert(state.enabled and state.pending and state.commit == "good" and state.rev == koreader_rev)
    assert(Engine.hasStock() and G_reader_settings.store.start_with == "last")
    -- The next start loads it; a book opening with it settles it.
    assert(start() == data)
    assert(Loader.readState().attempts == 1)
    Engine.verify("other") -- not this build
    assert(Loader.readState().pending)
    Engine.verify("good")
    state = Loader.readState()
    assert(state.pending == nil and state.enabled)
    -- It stays, with no more counting.
    for _i = 1, 3 do assert(start() == data) end
    assert(Loader.readState().attempts == nil)

    -- An engine that fails to load, with no previous engine to go back to
    -- (see below): KOReader's own, at once and from then on.
    assert(Engine.restoreStock())
    b, data = build("bad")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == "standard")
    state = Loader.readState()
    assert(not state.enabled and state.failed:find("FT_Bad", 1, true))
    local rolled_back = Engine.takeRollback()
    assert(rolled_back.commit == "bad" and rolled_back.reason:find("FT_Bad", 1, true))
    assert(Engine.getState().bad["bad/lib-bad.so@" .. koreader_rev])
    assert(Engine.takeRollback() == nil)
    assert(start() == "standard")
    assert(not Engine.hasStock())

    -- KOReader stopping twice before a book opened with it: KOReader's own.
    b, data = build("crashy")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data and start() == data)
    assert(start() == "standard")
    assert(Engine.takeRollback().reason:find("stopped", 1, true))

    -- After a KOReader update, it's checked again at start-up and, as it
    -- still fits, kept: proven again once a book opens with it.
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("good")
    local old_rev = koreader_rev
    koreader_rev = "v2026.08.1-12-gabcdef1_2026-11-20"
    assert(start() == data)
    state = Loader.readState()
    assert(state.rev == koreader_rev and state.previous_rev == old_rev)
    assert(state.pending and state.attempts == 1)
    Engine.verify("good")
    assert(not Loader.readState().pending)
    assert(start() == data) -- no more checking for this version

    -- One that lacks a function KOReader's own engine has: KOReader's own,
    -- and it isn't offered again for this version.
    assert(Engine.restoreStock())
    b, data = build("lacking")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("lacking")
    koreader_rev = "v2026.09.1-30-g1234567_2026-12-20"
    assert(start() == "standard")
    rolled_back = Engine.takeRollback()
    assert(rolled_back.reason:find("cre.getVersion", 1, true), rolled_back.reason)
    assert(Engine.getState().bad["lacking/lib-lacking.so@" .. koreader_rev])
    assert(start() == "standard")

    -- When KOReader's own engine can't be checked: KOReader's own for now,
    -- without turning it off or trying again for this version; the plugin's
    -- check can put it back (with the library already here).
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("good")
    koreader_rev = "v2026.10.1-5-g7654321_2027-01-20"
    standard_broken = true
    assert(start() == "standard")
    state = Loader.readState()
    assert(state.enabled and state.unchecked_rev == koreader_rev and not state.failed)
    standard_broken = false
    assert(start() == "standard")
    assert(Engine.existingLibrary(b) == data)
    assert(Engine.existingLibrary(build("other")) == nil)
    assert(Engine.install(b, Engine.existingLibrary(b), plugin_path))
    assert(Loader.readState().unchecked_rev == nil)
    assert(start() == data)

    -- Restoring KOReader's engine removes ours.
    assert(Engine.restoreStock())
    assert(not read(lib) and not read(patch) and not Engine.hasStock())
    assert(start() == "standard")

    -- Too late to redirect once the engine is loaded.
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    package.preload["libs/libkoreader-cre"] = nil
    package.loaded["libs/libkoreader-cre"] = { engine = "standard" }
    assert(not Loader.apply())

    -- The plugin keeps the patch current.
    write(patch, "-- old")
    Engine.setUp(plugin_path)
    assert(read(patch) == Engine.patchSource(plugin_path))
    os.remove(patch)
    Engine.setUp(plugin_path)
    assert(read(patch))

    -- Moving an engine installed over KOReader's (earlier versions)…
    assert(Engine.restoreStock())
    write(standard, "\127ELF old")
    write(standard .. ".stock", "\127ELF standard")
    G_reader_settings = settings{ start_with = "filemanager",
        knuthplass_engine = { stock_rev = koreader_rev,
            pending = { commit = "old", id = "old/lib-old.so", start_with = { value = "last" } } } }
    G_reader_settings.flush = function() end
    Engine.migrate(plugin_path)
    assert(read(standard) == "\127ELF standard" and not read(standard .. ".stock"))
    assert(read(lib) == "\127ELF old" and read(patch))
    state = Loader.readState()
    assert(state.enabled and state.commit == "old" and state.pending and state.rev == koreader_rev)
    assert(G_reader_settings.store.start_with == "last")
    assert(G_reader_settings.store.knuthplass_engine.stock_rev == nil)
    assert(start() == "\127ELF old")
    -- …or after a KOReader update replaced it: just tidy up.
    write(standard .. ".stock", "\127ELF older")
    G_reader_settings.store.knuthplass_engine = { stock_rev = "v2026.06.1" }
    Engine.migrate(plugin_path)
    assert(read(standard) == "\127ELF standard" and not read(standard .. ".stock"))
    assert(G_reader_settings.store.knuthplass_engine.stock_rev == nil)

    -- The comparison covers every table the engine registers: a missing
    -- document method, or a metatable only KOReader's own engine has.
    assert(Engine.restoreStock())
    local function updateWith(name)
        b, data = build(name)
        assert(Engine.install(b, data, plugin_path))
        assert(start() == data)
        Engine.verify(name)
        koreader_rev = koreader_rev .. "+"
        return start()
    end
    assert(updateWith("nomethod") == "standard")
    assert(Engine.takeRollback().reason:find("credocument:close", 1, true))
    standard_highlight = true
    assert(updateWith("good") == "standard")
    assert(Engine.takeRollback().reason:find("crehighlight:get", 1, true))
    standard_highlight = false
    assert(updateWith("good") == data) -- (and the same build passes otherwise)

    -- KOReader always gets an engine: an engine raising an error as it
    -- loads, or KOReader's loaders not finding its own, fall back to libs/.
    b, data = build("explode")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == "standard")
    assert(Engine.takeRollback().reason:find("boom", 1, true))
    b, data = build("bad")
    assert(Engine.install(b, data, plugin_path))
    for i, loader in ipairs(package.loaders) do
        if loader == standardLoader then table.remove(package.loaders, i) break end
    end
    assert(start() == "\127ELF standard") -- straight from libs/
    table.insert(package.loaders, standardLoader)
    assert(Engine.takeRollback())

    -- KOReader's child-process helpers changing doesn't stop KOReader: its
    -- own engine, checked again later, nothing turned off.
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("good")
    local ffiutil = package.loaded["ffi/util"]
    local runInSubProcess = ffiutil.runInSubProcess
    ffiutil.runInSubProcess = nil
    koreader_rev = koreader_rev .. "+"
    assert(start() == "standard")
    state = Loader.readState()
    assert(state.enabled and state.unchecked_rev == koreader_rev and not state.failed)
    ffiutil.runInSubProcess = runInSubProcess

    -- The last engine known to work is kept when a new one is installed…
    assert(Engine.restoreStock())
    local good_path = dir .. "/knuthplass/libkoreader-cre.good.so"
    b, data = build("good")
    local good_data = data
    assert(Engine.install(b, data, plugin_path))
    assert(not read(good_path)) -- (nothing before it)
    assert(start() == data)
    -- …once a book has opened with it.
    b, data = build("second")
    assert(Engine.install(b, data, plugin_path))
    assert(not read(good_path) and Engine.previous() == nil)
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("good")
    b, data = build("second")
    assert(Engine.install(b, data, plugin_path))
    assert(read(good_path) == good_data and read(lib) == data)
    assert(not read(good_path .. ".new"))
    assert(Engine.previous().commit == "good")
    -- An unproven one doesn't replace it.
    b, data = build("third")
    assert(Engine.install(b, data, plugin_path))
    assert(Engine.previous().commit == "good" and read(good_path) == good_data)
    -- Reinstalling the kept one doesn't keep it as its own backup.
    b, data = build("good")
    assert(Engine.install(b, data, plugin_path))
    assert(Engine.previous() == nil and not read(good_path))

    -- A new engine that fails to load: the previous one, at once.
    assert(start() == good_data)
    Engine.verify("good")
    b, data = build("bad")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == good_data)
    state = Loader.readState()
    assert(state.enabled and state.commit == "good" and not state.pending and state.good == nil)
    assert(read(lib) == good_data and not read(good_path))
    rolled_back = Engine.takeRollback()
    assert(rolled_back.commit == "bad" and rolled_back.fallback == "good")
    assert(rolled_back.reason:find("FT_Bad", 1, true))
    assert(Engine.getState().bad["bad/lib-bad.so@" .. koreader_rev])
    assert(not Engine.getState().bad["good/lib-good.so@" .. koreader_rev])
    assert(start() == good_data)

    -- KOReader stopping twice before a book opened with it: the previous one.
    b, data = build("crashy")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data and start() == data)
    assert(start() == good_data)
    rolled_back = Engine.takeRollback()
    assert(rolled_back.commit == "crashy" and rolled_back.fallback == "good")

    -- Failing the re-check after a KOReader update: the previous one, checked
    -- in turn.
    Engine.verify("good")
    b, data = build("lacking")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("lacking")
    koreader_rev = koreader_rev .. "+"
    assert(start() == good_data)
    state = Loader.readState()
    assert(state.commit == "good" and state.rev == koreader_rev and state.pending)
    rolled_back = Engine.takeRollback()
    assert(rolled_back.commit == "lacking" and rolled_back.fallback == "good")
    assert(rolled_back.reason:find("cre.getVersion", 1, true))
    Engine.verify("good")

    -- Rolling back by hand: the previous one from the next start, and the
    -- installed one not offered again.
    b, data = build("second")
    assert(Engine.install(b, data, plugin_path))
    assert(start() == data)
    Engine.verify("second")
    assert(Engine.previous().commit == "good")
    assert(Engine.rollBack())
    state = Loader.readState()
    assert(state.enabled and state.commit == "good" and not state.pending and state.good == nil)
    assert(read(lib) == good_data and not read(good_path))
    assert(Engine.getState().bad["second/lib-second.so@" .. koreader_rev])
    assert(start() == good_data)
    local ok, err = Engine.rollBack()
    assert(not ok and err)

    -- Restoring KOReader's engine removes the kept one too.
    b, data = build("second")
    assert(Engine.install(b, data, plugin_path))
    assert(read(good_path))
    assert(Engine.restoreStock())
    assert(not read(good_path) and not read(lib))

    -- The plugin's check before installing is the same comparison.
    assert(Engine.checkCompatible("\127ELF good"))
    ok, err = Engine.checkCompatible("\127ELF lacking")
    assert(not ok and err:find("cre.getVersion", 1, true), err)
    ok, err = Engine.checkCompatible("\127ELF bad")
    assert(not ok and err:find("FT_Bad", 1, true), err)
    standard_broken = true
    ok, err = Engine.checkCompatible("\127ELF good")
    assert(not ok and err:find("couldn't be checked", 1, true), err)
    standard_broken = false
    assert(not read(dir .. "/knuthplass/probe.so")) -- cleaned up
    debug.getregistry().credocument = nil
    debug.getregistry().crehighlight = nil

    package.loadlib = real_loadlib
    for i, loader in ipairs(package.loaders) do
        if loader == standardLoader then table.remove(package.loaders, i) break end
    end
    package.loaded["libs/libkoreader-cre"] = nil
    package.preload["libs/libkoreader-cre"] = nil
    koreader_rev = "v2026.07.2-299-g8012773_2026-10-30"

    -- An engine's functions: its module's, and what it changed in the
    -- registry (here, over a table another engine registered).
    local Loader = require("knuthplass_loader")
    local registry = { credocument = { close = function() end, keep = print, __index = true }, _LOADED = {} }
    local snapshot = Loader.registrySnapshot(registry)
    registry.credocument.close = function() end -- the new engine's
    registry.creimage = { scale = function() end }
    registry._LOADED.cre = { x = function() end }
    local api = Loader.creApi({ newDocView = function() end, version = 3 }, registry, snapshot)
    assert(api["cre.newDocView"] and api["credocument:close"] and api["creimage:scale"])
    assert(not api["cre.version"] and not api["credocument:keep"] and not api["credocument:__index"])
    assert(not api["_LOADED:cre"])

    os.execute("rm -rf '" .. dir .. "'")
end

-- The file browser: an entry under Tools for updates and the engine.
do
    local Updater = require("knuthplass_updater")
    G_reader_settings = settings()
    scheduled = {}
    Updater.scheduled = nil
    local registered = false
    local fm_ui = { menu = { registerToMainMenu = function() registered = true end } }
    local plugin = Plugin:new{ ui = fm_ui, version = "0.2.1", path = "/plugins/knuthplass.koplugin" }
    assert(registered)
    assert(#scheduled == 1) -- the automatic check
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    local entry = menu_items.knuth_plass
    assert(entry.sorting_hint == "tools" and entry.text == "Knuth–Plass justification")
    local items = entry.sub_item_table
    assert(items[1].text == "Check for updates (0.2.1)" and items[1].enabled_func())
    assert(items[2].text_func() == "Automatic updates: notify")
    local modes = items[2].sub_item_table
    assert(#modes == 3 and modes[2].checked_func() and not modes[3].checked_func())
    modes[3].callback()
    assert(items[2].text_func() == "Automatic updates: install" and modes[3].checked_func())
    assert(items[4].text_func() == "Roll back to previous engine" and not items[4].enabled_func())
    assert(items[5].text == "Restore standard engine" and not items[5].enabled_func())
    -- A PDF in the reader: no entry.
    registered = false
    Plugin:new{ ui = { document = {}, menu = { registerToMainMenu = function() registered = true end } } }
    assert(not registered)
end

-- Device types: KOReader's update target names; Linux packages by arch.
do
    local Engine = require("knuthplass_engine")
    local saved = package.loaded.device
    local function device(d) package.loaded.device = d end
    local yes, no = function() return true end, function() return false end
    device({ otaModel = function() return "kindlehf", "kotasync" end })
    assert(Engine.target() == "kindlehf")
    device({ otaModel = function() return "appimage-x86_64", "kotasync" end })
    assert(Engine.target() == "linux-x86_64")
    local arch = ({ x64 = "x86_64", arm64 = "aarch64", arm = "armhf" })[jit.arch]
    local expect = (jit.os == "Linux" and arch) and ("linux-" .. arch) or nil
    device({ otaModel = function() return nil end, isDesktop = yes, isEmulator = no, model = "Linux" })
    assert(Engine.target() == expect)
    device({ otaModel = function() return nil end, isDesktop = no, isEmulator = yes, model = "Emulator" })
    assert(Engine.target() == expect)
    device({ otaModel = function() return nil end, isDesktop = yes, isEmulator = no, model = "Flatpak" })
    assert(Engine.target() == nil)
    device({ otaModel = function() return nil end, isDesktop = no, isEmulator = no, model = "PocketBook" })
    assert(Engine.target() == nil)
    package.loaded.device = saved
end

-- Android: the engine in the app's private storage (not the data folder,
-- nor the launcher's own folder, which updates empty), and KOReader's own
-- in its monolibtic library.
do
    local Loader = require("knuthplass_loader")
    local native = os.tmpname()
    os.remove(native)
    assert(os.execute("mkdir -p '" .. native .. "'"))
    package.loaded.android = { dir = "/data/user/0/org.koreader.launcher/files", nativeLibraryDir = native }
    assert(Loader.dir() == "/data/user/0/org.koreader.launcher/knuthplass")
    assert(Loader.libPath() == "/data/user/0/org.koreader.launcher/knuthplass/libkoreader-cre.so")
    assert(Loader.standardLibPath() == native .. "/libkoreader-cre.so") -- (no monolibtic library)
    local f = assert(io.open(native .. "/libkoreader-monolibtic.so", "wb")); f:close()
    assert(Loader.standardLibPath() == native .. "/libkoreader-monolibtic.so")
    package.loaded.android = nil
    os.remove(native .. "/libkoreader-monolibtic.so")
    os.remove(native)
    assert(Loader.dir():sub(-11) == "/knuthplass" and not Loader.dir():find("org.koreader"))
end

print("plugin tests passed")
