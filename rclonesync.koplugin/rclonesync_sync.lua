--[[--
The rclone side of Settings sync: where things are, the commands to run,
and reading what rclone reported.

The remote is laid out much as the PushSettings.sh/PullSettings.sh scripts
had it, except that settings/ holds the contents of KOReader's settings/
folder (the scripts kept KOReader's whole folder there):

    <remote>:<root>/rclone/settings.txt   the lists of what to sync
    <remote>:<root>/rclone/plugins.txt
    <remote>:<root>/rclone/patches.txt
    <remote>:<root>/settings/             what settings.txt lists in settings/
    <remote>:<root>/plugins/              what plugins.txt lists in plugins/
    <remote>:<root>/patches/              what patches.txt lists in patches/
    <remote>:<root>/fonts/                pulled only, nothing deleted
    <remote>:<root>/dict/                 KOReader's data/dict
    <remote>:<root>/styletweaks/

Settings files that KOReader keeps in memory (gestures.lua and the like)
would be written over with the old values when KOReader next saves them.
So a pull puts them in a staging folder, and they're copied into place the
next time KOReader starts, before any plugin has read them.
--]]--

local Sync = {}

-- In the order they run: the list first, so a pull uses the new one.
--   dir:       under KOReader's folder ("" for the folder itself)
--   in_rclone: under the rclone folder instead
--   list:      only what this file in the rclone folder lists
--   tweaks:    also part of "style tweaks only"
--   pull_only: never pushed, and a pull adds and updates files but never
--              deletes them (fonts installed on one device stay there)
--   staged:    pulled into the staging folder (see above)
--   restart:   KOReader uses the files only after a restart
Sync.JOBS = {
    { name = "list", in_rclone = true, dir = "", remote = "rclone", tweaks = true,
      filter = { "--include", "/settings.txt", "--include", "/plugins.txt",
                 "--include", "/patches.txt" } },
    { name = "settings", dir = "settings", remote = "settings", list = "settings.txt", staged = true },
    { name = "plugins", dir = "plugins", remote = "plugins", list = "plugins.txt", restart = true },
    { name = "fonts", dir = "fonts", remote = "fonts", pull_only = true, restart = true },
    { name = "patches", dir = "patches", remote = "patches", list = "patches.txt", restart = true },
    { name = "dict", dir = "data/dict", remote = "dict", restart = true },
    { name = "styletweaks", dir = "styletweaks", remote = "styletweaks", tweaks = true },
}

-- The flags the scripts used: compare by checksum, as file times differ
-- between devices and cloud storage.
local FLAGS = "--checksum --no-update-modtime --modify-window 1m"

local function lfs()
    return require("libs/libkoreader-lfs")
end

local function exists(path, mode)
    local attr = path and lfs().attributes(path)
    return attr ~= nil and (mode == nil or attr.mode == mode)
end

--- Quote a string for sh.
function Sync.quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
local q = Sync.quote

--- KOReader's data folder, made absolute ("." on e-readers).
function Sync.dataDir()
    local dir = require("datastorage"):getDataDir()
    if dir:sub(1, 1) ~= "/" then
        dir = lfs().currentdir() .. (dir == "." and "" or "/" .. dir:gsub("^%./", ""))
    end
    return (dir:gsub("/+$", ""))
end

--- Where the rclone folder (rclone, rclone.conf and the lists) might be:
--- next to KOReader's folder, as the scripts had it (.adds/rclone on Kobo,
--- /mnt/us/rclone on Kindle, ~/.config/rclone on Linux), in it, or in the
--- plugin's folder.
function Sync.candidateDirs(kodir, plugin_path)
    local parent = kodir:match("^(.*)/[^/]+$") or ""
    local dirs = { parent .. "/rclone", kodir .. "/rclone" }
    if plugin_path then table.insert(dirs, plugin_path) end
    return dirs
end

function Sync.findRcloneDir(kodir, plugin_path)
    for _, dir in ipairs(Sync.candidateDirs(kodir, plugin_path)) do
        if exists(dir .. "/rclone", "file") or exists(dir .. "/rclone.conf", "file") then
            return dir
        end
    end
end

local function android()
    local ok, module = pcall(require, "android")
    return ok and type(module) == "table" and module.dir and module or nil
end

local function onPath(name)
    local pipe = io.popen("command -v " .. q(name) .. " 2>/dev/null")
    if not pipe then return nil end
    local path = pipe:read("*l")
    pipe:close()
    return path ~= "" and path or nil
end

--- Everything a run needs, from the plugin's settings. Returns nil and a
--- message if rclone can't be found.
---   opts: { rclone_dir, remote, root, dry_run }
function Sync.context(opts, plugin_path)
    opts = opts or {}
    local kodir = Sync.dataDir()
    local rclone_dir = opts.rclone_dir or Sync.findRcloneDir(kodir, plugin_path)
    if not rclone_dir then
        return nil, "no_folder", Sync.candidateDirs(kodir, plugin_path)
    end
    rclone_dir = rclone_dir:gsub("/+$", "")
    local ctx = {
        kodir = kodir,
        rclone_dir = rclone_dir,
        state_dir = kodir .. "/rclonesync",
        root = opts.root or "/KOReader/Settings",
        dry_run = opts.dry_run and true or false,
    }
    local bundled = rclone_dir .. "/rclone"
    if exists(bundled, "file") then
        local A = android()
        if A then
            -- Android runs programs only from the app's private storage.
            ctx.source_binary = bundled
            ctx.binary = A.dir:match("^(.*)/[^/]+$") .. "/rclonesync/rclone"
        else
            ctx.binary = bundled
        end
    else
        ctx.binary = onPath("rclone")
        if not ctx.binary then return nil, "no_binary", { bundled } end
    end
    if exists(rclone_dir .. "/rclone.conf", "file") then
        ctx.config = rclone_dir .. "/rclone.conf"
    end
    -- KOReader's own certificates; or the ones the scripts downloaded.
    for _, ca in ipairs({ lfs().currentdir() .. "/data/ca-bundle.crt", "/tmp/ca-bundle.crt" }) do
        if exists(ca, "file") then
            ctx.ca = ca
            break
        end
    end
    ctx.remote = opts.remote or Sync.remotes(ctx)[1] or "Dropbox"
    return ctx
end

--- The remotes in rclone.conf (or rclone's own config, if there's none).
function Sync.remotes(ctx)
    local names = {}
    if ctx.config then
        local file = io.open(ctx.config, "r")
        if file then
            for line in file:lines() do
                local name = line:match("^%s*%[(.-)%]%s*$")
                if name and name ~= "" then table.insert(names, name) end
            end
            file:close()
        end
    elseif ctx.binary then
        local pipe = io.popen(q(ctx.binary) .. " listremotes 2>/dev/null")
        if pipe then
            for line in pipe:lines() do
                local name = line:match("^(.-):%s*$")
                if name then table.insert(names, name) end
            end
            pipe:close()
        end
    end
    return names
end

--- A list in the rclone folder (settings.txt by default).
function Sync.listPath(ctx, name) return ctx.rclone_dir .. "/" .. (name or "settings.txt") end
function Sync.settingsDir(ctx) return ctx.kodir .. "/settings" end
function Sync.stagingDir(ctx) return ctx.state_dir .. "/staging" end
function Sync.pendingPath(ctx) return ctx.state_dir .. "/pending" end
function Sync.logPath(ctx) return ctx.state_dir .. "/last.log" end

function Sync.isPending(ctx)
    return exists(Sync.pendingPath(ctx))
end

local function writeFile(path, data)
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    file:write(data)
    file:close()
    return true
end

local function makeStateDir(ctx)
    os.execute("mkdir -p " .. q(ctx.state_dir))
end

function Sync.setPending(ctx)
    makeStateDir(ctx)
    return writeFile(Sync.pendingPath(ctx), os.date("%Y-%m-%d %H:%M:%S") .. "\n")
end

function Sync.saveLog(ctx, output)
    makeStateDir(ctx)
    return writeFile(Sync.logPath(ctx), output)
end

function Sync.readLog(ctx)
    local file = io.open(Sync.logPath(ctx), "r")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

--- On Android, copy rclone to where it can run, when it's new or changed.
function Sync.prepareBinary(ctx)
    if not ctx.source_binary then return true end
    local src = lfs().attributes(ctx.source_binary)
    local dst = lfs().attributes(ctx.binary)
    if dst and src and dst.size == src.size and dst.modification == src.modification then
        return true
    end
    local dir = ctx.binary:match("^(.*)/[^/]+$")
    local ok = os.execute(table.concat({
        "mkdir -p " .. q(dir),
        "cp -p " .. q(ctx.source_binary) .. " " .. q(ctx.binary),
        "chmod 700 " .. q(ctx.binary),
    }, " && "))
    -- os.execute returns 0 (LuaJIT, Lua 5.1) or true (Lua 5.2+).
    return ok == 0 or ok == true
end

--- The start of every rclone command.
function Sync.base(ctx)
    local parts = { q(ctx.binary), "-v" }
    if ctx.config then table.insert(parts, "--config " .. q(ctx.config)) end
    if ctx.ca then table.insert(parts, "--ca-cert " .. q(ctx.ca)) end
    return table.concat(parts, " ")
end

local function localDir(ctx, job)
    local dir = job.in_rclone and ctx.rclone_dir or ctx.kodir
    if job.dir ~= "" then dir = dir .. "/" .. job.dir end
    return dir .. "/"
end

local function remoteDir(ctx, job)
    return ctx.remote .. ":" .. ctx.root:gsub("/+$", "") .. "/" .. job.remote .. "/"
end

local function filterArgs(ctx, job)
    local args = {}
    for _, arg in ipairs(job.filter or {}) do table.insert(args, q(arg)) end
    if job.list then
        table.insert(args, "--include-from " .. q(Sync.listPath(ctx, job.list)))
    end
    return table.concat(args, " ")
end

--- Which jobs a run does.
function Sync.jobs(direction, tweaks_only)
    local jobs = {}
    for _, job in ipairs(Sync.JOBS) do
        if (not tweaks_only or job.tweaks) and not (direction == "push" and job.pull_only) then
            table.insert(jobs, job)
        end
    end
    return jobs
end

--- The shell script for a push or pull. It marks each job in its output
--- (@@job, @@fail, @@skip, @@differ) for Sync.parse.
function Sync.script(ctx, direction, tweaks_only)
    local base = Sync.base(ctx)
    local flags = FLAGS .. (ctx.dry_run and " --dry-run" or "")
    local lines = {}
    local function add(line) table.insert(lines, line) end
    for _, job in ipairs(Sync.jobs(direction, tweaks_only)) do
        add("echo '@@job " .. job.name .. "'")
        local filter = filterArgs(ctx, job)
        local staged = direction == "pull" and job.staged and not ctx.dry_run
        local src, dst
        if direction == "push" then
            src, dst = localDir(ctx, job), remoteDir(ctx, job)
        else
            src, dst = remoteDir(ctx, job), staged and Sync.stagingDir(ctx) .. "/" or localDir(ctx, job)
        end
        local cmd = (staged and "mkdir -p " .. q(Sync.stagingDir(ctx)) .. "\n" or "")
            .. base .. " " .. (job.pull_only and "copy " or "sync ") .. flags
            .. " " .. filter .. " " .. q(src) .. " " .. q(dst)
            .. " 2>&1 || echo '@@fail " .. job.name .. "'"
        if staged then
            -- Is there anything to put in place?
            cmd = cmd .. "\n" .. base .. " check " .. filter .. " "
                .. q(Sync.stagingDir(ctx) .. "/") .. " " .. q(localDir(ctx, job))
                .. " >/dev/null 2>&1 || echo '@@differ " .. job.name .. "'"
        end
        local conditions = {}
        if job.list then
            table.insert(conditions, { "-f " .. q(Sync.listPath(ctx, job.list)), "no " .. job.list })
        end
        if direction == "push" then
            -- An empty source would empty the remote.
            table.insert(conditions, { "-d " .. q(src), "no folder" })
        end
        for i = #conditions, 1, -1 do
            local test, why = conditions[i][1], conditions[i][2]
            cmd = "if [ " .. test .. " ]; then\n" .. cmd .. "\nelse echo '@@skip "
                .. job.name .. " " .. why .. "'; fi"
        end
        add(cmd)
    end
    add("echo '@@done'")
    return table.concat(lines, "\n")
end

local CHANGE_PATTERNS = {
    ": Copied", ": Deleted", "Skipped copy as %-%-dry%-run", "Skipped delete as %-%-dry%-run",
}

--- What a run did, from its output:
---   { jobs = { [name] = { changes, failed, differ, skipped } }, order,
---     changes, failed, complete, restart, pending }
function Sync.parse(output, direction)
    local result = { jobs = {}, order = {}, changes = 0, failed = false, complete = false }
    local function job(name)
        if not result.jobs[name] then
            result.jobs[name] = { changes = 0 }
            table.insert(result.order, name)
        end
        return result.jobs[name]
    end
    local current
    for line in (output or ""):gmatch("[^\n]+") do
        local tag, rest = line:match("^@@(%a+)%s*(.*)$")
        if tag then
            local name, why = rest:match("^(%S+)%s*(.*)$")
            if tag == "job" then current = job(name)
            elseif tag == "fail" then job(name).failed = true; result.failed = true
            elseif tag == "differ" then job(name).differ = true
            elseif tag == "skip" then job(name).skipped = why
            elseif tag == "done" then result.complete = true
            end
        elseif current then
            for _, pattern in ipairs(CHANGE_PATTERNS) do
                if line:find(pattern) then
                    current.changes = current.changes + 1
                    result.changes = result.changes + 1
                    break
                end
            end
        end
    end
    if not result.complete then result.failed = true end
    if direction == "pull" then
        for _, spec in ipairs(Sync.JOBS) do
            local j = result.jobs[spec.name]
            if j and spec.staged and j.differ and not j.failed then
                result.pending = true
                result.restart = true
            elseif j and spec.restart and j.changes > 0 then
                result.restart = true
            end
        end
    end
    return result
end

--- Put staged settings in place. Run by the plugin as KOReader starts.
--- Returns ok, output.
function Sync.applyPending(ctx)
    local list = Sync.listPath(ctx)
    local ok, output = false, "no " .. list
    if exists(list, "file") then
        local pipe = io.popen(Sync.base(ctx) .. " sync --checksum --include-from " .. q(list)
            .. " " .. q(Sync.stagingDir(ctx) .. "/") .. " " .. q(Sync.settingsDir(ctx) .. "/")
            .. " 2>&1 && echo '@@done'")
        output = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end
        ok = output:find("@@done") ~= nil
    end
    if ok then os.remove(Sync.pendingPath(ctx)) end
    Sync.saveLog(ctx, output)
    return ok, output
end

return Sync
