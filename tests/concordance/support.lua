--[[--
Test support for statsync: loads KOReader's own code where the tests need
it (lua-ljsqlite3 and statistics.koplugin, from a KOReader checkout), and
provides a fork-based subprocess runner and a minimal HTTP client with
LuaSocket's http.request interface, for running without KOReader.

KOREADER_SRC must point at a folder holding koreader/ and koreader-base/
checkouts (scripts/test-statsync.sh clones them).
--]]

local S = {}

local src = os.getenv("KOREADER_SRC")
if not src or src == "" then
    error("KOREADER_SRC is not set (folder with koreader/ and koreader-base/ checkouts)")
end
S.koreader = src .. "/koreader"
S.base = src .. "/koreader-base"

package.path = "concordance.koplugin/?.lua;" .. S.base .. "/?.lua;" .. package.path

local ffi = require("ffi")
-- What KOReader's ffi/loadlib sets up, enough for its posix_h and ljsqlite3.
ffi.libc = ffi.libc or "gnu"
ffi.loadlib = ffi.loadlib or function(name, ver)
    return ffi.load("lib" .. name .. ".so" .. (ver and ("." .. ver) or ""))
end
require("ffi/posix_h")
local C = ffi.C

package.preload["lua-ljsqlite3/init"] = function()
    return dofile(S.base .. "/thirdparty/lua-ljsqlite3/init.lua")
end
S.SQ3 = require("lua-ljsqlite3/init")

-- Small helpers -------------------------------------------------------------

function S.sh(cmd)
    local p = io.popen(cmd)
    local out = p:read("*a")
    p:close()
    return out
end

function S.q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

function S.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

function S.writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

function S.mkdirp(path) os.execute("mkdir -p " .. S.q(path)) end
function S.rmrf(path) os.execute("rm -rf " .. S.q(path)) end

function S.sleep(sec) C.usleep(math.floor(sec * 1e6)) end

function S.now()
    local tv = ffi.new("struct timeval")
    C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

local failures, count = 0, 0
function S.check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
    return cond
end
function S.results() return failures, count end
function S.finish(name)
    print(string.format("%s: %d checks, %d failures", name, count, failures))
    os.exit(failures == 0 and 0 or 1)
end

-- KOReader's statistics plugin -------------------------------------------------

local function stubModule(name, dir)
    local any
    any = setmetatable({}, {
        __index = function() return any end,
        __call = function() return any end,
        __concat = function(a, b) return tostring(a == any and "" or a) .. tostring(b == any and "" or b) end,
    })
    if name == "datastorage" then
        return { getDataDir = function() return dir end, getSettingsDir = function() return dir end }
    elseif name == "device" then
        return { canUseWAL = function() return true end, isAndroid = function() return false end }
    elseif name == "ui/widget/widget" then
        return { extend = function(_, o) o = o or {}; o.__index = o; return o end }
    elseif name == "gettext" then
        return setmetatable({ pgettext = function(_, s) return s end, ngettext = function(s) return s end },
            { __call = function(_, s) return s end })
    elseif name == "logger" then
        return { info = function() end, warn = function() end, dbg = function() end, err = print }
    elseif name == "lua-ljsqlite3/init" then
        return S.SQ3
    elseif name == "ffi/util" then
        return { template = function(s) return s end, copyFile = function() end }
    end
    return any
end

--- Loads statistics.koplugin/main.lua with its database in `dir`.
-- Returns the ReaderStatistics class (KOReader's code, unmodified).
function S.loadStatistics(dir)
    local path = S.koreader .. "/plugins/statistics.koplugin/main.lua"
    local chunk = assert(loadfile(path))
    local env = setmetatable({
        require = function(name) return stubModule(name, dir) end,
    }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end

--- KOReader's STATISTICS_SQL_BOOK_TOTALS_QUERY text, from its source.
function S.koreaderTotalsQuery()
    local text = S.readFile(S.koreader .. "/plugins/statistics.koplugin/main.lua")
    return text:match("local STATISTICS_SQL_BOOK_TOTALS_QUERY = %[%[(.-)%]%]")
end

--- A simulated KOReader device: its own settings folder and statistics
-- database, created and written by KOReader's statistics code.
local Device = {}
Device.__index = Device

function S.newDevice(name, dir)
    S.rmrf(dir)
    S.mkdirp(dir)
    local RS = S.loadStatistics(dir)
    local stats = setmetatable({
        settings = { is_enabled = true, max_sec = 120, min_sec = 5 },
        ui = {}, is_doc_not_frozen = true,
    }, { __index = RS })
    local conn = S.SQ3.open(dir .. "/statistics.sqlite3")
    stats:createDB(conn)
    conn:close()
    return setmetatable({ name = name, dir = dir, RS = RS, stats = stats,
                          db = dir .. "/statistics.sqlite3", state = dir .. "/statsync.sqlite3" }, Device)
end

--- Records reading through KOReader's insertDB: `sessions` is a list of
-- { page, start_time, duration }, for the book `book` = { title, authors, md5, pages }.
function Device:read(book, sessions)
    local st = self.stats
    st.data = { title = book.title, authors = book.authors or "N/A", language = book.language or "en",
                series = book.series or "N/A", pages = book.pages or 100, notes = 0, highlights = 0 }
    st.doc_md5 = book.md5
    st.is_doc_not_frozen = true
    st.id_curr_book = st:getIdBookDB()
    st.page_stat = {}
    for _, s in ipairs(sessions) do
        st.page_stat[s[1]] = st.page_stat[s[1]] or {}
        table.insert(st.page_stat[s[1]], { s[2], s[3] })
    end
    st.curr_page = -1 -- not one of the pages above, so nothing is held back
    st:insertDB()
    return st.id_curr_book
end

function Device:open()
    local c = S.SQ3.open(self.db)
    c:set_busy_timeout(5000)
    return c
end

--- page_stat_data keyed by md5, as one string (sorted).
function Device:dump()
    local c = self:open()
    local rows = {}
    for r in c:prepare([[SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages
                         FROM page_stat_data p JOIN book b ON b.id = p.id_book
                         ORDER BY b.md5, p.page, p.start_time]]):rows() do
        rows[#rows + 1] = table.concat({ r[1], tonumber(r[2]), tonumber(r[3]), tonumber(r[4]), tonumber(r[5]) }, "|")
    end
    c:close()
    return table.concat(rows, "\n"), #rows
end

--- For every book: stored totals equal what KOReader's own code computes now.
-- Returns true, or false and a description.
function Device:totalsMatch()
    local c = self:open()
    local books = {}
    for r in c:prepare("SELECT id, total_read_pages, total_read_time FROM book"):rows() do
        books[#books + 1] = { id = tonumber(r[1]), pages = tonumber(r[2]) or 0, time = tonumber(r[3]) or 0 }
    end
    c:close()
    local st = self.stats
    -- getStatsBookStatus runs KOReader's totals query; "frozen" makes its
    -- insertDB call a no-op, so it doesn't touch the book row first.
    st.is_doc_not_frozen = false
    for _, b in ipairs(books) do
        st.id_curr_book = b.id
        local got = st:getStatsBookStatus()
        if got.pages ~= b.pages or got.time ~= b.time then
            return false, string.format("%s book %d: stored %d pages/%ds, KOReader computes %d/%ds",
                self.name, b.id, b.pages, b.time, got.pages, got.time)
        end
    end
    st.is_doc_not_frozen = true
    return true
end

function Device:count(sql)
    local c = self:open()
    local n = tonumber(c:rowexec(sql))
    c:close()
    return n
end

-- Subprocesses, as KOReader's ffi/util runInSubProcess ------------------------

local Fork = {}
S.Fork = Fork

function Fork.spawn(fn)
    io.stdout:flush()
    local pid = C.fork()
    if pid < 0 then return nil, "fork failed" end
    if pid == 0 then
        C.setpgid(0, 0)
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then io.stderr:write("error in subprocess: ", tostring(err), "\n") end
        io.stdout:flush()
        io.stderr:flush()
        C._exit(0)
    end
    return { pid = pid }
end

function Fork.isDone(h)
    if h.done then return true end
    local status = ffi.new("int[1]")
    local ret = C.waitpid(h.pid, status, C.WNOHANG)
    if ret == h.pid or ret == -1 then h.done = true end
    return h.done or false
end

function Fork.kill(h)
    if not Fork.isDone(h) then C.kill(-h.pid, 9) end
end

-- A UI loop stand-in: scheduleIn with real time ------------------------------

local Loop = {}
Loop.__index = Loop
S.Loop = Loop

function Loop.new() return setmetatable({ tasks = {}, seq = 0 }, Loop) end

function Loop:schedule(delay, fn)
    self.seq = self.seq + 1
    table.insert(self.tasks, { at = S.now() + delay, seq = self.seq, fn = fn })
end

--- Runs tasks until none are left (or `until_fn()` is true, or timeout).
function Loop:run(timeout, until_fn)
    local deadline = S.now() + (timeout or 600)
    while #self.tasks > 0 and S.now() < deadline do
        if until_fn and until_fn() then return true end
        table.sort(self.tasks, function(a, b)
            if a.at ~= b.at then return a.at < b.at end
            return a.seq < b.seq
        end)
        local t = table.remove(self.tasks, 1)
        local wait = t.at - S.now()
        if wait > 0 then S.sleep(wait) end
        t.fn()
    end
    return #self.tasks == 0
end

-- HTTP client with LuaSocket's http.request{} interface ---------------------

local Http = {}
S.Http = Http

local function parseUrl(url)
    local host, port, path = url:match("^http://([^/:]+):?(%d*)(/?.*)$")
    if not host then return nil end
    return host, tonumber(port) or 80, path ~= "" and path or "/"
end

local function sendAll(fd, data)
    local sent = 0
    while sent < #data do
        local n = C.send(fd, ffi.cast("const char *", data) + sent, #data - sent, 0)
        if n <= 0 then return false end
        sent = sent + n
    end
    return true
end

--- opts.chunk_delay: seconds to wait between request body chunks (to make
-- an upload slow enough to be killed).
function Http.new(opts)
    opts = opts or {}
    local http = {}
    function http.request(reqt)
        local host, port, path = parseUrl(reqt.url)
        if not host then return nil, "bad url" end
        local fd = C.socket(C.AF_INET, 1 --[[SOCK_STREAM]], 0)
        if fd < 0 then return nil, "socket" end
        local addr = ffi.new("struct sockaddr_in")
        addr.sin_family = C.AF_INET
        addr.sin_port = C.htons(port)
        if C.inet_aton(host == "localhost" and "127.0.0.1" or host, addr.sin_addr) == 0 then
            C.close(fd)
            return nil, "only numeric hosts"
        end
        if C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) ~= 0 then
            C.close(fd)
            return nil, "connection refused"
        end
        local lines = { string.format("%s %s HTTP/1.1", reqt.method or "GET", path),
                        "Host: " .. host .. ":" .. port, "Connection: close" }
        for k, v in pairs(reqt.headers or {}) do lines[#lines + 1] = k .. ": " .. tostring(v) end
        local ok = sendAll(fd, table.concat(lines, "\r\n") .. "\r\n\r\n")
        if ok and reqt.source then
            while true do
                local chunk = reqt.source()
                if not chunk then break end
                if opts.chunk_delay then S.sleep(opts.chunk_delay) end
                if not sendAll(fd, chunk) then ok = false; break end
            end
        end
        if not ok then C.close(fd); return nil, "closed" end
        local buf = ffi.new("char[65536]")
        local parts = {}
        while true do
            local pfd = ffi.new("struct pollfd[1]")
            pfd[0].fd, pfd[0].events = fd, C.POLLIN
            if C.poll(pfd, 1, 30000) <= 0 then C.close(fd); return nil, "timeout" end
            local n = C.recv(fd, buf, 65536, 0)
            if n <= 0 then break end
            parts[#parts + 1] = ffi.string(buf, n)
        end
        C.close(fd)
        local resp = table.concat(parts)
        local head, body = resp:match("^(.-)\r\n\r\n(.*)$")
        if not head then return nil, "bad response" end
        local status = head:match("^[^\r\n]*")
        local code = tonumber(status:match("^HTTP/%d%.%d (%d+)"))
        local headers = {}
        for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do headers[k:lower()] = v end
        if (headers["transfer-encoding"] or ""):lower():find("chunked") then
            local out, pos = {}, 1
            while true do
                local size_hex, after = body:match("^(%x+)[^\r\n]*\r\n()", pos)
                local size = size_hex and tonumber(size_hex, 16)
                if not size or size == 0 then break end
                out[#out + 1] = body:sub(after, after + size - 1)
                pos = after + size + 2
            end
            body = table.concat(out)
        end
        if reqt.sink then
            if #body > 0 then reqt.sink(body) end
            reqt.sink(nil)
        end
        return 1, code, headers, status
    end
    return http
end

-- A local WebDAV server -------------------------------------------------------

--- Starts `rclone serve webdav` on a free port; returns { url, dir, stop() }.
function S.startWebDav(dir, user, pass)
    if S.sh("command -v rclone") == "" then return nil, "rclone not found" end
    S.mkdirp(dir)
    local port = 20000 + (tonumber(S.sh("echo $$")) or 0) % 20000
    local log = dir .. ".log"
    local pidfile = dir .. ".pid"
    os.execute(string.format("rclone serve webdav %s --dir-cache-time 0s --addr 127.0.0.1:%d --user %s --pass %s >%s 2>&1 & echo $! >%s",
        S.q(dir), port, S.q(user), S.q(pass), S.q(log), S.q(pidfile)))
    local url = "http://127.0.0.1:" .. port
    local http = Http.new()
    for _ = 1, 100 do
        local ok, code = http.request{ url = url .. "/", method = "OPTIONS" }
        if ok and code then break end
        S.sleep(0.1)
    end
    local pid = S.readFile(pidfile):match("%d+")
    return {
        url = url, dir = dir, port = port,
        stop = function() os.execute("kill " .. pid .. " 2>/dev/null") end,
    }
end

return S
