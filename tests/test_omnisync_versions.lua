-- Unit tests for statistics across versions of a book (omnisync/store.lua:
-- Versions of a book). Statistics databases are written by KOReader's own
-- statistics code; the book identity's groups are set directly.
-- Run through scripts/test-omnisync.sh.

local S = dofile("tests/omnisync/support.lua")
local check = S.check

local Store = require("omnisync/store")
local IdStore = require("omnisync/idstore")

local TMP = assert(os.getenv("STATSYNC_TMP"), "STATSYNC_TMP not set") .. "/versions"
S.rmrf(TMP)
S.mkdirp(TMP)

local X, Y = string.rep("1", 32), string.rep("2", 32) -- two versions of one book
local OTHER = string.rep("9", 32)
local BOOK = { title = "Pride and Prejudice", authors = "Jane Austen", pages = 300 }

local n = 0
local function device(name, opts)
    n = n + 1
    local d = S.newDevice(name, TMP .. "/" .. n .. "-" .. name)
    opts = opts or {}
    d.store = Store.new{ sq3 = S.SQ3, stats_path = d.db, state_path = d.state,
                         join_versions = opts.join_versions, open_md5 = opts.open_md5 }
    function d:readBook(md5, sessions, title)
        return self:read({ title = title or BOOK.title, authors = BOOK.authors, md5 = md5, pages = BOOK.pages }, sessions)
    end
    -- The two versions joined as one book.
    function d:join(md5s)
        local id = IdStore.new{ sq3 = S.SQ3, state_path = self.state }
        id:open():close()
        local conn = S.SQ3.open(self.state)
        for _, m in ipairs(md5s) do
            conn:exec(string.format("INSERT OR REPLACE INTO id_groups (md5, grp) VALUES ('%s', '%s');", m, md5s[1]))
        end
        conn:close()
    end
    return d
end

local seg = 0
-- Exports from d (marked exported, as after an upload); the segment's path.
local function export(d)
    seg = seg + 1
    local path = TMP .. "/seg-" .. seg .. ".jsonl"
    local res = d.store:export{ device_id = d.name, out_path = path, now = 1700000000, max_events = 100000,
                                force_diff = true }
    if not res then return nil end
    d.store:markExported(path, d.name, "seg-" .. seg, res.size, nil, 1700000000)
    return path, res
end

local function import(d, path)
    seg = seg + 1
    return assert(d.store:importSegment(path, "other", "seg-in-" .. seg, 1, nil, 1700000000))
end

local function rows(d, md5) return d:count("SELECT count(*) FROM book WHERE md5 = '" .. md5 .. "'") end
local function events(d, md5)
    return d:count("SELECT count(*) FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.md5 = '" .. md5 .. "'")
end
local function totalsOk(d, what)
    local ok, why = d:totalsMatch()
    check(ok, what .. ": totals as KOReader computes them (" .. tostring(why) .. ")")
end
-- Nothing of what came from elsewhere goes out as this device's.
local function sendsNothing(d, what)
    seg = seg + 1
    local res = d.store:export{ device_id = d.name, out_path = TMP .. "/check-" .. seg .. ".jsonl", now = 1,
                                max_events = 100000, force_diff = true }
    check(res == nil, what .. ": nothing sent back")
end

-- Another device's readings of another version: into this device's row -------------------------

do
    local A, B = device("A"), device("B")
    A:readBook(X, { { 1, 1000, 30 }, { 2, 1030, 40 } })
    B:readBook(Y, { { 5, 2000, 60 } })
    export(B)
    B:join{ X, Y }
    local pathA = export(A)
    local res = import(B, pathA)
    check(rows(B, X) == 0 and rows(B, Y) == 1, "no row made for the other version")
    check(events(B, Y) == 3, "its readings in this device's row")
    check(res.inserted == 2, "two readings new here")
    sendsNothing(B, "joined on import")
    totalsOk(B, "joined on import")
    -- The same segment again changes nothing.
    local again = import(B, pathA)
    check(events(B, Y) == 3 and again.inserted == 0, "importing again changes nothing")
end

-- The groups arrive after the readings: the row made for them is folded in --------------------

do
    local A, B = device("A"), device("B")
    A:readBook(X, { { 1, 1000, 30 }, { 2, 1030, 40 }, { 5, 2000, 20 } })
    B:readBook(Y, { { 5, 2000, 60 } }) -- one reading both have: the longer wins
    export(B)
    import(B, (export(A)))
    check(rows(B, X) == 1 and rows(B, Y) == 1, "before the link: a row per version")
    B:join{ X, Y }
    local res = assert(B.store:joinVersions())
    check(res.removed == 1 and rows(B, X) == 0, "the other version's row removed")
    check(events(B, Y) == 3, "its readings moved, the shared one once")
    check(B:count("SELECT duration FROM page_stat_data WHERE page = 5 AND start_time = 2000") == 60, "the longer one kept")
    sendsNothing(B, "joined late")
    totalsOk(B, "joined late")
    check(assert(B.store:joinVersions()).removed == 0, "joining again: nothing to do")
    -- Later readings of that version go straight to this device's row.
    A:readBook(X, { { 7, 3000, 25 } })
    import(B, (export(A)))
    check(rows(B, X) == 0 and events(B, Y) == 4, "later readings: into this device's row")
    sendsNothing(B, "later readings")
end

-- A book this device doesn't have: one row for both versions ----------------------------------

do
    local A, B, C = device("A"), device("B"), device("C")
    A:readBook(X, { { 1, 1000, 30 } })
    B:readBook(Y, { { 2, 2000, 40 } })
    import(C, (export(A)))
    import(C, (export(B)))
    C:join{ X, Y }
    local res = assert(C.store:joinVersions())
    check(res.removed == 1 and rows(C, X) + rows(C, Y) == 1, "one row left")
    check(C:count("SELECT count(*) FROM page_stat_data") == 2, "both versions' readings in it")
    A:readBook(X, { { 3, 3000, 10 } })
    B:readBook(Y, { { 4, 4000, 10 } })
    import(C, (export(A)))
    import(C, (export(B)))
    check(C:count("SELECT count(*) FROM book") == 1 and C:count("SELECT count(*) FROM page_stat_data") == 4,
        "later readings of either version: same row")
    sendsNothing(C, "book not here")
    totalsOk(C, "book not here")
end

-- Both versions opened on this device: each keeps its row --------------------------------------

do
    local A, B = device("A"), device("B")
    A:readBook(X, { { 1, 1000, 30 } })
    B:readBook(X, { { 2, 1500, 20 } })
    B:readBook(Y, { { 3, 2000, 40 } }, "Pride & Prejudice")
    export(B)
    B:join{ X, Y }
    check(assert(B.store:joinVersions()).removed == 0, "rows KOReader uses stay")
    import(B, (export(A)))
    check(events(B, X) == 2 and events(B, Y) == 1, "readings of a version with a row here go to that row")
    sendsNothing(B, "two versions here")
end

-- The open book's rows aren't touched -----------------------------------------------------------

do
    local A, B = device("A"), device("B", { open_md5 = function() return X end })
    A:readBook(X, { { 1, 1000, 30 } })
    B:readBook(Y, { { 2, 2000, 40 } })
    import(B, (export(A)))
    B:join{ X, Y }
    check(assert(B.store:joinVersions()).removed == 0 and rows(B, X) == 1, "the open book's row stays")
end

-- Unrelated books aren't joined; the web app keeps a row per file -------------------------------

do
    local A, B = device("A"), device("B")
    A:readBook(OTHER, { { 1, 1000, 30 } })
    B:readBook(Y, { { 2, 2000, 40 } })
    B:join{ X, Y }
    import(B, (export(A)))
    check(rows(B, OTHER) == 1 and events(B, Y) == 1, "a book outside the group: its own row")

    local W = device("W", { join_versions = false })
    A:readBook(X, { { 3, 3000, 30 } })
    B:readBook(Y, { { 4, 4000, 40 } })
    import(W, (export(A)))
    import(W, (export(B)))
    W:join{ X, Y }
    check(assert(W.store:joinVersions()).removed == 0 and rows(W, X) == 1 and rows(W, Y) == 1,
        "joining off: a row per file")
end

S.finish("omnisync version statistics tests")
