--[[--
The server side of Settings sync: small Dropbox and WebDAV clients, and a
plain folder (used by the tests), all with the same methods. Paths are
relative to the sync folder on the server and use "/".

    remote:get(path, local_path)        → true, version | nil, "not_found" or error
    remote:put(path, local_path, opts)  → true, version | nil, "conflict" or error
        opts.version: replace only if the server still has this version
        opts.create:  create only if there's no file there yet
    remote:delete(path)                 → true | nil, error (a missing file is fine)
    remote:list(folder)                 → { [path] = { size, fp } } | nil, error
        every file under the folder, recursively; fp changes when the file does
    remote:mkdirs(folder)               → true | nil, error

Logins come from KOReader's Cloud storage servers (settings/cloudstorage.lua).
This runs in a separate process during a sync, so it doesn't touch the UI.
--]]--

local Remote = {}

-- JSON ------------------------------------------------------------------

-- Dropbox-API-Arg is an HTTP header, so it must be ASCII: everything else
-- is written as \u escapes.
local function utf8Codepoints(s)
    local i, n, out = 1, #s, {}
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
        local cp = len == 1 and c or c % (2 ^ (7 - len))
        for k = 1, len - 1 do
            cp = cp * 64 + ((s:byte(i + k) or 0x80) % 64)
        end
        table.insert(out, cp)
        i = i + len
    end
    return out
end

local function jsonString(s)
    local out = { '"' }
    for _, cp in ipairs(utf8Codepoints(s)) do
        if cp == 34 then table.insert(out, '\\"')
        elseif cp == 92 then table.insert(out, "\\\\")
        elseif cp >= 32 and cp < 127 then table.insert(out, string.char(cp))
        elseif cp < 0x10000 then table.insert(out, string.format("\\u%04x", cp))
        else
            cp = cp - 0x10000
            table.insert(out, string.format("\\u%04x\\u%04x",
                0xD800 + math.floor(cp / 0x400), 0xDC00 + cp % 0x400))
        end
    end
    table.insert(out, '"')
    return table.concat(out)
end

--- Encode strings, numbers, booleans and tables with string keys (objects).
function Remote.jsonEncode(v)
    local t = type(v)
    if t == "string" then return jsonString(v)
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do table.insert(keys, k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do
            table.insert(parts, jsonString(k) .. ":" .. Remote.jsonEncode(v[k]))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function utf8Char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

--- Decode JSON. Returns the value, or nil and an error.
function Remote.jsonDecode(s)
    local pos = 1
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local a = s:find('["\\]', pos)
            if not a then error("unterminated string") end
            table.insert(out, s:sub(pos, a - 1))
            if s:sub(a, a) == '"' then pos = a + 1 break end
            local e = s:sub(a + 1, a + 1)
            local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if e == "u" then
                local cp = tonumber(s:sub(a + 2, a + 5), 16)
                pos = a + 6
                if cp >= 0xD800 and cp < 0xDC00 and s:sub(pos, pos + 1) == "\\u" then
                    local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    pos = pos + 6
                end
                table.insert(out, utf8Char(cp))
            else
                table.insert(out, simple[e] or e)
                pos = a + 2
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            local obj = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
            while true do
                ws()
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then error("expected :") end
                pos = pos + 1
                obj[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then error("expected , or }") end
            end
        elseif c == "[" then
            local arr = {}
            pos = pos + 1
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return arr end
            while true do
                table.insert(arr, value())
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then error("expected , or ]") end
            end
        elseif c == '"' then return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then error("unexpected " .. c) end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local ok, result = pcall(value)
    if ok then return result end
    return nil, result
end

-- HTTP ------------------------------------------------------------------

local function fileSize(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:close()
    return size
end

--- One HTTP request. opts: url, method, headers, body (string),
--- source_path (upload a file), sink_path (download into a file).
--- Returns code (a number), headers (lower-case keys), body; or nil, error.
--- (Replaced in the tests.)
function Remote.request(opts)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    local source
    if opts.source_path then
        local file = io.open(opts.source_path, "rb")
        if not file then return nil, "can't read " .. opts.source_path end
        headers["Content-Length"] = tostring(fileSize(opts.source_path))
        source = ltn12.source.file(file)
    elseif opts.body then
        headers["Content-Length"] = tostring(#opts.body)
        source = ltn12.source.string(opts.body)
    end
    local chunks = {}
    local sink
    if opts.sink_path then
        local file = io.open(opts.sink_path, "wb")
        if not file then return nil, "can't write " .. opts.sink_path end
        sink = ltn12.sink.file(file)
    else
        sink = ltn12.sink.table(chunks)
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = opts.url,
        method = opts.method,
        headers = headers,
        source = source,
        sink = sink,
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        return nil, tostring(status or code)
    end
    return code, resp_headers or {}, table.concat(chunks)
end

local function base64(s)
    return require("ffi/sha2").bin_to_base64(s)
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function joinPath(a, b)
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end

--- "/KOReader/Settings/" → "/KOReader/Settings"; "" and "/" → "".
local function normalizeRoot(root)
    root = (root or ""):gsub("/+$", "")
    if root ~= "" and root:sub(1, 1) ~= "/" then root = "/" .. root end
    return root
end

-- Dropbox's content hash ---------------------------------------------------

local BLOCK = 4 * 1024 * 1024

local function hexToBin(hex)
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function sha256sum(cmd)
    local pipe = io.popen(cmd .. " 2>/dev/null")
    if not pipe then return nil end
    local out = pipe:read("*a") or ""
    pipe:close()
    local hash = out:match("^(%x+)")
    return hash and #hash == 64 and hash or nil
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--- The hash Dropbox lists for a file: SHA-256 of the SHA-256 of each 4 MB
--- block. With sha256sum where there is one (fast), KOReader's own
--- otherwise. tmp_path is a scratch file. Returns hex, or nil.
function Remote.dropboxContentHash(path, tmp_path)
    local size = fileSize(path)
    if not size then return nil end
    local digests = {}
    local blocks = math.ceil(size / BLOCK)
    local fast = sha256sum("printf '' | sha256sum") ~= nil
    if fast then
        for i = 0, blocks - 1 do
            local hex = sha256sum("dd if=" .. shq(path) .. " bs=" .. BLOCK .. " skip=" .. i
                .. " count=1 2>/dev/null | sha256sum")
            if not hex then fast = false break end
            table.insert(digests, hexToBin(hex))
        end
    end
    if fast then
        local file = io.open(tmp_path, "wb")
        if not file then return nil end
        file:write(table.concat(digests))
        file:close()
        local hex = sha256sum("sha256sum " .. shq(tmp_path))
        os.remove(tmp_path)
        return hex
    end
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok or not sha2.sha256 then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    digests = {}
    while true do
        local block = file:read(BLOCK)
        if not block then break end
        table.insert(digests, hexToBin(sha2.sha256(block)))
    end
    file:close()
    return sha2.sha256(table.concat(digests))
end

-- Dropbox ---------------------------------------------------------------

local Dropbox = {}
Dropbox.__index = Dropbox

local DROPBOX_API = "https://api.dropboxapi.com/2/"
local DROPBOX_CONTENT = "https://content.dropboxapi.com/2/"

function Dropbox:auth()
    if self.token then return true end
    local server = self.server
    -- As Cloud storage keeps them: a refresh token in password and
    -- <app key>:<app secret> in address, or a long-lived token in password.
    if server.address and server.address ~= "" then
        local body = "grant_type=refresh_token&refresh_token=" .. (server.password or "")
        local code, _, resp = Remote.request{
            url = "https://api.dropbox.com/oauth2/token",
            method = "POST",
            headers = {
                ["Authorization"] = "Basic " .. base64(server.address),
                ["Content-Type"] = "application/x-www-form-urlencoded",
            },
            body = body,
        }
        local data = code == 200 and Remote.jsonDecode(resp)
        if not (data and data.access_token) then
            return nil, "Dropbox login failed (" .. tostring(code) .. ")"
        end
        self.token = data.access_token
    else
        self.token = server.password
    end
    return true
end

function Dropbox:path(rel)
    return joinPath(self.root, rel)
end

function Dropbox:call(endpoint, args)
    local ok, err = self:auth()
    if not ok then return nil, err end
    local code, headers, body = Remote.request{
        url = DROPBOX_API .. endpoint,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Content-Type"] = "application/json",
        },
        body = Remote.jsonEncode(args),
    }
    if not code then return nil, headers end
    return code, Remote.jsonDecode(body) or {}, body
end

local function summary(data, text)
    return (type(data) == "table" and data.error_summary) or text or ""
end

function Dropbox:get(rel, local_path)
    local ok, err = self:auth()
    if not ok then return nil, err end
    local code, headers = Remote.request{
        url = DROPBOX_CONTENT .. "files/download",
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Dropbox-API-Arg"] = Remote.jsonEncode({ path = self:path(rel) }),
        },
        sink_path = local_path,
    }
    if code == 200 then
        local result = Remote.jsonDecode(headers["dropbox-api-result"] or "") or {}
        return true, result.rev
    end
    local text = code and readFile(local_path)
    os.remove(local_path)
    if code == 409 and summary(Remote.jsonDecode(text or ""), text):find("not_found") then
        return nil, "not_found"
    end
    return nil, "download failed (" .. tostring(code or headers) .. ") " .. (text or "")
end

function Dropbox:put(rel, local_path, opts)
    opts = opts or {}
    local ok, err = self:auth()
    if not ok then return nil, err end
    local mode = "overwrite"
    if opts.version then
        mode = { [".tag"] = "update", update = opts.version }
    elseif opts.create then
        mode = "add"
    end
    local code, headers, body = Remote.request{
        url = DROPBOX_CONTENT .. "files/upload",
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Content-Type"] = "application/octet-stream",
            ["Dropbox-API-Arg"] = Remote.jsonEncode({
                path = self:path(rel), mode = mode, autorename = false,
                mute = true, strict_conflict = true,
            }),
        },
        source_path = local_path,
    }
    if code == 200 then
        return true, (Remote.jsonDecode(body) or {}).rev
    end
    if code == 409 and summary(Remote.jsonDecode(body or ""), body):find("conflict") then
        return nil, "conflict"
    end
    return nil, "upload failed (" .. tostring(code or headers) .. ") " .. (body or "")
end

function Dropbox:delete(rel)
    local code, data, body = self:call("files/delete_v2", { path = self:path(rel) })
    if code == 200 then return true end
    if code == 409 and summary(data, body):find("not_found") then return true end
    return nil, "delete failed (" .. tostring(code or data) .. ") " .. summary(data, body)
end

function Dropbox:list(rel)
    local prefix = self:path(rel)
    local code, data, body = self:call("files/list_folder", { path = prefix, recursive = true })
    if code == 409 and summary(data, body):find("not_found") then return {} end
    local files = {}
    while true do
        if code ~= 200 then
            return nil, "listing failed (" .. tostring(code or data) .. ") " .. summary(data, body)
        end
        for _, entry in ipairs(data.entries or {}) do
            local path = entry.path_display or ""
            -- Dropbox ignores case, so the folder may be spelled differently.
            if entry[".tag"] == "file" and path:sub(1, #prefix):lower() == prefix:lower() then
                files[path:sub(#prefix + 2)] = {
                    size = tonumber(entry.size), fp = entry.content_hash or entry.rev,
                }
            end
        end
        if not data.has_more then break end
        code, data, body = self:call("files/list_folder/continue", { cursor = data.cursor })
    end
    return files
end

function Dropbox:mkdirs()
    return true -- uploads create folders
end

function Dropbox:contentHash(local_path, tmp_path)
    return Remote.dropboxContentHash(local_path, tmp_path)
end

-- WebDAV ----------------------------------------------------------------

local WebDav = {}
WebDav.__index = WebDav

local function encodePath(path)
    return (path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decodePath(path)
    return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function WebDav:url(rel)
    return self.address .. encodePath(joinPath(self.root, rel))
end

function WebDav:authHeaders(headers)
    headers = headers or {}
    if self.server.username and self.server.username ~= "" then
        headers["Authorization"] = "Basic "
            .. base64(self.server.username .. ":" .. (self.server.password or ""))
    end
    return headers
end

function WebDav:send(method, rel, opts)
    opts = opts or {}
    opts.url = self:url(rel)
    opts.method = method
    opts.headers = self:authHeaders(opts.headers)
    return Remote.request(opts)
end

local function etag(headers)
    local tag = headers and headers.etag
    return tag and tag:gsub("^W/", "") or nil
end

function WebDav:get(rel, local_path)
    local code, headers = self:send("GET", rel, { sink_path = local_path })
    if code == 200 then return true, etag(headers) end
    os.remove(local_path)
    if code == 404 then return nil, "not_found" end
    return nil, "download failed (" .. tostring(code or headers) .. ")"
end

function WebDav:put(rel, local_path, opts)
    opts = opts or {}
    local headers = {}
    if opts.version then
        headers["If-Match"] = opts.version
    elseif opts.create then
        headers["If-None-Match"] = "*"
    end
    local code, resp = self:send("PUT", rel, { headers = headers, source_path = local_path })
    if code == 200 or code == 201 or code == 204 then return true, etag(resp) end
    if code == 412 then return nil, "conflict" end
    return nil, "upload failed (" .. tostring(code or resp) .. ")"
end

function WebDav:delete(rel)
    local code, err = self:send("DELETE", rel)
    if code == 200 or code == 204 or code == 404 then return true end
    return nil, "delete failed (" .. tostring(code or err) .. ")"
end

function WebDav:mkdirs(rel)
    local path = ""
    for part in joinPath(self.root:gsub("^/", ""), rel):gmatch("[^/]+") do
        path = path .. "/" .. part
        if not self.made[path] then
            local code, err = Remote.request{
                url = self.address .. encodePath(path),
                method = "MKCOL",
                headers = self:authHeaders(),
            }
            -- 405: it's there already.
            if code ~= 201 and code ~= 405 and code ~= 200 then
                return nil, "couldn't create folder " .. path .. " (" .. tostring(code or err) .. ")"
            end
            self.made[path] = true
        end
    end
    return true
end

local PROPFIND = [[<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop>]]
    .. [[<d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>]]

local XML_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }

local function xmlText(text)
    return (text:gsub("&(#?x?)(%w+);", function(kind, name)
        if kind == "#" then return string.char(tonumber(name) % 256) end
        if kind == "#x" then return string.char(tonumber(name, 16) % 256) end
        return XML_ENTITIES[name] or ("&" .. name .. ";")
    end))
end

-- A property's text, if it has any.
local function tag(block, name)
    local text = block:match("<[^>]-" .. name .. "[^>]*>(.-)</[^>]-" .. name .. ">")
    if text and text:find("%S") then return xmlText(text) end
end

-- What the server said, briefly, for an error message.
local function serverSays(body)
    local text = (body or ""):gsub("<[^>]*>", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return text ~= "" and ": " .. text:sub(1, 200) or ""
end

function WebDav:listInto(rel, files, base_len, depth)
    local code, err, body = Remote.request{
        -- A folder's URL ends with a slash: some servers insist.
        url = self:url(rel):gsub("/*$", "/"),
        method = "PROPFIND",
        headers = self:authHeaders{ ["Depth"] = "1", ["Content-Type"] = "application/xml" },
        body = PROPFIND,
    }
    if code == 404 then return true end
    if code ~= 207 then
        return nil, "listing " .. joinPath(self.root, rel) .. " failed (" .. tostring(code or err) .. ")"
            .. (code and serverSays(body) or "")
    end
    -- Where hrefs start, as a decoded path: the server may give full URLs.
    local folder = decodePath(self.address:match("^%a+://[^/]+(.*)$") or "")
        .. joinPath(self.root, rel)
    folder = folder:gsub("/+$", "")
    for block in body:gmatch("<[^>]-response[^>]*>(.-)</[^>]-response>") do
        local href = tag(block, "href")
        if href then
            href = decodePath((href:gsub("^%a+://[^/]+", ""))):gsub("/+$", "")
            if href ~= folder and href:sub(1, #folder + 1) == folder .. "/" then
                local child = href:sub(#folder + 2)
                local child_rel = joinPath(rel, child)
                if block:find("<[^>]-collection") then
                    if depth < 32 then
                        local ok, list_err = self:listInto(child_rel, files, base_len, depth + 1)
                        if not ok then return nil, list_err end
                    end
                else
                    local size = tonumber(tag(block, "getcontentlength") or "")
                    local fp = tag(block, "getetag")
                        or (tostring(size) .. ":" .. (tag(block, "getlastmodified") or ""))
                    files[child_rel:sub(base_len + 1)] = { size = size, fp = fp }
                end
            end
        end
    end
    return true
end

function WebDav:list(rel)
    local files = {}
    local base_len = rel == "" and 0 or #rel + 1
    local ok, err = self:listInto(rel, files, base_len, 0)
    if not ok then return nil, err end
    return files
end

-- A plain folder ---------------------------------------------------------

local Folder = {}
Folder.__index = Folder

local function lfs() return require("libs/libkoreader-lfs") end

local function mkdirs(path)
    local sofar = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        sofar = sofar .. "/" .. part
        if not lfs().attributes(sofar) then lfs().mkdir(sofar) end
    end
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return nil, "can't read " .. from end
    local dst = io.open(to, "wb")
    if not dst then src:close() return nil, "can't write " .. to end
    while true do
        local chunk = src:read(65536)
        if not chunk then break end
        dst:write(chunk)
    end
    src:close()
    dst:close()
    return true
end
Remote.copyFile = copyFile

function Folder:full(rel) return joinPath(self.dir, rel) end

function Folder:version(rel)
    local attr = lfs().attributes(self:full(rel))
    if not attr then return nil end
    return self.versioner and self.versioner(self:full(rel)) or (attr.size .. ":" .. attr.modification)
end

function Folder:get(rel, local_path)
    if not lfs().attributes(self:full(rel), "mode") then return nil, "not_found" end
    local ok, err = copyFile(self:full(rel), local_path)
    if not ok then return nil, err end
    return true, self:version(rel)
end

function Folder:put(rel, local_path, opts)
    opts = opts or {}
    local current = self:version(rel)
    if (opts.version and current ~= opts.version) or (opts.create and current) then
        return nil, "conflict"
    end
    mkdirs(self:full(rel):match("^(.*)/[^/]+$"))
    local ok, err = copyFile(local_path, self:full(rel))
    if not ok then return nil, err end
    return true, self:version(rel)
end

function Folder:delete(rel)
    os.remove(self:full(rel))
    return true
end

function Folder:list(rel)
    local files = {}
    local function walk(sub)
        local dir = self:full(joinPath(rel, sub))
        if lfs().attributes(dir, "mode") ~= "directory" then return end
        for name in lfs().dir(dir) do
            if name ~= "." and name ~= ".." then
                local child = joinPath(sub, name)
                local attr = lfs().attributes(dir .. "/" .. name)
                if attr.mode == "directory" then walk(child)
                else
                    files[child] = { size = attr.size, fp = self.dropbox_like
                        and Remote.dropboxContentHash(dir .. "/" .. name, dir .. "/.hash")
                        or attr.size .. ":" .. attr.modification }
                end
            end
        end
    end
    walk("")
    return files
end

function Folder:mkdirs() return true end

function Folder:contentHash(local_path, tmp_path)
    return Remote.dropboxContentHash(local_path, tmp_path)
end

-- -------------------------------------------------------------------------

Remote.TYPES = { dropbox = "Dropbox", webdav = "WebDAV" }

--- A client for a Cloud storage server under the folder root.
function Remote.new(server, root)
    root = normalizeRoot(root)
    if server.type == "dropbox" then
        return setmetatable({ server = server, root = root }, Dropbox)
    elseif server.type == "webdav" then
        return setmetatable({
            server = server, root = root, made = {},
            address = (server.address or ""):gsub("/+$", ""),
        }, WebDav)
    elseif server.type == "folder" then
        local folder = setmetatable({ dir = server.address .. root, versioner = server.versioner,
            dropbox_like = server.dropbox_like }, Folder)
        -- Like Dropbox, list files with their content hash (for the tests).
        if not server.dropbox_like then folder.contentHash = false end
        return folder
    end
    return nil, "Settings sync doesn't support " .. tostring(server.type) .. " servers"
end

return Remote
