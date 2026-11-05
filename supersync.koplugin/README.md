# SuperSync (supersync.koplugin)

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

It replaces two plugins, Settings sync (`rclonesync.koplugin`) and
Statistics sync (`statsync.koplugin`), and takes over their data on each
device (see [Moving from Settings sync and Statistics sync](#moving-from-settings-sync-and-statistics-sync)).

## Install

1. Copy `supersync.koplugin` into KOReader's `plugins/` folder and restart
   KOReader. Statistics need the Reading statistics plugin enabled.
2. Add your server in Cloud storage (file browser → Cloud storage), if it
   isn't there already. Statistics and highlights need a WebDAV server;
   settings work with Dropbox too.
3. Tools → SuperSync → Server: choose it (with none chosen, the first
   Dropbox or WebDAV server in Cloud storage is used). The server is
   remembered by its name, so give it the same name on every device.
4. Tools → SuperSync → Folder on server: `/KOReader` unless you change it.
   It's relative to the server's address; the folder set for the server in
   Cloud storage isn't used. Use the same server and folder on every device.
5. For settings, put the lists of what to sync in `koreader/supersync/`
   (see [SETTINGS.md](SETTINGS.md)).

## Menu

Tools → SuperSync, in both the file browser and the reader:

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

Each of the three syncs is also a gesture (General → "SuperSync: sync
settings", "SuperSync: sync statistics", "SuperSync: sync highlights and
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

Changes to highlights are recorded when a book is closed, and changes from
other devices are put into a book when it's opened (or right away for the
book being read), whether or not automatic sync is on. Book status,
rating, review and custom metadata are also written into books that aren't
open, right after a sync.

## On the server

```
<folder on server>/        /KOReader unless changed
  Settings/                settings (manifest.tsv, lists/, settings/, plugins/, …)
  Statistics/devices/      statistics and highlights, a folder per device
```

Settings sync used the same `/KOReader/Settings` by default. Statistics
sync kept its device folders one level deeper, in
`/KOReader/Statistics/v2/devices/`.

## Moving from Settings sync and Statistics sync

SuperSync takes over what the two plugins kept on each device, so nothing
has to be sent or received again. What it can't do is move their folders on
the server, and it has one folder for both.

1. **On the server, first**: put the old folders' files in SuperSync's
   folder (`/KOReader` unless you choose another):
   - everything in Settings sync's folder (`manifest.tsv`, `lists/`,
     `settings/`, …) into `<folder>/Settings/`;
   - the `devices/` folder from Statistics sync's `v2/` folder into
     `<folder>/Statistics/`, so its device folders end up in
     `<folder>/Statistics/devices/`.

   If both plugins used their default folders on the same server, settings
   are in place already; for statistics, move
   `/KOReader/Statistics/v2/devices/` to `/KOReader/Statistics/devices/`
   (then delete the empty `v2/`).
2. **On each device**: install SuperSync (above) and restart KOReader. On
   the first start it takes over the old plugins' data, turns the old
   plugins off, and says so. Delete `rclonesync.koplugin` and
   `statsync.koplugin` from `plugins/`.
3. Choose the server and folder (Tools → SuperSync), then use each of the
   three syncs once to check. A statistics sync after the move sends and
   receives only what's new.
4. If `settings.txt` lists `/statsync_settings.lua`, change it to
   `/supersync_settings.lua`. Gestures assigned to the old plugins' syncs
   need assigning again.

What's taken over, on the first start:

| From | To |
|---|---|
| `koreader/rclonesync/` (lists, state, pulled settings waiting, conflicts, logs) | `koreader/supersync/` (moved) |
| `settings/statsync.sqlite3` (what was sent and received, highlights) | `settings/supersync.sqlite3` (copied) |
| `settings/statsync_device.lua` (device ID, status) | `settings/supersync_device.lua` |
| "Turn on Wi-Fi to sync" and `time_limit` from `settings/statsync_settings.lua` | `settings/supersync_settings.lua` |
| the old plugins' automatic updates setting | SuperSync's |

Not taken over: the servers and folders (SuperSync has one of each, set by
hand), and Statistics sync's "Sync automatically" and highlights on/off
(SuperSync's automatic syncs are on by default). Statistics sync's files
are left where they were; delete `statsync.sqlite3`, `statsync_device.lua`,
`statsync_settings.lua` (and `statsync.lua`, from older versions) from
`settings/`, and `cache/statsync/`, once everything works.

**If a device syncs before the files are in place:**

- Statistics and highlights stop before writing anything: a device that
  has sent files before, and doesn't find its own in the folder, says so
  (an automatic sync just records the error). Copy the files and sync
  again. If you meant a new folder, the message offers to send everything
  this device has there instead.
- Settings: a folder without `manifest.tsv` is synced as for the first time
  (this device's files are uploaded, nothing is deleted). Settings only
  sync when you ask, so copy the files first.

## Where things are kept

In KOReader's `settings/` folder:

- `supersync_settings.lua`: the settings that are the same on every device:
  server's name (no password: that stays in Cloud storage's
  `cloudstorage.lua`), folder, the automatic syncs, "Turn on Wi-Fi to sync",
  and `time_limit` (seconds before the network step of a statistics sync is
  stopped, default 180; not in the menu). **Fine to sync**: add
  `/supersync_settings.lua` to `settings.txt`. A synced change takes effect
  at the next start.
- `supersync_device.lua`: this device's ID and sync status. **Never sync
  it**: devices sharing it would share an ID.
- `supersync.sqlite3`: what was sent and received, and the merged
  highlights of every book. Never sync it either. Safe to delete, at the
  cost of sending everything once more.

So in `settings.txt` list `/supersync_settings.lua` exactly, not a pattern
such as `/supersync*` that would also match the other two.

Also: `koreader/supersync/` (settings sync's lists, state, pulled settings
waiting for a restart, conflicts and logs), `cache/supersync/` (temporary
files), and the updater's setting (`supersync_updates` in
`settings.reader.lua`, kept per device).

Logs: statistics and highlights messages start with `StatSync:`, the rest
with `SuperSync:`, in KOReader's `crash.log`. Passwords are never logged.

## Updates

"Check for updates" looks for a newer release of the plugin on GitHub.
"Automatic updates" sets what happens once a day when KOReader is already
online: off, notify (the default: asks first), or install. An update is
checked (checksum, complete plugin) before it replaces the installed one,
and takes effect after a restart. Don't also copy this plugin between
devices with settings sync (`plugins.txt`): the two would fight over its
folder.

## Tests

```
scripts/test.sh                    # settings sync (and the other plugins)
scripts/test-supersync.sh          # statistics and highlights: unit, integration and plugin tests
scripts/test-supersync.sh unit     # unit tests only
scripts/test-supersync.sh bench    # 5-year benchmark
```

The statistics tests need LuaJIT, libsqlite3, LuaFileSystem and (except the
unit tests) rclone, used as a local WebDAV server. They use KOReader's own
statistics plugin and lua-ljsqlite3 from KOReader's sources: set
`KOREADER_SRC` to a folder with `koreader/` and `koreader-base/` checkouts,
or the script clones them into `.cache/`.

See [DESIGN.md](DESIGN.md) for how statistics sync works and why, and
[ANNOTATIONS.md](ANNOTATIONS.md) for highlights and bookmarks.
