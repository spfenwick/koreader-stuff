--[[--
WebDAV transport for statsync.

A transport is an object with:

    list(path)               -> { {name=, is_dir=, size=, etag=}, … } | nil, err, code
    stat(path)               -> { size=, etag= } | nil, err, code
    get(path, local_path)    -> true, { etag= } | nil, err, code
    put(path, local_path)    -> true | nil, err, code     (create or replace)
    put_new(path, local_path)-> true | false (name taken) | nil, err, code
    mkdir(path)              -> true (created or already there) | nil, err, code
    mkdir_root()             -> the same, for the root folder and every
                                missing folder above it (optional; without
                                it, mkdir("") is used)
    delete(path)             -> true | nil, err, code

Paths are relative to the transport's root folder, "/"-separated and not
URL-encoded. put_new never leaves a partial file under `path`: it uploads
to a temporary name in the same folder, then MOVEs it with "Overwrite: F".
A Dropbox transport could map put_new to an upload with mode "add" and
autorename off.

`http` is LuaSocket's socket.http (or anything with the same request()).
Credentials only go into the Authorization header; they are never logged.
--]]

local WebDav = {}
WebDav.__index = WebDav

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
    return ((s:gsub(".", function(c)
        local byte, bits = c:byte(), ""
        for i = 8, 1, -1 do bits = bits .. (math.floor(byte / 2 ^ (i - 1)) % 2) end
        return bits
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
        if #bits < 6 then return "" end
        local n = 0
        for i = 1, 6 do n = n * 2 + (bits:sub(i, i) == "1" and 1 or 0) end
        return B64:sub(n + 1, n + 1)
    end) .. ({ "", "==", "=" })[#s % 3 + 1])
end
WebDav._base64 = base64

local function urlEncodePath(path)
    return (path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xmlUnescape(s)
    return (s:gsub("&(#?x?)(%w+);", function(kind, v)
        if kind == "" then return entities[v] end
        local n = kind == "#x" and tonumber(v, 16) or tonumber(v)
        return n and n < 128 and string.char(n) or nil
    end))
end

local function trimSlashes(s)
    return (s:gsub("^/+", ""):gsub("/+$", ""))
end

local function joinRel(a, b)
    a, b = trimSlashes(a or ""), trimSlashes(b or "")
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end
WebDav.join = joinRel

--- Strips user:password@ from a URL, for log messages.
local function redact(url)
    return (url:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1"))
end
WebDav.redact = redact

--- opts: address, username, password, root (folder under address),
--  http (socket.http), logger (optional), random (optional, () -> string)
function WebDav.new(opts)
    local self = setmetatable({}, WebDav)
    self.http = assert(opts.http, "http module")
    self.address = assert(opts.address, "address"):gsub("/+$", "")
    self.root = trimSlashes(opts.root or "")
    if opts.username and opts.username ~= "" then
        self.auth = "Basic " .. base64(opts.username .. ":" .. (opts.password or ""))
    end
    self.log = opts.logger
    self.random = opts.random or function() return string.format("%08x", math.random(0, 0x7fffffff)) end
    self.bytes_up, self.bytes_down, self.requests = 0, 0, 0
    return self
end

function WebDav:url(path, is_dir)
    local rel = joinRel(self.root, path)
    local url = self.address .. "/" .. urlEncodePath(rel)
    if is_dir and url:sub(-1) ~= "/" then url = url .. "/" end
    return url
end

-- One HTTP request. opts: method, path|url, is_dir, headers, body (string),
-- file (upload path), sink_path (download path).
-- Returns code, headers, body; or nil, err.
function WebDav:request(opts)
    local url = opts.url or self:url(opts.path or "", opts.is_dir)
    local headers = opts.headers or {}
    if self.auth then headers["Authorization"] = self.auth end
    local source, src_file
    if opts.body then
        local sent = false
        source = function()
            if sent then return nil end
            sent = true
            return opts.body
        end
        headers["Content-Length"] = tostring(#opts.body)
        self.bytes_up = self.bytes_up + #opts.body
    elseif opts.file then
        local err
        src_file, err = io.open(opts.file, "rb")
        if not src_file then return nil, err end
        local size = src_file:seek("end")
        src_file:seek("set", 0)
        headers["Content-Length"] = tostring(size)
        source = function()
            if not src_file then return nil end
            local chunk = src_file:read(16384)
            if chunk then
                self.bytes_up = self.bytes_up + #chunk
                return chunk
            end
            src_file:close()
            src_file = nil
            return nil
        end
    end
    local body_parts, out_file = {}, nil
    if opts.sink_path then
        local err
        out_file, err = io.open(opts.sink_path, "wb")
        if not out_file then
            if src_file then src_file:close() end
            return nil, err
        end
    end
    local sink = function(chunk)
        if chunk then
            self.bytes_down = self.bytes_down + #chunk
            if out_file then out_file:write(chunk) else body_parts[#body_parts + 1] = chunk end
        end
        return 1
    end
    self.requests = self.requests + 1
    local ok, code, rheaders, status = self.http.request{
        url = url, method = opts.method, headers = headers, source = source, sink = sink,
    }
    if src_file then src_file:close() end
    if out_file then out_file:close() end
    if not ok then
        local err = tostring(code)
        if self.log then self.log.warn("StatSync: WebDAV", opts.method, redact(url), "failed:", err) end
        return nil, err
    end
    code = tonumber(code)
    if self.log and (not code or code >= 400) then
        self.log.dbg("StatSync: WebDAV", opts.method, redact(url), "->", status or code)
    end
    return code, rheaders or {}, table.concat(body_parts)
end

local function fail(code, what)
    if not code then return nil, what end
    return nil, string.format("HTTP %s", tostring(code)), code
end

local PROPFIND_BODY = '<?xml version="1.0" encoding="utf-8"?>'
    .. '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getcontentlength/><D:getetag/></D:prop></D:propfind>'

local function hrefPath(href)
    href = xmlUnescape(href)
    href = href:gsub("^%a[%w+.-]*://[^/]*", "") -- absolute URL -> path
    return (trimSlashes(urlDecode(href)):gsub("/+", "/"))
end

local function parseMultistatus(body)
    local entries = {}
    for item in body:gmatch("<[%w]*:?response[%s>].-</[%w]*:?response>") do
        local href = item:match("<[%w]*:?href[^>]*>%s*(.-)%s*</[%w]*:?href>")
        if href then
            local is_dir = item:find("<[%w]*:?collection[^>]*/>") or item:find("<[%w]*:?collection[^>]*>%s*</")
            local size = item:match("<[%w]*:?getcontentlength[^>]*>%s*(%d+)%s*<")
            local etag = item:match("<[%w]*:?getetag[^>]*>%s*(.-)%s*</")
            local p = hrefPath(href)
            entries[#entries + 1] = {
                path = p,
                name = p:match("([^/]+)$") or p,
                is_dir = is_dir and true or false,
                size = tonumber(size),
                etag = etag and etag ~= "" and xmlUnescape(etag) or nil,
            }
        end
    end
    return entries
end

function WebDav:propfind(path, is_dir, depth)
    local url = self:url(path, is_dir)
    local code, headers_or_err, body = self:request{
        method = "PROPFIND", url = url, body = PROPFIND_BODY,
        headers = { ["Depth"] = depth, ["Content-Type"] = "application/xml; charset=utf-8" },
    }
    if code ~= 207 then return fail(code, headers_or_err) end
    return parseMultistatus(body), hrefPath(url)
end

function WebDav:list(path)
    local all, self_path, code = self:propfind(path, true, "1")
    if not all then return nil, self_path, code end
    local entries = {}
    for _, e in ipairs(all) do
        if e.path ~= self_path then entries[#entries + 1] = e end
    end
    return entries
end

--- { size, etag } of one file.
function WebDav:stat(path)
    local all, err, code = self:propfind(path, false, "0")
    if not all then return nil, err, code end
    return all[1] or {}
end

function WebDav:get(path, local_path)
    local code, headers_or_err = self:request{ method = "GET", path = path, sink_path = local_path }
    if code ~= 200 then
        os.remove(local_path)
        return fail(code, headers_or_err)
    end
    return true, { etag = headers_or_err.etag }
end

function WebDav:put(path, local_path)
    local code, err = self:request{ method = "PUT", path = path, file = local_path }
    if not code or code < 200 or code > 299 then return fail(code, err) end
    return true
end

function WebDav:mkdir(path)
    local code, err = self:request{ method = "MKCOL", path = path, is_dir = true }
    -- 405: already exists. 301: some servers redirect to the slashed URL of an existing folder.
    if code and ((code >= 200 and code <= 299) or code == 405 or code == 301) then return true end
    return fail(code, err)
end

function WebDav:mkdir_root()
    local prefix = ""
    for part in self.root:gmatch("[^/]+") do
        prefix = prefix == "" and part or prefix .. "/" .. part
        local url = self.address .. "/" .. urlEncodePath(prefix) .. "/"
        local code, err = self:request{ method = "MKCOL", url = url }
        if not (code and ((code >= 200 and code <= 299) or code == 405 or code == 301)) then
            return fail(code, err)
        end
    end
    return true
end

function WebDav:delete(path)
    local code, err = self:request{ method = "DELETE", path = path }
    if code and ((code >= 200 and code <= 299) or code == 404) then return true end
    return fail(code, err)
end

function WebDav:put_new(path, local_path)
    local dir = path:match("^(.*)/[^/]+$") or ""
    local tmp = joinRel(dir, ".upload-" .. self.random() .. ".part")
    local ok, err, ecode = self:put(tmp, local_path)
    if not ok then
        self:delete(tmp)
        return nil, err, ecode
    end
    local code, merr = self:request{
        method = "MOVE", path = tmp,
        headers = { ["Destination"] = self:url(path), ["Overwrite"] = "F" },
    }
    if code and code >= 200 and code <= 299 then return true end
    self:delete(tmp)
    if code == 412 then return false end
    return fail(code, merr)
end

return WebDav
