--[[
HTTP GET with Basic auth, like KOReader's OPDS plugin. Blocking: call it
from a subprocess.
]]

local Http = {}

--- The Authorization header's value for a server, or nil without a user
-- name. Made here rather than through LuaSocket's user and password
-- fields: it takes a % in them for an escape and changes the password.
function Http.auth(server)
    if type(server.username) ~= "string" or server.username == "" then return nil end
    local mime = require("mime")
    return "Basic " .. mime.b64(server.username .. ":" .. (server.password or ""))
end

--- Returns body, nil, nil and the response headers (lower-case names), or
-- nil, an error message and "http" (the server answered with an error),
-- "network" (it wasn't reached) or "not_modified" (304, for a conditional
-- request). server: { url, username, password } as in KOReader's OPDS
-- settings. extra_headers: more request headers (If-None-Match...).
function Http.get(server, url, extra_headers)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    local headers = {
        ["Accept-Encoding"] = "identity",
        ["Accept"] = "application/atom+xml, application/xml;q=0.9, image/*;q=0.8, */*;q=0.5",
    }
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    headers["Authorization"] = Http.auth(server)
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then return table.concat(sink), nil, nil, resp_headers or {} end
    if code == 304 then return nil, "not modified", "not_modified" end
    -- Without an HTTP status, the server wasn't reached (no network, timeout).
    if type(code) ~= "number" then
        return nil, "Network error: " .. tostring(code or status), "network"
    end
    if code == 401 or code == 403 then
        return nil, "The server refused the user name or password (" .. tostring(code) .. ").", "http"
    end
    return nil, "Request failed: " .. tostring(status or code) .. " " .. url, "http"
end

--- Downloads url to path, streaming (books can be large). Returns true, or
-- nil and an error message; on failure path is removed.
function Http.download(server, url, path)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local file, ferr = io.open(path, "wb")
    if not file then return nil, "Can't write " .. path .. ": " .. tostring(ferr) end
    local block_timeout, total_timeout = socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT,
        socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = { ["Accept-Encoding"] = "identity", ["Authorization"] = Http.auth(server) },
        sink = ltn12.sink.file(file), -- closes the file
    })
    socketutil:reset_timeout()
    if code == 200 then return true end
    os.remove(path)
    if code == 401 or code == 403 then
        return nil, "The server refused the user name or password (" .. tostring(code) .. ")."
    end
    local described = socketutil.describe_error and socketutil.describe_error(code, block_timeout, total_timeout)
    return nil, described or ("Download failed: " .. tostring(status or code))
end

--- fetch(url) for Sync.
function Http.fetcher(server)
    return function(url, headers) return Http.get(server, url, headers) end
end

return Http
