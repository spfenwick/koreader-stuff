--[[
Fills the catalog store from a Calibre-Web (or Calibre-Web Automated) OPDS
catalog. Network access is a function passed in, so this runs the same in
KOReader (in a subprocess) and in tests.

    local sync = Sync.new{ store = store, root = url, fetch = function(url) ... end }
    sync:full()   -- every book, then series; deletes books no longer listed
    sync:quick()  -- new books only; says when a full sync is needed

fetch(url) returns body, or nil and an error message.

Calibre-Web's OPDS entries have no series and no last-modified date, so:
- series come from walking the series index ("All" -> each series, in
  series order); a book's series number is its position in that feed;
- edits to existing books are only picked up by a full sync.
]]

local Feed = require("cloudlibrary/feed")
local Timing = require("cloudlibrary/timing")

local Sync = {}
Sync.__index = Sync

local MAX_PAGES = 2000 -- safety net against a feed whose "next" never ends

function Sync.new(o)
    assert(o.store and o.root and o.fetch, "Sync.new needs store, root and fetch")
    o.now = o.now or os.time
    o.progress = o.progress or function() end
    o.clock = o.clock or Timing.clock
    o.requests = 0
    -- Milliseconds spent in each part, and bytes received.
    o.spent = { network = 0, parsing = 0, database = 0, bytes = 0 }
    return setmetatable(o, Sync)
end

-- Runs fn and adds its duration to self.spent[part].
function Sync:timed(part, fn, ...)
    local t0 = self.clock()
    local results = Timing.pack(fn(...))
    self.spent[part] = self.spent[part] + (self.clock() - t0)
    return unpack(results, 1, results.n)
end

--- Timings for this sync, in the form Timing.recordAll() takes.
function Sync:timings(total_ms, phases)
    local sp = self.spent
    local t = {
        total = { ms = total_ms, note = string.format("%d requests, %.1f MB", self.requests, sp.bytes / 1048576) },
        network = { ms = sp.network, note = self.requests > 0
            and string.format("%.0f ms a request", sp.network / self.requests) or nil },
        parsing = { ms = sp.parsing },
        database = { ms = sp.database },
    }
    for name, ms in pairs(phases or {}) do t[name] = { ms = ms } end
    return t
end

--- Resolves href against base, the way a browser would for these feeds.
function Sync.resolve(base, href)
    if not href then return nil end
    if href:match("^%a[%w+.-]*://") then return href end
    local origin = base:match("^(%a[%w+.-]*://[^/]+)")
    if href:sub(1, 1) == "/" then return origin .. href end
    local path = base:sub(#origin + 1):gsub("[?#].*$", "")
    local dir = path:match("^(.*/)") or "/"
    return origin .. dir .. href
end

function Sync:get(url)
    self.requests = self.requests + 1
    local body, err = self:timed("network", self.fetch, url)
    if not body then return nil, err or "request failed" end
    self.spent.bytes = self.spent.bytes + #body
    return body
end

function Sync:getFeed(url)
    local body, err = self:get(url)
    if not body then return nil, err end
    local feed, perr = self:timed("parsing", Feed.parse, body)
    if not feed then return nil, (perr or "can't parse feed") .. ": " .. url end
    return feed
end

local function findSection(feed, suffix)
    for _i, s in ipairs(feed.sections) do
        local path = s.href:gsub("[?#].*$", "")
        if path:sub(-#suffix) == suffix then return s end
    end
end

--- Finds the catalog's "all books", "new books" and "all series" feeds from
-- its root. Cached in the store's meta table.
function Sync:endpoints()
    if self._endpoints then return self._endpoints end
    local cached = self.store:getMeta("endpoints")
    if cached then
        local all, new, series, stats = cached:match("^([^\n]*)\n([^\n]*)\n([^\n]*)\n([^\n]*)$")
        if all then
            self._endpoints = { all = all, new = new ~= "" and new or nil,
                series = series ~= "" and series or nil, stats = stats ~= "" and stats or nil }
            return self._endpoints
        end
    end
    local root, err = self:getFeed(self.root)
    if not root then return nil, err end
    local books = findSection(root, "/books")
    if not books then
        return nil, "This catalog doesn't look like Calibre-Web: no \"Alphabetical Books\" section."
    end
    local books_url = Sync.resolve(self.root, books.href)
    local index, ierr = self:getFeed(books_url)
    if not index then return nil, ierr end
    local all = findSection(index, "/letter/00")
    if not all then return nil, "No \"All\" entry in the alphabetical index." end
    local e = { all = Sync.resolve(books_url, all.href) }
    local new = findSection(root, "/new")
    e.new = new and Sync.resolve(self.root, new.href)
    local series = findSection(root, "/series")
    if series then
        local series_url = Sync.resolve(self.root, series.href)
        local sindex = self:getFeed(series_url)
        local sall = sindex and findSection(sindex, "/letter/00")
        e.series = sall and Sync.resolve(series_url, sall.href)
    end
    -- Calibre-Web's book count, next to the root feed: /opds -> /opds/stats.
    local prefix = books_url:gsub("/books[?#]?.*$", "")
    e.stats = prefix .. "/stats"
    self.store:setMeta("endpoints", table.concat({ e.all, e.new or "", e.series or "", e.stats or "" }, "\n"))
    self._endpoints = e
    return e
end

--- Calls on_page(feed) for each page, following "next" links.
function Sync:eachPage(url, on_page)
    local pages, seen_urls = 0, {}
    while url do
        if seen_urls[url] or pages >= MAX_PAGES then
            return nil, "feed pages loop: " .. url
        end
        seen_urls[url] = true
        local feed, err = self:getFeed(url)
        if not feed then return nil, err end
        pages = pages + 1
        local stop = on_page(feed, pages)
        if stop then break end
        url = feed.next and Sync.resolve(url, feed.next)
    end
    return pages
end

function Sync:remoteCount()
    local e = self:endpoints()
    if not (e and e.stats) then return nil end
    local body = self:get(e.stats)
    return body and tonumber(body:match('"books"%s*:%s*(%d+)'))
end

--- Full sync. Books not listed any more are deleted only if every page was
-- read. Returns { added, updated, deleted, total, series, requests, seconds }
-- or nil, error.
function Sync:full()
    local started = self.now()
    local t_start = self.clock()
    local e, err = self:endpoints()
    if not e then return nil, err end
    local stamp = started
    local seen, added = 0, 0
    local store = self.store
    local t_books = self.clock()
    local ok, perr = self:eachPage(e.all, function(feed, page)
        local res = self:timed("database", function()
            store:begin()
            local ok_tx, n = pcall(store.upsertBooks, store, feed.books, stamp)
            if not ok_tx then store:rollback(); error(n) end
            store:commit()
            return n
        end)
        added = added + res
        seen = seen + #feed.books
        self.progress("books", page, seen)
    end)
    if not ok then return nil, perr end
    local deleted = self:timed("database", function()
        store:begin()
        local n = store:deleteUnseen(stamp)
        store:commit()
        return n
    end)
    local books_ms = self.clock() - t_books

    local in_series = 0
    local t_series = self.clock()
    if e.series then
        local n, serr = self:syncSeries(e.series, stamp)
        if n then in_series = n else return nil, serr end
    end
    local result = {
        added = added, updated = seen - added, deleted = deleted, total = store:count(),
        in_series = in_series, requests = self.requests, seconds = self.now() - started,
    }
    result.timing = self:timings(self.clock() - t_start,
        { ["books list"] = books_ms, series = self.clock() - t_series })
    store:setMeta("last_full_sync", stamp)
    store:setMeta("last_sync", stamp)
    return result
end

function Sync:syncSeries(series_url, stamp)
    local store = self.store
    local list = {}
    local ok, err = self:eachPage(series_url, function(feed)
        for _i, s in ipairs(feed.sections) do table.insert(list, s) end
    end)
    if not ok then return nil, err end
    local in_series = 0
    for i, s in ipairs(list) do
        local position = 0
        local url = Sync.resolve(series_url, s.href)
        store:begin()
        local okp, pages, perr = pcall(self.eachPage, self, url, function(feed)
            self:timed("database", function()
                for _j, b in ipairs(feed.books) do
                    position = position + 1
                    store:setSeries(b.uuid, s.title, position, stamp)
                    in_series = in_series + 1
                end
            end)
        end)
        if not okp then store:rollback(); error(pages) end
        if not pages then store:rollback(); return nil, perr end
        store:commit()
        self.progress("series", i, #list)
    end
    store:clearSeriesNotSeen(stamp)
    return in_series
end

--- Quick sync: reads the newest books until it reaches ones already known.
-- Returns { added, needs_full, remote_count, total, requests } or nil, err.
-- needs_full is true when the counts still differ afterwards (books were
-- removed, or more were added than the new-books feed showed).
function Sync:quick()
    local started = self.now()
    local t_start = self.clock()
    local store = self.store
    if store:count() == 0 or not store:getMeta("last_full_sync") then
        return { needs_full = true, added = 0, total = store:count(), requests = self.requests }
    end
    local e, err = self:endpoints()
    if not e then return nil, err end
    local remote = self:remoteCount()
    if remote and remote == store:count() then
        store:setMeta("last_sync", started)
        return { added = 0, needs_full = false, remote_count = remote, total = remote,
            requests = self.requests, seconds = self.now() - started,
            timing = self:timings(self.clock() - t_start) }
    end
    if not e.new then
        return { added = 0, needs_full = true, remote_count = remote, total = store:count(),
            requests = self.requests }
    end
    local added = 0
    local stamp = tonumber(store:getMeta("last_full_sync"))
    local ok, perr = self:eachPage(e.new, function(feed, page)
        local fresh, known = {}, false
        for _i, b in ipairs(feed.books) do
            if store:has(b.uuid) then known = true else table.insert(fresh, b) end
        end
        if #fresh > 0 then
            store:begin()
            added = added + store:upsertBooks(fresh, stamp)
            store:commit()
        end
        return known or page >= 10
    end)
    if not ok then return nil, perr end
    local total = store:count()
    store:setMeta("last_sync", started)
    return { added = added, remote_count = remote, total = total,
        needs_full = remote ~= nil and remote ~= total,
        requests = self.requests, seconds = self.now() - started,
        timing = self:timings(self.clock() - t_start) }
end

return Sync
