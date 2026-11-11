-- Exercises concordance.koplugin's settings sync: list patterns, JSON, the sync engine with
-- simulated devices and a folder standing in for the server, the Dropbox
-- and WebDAV clients against a fake HTTP layer, and the plugin's flow
-- against stubbed KOReader modules.
--
-- Needs LuaFileSystem and md5sum; skipped without them.

package.path = "concordance.koplugin/?.lua;" .. package.path

local function sh(cmd)
    local pipe = io.popen(cmd)
    local out = pipe:read("*a")
    pipe:close()
    return out
end

local have_lfs, lfs = pcall(require, "lfs")
if not have_lfs or sh("command -v md5sum") == "" then
    print("concordance settings: skipped (needs LuaFileSystem and md5sum)")
    return
end
package.loaded["libs/libkoreader-lfs"] = lfs

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function write(path, data)
    os.execute("mkdir -p " .. q(path:match("^(.*)/[^/]+$")))
    local f = assert(io.open(path, "w"))
    f:write(data)
    f:close()
end
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end
local function exists(path) return lfs.attributes(path) ~= nil end
local function touch(path, t) lfs.touch(path, t, t) end

local Engine = require("concordance/settings_engine")
local Remote = require("concordance/remote")

-- Patterns ------------------------------------------------------------------

local function m(lines, path) return Engine.kind(Engine.compile(lines), path) end
check(m({ "/settings/gestures.lua" }, "settings/gestures.lua") == "sync", "exact path")
check(not m({ "/settings/gestures.lua" }, "settings/x/gestures.lua"), "only that path")
check(m({ "/settings/ZenOS/**" }, "settings/ZenOS/a/b.lua"), "** crosses folders")
check(not m({ "/settings/ZenOS/*" }, "settings/ZenOS/a/b.lua"), "* stays in a folder")
check(m({ "/settings/ZenOS/*" }, "settings/ZenOS/b.lua"), "* in a folder")
check(m({ "/patches/2-*.lua" }, "patches/2-fold-8-fix.lua") and not m({ "/patches/2-*.lua" }, "patches/1-x.lua"),
    "* in a name")
check(m({ "/{a,b}.lua" }, "b.lua") and not m({ "/{a,b}.lua" }, "c.lua"), "{a,b}")
check(m({ "/x?.lua" }, "x1.lua") and not m({ "/x?.lua" }, "x12.lua"), "?")
check(m({ "/a-b.lua" }, "a-b.lua") and not m({ "/a.lua" }, "aXlua"), "magic characters literal")
check(not m({ "# /a.lua", "", "  ; /b.lua" }, "a.lua"), "comments and blank lines")
check(m({ "  /a.lua  " }, "a.lua"), "spaces trimmed")
check(m({ "/[ab].lua" }, "a.lua") and not m({ "/[!ab].lua" }, "a.lua"), "character classes")
check(m({ "< /fonts/**", "/fonts/**" }, "fonts/x.ttf") == "pull" and m({ "</fonts/**" }, "fonts/a.ttf") == "pull",
    "< lines: only pulled, and they win")
do
    local rules = Engine.compile({ "gestures.lua", "//plugins/x.lua", "/settings/", "/../x", "/a//b", "/",
        "/{ok,../bad}.lua", "/settings/ok.lua" })
    check(#rules.bad == 7 and #rules.sync == 1, "bad lines refused: " .. #rules.bad)
    check(rules.bad[1]:find("doesn't start with /", 1, true) and rules.bad[2]:find("single /", 1, true)
        and rules.bad[3]:find("/**", 1, true), "and why: " .. table.concat(rules.bad, "; "))
end

-- Never synced, and how pulled files are put in place.
check(Engine.excluded("settings/concordance/device.lua") and Engine.excluded("settings/concordance/state.sqlite3-wal")
    and Engine.excluded("settings/concordance/settings-sync/state.tsv"), "Concordance's own files never synced")
check(not Engine.excluded("settings/concordance/settings.lua") and not Engine.excluded(Engine.LIST),
    "its shared settings and the list are")
check(Engine.excluded("settings.reader.lua") and not Engine.excluded("defaults.custom.lua")
    and not Engine.excluded("settings/reader.lua") and not Engine.excluded("settings.reader.lua.old"),
    "KOReader's main settings never synced")
check(Engine.excluded("cache/x.lua") and Engine.excluded("plugins/concordance.koplugin/main.lua")
    and Engine.excluded("plugins/knuthplass.koplugin/main.lua") and not Engine.excluded("plugins/assistant.koplugin/main.lua"),
    "the cache and plugins that update themselves never synced")
local function how(path) local staged, restart = Engine.behaviour(path) return staged, restart end
check(how("settings/gestures.lua") == true and how("defaults.custom.lua") == true, "settings and the rest: staged")
check(how("plugins/a.koplugin/main.lua") == false and select(2, how("plugins/a.koplugin/main.lua")) == true
    and select(2, how("data/dict/d.ifo")) == true, "plugins, dictionaries: written now, restart")
check(how("styletweaks/t.css") == false and select(2, how("styletweaks/t.css")) == false, "style tweaks: no restart")
check(how(Engine.LIST) == false and select(2, how(Engine.LIST)) == false, "the list: in place at once")

-- JSON ------------------------------------------------------------------------

-- JSON escapes written as U"00e9" (a backslash, u, and the hex digits).
local function U(hex) return "\\" .. "u" .. hex end
local fonts_path = "/Fonts/" .. string.char(0xC3, 0x89) .. " " .. string.char(0xC3, 0xBC) .. " "
    .. string.char(0xE5, 0xAD, 0x97) .. ".ttf"
local emoji = string.char(0xF0, 0x9F, 0x98, 0x80)
check(Remote.jsonEncode({ path = fonts_path })
    == '{"path":"/Fonts/' .. U"00c9" .. " " .. U"00fc" .. " " .. U"5b57" .. '.ttf"}',
    "JSON escapes non-ASCII: " .. Remote.jsonEncode({ path = fonts_path }))
check(Remote.jsonEncode({ p = emoji }) == '{"p":"' .. U"d83d" .. U"de00" .. '"}', "JSON surrogate pairs")
local decoded = Remote.jsonDecode([[{"a": [1, 2.5, true, null, "x"], "b": {}}]])
check(decoded and decoded.a[1] == 1 and decoded.a[2] == 2.5 and decoded.a[3] == true, "JSON decode")
local d2 = Remote.jsonDecode('{"s": "x\\"' .. U"00e9" .. U"d83d" .. U"de00" .. '\\n"}')
check(d2 and d2.s == 'x"' .. string.char(0xC3, 0xA9) .. emoji .. "\n", "JSON decode escapes")
check(Remote.jsonDecode("{bad") == nil, "JSON decode error")

-- Manifest --------------------------------------------------------------------

local man = { ["settings/gestures.lua"] = { h = "abc", s = 3, t = 100, by = "Kobo" } }
local back = Engine.parseManifest(Engine.formatManifest(man))
check(back["settings/gestures.lua"].h == "abc" and back["settings/gestures.lua"].t == 100
    and back["settings/gestures.lua"].by == "Kobo", "manifest round trip")
local old_man, old_why = Engine.parseManifest("#\tSettings sync manifest\t2\nsettings\tgestures.lua\tabc\t3\t1\tKobo\t\n")
check(old_man == nil and old_why:find("older version"), "an old file list refused: " .. tostring(old_why))

-- Paths from the server: only plain ones inside KOReader's folder.
for _, bad in ipairs({ "", "/etc/passwd", "settings/../../../etc/passwd", "settings/x/../concordance/device.lua",
                       "fonts/../patches/9-evil.lua", "..", "./a", "a//b", "a/", "a\tb", "a\nb" }) do
    check(not Engine.safePath(bad), "path refused: " .. bad)
end
check(Engine.safePath("settings/gestures.lua") and Engine.safePath("fonts/a..b/c.ttf")
    and Engine.safePath("settings/.hidden"), "plain paths accepted")
local evil = Engine.parseManifest(table.concat({
    "#\tConcordance manifest\t3",
    "settings/gestures.lua\tabc\t3\t100\tKobo\t",
    "settings/../../../etc/passwd\tabc\t3\t100\tKobo\t",
    "fonts/../patches/9-evil.lua\tabc\t3\t100\tKobo\t",
    "/abs.lua\tabc\t3\t100\tKobo\t",
}, "\n") .. "\n")
local evil_n = 0
for _ in pairs(evil) do evil_n = evil_n + 1 end
check(evil_n == 1 and evil["settings/gestures.lua"], "file list entries with .. or a leading / dropped")

-- The engine --------------------------------------------------------------------

-- A space and a quote, to check paths are handled.
local base = sh("mktemp -d"):gsub("%s+$", "") .. "/it's here"
os.execute("mkdir -p " .. q(base))
local server_dir = base .. "/server"
os.execute("mkdir -p " .. q(server_dir))

local function md5(path) return Engine.md5Files({ path })[path] end
local server = { type = "folder", address = server_dir, versioner = md5 }
local ROOT = "/KOReader/Files"
local remote_root = server_dir .. ROOT
local files_root = remote_root .. "/files"

local function device(name)
    local kodir = base .. "/" .. name .. "/koreader"
    os.execute("mkdir -p " .. q(kodir))
    return { name = name, kodir = kodir, paths = Engine.paths(kodir) }
end

local function sync(dev, opts)
    local remote = assert(Remote.new(server, ROOT))
    return Engine.sync({ paths = dev.paths, remote = remote, device = dev.name }, opts)
end

local A, B, C = device("A"), device("B"), device("C")

-- A's files and list.
write(A.paths.list, table.concat({
    "# A's list",
    "/settings/gestures.lua",
    "/settings/ZenOS/**",
    "/plugins/shared.koplugin/**",
    "/plugins/assistant.koplugin/configuration.lua",
    "/plugins/concordance.koplugin/**",
    "/patches/2-mine.lua",
    "< /fonts/**",
    "/data/dict/**",
    "/styletweaks/**",
}, "\n") .. "\n")
write(A.kodir .. "/settings/gestures.lua", "return { a = 1 }\n")
write(A.kodir .. "/settings/ZenOS/config.lua", "return {}\n")
write(A.kodir .. "/settings/unlisted.lua", "return {}\n")
write(A.kodir .. "/plugins/shared.koplugin/main.lua", "-- shared\n")
write(A.kodir .. "/plugins/big.koplugin/main.lua", "-- big\n")
write(A.kodir .. "/plugins/assistant.koplugin/configuration.lua", "return { key = 1 }\n")
write(A.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
write(A.kodir .. "/plugins/concordance.koplugin/main.lua", "-- updates itself\n")
write(A.kodir .. "/patches/2-mine.lua", "-- mine\n")
write(A.kodir .. "/patches/2-a-only.lua", "-- unlisted\n")
write(A.kodir .. "/fonts/a.ttf", "font a\n")
write(A.kodir .. "/data/dict/d.ifo", "dict\n")
write(A.kodir .. "/styletweaks/t.css", "p {}\n")

-- First sync from A: everything listed goes up.
local r = sync(A)
check(not r.fatal and #r.errors == 0, "A's first sync\n" .. r.log)
check(read(files_root .. "/" .. Engine.LIST) == read(A.paths.list), "the list uploaded")
check(read(files_root .. "/settings/gestures.lua") == "return { a = 1 }\n", "settings uploaded")
check(exists(files_root .. "/settings/ZenOS/config.lua"), "listed folder uploaded")
check(not exists(files_root .. "/settings/unlisted.lua"), "unlisted setting not uploaded")
check(exists(files_root .. "/plugins/shared.koplugin/main.lua"), "listed plugin uploaded")
check(exists(files_root .. "/plugins/assistant.koplugin/configuration.lua"), "plugin file uploaded")
check(not exists(files_root .. "/plugins/assistant.koplugin/main.lua"), "rest of the plugin not")
check(not exists(files_root .. "/plugins/big.koplugin"), "unlisted plugin not uploaded")
check(not exists(files_root .. "/plugins/concordance.koplugin")
    and r.log:find("plugins/concordance.koplugin/: updates itself, never synced", 1, true),
    "a plugin that updates itself not uploaded, and the log says so")
check(exists(files_root .. "/patches/2-mine.lua") and not exists(files_root .. "/patches/2-a-only.lua"),
    "only listed patches uploaded")
check(not exists(files_root .. "/fonts"), "fonts not uploaded")
check(exists(files_root .. "/data/dict/d.ifo") and exists(files_root .. "/styletweaks/t.css"),
    "dict and style tweaks uploaded")
check(exists(remote_root .. "/manifest.tsv"), "manifest uploaded")
check(r.uploaded == 8, "8 uploads: " .. r.uploaded)
check(not exists(A.kodir .. "/koreader") and exists(A.paths.state .. "/state.tsv") and exists(A.paths.cache),
    "state in settings/concordance/settings-sync, hashes in cache/concordance")

-- Nothing to do the second time.
r = sync(A)
check(not r.fatal and r.uploaded == 0 and r.downloaded == 0, "A's second sync does nothing\n" .. r.log)

-- Fonts only ever come from the server: put some there.
write(files_root .. "/fonts/shared.ttf", "shared\n")
write(files_root .. "/fonts/sub/deep.otf", "deep\n")

-- B: a new device with its own settings, patch, plugin and font, no list.
write(B.kodir .. "/settings/gestures.lua", "return { b = 2 }\n")
write(B.kodir .. "/patches/2-b-only.lua", "-- B's\n")
write(B.kodir .. "/plugins/own.koplugin/main.lua", "-- B's own\n")
write(B.kodir .. "/fonts/b-only.ttf", "b\n")
touch(B.kodir .. "/settings/gestures.lua", os.time() - 3600) -- older than A's
r = sync(B)
check(not r.fatal and #r.errors == 0, "B's first sync\n" .. r.log)
check(read(B.paths.list) == read(A.paths.list), "the list downloaded first")
check(r.pending and r.restart, "settings wait for a restart")
check(read(B.kodir .. "/settings/gestures.lua") == "return { b = 2 }\n", "settings not in place yet")
check(#r.conflicts == 1 and r.conflicts[1].path == "settings/gestures.lua" and r.conflicts[1].kept == "A",
    "both had gestures.lua: A's is newer")
check(exists(B.kodir .. "/plugins/assistant.koplugin/configuration.lua"), "plugin file downloaded")
check(exists(B.kodir .. "/plugins/own.koplugin/main.lua"), "unlisted plugin kept")
check(exists(B.kodir .. "/patches/2-mine.lua") and exists(B.kodir .. "/patches/2-b-only.lua"),
    "listed patch downloaded, own kept")
check(read(B.kodir .. "/fonts/shared.ttf") == "shared\n" and exists(B.kodir .. "/fonts/sub/deep.otf"),
    "fonts downloaded")
check(exists(B.kodir .. "/fonts/b-only.ttf"), "own font kept")
check(not exists(files_root .. "/fonts/b-only.ttf"), "own font not uploaded")
check(read(B.kodir .. "/styletweaks/t.css") == "p {}\n", "style tweaks downloaded")

-- A sync waits for the restart.
r = sync(B)
check(r.fatal and r.fatal:find("restart"), "sync refused while settings wait")

-- The restart.
local ok, apply_log = Engine.applyPending(B.paths)
check(ok, "settings put in place\n" .. tostring(apply_log))
check(read(B.kodir .. "/settings/gestures.lua") == "return { a = 1 }\n", "A's gestures in place")
check(exists(B.kodir .. "/settings/ZenOS/config.lua"), "listed folder in place")
check(not Engine.isPending(B.paths), "nothing waiting")
check(Engine.applyPending(B.paths) == nil, "nothing to put in place twice")
-- A pending list that names files outside KOReader's folder, or ones never
-- synced, changes nothing.
do
    local outside = B.kodir .. "/../outside-" .. tostring(os.time()) .. ".txt"
    write(outside, "keep\n")
    write(B.kodir .. "/settings/concordance/device.lua", "return 1\n")
    Engine.writeFile(B.paths.pending, "delete\t../" .. outside:match("[^/]+$") .. "\n"
        .. "delete\tsettings/x/../concordance/device.lua\n"
        .. "delete\tsettings/concordance/device.lua\n")
    local ok_evil, evil_log = Engine.applyPending(B.paths)
    check(ok_evil and evil_log:find("not a path to change", 1, true), "bad pending entries refused")
    check(exists(outside), "file outside KOReader's folder kept")
    check(exists(B.kodir .. "/settings/concordance/device.lua"), "never-synced file kept")
    check(not Engine.isPending(B.paths), "refused entries not tried again")
    os.remove(outside)
    os.remove(B.kodir .. "/settings/concordance/device.lua")
end
local conflict_copy = sh("find " .. q(B.paths.conflicts) .. " -name gestures.lua"):gsub("%s+$", "")
check(conflict_copy ~= "" and read(conflict_copy) == "return { b = 2 }\n"
    and conflict_copy:find("/settings/gestures.lua$"), "B's own gestures kept in conflicts/: " .. conflict_copy)

r = sync(B)
check(not r.fatal and r.uploaded == 0 and r.downloaded == 0 and #r.conflicts == 0,
    "B's next sync does nothing\n" .. r.log)

-- A catches up on the fonts put on the server.
r = sync(A)
check(r.downloaded == 2 and exists(A.kodir .. "/fonts/sub/deep.otf"), "A gets the server's fonts\n" .. r.log)

-- An edit on B reaches A.
write(B.kodir .. "/styletweaks/t.css", "p { margin: 0 }\n")
check(sync(B).uploaded == 1, "B uploads its tweak")
r = sync(A)
check(r.downloaded == 1 and read(A.kodir .. "/styletweaks/t.css") == "p { margin: 0 }\n", "A gets it\n" .. r.log)
check(not r.restart, "style tweaks need no restart")

-- A changed patch.
write(A.kodir .. "/patches/2-mine.lua", "-- mine, changed\n")
r = sync(A)
check(r.uploaded == 1 and read(files_root .. "/patches/2-mine.lua") == "-- mine, changed\n", "sync sends it")
r = sync(B)
check(r.downloaded == 1 and r.restart and not r.pending and read(B.kodir .. "/patches/2-mine.lua") == "-- mine, changed\n",
    "B gets the patch at once and needs a restart")

-- A changed list reaches B and is used in the same sync.
write(A.paths.list, read(A.paths.list) .. "/patches/2-a-only.lua\n")
r = sync(A)
check(r.uploaded == 2 and exists(files_root .. "/patches/2-a-only.lua"), "A's longer list and its new patch\n" .. r.log)
r = sync(B)
check(r.downloaded == 2 and read(B.paths.list) == read(A.paths.list) and exists(B.kodir .. "/patches/2-a-only.lua"),
    "B gets the list, and what's newly listed\n" .. r.log)

-- C has never had assistant's configuration: it gets it, rather than
-- deleting it everywhere.
write(C.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
r = sync(C)
check(not r.fatal and r.deleted_server == 0, "C deletes nothing on the server\n" .. r.log)
check(exists(C.kodir .. "/plugins/assistant.koplugin/configuration.lua"), "C gets the configuration")
check(exists(files_root .. "/plugins/assistant.koplugin/configuration.lua"), "still on the server")
Engine.applyPending(C.paths)

-- A deletion on A reaches B, staged for settings.
os.remove(A.kodir .. "/settings/ZenOS/config.lua")
os.remove(A.kodir .. "/plugins/assistant.koplugin/configuration.lua")
r = sync(A)
check(r.deleted_server == 2, "A's deletions go to the server\n" .. r.log)
check(not exists(files_root .. "/settings/ZenOS/config.lua"), "deleted on the server")
r = sync(B)
check(r.deleted_here == 2 and r.pending, "B deletes them\n" .. r.log)
check(not exists(B.kodir .. "/plugins/assistant.koplugin/configuration.lua"), "plugin file deleted at once")
check(exists(B.kodir .. "/settings/ZenOS/config.lua"), "setting deleted only at the restart")
Engine.applyPending(B.paths)
check(not exists(B.kodir .. "/settings/ZenOS/config.lua"), "setting deleted at the restart")

-- Changed on one side, deleted on the other: the change wins.
write(C.kodir .. "/settings/ZenOS/config.lua", "return { c = 3 }\n")
r = sync(C)
check(r.uploaded == 1 and read(files_root .. "/settings/ZenOS/config.lua") == "return { c = 3 }\n",
    "an edit beats a deletion\n" .. r.log)

-- Both changed: the newer is kept, the other saved.
write(A.kodir .. "/styletweaks/t.css", "A\n")
touch(A.kodir .. "/styletweaks/t.css", os.time() - 60)
write(B.kodir .. "/styletweaks/t.css", "B\n")
check(sync(B).uploaded == 1, "B uploads first")
r = sync(A)
check(#r.conflicts == 1 and r.conflicts[1].kept == "B", "B's is newer")
check(read(A.kodir .. "/styletweaks/t.css") == "B\n", "A gets B's")
check(r.conflicts[1] and r.conflicts[1].copy and read(r.conflicts[1].copy) == "A\n", "A's saved")

-- Fonts: changes on the server come down; deletions on the server and
-- fonts deleted here stay as they are.
write(files_root .. "/fonts/shared.ttf", "shared, updated\n")
os.remove(files_root .. "/fonts/sub/deep.otf")
os.remove(B.kodir .. "/fonts/b-only.ttf")
Engine.applyPending(B.paths)
r = sync(B)
check(read(B.kodir .. "/fonts/shared.ttf") == "shared, updated\n", "changed font downloaded")
check(exists(B.kodir .. "/fonts/sub/deep.otf"), "font deleted on the server kept")
check(not Engine.parseManifest(read(remote_root .. "/manifest.tsv"))["fonts/sub/deep.otf"],
    "and it leaves the manifest")
os.remove(B.kodir .. "/fonts/shared.ttf")
Engine.applyPending(B.paths)
r = sync(B)
check(not exists(B.kodir .. "/fonts/shared.ttf") and r.downloaded == 0, "font deleted here stays deleted\n" .. r.log)
Engine.applyPending(B.paths)

-- Preview changes nothing.
write(A.kodir .. "/styletweaks/new.css", "new\n")
Engine.applyPending(A.paths)
r = sync(A, { preview = true })
check(r.uploaded >= 1 and r.log:find("new.css", 1, true), "preview lists the change\n" .. r.log)
check(not exists(files_root .. "/styletweaks/new.css"), "preview uploads nothing")

-- No list anywhere: nothing synced.
local D = device("D")
write(D.kodir .. "/patches/2-d.lua", "-- D\n")
local d_server = { type = "folder", address = base .. "/other", versioner = md5 }
r = Engine.sync({ paths = D.paths, remote = Remote.new(d_server, ROOT), device = "D" })
check(not r.fatal and #r.skipped == 1 and r.uploaded == 0, "no list: nothing synced\n" .. r.log)
check(not exists(base .. "/other" .. ROOT .. "/files"), "no files uploaded")

-- Bad lines are reported and skipped; the rest is synced.
write(D.paths.list, "gestures.lua\n//patches/2-d.lua\n/patches/2-d.lua\n")
r = Engine.sync({ paths = D.paths, remote = Remote.new(d_server, ROOT), device = "D" })
check(#r.errors == 2 and r.uploaded == 2 and r.log:find("doesn't start with /", 1, true),
    "bad lines reported, the rest synced\n" .. r.log)

-- Another device saving the file list mid-sync: the sync runs again.
local remote = Remote.new(server, ROOT)
local put = remote.put
local interfered = false
remote.put = function(self, path, local_path, opts)
    if path == "manifest.tsv" and not interfered then
        interfered = true
        -- Someone else's sync finishes first.
        write(files_root .. "/styletweaks/other.css", "other\n")
        local text = read(remote_root .. "/manifest.tsv") .. "styletweaks/other.css\t"
            .. md5(files_root .. "/styletweaks/other.css") .. "\t6\t1\tX\t\n"
        write(remote_root .. "/manifest.tsv", text)
    end
    return put(self, path, local_path, opts)
end
r = Engine.sync({ paths = A.paths, remote = remote, device = "A" })
check(not r.fatal, "sync after a clash\n" .. r.log)
local manifest = Engine.parseManifest(read(remote_root .. "/manifest.tsv"))
check(manifest["styletweaks/other.css"] and manifest["styletweaks/new.css"],
    "both devices' changes in the file list")
check(read(A.kodir .. "/styletweaks/other.css") == "other\n", "the other device's file downloaded")

-- Files already on the server from before: not uploaded again when
-- they're the same, which Dropbox's content hashes tell.
local F = device("F")
local f_dir = base .. "/old-dropbox"
write(F.paths.list, "/patches/*.lua\n/data/dict/**\n")
write(F.kodir .. "/data/dict/big.dict", string.rep("dictionary ", 500000)) -- over 4 MB
write(F.kodir .. "/patches/2-same.lua", "-- same\n")
write(F.kodir .. "/patches/2-differs.lua", "-- here\n")
write(F.kodir .. "/patches/2-new.lua", "-- new\n")
write(f_dir .. ROOT .. "/files/data/dict/big.dict", string.rep("dictionary ", 500000))
write(f_dir .. ROOT .. "/files/patches/2-same.lua", "-- same\n")
write(f_dir .. ROOT .. "/files/patches/2-differs.lua", "-- ther\n") -- same size, different
local f_server = { type = "folder", address = f_dir, versioner = md5, dropbox_like = true }
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" }, { preview = true })
check(r.already_there == 2 and r.log:find("= data/dict/big.dict (already on the server)", 1, true),
    "preview shows files already there\n" .. r.log)
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" })
check(not r.fatal and r.already_there == 2 and r.uploaded == 3,
    "same files not uploaded; differing and new ones are (and the list)\n" .. r.log)
check(read(f_dir .. ROOT .. "/files/patches/2-differs.lua") == "-- here\n", "differing file uploaded")
manifest = Engine.parseManifest(read(f_dir .. ROOT .. "/manifest.tsv"))
check(manifest["data/dict/big.dict"] and manifest["patches/2-same.lua"], "files already there are in the file list")
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" })
check(r.uploaded == 0 and r.downloaded == 0 and r.already_there == 0, "then nothing to do\n" .. r.log)

-- A new device that already has the same files downloads nothing.
local G = device("G")
Engine.applyPending(A.paths) -- A up to date first
os.execute("cp -R " .. q(A.kodir) .. "/. " .. q(G.kodir))
-- Keep the list; forget A's sync history.
os.execute("rm -rf " .. q(G.paths.state) .. " " .. q(G.kodir .. "/cache"))
os.execute("cp -R " .. q(B.kodir .. "/fonts") .. " " .. q(G.kodir)) -- B has the server's fonts
r = sync(G)
check(not r.fatal and r.downloaded == 0 and r.uploaded == 0 and #r.conflicts == 0,
    "first sync of a device with the same files: nothing transferred\n" .. r.log)
r = sync(G)
check(r.downloaded == 0 and r.uploaded == 0, "and nothing the next time")

-- Fonts in the manifest, and moving to another server.
do
    local dbx = { type = "folder", address = base .. "/fm-dropbox", versioner = md5, dropbox_like = true }
    local dav = { type = "folder", address = base .. "/fm-webdav", versioner = md5 } -- IDs: size and time
    local function fsync(dev, srv)
        local res = Engine.sync({ paths = dev.paths, remote = Remote.new(srv, ROOT), device = dev.name })
        Engine.applyPending(dev.paths)
        return res
    end
    local function fonts(dir) return base .. "/" .. dir .. ROOT .. "/files/fonts/" end
    local FA, FB, FC = device("FA"), device("FB"), device("FC")
    for _, dev in ipairs({ FA, FB, FC }) do write(dev.paths.list, "< /fonts/**\n") end
    write(fonts("fm-dropbox") .. "one.ttf", "one\n")
    write(fonts("fm-dropbox") .. "sub/two.otf", "two\n")
    write(FB.kodir .. "/fonts/one.ttf", "one\n") -- installed by hand before
    r = fsync(FA, dbx)
    check(r.downloaded == 2, "fonts downloaded\n" .. r.log)
    local fm = Engine.parseManifest(read(base .. "/fm-dropbox" .. ROOT .. "/manifest.tsv"))
    check(fm["fonts/one.ttf"] and fm["fonts/one.ttf"].h == md5(FA.kodir .. "/fonts/one.ttf") and fm["fonts/one.ttf"].fp
        and fm["fonts/sub/two.otf"], "fonts in the manifest with hash and server ID")
    r = fsync(FB, dbx)
    check(r.downloaded == 1 and read(FB.kodir .. "/fonts/sub/two.otf") == "two\n",
        "a font already here isn't downloaded\n" .. r.log)

    -- The files copied to a server with IDs of its own.
    os.execute("cp -R " .. q(base .. "/fm-dropbox") .. " " .. q(base .. "/fm-webdav"))
    for __, f in ipairs({ "one.ttf", "sub/two.otf" }) do touch(fonts("fm-webdav") .. f, os.time() - 3600) end
    r = fsync(FA, dav)
    check(not r.fatal and r.downloaded == 0 and r.uploaded == 0, "new server: no fonts downloaded\n" .. r.log)
    local moved_fp = Engine.parseManifest(read(base .. "/fm-webdav" .. ROOT .. "/manifest.tsv"))["fonts/one.ttf"]
    r = fsync(FB, dav)
    check(r.downloaded == 0 and r.uploaded == 0, "nor on the next device\n" .. r.log)
    check(moved_fp and moved_fp.fp ~= fm["fonts/one.ttf"].fp, "the manifest has the new server's IDs")

    -- A font replaced on the server, the same size: its ID changes.
    write(fonts("fm-webdav") .. "one.ttf", "ONE\n")
    touch(fonts("fm-webdav") .. "one.ttf", os.time() - 60)
    r = fsync(FA, dav)
    check(r.downloaded == 1 and read(FA.kodir .. "/fonts/one.ttf") == "ONE\n",
        "replaced font downloaded\n" .. r.log)
    r = fsync(FB, dav)
    check(r.downloaded == 1 and read(FB.kodir .. "/fonts/one.ttf") == "ONE\n", "on every device")
    r = fsync(FB, dav)
    check(r.downloaded == 0, "once")

    -- A new device with a different font of the same name and size.
    write(FC.kodir .. "/fonts/sub/two.otf", "TWO\n")
    r = fsync(FC, dav)
    check(read(FC.kodir .. "/fonts/sub/two.otf") == "two\n", "a different font the same size is replaced")

    -- A device that synced fonts before they were in the manifest.
    local FD = device("FD")
    write(FD.paths.list, "< /fonts/**\n")
    local plain = { type = "folder", address = base .. "/fm-plain", versioner = md5 }
    write(fonts("fm-plain") .. "old.ttf", "old\n")
    write(fonts("fm-plain") .. "gone.ttf", "gone\n")
    write(FD.kodir .. "/fonts/old.ttf", "old\n")
    local function id(f) -- the plain test server's ID: size and time
        local attr = lfs.attributes(fonts("fm-plain") .. f)
        return attr.size .. ":" .. attr.modification
    end
    write(FD.paths.state .. "/state.tsv", "pull\tfonts/old.ttf\t" .. id("old.ttf") .. "\n"
        .. "pull\tfonts/gone.ttf\t" .. id("gone.ttf") .. "\n")
    r = fsync(FD, plain)
    check(r.downloaded == 0 and not exists(FD.kodir .. "/fonts/gone.ttf"),
        "earlier state: nothing downloaded, a deleted font stays deleted\n" .. r.log)
    fm = Engine.parseManifest(read(base .. "/fm-plain" .. ROOT .. "/manifest.tsv"))
    check(fm["fonts/old.ttf"] and not fm["fonts/gone.ttf"], "and the font it has goes in the manifest")
end

-- Files anywhere in KOReader's folder: a plugin's configuration (written
-- at once, then a restart) and a file at the top (put in place at the next
-- start, like settings).
do
    local ko_server = { type = "folder", address = base .. "/ko", versioner = md5 }
    local ko_files = base .. "/ko" .. ROOT .. "/files"
    local function ksync(dev)
        return Engine.sync({ paths = dev.paths, remote = Remote.new(ko_server, ROOT), device = dev.name })
    end
    local CONF = "/plugins/assistant.koplugin/configuration.lua"
    local TOP = "/defaults.custom.lua"
    local H, I, J = device("H"), device("I"), device("J")
    write(H.paths.list, "/settings/gestures.lua\n" .. CONF .. "\n" .. TOP .. "\n")
    write(H.kodir .. "/settings/gestures.lua", "return {}\n")
    write(H.kodir .. CONF, "return { key = 1 }\n")
    write(H.kodir .. TOP, "return { top = 1 }\n")

    r = ksync(H)
    check(not r.fatal and #r.errors == 0 and r.uploaded == 4, "all uploaded with the list\n" .. r.log)
    check(read(ko_files .. CONF) == "return { key = 1 }\n" and read(ko_files .. TOP) == "return { top = 1 }\n",
        "kept on the server by their path in KOReader's folder")

    write(I.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
    r = ksync(I)
    check(not r.fatal and r.downloaded == 4 and r.pending and r.restart, "pulled\n" .. r.log)
    check(read(I.kodir .. CONF) == "return { key = 1 }\n", "the plugin's configuration in place at once")
    check(not exists(I.kodir .. TOP), "the top file not before the restart")
    check(Engine.applyPending(I.paths), "put in place")
    check(read(I.kodir .. TOP) == "return { top = 1 }\n", "the top file in place at the restart")

    -- An edit on I reaches H.
    write(I.kodir .. CONF, "return { key = 2 }\n")
    r = ksync(I)
    check(r.uploaded == 1, "I uploads its edit\n" .. r.log)
    r = ksync(H)
    check(r.downloaded == 1 and r.restart and read(H.kodir .. CONF) == "return { key = 2 }\n", "H gets it\n" .. r.log)

    -- A device that already has the same files transfers nothing.
    write(J.paths.list, read(H.paths.list))
    write(J.kodir .. "/settings/gestures.lua", "return {}\n")
    write(J.kodir .. CONF, "return { key = 2 }\n")
    write(J.kodir .. TOP, "return { top = 1 }\n")
    r = ksync(J)
    check(not r.fatal and r.downloaded == 0 and r.uploaded == 0 and not r.pending,
        "same files already here: nothing transferred\n" .. r.log)

    -- A deletion on H reaches I.
    os.remove(H.kodir .. TOP)
    r = ksync(H)
    check(r.deleted_server == 1 and not exists(ko_files .. TOP), "deleted on the server\n" .. r.log)
    r = ksync(I)
    check(r.deleted_here == 1 and r.pending and exists(I.kodir .. TOP), "I deletes it at the restart\n" .. r.log)
    Engine.applyPending(I.paths)
    check(not exists(I.kodir .. TOP), "deleted at the restart")
end

-- Concordance's own device ID and database are never synced, even when the
-- list names them; its shared settings are.
do
    local own_server = { type = "folder", address = base .. "/own", versioner = md5 }
    local own_files = base .. "/own" .. ROOT .. "/files"
    local function osync(dev)
        return Engine.sync({ paths = dev.paths, remote = Remote.new(own_server, ROOT), device = dev.name })
    end
    local M, N = device("M"), device("N")
    for _, dev in ipairs({ M, N }) do
        write(dev.paths.list, "/settings/**\n/cache/**\n")
        write(dev.kodir .. "/settings/concordance/device.lua", 'return { device_id = "' .. dev.name .. '" }\n')
        write(dev.kodir .. "/settings/concordance/state.sqlite3", dev.name .. " db\n")
        write(dev.kodir .. "/settings/concordance/state.sqlite3-wal", dev.name .. " wal\n")
        write(dev.kodir .. "/cache/x.lua", dev.name .. "\n")
    end
    write(M.kodir .. "/settings/concordance/settings.lua", "return { root = \"/KOReader\" }\n")

    r = osync(M)
    check(not r.fatal and #r.errors == 0 and r.uploaded == 2, "only the list and the shared settings uploaded\n" .. r.log)
    check(exists(own_files .. "/settings/concordance/settings.lua"), "shared settings on the server")
    check(not exists(own_files .. "/settings/concordance/device.lua")
        and not exists(own_files .. "/settings/concordance/state.sqlite3")
        and not exists(own_files .. "/settings/concordance/state.sqlite3-wal")
        and not exists(own_files .. "/settings/concordance/settings-sync")
        and not exists(own_files .. "/cache"), "device ID, database, sync state and cache not uploaded")
    check(r.log:find("settings/concordance/device.lua: Concordance's own, never synced", 1, true), "the log says so\n" .. r.log)

    -- One on the server anyway (put there by hand): not pulled, and the
    -- device's own left alone.
    local man_path = base .. "/own" .. ROOT .. "/manifest.tsv"
    local own_man = Engine.parseManifest(read(man_path))
    write(own_files .. "/settings/concordance/device.lua", 'return { device_id = "X" }\n')
    own_man["settings/concordance/device.lua"] = { h = md5(own_files .. "/settings/concordance/device.lua"), s = 27, t = os.time(), by = "X" }
    write(man_path, Engine.formatManifest(own_man))
    r = osync(N)
    check(not r.fatal and #r.errors == 0 and r.downloaded == 1 and r.uploaded == 0, "N pulls only the shared settings\n" .. r.log)
    Engine.applyPending(N.paths)
    check(read(N.kodir .. "/settings/concordance/settings.lua") == "return { root = \"/KOReader\" }\n", "shared settings arrive")
    check(read(N.kodir .. "/settings/concordance/device.lua") == 'return { device_id = "N" }\n'
        and read(N.kodir .. "/settings/concordance/state.sqlite3") == "N db\n", "N's own ID and database left alone")
    r = osync(M)
    check(not r.fatal and r.downloaded == 0 and r.uploaded == 0 and r.deleted_server == 0 and r.deleted_here == 0
        and read(M.kodir .. "/settings/concordance/device.lua") == 'return { device_id = "M" }\n', "M unchanged\n" .. r.log)
end

-- Dropbox and WebDAV ------------------------------------------------------------

local real_request = Remote.request
local requests, responses = {}, {}
Remote.request = function(opts)
    table.insert(requests, opts)
    local resp = table.remove(responses, 1) or { 500 }
    if opts.sink_path and resp.file then write(opts.sink_path, resp.file) end
    return resp[1], resp.headers or {}, resp.body or ""
end
package.loaded["ffi/sha2"] = { bin_to_base64 = function(s) return "b64(" .. s .. ")" end }
local some_file = remote_root .. "/manifest.tsv"

local db = Remote.new({ type = "dropbox", password = "refresh", address = "key:secret" }, "/KOReader/Settings/")
responses = { { 200, body = [[{"access_token": "tok"}]] }, { 200, file = "data",
    headers = { ["dropbox-api-result"] = [[{"rev": "r1"}]] } } }
local tmp = base .. "/dl"
local got, rev = db:get("settings/Été.lua", tmp)
check(got and rev == "r1" and read(tmp) == "data", "Dropbox download")
check(requests[1].headers.Authorization == "Basic b64(key:secret)", "Dropbox token refresh")
check(requests[2].headers["Dropbox-API-Arg"]
    == '{"path":"/KOReader/Settings/settings/' .. U"00c9" .. "t" .. U"00e9" .. '.lua"}',
    "Dropbox path escaped: " .. tostring(requests[2].headers["Dropbox-API-Arg"]))
check(requests[2].headers.Authorization == "Bearer tok", "Dropbox token used")
responses = { { 409, file = [[{"error_summary": "path/not_found/.."}]] } }
local _, err = db:get("manifest.tsv", tmp)
check(err == "not_found" and not exists(tmp), "Dropbox missing file")
responses = { { 409, body = [[{"error_summary": "path/conflict/file/.."}]] } }
_, err = db:put("manifest.tsv", some_file, { version = "r1" })
check(err == "conflict", "Dropbox upload conflict")
check(requests[#requests].headers["Dropbox-API-Arg"]:find([["mode":{".tag":"update","update":"r1"}]], 1, true),
    "Dropbox conditional upload")
responses = {
    { 200, body = [[{"entries": [{".tag": "file", "path_display": "/koreader/settings/fonts/a.ttf", "size": 3, "content_hash": "h1"},
        {".tag": "folder", "path_display": "/KOReader/Settings/fonts/sub"}], "has_more": true, "cursor": "c"}]] },
    { 200, body = [[{"entries": [{".tag": "file", "path_display": "/KOReader/Settings/fonts/sub/b.ttf", "size": 4, "content_hash": "h2"}], "has_more": false}]] },
}
local listed = db:list("fonts")
check(listed and listed["a.ttf"] and listed["a.ttf"].fp == "h1" and listed["sub/b.ttf"].size == 4,
    "Dropbox listing, any case, two pages")
responses = { { 409, body = [[{"error_summary": "path_lookup/not_found/"}]] } }
check(db:delete("x") == true, "Dropbox delete of a missing file")

requests = {}
local dav = Remote.new({ type = "webdav", address = "https://dav.example/remote.php/dav/", username = "u", password = "p" },
    "/KOReader/Settings")
responses = { { 412 } }
_, err = dav:put("manifest.tsv", some_file, { version = '"e1"' })
check(err == "conflict" and requests[1].headers["If-Match"] == '"e1"', "WebDAV conditional upload")
check(requests[1].url == "https://dav.example/remote.php/dav/KOReader/Settings/manifest.tsv",
    "WebDAV URL: " .. tostring(requests[1].url))
check(requests[1].headers.Authorization == "Basic b64(u:p)", "WebDAV login")
responses = { { 201 } }
dav:put("new", some_file, { create = true })
check(requests[2].headers["If-None-Match"] == "*", "WebDAV create only")
requests = {}
responses = { { 405 }, { 405 }, { 201 }, { 201 } }
check(dav:mkdirs("settings/My Dir"), "WebDAV folders")
check(requests[4] and requests[4].url == "https://dav.example/remote.php/dav/KOReader/Settings/settings/My%20Dir",
    "WebDAV folder URL encoded: " .. tostring(requests[4] and requests[4].url))
local before = #requests
dav:mkdirs("settings/My Dir")
check(#requests == before, "WebDAV folders made once each")
requests = {}
responses = {
    { 207, body = [[<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/remote.php/dav/KOReader/Settings/fonts/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>/remote.php/dav/KOReader/Settings/fonts/A%20b.ttf</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>&quot;e5&quot;</d:getetag></d:prop></d:propstat></d:response>
<d:response><d:href>https://dav.example/remote.php/dav/KOReader/Settings/fonts/sub/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
</d:multistatus>]] },
    { 207, body = [[<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/remote.php/dav/KOReader/Settings/fonts/sub/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/remote.php/dav/KOReader/Settings/fonts/sub/c.otf</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>7</D:getcontentlength><D:getlastmodified>Mon</D:getlastmodified></D:prop></D:propstat></D:response>
<D:response><D:href>/remote.php/dav/KOReader/Settings/fonts/sub/b%20&amp;%20c.ttf</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>3</D:getcontentlength><D:getlastmodified>Tue</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:getetag></D:getetag></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
</D:multistatus>]] },
}
listed = dav:list("fonts")
check(listed and listed["A b.ttf"] and listed["A b.ttf"].fp == '"e5"' and listed["A b.ttf"].size == 5,
    "WebDAV listing")
check(listed and listed["sub/c.otf"] and listed["sub/c.otf"].fp == "7:Mon", "WebDAV listing of subfolders")
check(requests[1] and requests[1].headers.Depth == "1", "WebDAV one level at a time")
check(requests[1] and requests[1].url == "https://dav.example/remote.php/dav/KOReader/Settings/fonts/"
    and requests[2] and requests[2].url:sub(-5) == "/sub/", "WebDAV folder URLs end with a slash")
check(listed and listed["sub/b & c.ttf"] and listed["sub/b & c.ttf"].fp == "3:Tue",
    "WebDAV names with XML entities; an empty ETag isn't an ID")
requests = {}
responses = { { 400, body = "<html><body><h1>Bad Request</h1><p>Invalid Depth header</p></body></html>" } }
listed, err = dav:list("fonts")
check(not listed and err:find("/KOReader/Settings/fonts", 1, true) and err:find("400") and err:find("Invalid Depth header"),
    "WebDAV listing error says where and what the server said: " .. tostring(err))
Remote.request = real_request

-- A folder without a manifest (moved, not copied there yet): what the
-- device remembers about the old one doesn't make its files look deleted.
do
    local G = device("MovedDev")
    write(G.paths.list, "/settings/gestures.lua\n")
    write(G.kodir .. "/settings/gestures.lua", "return { g = 1 }\n")
    write(G.paths.state .. "/state.tsv", "sync\tsettings/gestures.lua\t" .. md5(G.kodir .. "/settings/gestures.lua") .. "\n"
        .. "sync\t" .. Engine.LIST .. "\t" .. md5(G.paths.list) .. "\n")
    local r = Engine.sync({ paths = G.paths, remote = assert(Remote.new(server, "/Moved")), device = "G" })
    check(exists(G.kodir .. "/settings/gestures.lua") and exists(G.paths.list)
        and r.deleted_here == 0 and r.uploaded == 2 and exists(server_dir .. "/Moved/files/settings/gestures.lua"),
        "no manifest: nothing deleted here, files uploaded\n" .. r.log)
end

-- Taking over OmniSync's files ---------------------------------------------------
local Migrate = require("concordance/migrate")
do
    check(Migrate.convertList("# /settings/omnisync/x\n/settings/gestures.lua\n/settings/omnisync/settings.lua\n"
        .. "< /plugins/omnisync.koplugin/**\n") == "# /settings/omnisync/x\n/settings/gestures.lua\n"
        .. "/settings/concordance/settings.lua\n< /plugins/concordance.koplugin/**\n", "list lines renamed, comments kept")

    -- Pulled settings waiting, by OmniSync's paths: put in place first.
    local O = device("Old")
    local old = O.kodir .. "/settings/omnisync"
    write(old .. "/sync.txt", "/settings/gestures.lua\n")
    write(old .. "/settings-sync/pending.tsv", "copy\tsettings/gestures.lua\ncopy\tsettings/omnisync/settings.lua\n")
    write(old .. "/settings-sync/staging/settings/gestures.lua",
        'return { ["tap"] = { omnisync_sync = true, settings = { order = { "omnisync_sync" } } } }\n')
    write(old .. "/settings-sync/staging/settings/omnisync/settings.lua", "return { pulled = true }\n")
    local LuaSettings = { open = function(_, path)
        return { data = dofile(path), flush = function(self)
            write(path, "return { [\"tap\"] = { concordance_sync = " .. tostring(self.data.tap.concordance_sync)
                .. ", settings = { order = { \"" .. self.data.tap.settings.order[1] .. "\" } } } }\n")
        end }
    end }
    local done = Migrate.run{ kodir = O.kodir, settings_dir = O.kodir .. "/settings", LuaSettings = LuaSettings }
    check(done.omnisync and not exists(old) and read(O.kodir .. "/settings/concordance/settings.lua") == "return { pulled = true }\n"
        and not Engine.isPending(O.paths), "pulled settings put in place first, then moved")
    local tap = dofile(O.kodir .. "/settings/gestures.lua").tap
    check(tap.concordance_sync and tap.omnisync_sync == nil and tap.settings.order[1] == "concordance_sync",
        "pulled gestures for OmniSync's syncs renamed")
    check(#Migrate.run{ kodir = O.kodir, settings_dir = O.kodir .. "/settings", LuaSettings = LuaSettings } == 0, "only once")
end

-- The plugin ----------------------------------------------------------------------

-- A device that used OmniSync: Concordance takes over its data.
local P = device("P")
local old_state = P.kodir .. "/settings/omnisync"
write(old_state .. "/sync.txt", "/settings/gestures.lua\n/settings/omnisync/settings.lua\n")
write(old_state .. "/settings-sync/state.tsv", "sync\tsettings/gestures.lua\tg1\nsync\tsettings/omnisync/sync.txt\tl1\n"
    .. "sync\tsettings/omnisync/settings.lua\ts1\n")
write(old_state .. "/device.lua", 'return { device_id = "abcdef0123456789", status = { last_success = 7 } }\n')
write(old_state .. "/settings.lua", 'return { allow_wifi = true }\n')
write(old_state .. "/state.sqlite3", "db")
write(old_state .. "/state.sqlite3-wal", "wal")
write(P.kodir .. "/cache/omnisync/settings-cache.tsv", "/some/file\t1\t2\th\n")
write(P.kodir .. "/settings/profiles.lua",
    'return { ["Night"] = { omnisync_statistics = true, settings = { order = { "omnisync_statistics" } } } }\n')
write(P.kodir .. "/settings/gestures.lua", "return { p = 1 }\n")
touch(P.kodir .. "/settings/gestures.lua", os.time() - 7200) -- the server's is newer

local shown, notified, restarts, flushed, broadcast = {}, {}, {}, 0, {}
local saved = { omnisync_updates = { mode = "install", last_check = 5 } }
_G.G_reader_settings = {
    readSetting = function(_, key) return saved[key] end,
    saveSetting = function(_, key, value) saved[key] = value end,
    flush = function() flushed = flushed + 1 end,
}
local function stub(name, value) package.loaded[name] = value end
stub("datastorage", {
    getDataDir = function() return P.kodir end,
    getSettingsDir = function() return P.kodir .. "/settings" end,
})
local cs_servers = {
    { name = "Mine", type = "folder", address = server_dir, versioner = md5 },
    { name = "Box", type = "dropbox", password = "x", address = "k:s" },
}
Remote.TYPES.folder = "Folder"
-- LuaSettings: Cloud storage's servers, and other files read with dofile
-- and written as a Lua table.
local function serialize(v)
    if type(v) == "table" then
        local out = {}
        for k, x in pairs(v) do table.insert(out, string.format("[%s] = %s", serialize(k), serialize(x))) end
        return "{ " .. table.concat(out, ", ") .. " }"
    end
    return type(v) == "string" and string.format("%q", v) or tostring(v)
end
stub("luasettings", { open = function(_, path)
    if path:find("cloudstorage%.lua$") then return { readSetting = function() return cs_servers end } end
    local ok, data = pcall(dofile, path)
    return {
        data = ok and type(data) == "table" and data or {},
        flush = function(self) write(path, "return " .. serialize(self.data) .. "\n") end,
    }
end })
stub("dispatcher", { registerAction = function() end })
stub("ui/event", { new = function(_, name) return { name = name } end })
-- Messages that stay until tapped (no timeout) are what the user is told.
stub("ui/widget/infomessage", {
    new = function(_, o)
        if not o.timeout then table.insert(notified, o.text) end
        return o
    end,
})
stub("ui/widget/confirmbox", { new = function(_, o) return o end })
stub("ui/widget/textviewer", { new = function(_, o) o.viewer = true return o end })
stub("ui/network/manager", { runWhenOnline = function(_, fn) fn() end, isConnected = function() return false end })
-- Notifications time out, so the plugin shouldn't use them.
stub("ui/widget/notification", { notify = function() error("a notification that times out") end })
stub("device", { model = "Test" })
stub("datetime", { secondsToDateTime = function(t) return tostring(t) end })
stub("ui/trapper", {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, task) return true, task() end,
})
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    nextTick = function(_, fn) fn() end,
    scheduleIn = function() end,
    broadcastEvent = function(_, ev) table.insert(broadcast, ev.name) end,
    askForRestart = function(_, text) table.insert(restarts, text) end,
})
local WidgetContainer = {}
function WidgetContainer:extend(o) return setmetatable(o or {}, { __index = self }) end
function WidgetContainer:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
stub("ui/widget/container/widgetcontainer", WidgetContainer)
stub("logger", { info = function() end, warn = function(...) if os.getenv("VERBOSE") then print(...) end end,
                 dbg = function() end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
})

-- A copy of the plugin, next to OmniSync (still on).
local plugin_copy = base .. "/plugins/concordance.koplugin"
os.execute("mkdir -p " .. q(plugin_copy) .. " && cp -r concordance.koplugin/. " .. q(plugin_copy))
write(base .. "/plugins/omnisync.koplugin/main.lua", "-- old\n")

local function loadPlugin()
    local Plugin = dofile(plugin_copy .. "/main.lua")
    return Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
end

-- First start: OmniSync is running too, so it's only turned off.
local plugin = loadPlugin()
local sdir = P.kodir .. "/settings"
check(saved.plugins_disabled and saved.plugins_disabled.omnisync and flushed == 1, "OmniSync turned off, saved")
check(restarts[1] and restarts[1]:find("OmniSync's new name"), "asked to restart: " .. tostring(restarts[1]))
check(exists(old_state .. "/device.lua") and not exists(sdir .. "/concordance/device.lua")
    and saved.concordance_updates == nil, "nothing moved while OmniSync runs")
check(plugin.addToMainMenu == nil and plugin.trigger == nil, "Concordance does nothing until the restart")
restarts, flushed = {}, 0

-- Second start: OmniSync is off, its data moves.
plugin = loadPlugin()
local Settings = require("concordance/plugin")
local p_list = read(P.paths.list) or ""
check(not exists(old_state) and p_list == "/settings/gestures.lua\n/settings/concordance/settings.lua\n",
    "migrated: the list, its line for OmniSync's settings renamed\n" .. p_list)
check(read(P.paths.state .. "/state.tsv") == "sync\tsettings/gestures.lua\tg1\n",
    "settings sync's state kept, but not for OmniSync's own files (sent again by their new paths)")
check(Settings.deviceState().device_id == "abcdef0123456789" and Settings.deviceState().status.last_success == 7,
    "migrated: device ID and status")
check(Settings.settings().allow_wifi == true, "migrated: settings")
check(read(sdir .. "/concordance/state.sqlite3") == "db" and read(sdir .. "/concordance/state.sqlite3-wal") == "wal",
    "migrated: database, with its side files")
check(read(P.paths.cache) == "/some/file\t1\t2\th\n" and not exists(P.kodir .. "/cache/omnisync"), "migrated: cache")
local night = dofile(sdir .. "/profiles.lua").Night
check(night.concordance_statistics and night.omnisync_statistics == nil and night.settings.order[1] == "concordance_statistics",
    "migrated: gestures for OmniSync's syncs")
check(read(sdir .. "/gestures.lua") == "return { p = 1 }\n", "gestures without OmniSync's left alone")
check(Settings.autoStats() and Settings.autoAnnotations(), "automatic syncs on by default")
check(saved.concordance_updates and saved.concordance_updates.mode == "install" and not saved.concordance_updates.last_check,
    "migrated: update mode")
check(#restarts == 0 and notified[1] and notified[1]:find("took over OmniSync's", 1, true),
    "migration reported: " .. tostring(notified[1]))
-- Only once.
write(old_state .. "/sync.txt", "/other.lua\n")
loadPlugin()
check(read(P.paths.list) == p_list and exists(old_state), "a second start migrates nothing again")
os.execute("rm -rf " .. q(old_state))
write(P.paths.list, "/settings/gestures.lua\n")
notified = {}
plugin = loadPlugin()
check(#notified == 0, "nothing more to report")

local menu_items = {}
plugin:addToMainMenu(menu_items)
-- item("Folder on server") at the top; item("Statistics", "Sync now") in a submenu.
local function item(...)
    local path = { ... }
    local list = menu_items.concordance.sub_item_table_func()
    for i, text in ipairs(path) do
        local found
        for _, it in ipairs(list) do
            local t = it.text or (it.text_func and it.text_func())
            if t and t:find(text, 1, true) then found = it break end
        end
        if not found or i == #path then return found end
        list = found.sub_item_table or found.sub_item_table_func()
    end
end
check(item("Settings", "Sync now") and item("Statistics", "Sync now") and item("Highlights and books", "Sync now")
    and item("Settings", "Preview changes"), "a sync item each for settings, statistics and highlights")
check(item("Statistics", "Sync automatically").checked_func() and item("Highlights and books", "Sync automatically").checked_func(),
    "automatic syncs shown on")
item("Statistics", "Sync automatically").callback()
check(Settings.settings().auto_stats == false and not Settings.autoStats() and Settings.autoAnnotations(),
    "statistics' automatic sync turned off alone")
item("Statistics", "Sync automatically").callback()
check(Settings.autoStats(), "and on again")
check(item("Folder on server: /KOReader"), "folder shown")
check(Settings.settingsRoot() == "/KOReader/Files", "settings in <folder>/Files")
check(Settings.remoteRoot() == "KOReader/Reading", "statistics in <folder>/Reading")
check(Settings.server().name == "Mine", "first server by default")
Settings.settings().server = { name = "Box", type = "dropbox" }
check(Settings.server().name == "Box", "chosen server")
local none, why = Settings.statsServer()
check(none == nil and why:find("WebDAV"), "statistics need WebDAV: " .. tostring(why))
Settings.settings().server = { name = "Mine", type = "folder" }

-- Preview, then its Sync now button.
plugin:syncSettings(true)
local viewer = shown[#shown]
check(viewer and viewer.viewer and viewer.title:find("would make") and #broadcast == 0,
    "preview shows what would change")
local row = viewer and viewer.buttons_table and viewer.buttons_table[1] or {}
check(#row == 2 and row[2].text == "Sync now", "preview offers Sync now")
local closed
package.loaded["ui/uimanager"].close = function(_, w) closed = w end
if row[2] then row[2].callback() end
check(closed == viewer, "Sync now closes the preview")

check(broadcast[1] == "FlushSettings" and flushed == 1, "sync saves settings first")
check(#restarts == 1, "sync asks to restart for pulled settings")
check(Engine.isPending(P.paths), "settings waiting")
check(read(P.kodir .. "/settings/gestures.lua") == "return { p = 1 }\n", "not in place before restart")

plugin:onConcordanceSettings()
check(#restarts == 2 and #broadcast == 1, "sync refused while settings wait")
check(item("Discard pulled settings"), "menu offers to discard")

-- The next start puts them in place.
plugin = loadPlugin()
check(read(P.kodir .. "/settings/gestures.lua") ~= "return { p = 1 }\n", "put in place at start")
check(notified[#notified] == "Pulled settings put in place.", "start reports it")

plugin:onConcordanceSettings()
check(notified[#notified] == "Settings already up to date." or (notified[#notified] or ""):find("^Uploaded"),
    "sync after the restart: " .. tostring(notified[#notified]))
local before = #notified
plugin:onConcordanceSettings()
check(#notified == before + 1 and notified[#notified] == "Settings already up to date.",
    "nothing to sync: says so: " .. tostring(notified[#notified]))

Settings.settings().server = { name = "Box", type = "dropbox" }
Remote.request = function() return 401, {}, "{}" end
plugin:onConcordanceSettings()
check(notified[#notified] and notified[#notified]:find("Dropbox login failed"),
    "login failure reported: " .. tostring(notified[#notified]))
Remote.request = real_request

cs_servers = {}
plugin:onConcordanceSettings()
check(notified[#notified]:find("Cloud storage"), "no server: points to Cloud storage")

os.execute("rm -rf " .. q(base:match("^(.*)/[^/]+$")))
print(string.format("concordance settings: %d checks, %d failures", count, failures))
if failures > 0 then os.exit(1) end
