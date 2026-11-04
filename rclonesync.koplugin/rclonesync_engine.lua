--[[--
The sync itself: which files, what changed, and making both sides agree.

On the server, under the sync folder:

    manifest.tsv     every synced file with its hash, size, time and device
                     (and for fonts, the server's ID for the file)
    lists/           settings.txt, plugins.txt, patches.txt
    settings/        what settings.txt lists in KOReader's settings/
      @koreader/     files settings.txt lists with //, from KOReader's folder
    plugins/         what plugins.txt lists in plugins/
    patches/         what patches.txt lists in patches/
    fonts/           pulled only, never deleted
    dict/            data/dict/
    styletweaks/

On the device, in koreader/rclonesync/: the lists, state.tsv (what each file
was when this device last synced), cache.tsv (hashes, so unchanged files
aren't read again), pending.tsv and staging/ (pulled settings waiting for
the next start), conflicts/, last.log and apply.log.

Comparing a file with its state at the last sync tells which side changed
it, so a file a device never had isn't taken as deleted there. When both
sides changed a file, the newer one is kept and the other is saved in
conflicts/.

Settings files that KOReader keeps in memory (gestures.lua and the like)
would be written over with the old values when KOReader next saves them.
So they're downloaded into staging/ and put in place the next time
KOReader starts, before any plugin has read them.

This runs in a separate process during a sync: no UI here.
--]]--

local Remote = require("rclonesync_remote")

local Engine = {}

local TEMP_SUFFIX = ".rclonesync-part"
-- Files named with // in settings.txt: their paths in the sync.
local KO = "@koreader/"
local MANIFEST = "manifest.tsv"

-- In the order they're synced: the lists first, so the rest use the new ones.
--   dir:       under KOReader's folder (lists: koreader/rclonesync/)
--   list:      only what this list names; without the list, not synced
--   koreader_paths: the list can name files anywhere in KOReader's folder
--              with //, kept under @koreader/
--   pull_only: never uploaded, never deleted here
--   staged:    put in place at the next start
--   restart:   KOReader uses new files only after a restart
Engine.AREAS = {
    { name = "lists", remote = "lists", in_state = true,
      patterns = { "/settings.txt", "/plugins.txt", "/patches.txt" } },
    { name = "settings", dir = "settings", remote = "settings", list = "settings.txt", staged = true,
      koreader_paths = true },
    { name = "plugins", dir = "plugins", remote = "plugins", list = "plugins.txt", restart = true },
    { name = "patches", dir = "patches", remote = "patches", list = "patches.txt", restart = true },
    { name = "fonts", dir = "fonts", remote = "fonts", pull_only = true, restart = true },
    { name = "dict", dir = "data/dict", remote = "dict", restart = true },
    { name = "styletweaks", dir = "styletweaks", remote = "styletweaks" },
}

local function lfs() return require("libs/libkoreader-lfs") end

local function joinPath(a, b)
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end

local function dirname(path) return path:match("^(.*)/[^/]+$") or "" end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

--- Write a file whole, so it's never left half-written.
local function writeFile(path, data)
    local tmp = path .. TEMP_SUFFIX
    local file, err = io.open(tmp, "wb")
    if not file then return nil, err end
    file:write(data)
    file:close()
    return os.rename(tmp, path)
end

function Engine.mkdirs(path)
    local sofar = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        sofar = sofar .. "/" .. part
        if not lfs().attributes(sofar) then
            local ok, err = lfs().mkdir(sofar)
            if not ok and not lfs().attributes(sofar) then return nil, err end
        end
    end
    return true
end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Patterns ----------------------------------------------------------------

-- {a,b} → a, b (innermost first, so they can nest).
local function expandBraces(p)
    local s, e = p:find("{[^{}]*}")
    if not s then return { p } end
    local out = {}
    for alt in (p:sub(s + 1, e - 1) .. ","):gmatch("([^,]*),") do
        for _, x in ipairs(expandBraces(p:sub(1, s - 1) .. alt .. p:sub(e + 1))) do
            table.insert(out, x)
        end
    end
    return out
end

-- rclone's globs as a Lua pattern: ** anything, * and ? within a folder name.
local function globToLua(g)
    local out, i = {}, 1
    while i <= #g do
        local c = g:sub(i, i)
        if c == "*" then
            if g:sub(i + 1, i + 1) == "*" then
                table.insert(out, ".*")
                i = i + 2
            else
                table.insert(out, "[^/]*")
                i = i + 1
            end
        elseif c == "?" then
            table.insert(out, "[^/]")
            i = i + 1
        elseif c == "[" and g:find("]", i + 2, true) then
            local close = g:find("]", i + 2, true)
            local class = g:sub(i + 1, close - 1):gsub("^!", "^"):gsub("%%", "%%%%")
            table.insert(out, "[" .. class .. "]")
            i = close + 1
        elseif c == "\\" and i < #g then
            local n = g:sub(i + 1, i + 1)
            table.insert(out, n:match("%w") and n or "%" .. n)
            i = i + 2
        elseif c:match("[%^%$%(%)%%%.%[%]%+%-]") then
            table.insert(out, "%" .. c)
            i = i + 1
        else
            table.insert(out, c)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Why a // path can't be synced, or nil if it can.
local function badKoreaderPath(rel)
    if rel == "" then return "no file named" end
    if rel:find("[%*%?%[%]{}\\]") then return "only exact paths, no patterns" end
    if rel:find("[\t\n\r]") then return "tabs and line breaks can't be synced" end
    for part in (rel .. "/"):gmatch("([^/]*)/") do
        if part == "" or part == "." or part == ".." then return "not a plain path" end
    end
    local top = rel:match("^[^/]+")
    if top == "settings" then return "files in settings/ are listed with a single /" end
    if top == "rclonesync" then return "Settings sync's own folder" end
    return nil
end

--- Rules from the lines of a list: one rclone-style pattern per line, # or
--- ; for comments. "/x" matches only at the top of the folder; "x" at the
--- end of any path. "//x" names one file in KOReader's folder (only exact
--- paths, as finding them would mean looking through all of it): it goes
--- in rules.koreader, or rules.bad with why it can't be synced.
function Engine.compile(lines)
    local rules = { tops = {}, prunable = true, koreader = {}, bad = {} }
    for _, line in ipairs(lines) do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line:sub(1, 2) == "//" then
            local rel = line:sub(3)
            local why = badKoreaderPath(rel)
            if why then
                table.insert(rules.bad, line .. ": " .. why)
            else
                rules.koreader[rel] = true
            end
        elseif line ~= "" and not line:match("^[#;]") then
            local anchored = line:sub(1, 1) == "/"
            local body = anchored and line:sub(2) or line
            for _, alt in ipairs(expandBraces(body)) do
                table.insert(rules, { anchored = anchored, pattern = "^" .. globToLua(alt) .. "$" })
                -- Only these top-level names need looking at?
                local top = alt:match("^([^/]+)")
                if anchored and top and not top:find("[%*%?%[\\]") then
                    rules.tops[top] = true
                else
                    rules.prunable = false
                end
            end
        end
    end
    return rules
end

function Engine.matches(rules, path)
    if rules.all then return true end
    if path:sub(1, #KO) == KO then
        return rules.koreader ~= nil and rules.koreader[path:sub(#KO + 1)] == true
    end
    for _, rule in ipairs(rules) do
        if rule.anchored then
            if path:find(rule.pattern) then return true end
        else
            local s = path
            while true do
                if s:find(rule.pattern) then return true end
                local slash = s:find("/", 1, true)
                if not slash then break end
                s = s:sub(slash + 1)
            end
        end
    end
    return false
end

local ALL = { all = true }

local function readLines(path)
    local data = readFile(path)
    if not data then return nil end
    local lines = {}
    for line in data:gmatch("[^\r\n]+") do table.insert(lines, line) end
    return lines
end

-- Hashing -----------------------------------------------------------------

local function md5Lua(path)
    local ok, sha2 = pcall(require, "ffi/sha2")
    if not ok then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local append = sha2.md5()
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        append(chunk)
    end
    file:close()
    return append()
end

--- MD5 of each file (the same on every device): md5sum where there is one
--- (fast), KOReader's own otherwise. Returns { [path] = hash }.
function Engine.md5Files(paths)
    local hashes = {}
    for i = 1, #paths, 40 do
        local args = {}
        for j = i, math.min(i + 39, #paths) do table.insert(args, quote(paths[j])) end
        local pipe = io.popen("md5sum -- " .. table.concat(args, " ") .. " 2>/dev/null")
        if pipe then
            for line in pipe:lines() do
                local hash, path = line:match("^(%x+)  (.*)$")
                if hash and #hash == 32 then hashes[path] = hash end
            end
            pipe:close()
        end
    end
    for _, path in ipairs(paths) do
        if not hashes[path] then hashes[path] = md5Lua(path) end
    end
    return hashes
end

-- Tables on disk ----------------------------------------------------------

-- Tab-separated lines; paths can't hold tabs or newlines.
local function loadTsv(path, fields)
    local rows = {}
    local data = readFile(path)
    if not data then return rows end
    for line in data:gmatch("[^\n]+") do
        local row, i = {}, 1
        for value in (line .. "\t"):gmatch("([^\t]*)\t") do
            row[fields[i] or i] = value
            i = i + 1
        end
        table.insert(rows, row)
    end
    return rows
end

local function saveTsv(path, rows, fields)
    local lines = {}
    for _, row in ipairs(rows) do
        local values = {}
        for _, f in ipairs(fields) do table.insert(values, tostring(row[f] or "")) end
        table.insert(lines, table.concat(values, "\t"))
    end
    return writeFile(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

local function safePath(path)
    return not path:find("[\t\n\r]")
end

local MANIFEST_FIELDS = { "area", "path", "h", "s", "t", "by", "fp" }
local STATE_FIELDS = { "area", "path", "h" }
local CACHE_FIELDS = { "path", "size", "mtime", "h" }

--- { [area] = { [path] = { h, s, t, by, fp } } }
function Engine.parseManifest(text)
    local manifest = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local row, i = {}, 1
        for value in (line .. "\t"):gmatch("([^\t]*)\t") do
            row[MANIFEST_FIELDS[i] or i] = value
            i = i + 1
        end
        if row.area ~= "#" and row.path and row.h and row.h ~= "" then
            manifest[row.area] = manifest[row.area] or {}
            manifest[row.area][row.path] = { h = row.h, s = tonumber(row.s), t = tonumber(row.t), by = row.by,
                fp = row.fp ~= "" and row.fp or nil }
        end
    end
    return manifest
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

function Engine.formatManifest(manifest)
    local lines = { "#\tSettings sync manifest\t2" }
    for _, area in ipairs(sortedKeys(manifest)) do
        for _, path in ipairs(sortedKeys(manifest[area])) do
            local e = manifest[area][path]
            table.insert(lines, table.concat({ area, path, e.h, tostring(e.s or ""),
                tostring(e.t or ""), e.by or "", e.fp or "" }, "\t"))
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Paths -------------------------------------------------------------------

function Engine.paths(kodir)
    local state = kodir .. "/rclonesync"
    return {
        kodir = kodir,
        state = state,
        staging = state .. "/staging",
        pending = state .. "/pending.tsv",
        conflicts = state .. "/conflicts",
        log = state .. "/last.log",
        apply_log = state .. "/apply.log",
    }
end

local function areaDir(paths, area)
    if area.in_state then return paths.state end
    return paths.kodir .. "/" .. area.dir
end

function Engine.listPath(paths, name) return paths.state .. "/" .. name end

function Engine.isPending(paths)
    return lfs().attributes(paths.pending) ~= nil
end

-- Scanning ----------------------------------------------------------------

local function scan(root, rules)
    local files = {}
    local function walk(rel, depth)
        local dir = joinPath(root, rel)
        local ok, iter, state = pcall(lfs().dir, dir)
        if not ok then return end
        for name in iter, state do
            if name ~= "." and name ~= ".." and not name:find(TEMP_SUFFIX, 1, true) then
                local child = joinPath(rel, name)
                local attr = lfs().attributes(root .. "/" .. child)
                if attr and attr.mode == "directory" then
                    if depth < 32 then walk(child, depth + 1) end
                elseif attr and attr.mode == "file" and safePath(child)
                        and Engine.matches(rules, child) then
                    files[child] = { size = attr.size, mtime = attr.modification }
                end
            end
        end
    end
    if lfs().attributes(root, "mode") ~= "directory" then return files end
    if rules.all or not rules.prunable then
        walk("", 0)
    else
        for top in pairs(rules.tops) do
            local attr = lfs().attributes(root .. "/" .. top)
            if attr and attr.mode == "directory" then
                walk(top, 1)
            elseif attr and attr.mode == "file" and Engine.matches(rules, top) then
                files[top] = { size = attr.size, mtime = attr.modification }
            end
        end
    end
    return files
end

-- Hashes for scanned files, from the cache where size and time match.
-- fullOf gives a file's path on the device.
local function hashScan(fullOf, files, cache, new_cache)
    local todo = {}
    for path, f in pairs(files) do
        local full = fullOf(path)
        local c = cache[full]
        if c and tonumber(c.size) == f.size and tonumber(c.mtime) == f.mtime then
            f.h = c.h
        else
            table.insert(todo, full)
        end
    end
    local hashes = Engine.md5Files(todo)
    for path, f in pairs(files) do
        local full = fullOf(path)
        f.h = f.h or hashes[full]
        if f.h then new_cache[full] = { path = full, size = f.size, mtime = f.mtime, h = f.h } end
    end
end

-- The sync ----------------------------------------------------------------

local function newResult()
    return {
        uploaded = 0, downloaded = 0, deleted_here = 0, deleted_server = 0, already_there = 0,
        conflicts = {}, errors = {}, skipped = {}, lines = {},
        restart = false, pending = false,
    }
end

local function say(result, line) table.insert(result.lines, line) end

local function fail(result, area, path, err)
    table.insert(result.errors, area.name .. "/" .. path .. ": " .. tostring(err))
    say(result, "  ! " .. path .. ": " .. tostring(err))
end

-- Download a file into place whole (fonts may be in use, mapped in memory:
-- a file replaced, rather than rewritten, is safe).
local function download(ctx, area, path, dest)
    Engine.mkdirs(dirname(dest))
    local tmp = dest .. TEMP_SUFFIX
    os.remove(tmp)
    local ok, err = ctx.remote:get(area.remote .. "/" .. path, tmp)
    if not ok then
        os.remove(tmp)
        return nil, err == "not_found" and "missing on the server" or err
    end
    local hash = Engine.md5Files({ tmp })[tmp]
    local renamed, rename_err = os.rename(tmp, dest)
    if not renamed then
        os.remove(tmp)
        return nil, rename_err
    end
    return true, hash
end

local function conflictCopy(ctx, area, path)
    local dest = ctx.paths.conflicts .. "/" .. ctx.stamp .. "/" .. area.name .. "/" .. path
    Engine.mkdirs(dirname(dest))
    return dest
end

local function syncTwoWay(ctx, area, result)
    local paths, manifest, state, preview = ctx.paths, ctx.manifest, ctx.state, ctx.preview
    local root = areaDir(paths, area)
    local rules
    if area.patterns then
        rules = Engine.compile(area.patterns)
    elseif area.list then
        local lines = readLines(Engine.listPath(paths, area.list))
        if not lines then
            table.insert(result.skipped, area.name)
            say(result, area.name .. ": skipped, no " .. area.list)
            return
        end
        rules = Engine.compile(lines)
    else
        rules = ALL
    end
    for _, bad in ipairs(rules.bad or {}) do
        table.insert(result.errors, area.list .. ": " .. bad)
        say(result, "  ! " .. bad)
    end
    if rules.koreader and next(rules.koreader) and not area.koreader_paths then
        for rel in pairs(rules.koreader) do
            table.insert(result.errors, area.list .. ": //" .. rel .. ": only settings.txt can list // paths")
            say(result, "  ! //" .. rel .. ": only settings.txt can list // paths")
        end
        rules.koreader = {}
    end

    -- A file's path on the device.
    local function fullOf(path)
        if area.koreader_paths and path:sub(1, #KO) == KO then
            return paths.kodir .. "/" .. path:sub(#KO + 1)
        end
        return root .. "/" .. path
    end

    local L = scan(root, rules)
    if area.koreader_paths then
        -- A folder really called @koreader in settings/ isn't these files.
        for path in pairs(L) do
            if path:sub(1, #KO) == KO then L[path] = nil end
        end
        for rel in pairs(rules.koreader) do
            local attr = lfs().attributes(paths.kodir .. "/" .. rel)
            if attr and attr.mode == "file" then
                L[KO .. rel] = { size = attr.size, mtime = attr.modification }
            end
        end
    end
    hashScan(fullOf, L, ctx.cache, ctx.new_cache)
    manifest[area.name] = manifest[area.name] or {}
    local R = {}
    for path, e in pairs(manifest[area.name]) do
        if Engine.matches(rules, path) then R[path] = e end
    end
    local B = state[area.name] or {}
    local newB = {}

    local all = {}
    for path in pairs(L) do all[path] = true end
    for path in pairs(R) do all[path] = true end
    local staged = area.staged

    -- A file the server's list doesn't know yet (the first sync, or a file
    -- put there some other way) needn't be uploaded if the same file is
    -- there already. The server's own listing tells (Dropbox's does).
    local listing
    local function alreadyThere(path, l)
        if not ctx.remote.contentHash then return false end
        if listing == nil then listing = ctx.remote:list(area.remote) or false end
        local f = listing and listing[path]
        if not (f and f.size == l.size and f.fp) then return false end
        return ctx.remote:contentHash(fullOf(path), paths.state .. "/hash" .. TEMP_SUFFIX) == f.fp
    end

    local function setRemote(path, l)
        manifest[area.name][path] = { h = l.h, s = l.size, t = l.mtime, by = ctx.device }
        ctx.manifest_changed = true
    end
    local function fetch(path, r)
        if preview then return true end
        local dest = staged and paths.staging .. "/" .. path or fullOf(path)
        local ok, hash = download(ctx, area, path, dest)
        if not ok then return nil, hash end
        if hash and hash ~= r.h then
            -- Changed on the server without the manifest: take what's there.
            r.h = hash
            ctx.manifest_changed = true
        end
        if staged then table.insert(ctx.pending, { op = "copy", path = path }) end
        return true
    end

    for _, path in ipairs(sortedKeys(all)) do
        local l, r, b = L[path], R[path], B[path]
        local lh, rh = l and l.h, r and r.h
        local full = fullOf(path)
        if l and not lh then
            fail(result, area, path, "couldn't read it")
            newB[path] = b
        elseif lh == rh then
            newB[path] = lh
        elseif lh == b or (not lh and not b) then
            -- Changed on the server only.
            if rh then
                say(result, "  ↓ " .. path .. (staged and " (at the next start)" or ""))
                local ok, err = fetch(path, r)
                if ok then
                    result.downloaded = result.downloaded + 1
                    newB[path] = r.h
                else
                    fail(result, area, path, err)
                    newB[path] = b
                end
            else
                say(result, "  ✕ " .. path .. " (deleted on another device)")
                if not preview then
                    if staged then
                        table.insert(ctx.pending, { op = "delete", path = path })
                    else
                        os.remove(full)
                    end
                end
                result.deleted_here = result.deleted_here + 1
            end
            if area.restart then result.restart = true end
        elseif rh == b then
            -- Changed here only.
            if lh and not rh and not b and alreadyThere(path, l) then
                say(result, "  = " .. path .. " (already on the server)")
                if not preview then setRemote(path, l) end
                result.already_there = result.already_there + 1
                newB[path] = lh
            elseif lh then
                say(result, "  ↑ " .. path)
                local ok, err = true, nil
                if not preview then
                    ok, err = ctx.remote:mkdirs(dirname(area.remote .. "/" .. path))
                    if ok then ok, err = ctx.remote:put(area.remote .. "/" .. path, full) end
                end
                if ok then
                    if not preview then setRemote(path, l) end
                    result.uploaded = result.uploaded + 1
                    newB[path] = lh
                else
                    fail(result, area, path, err)
                    newB[path] = b
                end
            else
                say(result, "  ✕ " .. path .. " (deleted on the server)")
                local ok, err = true, nil
                if not preview then ok, err = ctx.remote:delete(area.remote .. "/" .. path) end
                if ok then
                    if not preview then
                        manifest[area.name][path] = nil
                        ctx.manifest_changed = true
                    end
                    result.deleted_server = result.deleted_server + 1
                else
                    fail(result, area, path, err)
                    newB[path] = b
                end
            end
        else
            -- Changed on both sides. A change beats a deletion; otherwise
            -- the newer one is kept and the other saved in conflicts/.
            local keep_server
            if not lh then keep_server = true
            elseif not rh then keep_server = false
            else keep_server = (r.t or 0) > (l.mtime or 0) end
            local conflict = {
                path = area.name .. "/" .. path,
                kept = keep_server and (r.by ~= "" and r.by or "the server") or "this device",
            }
            if lh and rh then
                if not preview then
                    local copy = conflictCopy(ctx, area, path)
                    if keep_server then
                        Remote.copyFile(full, copy)
                    else
                        ctx.remote:get(area.remote .. "/" .. path, copy)
                    end
                    conflict.copy = copy
                end
                table.insert(result.conflicts, conflict)
                say(result, "  ! " .. path .. ": changed on both sides, kept the version from "
                    .. conflict.kept)
            end
            if keep_server then
                say(result, "  ↓ " .. path .. (staged and " (at the next start)" or ""))
                local ok, err = fetch(path, r)
                if ok then
                    result.downloaded = result.downloaded + 1
                    newB[path] = r.h
                    if area.restart then result.restart = true end
                else
                    fail(result, area, path, err)
                    newB[path] = b
                end
            else
                say(result, "  ↑ " .. path)
                local ok, err = true, nil
                if not preview then
                    ok, err = ctx.remote:mkdirs(dirname(area.remote .. "/" .. path))
                    if ok then ok, err = ctx.remote:put(area.remote .. "/" .. path, full) end
                end
                if ok then
                    if not preview then setRemote(path, l) end
                    result.uploaded = result.uploaded + 1
                    newB[path] = lh
                else
                    fail(result, area, path, err)
                    newB[path] = b
                end
            end
        end
    end
    ctx.new_state[area.name] = newB
end

-- Fonts: whatever is in the folder on the server, pulled only. Fonts are
-- put there by hand, not by a sync, so a font changed on the server shows
-- only in the server's listing: its size, or the server's ID for the file.
-- The manifest has each font's hash, size and ID; the first device to have
-- a font adds it. A font is downloaded when this device doesn't have the
-- server's version and didn't have it at its last sync, so fonts deleted or
-- changed here stay as they are.
local function syncPullOnly(ctx, area, result)
    local root = areaDir(ctx.paths, area)
    local R, err = ctx.remote:list(area.remote)
    if not R then
        table.insert(result.errors, area.name .. ": " .. tostring(err))
        say(result, "  ! " .. tostring(err))
        ctx.new_state[area.name] = ctx.state[area.name]
        return
    end
    ctx.manifest[area.name] = ctx.manifest[area.name] or {}
    local M = ctx.manifest[area.name]
    local L = scan(root, ALL)
    local B = ctx.state[area.name] or {}
    local newB = {}
    local function changed() ctx.manifest_changed = true end

    -- Another server (the files copied from the old one) has its own IDs for
    -- them all: then fonts the same size as in the manifest are taken as the
    -- same fonts.
    local known, same = false, false
    for path, r in pairs(R) do
        local m = M[path]
        if m and m.fp and r.fp then
            known = true
            if m.fp == r.fp then same = true end
        end
    end
    local moved = known and not same
    if moved then say(result, "  (on a different server: fonts the same size taken as the same)") end

    -- Hashes of this device's fonts, where they're needed.
    local need = {}
    for path in pairs(R) do
        local l, m = L[path], M[path]
        if l and not (m and B[path] == m.h) then need[path] = l end
    end
    hashScan(function(path) return root .. "/" .. path end, need, ctx.cache, ctx.new_cache)

    -- Whether a font here the same size as the server's is the same font:
    -- Dropbox's listing tells. Otherwise only for a font this device hasn't
    -- had from the server (one installed here before the first sync).
    local function sameAsServer(path, r, b)
        if ctx.remote.contentHash and r.fp then
            return ctx.remote:contentHash(root .. "/" .. path, ctx.paths.state .. "/hash" .. TEMP_SUFFIX) == r.fp
        end
        return b == nil
    end
    local function add(path, l, r)
        M[path] = { h = l.h, s = r.size, t = l.mtime, by = ctx.device, fp = r.fp }
        changed()
        return l.h
    end

    for _, path in ipairs(sortedKeys(R)) do
        local r, m, l, b = R[path], M[path], L[path], B[path]
        -- The manifest's entry, if it's still the font on the server.
        if m and m.s == r.size and r.fp and m.fp ~= r.fp and (moved or not m.fp) then
            m.fp = r.fp
            changed()
        end
        if m and not (m.s == r.size and (m.fp == r.fp or not r.fp)) then
            m = nil -- changed on the server
        end
        if m and (b == m.h or (b and b == r.fp)) then
            newB[path] = m.h -- had it at the last sync
        elseif m and l and l.h == m.h then
            newB[path] = m.h -- already here
        elseif not m and b and b == r.fp then
            -- Had it at the last sync, before fonts were in the manifest.
            newB[path] = (l and l.h and l.size == r.size) and add(path, l, r) or b
        elseif not m and l and l.h and l.size == r.size and sameAsServer(path, r, b) then
            newB[path] = add(path, l, r) -- already here, new to the manifest
        else
            say(result, "  ↓ " .. path)
            local ok, hash = true, nil
            if not ctx.preview then ok, hash = download(ctx, area, path, root .. "/" .. path) end
            if ok then
                result.downloaded = result.downloaded + 1
                result.restart = true
                if hash then
                    M[path] = { h = hash, s = r.size, t = os.time(), by = ctx.device, fp = r.fp }
                    changed()
                end
                newB[path] = hash or b
            else
                fail(result, area, path, hash)
                newB[path] = b
            end
        end
    end
    -- Fonts taken off the server leave the manifest (not this device).
    for path in pairs(M) do
        if not R[path] then
            M[path] = nil
            changed()
        end
    end
    ctx.new_state[area.name] = newB
end

local function loadState(paths)
    local state = {}
    for _, row in ipairs(loadTsv(paths.state .. "/state.tsv", STATE_FIELDS)) do
        if row.area and row.path then
            state[row.area] = state[row.area] or {}
            state[row.area][row.path] = row.h
        end
    end
    return state
end

local function saveState(paths, state)
    local rows = {}
    for _, area in ipairs(sortedKeys(state)) do
        for _, path in ipairs(sortedKeys(state[area])) do
            table.insert(rows, { area = area, path = path, h = state[area][path] })
        end
    end
    return saveTsv(paths.state .. "/state.tsv", rows, STATE_FIELDS)
end

local function loadCache(paths)
    local cache = {}
    for _, row in ipairs(loadTsv(paths.state .. "/cache.tsv", CACHE_FIELDS)) do
        if row.path then cache[row.path] = row end
    end
    return cache
end

local function saveCache(paths, cache)
    local rows = {}
    for _, path in ipairs(sortedKeys(cache)) do table.insert(rows, cache[path]) end
    return saveTsv(paths.state .. "/cache.tsv", rows, CACHE_FIELDS)
end

local function writePending(paths, entries)
    local existing = loadTsv(paths.pending, { "op", "path" })
    local seen = {}
    for _, e in ipairs(existing) do seen[e.path] = e end
    for _, e in ipairs(entries) do
        if seen[e.path] then seen[e.path].op = e.op
        else
            table.insert(existing, e)
            seen[e.path] = e
        end
    end
    return saveTsv(paths.pending, existing, { "op", "path" })
end

local function runOnce(ctx, opts)
    local result = newResult()
    local paths = ctx.paths
    ctx.state = loadState(paths)
    ctx.cache = loadCache(paths)
    ctx.new_state, ctx.new_cache, ctx.pending = {}, {}, {}
    ctx.manifest_changed = false

    local incoming = paths.state .. "/manifest.in" .. TEMP_SUFFIX
    os.remove(incoming)
    local ok, version = ctx.remote:get(MANIFEST, incoming)
    local exists = ok
    if ok then
        ctx.manifest = Engine.parseManifest(readFile(incoming))
    elseif version == "not_found" then
        ctx.manifest = {}
        version = nil
    else
        result.fatal = "Couldn't reach the server: " .. tostring(version)
        return result
    end
    os.remove(incoming)

    for _, area in ipairs(Engine.AREAS) do
        say(result, area.name .. ":")
        if area.pull_only then
            syncPullOnly(ctx, area, result)
        else
            syncTwoWay(ctx, area, result)
        end
    end

    if ctx.preview then return result end

    if ctx.manifest_changed then
        local out = paths.state .. "/manifest.out" .. TEMP_SUFFIX
        writeFile(out, Engine.formatManifest(ctx.manifest))
        local put_ok, err = ctx.remote:put(MANIFEST, out, { version = version, create = not exists })
        os.remove(out)
        if not put_ok then
            if err == "conflict" then return "retry" end
            result.fatal = "Couldn't save the file list on the server: " .. tostring(err)
            return result
        end
    end

    -- Keep the state of areas this run didn't look at.
    for area, files in pairs(ctx.state) do
        if not ctx.new_state[area] then ctx.new_state[area] = files end
    end
    saveState(paths, ctx.new_state)
    for path, row in pairs(ctx.cache) do
        if not ctx.new_cache[path] and lfs().attributes(path) then ctx.new_cache[path] = row end
    end
    saveCache(paths, ctx.new_cache)
    if #ctx.pending > 0 then
        writePending(paths, ctx.pending)
        result.pending = true
        result.restart = true
    end
    return result
end

--- Sync with the server.
---   ctx:  { paths = Engine.paths(kodir), remote, device }
---   opts: { preview }
--- Returns a result: counts, conflicts, errors, restart, pending, fatal, log.
function Engine.sync(ctx, opts)
    opts = opts or {}
    ctx.preview = opts.preview
    ctx.stamp = os.date("%Y-%m-%d_%H%M%S")
    Engine.mkdirs(ctx.paths.state)
    local result
    if not opts.preview and Engine.isPending(ctx.paths) then
        result = newResult()
        result.fatal = "Pulled settings are waiting for a restart."
    else
        for _ = 1, 3 do
            result = runOnce(ctx, opts)
            if result ~= "retry" then break end
        end
        if result == "retry" then
            result = newResult()
            result.fatal = "Another device kept syncing at the same time. Try again in a moment."
        end
    end
    local header = os.date("%Y-%m-%d %H:%M:%S") .. (opts.preview and " preview" or " sync")
    result.log = header .. "\n" .. table.concat(result.lines, "\n")
        .. (result.fatal and "\n\n" .. result.fatal or "") .. "\n"
    if not opts.preview then writeFile(ctx.paths.log, result.log) end
    result.lines = nil
    return result
end

--- Put pulled settings in place. Run as KOReader starts, before plugins
--- read their settings. Returns nil if there was nothing to do, otherwise
--- ok and the log.
function Engine.applyPending(paths)
    if not Engine.isPending(paths) then return nil end
    local entries = loadTsv(paths.pending, { "op", "path" })
    local settings = paths.kodir .. "/settings"
    local failed, lines = {}, {}
    for _, e in ipairs(entries) do
        local path = e.path or ""
        local dest = path:sub(1, #KO) == KO and paths.kodir .. "/" .. path:sub(#KO + 1)
            or settings .. "/" .. path
        local ok, err
        if e.op == "copy" then
            local src = paths.staging .. "/" .. e.path
            Engine.mkdirs(dirname(dest))
            ok, err = Remote.copyFile(src, dest .. TEMP_SUFFIX)
            if ok then ok, err = os.rename(dest .. TEMP_SUFFIX, dest) end
            if ok then os.remove(src) end
        elseif e.op == "delete" then
            os.remove(dest)
            ok = lfs().attributes(dest) == nil
            err = "couldn't delete"
        end
        table.insert(lines, (ok and "  " or "  ! ") .. e.op .. " " .. tostring(e.path)
            .. (ok and "" or ": " .. tostring(err)))
        if not ok then table.insert(failed, e) end
    end
    if #failed > 0 then
        saveTsv(paths.pending, failed, { "op", "path" })
    else
        os.remove(paths.pending)
    end
    local log = os.date("%Y-%m-%d %H:%M:%S") .. " put pulled settings in place\n"
        .. table.concat(lines, "\n") .. "\n"
    writeFile(paths.apply_log, log)
    return #failed == 0, log
end

--- Forget pulled settings waiting for a restart.
function Engine.discardPending(paths)
    os.remove(paths.pending)
end

return Engine
