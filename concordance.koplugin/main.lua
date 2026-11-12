--[[--
Concordance: keeps settings, reading statistics, and highlights and bookmarks
the same on several devices, through a server set up in Cloud storage.

- Settings (with chosen plugins, patches, dictionaries, fonts and style
  tweaks): concordance/settings_engine.lua does the syncing, in a separate
  process; concordance/remote.lua talks to the server (Dropbox or WebDAV).
  See SETTINGS.md.
- Statistics and annotations: concordance/engine.lua runs the sync,
  concordance/store.lua the databases, concordance/webdav.lua and
  concordance/netjob.lua the network (in a subprocess), concordance/plugin.lua
  connects them to KOReader. Annotations: concordance/annstore.lua (data),
  concordance/annsync.lua (in the reader). Book data (status, rating, review,
  custom metadata, handmade table of contents), synced with annotations:
  concordance/bookstore.lua and concordance/booksync.lua. See DESIGN.md,
  ANNOTATIONS.md and BOOKDATA.md.

concordance/migrate.lua takes over OmniSync's data (Concordance's old
name) on this device, the first time.
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

local Plugin = require("concordance/plugin")
local SettingsEngine = require("concordance/settings_engine")
local Updater = require("concordance/updatecore").new{
    name = "concordance",
    title = _("Concordance"),
    settings_key = "concordance_updates",
    log_prefix = "Concordance:",
}
local Updates = require("concordance/updates")

local STARTUP_DELAY = 20 -- s: let KOReader settle (and Wi-Fi come up) first
local CLOSE_DELAY = 2    -- s: after the statistics plugin has written the closed book
local OPEN_DELAY = 2     -- s: after KOReader has put the opened book into its history

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
-- take over OmniSync's data, then put settings pulled last time in place
-- before their plugins read them.
local migrated, startup
do
    local ok, err = pcall(function()
        local plugin_path = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
        migrated = require("concordance/migrate").run{
            kodir = dataDir(),
            settings_dir = require("datastorage"):getSettingsDir(),
            plugins_dir = plugin_path and plugin_path:match("^(.*)/[^/]+$"),
            LuaSettings = require("luasettings"),
            reader_settings = G_reader_settings,
            logger = logger,
        }
        Plugin.reload()
    end)
    if not ok then logger.warn("Concordance: migrating:", err) end
    -- OmniSync is running this time: it was turned off, and Concordance does
    -- nothing until the restart (it would start without OmniSync's data).
    if migrated and migrated.restart then
        local Waiting = WidgetContainer:extend{ name = "concordance", is_doc_only = false }
        function Waiting:init()
            if migrated.shown then return end
            migrated.shown = true
            UIManager:nextTick(function()
                UIManager:askForRestart(_([[Concordance is OmniSync's new name. OmniSync is now turned off; restart KOReader, and Concordance takes over its data and settings.

Then delete omnisync.koplugin from KOReader's plugins folder.]]))
            end)
        end
        return Waiting
    end
    ok, err = pcall(function()
        local p = settingsPaths()
        local applied = SettingsEngine.applyPending(p)
        if applied ~= nil then
            startup = { ok = applied, log = p.apply_log }
            logger.info("Concordance: put pulled settings in place:", applied)
            -- From a device still on OmniSync, they can name its gestures.
            local Migrate = require("concordance/migrate")
            Migrate.renameGestures({
                settings_dir = require("datastorage"):getSettingsDir(),
                LuaSettings = require("luasettings"),
            }, Migrate.stepper({}, logger))
        end
    end)
    if not ok then
        logger.warn("Concordance: putting pulled settings in place:", err)
        startup = { ok = false }
    end
end

local Concordance = WidgetContainer:extend{
    name = "concordance",
    is_doc_only = false,
}

local started -- once per KOReader process
local home    -- the file browser's instance, while it's open

function Concordance:onDispatcherRegisterActions()
    Dispatcher:registerAction("concordance_sync", {
        category = "none", event = "ConcordanceNow", general = true,
        title = _("Concordance: sync statistics and highlights"),
    })
    Dispatcher:registerAction("concordance_settings", {
        category = "none", event = "ConcordanceSettings", general = true,
        title = _("Concordance: sync settings"),
    })
    Dispatcher:registerAction("concordance_statistics", {
        category = "none", event = "ConcordanceStatistics", general = true,
        title = _("Concordance: sync statistics"),
    })
    Dispatcher:registerAction("concordance_annotations", {
        category = "none", event = "ConcordanceAnnotations", general = true,
        title = _("Concordance: sync highlights and bookmarks"),
    })
end

function Concordance:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Plugin.onDone = function(status, run) self.showResult(status, run) end
    require("concordance/problems").enable()
    Plugin.checkKOReader()
    Plugin.installProgressHook()
    Plugin.setupIdentity()
    if not started then
        started = true
        UIManager:scheduleIn(STARTUP_DELAY, function() self.trigger("start") end)
    end
    if self.ui and not self.ui.document then
        home = self
        self:scheduleHomeSync()
    end
    Updates.register(function() return self:updateEntries() end)
    Updates.scheduleCheck()
    if migrated and migrated.omnisync and not migrated.shown then
        migrated.shown = true
        UIManager:nextTick(function()
            notify(_([[Concordance took over OmniSync's data and settings on this device. Delete omnisync.koplugin from KOReader's plugins folder.]]))
        end)
    end
    if startup and not startup.shown then
        startup.shown = true
        UIManager:nextTick(function()
            if startup.ok then
                notify(_("Pulled settings put in place."))
            else
                notify(T(_("Concordance couldn't put all the pulled settings in place. It will try again at the next start.\n\nLog: %1"),
                    startup.log or "?"))
            end
        end)
    end
end

-- Statistics and annotations ----------------------------------------------------

local function syncWhat(run)
    if run.stats and run.ann then return _("Statistics and highlights") end
    return run.ann and _("Highlights and bookmarks") or _("Statistics")
end

--- Shown from when a sync asked for from the menu or a gesture starts until
--- its result replaces it (a tap dismisses it sooner).
local progress

local function showProgress(what)
    if progress then return end
    progress = InfoMessage:new{
        text = (what.stats and what.ann and _("Syncing statistics and highlights…"))
            or (what.ann and _("Syncing highlights and bookmarks…")) or _("Syncing statistics…"),
        dismiss_callback = function() progress = nil end,
    }
    UIManager:show(progress)
    UIManager:forceRePaint() -- before the sync's own work holds up the screen
end

local function hideProgress()
    if progress then
        local p = progress
        progress = nil
        UIManager:close(p)
    end
end

--- Asks for a sync of statistics and/or annotations.
-- what: { stats = bool, ann = bool }; nil for an automatic sync, of what's
-- set to sync automatically.
function Concordance.trigger(reason, what, interactive, scanned, refreshed)
    if not what then
        what = { stats = Plugin.autoStats(), ann = Plugin.autoAnnotations() }
        if not what.stats and not what.ann then return end
    end
    if interactive and NetworkMgr:isConnected() then showProgress(what) end
    if what.ann and not scanned and Plugin.annotationsNeedScan() then
        -- Before the first sync of highlights and bookmarks: read the
        -- reading history, so books not opened since get sent too.
        if Plugin.annSync():scan(function() Concordance.trigger(reason, what, interactive, true) end) then return end
    end
    if what.ann and not refreshed then
        -- Book data changed in the file browser (status, rating, metadata):
        -- read the sidecars that changed since last time.
        -- And find the books in collections and the history (their MD5s),
        -- the first time many.
        if Plugin.bookSync():refresh(function()
            Plugin.collSync():refresh(function()
                Plugin.histSync():refresh(function() Concordance.trigger(reason, what, interactive, true, true) end)
            end)
        end) then
            return
        end
    end
    local opts = { interactive = interactive, stats = what.stats or false, ann = what.ann or false }
    local engine = Plugin.engine()
    if interactive and not engine.running and not NetworkMgr:isConnected() then
        -- Asked for by the user: do what KOReader does for other network actions.
        NetworkMgr:runWhenConnected(function()
            showProgress(what)
            engine:request(reason, opts)
        end)
        return
    end
    if not interactive and not engine.running and not NetworkMgr:isConnected() and Plugin.settings().allow_wifi then
        NetworkMgr:runWhenConnected(function() engine:request(reason, opts) end)
        return
    end
    engine:request(reason, opts)
end


function Concordance.showResult(status, run)
    if not run.interactive then return end
    hideProgress()
    if run.missing_own then
        UIManager:show(ConfirmBox:new{
            text = T(_([[This device has synced statistics and highlights before, but its files aren't in the folder on the server:

%1

If you moved the folder, copy the old one's files there first (see Concordance's README).

Or send everything this device has to this folder?]]), Plugin.serverLocation() or "?"),
            ok_text = _("Send everything"),
            ok_callback = function()
                Plugin.sendEverythingAgain()
                Concordance.trigger("resend", { stats = true, ann = true }, true)
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
            table.insert(lines, T(_("Book status, details, collections and history: sent %1 changes, received %2."),
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

function Concordance:onReadSettings(config)
    -- Before KOReader fills in a missing status: was the book's sidecar new or reset?
    if self.ui and self.ui.document then Plugin.bookSync():onReadSettings(self.ui, config) end
end

function Concordance:onReaderReady()
    local ui = self.ui
    pcall(Plugin.checkReader, ui)
    local function ready()
        Plugin.bookSync():onReaderReady(ui)
        local md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
        Plugin.collSync():onBookOpened(md5)
        if Plugin.annSync():onReaderReady(ui) > 0 then
            UIManager:scheduleIn(1, function() Plugin.annSync():askHeld() end)
        end
        self:scheduleOpenSync()
    end
    -- After KOReader's own post-load work on the annotations (sorting, page numbers).
    if ui.registerPostReaderReadyCallback and ui.postReaderReadyCallback then
        ui:registerPostReaderReadyCallback(ready)
    else
        UIManager:nextTick(ready)
    end
end

--- Opening a book syncs, so the other devices' next sync puts it at the
-- top of their history. Only while Wi-Fi is on already: never turns it on
-- for this.
function Concordance:scheduleOpenSync()
    self:unscheduleOpenSync()
    self.open_tick = function()
        self.open_tick = nil
        if NetworkMgr:isConnected() then self.trigger("open") end
    end
    UIManager:scheduleIn(OPEN_DELAY, self.open_tick)
end

function Concordance:unscheduleOpenSync()
    if self.open_tick then UIManager:unschedule(self.open_tick) end
    self.open_tick = nil
end

function Concordance:onCloseDocument()
    self:unscheduleOpenSync() -- closed already: its own sync follows
    -- KOReader has saved the book's annotations: record its changes now,
    -- while they're still in memory.
    Plugin.bookSync():onClose(self.ui)
    local held = Plugin.annSync():onClose(self.ui)
    if held > 0 then
        UIManager:scheduleIn(1, function() Plugin.annSync():askHeld() end)
    end
    UIManager:scheduleIn(CLOSE_DELAY, function() self.trigger("close") end)
end

-- Syncs every few minutes while the file browser is shown --------------------------

--- (Re)starts the wait for the next sync from the file browser, a full
-- interval from now, or stops it (set to never, or not the file browser).
function Concordance:scheduleHomeSync()
    if self.home_tick then UIManager:unschedule(self.home_tick) end
    self.home_tick = nil
    if home ~= self then return end
    local minutes = Plugin.homeInterval()
    if minutes <= 0 then return end
    self.home_tick = function()
        self.home_tick = nil
        if home ~= self then return end
        -- Only while Wi-Fi is on already: never turns it on for this.
        if NetworkMgr:isConnected() then self.trigger("home") end
        self:scheduleHomeSync()
    end
    UIManager:scheduleIn(minutes * 60, self.home_tick)
end

function Concordance:onCloseWidget()
    if home == self then
        home = nil
        self:scheduleHomeSync()
    end
end

function Concordance:onSuspend()
    if self.home_tick then UIManager:unschedule(self.home_tick) end
    self.home_tick = nil
end

-- Waking up and Wi-Fi connecting sync anyway: the next one from the file
-- browser is a full interval after.
function Concordance:onResume()
    self.trigger("resume")
    self:scheduleHomeSync()
end

function Concordance:onNetworkConnected()
    self.trigger("network")
    self:scheduleHomeSync()
end

function Concordance:onConcordanceNow()
    self.trigger("manual", { stats = true, ann = true }, true)
    return true
end

function Concordance:onConcordanceStatistics()
    self.trigger("manual", { stats = true }, true)
    return true
end

function Concordance:onConcordanceAnnotations()
    self.trigger("manual", { ann = true }, true)
    return true
end

-- Settings ---------------------------------------------------------------------------

function Concordance:onConcordanceSettings()
    self:syncSettings()
    return true
end

--- buttons: an optional row of buttons, shown instead of Close and Find.
--- Their callbacks get the viewer, to close it.
function Concordance:showLog(title, text, buttons)
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

function Concordance:syncSettings(preview)
    local p = settingsPaths()
    if not preview and SettingsEngine.isPending(p) then
        UIManager:askForRestart(_("Pulled settings are waiting to be put in place at the next start. Syncing now would send the old ones back.\n\nRestart KOReader first?"))
        return
    end
    local server, why = Plugin.server()
    if not server then
        notify(T(_("Settings sync uses a Dropbox or WebDAV server from Cloud storage (%1). Add one there first (file browser → Cloud storage), or choose it in Tools → Concordance → Server."), why))
        return
    end
    local root = Plugin.settingsRoot()
    local device = Plugin.deviceName() or "?"
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
                    local Remote = require("concordance/remote")
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

function Concordance:reportSettings(result, preview)
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

function Concordance:serverText()
    local server = Plugin.server()
    if server then
        return T("%1 (%2)", server.name or server.address or "?", Plugin.TYPES[server.type] or server.type)
    end
    local chosen = Plugin.settings().server
    return chosen and T(_("%1 (not in Cloud storage)"), chosen.name or "?") or _("not set")
end

function Concordance:showStatus()
    local d = Plugin.deviceState()
    local st = d.status or {}
    local ok, counts = pcall(function() return Plugin.makeStore():counts() end)
    counts = ok and counts or {}
    local aok, a = pcall(function() return Plugin.annStore():counts() end)
    a = aok and a or {}
    local bok, b = pcall(function() return Plugin.bookStore():counts() end)
    b = bok and b or {}
    local iok, id = pcall(function() return Plugin.idStore():counts() end)
    id = iok and id or {}
    local function onOff(v) return v and _("on") or _("off") end
    local lines = {
        T(_("Server: %1"), self:serverText()),
        T(_("Settings folder: %1"), Plugin.settingsRoot()),
        T(_("Statistics and highlights folder: %1"), Plugin.serverLocation() or Plugin.serverProblem() or "?"),
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
        "",
        T(_("Book identity (synced with highlights): %1 book files known, %2 read on this device"),
            id.files or "?", id.scanned or "?"),
        T(_("Books known in more than one version: %1"), id.versions or "?"),
        T(_("Books with different editions under one ID: %1"), id.editions or "?"),
        T(_("Book IDs shared by unrelated books (not joined): %1"), id.held or "?"),
        T(_("Facts waiting to be sent: %1"), id.outbox or "?"),
        T(_("Facts sent last time: %1, received: %2"), st.id_uploaded or 0, st.id_imported or 0),
        T(_("Files imported: %1, unreadable: %2"), counts.id_seen or "?", counts.id_bad or "?"),
    }
    local problems = require("concordance/problems").statusLines()
    table.insert(lines, 1, "")
    if #problems == 0 then
        table.insert(lines, 1, _("Problems since KOReader started: none"))
    else
        for i = #problems, 1, -1 do table.insert(lines, 1, "• " .. problems[i]) end
        table.insert(lines, 1, _("Problems since KOReader started (often from a KOReader or ZenOS update):"))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

--- The Dropbox and WebDAV servers from Cloud storage, to choose one.
function Concordance:serverMenu()
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

function Concordance:editRoot(touchmenu_instance)
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

local function heldCount()
    local ok, n = pcall(function() return #Plugin.annStore():held() end)
    return ok and n or 0
end

function Concordance:showSettingsLog(p)
    local file = io.open(p.log, "r")
    local log = file and file:read("*a")
    if file then file:close() end
    local apply = io.open(p.apply_log, "r")
    if apply then
        log = (log or "") .. "\n" .. apply:read("*a")
        apply:close()
    end
    self:showLog(_("Settings sync log"), log or _("No settings sync has run yet."))
end

function Concordance:menuItems()
    local p = settingsPaths()
    local items = {
        {
            text = _("Sync now"),
            help_text = _([[Sync statistics, highlights, bookmarks and book status. Settings are synced on their own, in Settings.]]),
            keep_menu_open = true,
            callback = function() self.trigger("manual", { stats = true, ann = true }, true) end,
        },
    }
    -- Only when there's something to decide.
    local held = heldCount()
    if held > 0 then
        table.insert(items, {
            text = T(_("Removed highlights waiting for you: %1"), held),
            help_text = _([[When many highlights and bookmarks of a book disappear at once (for example, its settings were reset), they're not removed on the other devices until you decide.]]),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                Plugin.annSync():askHeld()
            end,
        })
    end
    if SettingsEngine.isPending(p) then
        table.insert(items, {
            text = _("Discard pulled settings waiting for a restart"),
            callback = function(touchmenu_instance)
                SettingsEngine.discardPending(p)
                notify(_("Discarded. The next settings sync sends this device's settings."))
                if touchmenu_instance then touchmenu_instance:closeMenu() end
            end,
        })
    end
    items[#items].separator = true

    local more = {
        {
            text = _("Settings"),
            help_text = _([[Settings, plugins, patches, dictionaries, fonts and anything else in KOReader's folder that settings/concordance/sync.txt lists. Pulled settings are put in place at the next start.]]),
            sub_item_table = {
                {
                    text = _("Sync now"),
                    callback = function(touchmenu_instance)
                        if touchmenu_instance then touchmenu_instance:closeMenu() end
                        self:syncSettings()
                    end,
                },
                {
                    text = _("Preview changes"),
                    help_text = _("Shows what a sync would change, without changing anything."),
                    callback = function(touchmenu_instance)
                        if touchmenu_instance then touchmenu_instance:closeMenu() end
                        self:syncSettings(true)
                    end,
                },
                {
                    text = _("Log"),
                    help_text = _("The last settings sync, and putting pulled settings in place."),
                    keep_menu_open = true,
                    callback = function() self:showSettingsLog(p) end,
                },
            },
        },
        {
            text = _("Statistics"),
            sub_item_table = {
                {
                    text = _("Sync now"),
                    keep_menu_open = true,
                    callback = function() self.trigger("manual", { stats = true }, true) end,
                },
                {
                    text = _("Sync automatically"),
                    help_text = _([[Sync reading statistics when a book is closed, on wake-up, when the network connects and when KOReader starts. Without a network connection, the sync is skipped; the next one catches up.]]),
                    checked_func = Plugin.autoStats,
                    callback = function() toggle("auto_stats") end,
                },
            },
        },
        {
            text = _("Highlights and books"),
            help_text = _([[Highlights, notes and page bookmarks, with book status (reading, on hold, finished), rating, review, custom metadata (title, authors, series…), the handmade table of contents, hidden flows, collections and favorites, and the reading history.]]),
            sub_item_table = {
                {
                    text = _("Sync now"),
                    keep_menu_open = true,
                    callback = function() self.trigger("manual", { ann = true }, true) end,
                },
                {
                    text = _("Sync automatically"),
                    help_text = _([[Sync highlights, notes and page bookmarks at the same times as statistics, for books with the same file on each device. Changes from other devices are written into books right after a sync, including books that aren't open (if they've been opened on this device before).

Book status (reading, on hold, finished), rating, review, custom metadata (title, authors, series…) and the handmade table of contents and hidden flows are synced with them, and so are collections and favorites (which books are in which, and the collections' names) and the reading history (when each book was last opened: a book read on another device goes into this device's history at the time it was read; books removed from the history aren't removed elsewhere). Status, rating, review, metadata and collections are written into books that aren't open too; the table of contents waits until the book is opened.

A book read elsewhere that isn't on this device appears in the history only if Cloud library is installed and has it: tap it to download it.

Notes and reviews are stored on the server as plain text.

Turn off KOReader's "Export annotations on book closing" (in the reader's Bookmarks settings): the import that goes with it deletes highlights that aren't in the exported file.]]),
                    checked_func = Plugin.autoAnnotations,
                    callback = function() toggle("auto_annotations") end,
                },
            },
            separator = true,
        },
        {
            text_func = function() return T(_("Server: %1"), self:serverText()) end,
            help_text = _([[A Dropbox or WebDAV server set up in Cloud storage, which has its address and login. Only its name is kept here. Statistics and highlights need a WebDAV server.]]),
            sub_item_table_func = function() return self:serverMenu() end,
        },
        {
            text_func = function() return T(_("Folder on server: %1"), Plugin.root()) end,
            help_text = _([[Settings are synced in its Files folder, statistics, highlights and book data in its Reading folder. Use the same server and folder on every device.]]),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:editRoot(touchmenu_instance) end,
        },
        {
            text_func = function()
                local m = Plugin.homeInterval()
                return T(_("Sync in the file browser: %1"),
                    m > 0 and T(_("every %1 min"), m) or _("never"))
            end,
            help_text = _([[While the file browser is shown, sync statistics and highlights this often too (as set to sync automatically), so changes from other devices show up without opening a book. Only while Wi-Fi is on: it's never turned on for this.]]),
            sub_item_table_func = function()
                local list = {}
                local function choice(text, minutes)
                    table.insert(list, {
                        text = text,
                        radio = true,
                        checked_func = function() return Plugin.homeInterval() == minutes end,
                        callback = function()
                            Plugin.settings().home_interval = minutes > 0 and minutes or nil
                            Plugin.saveSettings()
                            if home then home:scheduleHomeSync() end
                        end,
                    })
                end
                for _i, m in ipairs(Plugin.HOME_INTERVALS) do choice(T(_("Every %1 minutes"), m), m) end
                choice(_("Never"), 0)
                return list
            end,
        },
        {
            text = _("Turn on Wi-Fi for automatic syncs"),
            help_text = _([[When off (the default), automatic syncs are skipped while offline. When on, they turn on Wi-Fi as set in KOReader's network settings. Syncs from the menu always offer to connect.]]),
            checked_func = function() return Plugin.settings().allow_wifi end,
            callback = function()
                local s = Plugin.settings()
                s.allow_wifi = not s.allow_wifi
                Plugin.saveSettings()
            end,
            separator = true,
        },
        {
            text = _("Status"),
            keep_menu_open = true,
            callback = function() self:showStatus() end,
        },
        {
            text = _("Troubleshooting"),
            sub_item_table = {
                {
                    text = _("Rebuild from server"),
                    help_text = _("Downloads and merges every device's statistics and highlights again. Nothing is deleted."),
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
                },
            },
            separator = true,
        },
    }
    for _i, item in ipairs(more) do table.insert(items, item) end
    for _i, item in ipairs(Updates.menuItems()) do table.insert(items, item) end
    return items
end

--- Cloud library's running instance and its own updater, when it's
-- installed and enabled (it loaded its updater at start).
function Concordance:cloudLibrary()
    local plugin = self.ui and self.ui.cloudlibrary
    local updater = package.loaded["cloudlibrary/updater"]
    if plugin and plugin.path and plugin.version and type(updater) == "table" and updater.check then
        return plugin, updater
    end
end

--- The plugins checked together for updates (concordance/updates.lua): this
-- one and Cloud library, each with its own updater and settings. A Cloud
-- library from before it handed its automatic check to Concordance keeps it.
function Concordance:updateEntries()
    local entries = { { updater = Updater, plugin = self } }
    local plugin, updater = self:cloudLibrary()
    if plugin then
        table.insert(entries, { updater = updater, plugin = plugin, own_automatic = not updater.defers_to_concordance })
    end
    return entries
end

function Concordance:addToMainMenu(menu_items)
    menu_items.concordance = {
        text = _("Concordance"),
        sorting_hint = "tools",
        sub_item_table_func = function() return self:menuItems() end,
    }
end

return Concordance
