--[[--
Statistics sync: syncs reading statistics, and optionally highlights and
bookmarks, between devices as a log of immutable per-device files on a
WebDAV server.

statsync/engine.lua runs the sync, statsync/store.lua the databases,
statsync/webdav.lua and statsync/netjob.lua the network (in a subprocess),
statsync/plugin.lua connects them to KOReader. Annotations: statsync/annstore.lua
(data), statsync/annsync.lua (in the reader). See README.md and ANNOTATIONS.md.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local _ = require("gettext")
local T = require("ffi/util").template

local Plugin = require("statsync/plugin")
local Updater = require("statsync/updatecore").new{
    name = "statsync",
    title = _("Statistics sync"),
    settings_key = "statsync_updates",
    log_prefix = "StatSync:",
}

local STARTUP_DELAY = 20 -- s: let KOReader settle (and Wi-Fi come up) first
local CLOSE_DELAY = 2    -- s: after the statistics plugin has written the closed book

local StatSync = WidgetContainer:extend{
    name = "statsync",
    is_doc_only = false,
}

local started -- once per KOReader process

function StatSync:init()
    self.ui.menu:registerToMainMenu(self)
    Dispatcher:registerAction("statsync_sync", {
        category = "none", event = "StatSyncNow", title = _("Statistics sync: sync now"), general = true,
    })
    Plugin.onDone = function(status, run) self.showResult(status, run) end
    if not started then
        started = true
        UIManager:scheduleIn(STARTUP_DELAY, function() self.trigger("start") end)
    end
    Updater.scheduleCheck(self)
end

function StatSync.trigger(reason, interactive, scanned)
    if not scanned and Plugin.annotationsNeedScan() then
        -- Before the first sync with highlights and bookmarks: read the
        -- reading history, so books not opened since get sent too.
        if Plugin.annSync():scan(function() StatSync.trigger(reason, interactive, true) end) then return end
    end
    local engine = Plugin.engine()
    if interactive and not engine.running and not NetworkMgr:isConnected() then
        -- Asked for by the user: do what KOReader does for other network actions.
        NetworkMgr:runWhenConnected(function() engine:request(reason, { interactive = true }) end)
        return
    end
    if not interactive and not engine.running and not NetworkMgr:isConnected()
            and Plugin.settings().enabled and Plugin.settings().allow_wifi then
        NetworkMgr:runWhenConnected(function() engine:request(reason) end)
        return
    end
    engine:request(reason, { interactive = interactive })
end

function StatSync.showResult(status, run)
    if not run.interactive then return end
    local text
    if run.skipped then
        text = T(_("Statistics not synced: %1"), status.last_error or "")
    elseif run.error then
        text = T(_("Statistics sync failed: %1"), run.error)
    else
        text = T(_("Statistics synced.\nSent %1 entries, received %2 entries from %3 files."),
            run.uploaded_events or 0, run.imported_events or 0, run.segments_imported or 0)
        if run.ann then
            text = text .. "\n" .. T(_("Highlights and bookmarks: sent %1 changes, received %2."),
                run.ann_uploaded_records or 0, run.ann_imported_records or 0)
        end
        if run.upload_error then
            text = text .. "\n" .. T(_("Upload failed: %1"), run.upload_error)
        end
        if run.ann_upload_error then
            text = text .. "\n" .. T(_("Upload of highlights and bookmarks failed: %1"), run.ann_upload_error)
        end
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = run.error and nil or 4 })
end

-- Triggers --------------------------------------------------------------------

function StatSync:onReaderReady()
    if not Plugin.annotationsEnabled() then return end
    local ui = self.ui
    local function ready()
        if Plugin.annSync():onReaderReady(ui) > 0 then
            UIManager:scheduleIn(1, function() Plugin.annSync():askHeld() end)
        end
    end
    -- After KOReader's own post-load work on the annotations (sorting, page numbers).
    if ui.registerPostReaderReadyCallback and ui.postReaderReadyCallback then
        ui:registerPostReaderReadyCallback(ready)
    else
        UIManager:nextTick(ready)
    end
end

function StatSync:onCloseDocument()
    -- KOReader has saved the book's annotations: record its changes now,
    -- while they're still in memory.
    local held = Plugin.annSync():onClose(self.ui)
    if held > 0 then
        UIManager:scheduleIn(1, function() Plugin.annSync():askHeld() end)
    end
    UIManager:scheduleIn(CLOSE_DELAY, function() self.trigger("close") end)
end

function StatSync:onResume()
    self.trigger("resume")
end

function StatSync:onNetworkConnected()
    self.trigger("network")
end

function StatSync:onStatSyncNow()
    self.trigger("manual", true)
end

-- Menu --------------------------------------------------------------------------

local function when(ts)
    return ts and datetime.secondsToDateTime(ts) or _("never")
end

function StatSync:serverText()
    local server, why = Plugin.server()
    if server then return server.name or server.address or "?" end
    local chosen = Plugin.settings().server
    return chosen and T(_("%1 (not in Cloud storage)"), chosen.name or "?") or _("not set")
end

function StatSync:showStatus()
    local s = Plugin.settings()
    local d = Plugin.deviceState()
    local st = d.status or {}
    local ok, counts = pcall(function() return Plugin.makeStore():counts() end)
    counts = ok and counts or {}
    local lines = {
        T(_("Server: %1"), self:serverText()),
        T(_("Folder: %1"), Plugin.serverLocation() or _("not set")),
        T(_("Automatic sync: %1"), s.enabled and _("on") or _("off")),
        T(_("Last success: %1"), when(st.last_success)),
        T(_("Last attempt: %1"), when(st.last_attempt)),
        T(_("Last error: %1"), st.last_error or _("none")),
        T(_("Devices seen: %1"), st.devices or "?"),
        T(_("Entries imported last time: %1"), st.imported_events or 0),
        T(_("Entries sent last time: %1"), st.uploaded_events or 0),
        T(_("Entries published or received in total: %1"), counts.exported or "?"),
        T(_("Files imported: %1, unreadable: %2"), counts.seen or "?", counts.bad or "?"),
        T(_("This device's ID: %1"), d.device_id or _("not yet created")),
    }
    if Plugin.annotationsEnabled() then
        local aok, a = pcall(function() return Plugin.annStore():counts() end)
        a = aok and a or {}
        table.insert(lines, "")
        table.insert(lines, T(_("Highlights and bookmarks: %1 in %2 books"), a.annotations or "?", a.books or "?"))
        table.insert(lines, T(_("Changes waiting to be sent: %1"), a.outbox or "?"))
        table.insert(lines, T(_("Books to update when opened: %1"), a.pending or "?"))
        table.insert(lines, T(_("Books with removals waiting for you: %1"), a.held or "?"))
        table.insert(lines, T(_("Changes sent last time: %1, received: %2"), st.ann_uploaded or 0, st.ann_imported or 0))
        table.insert(lines, T(_("Files imported: %1, unreadable: %2"), counts.ann_seen or "?", counts.ann_bad or "?"))
        table.insert(lines, T(_("Reading history read: %1"), when(d.ann_scanned)))
    else
        table.insert(lines, T(_("Highlights and bookmarks: %1"), _("not synced")))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--- The WebDAV servers from Cloud storage, to choose one (as Settings sync does).
function StatSync:serverMenu()
    local items = {}
    for _i, server in ipairs(Plugin.servers()) do
        table.insert(items, {
            text = server.name or server.address or "?",
            radio = true,
            checked_func = function()
                local current = Plugin.server()
                return current ~= nil and current.name == server.name
            end,
            callback = function()
                Plugin.settings().server = { name = server.name, type = server.type }
                Plugin.saveSettings()
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("No WebDAV servers in Cloud storage"),
            enabled = false,
            help_text = _("Add a WebDAV server in Cloud storage (file browser → Cloud storage) first."),
        })
    end
    return items
end

function StatSync:editRoot(touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Folder on the server"),
        input = Plugin.root(),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local root = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    Plugin.settings().root = root ~= "" and root or nil
                    Plugin.saveSettings()
                    UIManager:close(dialog)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function StatSync:addToMainMenu(menu_items)
    local items = self:menuItems()
    items[#items].separator = true
    for _i, item in ipairs(Updater.menuItems(self)) do table.insert(items, item) end
    menu_items.statsync = {
        text = _("Statistics sync"),
        sorting_hint = "tools",
        sub_item_table = items,
    }
end

function StatSync:menuItems()
    return {
        {
            text = _("Sync automatically"),
            help_text = _([[Sync when a book is closed, on wake-up, when the network connects and when KOReader starts. Without a network connection, the sync is skipped; the next one catches up.]]),
            checked_func = function() return Plugin.settings().enabled end,
            callback = function()
                local s = Plugin.settings()
                s.enabled = not s.enabled
                Plugin.saveSettings()
            end,
        },
        {
            text = _("Sync now"),
            keep_menu_open = true,
            callback = function() self.trigger("manual", true) end,
        },
        {
            text_func = function() return T(_("Server: %1"), self:serverText()) end,
            help_text = _([[A WebDAV server set up in Cloud storage, which has its address and login. Only its name is kept here.]]),
            sub_item_table_func = function() return self:serverMenu() end,
        },
        {
            text_func = function() return T(_("Folder on server: %1"), Plugin.root()) end,
            help_text = _([[Use the same server and folder on every device. Changing it sends all of this device's statistics to the new folder at the next sync.]]),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editRoot(touchmenu_instance) end,
        },
        {
            text = _("Sync highlights and bookmarks"),
            help_text = _([[Also sync highlights, notes and page bookmarks, for books with the same file on each device. Changes reach a book when it's open: right away for the book you're reading, otherwise when it's next opened.

Notes are stored on the server as plain text.

While this is on, turn off KOReader's "Export annotations on book closing" (in the reader's Bookmarks settings): the import that goes with it deletes highlights that aren't in the exported file.]]),
            checked_func = function() return Plugin.annotationsEnabled() end,
            callback = function()
                local s = Plugin.settings()
                s.annotations = not Plugin.annotationsEnabled()
                Plugin.saveSettings()
                if s.annotations then
                    local info = InfoMessage:new{ text = _("Reading highlights and bookmarks from the reading history…") }
                    UIManager:show(info)
                    Plugin.startAnnotations(function(stats)
                        UIManager:close(info)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Found highlights and bookmarks in %1 books. They'll be sent at the next sync."), stats.books),
                            timeout = 4,
                        })
                        Plugin.annSync():askHeld()
                        self.trigger("annotations", false, true)
                    end)
                end
            end,
        },
        {
            text_func = function()
                local ok, n = pcall(function() return #Plugin.annStore():held() end)
                return T(_("Removed highlights waiting for you: %1"), ok and n or "?")
            end,
            help_text = _([[When many highlights and bookmarks of a book disappear at once (for example, its settings were reset), they're not removed on the other devices until you decide.]]),
            enabled_func = function()
                if not Plugin.annotationsEnabled() then return false end
                local ok, n = pcall(function() return #Plugin.annStore():held() end)
                return ok and n > 0
            end,
            keep_menu_open = true,
            callback = function() Plugin.annSync():askHeld() end,
        },
        {
            text = _("Turn on Wi-Fi to sync"),
            help_text = _([[When off (the default), automatic syncs are skipped while offline. When on, they turn on Wi-Fi as set in KOReader's network settings.]]),
            checked_func = function() return Plugin.settings().allow_wifi end,
            callback = function()
                local s = Plugin.settings()
                s.allow_wifi = not s.allow_wifi
                Plugin.saveSettings()
            end,
        },
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function() self:showStatus() end,
            separator = true,
        },
        {
            text = _("Rebuild from cloud"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Download and merge every device's statistics again?\n\nNothing is deleted. Use this if statistics are missing on this device."),
                    ok_text = _("Rebuild"),
                    ok_callback = function()
                        Plugin.rebuild()
                        self.trigger("rebuild", true)
                    end,
                })
            end,
        },
        {
            text = _("Reset device ID"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Give this device a new ID?\n\nDo this on a device restored from a backup of another device, or copied from one, so the two don't share an ID."),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        local id = Plugin.resetDeviceId()
                        UIManager:show(InfoMessage:new{ text = T(_("New device ID: %1"), id) })
                    end,
                })
            end,
        },
    }
end

return StatSync
