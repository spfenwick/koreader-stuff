--[[
Keeps KOReader working if KOReader, CoverBrowser or ZenOS change under the
plugin. The plugin needs ZenOS with book sources (common/book_sources.lua):
without it, the library doesn't start.

Guard.hook(feature, target, name, fn, label, fallback)
    replaces target[name] with fn(orig, ...). If fn throws, the original
    runs instead and the feature is turned off: the plugin never breaks
    the function it hooks.
Guard.call(feature, fn, ...)
    runs fn protected (for scheduled callbacks: an error there would
    otherwise stop KOReader).
Guard.check()
    before hooking: checks that what each feature relies on is still there.

Features:
  library  cloud books in the folder (also: the settings guard, covers);
           turning it off removes the cloud books
  open     a cloud book opened from outside ZenOS's book sources (ReaderUI)
           shows its details; off: KOReader says the file isn't there
  delete   a deleted download is a cloud book again at once (and keeps its
           history place); off: it comes back at the next catalog load
  sync     syncs, downloads and cover downloads (KOReader's subprocess and
           network functions); off: the cached catalog is still shown
  covers   a cloud book's cover downloaded when CoverBrowser asks to extract
           it; off: CoverBrowser is never given cloud books (fail-closed),
           which show covers already downloaded, else none
  listing  extras while the library is listed: the "Rebuilding library…"
           message and the hasBookBeenOpened / isFileInCollections
           shortcuts; turning it off only loses those (the library stays)
  search   cloud books in file search (ZenOS puts them there; only checked)
  badge    the cover badges (ZenOS paints them, from the source's badge())
  zenos    cloud books in ZenOS's Authors, Series and Tags tabs, and the
           open and tag hooks in zenos_source.lua
  history  cloud books in the reading history (history.lua)
  metadata downloaded books shown with the catalog's metadata, under
           their custom metadata (Library.installCatalogMetadataHook)
  jobs     background tasks, menu actions: an error is logged and reported,
           nothing is turned off
]]

local logger = require("logger")

local Guard = {
    failed = {},     -- feature -> error message (turned off after an error)
    unavailable = {},-- feature -> list of problems (failed the startup check)
    on_failure = {}, -- feature -> function(), called once when it's turned off
    notified = false,
}

local function pack(...) return { n = select("#", ...), ... } end

function Guard.ok(feature)
    return not Guard.failed[feature] and not Guard.unavailable[feature]
end

--- Turns a feature off after an error (once), logs it and tells the user.
function Guard.fail(feature, where, err)
    logger.err("Athenaeum: error in", where, "(" .. feature .. "):", err)
    if Guard.failed[feature] then return end
    Guard.failed[feature] = string.format("%s: %s", where, tostring(err))
    local cb = Guard.on_failure[feature]
    if cb then
        local ok, cerr = pcall(cb)
        if not ok then logger.err("Athenaeum: while turning off", feature, cerr) end
    end
    if feature == "library" then
        -- Everything else depends on the library.
        for other in pairs({ listing = true, open = true, delete = true, sync = true, covers = true,
                search = true, badge = true, zenos = true, history = true, metadata = true }) do
            if not Guard.failed[other] then Guard.failed[other] = "library turned off" end
        end
    end
    if not Guard.notified then
        Guard.notified = true
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui then
            UIManager:nextTick(function()
                local InfoMessage = require("ui/widget/infomessage")
                local _ = require("gettext")
                UIManager:show(InfoMessage:new{
                    text = _("Athenæum turned part of itself off after an error, probably from a KOReader or ZenOS update. Your books and the file browser aren't affected.\n\nDetails: Athenæum → Status, and crash.log."),
                })
            end)
        end
    end
end

local function traceback(err)
    return debug.traceback(tostring(err), 2)
end

--- Hooks target[name]. fn(orig, ...) does the work; returns the wrapper, or
-- nil if there's nothing to hook. fallback(orig, ...), if given, runs
-- instead of the original whenever the feature is off (after a failure, or
-- the startup check), for a hook whose original mustn't see what the plugin
-- normally keeps from it (fail-closed). It should be trivial; if it fails
-- too, the original runs.
function Guard.hook(feature, target, name, fn, label, fallback)
    local orig = target[name]
    if type(orig) ~= "function" then
        Guard.problem(feature, (label or name) .. " is missing")
        return nil
    end
    label = label or name
    local function off(...)
        if not fallback then return orig(...) end
        local r = pack(pcall(fallback, orig, ...))
        if r[1] then return unpack(r, 2, r.n) end
        logger.err("Athenaeum: fallback for", label, "(" .. feature .. ") failed:", r[2])
        return orig(...)
    end
    local wrapper = function(...)
        if not Guard.ok(feature) then return off(...) end
        -- Errors from the original itself aren't ours: pass them on as if
        -- the plugin weren't there, rather than turning the feature off.
        local orig_error, orig_done
        local function call_orig(...)
            local r = pack(pcall(orig, ...))
            if not r[1] then
                orig_error = r[2]
                error(r[2], 0)
            end
            orig_done = r
            return unpack(r, 2, r.n)
        end
        local r = pack(xpcall(fn, traceback, call_orig, ...))
        if r[1] then return unpack(r, 2, r.n) end
        if orig_error ~= nil then error(orig_error, 0) end
        Guard.fail(feature, label, r[2])
        -- The original already ran before our code failed: its results
        -- stand. Running it again would delete, or open, twice.
        if orig_done then return unpack(orig_done, 2, orig_done.n) end
        return off(...)
    end
    target[name] = wrapper
    return wrapper
end

--- Wraps every callback in KOReader menu or button tables (nested too),
-- so an error in one is reported instead of stopping KOReader.
function Guard.wrapCallbacks(items, feature)
    if type(items) ~= "table" then return items end
    for _k, item in pairs(items) do
        if type(item) == "table" then
            for _i, key in ipairs({ "callback", "hold_callback" }) do
                local cb = item[key]
                if type(cb) == "function" then
                    item[key] = function(...) return Guard.call(feature or "jobs", cb, ...) end
                end
            end
            if type(item.sub_item_table) == "table" then Guard.wrapCallbacks(item.sub_item_table, feature) end
            if type(item.sub_item_table_func) == "function" then
                local f = item.sub_item_table_func
                item.sub_item_table_func = function(...)
                    return Guard.wrapCallbacks(Guard.call(feature or "jobs", f, ...) or {}, feature)
                end
            end
            if item[1] ~= nil then Guard.wrapCallbacks(item, feature) end -- button rows
        end
    end
    return items
end

--- Runs fn protected; on error turns feature off and returns nil.
function Guard.call(feature, fn, ...)
    local r = pack(xpcall(fn, traceback, ...))
    if r[1] then return unpack(r, 2, r.n) end
    Guard.fail(feature, "background task", r[2])
end

--- Wraps fn so that each call is protected (for UIManager:scheduleIn).
function Guard.task(feature, fn)
    return function(...) return Guard.call(feature, fn, ...) end
end

-- Startup check ------------------------------------------------------------------

function Guard.problem(feature, text)
    Guard.unavailable[feature] = Guard.unavailable[feature] or {}
    table.insert(Guard.unavailable[feature], text)
end

local function params(f)
    local ok, info = pcall(debug.getinfo, f, "u")
    return ok and info and info.nparams, ok and info and info.isvararg
end

-- requires(feature, module, { name = minimum parameter count or true, ... })
local function requires(feature, modname, functions)
    local ok, mod = pcall(require, modname)
    if not ok or type(mod) ~= "table" then
        Guard.problem(feature, modname .. " can't be loaded")
        return nil
    end
    for fname, min in pairs(functions) do
        local f = mod[fname]
        if type(f) ~= "function" then
            Guard.problem(feature, modname .. "." .. fname .. " is missing")
        elseif type(min) == "number" then
            local n, vararg = params(f)
            if n and n < min and not vararg then
                Guard.problem(feature, string.format("%s.%s takes %d parameters, expected %d",
                    modname, fname, n, min))
            end
        end
    end
    return mod
end

--- Checks what each feature relies on. Returns true if the library can run.
-- (Parameter counts include self.)
function Guard.check()
    Guard.unavailable = {}
    local fc = requires("library", "ui/widget/filechooser", { updateItems = true })
    -- The "Rebuilding library…" message: getPathList (KOReader 2026.07 and
    -- later), else getList.
    if not (fc and type(fc.getPathList) == "function") then
        requires("listing", "ui/widget/filechooser", { getList = 3 })
    end
    requires("open", "apps/reader/readerui", { showReader = 2 })
    requires("library", "docsettings", { flush = 1 })
    requires("listing", "ui/widget/booklist", { hasBookBeenOpened = 1 })
    requires("listing", "readcollection", { isFileInCollections = 2 })
    requires("library", "apps/filemanager/filemanager", { openFile = true })
    -- ZenOS's book sources (the plugin is ZenOS-only).
    local ok_zen, zen = pcall(require, "common/book_sources")
    Guard.zenos_missing = not ok_zen or type(zen) ~= "table"
    if Guard.zenos_missing then
        Guard.problem("library", "needs ZenOS with book sources")
    else
        -- booksWithoutFile: ZenOS lists the cloud books in the library folder.
        requires("library", "common/book_sources", {
            register = 2, changed = true, bookInfo = true, listingKey = true,
            installMetadataIntegration = true, booksWithoutFile = true,
        })
        -- Cover badges are ZenOS's to paint (athenaeum/badge.lua).
        requires("badge", "common/book_sources", { badge = true })
        -- ZenOS's search puts the cloud books into its results (fileless sources).
        requires("search", "common/book_sources", { searchResults = 4 })
    end
    requires("sync", "ffi/util", {
        runInSubProcess = 2, isSubProcessDone = 1, readAllFromFD = 1, writeToFD = 2,
    })
    requires("sync", "ui/network/manager", { isConnected = true, runWhenConnected = true })

    -- CoverBrowser: metadata and covers of cloud books. Missing CoverBrowser
    -- is fine (no covers anywhere then); a changed one isn't.
    local ok_bim, bim = pcall(require, "bookinfomanager")
    if ok_bim and type(bim) == "table" then
        requires("library", "bookinfomanager", { getBookInfo = 3, isCachedCoverInvalid = 2 })
        requires("covers", "bookinfomanager", { extractInBackground = 2, isExtractingInBackground = 1 })
        -- The shape of what getBookInfo returns, on a folder (no database read).
        local DataStorage = require("datastorage")
        local okc, info = pcall(bim.getBookInfo, bim, DataStorage:getDataDir(), false)
        if not okc or type(info) ~= "table" or info.cover_fetched == nil then
            Guard.problem("library", "CoverBrowser's book information has changed shape")
        end
        if type(bim.isCachedCoverInvalid) == "function" then
            local okv, invalid = pcall(bim.isCachedCoverInvalid,
                { cover_w = 100, cover_h = 150, cover_sizetag = "100x150" },
                { max_cover_w = 200, max_cover_h = 300 })
            if not okv or invalid then
                Guard.problem("library", "CoverBrowser's cover size check has changed")
            end
        end
    end

    requires("history", "readhistory", {
        _read = 1, clearMissing = 1, _flush = 1, getIndexByFile = 2, getIndexByTime = 2, removeItem = 2,
    })
    requires("history", "apps/filemanager/filemanagerhistory", { onShowHist = 1 })
    requires("metadata", "apps/filemanager/filemanagerbookinfo", { extendProps = 2 })

    for feature, problems in pairs(Guard.unavailable) do
        logger.warn("Athenaeum: not starting", feature, "-", table.concat(problems, "; "))
    end
    return Guard.unavailable.library == nil
end

--- Lines for the Status screen ("" when all is well).
function Guard.statusText()
    local lines = {}
    for _i, feature in ipairs({ "library", "listing", "open", "delete", "sync", "covers", "search", "badge",
            "zenos", "history", "metadata", "jobs" }) do
        if Guard.unavailable[feature] then
            table.insert(lines, string.format("%s not started: %s", feature,
                table.concat(Guard.unavailable[feature], "; ")))
        elseif Guard.failed[feature] then
            table.insert(lines, string.format(feature == "jobs" and "%s error: %s" or "%s turned off: %s",
                feature, (Guard.failed[feature]:gsub("\n.*", ""))))
        end
    end
    return table.concat(lines, "\n")
end

return Guard
