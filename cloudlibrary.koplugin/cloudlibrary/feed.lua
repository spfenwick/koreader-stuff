--[[
OPDS 1 (Atom) feed parser. Unlike KOReader's OPDS parser, it keeps every
repeated element (several authors, tags or languages), which a catalog
needs. Uses KOReader's luxl lexer.

Feed.parse(xml) returns:
  {
    next = href or nil,          -- rel="next" link
    books = { book, ... },        -- entries with an acquisition link
    sections = { {title=, href=, id=}, ... }, -- navigation entries
  }
book = { uuid, title, authors = {...}, languages = {...}, tags = {...},
         custom = { [column] = value }, summary, publisher, published (year
         or nil), added (unix time, from <updated>), calibre_id,
         formats = { {type=, href=, size=}, ... }, cover = href or nil }
]]

local ffi = require("ffi")
local luxl = require("luxl")
local util = require("util")

local Feed = {}

local entities = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function unescape(s)
    return (s:gsub("&(#?)([%w]+);", function(hash, name)
        if hash == "" then
            return entities[name]
        end
        local cp = name:sub(1, 1) == "x" and tonumber(name:sub(2), 16) or tonumber(name)
        return cp and util.unicodeCodepointToUtf8(cp)
    end))
end

Feed.unescape = unescape

local function localName(name)
    return name:match(":(.+)$") or name
end

-- Builds a tree of { name, attr = {}, text, children = {} }.
local function tree(text)
    -- The same clean-ups KOReader's OPDS parser needs for luxl.
    text = text:gsub("<%?xml%-stylesheet.-%?>", "")
    text = text:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<!%[CDATA%[(.-)%]%]>", function(s)
        return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
    end)
    text = text:gsub("<([%w:%-_]+)(%s*[^<>]-)/>", "<%1%2></%1>")
    -- <content> may hold (X)HTML; keep it as one text node.
    text = text:gsub("<content([^>]*)>(.-)</content>", function(attrs, s)
        return "<content" .. attrs .. ">" .. s:gsub("[<>]", { ["<"] = "&lt;", [">"] = "&gt;" }) .. "</content>"
    end)

    local lexer = luxl.new(text, #text)
    local root = { name = "#root", attr = {}, children = {} }
    local stack = { root }
    local attr_name
    for event, offset, size in lexer:Lexemes() do
        local s = ffi.string(lexer.buf + offset, size)
        local top = stack[#stack]
        if event == luxl.EVENT_START then
            if s ~= "xml" then
                local node = { name = localName(s), attr = {}, children = {} }
                table.insert(top.children, node)
                table.insert(stack, node)
            end
        elseif event == luxl.EVENT_ATTR_NAME then
            attr_name = localName(s)
        elseif event == luxl.EVENT_ATTR_VAL then
            if attr_name then top.attr[attr_name] = unescape(s) end
            attr_name = nil
        elseif event == luxl.EVENT_TEXT then
            top.text = (top.text or "") .. unescape(s)
        elseif event == luxl.EVENT_END then
            if #stack > 1 then table.remove(stack) end
        end
    end
    return root
end

local function child(node, name)
    for _i, c in ipairs(node.children) do
        if c.name == name then return c end
    end
end

local function childText(node, name)
    local c = child(node, name)
    local text = c and c.text
    if text then
        text = util.trim(text)
        if text ~= "" then return text end
    end
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
local function daysFromCivil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- Parses an Atom date ("2025-04-23T11:28:40+00:00") to unix time.
function Feed.parseTime(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, sec, rest = s:match("^(%d+)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
    if not y then
        y, mo, d = s:match("^(%d+)%-(%d%d)%-(%d%d)$")
        if not y then return nil end
        h, mi, sec, rest = 0, 0, 0, ""
    end
    local t = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == "+" and t - offset or t + offset
    end
    return t
end

local ACQUISITION = "http://opds-spec.org/acquisition"
local IMAGE = "http://opds-spec.org/image"
local THUMBNAIL = "http://opds-spec.org/image/thumbnail"

local function parseEntry(entry)
    local book = {
        title = childText(entry, "title"),
        authors = {}, languages = {}, tags = {}, custom = {}, formats = {},
    }
    local id = childText(entry, "id")
    book.uuid = id and (id:match("^urn:uuid:(.+)$") or id)
    book.added = Feed.parseTime(childText(entry, "updated"))
    local year = (childText(entry, "published") or ""):match("^(%d+)%-")
    year = tonumber(year)
    -- Calibre's "undefined" date is year 101.
    book.published = year and year >= 1000 and year or nil
    book.summary = childText(entry, "summary") or childText(entry, "content")
    local thumbnail, image, subsection
    for _i, c in ipairs(entry.children) do
        if c.name == "author" then
            local name = childText(c, "name")
            if name then table.insert(book.authors, name) end
        elseif c.name == "language" then
            local lang = c.text and util.trim(c.text)
            if lang and lang ~= "" then table.insert(book.languages, lang) end
        elseif c.name == "publisher" then
            book.publisher = childText(c, "name")
        elseif c.name == "category" then
            local scheme = c.attr.scheme or ""
            local column = scheme:match("^custom_column:(.+)$")
            if column then
                book.custom[column] = c.attr.label
            else
                local tag = c.attr.label or c.attr.term
                if tag and tag ~= "" then table.insert(book.tags, tag) end
            end
        elseif c.name == "link" then
            local rel, href = c.attr.rel or "", c.attr.href
            if href then
                if rel == ACQUISITION or rel:find("^" .. ACQUISITION:gsub("%p", "%%%0") .. "/") then
                    table.insert(book.formats, {
                        type = c.attr.type, href = href, size = tonumber(c.attr.length),
                    })
                    book.calibre_id = book.calibre_id
                        or tonumber(href:match("/download/(%d+)/"))
                elseif rel == THUMBNAIL then
                    thumbnail = href
                elseif rel == IMAGE then
                    image = href
                elseif rel == "subsection" or (c.attr.type or ""):find("opds%-catalog") then
                    subsection = subsection or href
                end
            end
        end
    end
    book.cover = thumbnail or image
    return book, subsection
end

function Feed.parse(xml)
    local root = tree(xml)
    local feed = child(root, "feed")
    if not feed then return nil, "not an Atom feed" end
    local result = { books = {}, sections = {} }
    for _i, c in ipairs(feed.children) do
        if c.name == "link" and c.attr.rel == "next" then
            result.next = c.attr.href
        elseif c.name == "entry" then
            local book, subsection = parseEntry(c)
            if #book.formats > 0 then
                table.insert(result.books, book)
            elseif subsection then
                table.insert(result.sections, {
                    title = book.title, href = subsection, id = childText(c, "id"),
                })
            end
        end
    end
    return result
end

return Feed
