--[[--
The sync itself: which files, what changed, and making both sides agree.

What's synced is what one list names, settings/concordance/sync.txt: a
pattern per line, from KOReader's folder (see Engine.compile). The list
itself is always synced, first, so the rest uses the newest one.

On the server, under the sync folder (<folder>/Files):

    manifest.tsv     every synced file with its hash, size, time and device
                     (and for files only ever pulled, the server's ID for it)
    files/           the files, laid out as in KOReader's folder

On the device, in settings/concordance/settings-sync/: state.tsv (what each
file was when this device last synced), pending.tsv and staging/ (pulled
settings waiting for the next start), conflicts/, last.log and apply.log.
cache/concordance/settings-cache.tsv keeps hashes, so unchanged files aren't
read again.

Comparing a file with its state at the last sync tells which side changed
it, so a file a device never had isn't taken as deleted there. When both
sides changed a file, the newer one is kept and the other is saved in
conflicts/.

Settings files that KOReader keeps in memory (gestures.lua and the like)
would be written over with the old values when KOReader next saves them.
So they're downloaded into staging/ and put in place the next time
KOReader starts, before any plugin has read them. Plugins, patches, fonts,
dictionaries and style tweaks are only read at the start, so they're
written straight away (see Engine.behaviour).

This runs in a separate process during a sync: no UI here.
--]]--

local Remote = require("concordance/remote")

local Engine = {}

local TEMP_SUFFIX = ".concordance-part"
local MANIFEST = "manifest.tsv"
local MANIFEST_HEADER = "#\tConcordance manifest\t3"
-- On the server, the files are in files/, by their path in KOReader's folder.
local FILES = "files"

--- The list, by its path in KOReader's folder.
Engine.LIST = "settings/concordance/sync.txt"

-- Never synced, whatever the list says ------------------------------------

-- Concordance's own folder: only its shared settings and the list are synced
-- (device.lua and state.sqlite3 are this device's own: devices sharing them
-- would share an ID).
local OWN = "settings/concordance/"
local OWN_SYNCED = { ["settings/concordance/settings.lua"] = true, [Engine.LIST] = true }
-- Not even looked through.
local SKIPPED_DIRS = { ["cache"] = true, ["settings/concordance/settings-sync"] = true }
--- Plugins that update themselves from GitHub: a sync would fight the
-- updater over their folders. (omnisync.koplugin: Concordance's old name,
-- left in plugins/ until it's deleted.)
Engine.SELF_UPDATING = { "concordance.koplugin", "knuthplass.koplugin", "omnisync.koplugin" }

--- Why a file is never synced, or nil if it can be. Also a key to report it
-- under, once for a whole folder.
function Engine.excluded(path)
    if path:sub(1, #OWN) == OWN and not OWN_SYNCED[path] then
        return "Concordance's own, never synced", path
    end
    for dir in pairs(SKIPPED_DIRS) do
        if path:sub(1, #dir + 1) == dir .. "/" then return "never synced", dir .. "/" end
    end
    for _, name in ipairs(Engine.SELF_UPDATING) do
        local dir = "plugins/" .. name .. "/"
        if path:sub(1, #dir) == dir then return "updates itself, never synced", dir end
    end
    return nil
end

-- How a pulled file is put in place ----------------------------------------

-- Written straight into place, and whether KOReader needs a restart to use
-- it. Anything else is put in place at the next start.
local DIRECT = {
    { prefix = "plugins/", restart = true },
    { prefix = "patches/", restart = true },
    { prefix = "fonts/", restart = true },
    { prefix = "data/dict/", restart = true },
    { prefix = "styletweaks/", restart = false },
}

--- staged (put in place at the next start), restart (KOReader uses the new
-- file only after a restart) for a file pulled from the server.
function Engine.behaviour(path)
    if path == Engine.LIST then return false, false end
    for _, d in ipairs(DIRECT) do
        if path:sub(1, #d.prefix) == d.prefix then return false, d.restart end
    end
    return true, true
end

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

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

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

-- The folders at the start of a pattern without wildcards: only they need
-- looking through. Returns the folder, or the whole path (and true) when
-- the pattern names one file.
local function literalBase(alt)
    local base = {}
    for part in alt:gmatch("[^/]+") do
        if part:find("[%*%?%[\\]") then return table.concat(base, "/"), false end
        table.insert(base, part)
    end
    return alt, true
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Why a pattern (after the leading /, braces expanded) can't be used, or nil.
local function badPattern(alt)
    if alt == "" then return "no file named" end
    if alt:sub(-1) == "/" then return "ends with /: use /** for the files in a folder" end
    if alt:find("[\t\r\n]") then return "tabs and line breaks can't be synced" end
    for part in (alt .. "/"):gmatch("([^/]*)/") do
        if part == "" or part == "." or part == ".." then return "not a plain path" end
    end
    return nil
end

--- Rules from the lines of the list: one rclone-style pattern per line,
--- from KOReader's folder, starting with /. # or ; start a comment. A line
--- starting with < names files that are only ever pulled from the server
--- (never uploaded, never deleted here). Lines that can't be used go in
--- rules.bad, with why.
function Engine.compile(lines)
    local rules = { sync = {}, pull = {}, bad = {} }
    for _, raw in ipairs(lines) do
        local line = trim(raw)
        if line ~= "" and not line:match("^[#;]") then
            local pull = false
            if line:sub(1, 1) == "<" then
                pull = true
                line = trim(line:sub(2))
            end
            local why
            if line:sub(1, 2) == "//" then
                why = "starts with //: list files from KOReader's folder with a single /"
            elseif line:sub(1, 1) ~= "/" then
                why = "doesn't start with /: list files from KOReader's folder, such as /settings/gestures.lua"
            end
            local found = {}
            if not why then
                for _, alt in ipairs(expandBraces(line:sub(2))) do
                    why = badPattern(alt)
                    if why then break end
                    local base, exact = literalBase(alt)
                    table.insert(found, { pattern = "^" .. globToLua(alt) .. "$", base = base, exact = exact })
                end
            end
            if why then
                table.insert(rules.bad, trim(raw) .. ": " .. why)
            else
                for _, rule in ipairs(found) do table.insert(pull and rules.pull or rules.sync, rule) end
            end
        end
    end
    return rules
end

local function matchAny(list, path)
    for _, rule in ipairs(list) do
        if path:find(rule.pattern) then return true end
    end
    return false
end

--- "pull" (a line starting with < names it: that wins) or "sync" if the
--- rules name the path, otherwise nil.
function Engine.kind(rules, path)
    if matchAny(rules.pull, path) then return "pull" end
    if matchAny(rules.sync, path) then return "sync" end
    return nil
end

function Engine.matches(rules, path)
    return Engine.kind(rules, path) ~= nil
end

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

local function splitTabs(line)
    local row = {}
    for value in (line .. "\t"):gmatch("([^\t]*)\t") do table.insert(row, value) end
    return row
end

-- Tab-separated lines; paths can't hold tabs or newlines.
local function loadTsv(path, fields)
    local rows = {}
    local data = readFile(path)
    if not data then return rows end
    for line in data:gmatch("[^\n]+") do
        local row = {}
        for i, value in ipairs(splitTabs(line)) do row[fields[i] or i] = value end
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

--- Whether a path is a plain one inside KOReader's folder: no empty, "."
-- or ".." part (so no leading / either), no control characters. Paths from
-- the server (its file list, its folders) and from pending.tsv are only
-- used if they are: one with ".." could reach outside KOReader's folder,
-- or the files that are never synced.
local function safePath(path)
    if type(path) ~= "string" or path == "" or path:find("%c") then return false end
    for part in (path .. "/"):gmatch("([^/]*)/") do
        if part == "" or part == "." or part == ".." then return false end
    end
    return true
end
Engine.safePath = safePath

-- kind is "sync" or "pull" (see Engine.kind).
local STATE_FIELDS = { "kind", "path", "h" }
local CACHE_FIELDS = { "path", "size", "mtime", "h" }

--- { [path] = { h, s, t, by, fp } }, or nil and why if it's a file list
--- from another version.
function Engine.parseManifest(text)
    local manifest = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local row = splitTabs(line)
        if row[1] == "#" then
            if row[3] and row[3] ~= "3" then
                return nil, "The file list on the server is in another format (" .. tostring(row[3])
                    .. "): it's from an older version of Concordance."
            end
        elseif safePath(row[1]) and row[2] and row[2] ~= "" then
            manifest[row[1]] = { h = row[2], s = tonumber(row[3]), t = tonumber(row[4]), by = row[5],
                fp = row[6] ~= "" and row[6] or nil }
        end
    end
    return manifest
end

function Engine.formatManifest(manifest)
    local lines = { MANIFEST_HEADER }
    for _, path in ipairs(sortedKeys(manifest)) do
        local e = manifest[path]
        table.insert(lines, table.concat({ path, e.h, tostring(e.s or ""),
            tostring(e.t or ""), e.by or "", e.fp or "" }, "\t"))
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Paths -------------------------------------------------------------------

function Engine.paths(kodir)
    local state = kodir .. "/settings/concordance/settings-sync"
    return {
        kodir = kodir,
        list = kodir .. "/" .. Engine.LIST,
        state = state,
        staging = state .. "/staging",
        pending = state .. "/pending.tsv",
        conflicts = state .. "/conflicts",
        log = state .. "/last.log",
        apply_log = state .. "/apply.log",
        cache = kodir .. "/cache/concordance/settings-cache.tsv",
    }
end

function Engine.isPending(paths)
    return lfs().attributes(paths.pending) ~= nil
end

local function remotePath(path) return FILES .. "/" .. path end

-- Scanning ----------------------------------------------------------------

-- The files in KOReader's folder the rules name: { [path] = { size, mtime,
-- kind } }. Files named but never synced go in kept_out (why, by key). The
-- list itself is left out: it's synced on its own.
local function scan(kodir, rules, kept_out)
    local files = {}
    local function consider(rel, attr)
        if rel == Engine.LIST or not safePath(rel) then return end
        local kind = Engine.kind(rules, rel)
        if not kind then return end
        local why, key = Engine.excluded(rel)
        if why then
            kept_out[key] = why
            return
        end
        files[rel] = { size = attr.size, mtime = attr.modification, kind = kind }
    end
    local walked = {}
    local function walk(rel, depth)
        if SKIPPED_DIRS[rel] or walked[rel] then return end
        walked[rel] = true
        local dir = rel == "" and kodir or kodir .. "/" .. rel
        local ok, iter, state = pcall(lfs().dir, dir)
        if not ok then return end
        for name in iter, state do
            if name ~= "." and name ~= ".." and not name:find(TEMP_SUFFIX, 1, true) then
                local child = joinPath(rel, name)
                local attr = lfs().attributes(dir .. "/" .. name)
                if attr and attr.mode == "directory" then
                    if depth < 32 then walk(child, depth + 1) end
                elseif attr and attr.mode == "file" then
                    consider(child, attr)
                end
            end
        end
    end
    local bases = {}
    for _, list in ipairs({ rules.sync, rules.pull }) do
        for _, rule in ipairs(list) do bases[rule.base] = true end
    end
    -- Sorted, a folder comes before those in it, which it covers.
    for _, base in ipairs(sortedKeys(bases)) do
        local attr = lfs().attributes(base == "" and kodir or kodir .. "/" .. base)
        if attr and attr.mode == "directory" then
            local depth = base == "" and 0 or select(2, base:gsub("/", "")) + 1
            walk(base, depth)
        elseif attr and attr.mode == "file" then
            consider(base, attr)
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

local function fail(result, path, err)
    table.insert(result.errors, path .. ": " .. tostring(err))
    say(result, "  ! " .. path .. ": " .. tostring(err))
end

-- Download a file into place whole (fonts may be in use, mapped in memory:
-- a file replaced, rather than rewritten, is safe).
local function download(ctx, path, dest)
    Engine.mkdirs(dirname(dest))
    local tmp = dest .. TEMP_SUFFIX
    os.remove(tmp)
    local ok, err = ctx.remote:get(remotePath(path), tmp)
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

local function conflictCopy(ctx, path)
    local dest = ctx.paths.conflicts .. "/" .. ctx.stamp .. "/" .. path
    Engine.mkdirs(dirname(dest))
    return dest
end

local function fullOf(ctx, path) return ctx.paths.kodir .. "/" .. path end

-- Pull a file from the server: into staging/ for the next start, or into
-- place. Returns ok, err and the downloaded file's hash.
local function fetch(ctx, path)
    if ctx.preview then return true end
    local staged = Engine.behaviour(path)
    local dest = staged and ctx.paths.staging .. "/" .. path or fullOf(ctx, path)
    local ok, hash = download(ctx, path, dest)
    if not ok then return nil, hash end
    if staged then table.insert(ctx.pending, { op = "copy", path = path }) end
    return true, nil, hash
end

local function pulledSay(path)
    local staged = Engine.behaviour(path)
    return "  ↓ " .. path .. (staged and " (at the next start)" or "")
end

--- Both ways: L, the files here; R, the manifest's. State in ctx.state.sync.
local function syncTwoWay(ctx, result, L, R)
    local paths, manifest, preview = ctx.paths, ctx.manifest, ctx.preview
    local B = ctx.state.sync
    local newB = ctx.new_state.sync

    local all = {}
    for path in pairs(L) do all[path] = true end
    for path in pairs(R) do all[path] = true end

    -- A file the server's list doesn't know yet (the first sync, or a file
    -- put there some other way) needn't be uploaded if the same file is
    -- there already. The server's own listing tells (Dropbox's does).
    local listings = {}
    local function alreadyThere(path, l)
        if not ctx.remote.contentHash then return false end
        local dir = dirname(path)
        if listings[dir] == nil then listings[dir] = ctx.remote:list(joinPath(FILES, dir)) or false end
        local f = listings[dir] and listings[dir][dir == "" and path or path:sub(#dir + 2)]
        if not (f and f.size == l.size and f.fp) then return false end
        return ctx.remote:contentHash(fullOf(ctx, path), paths.state .. "/hash" .. TEMP_SUFFIX) == f.fp
    end

    local function setRemote(path, l)
        manifest[path] = { h = l.h, s = l.size, t = l.mtime, by = ctx.device }
        ctx.manifest_changed = true
    end
    local function pull(path, r)
        local ok, err, hash = fetch(ctx, path)
        if not ok then return nil, err end
        if hash and hash ~= r.h then
            -- Changed on the server without the manifest: take what's there.
            r.h = hash
            ctx.manifest_changed = true
        end
        local _, restart = Engine.behaviour(path)
        if restart then result.restart = true end
        return true
    end
    local function push(path, l, b)
        say(result, "  ↑ " .. path)
        local ok, err = true, nil
        if not preview then
            ok, err = ctx.remote:mkdirs(dirname(remotePath(path)))
            if ok then ok, err = ctx.remote:put(remotePath(path), fullOf(ctx, path)) end
        end
        if ok then
            if not preview then setRemote(path, l) end
            result.uploaded = result.uploaded + 1
            newB[path] = l.h
        else
            fail(result, path, err)
            newB[path] = b
        end
    end

    for _, path in ipairs(sortedKeys(all)) do
        local l, r, b = L[path], R[path], B[path]
        local lh, rh = l and l.h, r and r.h
        local full = fullOf(ctx, path)
        if l and not lh then
            fail(result, path, "couldn't read it")
            newB[path] = b
        elseif lh == rh then
            newB[path] = lh
        elseif lh == b or (not lh and not b) then
            -- Changed on the server only.
            if rh then
                say(result, pulledSay(path))
                local ok, err = pull(path, r)
                if ok then
                    result.downloaded = result.downloaded + 1
                    newB[path] = r.h
                else
                    fail(result, path, err)
                    newB[path] = b
                end
            else
                say(result, "  ✕ " .. path .. " (deleted on another device)")
                local staged, restart = Engine.behaviour(path)
                if not preview then
                    if staged then
                        table.insert(ctx.pending, { op = "delete", path = path })
                    else
                        os.remove(full)
                    end
                end
                if restart then result.restart = true end
                result.deleted_here = result.deleted_here + 1
            end
        elseif rh == b then
            -- Changed here only.
            if lh and not rh and not b and alreadyThere(path, l) then
                say(result, "  = " .. path .. " (already on the server)")
                if not preview then setRemote(path, l) end
                result.already_there = result.already_there + 1
                newB[path] = lh
            elseif lh then
                push(path, l, b)
            else
                say(result, "  ✕ " .. path .. " (deleted on the server)")
                local ok, err = true, nil
                if not preview then ok, err = ctx.remote:delete(remotePath(path)) end
                if ok then
                    if not preview then
                        manifest[path] = nil
                        ctx.manifest_changed = true
                    end
                    result.deleted_server = result.deleted_server + 1
                else
                    fail(result, path, err)
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
                path = path,
                kept = keep_server and (r.by ~= "" and r.by or "the server") or "this device",
            }
            if lh and rh then
                if not preview then
                    local copy = conflictCopy(ctx, path)
                    if keep_server then
                        Remote.copyFile(full, copy)
                    else
                        ctx.remote:get(remotePath(path), copy)
                    end
                    conflict.copy = copy
                end
                table.insert(result.conflicts, conflict)
                say(result, "  ! " .. path .. ": changed on both sides, kept the version from "
                    .. conflict.kept)
            end
            if keep_server then
                say(result, pulledSay(path))
                local ok, err = pull(path, r)
                if ok then
                    result.downloaded = result.downloaded + 1
                    newB[path] = r.h
                else
                    fail(result, path, err)
                    newB[path] = b
                end
            else
                push(path, l, b)
            end
        end
    end
end

-- Files only ever pulled (lines starting with <, such as fonts): whatever
-- is in their folders on the server. They're put there by hand, not by a
-- sync, so a file changed on the server shows only in the server's
-- listing: its size, or the server's ID for the file. The manifest has each
-- file's hash, size and ID; the first device to have a file adds it. A file
-- is downloaded when this device doesn't have the server's version and
-- didn't have it at its last sync, so files deleted or changed here stay as
-- they are. State in ctx.state.pull.
local function syncPullOnly(ctx, result, rules, L)
    -- The server's files, from the folders the < lines start with.
    local dirs = {}
    for _, rule in ipairs(rules.pull) do dirs[rule.exact and dirname(rule.base) or rule.base] = true end
    local R, listed = {}, {}
    for _, dir in ipairs(sortedKeys(dirs)) do
        local covered = false
        for done in pairs(listed) do
            if done == "" or dir:sub(1, #done + 1) == done .. "/" then covered = true end
        end
        if not covered then
            local files, err = ctx.remote:list(joinPath(FILES, dir))
            if not files then
                table.insert(result.errors, dir .. ": " .. tostring(err))
                say(result, "  ! " .. tostring(err))
                for path, h in pairs(ctx.state.pull) do ctx.new_state.pull[path] = h end
                return
            end
            listed[dir] = true
            for rel, f in pairs(files) do
                local path = joinPath(dir, rel)
                if safePath(path) and not path:find(TEMP_SUFFIX, 1, true) and path ~= Engine.LIST
                        and Engine.kind(rules, path) == "pull" and not Engine.excluded(path) then
                    R[path] = f
                end
            end
        end
    end
    local function inListed(path)
        for dir in pairs(listed) do
            if dir == "" or path:sub(1, #dir + 1) == dir .. "/" then return true end
        end
        return false
    end

    local M = ctx.manifest
    local B = ctx.state.pull
    local newB = ctx.new_state.pull
    local function changed() ctx.manifest_changed = true end

    -- Another server (the files copied from the old one) has its own IDs for
    -- them all: then files the same size as in the manifest are taken as the
    -- same files.
    local known, same = false, false
    for path, r in pairs(R) do
        local m = M[path]
        if m and m.fp and r.fp then
            known = true
            if m.fp == r.fp then same = true end
        end
    end
    local moved = known and not same
    if moved then say(result, "  (on a different server: files the same size taken as the same)") end

    -- Hashes of this device's files, where they're needed.
    local need = {}
    for path in pairs(R) do
        local l, m = L[path], M[path]
        if l and not (m and B[path] == m.h) then need[path] = l end
    end
    hashScan(function(path) return fullOf(ctx, path) end, need, ctx.cache, ctx.new_cache)

    -- Whether a file here the same size as the server's is the same file:
    -- Dropbox's listing tells. Otherwise only for a file this device hasn't
    -- had from the server (one put here by hand before the first sync).
    local function sameAsServer(path, r, b)
        if ctx.remote.contentHash and r.fp then
            return ctx.remote:contentHash(fullOf(ctx, path), ctx.paths.state .. "/hash" .. TEMP_SUFFIX) == r.fp
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
        -- The manifest's entry, if it's still the file on the server.
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
            -- Had it at the last sync, before it was in the manifest.
            newB[path] = (l and l.h and l.size == r.size) and add(path, l, r) or b
        elseif not m and l and l.h and l.size == r.size and sameAsServer(path, r, b) then
            newB[path] = add(path, l, r) -- already here, new to the manifest
        else
            say(result, pulledSay(path))
            local ok, err, hash = fetch(ctx, path)
            if ok then
                result.downloaded = result.downloaded + 1
                local _, restart = Engine.behaviour(path)
                if restart then result.restart = true end
                if hash then
                    M[path] = { h = hash, s = r.size, t = os.time(), by = ctx.device, fp = r.fp }
                    changed()
                end
                newB[path] = hash or b
            else
                fail(result, path, err)
                newB[path] = b
            end
        end
    end
    -- Files taken off the server leave the manifest (not this device).
    for path in pairs(M) do
        if not R[path] and inListed(path) and Engine.kind(rules, path) == "pull" then
            M[path] = nil
            changed()
        end
    end
end

local function loadState(paths)
    local state = { sync = {}, pull = {} }
    for _, row in ipairs(loadTsv(paths.state .. "/state.tsv", STATE_FIELDS)) do
        if state[row.kind] and row.path and row.h then state[row.kind][row.path] = row.h end
    end
    return state
end

local function saveState(paths, state)
    local rows = {}
    for _, kind in ipairs({ "pull", "sync" }) do
        for _, path in ipairs(sortedKeys(state[kind])) do
            table.insert(rows, { kind = kind, path = path, h = state[kind][path] })
        end
    end
    return saveTsv(paths.state .. "/state.tsv", rows, STATE_FIELDS)
end
Engine.loadState = loadState
Engine.saveState = saveState

local function loadCache(paths)
    local cache = {}
    for _, row in ipairs(loadTsv(paths.cache, CACHE_FIELDS)) do
        if row.path then cache[row.path] = row end
    end
    return cache
end

local function saveCache(paths, cache)
    local rows = {}
    for _, path in ipairs(sortedKeys(cache)) do table.insert(rows, cache[path]) end
    return saveTsv(paths.cache, rows, CACHE_FIELDS)
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

local function runOnce(ctx)
    local result = newResult()
    local paths = ctx.paths
    ctx.state = loadState(paths)
    ctx.cache = loadCache(paths)
    ctx.new_state, ctx.new_cache, ctx.pending = { sync = {}, pull = {} }, {}, {}
    ctx.manifest_changed = false

    local incoming = paths.state .. "/manifest.in" .. TEMP_SUFFIX
    os.remove(incoming)
    local ok, version = ctx.remote:get(MANIFEST, incoming)
    local exists = ok
    if ok then
        local manifest, why = Engine.parseManifest(readFile(incoming))
        os.remove(incoming)
        if not manifest then
            result.fatal = why
            return result
        end
        ctx.manifest = manifest
    elseif version == "not_found" then
        ctx.manifest = {}
        version = nil
        -- A folder without a manifest is new (or not copied over yet, after
        -- moving): what this device remembers is about another folder, and
        -- would make every file look deleted on the server. Sync as if for
        -- the first time: upload, never delete. (Pulled files are never
        -- deleted here, and their state says which were deleted on this
        -- device.)
        if next(ctx.state.sync) then
            ctx.state.sync = {}
            say(result, "No " .. MANIFEST .. " on the server: syncing as for the first time (nothing is deleted).")
        end
    else
        result.fatal = "Couldn't reach the server: " .. tostring(version)
        return result
    end
    os.remove(incoming)

    -- The list first, so the rest uses the newest one. (A preview doesn't
    -- download it: it shows what this device's list would do.)
    say(result, "list:")
    local L = {}
    local attr = lfs().attributes(paths.list)
    if attr and attr.mode == "file" then L[Engine.LIST] = { size = attr.size, mtime = attr.modification } end
    hashScan(function(path) return fullOf(ctx, path) end, L, ctx.cache, ctx.new_cache)
    syncTwoWay(ctx, result, L, { [Engine.LIST] = ctx.manifest[Engine.LIST] })

    local lines = readLines(paths.list)
    if not lines then
        table.insert(result.skipped, Engine.LIST)
        say(result, "No " .. Engine.LIST .. ": nothing else to sync.")
        for path, h in pairs(ctx.state.sync) do
            if ctx.new_state.sync[path] == nil and path ~= Engine.LIST then ctx.new_state.sync[path] = h end
        end
        ctx.new_state.pull = ctx.state.pull
    else
        local rules = Engine.compile(lines)
        for _, bad in ipairs(rules.bad) do
            table.insert(result.errors, "sync.txt: " .. bad)
            say(result, "  ! " .. bad)
        end
        say(result, "files:")
        local kept_out = {}
        local found = scan(paths.kodir, rules, kept_out)
        local Ls, Lp = {}, {}
        for path, f in pairs(found) do
            if f.kind == "pull" then Lp[path] = f else Ls[path] = f end
        end
        hashScan(function(path) return fullOf(ctx, path) end, Ls, ctx.cache, ctx.new_cache)
        local Rs = {}
        for path, e in pairs(ctx.manifest) do
            if path ~= Engine.LIST and Engine.kind(rules, path) == "sync" then
                local why, key = Engine.excluded(path)
                if why then kept_out[key] = why else Rs[path] = e end
            end
        end
        for _, key in ipairs(sortedKeys(kept_out)) do say(result, "  - " .. key .. ": " .. kept_out[key]) end
        syncTwoWay(ctx, result, Ls, Rs)
        if #rules.pull > 0 then
            say(result, "pulled only:")
            syncPullOnly(ctx, result, rules, Lp)
        else
            ctx.new_state.pull = ctx.state.pull
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
    Engine.mkdirs(dirname(ctx.paths.cache))
    local result
    if not opts.preview and Engine.isPending(ctx.paths) then
        result = newResult()
        result.fatal = "Pulled settings are waiting for a restart."
    else
        for _ = 1, 3 do
            result = runOnce(ctx)
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
    local failed, lines, refused = {}, {}, false
    for _, e in ipairs(entries) do
        local dest = paths.kodir .. "/" .. (e.path or "")
        local ok, err
        if not safePath(e.path) or Engine.excluded(e.path) then
            -- Never written by a sync: refused, and not tried again.
            lines[#lines + 1] = "  ! " .. tostring(e.op) .. " " .. tostring(e.path) .. ": not a path to change"
            ok, refused = true, true
        elseif e.op == "copy" then
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
        if refused then
            refused = false
        else
            table.insert(lines, (ok and "  " or "  ! ") .. tostring(e.op) .. " " .. tostring(e.path)
                .. (ok and "" or ": " .. tostring(err)))
        end
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

Engine.readFile = readFile
Engine.writeFile = writeFile

return Engine
