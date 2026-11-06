--[[
Cloud library: every book in your OPDS library (Calibre-Web / Calibre-Web
Automated) is listed in your library folder, downloaded or not.

Tools → Cloud library: choose the catalog (one of the OPDS plugin's
catalogs), the folder, and sync.

For tests: settings/cloudlibrary/fixture.lua, if present, replaces the
catalog with a fixed list of books and no syncing.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Virtual = require("cloudlibrary/virtual")
local Library = require("cloudlibrary/library")

local CloudLibrary = WidgetContainer:extend{
    name = "cloudlibrary",
    is_doc_only = false,
}

local function loadFixture()
    local path = DataStorage:getSettingsDir() .. "/cloudlibrary/fixture.lua"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return end
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    logger.warn("CloudLibrary: can't load test catalog", path, data)
end

function CloudLibrary:onDispatcherRegisterActions()
    Dispatcher:registerAction("cloudlibrary_sync", {
        category = "none", event = "CloudLibrarySync", title = _("Cloud library: sync"),
        general = true,
    })
end

function CloudLibrary:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local first = not Virtual.installed
    if first then
        Virtual.details = Library.bookDetails
        Virtual.install()
        local Badge = require("cloudlibrary/badge")
        Badge.install()
        if Badge.installed then
            local Guard = require("cloudlibrary/guard")
            Virtual.decorate = function(item)
                if Guard.ok("badge") then Guard.call("badge", Badge.decorate, item) end
            end
        end
        require("cloudlibrary/search").install(Virtual)
        Library.installDeleteHooks()
    end
    if self.ui.document then return end -- reader: menu only
    local fixture = loadFixture()
    if fixture then
        Virtual.details = nil
        Library.fixture = true -- the catalog never changes
        Virtual.setCatalog(fixture.library_dir or G_reader_settings:readSetting("home_dir"),
            fixture.books)
        return
    end
    require("cloudlibrary/guard").call("jobs", Library.onFileManagerReady)
end

function CloudLibrary:addToMainMenu(menu_items)
    menu_items.cloudlibrary = Library.menuItems()
end

function CloudLibrary:onNetworkConnected()
    if not self.ui.document then
        require("cloudlibrary/guard").call("jobs", Library.onNetworkConnected)
    end
end

function CloudLibrary:onCloudLibrarySync()
    require("cloudlibrary/guard").call("jobs", Library.sync, "quick")
    return true
end

return CloudLibrary
