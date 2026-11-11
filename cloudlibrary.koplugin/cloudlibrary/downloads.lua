--[[
Downloading cloud books into the library folder, one at a time, in a
subprocess.

Files are named like KOReader's OPDS downloads ("Author, Author - Title.ext"),
written to a ".part" file and renamed when complete. The file's date is set
to the date the book was added to the library, so sorting by date keeps it
where its cloud entry was.
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Downloads = {
    job = nil,   -- { pid, fd, req, t0 }
    queue = {},
}

-- Preferred formats, best first; anything else comes after.
Downloads.PREFERRED = { "epub", "kepub", "pdf", "cbz", "cbr", "azw3", "mobi", "azw", "fb2", "djvu", "txt" }

local TYPE_EXT = {
    ["application/epub+zip"] = "epub",
    ["application/kepub+zip"] = "kepub",
    ["application/pdf"] = "pdf",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbz"] = "cbz",
    ["application/vnd.comicbook-rar"] = "cbr",
    ["application/x-cbr"] = "cbr",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/x-mobi8-ebook"] = "azw3",
    ["application/vnd.amazon.ebook"] = "azw",
    ["application/fb2"] = "fb2",
    ["application/x-fictionbook+xml"] = "fb2",
    ["image/vnd.djvu"] = "djvu",
    ["image/x-djvu"] = "djvu",
    ["text/plain"] = "txt",
}

--- File extension for an acquisition link ({ type, href }).
function Downloads.extension(format)
    local t = (format.type or ""):lower():gsub("%s*;.*$", "")
    local ext = TYPE_EXT[t]
    if not ext and format.href then
        ext = format.href:match("/download/%d+/([%w]+)/?$") or format.href:match("%.([%w]+)$")
        ext = ext and ext:lower()
    end
    return ext
end

--- The book's formats, best first, each with .ext.
function Downloads.choices(formats)
    local rank = {}
    for i, ext in ipairs(Downloads.PREFERRED) do rank[ext] = i end
    local out = {}
    for _i, f in ipairs(formats or {}) do
        local ext = Downloads.extension(f)
        if ext then
            table.insert(out, { ext = ext, type = f.type, href = f.href, size = f.size })
        end
    end
    table.sort(out, function(a, b)
        return (rank[a.ext] or 100) < (rank[b.ext] or 100)
    end)
    return out
end

--- "Author, Author - Title.ext", safe for the folder, not overwriting a file.
function Downloads.fileName(book, ext, folder)
    local name = book.title or book.id
    if book.authors and #book.authors > 0 then
        name = table.concat(book.authors, ", ") .. " - " .. name
    end
    -- As KOReader's OPDS plugin: replace characters FAT can't store, always.
    -- KOReader opens a KEPUB as "….kepub.epub"; ".kepub" alone it doesn't know.
    if ext == "kepub" then ext = "kepub.epub" end
    name = util.getSafeFilename(util.replaceAllInvalidChars(name) .. "." .. ext, folder)
    local base, suffix = name:match("^(.*)(%.kepub%.epub)$")
    if not base then base, suffix = name:match("^(.*)(%.[^.]+)$") end
    local candidate, n = name, 1
    while lfs.attributes(folder .. "/" .. candidate) do
        n = n + 1
        candidate = string.format("%s (%d)%s", base, n, suffix)
    end
    return candidate
end

--- Runs in the subprocess: download to a .part file, then rename.
-- download(url, path) -> true or nil, err.
function Downloads.fetch(download, url, path)
    local part = path .. ".part"
    local ok, err = download(url, part)
    if not ok then
        os.remove(part)
        return nil, err
    end
    local size = lfs.attributes(part, "size") or 0
    if size == 0 then
        os.remove(part)
        return nil, "The server sent an empty file."
    end
    if lfs.attributes(path) then
        os.remove(part)
        return nil, "A file with that name appeared meanwhile: " .. path
    end
    local renamed, rerr = os.rename(part, path)
    if not renamed then
        os.remove(part)
        return nil, tostring(rerr)
    end
    return { path = path, size = size }
end

--- After a download, in the UI process: set the file's date to when the
-- book was added, and return the file's attributes.
function Downloads.finish(path, book)
    if book.added then lfs.touch(path, book.added, book.added) end
    return lfs.attributes(path)
end

-- In the UI process --------------------------------------------------------------

function Downloads.busy()
    return Downloads.job ~= nil
end

function Downloads.isQueued(id)
    if Downloads.job and Downloads.job.req.book.id == id then return true end
    for _i, req in ipairs(Downloads.queue) do
        if req.book.id == id then return true end
    end
    return false
end

local start
local poll

local function pollDownload()
    local job = Downloads.job
    if not job then return end
    local ffiutil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    if not ffiutil.isSubProcessDone(job.pid) then
        UIManager:scheduleIn(0.5, poll)
        return
    end
    local data = ffiutil.readAllFromFD(job.fd)
    local result
    local chunk = data and data ~= "" and loadstring("return " .. data, "download result")
    if chunk then
        setfenv(chunk, {})
        local ok, res = pcall(chunk)
        result = ok and type(res) == "table" and res or nil
    end
    result = result or { error = "the download stopped unexpectedly" }
    result.ms = require("cloudlibrary/timing").since(job.t0)
    Downloads.job = nil
    local ok, err = pcall(job.req.on_done, result)
    if not ok then logger.warn("CloudLibrary: after download:", err) end
    local next_req = table.remove(Downloads.queue, 1)
    if next_req then start(next_req) end
end

poll = function() return require("cloudlibrary/guard").call("jobs", pollDownload) end

start = function(req)
    local ffiutil = require("ffi/util")
    local server, url, path = req.server, req.url, req.path
    local pid, fd = ffiutil.runInSubProcess(function(_pid, child_fd)
        local Http = require("cloudlibrary/http")
        local ok, res, err = pcall(Downloads.fetch, function(u, p) return Http.download(server, u, p) end,
            url, path)
        local result
        if not ok then
            result = { error = tostring(res) }
        elseif not res then
            result = { error = err }
        else
            result = res
        end
        ffiutil.writeToFD(child_fd, require("dump")(result), true)
    end, true)
    if not pid then
        req.on_done({ error = "can't start the download: " .. tostring(fd) })
        return
    end
    Downloads.job = { pid = pid, fd = fd, req = req, t0 = require("cloudlibrary/timing").start() }
    require("ui/uimanager"):scheduleIn(0.5, poll)
end

--- Queues a download. req: { server, url, path, book, on_done(result) }
-- where result is { path, size, ms } or { error, ms }.
function Downloads.start(req)
    if Downloads.job then
        table.insert(Downloads.queue, req)
    else
        start(req)
    end
end

return Downloads
