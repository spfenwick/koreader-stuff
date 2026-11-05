--[[
HTTP GET with Basic auth, like KOReader's OPDS plugin. Blocking: call it
from a subprocess.
]]

local Http = {}

--- Returns body, or nil and an error message.
-- server: { url, username, password } as in KOReader's OPDS settings.
function Http.get(server, url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["Accept-Encoding"] = "identity",
            ["Accept"] = "application/atom+xml, application/xml;q=0.9, image/*;q=0.8, */*;q=0.5",
        },
        sink = ltn12.sink.table(sink),
        user = server.username,
        password = server.password,
    })
    socketutil:reset_timeout()
    if code == 200 then return table.concat(sink) end
    if code == 401 or code == 403 then
        return nil, "The server refused the user name or password (" .. tostring(code) .. ")."
    end
    return nil, "Request failed: " .. tostring(status or code) .. " " .. url
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
        headers = { ["Accept-Encoding"] = "identity" },
        sink = ltn12.sink.file(file), -- closes the file
        user = server.username,
        password = server.password,
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
    return function(url) return Http.get(server, url) end
end

return Http
