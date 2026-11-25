--[[
Cover badges, in a white circle on the bottom-right corner of the cover:
- cloud: a cloud on books that are only in the online library (default on);
  it shows only that the book is in the cloud, not its reading status (ZenOS
  shows that in its own status badge);
- local: a check mark on local books that are in the catalog (default off);
- noncloud: a crossed-out cloud on books in the library folder that aren't
  in the catalog (default off).

On covers, ZenOS paints it: the book source's badge(path) (see
athenaeum/zenos_source.lua) gives Badge.icon(Badge.kind(path)), and ZenOS
draws that icon in its badge colours wherever it draws the book's cover
(library mosaic and list, group views, Home's strips and featured book),
moving its series number clear of it.

Only KOReader's plain list (no covers) is painted here: after the file
browser (FileChooser), book lists (BookList: search results, history,
collections) and other Menus listing books by path paint, the badge goes
before the name. Badge.decorate gives those rows an indent to make room
for it.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local Badge = {
    local_enabled = false,
    cloud_enabled = true,
    noncloud_enabled = false,
    isOnDevice = nil, -- function(path) -> true for local books in the catalog
    isCloud = nil,    -- function(path) -> true for cloud-only books
    isNonCloud = nil, -- function(path) -> true for local books not in the catalog
    installed = false,
}

-- The plugin's own cloud icons (KOReader has none).
local ICONS = (debug.getinfo(1, "S").source:match("^@(.*)/athenaeum/[^/]*$") or ".") .. "/icons/"
local CLOUD_ICON = ICONS .. "cloud.svg"
local CLOUD_OFF_ICON = ICONS .. "cloud-off.svg"
local KIND_ICONS = {
    ["local"] = ICONS .. "check.svg",
    cloud = CLOUD_ICON,
    noncloud = CLOUD_OFF_ICON,
}

local widgets = {} -- kind .. size -> widget

local function badgeWidget(size, kind)
    local key = kind .. size
    local w = widgets[key]
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
            IconWidget:new{ file = Badge.icon(kind), alpha = true, width = icon, height = icon },
        },
    }
    widgets[key] = w
    return w
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

--- Plain list rows: the badge's size, and the room reserved before the name.
function Badge.plainSize()
    return Screen:scaleBySize(20), Screen:scaleBySize(28)
end

--- True when a path gets a badge: Badge.kind() without working out which.
function Badge.has(path)
    return (Badge.cloud_enabled and Badge.isCloud and Badge.isCloud(path))
        or (Badge.local_enabled and Badge.isOnDevice and Badge.isOnDevice(path))
        or (Badge.noncloud_enabled and Badge.isNonCloud and Badge.isNonCloud(path))
        or false
end

--- Makes room for the badge in a plain list row (other views ignore indent).
function Badge.decorate(item)
    if item.path and Badge.has(item.path) then
        local _size, slot = Badge.plainSize()
        item.indent = slot
    end
end

-- A plain list row (KOReader's MenuItem): where its text starts, once painted.
local function plainText(item)
    local u = item._underline_container
    if type(u) == "table" and type(u.dimen) == "table" and u.dimen.x and u.dimen.h then
        return u.dimen
    end
end

--- Startup check (Guard.check) for the fields paintOn reads from KOReader's
-- list rows, which are private and change: paints a real Menu with two
-- rows, one with room made for the badge (entry.indent), finds them as
-- paintOn does (item_group, entry, dimen, _underline_container), and checks
-- that the room keeps the row's text clear of where the badge goes.
-- Returns nil when all is well, else what's wrong.
function Badge.checkPlainRows()
    local Blitbuffer = require("ffi/blitbuffer")
    local Menu = require("ui/widget/menu")
    local size, slot = Badge.plainSize()
    local w, h = Screen:scaleBySize(400), Screen:scaleBySize(300)
    local plain, room = "/athenaeum-check/plain.epub", "/athenaeum-check/room.epub"
    local menu, bb
    local ok, problem = pcall(function()
        menu = Menu:new{
            item_table = {
                { text = "WWWW", path = room, indent = slot },
                { text = "WWWW", path = plain },
            },
            width = w, height = h, items_per_page = 2,
            is_borderless = true, no_title = true, is_popout = false,
        }
        bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        menu:paintTo(bb, 0, 0)
        local rows = {}
        eachItem(menu.item_group, function(item, path) rows[path] = item end, 0, {})
        if not (rows[plain] and rows[room]) then
            return "list rows not found (item_group, entry, dimen)"
        end
        -- Where a row's text starts: its first dark pixel, away from the
        -- row's top and bottom (separator lines).
        local function textStart(item)
            local text = plainText(item)
            if not text then return nil end
            local y0 = math.max(0, text.y + math.floor(text.h / 4))
            local y1 = math.min(h - 1, text.y + math.floor(text.h * 3 / 4))
            for x = math.max(0, text.x), math.min(w, text.x + text.w) - 1 do
                for y = y0, y1 do
                    if bb:getPixel(x, y):getColor8().a < 128 then return x, text end
                end
            end
        end
        local plain_x = textStart(rows[plain])
        local room_x, text = textStart(rows[room])
        if not (plain_x and room_x) then return "row text not found (_underline_container)" end
        if room_x < text.x + size or room_x <= plain_x then
            return "room for the badge not kept (entry.indent)"
        end
    end)
    if bb then bb:free() end
    if menu and type(menu.free) == "function" then pcall(menu.free, menu) end
    if not ok then return "checking plain list rows failed: " .. tostring(problem) end
    return problem
end

--- Which badge a path gets: "cloud", "local", "noncloud" or nil.
function Badge.kind(path)
    if Badge.cloud_enabled and Badge.isCloud and Badge.isCloud(path) then return "cloud" end
    if Badge.local_enabled and Badge.isOnDevice and Badge.isOnDevice(path) then return "local" end
    if Badge.noncloud_enabled and Badge.isNonCloud and Badge.isNonCloud(path) then return "noncloud" end
end

--- The SVG file for a badge kind (from Badge.kind).
function Badge.icon(kind)
    return KIND_ICONS[kind] or CLOUD_ICON
end

function Badge.paintOn(menu, bb)
    if not ((Badge.cloud_enabled or Badge.local_enabled or Badge.noncloud_enabled)
            and menu.item_group) then return end
    eachItem(menu.item_group, function(item, path)
        -- CoverBrowser's items showing covers: ZenOS badges the cover.
        if item.do_cover_image then return end
        -- Plain row: before the name, if the row made room for it.
        if (item.entry.indent or 0) <= 0 then return end
        local text = plainText(item)
        if not text then return end
        local kind = Badge.kind(path)
        if not kind then return end
        local size = math.min(Badge.plainSize(), math.floor(text.h * 0.8))
        badgeWidget(size, kind):paintTo(bb, text.x, text.y + math.floor((text.h - size) / 2))
    end, 0, {})
end

function Badge.install()
    if Badge.installed then return end
    local Guard = require("athenaeum/guard")
    if not Guard.ok("rows") then return end -- failed the startup check
    Badge.installed = true
    -- FileChooser extends BookList, so wrapping BookList covers both (older
    -- KOReader versions have no BookList: wrap FileChooser there).
    local ok, cls = pcall(require, "ui/widget/booklist")
    if not (ok and type(cls) == "table") then cls = require("ui/widget/filechooser") end
    Guard.hook("rows", cls, "paintTo", function(orig, self, bb, x, y)
        orig(self, bb, x, y)
        Badge.paintOn(self, bb)
    end, "BookList:paintTo")
    -- BookList now has its own paintTo, so its lists aren't badged twice.
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    if ok_menu and type(Menu) == "table" and Menu ~= cls and rawget(cls, "paintTo") then
        Guard.hook("rows", Menu, "paintTo", function(orig, self, bb, x, y)
            orig(self, bb, x, y)
            Badge.paintOn(self, bb)
        end, "Menu:paintTo")
    end
end

return Badge
