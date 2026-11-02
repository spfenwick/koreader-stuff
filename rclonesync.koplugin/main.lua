--[[--
Settings sync: keep KOReader's settings, chosen plugins and patches,
dictionaries, fonts and style tweaks the same on several devices, through a
Dropbox or WebDAV server set up in Cloud storage.

rclonesync_engine.lua does the syncing (in a separate process, so KOReader
stays responsive and the sync can be cancelled); rclonesync_remote.lua
talks to the server.
--]]--

local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
-- Names of their own: plugins share package.loaded.
local Engine = require("rclonesync_engine")
local Remote = require("rclonesync_remote")

local SETTINGS_KEY = "rclonesync"
local DEFAULT_ROOT = "/KOReader/Settings"

--- KOReader's data folder, made absolute ("." on e-readers).
local function dataDir()
    local dir = require("datastorage"):getDataDir()
    if dir:sub(1, 1) ~= "/" then
        local lfs = require("libs/libkoreader-lfs")
        dir = lfs.currentdir() .. (dir == "." and "" or "/" .. dir:gsub("^%./", ""))
    end
    return (dir:gsub("/+$", ""))
end

local function paths() return Engine.paths(dataDir()) end

-- Runs as KOReader loads its plugins, before any of them is started, so
-- settings pulled last time are in place before their plugins read them.
local startup
do
    local ok, err = pcall(function()
        local p = paths()
        local applied = Engine.applyPending(p)
        if applied ~= nil then
            startup = { ok = applied, log = p.apply_log }
            logger.info("Settings sync: put pulled settings in place:", applied)
        end
    end)
    if not ok then
        logger.warn("Settings sync: putting pulled settings in place:", err)
        startup = { ok = false }
    end
end

-- Files earlier versions had and this one doesn't: a new version copied
-- over an old one leaves them behind, and when the plugin syncs itself
-- (plugins.txt) they would spread to other devices. Deleted here, the
-- next sync deletes them everywhere.
local OBSOLETE = { "rclonesync_sync.lua" }
do
    local plugin_path = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
    if plugin_path then
        for __, name in ipairs(OBSOLETE) do
            if os.remove(plugin_path .. "/" .. name) then
                logger.info("Settings sync: removed", name, "from an earlier version")
            end
        end
    end
end

local RcloneSync = WidgetContainer:extend{
    name = "rclonesync",
    is_doc_only = false,
}

function RcloneSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("rclonesync_sync", {
        category = "none", event = "RcloneSync", general = true,
        title = _("Settings sync: sync"),
    })
end

function RcloneSync:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- The lists used to be in the rclone folder the scripts used.
    local kodir = dataDir()
    local parent = kodir:match("^(.*)/[^/]+$") or ""
    pcall(Engine.migrateLists, paths(), { parent .. "/rclone", kodir .. "/rclone" })
    if startup and not startup.shown then
        startup.shown = true
        UIManager:nextTick(function()
            if startup.ok then
                Notification:notify(_("Pulled settings put in place."))
            else
                UIManager:show(InfoMessage:new{
                    text = T(_("Settings sync couldn't put all the pulled settings in place. It will try again at the next start.\n\nLog: %1"),
                        startup.log or "?"),
                })
            end
        end)
    end
end

function RcloneSync:onRcloneSync() self:sync() return true end

function RcloneSync:save()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

--- The Dropbox and WebDAV servers set up in Cloud storage.
function RcloneSync:servers()
    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    local ok, cs = pcall(LuaSettings.open, LuaSettings, DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    local servers = {}
    for __, server in ipairs(ok and cs:readSetting("cs_servers") or {}) do
        if Remote.TYPES[server.type] then table.insert(servers, server) end
    end
    return servers
end

function RcloneSync:server()
    local servers = self:servers()
    local chosen = self.settings.server
    if chosen then
        for __, server in ipairs(servers) do
            if server.name == chosen.name and server.type == chosen.type then return server end
        end
    end
    return servers[1]
end

local function serverLabel(server)
    return server and T("%1 (%2)", server.name, Remote.TYPES[server.type]) or _("none")
end

function RcloneSync:showLog(title, text)
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = title,
        text = text ~= "" and text or _("(nothing)"),
        monospace_font = true,
        justified = false,
    })
end

function RcloneSync:sync(preview)
    local p = paths()
    if not preview and Engine.isPending(p) then
        UIManager:askForRestart(_("Pulled settings are waiting to be put in place at the next start. Syncing now would send the old ones back.\n\nRestart KOReader first?"))
        return
    end
    local server = self:server()
    if not server then
        UIManager:show(InfoMessage:new{
            text = _("Settings sync uses a Dropbox or WebDAV server from Cloud storage. Add one there first (file browser → Cloud storage)."),
        })
        return
    end
    local root = self.settings.root or DEFAULT_ROOT
    local device = require("device").model or "?"
    NetworkMgr:runWhenOnline(function()
        if not preview then
            -- So what's synced is what's in use.
            UIManager:broadcastEvent(Event:new("FlushSettings"))
            G_reader_settings:flush()
        end
        Trapper:wrap(function()
            local text = preview and _("Checking what would change…") or _("Syncing…")
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local ok, res = pcall(function()
                    local remote, err = Remote.new(server, root)
                    if not remote then return { fatal = err, log = err } end
                    return Engine.sync({ paths = p, remote = remote, device = device },
                        { preview = preview })
                end)
                if ok then return res end
                return { fatal = tostring(res), log = tostring(res) }
            end, text)
            if not completed then
                Notification:notify(_("Sync cancelled. Run it again to finish."))
                return
            end
            self:report(result or { fatal = _("The sync stopped unexpectedly.") }, preview)
        end)
    end)
end

function RcloneSync:report(result, preview)
    local log = result.log or ""
    if result.fatal then
        UIManager:show(InfoMessage:new{ text = result.fatal })
        return
    end
    local changes = (result.uploaded or 0) + (result.downloaded or 0)
        + (result.deleted_here or 0) + (result.deleted_server or 0)
    if preview then
        self:showLog(T(_("Sync would make %1 changes"), changes), log)
        return
    end
    local summary = T(_("Uploaded %1, downloaded %2, deleted %3."), result.uploaded or 0,
        result.downloaded or 0, (result.deleted_here or 0) + (result.deleted_server or 0))
    if (result.already_there or 0) > 0 then
        summary = summary .. " " .. T(_("%1 files were already on the server."), result.already_there)
    end
    if #(result.errors or {}) > 0 then
        self:showLog(T(_("Sync finished with %1 errors"), #result.errors), log)
        return
    end
    if #(result.conflicts or {}) > 0 then
        local lines = {}
        for __, c in ipairs(result.conflicts) do
            table.insert(lines, T(_("%1: kept the version from %2"), c.path, c.kept))
        end
        UIManager:show(InfoMessage:new{
            text = T(_("Some files had changed on more than one device:\n\n%1\n\nThe other versions are in %2."),
                table.concat(lines, "\n"), paths().conflicts),
        })
    end
    if result.restart then
        UIManager:askForRestart(summary .. "\n\n"
            .. (result.pending and _("Pulled settings are put in place when KOReader restarts.")
                or _("The new files are used after KOReader restarts.")))
    elseif changes == 0 and (result.already_there or 0) == 0 then
        Notification:notify(_("Already up to date."))
    else
        Notification:notify(summary)
    end
end

function RcloneSync:serverMenu()
    local items = {}
    for __, server in ipairs(self:servers()) do
        table.insert(items, {
            text = serverLabel(server),
            radio = true,
            checked_func = function()
                local current = self:server()
                return current and current.name == server.name and current.type == server.type
            end,
            callback = function()
                self.settings.server = { name = server.name, type = server.type }
                self:save()
            end,
        })
    end
    if #items == 0 then
        table.insert(items, { text = _("No Dropbox or WebDAV servers in Cloud storage"), enabled = false })
    end
    return items
end

function RcloneSync:editRoot(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Folder on the server"),
        input = self.settings.root or DEFAULT_ROOT,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local root = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    self.settings.root = root ~= "" and root or nil
                    self:save()
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function RcloneSync:menu()
    local function action(text, preview)
        return {
            text = text,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:sync(preview)
            end,
        }
    end
    local p = paths()
    local items = {
        action(_("Sync"), false),
        action(_("Preview sync (what would change)"), true),
    }
    items[#items].separator = true
    if Engine.isPending(p) then
        table.insert(items, {
            text = _("Discard pulled settings waiting for a restart"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Engine.discardPending(p)
                Notification:notify(_("Discarded. The next sync sends this device's settings."))
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            separator = true,
        })
    end
    table.insert(items, {
        text_func = function() return T(_("Server: %1"), serverLabel(self:server())) end,
        sub_item_table_func = function() return self:serverMenu() end,
    })
    table.insert(items, {
        text_func = function()
            return T(_("Folder on server: %1"), self.settings.root or DEFAULT_ROOT)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance) self:editRoot(touchmenu_instance) end,
        separator = true,
    })
    table.insert(items, {
        text = _("Show last log"),
        callback = function()
            local file = io.open(p.log, "r")
            local log = file and file:read("*a")
            if file then file:close() end
            local apply = io.open(p.apply_log, "r")
            if apply then
                log = (log or "") .. "\n" .. apply:read("*a")
                apply:close()
            end
            self:showLog(_("Settings sync log"), log or _("No sync has run yet."))
        end,
    })
    return items
end

function RcloneSync:addToMainMenu(menu_items)
    menu_items.rclonesync = {
        text = _("Settings sync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menu() end,
    }
end

return RcloneSync
