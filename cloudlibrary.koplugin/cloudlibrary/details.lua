--[[
The details sheet for a cloud book, drawn like ZenOS's long-press book menu:
the cover beside the title, authors and series, then one action per row
(icon + label, left-aligned, in ZenOS's library font). ZenOS's helpers are
looked up when the sheet opens; anything missing falls back to KOReader's
own fonts and borders.
]]

local Device = require("device")
local _ = require("gettext")

local Details = {}

local function zen(name)
    local ok, mod = pcall(require, name)
    return ok and type(mod) == "table" and mod or nil
end

--- ZenOS's inline glyph for an action ("download", "reading"...), or nil.
function Details.icon(name)
    local icons = zen("common/inline_icon_map")
    return icons and icons[name] or nil
end

--- "<glyph>  label", as ZenOS writes its menu rows (it moves the glyph into
-- an aligned icon column and draws it as an SVG).
function Details.label(icon_name, text)
    local glyph = Details.icon(icon_name)
    return glyph and (glyph .. "  " .. text) or text
end

local function fontFace(size)
    local library_font = zen("modules/filebrowser/patches/library_font")
    if library_font and library_font.getFace then
        local ok, face = pcall(library_font.getFace, size)
        if ok and face then return face end
    end
    return require("ui/font"):getFace("cfont", size)
end

-- Buttons in the library font, as ZenOS's apply_button_group_font does.
local function applyFont(rows)
    local library_font = zen("modules/filebrowser/patches/library_font")
    if not (library_font and library_font.scaleValue and library_font.getFontName) then return rows end
    local ok, size = pcall(library_font.scaleValue, 20)
    local ok2, name = pcall(library_font.getFontName)
    if not (ok and ok2 and size and name) then return rows end
    for _i, row in ipairs(rows) do
        for _j, btn in ipairs(row) do
            if type(btn.text) == "string" then
                btn.font_face, btn.font_size = name, size
                btn.text_font_face, btn.text_font_size = name, size
            end
        end
    end
    return rows
end

local function showCoverFullscreen(image_file)
    local UIManager = require("ui/uimanager")
    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        file = image_file,
        fullscreen = true,
        with_title_bar = false,
    }
    viewer.onTap = function(self)
        self:onClose()
        return true
    end
    UIManager:show(viewer)
end

-- Cover as ZenOS draws it in its book menu: CoverUtils.makeCover reads the
-- cover through BookInfoManager (which asks our book source) and falls back
-- to ZenOS's generated placeholder.
local function coverWidget(path, image_file, max_h)
    local Screen = Device.screen
    local Cover = zen("common/cover_utils")
    if not (Cover and Cover.makeCover and Cover.getRatio) then return nil end
    local max_w = math.floor(max_h * Cover.getRatio())
    local ok, bb, w, h = pcall(Cover.makeCover, path, nil, {
        is_folder = false, width = max_w, height = max_h,
    })
    if not (ok and bb and w and h) then return nil end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local border = Cover.BORDER_SIZE or Screen:scaleBySize(1)
    local frame = FrameContainer:new{
        padding = 0,
        bordersize = border,
        ImageWidget:new{ image = bb, image_disposable = true, scale_factor = 1.0 },
    }
    local common = zen("modules/filebrowser/patches/home/widgets/cover_common")
    if common and common.decorate_cover_frame then pcall(common.decorate_cover_frame, frame) end
    local framed_w, framed_h = w + 2 * border, h + 2 * border
    if not image_file then return frame, framed_w, framed_h end

    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local wrapper = InputContainer:new{
        dimen = Geom:new{ w = framed_w, h = framed_h },
        frame,
    }
    if Device:isTouchDevice() then
        wrapper.ges_events = {
            TapCover = { GestureRange:new{ ges = "tap", range = function() return wrapper.dimen end } },
        }
        function wrapper:onTapCover()
            showCoverFullscreen(image_file)
            return true
        end
    end
    return wrapper, framed_w, framed_h
end

--[[ Show the sheet.
info = {
    path, cover_file (image on disk or nil),
    title, authors, series, facts, state, summary: strings or nil,
    buttons: ButtonDialog rows,
}
Returns the dialog.
]]
function Details.show(info)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen

    -- Same widths as ZenOS's book menu (a 0.9 ButtonDialog).
    local dialog_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local avail_w = dialog_w - 2 * (Size.border.window + Size.padding.button)
        - 2 * (Size.padding.default + Size.margin.default)
    local gap = Screen:scaleBySize(8)
    local gray = Blitbuffer.COLOR_GRAY_3

    local cover, cover_w, cover_h = coverWidget(info.path, info.cover_file, Screen:scaleBySize(140))
    local text_w = cover and math.max(avail_w - cover_w - gap, Screen:scaleBySize(60)) or avail_w

    local column = VerticalGroup:new{ align = "left" }
    local function line(text, size, opts)
        if not text or text == "" then return end
        opts = opts or {}
        if #column > 0 then
            table.insert(column, VerticalSpan:new{ width = Screen:scaleBySize(opts.space or 2) })
        end
        table.insert(column, TextWidget:new{
            text = text,
            face = fontFace(size),
            bold = opts.bold,
            fgcolor = opts.gray and gray or nil,
            max_width = text_w,
        })
    end
    local BD = require("ui/bidi")
    line(info.title and BD.auto(info.title), 20, { bold = true })
    line(info.authors and BD.auto(info.authors), 17)
    line(_("Cloud library"), 14, { gray = true })
    line(info.series and BD.auto(info.series), 17, { gray = true })
    line(info.facts, 14, { gray = true, space = 3 })
    line(info.state, 14, { gray = true, space = 3 })

    local header
    if cover then
        header = LeftContainer:new{
            dimen = Geom:new{ w = avail_w, h = math.max(cover_h, column:getSize().h) },
            HorizontalGroup:new{
                align = "center",
                cover,
                HorizontalSpan:new{ width = gap },
                column,
            },
        }
    else
        header = column
    end

    local added = { header }
    if info.summary then
        local text_group = VerticalGroup:new{
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
            TextBoxWidget:new{
                text = info.summary,
                face = fontFace(14),
                fgcolor = gray,
                width = avail_w,
            },
        }
        text_group.not_focusable = true
        table.insert(added, text_group)
    end
    header.not_focusable = true

    local dialog = ButtonDialog:new{
        buttons = applyFont(info.buttons),
        _added_widgets = added,
    }
    UIManager:show(dialog)
    return dialog
end

return Details
