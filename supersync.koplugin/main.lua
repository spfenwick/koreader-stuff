--[[--
SuperSync: keeps settings, reading statistics, and highlights and bookmarks
the same on several devices, through a server set up in Cloud storage.

- Settings (with chosen plugins, patches, dictionaries, fonts and style
  tweaks): supersync/settings_engine.lua does the syncing, in a separate
  process; supersync/remote.lua talks to the server (Dropbox or WebDAV).
  See SETTINGS.md.
- Statistics and annotations: supersync/engine.lua runs the sync,
  supersync/store.lua the databases, supersync/webdav.lua and
  supersync/netjob.lua the network (in a subprocess), supersync/plugin.lua
  connects them to KOReader. Annotations: supersync/annstore.lua (data),
  supersync/annsync.lua (in the reader). Book data (status, rating, review,
  custom metadata, handmade table of contents), synced with annotations:
  supersync/bookstore.lua and supersync/booksync.lua. See DESIGN.md,
  ANNOTATIONS.md and BOOKDATA.md.

supersync/migrate.lua takes over Settings sync's and Statistics sync's
data on this device, the first time.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Plugin = require("supersync/plugin")
local SettingsEngine = require("supersync/settings_engine")
local Updater = require("supersync/updatecore").new{
    name = "supersync",
    title = _("SuperSync"),
    settings_key = "supersync_updates",
    log_prefix = "SuperSync:",
}

local STARTUP_DELAY = 20 -- s: let KOReader settle (and Wi-Fi come up) first
local CLOSE_DELAY = 2    -- s: after the statistics plugin has written the closed book

--- KOReader's data folder, made absolute ("." on e-readers).
local function dataDir()
    local dir = require("datastorage"):getDataDir()
    if dir:sub(1, 1) ~= "/" then
        local lfs = require("libs/libkoreader-lfs")
        dir = lfs.currentdir() .. (dir == "." and "" or "/" .. dir:gsub("^%./", ""))
    end
    return (dir:gsub("/+$", ""))
end

local function settingsPaths() return SettingsEngine.paths(dataDir()) end

--- A message that stays until the screen is tapped.
local function notify(text)
    UIManager:show(InfoMessage:new{ text = text })
end

-- Runs as KOReader loads its plugins, before any of them is started: first
-- take over the old plugins' data, then put settings pulled last time in
-- place before their plugins read them.
local migrated, startup
do
    local ok, err = pcall(function()
        local plugin_path = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
        migrated = require("supersync/migrate").run{
            kodir = dataDir(),
            settings_dir = require("datastorage"):getSettingsDir(),
            plugins_dir = plugin_path and plugin_path:match("^(.*)/[^/]+$"),
            LuaSettings = require("luasettings"),
            reader_settings = G_reader_settings,
            forgetLocation = function(state_path)
                require("supersync/store").new{
                    sq3 = require("lua-ljsqlite3/init"), stats_path = state_path, state_path = state_path,
                }:forgetLocation()
            end,
            logger = logger,
        }
        Plugin.reload()
    end)
    if not ok then logger.warn("SuperSync: migrating:", err) end
    ok, err = pcall(function()
        local p = settingsPaths()
        local applied = SettingsEngine.applyPending(p)
        if applied ~= nil then
            startup = { ok = applied, log = p.apply_log }
            logger.info("SuperSync: put pulled settings in place:", applied)
        end
    end)
    if not ok then
        logger.warn("SuperSync: putting pulled settings in place:", err)
        startup = { ok = false }
    end
end

local SuperSync = WidgetContainer:extend{
    name = "supersync",
    is_doc_only = false,
}

local started -- once per KOReader process

function SuperSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("supersync_settings", {
        category = "none", event = "SuperSyncSettings", general = true,
        title = _("SuperSync: sync settings"),
    })
    Dispatcher:registerAction("supersync_statistics", {
        category = "none", event = "SuperSyncStatistics", general = true,
        title = _("SuperSync: sync statistics"),
    })
    Dispatcher:registerAction("supersync_annotations", {
        category = "none", event = "SuperSyncAnnotations", general = true,
        title = _("SuperSync: sync highlights and bookmarks"),
    })
end

function SuperSync:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Plugin.onDone = function(status, run) self.showResult(status, run) end
    if not started then
        started = true
        UIManager:scheduleIn(STARTUP_DELAY, function() self.trigger("start") end)
    end
    Updater.scheduleCheck(self)
    if migrated and #migrated > 0 and not migrated.shown then
        migrated.shown = true
        UIManager:nextTick(function()
            notify(_([[SuperSync took over Settings sync's and Statistics sync's data on this device, and turned those two plugins off: delete rclonesync.koplugin and statsync.koplugin from KOReader's plugins folder.

Then set SuperSync's server and folder (Tools → SuperSync). Copy the old folders' files on the server there first (see SuperSync's README), so nothing is sent again.]]))
        end)
    end
    if startup and not startup.shown then
        startup.shown = true
        UIManager:nextTick(function()
            if startup.ok then
                notify(_("Pulled settings put in place."))
            else
                notify(T(_("SuperSync couldn't put all the pulled settings in place. It will try again at the next start.\n\nLog: %1"),
                    startup.log or "?"))
            end
        end)
    end
end

-- Statistics and annotations ----------------------------------------------------

--- Asks for a sync of statistics and/or annotations.
-- what: { stats = bool, ann = bool }; nil for an automatic sync, of what's
-- set to sync automatically.
function SuperSync.trigger(reason, what, interactive, scanned, refreshed)
    if not what then
        what = { stats = Plugin.autoStats(), ann = Plugin.autoAnnotations() }
        if not what.stats and not what.ann then return end
    end
    if what.ann and not scanned and Plugin.annotationsNeedScan() then
        -- Before the first sync of highlights and bookmarks: read the
        -- reading history, so books not opened since get sent too.
        if Plugin.annSync():scan(function() SuperSync.trigger(reason, what, interactive, true) end) then return end
    end
    if what.ann and not refreshed then
        -- Book data changed in the file browser (status, rating, metadata):
        -- read the sidecars that changed since last time.
        if Plugin.bookSync():refresh(function() SuperSync.trigger(reason, what, interactive, true, true) end) then
            return
        end
    end
    local opts = { interactive = interactive, stats = what.stats or false, ann = what.ann or false }
    local engine = Plugin.engine()
    if interactive and not engine.running and not NetworkMgr:isConnected() then
        -- Asked for by the user: do what KOReader does for other network actions.
        NetworkMgr:runWhenConnected(function() engine:request(reason, opts) end)
        return
    end
    if not interactive and not engine.running and not NetworkMgr:isConnected() and Plugin.settings().allow_wifi then
        NetworkMgr:runWhenConnected(function() engine:request(reason, opts) end)
        return
    end
    engine:request(reason, opts)
end

local function syncWhat(run)
    if run.stats and run.ann then return _("Statistics and highlights") end
    return run.ann and _("Highlights and bookmarks") or _("Statistics")
end

function SuperSync.showResult(status, run)
    if not run.interactive then return end
    if run.missing_own then
        UIManager:show(ConfirmBox:new{
            text = T(_([[This device has synced statistics and highlights before, but its files aren't in the folder on the server:

%1

If you moved the folder, copy the old one's files there first (see SuperSync's README).

Or send everything this device has to this folder?]]), Plugin.serverLocation() or "?"),
            ok_text = _("Send everything"),
            ok_callback = function()
                Plugin.sendEverythingAgain()
                SuperSync.trigger("resend", { stats = true, ann = true }, true)
            end,
        })
        return
    end
    local text
    if run.skipped then
        text = T(_("%1 not synced: %2"), syncWhat(run), status.last_error or run.error or "")
    elseif run.error then
        text = T(_("%1 sync failed: %2"), syncWhat(run), run.error)
    else
        local lines = {}
        if run.stats then
            table.insert(lines, T(_("Statistics: sent %1 entries, received %2 entries from %3 files."),
                run.uploaded_events or 0, run.imported_events or 0, run.segments_imported or 0))
        end
        if run.ann then
            table.insert(lines, T(_("Highlights and bookmarks: sent %1 changes, received %2."),
                run.ann_uploaded_records or 0, run.ann_imported_records or 0))
        end
        if run.upload_error then
            table.insert(lines, T(_("Upload of statistics failed: %1"), run.upload_error))
        end
        if run.book then
            table.insert(lines, T(_("Book status and details: sent %1 changes, received %2."),
                run.book_uploaded_records or 0, run.book_imported_records or 0))
        end
        if run.ann_upload_error then
            table.insert(lines, T(_("Upload of highlights and bookmarks failed: %1"), run.ann_upload_error))
        end
        if run.book_upload_error then
            table.insert(lines, T(_("Upload of book status and details failed: %1"), run.book_upload_error))
        end
        text = T(_("%1 synced."), syncWhat(run)) .. "\n" .. table.concat(lines, "\n")
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = run.error and nil or 4 })
end

function SuperSync:onReadSettings(config)
    -- Before KOReader fills in a missing status: was the book's sidecar new or reset?
    if self.ui and self.ui.document then Plugin.bookSync():onReadSettings(self.ui, config) end
end

function SuperSync:onReaderReady()
    local ui = self.ui
    local function ready()
        Plugin.bookSync():onReaderReady(ui)
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

function SuperSync:onCloseDocument()
    -- KOReader has saved the book's annotations: record its changes now,
    -- while they're still in memory.
    Plugin.bookSync():onClose(self.ui)
    local held = Plugin.annSync():onClose(self.ui)
    if held > 0 then
        UIManager:scheduleIn(1, function() Plugin.annSync():askHeld() end)
    end
    UIManager:scheduleIn(CLOSE_DELAY, function() self.trigger("close") end)
end

function SuperSync:onResume() self.trigger("resume") end
function SuperSync:onNetworkConnected() self.trigger("network") end

function SuperSync:onSuperSyncStatistics()
    self.trigger("manual", { stats = true }, true)
    return true
end

function SuperSync:onSuperSyncAnnotations()
    self.trigger("manual", { ann = true }, true)
    return true
end

-- Settings ---------------------------------------------------------------------------

function SuperSync:onSuperSyncSettings()
    self:syncSettings()
    return true
end

--- buttons: an optional row of buttons, shown instead of Close and Find.
--- Their callbacks get the viewer, to close it.
function SuperSync:showLog(title, text, buttons)
    local TextViewer = require("ui/widget/textviewer")
    local viewer
    local row
    if buttons then
        row = {}
        for __, button in ipairs(buttons) do
            table.insert(row, {
                text = button.text,
                callback = function() button.callback(viewer) end,
            })
        end
    end
    viewer = TextViewer:new{
        title = title,
        text = text ~= "" and text or _("(nothing)"),
        monospace_font = true,
        justified = false,
        buttons_table = row and { row },
    }
    UIManager:show(viewer)
    return viewer
end

function SuperSync:syncSettings(preview)
    local p = settingsPaths()
    if not preview and SettingsEngine.isPending(p) then
        UIManager:askForRestart(_("Pulled settings are waiting to be put in place at the next start. Syncing now would send the old ones back.\n\nRestart KOReader first?"))
        return
    end
    local server, why = Plugin.server()
    if not server then
        notify(T(_("Settings sync uses a Dropbox or WebDAV server from Cloud storage (%1). Add one there first (file browser → Cloud storage), or choose it in Tools → SuperSync → Server."), why))
        return
    end
    local root = Plugin.settingsRoot()
    local device = require("device").model or "?"
    NetworkMgr:runWhenOnline(function()
        if not preview then
            -- So what's synced is what's in use.
            UIManager:broadcastEvent(Event:new("FlushSettings"))
            G_reader_settings:flush()
        end
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local text = preview and _("Checking what would change…") or _("Syncing settings…")
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local ok, res = pcall(function()
                    local Remote = require("supersync/remote")
                    local remote, err = Remote.new(server, root)
                    if not remote then return { fatal = err, log = err } end
                    return SettingsEngine.sync({ paths = p, remote = remote, device = device },
                        { preview = preview })
                end)
                if ok then return res end
                return { fatal = tostring(res), log = tostring(res) }
            end, text)
            if not completed then
                notify(_("Sync cancelled. Run it again to finish."))
                return
            end
            self:reportSettings(result or { fatal = _("The sync stopped unexpectedly.") }, preview)
        end)
    end)
end

function SuperSync:reportSettings(result, preview)
    local log = result.log or ""
    if result.fatal then
        notify(result.fatal)
        return
    end
    local changes = (result.uploaded or 0) + (result.downloaded or 0)
        + (result.deleted_here or 0) + (result.deleted_server or 0)
    if preview then
        self:showLog(T(_("Sync would make %1 changes"), changes), log, {
            { text = _("Close"), callback = function(viewer) UIManager:close(viewer) end },
            {
                text = _("Sync now"),
                callback = function(viewer)
                    UIManager:close(viewer)
                    self:syncSettings()
                end,
            },
        })
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
        notify(T(_("Some files had changed on more than one device:\n\n%1\n\nThe other versions are in %2."),
            table.concat(lines, "\n"), settingsPaths().conflicts))
    end
    if result.restart then
        UIManager:askForRestart(summary .. "\n\n"
            .. (result.pending and _("Pulled settings are put in place when KOReader restarts.")
                or _("The new files are used after KOReader restarts.")))
    elseif changes == 0 and (result.already_there or 0) == 0 then
        notify(_("Settings already up to date."))
    else
        notify(summary)
    end
end

-- Menu -------------------------------------------------------------------------------

local function when(ts)
    return ts and datetime.secondsToDateTime(ts) or _("never")
end

function SuperSync:serverText()
    local server = Plugin.server()
    if server then
        return T("%1 (%2)", server.name or server.address or "?", Plugin.TYPES[server.type] or server.type)
    end
    local chosen = Plugin.settings().server
    return chosen and T(_("%1 (not in Cloud storage)"), chosen.name or "?") or _("not set")
end

function SuperSync:showStatus()
    local d = Plugin.deviceState()
    local st = d.status or {}
    local ok, counts = pcall(function() return Plugin.makeStore():counts() end)
    counts = ok and counts or {}
    local aok, a = pcall(function() return Plugin.annStore():counts() end)
    a = aok and a or {}
    local bok, b = pcall(function() return Plugin.bookStore():counts() end)
    b = bok and b or {}
    local function onOff(v) return v and _("on") or _("off") end
    local lines = {
        T(_("Server: %1"), self:serverText()),
        T(_("Settings folder: %1"), Plugin.settingsRoot()),
        T(_("Statistics folder: %1"), Plugin.serverLocation() or Plugin.serverProblem() or "?"),
        T(_("Last attempt: %1"), when(st.last_attempt)),
        T(_("Last error: %1"), st.last_error or _("none")),
        T(_("Devices seen: %1"), st.devices or "?"),
        T(_("This device's ID: %1"), d.device_id or _("not yet created")),
        "",
        T(_("Statistics: automatic sync %1, last synced %2"), onOff(Plugin.autoStats()),
            when(st.stats_last_success or st.last_success)),
        T(_("Entries sent last time: %1, received: %2"), st.uploaded_events or 0, st.imported_events or 0),
        T(_("Entries published or received in total: %1"), counts.exported or "?"),
        T(_("Files imported: %1, unreadable: %2"), counts.seen or "?", counts.bad or "?"),
        "",
        T(_("Highlights and bookmarks: automatic sync %1, last synced %2"), onOff(Plugin.autoAnnotations()),
            when(st.ann_last_success)),
        T(_("%1 in %2 books"), a.annotations or "?", a.books or "?"),
        T(_("Changes waiting to be sent: %1"), a.outbox or "?"),
        T(_("Books to update when opened: %1"), a.pending or "?"),
        T(_("Books with removals waiting for you: %1"), a.held or "?"),
        T(_("Changes sent last time: %1, received: %2"), st.ann_uploaded or 0, st.ann_imported or 0),
        T(_("Files imported: %1, unreadable: %2"), counts.ann_seen or "?", counts.ann_bad or "?"),
        T(_("Reading history read: %1"), when(d.ann_scanned)),
        "",
        T(_("Book status and details (synced with highlights): %1 books"), b.books or "?"),
        T(_("Changes waiting to be sent: %1"), b.outbox or "?"),
        T(_("Books to update on this device: %1"), b.write or "?"),
        T(_("Changes sent last time: %1, received: %2"), st.book_uploaded or 0, st.book_imported or 0),
        T(_("Files imported: %1, unreadable: %2"), counts.book_seen or "?", counts.book_bad or "?"),
    }
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--- The Dropbox and WebDAV servers from Cloud storage, to choose one.
function SuperSync:serverMenu()
    local items = {}
    for _i, server in ipairs(Plugin.servers()) do
        table.insert(items, {
            text = T("%1 (%2)", server.name or server.address or "?", Plugin.TYPES[server.type] or server.type),
            radio = true,
            checked_func = function()
                local current = Plugin.server()
                return current ~= nil and current.name == server.name and current.type == server.type
            end,
            callback = function()
                Plugin.settings().server = { name = server.name, type = server.type }
                Plugin.saveSettings()
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("No Dropbox or WebDAV servers in Cloud storage"),
            enabled = false,
            help_text = _("Add a server in Cloud storage (file browser → Cloud storage) first."),
        })
    end
    return items
end

function SuperSync:editRoot(touchmenu_instance)
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

local function toggle(key)
    local s = Plugin.settings()
    s[key] = s[key] == false -- on unless false
    Plugin.saveSettings()
end

function SuperSync:menuItems()
    local p = settingsPaths()
    local items = {
        {
            text = _("Sync settings"),
            help_text = _([[Settings, and the plugins, patches, dictionaries, fonts and style tweaks the lists in koreader/supersync/ name. Pulled settings are put in place at the next start.]]),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:syncSettings()
            end,
        },
        {
            text = _("Preview settings sync (what would change)"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:syncSettings(true)
            end,
        },
        {
            text = _("Sync statistics"),
            keep_menu_open = true,
            callback = function() self.trigger("manual", { stats = true }, true) end,
        },
        {
            text = _("Sync highlights and bookmarks"),
            keep_menu_open = true,
            callback = function() self.trigger("manual", { ann = true }, true) end,
            separator = true,
        },
        {
            text = _("Sync statistics automatically"),
            help_text = _([[Sync reading statistics when a book is closed, on wake-up, when the network connects and when KOReader starts. Without a network connection, the sync is skipped; the next one catches up.]]),
            checked_func = Plugin.autoStats,
            callback = function() toggle("auto_stats") end,
        },
        {
            text = _("Sync highlights and bookmarks automatically"),
            help_text = _([[Sync highlights, notes and page bookmarks at the same times, for books with the same file on each device. Changes reach a book when it's open: right away for the book you're reading, otherwise when it's next opened.

Book status (reading, on hold, finished), rating, review, custom metadata (title, authors, series…) and the handmade table of contents and hidden flows are synced with them. Status, rating, review and metadata are written into books that aren't open too; the table of contents waits until the book is opened.

Notes and reviews are stored on the server as plain text.

Turn off KOReader's "Export annotations on book closing" (in the reader's Bookmarks settings): the import that goes with it deletes highlights that aren't in the exported file.]]),
            checked_func = Plugin.autoAnnotations,
            callback = function() toggle("auto_annotations") end,
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
            separator = true,
        },
    }
    if SettingsEngine.isPending(p) then
        table.insert(items, {
            text = _("Discard pulled settings waiting for a restart"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                SettingsEngine.discardPending(p)
                notify(_("Discarded. The next settings sync sends this device's settings."))
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end
    local more = {
        {
            text_func = function()
                local ok, n = pcall(function() return #Plugin.annStore():held() end)
                return T(_("Removed highlights waiting for you: %1"), ok and n or "?")
            end,
            help_text = _([[When many highlights and bookmarks of a book disappear at once (for example, its settings were reset), they're not removed on the other devices until you decide.]]),
            enabled_func = function()
                local ok, n = pcall(function() return #Plugin.annStore():held() end)
                return ok and n > 0
            end,
            keep_menu_open = true,
            callback = function() Plugin.annSync():askHeld() end,
            separator = true,
        },
        {
            text_func = function() return T(_("Server: %1"), self:serverText()) end,
            help_text = _([[A Dropbox or WebDAV server set up in Cloud storage, which has its address and login. Only its name is kept here. Statistics and highlights need a WebDAV server.]]),
            sub_item_table_func = function() return self:serverMenu() end,
        },
        {
            text_func = function() return T(_("Folder on server: %1"), Plugin.root()) end,
            help_text = _([[Settings are synced in its Settings folder, statistics and highlights in its Statistics folder. Use the same server and folder on every device.]]),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editRoot(touchmenu_instance) end,
            separator = true,
        },
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function() self:showStatus() end,
        },
        {
            text = _("Show last settings sync log"),
            callback = function()
                local file = io.open(p.log, "r")
                local log = file and file:read("*a")
                if file then file:close() end
                local apply = io.open(p.apply_log, "r")
                if apply then
                    log = (log or "") .. "\n" .. apply:read("*a")
                    apply:close()
                end
                self:showLog(_("Settings sync log"), log or _("No settings sync has run yet."))
            end,
        },
        {
            text = _("Rebuild statistics and highlights from cloud"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Download and merge every device's statistics and highlights again?\n\nNothing is deleted. Use this if statistics are missing on this device."),
                    ok_text = _("Rebuild"),
                    ok_callback = function()
                        Plugin.rebuild()
                        self.trigger("rebuild", { stats = true, ann = true }, true)
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
                        notify(T(_("New device ID: %1"), id))
                    end,
                })
            end,
            separator = true,
        },
    }
    for _i, item in ipairs(more) do table.insert(items, item) end
    for _i, item in ipairs(Updater.menuItems(self)) do table.insert(items, item) end
    return items
end

function SuperSync:addToMainMenu(menu_items)
    menu_items.supersync = {
        text = _("SuperSync"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

return SuperSync
