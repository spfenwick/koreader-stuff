--[[
Cover badges, in a white circle on the bottom-right corner of the cover:
- cloud: a cloud on books that are only in the cloud library (default on),
  with a check mark, play or pause mark cut out when OmniSync says the
  book is finished, being read or on hold on another device;
- local: a check mark on local books that are in the catalog (default off);
- noncloud: a crossed-out cloud on books in the library folder that aren't
  in the catalog (default off).

Drawn after the file browser (FileChooser) and book lists (BookList: search
results, history, collections) paint, over whatever drew the items: stock
CoverBrowser or ZenOS. Also after any other Menu listing books by path:
ZenOS's Authors, Series and Tags pages are Menus. Only the items on the page
shown are looked at. The cover's position comes from the ImageWidget that
drew it. In KOReader's plain list (no CoverBrowser) the badge goes before
the name: Badge.decorate gives those rows an indent to make room for it.

ZenOS's Home page isn't a list: its rows (strips, featured book) build each
cover with cover_common.make_cover_widget. Covers built for Home get the
badge painted after the cover (and ZenOS's own badges on it), at paint
time, so setting changes and downloads show on the next redraw.
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
    cloudState = nil, -- function(path) -> "complete", "reading", "abandoned" or nil
    installed = false,
}

-- The plugin's own cloud icons (KOReader has none).
local ICONS = (debug.getinfo(1, "S").source:match("^@(.*)/cloudlibrary/[^/]*$") or ".") .. "/icons/"
local CLOUD_ICON = ICONS .. "cloud.svg"
local CLOUD_OFF_ICON = ICONS .. "cloud-off.svg"
local KIND_ICONS = {
    cloud = CLOUD_ICON,
    noncloud = CLOUD_OFF_ICON,
    ["cloud-complete"] = ICONS .. "cloud-finished.svg",
    ["cloud-reading"] = ICONS .. "cloud-reading.svg",
    ["cloud-abandoned"] = ICONS .. "cloud-on-hold.svg",
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
            kind == "local"
                and IconWidget:new{ icon = "check", width = icon, height = icon }
                or IconWidget:new{ file = KIND_ICONS[kind] or CLOUD_ICON,
                    alpha = true, width = icon, height = icon },
        },
    }
    widgets[key] = w
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

--- Plain list rows: the badge's size, and the room reserved before the name.
function Badge.plainSize()
    return Screen:scaleBySize(20), Screen:scaleBySize(28)
end

--- Makes room for the badge in a plain list row (other views ignore indent).
function Badge.decorate(item)
    if item.path and Badge.kind(item.path) then
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

--- Where the badge goes for a cover (or item) rectangle, and its size.
function Badge.place(rect)
    local min_size, max_size = Screen:scaleBySize(14), Screen:scaleBySize(30)
    local size = math.floor(math.min(rect.w, rect.h) * 0.2)
    size = math.max(min_size, math.min(max_size, size))
    local margin = math.max(2, math.floor(size / 5))
    return rect.x + rect.w - size - margin, rect.y + rect.h - size - margin, size
end

local CLOUD_STATES = { complete = "cloud-complete", reading = "cloud-reading", abandoned = "cloud-abandoned" }

--- Which badge a path gets: "cloud" (or "cloud-<status>"), "local",
-- "noncloud" or nil.
function Badge.kind(path)
    if Badge.cloud_enabled and Badge.isCloud and Badge.isCloud(path) then
        local status = Badge.cloudState and Badge.cloudState(path)
        return CLOUD_STATES[status] or "cloud"
    end
    if Badge.local_enabled and Badge.isOnDevice and Badge.isOnDevice(path) then return "local" end
    if Badge.noncloud_enabled and Badge.isNonCloud and Badge.isNonCloud(path) then return "noncloud" end
end

function Badge.paintOn(menu, bb)
    if not ((Badge.cloud_enabled or Badge.local_enabled or Badge.noncloud_enabled)
            and menu.item_group) then return end
    eachItem(menu.item_group, function(item, path)
        local kind = Badge.kind(path)
        if not kind then return end
        local cover = coverRect(item, 0, {})
        local text = not cover and plainText(item)
        if text then
            -- Plain row: before the name, if the row made room for it.
            if (item.entry.indent or 0) <= 0 then return end
            local size = math.min(Badge.plainSize(), math.floor(text.h * 0.8))
            badgeWidget(size, kind):paintTo(bb, text.x, text.y + math.floor((text.h - size) / 2))
            return
        end
        local rect = cover or item.dimen
        if rect.w < 20 or rect.h < 20 then return end
        local x, y, size = Badge.place(rect)
        badgeWidget(size, kind):paintTo(bb, x, y)
    end, 0, {})
end

-- Home covers ---------------------------------------------------------------------

local HOME_COVERS = "modules/filebrowser/patches/home/widgets/cover_common"

-- True when make_cover_widget was called for Home (its strips and featured
-- book), not the file browser or the book switcher, which use it too.
local function forHome()
    for level = 3, 10 do
        local info = debug.getinfo(level, "S")
        if not info then return false end
        local src = info.source
        if type(src) == "string" and src:find("/patches/home/widgets/", 1, true)
                and not src:find("/cover_common.lua", 1, true) then
            return true
        end
    end
    return false
end

local function badgeHomeCover(frame, path)
    if frame._cloudlibrary_badge then return end
    frame._cloudlibrary_badge = true
    local orig = frame.paintTo
    frame.paintTo = function(self, bb, x, y)
        orig(self, bb, x, y)
        local Guard = require("cloudlibrary/guard")
        if not Guard.ok("badge") then return end
        local ok, err = pcall(function()
            local kind = Badge.kind(path)
            if not kind then return end
            local size = self:getSize()
            if not (size and size.w >= 20 and size.h >= 20) then return end
            local bx, by, badge = Badge.place({ x = x, y = y, w = size.w, h = size.h })
            badgeWidget(badge, kind):paintTo(bb, bx, by)
        end)
        if not ok then Guard.fail("badge", "Home cover badge", err) end
    end
end

--- Badges on ZenOS's Home covers. False when ZenOS's cover builder isn't
-- there (Home then has no badges; nothing else changes).
function Badge.installHome()
    local ok, covers = pcall(require, HOME_COVERS)
    if not ok or type(covers) ~= "table" or type(covers.make_cover_widget) ~= "function" then
        require("logger").warn("CloudLibrary: no badges on Home: ZenOS's cover builder not found")
        return false
    end
    local Guard = require("cloudlibrary/guard")
    local function pack(...) return { n = select("#", ...), ... } end
    Guard.hook("badge", covers, "make_cover_widget", function(orig, book, ...)
        local r = pack(orig(book, ...))
        local frame = r[1]
        if type(book) == "table" and type(book.path) == "string" and type(frame) == "table"
                and type(frame.paintTo) == "function" and forHome() then
            badgeHomeCover(frame, book.path)
        end
        return unpack(r, 1, r.n)
    end, "ZenOS cover_common.make_cover_widget")
    return true
end

function Badge.install()
    if Badge.installed then return end
    local Guard = require("cloudlibrary/guard")
    if not Guard.ok("badge") then return end -- failed the startup check
    Badge.installed = true
    -- FileChooser extends BookList, so wrapping BookList covers both (older
    -- KOReader versions have no BookList: wrap FileChooser there).
    local ok, cls = pcall(require, "ui/widget/booklist")
    if not (ok and type(cls) == "table") then cls = require("ui/widget/filechooser") end
    Guard.hook("badge", cls, "paintTo", function(orig, self, bb, x, y)
        orig(self, bb, x, y)
        Badge.paintOn(self, bb)
    end, "BookList:paintTo")
    -- BookList now has its own paintTo, so its lists aren't badged twice.
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    if ok_menu and type(Menu) == "table" and Menu ~= cls and rawget(cls, "paintTo") then
        Guard.hook("badge", Menu, "paintTo", function(orig, self, bb, x, y)
            orig(self, bb, x, y)
            Badge.paintOn(self, bb)
        end, "Menu:paintTo")
    end
    Badge.installHome()
end

return Badge
