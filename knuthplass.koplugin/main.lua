--[[--
Settings for Knuth–Plass paragraph line breaking in CREngine.

Everything lives in this plugin so that stock KOReader files stay untouched:
the engine properties are set directly on the document, values are stored
per book as copt_<name>, defaults as copt_<name> in the global settings, and
each setting is a Dispatcher action so gestures and Profiles can use it.

The plugin only activates when the CREngine in use knows these properties.
With a stock engine it stays out of the way.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local T = require("ffi/util").template
-- Names of their own: plugins share package.loaded.
local Engine = require("knuthplass_engine")
local Updater = require("knuthplass_updater")

-- Runs as KOReader loads its plugins: moves an engine installed by earlier
-- versions (over KOReader's own) to the plugin's folder, keeps the early
-- patch that loads it current, and sets up loading it if the patch didn't.
-- (KOReader tells the plugin its path only after loading this file.)
do
    local source = debug.getinfo(1, "S").source
    local plugin_path = source:match("^@(.*)/[^/]+$")
    if plugin_path then
        local ok, err = pcall(Engine.migrate, plugin_path)
        if not ok then logger.warn("Knuth–Plass: engine migration:", err) end
        ok, err = pcall(Engine.setUp, plugin_path)
        if not ok then logger.warn("Knuth–Plass: engine setup:", err) end
    end
end

-- A Knuth-capable engine fills in a default for this property when a
-- document view is created; a stock engine returns an empty string.
local CAPABILITY_PROPERTY = "crengine.style.justify.tolerance"

local KnuthPlass = WidgetContainer:extend{
    name = "knuthplass",
    -- Also in the file browser, for updates (its settings need a book).
    is_doc_only = false,
}

local function knuthOnly(self)
    return self.values.line_breaking_mode == 1
end

local options = {
    {
        name = "line_breaking_mode",
        event = "SetLineBreakingMode",
        title = _("Line breaking"),
        default = 1,
        values = { 0, 1 },
        labels = { C_("Line breaking", "greedy"), C_("Line breaking", "Knuth–Plass") },
        -- (0 and 1 are just the engine's names for these)
        preset_numbers = function() return nil end,
        properties = { "crengine.style.line.breaking.mode" },
        info = _([[Choose how text is split into lines.

- greedy: KOReader's standard line-by-line strategy.
- Knuth–Plass: chooses the line breaks of each paragraph together: in justified text, so that word spacing is as even as possible across the whole paragraph; in left-aligned, right-aligned or centered text, so that the line lengths are as even as possible (see Ragged text).

Knuth–Plass falls back to greedy for paragraphs with floats, drop caps, bidirectional or CJK text.]]),
    },
    {
        name = "justification_word_spacing",
        event = "SetJustificationWordSpacing",
        title = _("Word-space limits"),
        default = { 25, 35 },
        values = { { 25, 35 }, { 33, 50 }, { 40, 75 } },
        labels = {
            C_("Justification spacing", "tight"),
            C_("Justification spacing", "balanced"),
            C_("Justification spacing", "loose"),
        },
        properties = {
            "crengine.style.justify.space.shrink.percent",
            "crengine.style.justify.space.stretch.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Max −"), left_min = 0, left_max = 100, left_step = 1, left_hold_step = 5,
        right_text = _("Max +"), right_min = 0, right_max = 200, right_step = 1, right_hold_step = 5,
        unit = "%", signed = true,
        info = _([[Maximum contraction and expansion of every adjustable word space, as percentages of its natural width. All spaces on one line receive the same width.]]),
    },
    {
        name = "justification_letter_spacing",
        event = "SetJustificationLetterSpacing",
        title = _("Letter-space limits"),
        default = { 1, 0 },
        values = { { 0, 0 }, { 1, 0 } },
        labels = {
            C_("Letter spacing", "off"),
            C_("Letter spacing", "fallback"),
        },
        properties = {
            "crengine.style.justify.tracking.shrink.percent",
            "crengine.style.justify.tracking.stretch.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Max −"), left_min = 0, left_max = 20, left_step = 1, left_hold_step = 2,
        right_text = _("Max +"), right_min = 0, right_max = 0, right_step = 1, right_hold_step = 2,
        unit = "%", signed = true,
        info = _([[Maximum negative letter spacing, used when a line cannot fit after word spaces reach their minimum, and for the tiny overshoot from rounding equal word spaces upward. Letters are never expanded.

Only used with best kerning (HarfBuzz).]]),
    },
    {
        name = "justification_tracking_smoothness",
        event = "SetJustificationTrackingSmoothness",
        title = _("Letter-space smoothness"),
        default = 50,
        values = { 0, 25, 50, 100 },
        labels = {
            C_("Adjacent-line letter spacing", "off"),
            C_("Adjacent-line letter spacing", "strict"),
            C_("Adjacent-line letter spacing", "smooth"),
            C_("Adjacent-line letter spacing", "relaxed"),
        },
        properties = { "crengine.style.justify.tracking.delta.max.bp" },
        preset_numbers = function(value)
            if value == 0 then return nil end -- no limit
            return string.format("%.2f%%", value / 100)
        end,
        enabled_func = knuthOnly,
        value_min = 0, value_max = 1000, value_step = 5, value_hold_step = 25,
        info = _([[Maximum change in letter spacing between consecutive justified lines, in basis points. 50 means 0.50 percentage points. Off removes the limit.]]),
    },
    {
        name = "justification_tolerance",
        event = "SetJustificationTolerance",
        title = _("Fit tolerance"),
        default = { 100, 200 },
        values = { { 50, 100 }, { 100, 200 }, { 200, 500 } },
        labels = {
            C_("Fit tolerance", "strict"),
            C_("Fit tolerance", "balanced"),
            C_("Fit tolerance", "forgiving"),
        },
        properties = {
            "crengine.style.justify.pretolerance",
            "crengine.style.justify.tolerance",
        },
        enabled_func = knuthOnly,
        left_text = _("Normal"), left_min = 0, left_max = 10000, left_step = 10, left_hold_step = 100,
        right_text = _("Emergency"), right_min = 0, right_max = 10000, right_step = 10, right_hold_step = 100,
        info = _([[Knuth badness limits. The emergency tolerance is used only when no solution fits the normal one, together with emergency stretch. If neither finds a solution, a last pass accepts looser lines rather than giving up on the paragraph. Lower values reject uneven lines more aggressively.]]),
    },
    {
        name = "justification_line_penalty",
        event = "SetJustificationLinePenalty",
        title = _("Line-quality penalties"),
        default = { 10, 10000 },
        values = { { 10, 5000 }, { 10, 10000 }, { 10, 20000 } },
        labels = {
            C_("Line quality", "relaxed"),
            C_("Line quality", "balanced"),
            C_("Line quality", "smooth"),
        },
        properties = {
            "crengine.style.justify.line.penalty",
            "crengine.style.justify.adjacent.demerits",
        },
        enabled_func = knuthOnly,
        left_text = _("Line"), left_min = 0, left_max = 10000, left_step = 1, left_hold_step = 10,
        right_text = _("Adjacent fit"), right_min = 0, right_max = 100000, right_step = 100, right_hold_step = 1000,
        info = _([[Base penalty for every line (higher values prefer fewer lines), and extra demerits for neighbouring lines whose spacing differs sharply (one very tight next to one very loose).]]),
    },
    {
        name = "justification_line_limits",
        event = "SetJustificationLineLimits",
        title = _("Emergency & ending"),
        default = { 6, 33 },
        values = { { 6, 0 }, { 6, 33 }, { 8, 50 } },
        labels = {
            C_("Paragraph ending", "natural"),
            C_("Paragraph ending", "balanced"),
            C_("Paragraph ending", "long"),
        },
        properties = {
            "crengine.style.justify.emergency.stretch.percent",
            "crengine.style.justify.last.line.min.percent",
        },
        enabled_func = knuthOnly,
        left_text = _("Emergency"), left_min = 0, left_max = 100, left_step = 1, left_hold_step = 5,
        right_text = _("Ending min"), right_min = 0, right_max = 100, right_step = 1, right_hold_step = 5,
        unit = "%",
        info = _([[Emergency stretch is extra flexibility, as a percentage of the line width, used only when the normal pass cannot find a solution. Ending minimum prefers a final line at least this percentage of the line width. The shorter the final line, the stronger the preference, but it only chooses between layouts that fit the word-space limits and tolerances, so some paragraphs (short ones especially) keep a short ending.]]),
    },
    {
        name = "justification_hyphen_penalty",
        event = "SetJustificationHyphenPenalty",
        title = _("Hyphen penalties"),
        default = { 3000, 3000 },
        values = { { 0, 0 }, { 1000, 1000 }, { 3000, 3000 }, { 10000, 10000 } },
        labels = {
            C_("Hyphen penalty", "free"),
            C_("Hyphen penalty", "light"),
            C_("Hyphen penalty", "moderate"),
            C_("Hyphen penalty", "strong"),
        },
        properties = {
            "crengine.style.justify.hyphen.penalty",
            "crengine.style.justify.explicit.hyphen.penalty",
        },
        enabled_func = knuthOnly,
        left_text = _("Hyphenation"), left_min = 0, left_max = 100000, left_step = 100, left_hold_step = 1000,
        right_text = _("Explicit"), right_min = 0, right_max = 100000, right_step = 100, right_hold_step = 1000,
        info = _([[Cost of ending a line of justified text at a hyphenation point, and at a hyphen already in the text. Higher values mean fewer hyphenated lines, at the price of less even spacing. Values below about 1000 have little effect. A penalty counts squared (3000 costs 9000000), which is why repeated-hyphen penalties are so much larger. (Ragged text has its own hyphen penalty.)

A penalty only chooses between layouts that fit the word-space limits: where a line cannot be filled without breaking a word, the hyphen stays. Looser word-space limits leave more room to avoid hyphens.]]),
    },
    {
        name = "justification_hyphen_demerits",
        event = "SetJustificationHyphenDemerits",
        title = _("Repeated-hyphen penalties"),
        -- As in TeX (hyphen penalty 50, demerits 10000 / 5000): a second
        -- hyphen in a row costs 4 times, and one before the last line twice,
        -- a hyphen at the matching hyphen penalty (1000, 3000, 10000).
        default = { 36000000, 18000000 },
        values = { { 0, 0 }, { 4000000, 2000000 }, { 36000000, 18000000 }, { 400000000, 200000000 } },
        labels = {
            C_("Repeated hyphens", "free"),
            C_("Repeated hyphens", "light"),
            C_("Repeated hyphens", "moderate"),
            C_("Repeated hyphens", "strong"),
        },
        properties = {
            "crengine.style.justify.double.hyphen.demerits",
            "crengine.style.justify.final.hyphen.demerits",
        },
        enabled_func = knuthOnly,
        left_text = _("Consecutive"), left_min = 0, left_max = 1000000000, left_step = 100000, left_hold_step = 1000000,
        right_text = _("Before last"), right_min = 0, right_max = 1000000000, right_step = 100000, right_hold_step = 1000000,
        info = _([[Extra demerits for two hyphenated lines in a row, and for hyphenating the second-to-last line of a paragraph.

They are added as they are, while a hyphen penalty counts squared: a hyphen penalty of 3000 costs 9000000. The presets follow TeX: a second hyphen in a row costs 4 times, and a hyphen before the last line twice, a hyphen at the matching hyphen penalty.

Like the hyphen penalties, they only choose between layouts that fit the word-space limits: most of the remaining consecutive hyphens have no alternative, so even large values remove few of them once hyphens have a penalty.]]),
    },
    {
        name = "ragged_text",
        event = "SetRaggedText",
        title = _("Ragged text"),
        default = { 15, 100 },
        values = { { 0, 100 }, { 10, 100 }, { 15, 100 }, { 15, 200 } },
        labels = {
            C_("Ragged text", "greedy"),
            C_("Ragged text", "even"),
            C_("Ragged text", "balanced"),
            C_("Ragged text", "fewer hyphens"),
        },
        properties = {
            "crengine.style.ragged.width.percent",
            "crengine.style.ragged.hyphen.penalty",
        },
        -- Engines with Knuth–Plass but without ragged text lack these.
        requires = "crengine.style.ragged.width.percent",
        enabled_func = knuthOnly,
        left_text = _("Rag width %"), left_min = 0, left_max = 100, left_step = 1, left_hold_step = 5,
        right_text = _("Hyphen"), right_min = 0, right_max = 100000, right_step = 10, right_hold_step = 100,
        format = function(value) return T("%1% / %2", value[1], value[2]) end,
        preset_numbers = function(value)
            if value[1] == 0 then return nil end -- greedy: the penalty is unused
            return T("%1%/%2", value[1], value[2])
        end,
        info = _([[Left-aligned, right-aligned and centered paragraphs keep their natural word spacing; Knuth–Plass chooses their line breaks so that line lengths are as even as possible.

Rag width is how far short of the full width a line may fall, as a percentage of the line width, before it counts as loose: a smaller width gives an evener right edge, with more hyphens. 0 leaves these paragraphs to greedy line breaking.

Hyphen is the cost of ending a line at a hyphenation point (hyphens already in the text cost nothing). It is on a much smaller scale than the justified hyphen penalties: about 100 hyphenates only to avoid a fairly short line.

As spaces are never condensed, ragged text takes a few percent more pages than with greedy line breaking.]]),
    },
}

local options_by_name = {}
for _i, option in ipairs(options) do
    options_by_name[option.name] = option
end

local function copy(value)
    return type(value) == "table" and util.tableDeepCopy(value) or value
end

local function same(a, b)
    if type(a) == "table" and type(b) == "table" then
        return util.tableEquals(a, b)
    end
    return a == b
end


-- Short form of a number for preset names in notifications and gestures: 3000 → 3k, 1500000 → 1.5M.
local function shortNumber(n)
    if n >= 1000000 and n % 100000 == 0 then
        return string.format("%g", n / 1000000) .. "M"
    elseif n >= 1000 and n % 100 == 0 then
        return string.format("%g", n / 1000) .. "k"
    end
    return tostring(n)
end

-- The numbers behind a preset, shown next to its name (nil when they would
-- say nothing more than the name, as for "off" or "free").
local function presetNumbers(option, value)
    if option.preset_numbers then
        return option.preset_numbers(value)
    end
    if type(value) == "table" then
        if value[1] == 0 and value[2] == 0 then
            return nil
        end
        local a, b = shortNumber(value[1]), shortNumber(value[2])
        if option.signed then
            return T("−%1%/+%2%", a, b)
        elseif option.unit == "%" then
            return T("%1%/%2%", a, b)
        end
        return a .. "/" .. b
    end
    if value == 0 then
        return nil
    end
    return shortNumber(value)
end

-- A preset's name and numbers, for menus and notifications.
local function presetText(option, i)
    local numbers = presetNumbers(option, option.values[i])
    if numbers then
        return T("%1 (%2)", option.labels[i], numbers)
    end
    return option.labels[i]
end

local function formatValue(option, value)
    for i, preset in ipairs(option.values) do
        if same(preset, value) then
            return presetText(option, i)
        end
    end
    if option.format then
        return option.format(value)
    end
    if type(value) == "table" then
        if option.signed then
            return T("−%1% / +%2%", value[1], value[2])
        elseif option.unit == "%" then
            return T("%1% / %2%", value[1], value[2])
        end
        return T("%1 / %2", value[1], value[2])
    end
    if option.name == "justification_tracking_smoothness" then
        return string.format("%.2f%%", value / 100)
    end
    return tostring(value)
end

local function validValue(option, value)
    if type(option.default) == "table" then
        if type(value) ~= "table" or type(value[1]) ~= "number" or type(value[2]) ~= "number" then
            return nil
        end
    elseif type(value) ~= "number" then
        return nil
    end
    return value
end

function KnuthPlass:init()
    self.values = {}
    self.supported = {}
    self.active = false
    self:onDispatcherRegisterActions()
    if self.ui.rolling then
        -- Only reflowable (CREngine) documents have these settings.
        self.ui.menu:registerToMainMenu(self)
    elseif not self.ui.document and self.ui.menu then
        -- The file browser: updates and the engine.
        self.ui.menu:registerToMainMenu(self)
        UIManager:nextTick(function() self:showRollback() end)
        self:scheduleUpdateCheck()
    end
end

-- Once per session, a little after the file browser or a book is shown.
-- It returns at once unless automatic updates are on, a day has passed and
-- the device is online.
function KnuthPlass:scheduleUpdateCheck()
    if Updater.scheduled then return end
    Updater.scheduled = true
    UIManager:scheduleIn(10, function()
        Updater.check(self, false)
    end)
end

function KnuthPlass:onDispatcherRegisterActions()
    for _i, option in ipairs(options) do
        Dispatcher:registerAction(option.name, {
            category = "string",
            event = option.event,
            title = option.title,
            args = option.values,
            toggle = (function()
                local toggle = {}
                for i = 1, #option.values do
                    toggle[i] = presetText(option, i)
                end
                return toggle
            end)(),
            configurable = { name = option.name, values = option.values },
            rolling = true,
        })
    end
    Dispatcher:registerAction("knuth_plass_dialog", {
        category = "none",
        event = "ShowKnuthPlassDialog",
        title = _("Knuth–Plass justification settings"),
        rolling = true,
        separator = true,
    })
end

function KnuthPlass:engineSupported()
    local document = self.ui.document
    if not (self.ui.rolling and document and document._document) then
        return false
    end
    local probe = document._document:getStringProperty(CAPABILITY_PROPERTY)
    return probe ~= nil and probe ~= ""
end

-- Whether the engine has this setting (a Knuth–Plass engine fills in a
-- default for every property it knows).
function KnuthPlass:optionSupported(option)
    if not option.requires then
        return true
    end
    local probe = self.ui.document._document:getStringProperty(option.requires)
    return probe ~= nil and probe ~= ""
end

-- The settings this engine has, in menu order.
function KnuthPlass:supportedOptions()
    local list = {}
    for _i, option in ipairs(options) do
        if self.supported[option.name] then
            table.insert(list, option)
        end
    end
    return list
end

-- The value for books without their own: the user's default if set,
-- otherwise the plugin's.
local function defaultValue(option)
    local value = validValue(option, G_reader_settings:readSetting("copt_" .. option.name))
    if value == nil then
        value = option.default
    end
    return copy(value)
end

function KnuthPlass:readValue(config, option)
    local value = validValue(option, config:readSetting("copt_" .. option.name))
    if value == nil then
        return defaultValue(option)
    end
    return copy(value)
end

function KnuthPlass:applyOption(option, value)
    local cre = self.ui.document._document
    if #option.properties == 1 then
        cre:setIntProperty(option.properties[1], value)
    else
        cre:setIntProperty(option.properties[1], value[1])
        cre:setIntProperty(option.properties[2], value[2])
    end
end

-- Runs after the core reader modules have read their settings (plugins are
-- registered after them) and before the document is first rendered.
function KnuthPlass:onReadSettings(config)
    self.active = self:engineSupported()
    if self.ui.rolling then
        Engine.verify(Engine.installedBuild())
    end
    if not self.active then
        if self.ui.rolling then
            logger.info("Knuth–Plass: this CREngine has no Knuth–Plass support; plugin inactive")
        end
        return
    end
    for _i, option in ipairs(options) do
        self.supported[option.name] = self:optionSupported(option)
    end
    for _i, option in ipairs(self:supportedOptions()) do
        local value = self:readValue(config, option)
        self.values[option.name] = value
        -- Keeping the value in configurable lets ReaderConfig save it with
        -- the book (as copt_<name>) and Profiles capture it.
        self.ui.document.configurable[option.name] = copy(value)
        self:applyOption(option, value)
    end
end

function KnuthPlass:onReaderReady()
    if self.active then
        self:hookProfiles()
    end
    self:showRollback()
    self:scheduleUpdateCheck()
end

-- Tell the user (once) if the Knuth–Plass engine was turned off at start-up.
function KnuthPlass:showRollback()
    local rolled_back = Engine.takeRollback()
    if rolled_back then
        local InfoMessage = require("ui/widget/infomessage")
        local text
        if rolled_back.fallback then
            text = T(_("The Knuth–Plass engine %1 was turned off, and the previous engine %2 used, because %3."),
                rolled_back.commit, rolled_back.fallback, rolled_back.reason)
        else
            text = T(_("The Knuth–Plass engine %1 was turned off, and KOReader's own engine used, because %2."),
                rolled_back.commit, rolled_back.reason)
        end
        UIManager:show(InfoMessage:new{ text = text })
    end
end

-- Let Profiles' "create from current book settings" include our settings.
-- Applying a profile needs nothing extra: each setting is a Dispatcher action.
function KnuthPlass:hookProfiles()
    local profiles = self.ui.profiles
    if not profiles or profiles._knuth_plass_hooked
            or type(profiles.getProfileFromCurrentBookSettings) ~= "function" then
        return
    end
    local original = profiles.getProfileFromCurrentBookSettings
    profiles.getProfileFromCurrentBookSettings = function(plugin, new_name)
        local profile = original(plugin, new_name)
        if not plugin.ui.rolling or type(profile) ~= "table" or type(profile.settings) ~= "table" then
            return profile
        end
        local order = profile.settings.order or {}
        for _i, option in ipairs(self:supportedOptions()) do
            local value = self.values[option.name]
            if value ~= nil and not util.arrayContains(order, option.name) then
                table.insert(order, option.name)
                profile[option.name] = copy(value)
            end
        end
        profile.settings.order = order
        return profile
    end
    profiles._knuth_plass_hooked = true
end

function KnuthPlass:setValue(name, value, quiet)
    local option = options_by_name[name]
    if not option or not self.active or not self.supported[name] then return end
    value = validValue(option, value)
    if value == nil then return end
    value = copy(value)
    self.values[name] = value
    self.ui.document.configurable[name] = copy(value)
    self.ui.doc_settings:saveSetting("copt_" .. name, copy(value))
    self:applyOption(option, value)
    self.ui:handleEvent(Event:new("UpdatePos"))
    if not quiet then
        Notification:notify(T(_("%1: %2"), option.title, formatValue(option, value)))
    end
    self:refreshDialog()
    return true
end

function KnuthPlass:makeDefault(name, value)
    local option = options_by_name[name]
    value = validValue(option, value)
    if value == nil then return end
    G_reader_settings:saveSetting("copt_" .. name, copy(value))
    Notification:notify(T(_("Default %1: %2"), option.title, formatValue(option, value)))
    self:refreshDialog()
end

-- Forget the user's default so the plugin's built-in one applies again.
function KnuthPlass:resetDefault(name)
    local option = options_by_name[name]
    G_reader_settings:delSetting("copt_" .. name)
    Notification:notify(T(_("Default %1: %2 (built-in)"), option.title,
        formatValue(option, option.default)))
    self:refreshDialog()
end

function KnuthPlass:hasUserDefaults()
    for _i, option in ipairs(options) do
        if G_reader_settings:readSetting("copt_" .. option.name) ~= nil then
            return true
        end
    end
    return false
end

function KnuthPlass:confirmResetAllDefaults()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Reset all Knuth–Plass defaults for new books to the built-in values?\n\nSettings saved with individual books are not changed."),
        ok_text = _("Reset"),
        ok_callback = function()
            for _i, option in ipairs(options) do
                G_reader_settings:delSetting("copt_" .. option.name)
            end
            Notification:notify(_("Knuth–Plass defaults reset"))
            self:refreshDialog()
        end,
    })
end

function KnuthPlass:showPairWidget(option)
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local value = self.values[option.name]
    local default = defaultValue(option)
    UIManager:show(DoubleSpinWidget:new{
        title_text = option.title,
        info_text = option.info,
        width_factor = 0.8,
        left_text = option.left_text,
        left_value = value[1],
        left_min = option.left_min,
        left_max = option.left_max,
        left_step = option.left_step,
        left_hold_step = option.left_hold_step,
        left_default = default[1],
        right_text = option.right_text,
        right_value = value[2],
        right_min = option.right_min,
        right_max = option.right_max,
        right_step = option.right_step,
        right_hold_step = option.right_hold_step,
        right_default = default[2],
        unit = option.unit,
        keep_shown_on_apply = true,
        callback = function(left, right)
            self:setValue(option.name, { left, right }, true)
        end,
        extra_text = _("Set as default"),
        extra_callback = function(left, right)
            self:makeDefault(option.name, { left, right })
        end,
    })
end

function KnuthPlass:showSingleWidget(option)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = option.title,
        info_text = option.info,
        width_factor = 0.7,
        value = self.values[option.name],
        value_min = option.value_min,
        value_max = option.value_max,
        value_step = option.value_step,
        value_hold_step = option.value_hold_step,
        default_value = defaultValue(option),
        keep_shown_on_apply = true,
        callback = function(widget)
            self:setValue(option.name, widget.value, true)
        end,
        extra_text = _("Set as default"),
        extra_callback = function(widget)
            self:makeDefault(option.name, widget.value)
        end,
    })
end

function KnuthPlass:showInfo(option)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = option.info })
end

local function isPreset(option, value)
    for _i, preset in ipairs(option.values) do
        if same(preset, value) then
            return true
        end
    end
    return false
end

-- Laid out like KOReader's bottom menu: one row per setting, its name on
-- the left (right-aligned, in a column as wide as the longest name) and
-- its presets on the right. Names are a little larger than presets, as
-- there.
local NAME_FONT_SIZE = 20
local PRESET_FONT_SIZE = 16
-- The dialog's share of the screen width.
local DIALOG_WIDTH_FACTOR = 0.95

-- Marks the default for new books.
local DEFAULT_MARK = " ★"

-- A TextWidget for a setting name, in a smaller size if needed to fit.
local function fittedLine(text, size, width, fgcolor)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local widget
    while true do
        widget = TextWidget:new{
            text = text,
            face = Font:getFace("cfont", size),
            fgcolor = fgcolor,
            max_width = width,
        }
        if not widget:isTruncated() or size <= 10 then
            return widget
        end
        widget:free()
        size = size - 1
    end
end

-- Height of every setting row: one line of a name.
local function settingRowHeight()
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    local widget = TextWidget:new{ text = "0", face = Font:getFace("cfont", NAME_FONT_SIZE) }
    local height = widget:getSize().h
    widget:free()
    return height
end

-- Width of the names column: the longest name, but between a quarter and
-- a half of the dialog (as in the bottom menu).
local function nameColumnWidth(options)
    local Font = require("ui/font")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = require("device").screen
    local padding = 2 * Size.padding.large
    local widest = 0
    for _i, option in ipairs(options) do
        local widget = TextWidget:new{ text = option.title, face = Font:getFace("cfont", NAME_FONT_SIZE) }
        widest = math.max(widest, widget:getSize().w + padding)
        widget:free()
    end
    local dialog_width = math.floor(Screen:getWidth() * DIALOG_WIDTH_FACTOR)
    return math.max(math.floor(dialog_width / 4), math.min(widest, math.floor(dialog_width / 2)))
end

-- ButtonDialog whose setting names are right-aligned, which ButtonTable
-- can't do by itself: their labels are replaced after every (re)build.
-- Created on first use, as KOReader's widgets can only be loaded once the
-- UI is up.
local SettingsDialog
local function settingsDialogClass()
    if SettingsDialog then
        return SettingsDialog
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    SettingsDialog = ButtonDialog:extend{}
    function SettingsDialog:init()
        ButtonDialog.init(self)
        self:alignNames()
    end
    function SettingsDialog:alignNames()
        local Blitbuffer = require("ffi/blitbuffer")
        local RightContainer = require("ui/widget/container/rightcontainer")
        for _i, row in ipairs(self.buttons) do
            local entry = row[1]
            local button = entry and entry.setting_name and self:getButtonById(entry.id)
            if button and button.label_container then
                local dimen = button.label_container.dimen
                -- Grayed out like the presets, but still tappable for help.
                local fgcolor = entry.dimmed and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
                local name = fittedLine(entry.text, NAME_FONT_SIZE, dimen.w, fgcolor)
                button.label_widget:free()
                button.label_widget = name
                button.label_container = RightContainer:new{ dimen = dimen:copy(), name }
                button.frame[1] = button.label_container
            end
        end
    end
    return SettingsDialog
end

-- The dialog's rows: for each setting, its name (tap for an explanation)
-- then its presets, with the current one highlighted and the default
-- marked, then "…" for a custom value.
function KnuthPlass:getDialogButtons()
    local Blitbuffer = require("ffi/blitbuffer")
    local supported = self:supportedOptions()
    local row_height = settingRowHeight()
    local name_width = nameColumnWidth(supported)
    local rows = {}
    for _i, option in ipairs(supported) do
        local value = self.values[option.name]
        local enabled = not option.enabled_func or option.enabled_func(self)
        local default = defaultValue(option)
        local custom_default = not isPreset(option, default)
        local row = {
            {
                id = option.name .. "#name",
                text = option.title,
                setting_name = true,
                dimmed = not enabled,
                width = name_width,
                height = row_height,
                align = "left", -- (right-aligned once built)
                no_vertical_sep = true,
                avoid_text_truncation = false, -- (the label is replaced)
                font_size = NAME_FONT_SIZE,
                font_bold = false,
                callback = function()
                    self:showInfo(option)
                end,
                hold_callback = function()
                    self:resetDefault(option.name)
                end,
            },
        }
        for i, preset in ipairs(option.values) do
            local selected = same(value, preset)
            local text = option.labels[i]
            if same(default, preset) then
                text = text .. DEFAULT_MARK
            end
            table.insert(row, {
                id = option.name .. "#" .. i,
                text = text,
                height = row_height,
                font_size = PRESET_FONT_SIZE,
                font_bold = selected,
                background = selected and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                enabled = enabled,
                callback = function()
                    self:setValue(option.name, preset, true)
                end,
                hold_callback = function()
                    self:makeDefault(option.name, preset)
                end,
            })
        end
        if option.left_text or option.value_min then
            local custom = not isPreset(option, value)
            table.insert(row, {
                id = option.name .. "#custom",
                text = custom_default and "…" .. DEFAULT_MARK or "…",
                height = row_height,
                font_size = PRESET_FONT_SIZE,
                font_bold = custom,
                background = custom and Blitbuffer.COLOR_LIGHT_GRAY or nil,
                enabled = enabled,
                callback = function()
                    if type(option.default) == "table" then
                        self:showPairWidget(option)
                    else
                        self:showSingleWidget(option)
                    end
                end,
                -- Long-press makes the current custom value the default.
                hold_callback = custom and function()
                    self:makeDefault(option.name, value)
                end or nil,
            })
        end
        table.insert(rows, row)
    end
    table.insert(rows, {
        {
            text = _("Tap a name for help. Long-press a value to make it the default for new books (marked ★). Long-press a name to restore its built-in default."),
            font_size = PRESET_FONT_SIZE,
            font_bold = false,
            enabled = false,
            callback = function() end,
        },
    })
    table.insert(rows, {
        {
            text = T(_("Check for updates (%1)"), self.version or "?"),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            enabled = self.path ~= nil,
            callback = function()
                Updater.check(self, true)
            end,
        },
        {
            text = T(_("Automatic updates: %1"), Updater.modeText(Updater.getMode())),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            callback = function()
                -- Cycles off → notify → install.
                local mode = Updater.getMode()
                for i, m in ipairs(Updater.modes) do
                    if m == mode then
                        Updater.setMode(Updater.modes[i % #Updater.modes + 1])
                        break
                    end
                end
                self:refreshDialog()
            end,
            hold_callback = function()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("When KOReader is online, the plugin checks for a new version once a day.\n\noff: never\nnotify: ask before installing\ninstall: install it, ready for the next restart"),
                })
            end,
        },
    })
    local engine_row = {
        {
            text = T(_("Engine: %1"), Engine.buildText(Engine.installedBuild())),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            callback = function()
                self:showEngineInfo()
            end,
        },
    }
    if Engine.previous() then
        table.insert(engine_row, {
            text = _("Roll back"),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            callback = function()
                self:confirmRollBack()
            end,
        })
    end
    if Engine.hasStock() then
        table.insert(engine_row, {
            text = _("Restore standard engine"),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            callback = function()
                self:confirmRestoreStock()
            end,
        })
    end
    table.insert(rows, engine_row)
    table.insert(rows, {
        {
            text = _("Reset all defaults"),
            font_size = NAME_FONT_SIZE,
            font_bold = false,
            enabled = self:hasUserDefaults(),
            callback = function()
                self:confirmResetAllDefaults()
            end,
        },
    })
    return rows
end

function KnuthPlass:showEngineInfo()
    local InfoMessage = require("ui/widget/infomessage")
    -- In the file browser this loads the engine, if it isn't yet.
    local build, supported = Engine.runningEngine()
    local text = T(_("Engine build: %1\nKOReader: %2\nDevice: %3\n\nThe Knuth–Plass engine is a CREngine built from the knuth-plass-history branch of github.com/spfenwick/crengine. \"Check for updates\" also looks for a build for this KOReader version."),
        Engine.buildText(build), tostring(Engine.revision()), tostring(Engine.target()))
    local installed = Engine.installed()
    if installed then
        text = text .. "\n\n" .. T(_("The Knuth–Plass engine is loaded from %1 (KOReader's own engine is left as it is)."), installed.lib)
        if installed.unchecked_rev == Engine.revision() then
            text = text .. " " .. _("It couldn't be checked against this KOReader version, so KOReader's own engine is used; \"Check for updates\" checks it and puts it back.")
        elseif installed.rev ~= Engine.revision() then
            text = text .. " " .. _("It was checked against another KOReader version; it's checked against this one when KOReader next starts.")
        end
        if not Engine.patchesEnabled() then
            text = text .. " " .. _("User patches are turned off, so it's only loaded when KOReader starts in the file browser.")
        end
        local previous = Engine.previous()
        if previous then
            text = text .. "\n\n" .. T(_("The previous engine, %1, is kept: it's used if this one fails, and \"Roll back\" goes back to it."), previous.commit)
        end
    end
    if build == "" and supported then
        text = text .. "\n\n" .. _("This engine has the Knuth–Plass settings but doesn't report its build (an early build).")
    elseif build == "" then
        text = text .. "\n\n" .. _("This is KOReader's standard engine, without Knuth–Plass line breaking. \"Check for updates\" offers the Knuth–Plass engine when there's a build for this device.")
    end
    UIManager:show(InfoMessage:new{ text = text })
end

function KnuthPlass:confirmRestoreStock()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Put back KOReader's standard engine? Knuth–Plass line breaking will be unavailable after KOReader restarts."),
        ok_text = _("Restore"),
        ok_callback = function()
            local ok, err = Engine.restoreStock()
            if ok then
                UIManager:askForRestart(_("KOReader's standard engine has been put back. It will be used after KOReader restarts."))
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{ text = T(_("Could not restore the standard engine:\n%1"), err) })
            end
        end,
    })
end

function KnuthPlass:confirmRollBack()
    local previous = Engine.previous()
    if not previous then return end
    local installed = Engine.installed()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Go back to the previous Knuth–Plass engine, %1? Engine %2 won't be offered again for this KOReader version."),
            previous.commit, installed and installed.commit or "?"),
        ok_text = _("Roll back"),
        ok_callback = function()
            local ok, err = Engine.rollBack()
            if ok then
                UIManager:askForRestart(T(_("The Knuth–Plass engine %1 will be used after KOReader restarts."), previous.commit))
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{ text = T(_("Could not roll back the engine:\n%1"), err) })
            end
        end,
    })
end

function KnuthPlass:showDialog()
    if not self.active then return end
    local TitleBar = require("ui/widget/titlebar")
    local dialog
    dialog = settingsDialogClass():new{
        use_info_style = false,
        -- The title bar brings its own padding.
        title_padding = 0,
        title_margin = 0,
        buttons = self:getDialogButtons(),
        width_factor = DIALOG_WIDTH_FACTOR,
        tap_close_callback = function()
            self.dialog = nil
        end,
    }
    -- ButtonDialog has no close button, so the title is a TitleBar with
    -- KOReader's standard ✕ in the top right corner.
    local title_bar = TitleBar:new{
        width = dialog:getAddedWidgetAvailableWidth(),
        title = _("Knuth–Plass justification"),
        align = "left",
        with_bottom_line = false,
        close_callback = function()
            dialog:onClose()
        end,
        show_parent = dialog,
    }
    -- Having a parent keeps it from being freed when the dialog is
    -- rebuilt after a change; the ✕ is not part of key navigation (Back
    -- closes the dialog).
    title_bar.parent = dialog
    title_bar.not_focusable = true
    dialog:addWidget(title_bar)
    self.dialog = dialog
    UIManager:show(dialog)
end

-- Rebuild the open dialog after a change, keeping its scroll position.
function KnuthPlass:refreshDialog()
    local dialog = self.dialog
    if not dialog then return end
    local offset = dialog:getScrolledOffset()
    dialog.buttons = self:getDialogButtons()
    dialog:reinit()
    dialog:setScrolledOffset(offset)
    UIManager:setDirty("all", "ui")
end

function KnuthPlass:onShowKnuthPlassDialog()
    self:showDialog()
    return true
end

function KnuthPlass:addToMainMenu(menu_items)
    if not self.ui.document then
        menu_items.knuth_plass = self:fileBrowserMenu()
        return
    end
    menu_items.knuth_plass = {
        text_func = function()
            if not self.active then
                return _("Knuth–Plass justification: install engine…")
            end
            return T(_("Line breaking: %1"),
                formatValue(options_by_name.line_breaking_mode, self.values.line_breaking_mode))
        end,
        sorting_hint = "typeset",
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
            end
            if self.active then
                self:showDialog()
            else
                -- Offers to install the Knuth–Plass engine.
                Updater.check(self, true)
            end
        end,
    }
end

-- The file browser's entry (Tools): updates and the engine.
function KnuthPlass:fileBrowserMenu()
    local modes = {}
    for _i, mode in ipairs(Updater.modes) do
        table.insert(modes, {
            text = Updater.modeText(mode),
            checked_func = function()
                return Updater.getMode() == mode
            end,
            radio = true,
            callback = function()
                Updater.setMode(mode)
            end,
        })
    end
    return {
        text = _("Knuth–Plass justification"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = T(_("Check for updates (%1)"), self.version or "?"),
                enabled_func = function() return self.path ~= nil end,
                callback = function()
                    Updater.check(self, true)
                end,
            },
            {
                text_func = function()
                    return T(_("Automatic updates: %1"), Updater.modeText(Updater.getMode()))
                end,
                help_text = _("When KOReader is online, the plugin checks for a new version once a day.\n\noff: never\nnotify: ask before installing\ninstall: install it, ready for the next restart\n\nThe engine is checked automatically when a book is open."),
                sub_item_table = modes,
                separator = true,
            },
            {
                text = _("Engine information"),
                keep_menu_open = true,
                callback = function()
                    self:showEngineInfo()
                end,
            },
            {
                text_func = function()
                    local previous = Engine.previous()
                    return previous and T(_("Roll back to previous engine (%1)"), previous.commit)
                        or _("Roll back to previous engine")
                end,
                enabled_func = function() return Engine.previous() ~= nil end,
                callback = function()
                    self:confirmRollBack()
                end,
            },
            {
                text = _("Restore standard engine"),
                enabled_func = function() return Engine.hasStock() end,
                callback = function()
                    self:confirmRestoreStock()
                end,
            },
        },
    }
end

-- Dispatcher / gesture / Profiles events.
for _i, option in ipairs(options) do
    KnuthPlass["on" .. option.event] = function(self, value)
        return self:setValue(option.name, value)
    end
end

return KnuthPlass
