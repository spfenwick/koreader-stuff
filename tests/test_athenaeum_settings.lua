-- Tests athenaeum.koplugin/athenaeum/settings.lua: the plugin's settings in
-- two files, settings.lua (this device's) and shared.lua (can be synced),
-- and moving shared keys out of settings.lua. KOReader's modules are
-- stubbed; files are real, in a temporary folder. Needs LuaFileSystem.

local lfs = require("lfs")

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, msg .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local root = os.tmpname()
os.remove(root)
lfs.mkdir(root)

-- Stubs ----------------------------------------------------------------------------

local function serialize(v, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _i, k in ipairs(keys) do
            out[#out + 1] = "[" .. string.format("%q", k) .. "]="
            serialize(v[k], out)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    else
        out[#out + 1] = tostring(v)
    end
end

local LuaSettings = {}
LuaSettings.__index = LuaSettings
function LuaSettings:open(path)
    local ok, data = pcall(dofile, path)
    return setmetatable({ file = path, data = ok and type(data) == "table" and data or {} }, LuaSettings)
end
function LuaSettings:readSetting(k) return self.data[k] end
function LuaSettings:saveSetting(k, v) self.data[k] = v return self end
function LuaSettings:delSetting(k) self.data[k] = nil return self end
function LuaSettings:flush()
    local out = { "return " }
    serialize(self.data, out)
    local f = assert(io.open(self.file, "wb"))
    f:write(table.concat(out))
    f:close()
end

package.loaded["luasettings"] = LuaSettings
package.loaded["datastorage"] = { getSettingsDir = function() return root end }
package.loaded["logger"] = { info = function() end, warn = function() end }
package.loaded["util"] = { makePath = function(p) lfs.mkdir(p) end }
G_reader_settings = LuaSettings:open(root .. "/settings.reader.lua")

package.path = "athenaeum.koplugin/?.lua;" .. package.path
local Settings = require("athenaeum/settings")

local function file(path)
    local ok, data = pcall(dofile, path)
    return ok and data or nil
end

local function clean()
    os.remove(Settings.path())
    os.remove(Settings.sharedPath())
    os.remove(root .. "/settings.reader.lua")
    G_reader_settings = LuaSettings:open(root .. "/settings.reader.lua")
    Settings.reset()
end

-- Saving: each key to its own file --------------------------------------------------

clean()
Settings.save("folder", "/mnt/onboard/Books")
Settings.save("badge_noncloud", true)
Settings.save("server", { url = "https://books.example", username = "me" })
Settings.save("quick_sync", "3h")
Settings.save(Settings.UPDATES_KEY, { mode = "install", last_check = 5 })
local device, shared = file(Settings.path()), file(Settings.sharedPath())
eq(device.folder, "/mnt/onboard/Books", "folder in this device's file")
eq(device.updates.last_check, 5, "updater state in this device's file")
eq(device.badge_noncloud, nil, "badge not in this device's file")
eq(shared.badge_noncloud, true, "badge in the shared file")
eq(shared.server.url, "https://books.example", "catalog in the shared file")
eq(shared.quick_sync, "3h", "sync schedule in the shared file")
eq(shared.folder, nil, "folder not in the shared file")
eq(shared.updates, nil, "updater state not in the shared file")

local all = Settings.all()
eq(all.folder, "/mnt/onboard/Books", "all(): folder")
eq(all.badge_noncloud, true, "all(): badge")
eq(all.server.username, "me", "all(): catalog")
Settings.save("badge_noncloud", false)
eq(Settings.all().badge_noncloud, false, "all() sees a later save")

-- The updater writes through store() (this device's file).
local s = Settings.store()
s:saveSetting(Settings.UPDATES_KEY, { mode = "off" })
s:flush()
eq(file(Settings.path()).updates.mode, "off", "updater writes this device's file")

-- Read back after a restart.
Settings.reset()
eq(Settings.all().quick_sync, "3h", "shared key read back")
eq(Settings.all().folder, "/mnt/onboard/Books", "device key read back")

-- Moving from 0.8.1 (everything in settings.lua) ------------------------------------

clean()
do
    local old = LuaSettings:open(Settings.path())
    old.data = { folder = "/sdcard/Books", badge_local = true, show = false, search = false,
        server = { url = "https://books.example" }, updates = { last_check = 9 } }
    old:flush()
end
all = Settings.all()
eq(all.badge_local, true, "0.8.1: badge kept")
eq(all.show, false, "0.8.1: false value kept")
eq(all.folder, "/sdcard/Books", "0.8.1: folder kept")
device, shared = file(Settings.path()), file(Settings.sharedPath())
eq(device.badge_local, nil, "0.8.1: badge removed from this device's file")
eq(device.show, nil, "0.8.1: false value removed from this device's file")
eq(device.server, nil, "0.8.1: catalog removed from this device's file")
eq(device.folder, "/sdcard/Books", "0.8.1: folder stays in this device's file")
eq(device.updates.last_check, 9, "0.8.1: updater state stays")
eq(shared.badge_local, true, "0.8.1: badge in the shared file")
eq(shared.show, false, "0.8.1: false value in the shared file")
eq(shared.search, false, "0.8.1: search in the shared file")
eq(shared.server.url, "https://books.example", "0.8.1: catalog in the shared file")

-- A shared file pulled from another device wins over this device's old keys.
clean()
do
    local old = LuaSettings:open(Settings.path())
    old.data = { folder = "/sdcard/Books", badge_noncloud = false, badge_cloud = false }
    old:flush()
    local pulled = LuaSettings:open(Settings.sharedPath())
    pulled.data = { badge_noncloud = true }
    pulled:flush()
end
all = Settings.all()
eq(all.badge_noncloud, true, "pulled shared value wins")
eq(all.badge_cloud, false, "key the shared file lacks is moved")
eq(file(Settings.path()).badge_noncloud, nil, "old copy removed from this device's file")
eq(file(Settings.sharedPath()).badge_cloud, false, "moved key written to the shared file")

-- A device key in the shared file (written by hand) is ignored.
clean()
do
    local sh = LuaSettings:open(Settings.sharedPath())
    sh.data = { folder = "/elsewhere", search = false }
    sh:flush()
end
Settings.save("folder", "/here")
eq(Settings.all().folder, "/here", "folder only read from this device's file")
eq(Settings.all().search, false, "shared key read")

-- Moving from Cloud library (settings.reader.lua) ----------------------------------

clean()
G_reader_settings:saveSetting("cloudlibrary", { folder = "/books", badge_local = true })
G_reader_settings:saveSetting("cloudlibrary_updates", { mode = "notify" })
all = Settings.all()
eq(all.folder, "/books", "Cloud library: folder moved")
eq(all.badge_local, true, "Cloud library: badge moved")
eq(file(Settings.path()).badge_local, nil, "Cloud library: badge not left in this device's file")
eq(file(Settings.sharedPath()).badge_local, true, "Cloud library: badge in the shared file")
eq(file(Settings.path()).updates.mode, "notify", "Cloud library: updater state moved")
eq(G_reader_settings:readSetting("cloudlibrary"), nil, "Cloud library: removed from settings.reader.lua")

clean()
lfs.rmdir(root .. "/athenaeum")
lfs.rmdir(root)

print(string.format("athenaeum settings: %d checks, %d failures", count, failures))
os.exit(failures == 0 and 0 or 1)
