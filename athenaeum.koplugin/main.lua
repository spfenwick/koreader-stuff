--[[
Athenaeum: every book in your OPDS library (Calibre-Web / Calibre-Web
Automated) is listed in your library folder, downloaded or not. Runs under
ZenOS only (it needs ZenOS's book sources).

Tools → Athenaeum: choose the catalog (one of the OPDS plugin's
catalogs), the folder, and sync.

Formerly Cloud library (cloudlibrary.koplugin): athenaeum/migrate.lua moves
an installation from the old name, first, before anything else loads.

For tests: settings/athenaeum/fixture.lua, if present, replaces the
catalog with a fixed list of books and no syncing.
]]

local Migrate = require("athenaeum/migrate")
-- Another copy is in athenaeum.koplugin: KOReader skips this one.
if not Migrate.atLoad() then return { disabled = true } end

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Virtual = require("athenaeum/virtual")
local Library = require("athenaeum/library")
local Updater = require("athenaeum/updater")

local Athenaeum = WidgetContainer:extend{
    name = "athenaeum",
    is_doc_only = false,
}

local function fixturePath()
    local path = DataStorage:getSettingsDir() .. "/athenaeum/fixture.lua"
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "file" and path or nil
end

local function loadFixture()
    local path = fixturePath()
    if not path then return end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    logger.warn("Athenaeum: can't load test catalog", path, data)
end

function Athenaeum:onDispatcherRegisterActions()
    Dispatcher:registerAction("athenaeum_sync", {
        category = "none", event = "AthenaeumSync", title = _("Athenaeum: quick sync"),
        general = true,
    })
end

function Athenaeum:init()
    Migrate.fixLoadedPlugin(Athenaeum)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local first = not Virtual.installed
    if first then
        Virtual.details = Library.bookDetails
        if not Virtual.install() then
            local Guard = require("athenaeum/guard")
            if Guard.zenos_missing then
                local UIManager = require("ui/uimanager")
                UIManager:nextTick(function()
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = _("Athenaeum needs ZenOS (a version with book sources). It's turned off."),
                    })
                end)
            end
        end
        local Badge = require("athenaeum/badge")
        Badge.install()
        if Badge.installed then
            local Guard = require("athenaeum/guard")
            Virtual.decorate = function(item)
                if Guard.ok("badge") then Guard.call("badge", Badge.decorate, item) end
            end
        end
        require("athenaeum/search").install(Virtual)
        Library.installDeleteHooks()
        if Virtual.installed and require("athenaeum/guard").ok("library") then Library.installHistory() end
    end
    -- Not in tests: an update prompt would get in their way.
    if not fixturePath() then Updater.scheduleCheck(self) end
    if self.ui.document then return end -- reader: menu only
    local fixture = loadFixture()
    if fixture then
        Virtual.details = nil
        Library.fixture = true -- the catalog never changes
        Virtual.setCatalog(fixture.library_dir or G_reader_settings:readSetting("home_dir"),
            fixture.books)
        return
    end
    require("athenaeum/guard").call("jobs", Library.onFileManagerReady)
end

function Athenaeum:addToMainMenu(menu_items)
    menu_items.athenaeum = Library.menuItems(self)
end

function Athenaeum:onNetworkConnected()
    if not self.ui.document then
        require("athenaeum/guard").call("jobs", Library.onNetworkConnected)
    end
end

function Athenaeum:onAthenaeumSync()
    require("athenaeum/guard").call("jobs", Library.sync, "quick")
    return true
end

return Athenaeum
