# Statistics sync (statsync.koplugin)

Syncs KOReader's reading statistics (the page-by-page reading times behind
Reading statistics) between any number of devices, through a WebDAV server.

Unlike Reading statistics' own "Cloud sync", which uploads and downloads the
whole `statistics.sqlite3`, each device here writes only its own files, which
are never changed once written, and merges the other devices' files into its
database. A sync sends only what's new.

## Install

Copy `statsync.koplugin` into KOReader's `plugins/` folder and restart
KOReader. It needs a recent KOReader (developed against the November 2026
sources) with the Reading statistics plugin enabled.

## Set up

1. Tools → Statistics sync → Server.
   - If Reading statistics → Settings → Cloud sync already has a WebDAV
     server, it's used (shown as "from Reading statistics").
   - Or "Choose a WebDAV server and folder…" opens Cloud storage, where you
     pick (or add) a WebDAV server and the folder to sync in.
   Only WebDAV is supported for now.
2. Tools → Statistics sync → Sync now, to check it works.
3. Turn on "Sync automatically".

Use the same server and folder on every device. Each device gets a random ID
the first time it syncs.

**Don't also use Reading statistics' own "Sync now" on the same devices.**
It keeps working (this plugin doesn't change it), but the two syncs disagree
about deletions: the built-in one propagates them, this one never does, so
mixing them gives confusing results.

## When it syncs

Automatically (when turned on): when a book is closed, on wake-up, when the
network connects, and 20 seconds after KOReader starts. Without a network
connection the sync is skipped; nothing is queued, the next sync catches up.
"Turn on Wi-Fi to sync" (off by default) makes automatic syncs turn Wi-Fi on
the way KOReader's network settings say.

"Sync now" (also a gesture/Dispatcher action, "Statistics sync: sync now")
syncs at once, asking to turn on Wi-Fi if needed, and shows the outcome.

Only one sync runs at a time. A trigger during a sync gets exactly one more
sync after it. The network part runs in a background process, so reading
isn't interrupted; it's stopped after 3 minutes, keeping what it finished
(the next sync carries on).

## Menu

Tools → Statistics sync:

- **Sync automatically**: on/off (off until you turn it on).
- **Sync now**.
- **Server**: which server, and choosing another.
- **Turn on Wi-Fi to sync**: for automatic syncs.
- **Status**: last success, last attempt and error, devices seen, entries
  sent and received last time, totals, this device's ID.
- **Rebuild from cloud**: imports every device's files again (see below).
- **Reset device ID**: see below.
- **Check for updates** and **Automatic updates**: see Updates.

## What's on the server

```
<chosen folder>/statsync/
  devices/<device-id>/
    meta.json                  device ID, model, format version, when written
    seg-0000000001.jsonl       segment files, numbered 1, 2, 3, …
    seg-0000000002.jsonl
    …
```

A segment is a text file, one JSON object per line: a header (format and
version, device, time), one line per book (`md5`, title, authors, series,
language, pages, last opened), one line per page reading, and a trailer with
the counts:

```
{"created":1793680808,"device":"9f2c41d07ab3e655","format":"statsync","minor":0,"t":"h","v":1}
{"t":"b","md5":"7c1d…","title":"Der Zauberberg","authors":"Thomas Mann","series":"N/A","language":"de","pages":854,"last_open":1793680806}
{"t":"e","md5":"7c1d…","page":12,"start":1793679000,"dur":41,"tp":854}
{"t":"end","books":1,"events":1}
```

A page reading ("event") is one row of KOReader's `page_stat_data`:
book (by KOReader's partial MD5 of the file), page, start time, duration, and
the book's page count at the time. Segments hold at most 20,000 events
(about 2 MB). They are not compressed (see DESIGN.md).

## Guarantees

- **Nothing is lost by syncing.** Merging is a union: a device can only add
  events, or lengthen one, never remove any. When two devices have the same
  event (same book, page and start time), the longer duration wins.
- **Same data everywhere.** Merging gives the same result whatever order the
  files arrive in, and importing a file twice changes nothing. Once every
  device has synced (twice, so each sees the others' latest), their
  `page_stat_data` is the same.
- **Files are never overwritten.** A segment is uploaded under a temporary
  name and then moved to its final name, refusing to replace an existing
  file. An interrupted upload leaves no partial segment.
- **Only new data moves.** An ordinary sync lists `devices/` and asks each
  device for its next segment by name; with nothing new that's one small
  request per device. Once a day (and on "Sync now") every device folder is
  listed in full, to find anything out of sequence.
- **Failures fix themselves.** Nothing is marked as sent until the server
  shows the file with the right size, nor imported until it's in the
  database. A failed or skipped sync is caught up by the next one.
- **A bad file doesn't block the rest.** A segment that can't be read
  (truncated, corrupt, or from a newer incompatible version) is skipped and
  logged, the others are imported. It's not downloaded again unless it
  changes.

Totals (time and pages read per book) are recomputed on each device with the
same query Reading statistics uses. Pages read can differ between devices
for the same data: KOReader scales page numbers to each device's current
page count for the book.

## Book identity

Books are matched by KOReader's partial MD5 of the file, not by title. If a
device has the book under another title or author (edited metadata), the
other devices' readings are merged into its existing entry, which keeps its
own title and authors: KOReader finds a book's statistics by title, authors
and MD5, so changing them would split them. Series, language and "last
opened" are taken from whichever device opened the book last. A book only
known from other devices takes its details from the device that opened it
last, until it's opened on this device. Books without an MD5 (from very old
statistics) aren't synced.

## Deletions are not synced

This version never deletes anything anywhere:

- Statistics you delete on one device (Reading statistics → Reset
  statistics) are **not** deleted on the others.
- They also stay deleted on this device until you use "Rebuild from cloud"
  or set up the device afresh: then they **come back** from the other
  devices (and from this device's own earlier files).

If you want statistics gone everywhere, delete them on every device, and
remove the matching files from the server by hand, or start a new sync folder.

## Recovering

- **A device restored from a backup** (or a copy of another device's KOReader
  folder): use "Reset device ID" on it, so two devices don't share an ID.
  Even without, nothing is lost: segments are never overwritten, and a
  device that finds segments under its ID it doesn't know imports them.
- **Statistics missing on a device**: "Rebuild from cloud" re-imports every
  device's files. It only adds; it never deletes.
- **Starting over**: choose another server folder on every device. Each
  device then uploads its whole history again on its next syncs.
- **Logs**: messages start with `StatSync:` in KOReader's `crash.log`.
  Passwords are never logged.

## Where things are kept

In KOReader's `settings/` folder:

- `statsync.lua`: the settings that are the same on every device:
  automatic sync on/off, "Turn on Wi-Fi to sync", the chosen server
  (including its password, in plain text), and `time_limit` (seconds before
  the network step is stopped, default 180; not in the menu). **This one is
  meant to be synced between devices**, e.g. with Settings sync: add
  `/statsync.lua` to its `settings.txt`. A synced change takes effect at the
  next start.
- `statsync_device.lua`: this device's ID and sync status. **Never sync
  it**: devices sharing it would share an ID.
- `statsync.sqlite3`: what was sent and received. Never sync it either. Safe
  to delete, at the cost of sending everything once more.

So in `settings.txt` list `/statsync.lua` exactly, not a pattern such as
`/statsync*` that would also match the other two.

Also: `cache/statsync/` (temporary files), and the updater's setting
(`statsync_updates` in `settings.reader.lua`, kept per device along with
when it last checked). Versions before these files kept everything under
`statsync` in `settings.reader.lua`; it's moved on the first start.

## Updates

"Check for updates" looks for a newer release of the plugin on GitHub.
"Automatic updates" sets what happens once a day when KOReader is already
online: off, notify (the default: asks first), or install. An update is
checked (checksum, complete plugin) before it replaces the installed one, and
takes effect after a restart. Don't also copy this plugin between devices
with Settings sync (`plugins.txt`): the two would fight over its folder.

## Tests

```
scripts/test-statsync.sh          # unit, integration and plugin tests
scripts/test-statsync.sh unit     # unit tests only
scripts/test-statsync.sh bench    # 5-year benchmark
```

They need LuaJIT, libsqlite3, LuaFileSystem and (except the unit tests)
rclone, used as a local WebDAV server. They use KOReader's own statistics
plugin and lua-ljsqlite3 from KOReader's sources: set `KOREADER_SRC` to a
folder with `koreader/` and `koreader-base/` checkouts, or the script clones
them into `.cache/`.

See DESIGN.md for how it works and why.
