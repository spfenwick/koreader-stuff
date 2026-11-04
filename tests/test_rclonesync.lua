-- Exercises rclonesync.koplugin: list patterns, JSON, the sync engine with
-- simulated devices and a folder standing in for the server, the Dropbox
-- and WebDAV clients against a fake HTTP layer, and the plugin's flow
-- against stubbed KOReader modules.
--
-- Needs LuaFileSystem and md5sum; skipped without them.

package.path = "rclonesync.koplugin/?.lua;" .. package.path

local function sh(cmd)
    local pipe = io.popen(cmd)
    local out = pipe:read("*a")
    pipe:close()
    return out
end

local have_lfs, lfs = pcall(require, "lfs")
if not have_lfs or sh("command -v md5sum") == "" then
    print("rclonesync: skipped (needs LuaFileSystem and md5sum)")
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

local Engine = require("rclonesync_engine")
local Remote = require("rclonesync_remote")

-- Patterns ------------------------------------------------------------------

local function m(lines, path) return Engine.matches(Engine.compile(lines), path) end
check(m({ "/gestures.lua" }, "gestures.lua"), "anchored file")
check(not m({ "/gestures.lua" }, "x/gestures.lua"), "anchored only at the top")
check(m({ "gestures.lua" }, "x/gestures.lua"), "unanchored at any depth")
check(m({ "/ZenOS/**" }, "ZenOS/a/b.lua"), "** crosses folders")
check(not m({ "/ZenOS/*" }, "ZenOS/a/b.lua"), "* stays in a folder")
check(m({ "/ZenOS/*" }, "ZenOS/b.lua"), "* in a folder")
check(m({ "/2-*.lua" }, "2-fold-8-fix.lua") and not m({ "/2-*.lua" }, "1-x.lua"), "* in a name")
check(m({ "/{a,b}.lua" }, "b.lua") and not m({ "/{a,b}.lua" }, "c.lua"), "{a,b}")
check(m({ "/x?.lua" }, "x1.lua") and not m({ "/x?.lua" }, "x12.lua"), "?")
check(m({ "/a-b.lua" }, "a-b.lua") and not m({ "/a.lua" }, "aXlua"), "magic characters literal")
check(not m({ "# /a.lua", "", "  ; /b.lua" }, "a.lua"), "comments and blank lines")
check(m({ "  /a.lua  " }, "a.lua"), "spaces trimmed")
check(m({ "/[ab].lua" }, "a.lua") and not m({ "/[!ab].lua" }, "a.lua"), "character classes")

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

local man = { settings = { ["gestures.lua"] = { h = "abc", s = 3, t = 100, by = "Kobo" } } }
local back = Engine.parseManifest(Engine.formatManifest(man))
check(back.settings["gestures.lua"].h == "abc" and back.settings["gestures.lua"].t == 100
    and back.settings["gestures.lua"].by == "Kobo", "manifest round trip")

-- The engine --------------------------------------------------------------------

-- A space and a quote, to check paths are handled.
local base = sh("mktemp -d"):gsub("%s+$", "") .. "/it's here"
os.execute("mkdir -p " .. q(base))
local server_dir = base .. "/server"
os.execute("mkdir -p " .. q(server_dir))

local function md5(path) return Engine.md5Files({ path })[path] end
local server = { type = "folder", address = server_dir, versioner = md5 }
local ROOT = "/KOReader/Settings"
local remote_root = server_dir .. ROOT

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

-- A's files and lists.
write(A.paths.state .. "/settings.txt", "/gestures.lua\n/ZenOS/**\n")
write(A.paths.state .. "/plugins.txt", "/shared.koplugin/**\n/assistant.koplugin/configuration.lua\n")
write(A.paths.state .. "/patches.txt", "/2-mine.lua\n")
write(A.kodir .. "/settings/gestures.lua", "return { a = 1 }\n")
write(A.kodir .. "/settings/ZenOS/config.lua", "return {}\n")
write(A.kodir .. "/settings/unlisted.lua", "return {}\n")
write(A.kodir .. "/plugins/shared.koplugin/main.lua", "-- shared\n")
write(A.kodir .. "/plugins/big.koplugin/main.lua", "-- big\n")
write(A.kodir .. "/plugins/assistant.koplugin/configuration.lua", "return { key = 1 }\n")
write(A.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
write(A.kodir .. "/patches/2-mine.lua", "-- mine\n")
write(A.kodir .. "/patches/2-a-only.lua", "-- unlisted\n")
write(A.kodir .. "/fonts/a.ttf", "font a\n")
write(A.kodir .. "/data/dict/d.ifo", "dict\n")
write(A.kodir .. "/styletweaks/t.css", "p {}\n")

-- First sync from A: everything listed goes up.
local r = sync(A)
check(not r.fatal and #r.errors == 0, "A's first sync\n" .. r.log)
check(read(remote_root .. "/settings/gestures.lua") == "return { a = 1 }\n", "settings uploaded")
check(exists(remote_root .. "/settings/ZenOS/config.lua"), "listed folder uploaded")
check(not exists(remote_root .. "/settings/unlisted.lua"), "unlisted setting not uploaded")
check(exists(remote_root .. "/plugins/shared.koplugin/main.lua"), "listed plugin uploaded")
check(exists(remote_root .. "/plugins/assistant.koplugin/configuration.lua"), "plugin file uploaded")
check(not exists(remote_root .. "/plugins/assistant.koplugin/main.lua"), "rest of the plugin not")
check(not exists(remote_root .. "/plugins/big.koplugin"), "unlisted plugin not uploaded")
check(exists(remote_root .. "/patches/2-mine.lua") and not exists(remote_root .. "/patches/2-a-only.lua"),
    "only listed patches uploaded")
check(not exists(remote_root .. "/fonts"), "fonts not uploaded")
check(exists(remote_root .. "/dict/d.ifo") and exists(remote_root .. "/styletweaks/t.css"),
    "dict and style tweaks uploaded")
check(exists(remote_root .. "/lists/plugins.txt"), "lists uploaded")
check(exists(remote_root .. "/manifest.tsv"), "manifest uploaded")
check(r.uploaded == 10, "10 uploads: " .. r.uploaded)

-- Nothing to do the second time.
r = sync(A)
check(not r.fatal and r.uploaded == 0 and r.downloaded == 0, "A's second sync does nothing\n" .. r.log)

-- Fonts only ever come from the server: put some there.
write(remote_root .. "/fonts/shared.ttf", "shared\n")
write(remote_root .. "/fonts/sub/deep.otf", "deep\n")

-- B: a new device with its own settings, patch, plugin and font, no lists.
write(B.kodir .. "/settings/gestures.lua", "return { b = 2 }\n")
write(B.kodir .. "/patches/2-b-only.lua", "-- B's\n")
write(B.kodir .. "/plugins/own.koplugin/main.lua", "-- B's own\n")
write(B.kodir .. "/fonts/b-only.ttf", "b\n")
touch(B.kodir .. "/settings/gestures.lua", os.time() - 3600) -- older than A's
r = sync(B)
check(not r.fatal and #r.errors == 0, "B's first sync\n" .. r.log)
check(exists(B.paths.state .. "/plugins.txt"), "lists downloaded first")
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
check(not exists(remote_root .. "/fonts/b-only.ttf"), "own font not uploaded")
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
local conflict_copy = sh("find " .. q(B.paths.conflicts) .. " -name gestures.lua"):gsub("%s+$", "")
check(conflict_copy ~= "" and read(conflict_copy) == "return { b = 2 }\n", "B's own gestures kept in conflicts/")

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
check(r.uploaded == 1 and read(remote_root .. "/patches/2-mine.lua") == "-- mine, changed\n", "sync sends it")
r = sync(B)
check(r.downloaded == 1 and r.restart and read(B.kodir .. "/patches/2-mine.lua") == "-- mine, changed\n",
    "B gets the patch and needs a restart")

-- C has never had assistant's configuration: it gets it, rather than
-- deleting it everywhere.
write(C.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
r = sync(C)
check(not r.fatal and r.deleted_server == 0, "C deletes nothing on the server\n" .. r.log)
check(exists(C.kodir .. "/plugins/assistant.koplugin/configuration.lua"), "C gets the configuration")
check(exists(remote_root .. "/plugins/assistant.koplugin/configuration.lua"), "still on the server")
Engine.applyPending(C.paths)

-- A deletion on A reaches B, staged for settings.
os.remove(A.kodir .. "/settings/ZenOS/config.lua")
os.remove(A.kodir .. "/plugins/assistant.koplugin/configuration.lua")
r = sync(A)
check(r.deleted_server == 2, "A's deletions go to the server\n" .. r.log)
check(not exists(remote_root .. "/settings/ZenOS/config.lua"), "deleted on the server")
r = sync(B)
check(r.deleted_here == 2 and r.pending, "B deletes them\n" .. r.log)
check(not exists(B.kodir .. "/plugins/assistant.koplugin/configuration.lua"), "plugin file deleted at once")
check(exists(B.kodir .. "/settings/ZenOS/config.lua"), "setting deleted only at the restart")
Engine.applyPending(B.paths)
check(not exists(B.kodir .. "/settings/ZenOS/config.lua"), "setting deleted at the restart")

-- Changed on one side, deleted on the other: the change wins.
write(C.kodir .. "/settings/ZenOS/config.lua", "return { c = 3 }\n")
r = sync(C)
check(r.uploaded == 1 and read(remote_root .. "/settings/ZenOS/config.lua") == "return { c = 3 }\n",
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
write(remote_root .. "/fonts/shared.ttf", "shared, updated\n")
os.remove(remote_root .. "/fonts/sub/deep.otf")
os.remove(B.kodir .. "/fonts/b-only.ttf")
Engine.applyPending(B.paths)
r = sync(B)
check(read(B.kodir .. "/fonts/shared.ttf") == "shared, updated\n", "changed font downloaded")
check(exists(B.kodir .. "/fonts/sub/deep.otf"), "font deleted on the server kept")
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
check(not exists(remote_root .. "/styletweaks/new.css"), "preview uploads nothing")

-- A missing list skips its folder.
local D = device("D")
write(D.kodir .. "/patches/2-d.lua", "-- D\n")
local d_server = { type = "folder", address = base .. "/other", versioner = md5 }
r = Engine.sync({ paths = D.paths, remote = Remote.new(d_server, ROOT), device = "D" })
check(not r.fatal and #r.skipped == 3, "no lists: settings, plugins and patches skipped\n" .. r.log)
check(not exists(base .. "/other" .. ROOT .. "/patches"), "no patches uploaded")

-- Another device saving the file list mid-sync: the sync runs again.
local remote = Remote.new(server, ROOT)
local put = remote.put
local interfered = false
remote.put = function(self, path, local_path, opts)
    if path == "manifest.tsv" and not interfered then
        interfered = true
        -- Someone else's sync finishes first.
        write(remote_root .. "/styletweaks/other.css", "other\n")
        local text = read(remote_root .. "/manifest.tsv") .. "styletweaks\tother.css\t"
            .. md5(remote_root .. "/styletweaks/other.css") .. "\t6\t1\tX\n"
        write(remote_root .. "/manifest.tsv", text)
    end
    return put(self, path, local_path, opts)
end
r = Engine.sync({ paths = A.paths, remote = remote, device = "A" })
check(not r.fatal, "sync after a clash\n" .. r.log)
local manifest = Engine.parseManifest(read(remote_root .. "/manifest.tsv"))
check(manifest.styletweaks["other.css"] and manifest.styletweaks["new.css"],
    "both devices' changes in the file list")
check(read(A.kodir .. "/styletweaks/other.css") == "other\n", "the other device's file downloaded")

-- Files already on the server from before (the scripts): not uploaded
-- again when they're the same, which Dropbox's content hashes tell.
local F = device("F")
local f_dir = base .. "/old-dropbox"
write(F.paths.state .. "/patches.txt", "/*.lua\n")
write(F.kodir .. "/data/dict/big.dict", string.rep("dictionary ", 500000)) -- over 4 MB
write(F.kodir .. "/patches/2-same.lua", "-- same\n")
write(F.kodir .. "/patches/2-differs.lua", "-- here\n")
write(F.kodir .. "/patches/2-new.lua", "-- new\n")
write(f_dir .. ROOT .. "/dict/big.dict", string.rep("dictionary ", 500000))
write(f_dir .. ROOT .. "/patches/2-same.lua", "-- same\n")
write(f_dir .. ROOT .. "/patches/2-differs.lua", "-- ther\n") -- same size, different
local f_server = { type = "folder", address = f_dir, versioner = md5, dropbox_like = true }
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" }, { preview = true })
check(r.already_there == 2 and r.log:find("= big.dict (already on the server)", 1, true),
    "preview shows files already there\n" .. r.log)
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" })
check(not r.fatal and r.already_there == 2 and r.uploaded == 3,
    "same files not uploaded; differing and new ones are (and the list)\n" .. r.log)
check(read(f_dir .. ROOT .. "/patches/2-differs.lua") == "-- here\n", "differing file uploaded")
manifest = Engine.parseManifest(read(f_dir .. ROOT .. "/manifest.tsv"))
check(manifest.dict and manifest.dict["big.dict"] and manifest.patches["2-same.lua"],
    "files already there are in the file list")
r = Engine.sync({ paths = F.paths, remote = Remote.new(f_server, ROOT), device = "F" })
check(r.uploaded == 0 and r.downloaded == 0 and r.already_there == 0, "then nothing to do\n" .. r.log)

-- A new device that already has the same files downloads nothing.
local G = device("G")
Engine.applyPending(A.paths) -- A up to date first
os.execute("cp -R " .. q(A.kodir) .. "/. " .. q(G.kodir))
-- Keep the lists; forget A's sync history.
for _, name in ipairs({ "state.tsv", "cache.tsv", "pending.tsv", "staging", "conflicts" }) do
    os.execute("rm -rf " .. q(G.paths.state .. "/" .. name))
end
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
    local FA, FB, FC = device("FA"), device("FB"), device("FC")
    write(base .. "/fm-dropbox" .. ROOT .. "/fonts/one.ttf", "one\n")
    write(base .. "/fm-dropbox" .. ROOT .. "/fonts/sub/two.otf", "two\n")
    write(FB.kodir .. "/fonts/one.ttf", "one\n") -- installed by hand before
    r = fsync(FA, dbx)
    check(r.downloaded == 2, "fonts downloaded\n" .. r.log)
    local fm = Engine.parseManifest(read(base .. "/fm-dropbox" .. ROOT .. "/manifest.tsv")).fonts or {}
    check(fm["one.ttf"] and fm["one.ttf"].h == md5(FA.kodir .. "/fonts/one.ttf") and fm["one.ttf"].fp
        and fm["sub/two.otf"], "fonts in the manifest with hash and server ID")
    r = fsync(FB, dbx)
    check(r.downloaded == 1 and read(FB.kodir .. "/fonts/sub/two.otf") == "two\n",
        "a font already here isn't downloaded\n" .. r.log)

    -- The files copied to a server with IDs of its own.
    os.execute("cp -R " .. q(base .. "/fm-dropbox") .. " " .. q(base .. "/fm-webdav"))
    for __, f in ipairs({ "/fonts/one.ttf", "/fonts/sub/two.otf" }) do
        touch(base .. "/fm-webdav" .. ROOT .. f, os.time() - 3600)
    end
    r = fsync(FA, dav)
    check(not r.fatal and r.downloaded == 0 and r.uploaded == 0, "new server: no fonts downloaded\n" .. r.log)
    local moved_fp = (Engine.parseManifest(read(base .. "/fm-webdav" .. ROOT .. "/manifest.tsv")).fonts or {})["one.ttf"]
    r = fsync(FB, dav)
    check(r.downloaded == 0 and r.uploaded == 0, "nor on the next device\n" .. r.log)
    check(moved_fp and moved_fp.fp ~= fm["one.ttf"].fp, "the manifest has the new server's IDs")

    -- A font replaced on the server, the same size: its ID changes.
    write(base .. "/fm-webdav" .. ROOT .. "/fonts/one.ttf", "ONE\n")
    touch(base .. "/fm-webdav" .. ROOT .. "/fonts/one.ttf", os.time() - 60)
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
    local plain = { type = "folder", address = base .. "/fm-plain", versioner = md5 }
    write(base .. "/fm-plain" .. ROOT .. "/fonts/old.ttf", "old\n")
    write(base .. "/fm-plain" .. ROOT .. "/fonts/gone.ttf", "gone\n")
    write(FD.kodir .. "/fonts/old.ttf", "old\n")
    local function id(f) -- the plain test server's ID: size and time
        local attr = lfs.attributes(base .. "/fm-plain" .. ROOT .. "/fonts/" .. f)
        return attr.size .. ":" .. attr.modification
    end
    write(FD.paths.state .. "/state.tsv", "fonts\told.ttf\t" .. id("old.ttf") .. "\n"
        .. "fonts\tgone.ttf\t" .. id("gone.ttf") .. "\n")
    r = fsync(FD, plain)
    check(r.downloaded == 0 and not exists(FD.kodir .. "/fonts/gone.ttf"),
        "earlier state: nothing downloaded, a deleted font stays deleted\n" .. r.log)
    fm = Engine.parseManifest(read(base .. "/fm-plain" .. ROOT .. "/manifest.tsv")).fonts or {}
    check(fm["old.ttf"] and not fm["gone.ttf"], "and the font it has goes in the manifest")
end

-- settings.txt lines starting with // name files elsewhere in KOReader's
-- folder, such as a plugin's configuration.
do
    local rules = Engine.compile({ "//plugins/a.koplugin/configuration.lua", "//plugins/*.lua",
        "//../x.lua", "//settings/x.lua", "//rclonesync/state.tsv", "//a//b", "//" })
    check(rules.koreader["plugins/a.koplugin/configuration.lua"], "// path compiled")
    check(#rules.bad == 6, "patterns, .., settings/, rclonesync/ and empty paths refused: " .. #rules.bad)
    check(Engine.matches(rules, "@koreader/plugins/a.koplugin/configuration.lua"), "// path matches")
    check(not Engine.matches(Engine.compile({ "/**" }), "@koreader/plugins/x.lua"),
        "other patterns don't match // paths")

    local ko_server = { type = "folder", address = base .. "/ko", versioner = md5 }
    local ko_root = base .. "/ko" .. ROOT
    local function ksync(dev)
        return Engine.sync({ paths = dev.paths, remote = Remote.new(ko_server, ROOT), device = dev.name })
    end
    local CONF = "/plugins/assistant.koplugin/configuration.lua"
    local list = "/gestures.lua\n//plugins/assistant.koplugin/configuration.lua\n"
    local H, I, J = device("H"), device("I"), device("J")
    write(H.paths.state .. "/settings.txt", list)
    write(H.kodir .. "/settings/gestures.lua", "return {}\n")
    write(H.kodir .. CONF, "return { key = 1 }\n")
    write(H.kodir .. "/settings/@koreader/plugins/assistant.koplugin/configuration.lua", "stray\n")

    r = ksync(H)
    check(not r.fatal and #r.errors == 0 and r.uploaded == 3, "// file uploaded with the rest\n" .. r.log)
    check(read(ko_root .. "/settings/@koreader" .. CONF) == "return { key = 1 }\n",
        "kept under settings/@koreader/ on the server")
    check(not exists(ko_root .. "/plugins"), "not in plugins/")

    -- I has the plugin but not its configuration: it comes at the next start.
    write(I.kodir .. "/plugins/assistant.koplugin/main.lua", "-- assistant\n")
    r = ksync(I)
    check(not r.fatal and r.downloaded == 3 and r.pending, "// file pulled, staged\n" .. r.log)
    check(not exists(I.kodir .. CONF), "not in place before the restart")
    check(Engine.applyPending(I.paths), "put in place")
    check(read(I.kodir .. CONF) == "return { key = 1 }\n", "in the plugin's folder at the restart")
    check(not exists(I.kodir .. "/settings/@koreader"), "not in settings/")

    -- An edit on I reaches H.
    write(I.kodir .. CONF, "return { key = 2 }\n")
    r = ksync(I)
    check(r.uploaded == 1, "I uploads its edit\n" .. r.log)
    r = ksync(H)
    check(r.downloaded == 1 and r.pending, "H gets it\n" .. r.log)
    Engine.applyPending(H.paths)
    check(read(H.kodir .. CONF) == "return { key = 2 }\n", "H's configuration updated")

    -- A device that already has the same file transfers nothing.
    os.execute("mkdir -p " .. q(J.paths.state))
    os.execute("cp " .. q(H.paths.state .. "/settings.txt") .. " " .. q(J.paths.state))
    write(J.kodir .. "/settings/gestures.lua", "return {}\n")
    write(J.kodir .. CONF, "return { key = 2 }\n")
    r = ksync(J)
    check(not r.fatal and r.downloaded == 0 and r.uploaded == 0 and not r.pending,
        "same file already here: nothing transferred\n" .. r.log)

    -- A deletion on H reaches I at its next start.
    os.remove(H.kodir .. CONF)
    r = ksync(H)
    check(r.deleted_server == 1 and not exists(ko_root .. "/settings/@koreader" .. CONF),
        "deleted on the server\n" .. r.log)
    r = ksync(I)
    check(r.deleted_here == 1 and r.pending and exists(I.kodir .. CONF), "I deletes it at the restart\n" .. r.log)
    Engine.applyPending(I.paths)
    check(not exists(I.kodir .. CONF), "deleted at the restart")

    -- Bad // lines, and // in another list, are reported and ignored.
    write(H.paths.state .. "/settings.txt", list .. "//plugins/*.lua\n")
    write(H.paths.state .. "/plugins.txt", "//plugins/x.lua\n")
    r = ksync(H)
    check(#r.errors == 2 and r.log:find("//plugins/*.lua: only exact paths", 1, true)
        and r.log:find("only settings.txt", 1, true), "bad // lines reported\n" .. r.log)
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

-- The plugin ----------------------------------------------------------------------

local P = device("P")
write(P.paths.state .. "/settings.txt", "/gestures.lua\n")
write(P.kodir .. "/settings/gestures.lua", "return { p = 1 }\n")
touch(P.kodir .. "/settings/gestures.lua", os.time() - 7200) -- the server's is newer

local shown, notified, restarts, flushed, broadcast = {}, {}, {}, 0, {}
local saved = {}
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
stub("luasettings", { open = function() return { readSetting = function() return cs_servers end } end })
stub("dispatcher", { registerAction = function() end })
stub("ui/event", { new = function(_, name) return { name = name } end })
-- Messages that stay until tapped (no timeout) are what the user is told.
stub("ui/widget/infomessage", {
    new = function(_, o)
        if not o.timeout then table.insert(notified, o.text) end
        return o
    end,
})
stub("ui/widget/textviewer", { new = function(_, o) o.viewer = true return o end })
stub("ui/network/manager", { runWhenOnline = function(_, fn) fn() end })
-- Notifications time out, so the plugin shouldn't use them.
stub("ui/widget/notification", { notify = function() error("a notification that times out") end })
stub("device", { model = "Test" })
stub("ui/trapper", {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, task) return true, task() end,
})
stub("ui/uimanager", {
    show = function(_, w) table.insert(shown, w) end,
    nextTick = function(_, fn) fn() end,
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
stub("logger", { info = function() end, warn = function() end, dbg = function() end })
stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("ffi/util", {
    template = function(fmt, ...)
        local args = { ... }
        return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end,
})

-- A copy of the plugin, with a file left from an earlier version.
local plugin_copy = base .. "/plugins/rclonesync.koplugin"
os.execute("mkdir -p " .. q(plugin_copy) .. " && cp rclonesync.koplugin/*.lua " .. q(plugin_copy))
write(plugin_copy .. "/rclonesync_sync.lua", "-- old\n")

local function loadPlugin()
    local Plugin = dofile(plugin_copy .. "/main.lua")
    return Plugin:new{ ui = { menu = { registerToMainMenu = function() end } } }
end

local plugin = loadPlugin()
check(not exists(plugin_copy .. "/rclonesync_sync.lua") and exists(plugin_copy .. "/main.lua"),
    "file from an earlier version removed at start")
local menu_items = {}
plugin:addToMainMenu(menu_items)
check(#menu_items.rclonesync.sub_item_table_func() >= 5, "menu")
check(plugin:server().name == "Mine", "first server by default")
saved.rclonesync = { server = { name = "Box", type = "dropbox" } }
plugin.settings = saved.rclonesync
check(plugin:server().name == "Box", "chosen server")
saved.rclonesync.server = { name = "Mine", type = "folder" }

-- Preview, then its Sync now button.
plugin:sync(true)
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

plugin:onRcloneSync()
check(#restarts == 2 and #broadcast == 1, "sync refused while settings wait")

local discard = false
for _, item in ipairs(plugin:menu()) do
    if item.text and item.text:find("^Discard") then discard = true end
end
check(discard, "menu offers to discard")

-- The next start puts them in place.
plugin = loadPlugin()
plugin.settings = saved.rclonesync
check(read(P.kodir .. "/settings/gestures.lua") ~= "return { p = 1 }\n", "put in place at start")
check(notified[#notified] == "Pulled settings put in place.", "start reports it")

plugin:onRcloneSync()
check(notified[#notified] == "Already up to date." or (notified[#notified] or ""):find("^Uploaded"),
    "sync after the restart: " .. tostring(notified[#notified]))
local before = #notified
plugin:onRcloneSync()
check(#notified == before + 1 and notified[#notified] == "Already up to date.",
    "nothing to sync: says so: " .. tostring(notified[#notified]))

saved.rclonesync.server = { name = "Box", type = "dropbox" }
Remote.request = function() return 401, {}, "{}" end
plugin:onRcloneSync()
check(shown[#shown] and shown[#shown].text and shown[#shown].text:find("Dropbox login failed"),
    "login failure reported: " .. tostring(shown[#shown] and shown[#shown].text))
Remote.request = real_request

cs_servers = {}
plugin:onRcloneSync()
check(shown[#shown].text:find("Cloud storage"), "no server: points to Cloud storage")

os.execute("rm -rf " .. q(base:match("^(.*)/[^/]+$")))
print(string.format("rclonesync: %d checks, %d failures", count, failures))
if failures > 0 then os.exit(1) end
