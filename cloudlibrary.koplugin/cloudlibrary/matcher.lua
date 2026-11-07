--[[
Links files in the library folder to catalog books, so a book that's on the
device isn't also listed as a cloud book.

Matcher.scan(folder, store)     reads what it needs from new or changed
                                files (EPUB metadata) into the store's
                                local_files table. Slow the first time; run
                                it in a subprocess.
Matcher.match(folder, files, books)
                                cheap: uses scanned info, or the file name
                                for files not scanned yet. Returns
                                { [uuid] = path } and a list of local files
                                that matched nothing.

How a file matches a book, in order:
1. a UUID in the EPUB's identifiers equals the book's ID (Calibre writes
   its book UUID into the EPUB; Calibre-Web uses it as the OPDS entry ID);
2. title and first author (from the EPUB, or from KOReader's OPDS file name
   "Author - Title.ext");
3. title alone, if exactly one catalog book has that title.
Each catalog book matches at most one file.
Only files directly in the folder are considered.
]]

local lfs = require("libs/libkoreader-lfs")
local Feed = require("cloudlibrary/feed")

local Matcher = {}

local BOOK_EXTENSIONS = {
    epub = true, kepub = true, pdf = true, cbz = true, cbr = true, mobi = true,
    azw = true, azw3 = true, fb2 = true, djvu = true, txt = true, docx = true,
}

--- Lowercase, ASCII punctuation to spaces, single spaces.
function Matcher.normalize(s)
    if type(s) ~= "string" then return "" end
    s = s:lower():gsub("[%p%c]", " "):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end
local normalize = Matcher.normalize

local function extension(name)
    local ext = name:match("%.([^.]+)$")
    ext = ext and ext:lower()
    if ext == "epub" and name:lower():match("%.kepub%.epub$") then ext = "kepub" end
    return ext
end

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function readEpub(path)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(path) then return nil end
    for _entry in arc:iterate() do end -- index the entries
    local container = arc:extractToMemory("META-INF/container.xml")
    local opf_path = container and container:match('full%-path%s*=%s*"([^"]+)"')
    local opf = opf_path and arc:extractToMemory(opf_path)
    arc:close()
    if not opf then return nil end
    local info = { uuids = {}, authors = {} }
    for value in opf:gmatch("<dc:identifier[^>]*>%s*([^<]-)%s*</dc:identifier>") do
        -- Calibre 6 writes the bare UUID, Calibre 9 "uuid:...", others "urn:uuid:...".
        value = Feed.unescape(value):lower():gsub("^urn:", ""):gsub("^uuid:", "")
        if value:match(UUID) then table.insert(info.uuids, value) end
    end
    info.title = opf:match("<dc:title[^>]*>%s*([^<]-)%s*</dc:title>")
    info.title = info.title and Feed.unescape(info.title)
    for creator in opf:gmatch("<dc:creator[^>]*>%s*([^<]-)%s*</dc:creator>") do
        table.insert(info.authors, Feed.unescape(creator))
    end
    return info
end

--- "Author - Title" (KOReader's OPDS download name), or just a title.
function Matcher.fromFilename(name)
    local stem = name:gsub("%.kepub%.epub$", ""):gsub("%.[^.]+$", "")
    local author, title = stem:match("^(.-) %- (.+)$")
    if author then return { title = title, authors = { author }, uuids = {} } end
    return { title = stem, authors = {}, uuids = {} }
end

local function eachBookFile(folder, fn)
    local ok, iter, dir = pcall(lfs.dir, folder)
    if not ok then return end
    for name in iter, dir do
        if name:sub(1, 1) ~= "." then
            local ext = extension(name)
            if ext and BOOK_EXTENSIONS[ext] then
                local path = folder .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "file" then fn(path, name, ext, attr) end
            end
        end
    end
end

--- Updates the store's local_files for the folder. Returns how many files
-- were read, and how many were gone.
function Matcher.scan(folder, store)
    local known = store:localFiles()
    local present, read = {}, 0
    eachBookFile(folder, function(path, name, ext, attr)
        present[path] = true
        local cached = known[path]
        if cached and cached.mtime == attr.modification and cached.size == attr.size then return end
        local info
        if ext == "epub" or ext == "kepub" then
            local ok, res = pcall(readEpub, path)
            info = ok and res or nil
        end
        info = info or Matcher.fromFilename(name)
        info.mtime, info.size = attr.modification, attr.size
        store:setLocalFile(path, info)
        read = read + 1
    end)
    local removed = 0
    for path in pairs(known) do
        if not present[path] then
            store:removeLocalFile(path)
            removed = removed + 1
        end
    end
    return read, removed
end

--- Returns { [uuid] = path }, { unmatched local paths }.
function Matcher.match(folder, files, books)
    local by_uuid, by_title_author, by_title = {}, {}, {}
    for _i, b in ipairs(books) do
        by_uuid[b.id:lower()] = b.id
        local t = normalize(b.title)
        if t ~= "" then
            local a = normalize(b.authors and b.authors[1])
            by_title_author[t .. "\0" .. a] = by_title_author[t .. "\0" .. a] or b.id
            if by_title[t] == nil then by_title[t] = b.id else by_title[t] = false end
        end
    end
    local matched, unmatched = {}, {}
    eachBookFile(folder, function(path, name, _ext, attr)
        local info = files and files[path]
        if not (info and info.mtime == attr.modification and info.size == attr.size) then
            info = Matcher.fromFilename(name)
        end
        local id
        for _j, u in ipairs(info.uuids or {}) do
            id = by_uuid[u:lower()]
            if id then break end
        end
        local t = normalize(info.title)
        if not id and t ~= "" then
            for _j, author in ipairs(info.authors or {}) do
                id = by_title_author[t .. "\0" .. normalize(author)]
                if id then break end
            end
            -- File names may hold several authors ("A, B - Title"), so fall
            -- back to the title when only one catalog book has it.
            if not id then id = by_title[t] or nil end
        end
        if id and not matched[id] then
            matched[id] = path
        else
            table.insert(unmatched, path)
        end
    end)
    return matched, unmatched
end

return Matcher
