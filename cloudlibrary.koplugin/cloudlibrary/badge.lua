--[[
The "on this device" badge: a check mark in a white circle, drawn on the
bottom-right corner of the cover of local books that are in the catalog.

Drawn after the file browser (FileChooser) and book lists (BookList: search
results, history, collections) paint, over whatever drew the items: stock
CoverBrowser or ZenOS. The cover's position comes from the ImageWidget that
drew it; items without a cover image get the badge on the item's corner.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local Badge = {
    enabled = true,
    isOnDevice = nil, -- function(path) -> true for local books in the catalog
    installed = false,
}

local widgets = {} -- size -> widget

local function badgeWidget(size)
    local w = widgets[size]
    if w then return w end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local IconWidget = require("ui/widget/iconwidget")
    local Geom = require("ui/geometry")
    local border = math.max(1, math.floor(size / 14))
    local inner = size - 2 * border
    local icon = math.floor(inner * 0.72)
    w = FrameContainer:new{
        width = size, height = size,
        bordersize = border, radius = math.floor(size / 2),
        padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = inner },
            IconWidget:new{ icon = "check", width = icon, height = icon },
        },
    }
    widgets[size] = w
    return w
end

-- The drawn cover inside an item: its ImageWidget, if any.
local function coverRect(widget, depth, seen)
    if type(widget) ~= "table" or depth > 12 or seen[widget] then return nil end
    seen[widget] = true
    if (widget.image or widget.file) and type(widget.dimen) == "table" and widget.dimen.w
            and widget.dimen.w > 0 and widget.dimen.x then
        return widget.dimen
    end
    for _i, c in ipairs(widget) do
        local r = coverRect(c, depth + 1, seen)
        if r then return r end
    end
end

local function eachItem(widget, fn, depth, seen)
    if type(widget) ~= "table" or depth > 30 or seen[widget] then return end
    seen[widget] = true
    local entry = widget.entry
    local path = type(entry) == "table" and (entry.path or entry.file)
    if type(path) == "string" and type(widget.dimen) == "table" and widget.dimen.x then
        fn(widget, path)
        return
    end
    for _i, c in ipairs(widget) do eachItem(c, fn, depth + 1, seen) end
end

--- Where the badge goes for a cover (or item) rectangle, and its size.
function Badge.place(rect)
    local min_size, max_size = Screen:scaleBySize(14), Screen:scaleBySize(30)
    local size = math.floor(math.min(rect.w, rect.h) * 0.2)
    size = math.max(min_size, math.min(max_size, size))
    local margin = math.max(2, math.floor(size / 5))
    return rect.x + rect.w - size - margin, rect.y + rect.h - size - margin, size
end

function Badge.paintOn(menu, bb)
    if not (Badge.enabled and Badge.isOnDevice and menu.item_group) then return end
    eachItem(menu.item_group, function(item, path)
        if not Badge.isOnDevice(path) then return end
        local rect = coverRect(item, 0, {}) or item.dimen
        if rect.w < 20 or rect.h < 20 then return end
        local x, y, size = Badge.place(rect)
        badgeWidget(size):paintTo(bb, x, y)
    end, 0, {})
end

function Badge.install()
    if Badge.installed then return end
    Badge.installed = true
    -- FileChooser extends BookList, so wrapping BookList covers both (older
    -- KOReader versions have no BookList: wrap FileChooser there).
    local ok, cls = pcall(require, "ui/widget/booklist")
    if not (ok and type(cls) == "table") then cls = require("ui/widget/filechooser") end
    local orig = cls.paintTo
    cls.paintTo = function(self, bb, x, y)
        orig(self, bb, x, y)
        local okp, err = pcall(Badge.paintOn, self, bb)
        if not okp then require("logger").warn("CloudLibrary: badge:", err) end
    end
end

return Badge
