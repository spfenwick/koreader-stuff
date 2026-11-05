# OmniSync (omnisync.koplugin)

Keeps KOReader the same on several devices, through a server set up in
KOReader's Cloud storage:

- **Settings**, and the plugins, patches, dictionaries, fonts and style
  tweaks you choose (Dropbox or WebDAV). See [SETTINGS.md](SETTINGS.md).
- **Reading statistics** (WebDAV). See [STATISTICS.md](STATISTICS.md).
- **Highlights, notes and page bookmarks** (WebDAV). See
  [STATISTICS.md](STATISTICS.md#highlights-and-bookmarks).
- **Book status, rating, review, custom metadata and handmade table of
  contents**, with highlights (WebDAV). See
  [STATISTICS.md](STATISTICS.md#book-status-and-details).

It was called SuperSync, and takes over SuperSync's data on each device
(see [Moving from SuperSync](#moving-from-supersync)).

## Install

1. Copy `omnisync.koplugin` into KOReader's `plugins/` folder and restart
   KOReader. Statistics need the Reading statistics plugin enabled.
2. Add your server in Cloud storage (file browser → Cloud storage), if it
   isn't there already. Statistics and highlights need a WebDAV server;
   settings work with Dropbox too.
3. Tools → OmniSync → Server: choose it (with none chosen, the first
   Dropbox or WebDAV server in Cloud storage is used). The server is
   remembered by its name, so give it the same name on every device.
4. Tools → OmniSync → Folder on server: `/KOReader` unless you change it.
   It's relative to the server's address; the folder set for the server in
   Cloud storage isn't used. Use the same server and folder on every device.
5. For settings, list what to sync in `settings/omnisync/sync.txt`
   (see [SETTINGS.md](SETTINGS.md)).

## Menu

Tools → OmniSync, in both the file browser and the reader:

- **Sync settings**, and **Preview settings sync** (what would change).
- **Sync statistics**.
- **Sync highlights and bookmarks**.
- **Sync statistics automatically**: on unless you turn it off.
- **Sync highlights and bookmarks automatically**: on unless you turn it off.
- **Turn on Wi-Fi to sync**: for automatic syncs (off by default).
- **Discard pulled settings waiting for a restart** (only while there are
  some; see [SETTINGS.md](SETTINGS.md#moving-to-another-server)).
- **Removed highlights waiting for you**: highlights and bookmarks removed
  in bulk on this device, waiting for you to say whether to remove them
  everywhere.
- **Server** and **Folder on server**.
- **Status**: server and folders, last syncs and errors, devices seen,
  what was sent and received, this device's ID.
- **Show last settings sync log**.
- **Rebuild statistics and highlights from cloud**: imports every device's
  files again. Nothing is deleted.
- **Reset device ID**: for a device restored from a backup of another one.
- **Check for updates** and **Automatic updates** (see Updates).

Each of the three syncs is also a gesture (General → "OmniSync: sync
settings", "OmniSync: sync statistics", "OmniSync: sync highlights and
bookmarks").

## When it syncs

Settings only sync when you ask (a settings sync can ask to restart
KOReader).

Statistics and highlights sync automatically (each unless turned off): when
a book is closed, on wake-up, when the network connects, and 20 seconds
after KOReader starts. Without a network connection an automatic sync is
skipped; nothing is queued, the next sync catches up. "Turn on Wi-Fi to
sync" makes automatic syncs turn Wi-Fi on the way KOReader's network
settings say. A sync by hand asks to turn on Wi-Fi if needed, and shows the
outcome.

Only one statistics or highlights sync runs at a time. A trigger during a
sync gets exactly one more sync after it. The network part runs in a
background process, so reading isn't interrupted; it's stopped after 3
minutes, keeping what it finished (the next sync carries on).

Changes to highlights are recorded when a book is closed. Changes from
other devices are written into books right after a sync, including books
that aren't open (if they've been opened on that device before), and put
into a book when it's opened, whether or not automatic sync is on.

## On the server

```
<folder on server>/        /KOReader unless changed
  Files/                   settings sync (manifest.tsv, files/ as in KOReader's folder)
  Statistics/devices/      statistics and highlights, a folder per device
```

Earlier versions kept settings sync's files in `Settings/` (see
[SETTINGS.md](SETTINGS.md#from-the-earlier-layout)). Statistics sync kept its device folders one level deeper, in
`/KOReader/Statistics/v2/devices/`.

## Moving from SuperSync

OmniSync was called SuperSync (`supersync.koplugin`). It takes over
SuperSync's data on each device, so nothing has to be sent or received
again, and it uses the same server and folder.

1. Copy `omnisync.koplugin` into `plugins/` and restart KOReader. If
   SuperSync is still on, OmniSync turns it off and asks you to restart:
   the two can't both run while the data moves.
2. After the restart, OmniSync moves SuperSync's data and says so. Delete
   `supersync.koplugin` from `plugins/`.

What's moved, on the first start without SuperSync:

| From | To |
|---|---|
| `settings/supersync_settings.lua` | `settings/omnisync/settings.lua` |
| `settings/supersync_device.lua` | `settings/omnisync/device.lua` |
| `settings/supersync.sqlite3` | `settings/omnisync/state.sqlite3` |
| `koreader/supersync/` (settings sync's lists, state, conflicts, logs) | `settings/omnisync/sync.txt` and `settings-sync/` (see [SETTINGS.md](SETTINGS.md#from-the-earlier-layout)) |
| `/supersync_settings.lua` in `settings.txt` | `/settings/omnisync/settings.lua` in `sync.txt` |
| SuperSync's automatic updates setting | OmniSync's |
| gestures and profiles for SuperSync's syncs | OmniSync's |

SuperSync's updater doesn't find OmniSync, so each device needs this once
by hand. `cache/supersync/` only held temporary files; delete it.

## Where things are kept

In KOReader's `settings/omnisync/` folder:

- `settings.lua`: the settings that are the same on every device:
  server's name (no password: that stays in Cloud storage's
  `cloudstorage.lua`), folder, the automatic syncs, "Turn on Wi-Fi to sync",
  and `time_limit` (seconds before the network step of a statistics sync is
  stopped, default 180; not in the menu). **Fine to sync**: add
  `/settings/omnisync/settings.lua` to `sync.txt`. A synced change takes effect
  at the next start.
- `device.lua`: this device's ID and sync status. Devices sharing it
  would share an ID.
- `state.sqlite3`: what was sent and received, and the merged
  highlights of every book. Safe to delete, at the cost of sending
  everything once more.
- `sync.txt`: settings sync's list of what to sync (see
  [SETTINGS.md](SETTINGS.md)).
- `settings-sync/`: settings sync's state, pulled settings waiting for a
  restart, conflicts and logs.

Settings sync never syncs `device.lua`, `state.sqlite3` or
`settings-sync/`, even if `sync.txt` names them (a sync's log says it
skipped them), so `/settings/omnisync/**` there syncs only `settings.lua`
(and the list, which is always synced).

Also: `cache/omnisync/` (temporary files, and settings sync's checksums),
and the updater's setting (`omnisync_updates` in
`settings.reader.lua`, kept per device).

Logs: statistics and highlights messages start with `StatSync:`, the rest
with `OmniSync:`, in KOReader's `crash.log`. Passwords are never logged.

## Updates

"Check for updates" looks for a newer release of the plugin on GitHub.
"Automatic updates" sets what happens once a day when KOReader is already
online: off, notify (the default: asks first), or install. An update is
checked (checksum, complete plugin) before it replaces the installed one,
and takes effect after a restart. Don't also copy this plugin between
devices with settings sync: it never syncs this plugin's folder, as the
two would fight over it.

## Tests

```
scripts/test.sh                    # settings sync (and the other plugins)
scripts/test-omnisync.sh          # statistics and highlights: unit, integration and plugin tests
scripts/test-omnisync.sh unit     # unit tests only
scripts/test-omnisync.sh bench    # 5-year benchmark
```

The statistics tests need LuaJIT, libsqlite3, LuaFileSystem and (except the
unit tests) rclone, used as a local WebDAV server. They use KOReader's own
statistics plugin and lua-ljsqlite3 from KOReader's sources: set
`KOREADER_SRC` to a folder with `koreader/` and `koreader-base/` checkouts,
or the script clones them into `.cache/`.

See [DESIGN.md](DESIGN.md) for how statistics sync works and why, and
[ANNOTATIONS.md](ANNOTATIONS.md) for highlights and bookmarks.
