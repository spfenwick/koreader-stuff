# Statistics sync (statsync.koplugin)

Syncs KOReader's reading statistics (the page-by-page reading times behind
Reading statistics) between any number of devices, through a WebDAV server.
Optionally it syncs highlights, notes and page bookmarks too (see
[Highlights and bookmarks](#highlights-and-bookmarks)).

Unlike Reading statistics' own "Cloud sync", which uploads and downloads the
whole `statistics.sqlite3`, each device here writes only its own files, which
are never changed once written, and merges the other devices' files into its
database. A sync sends only what's new.

## Install

Copy `statsync.koplugin` into KOReader's `plugins/` folder and restart
KOReader. It needs a recent KOReader (developed against the November 2026
sources) with the Reading statistics plugin enabled.

## Set up

Like Settings sync, it uses a server set up in Cloud storage:

1. Add a WebDAV server in Cloud storage (file browser → Cloud storage), if
   there isn't one. Its address, user name and password are used from there.
   Only WebDAV is supported.
2. Tools → Statistics sync → Server: choose it. With none chosen, the first
   WebDAV server in Cloud storage is used.
3. Tools → Statistics sync → Folder on server: where on the server to keep
   the statistics, `/KOReader/Statistics` unless you change it. It's
   relative to the server's address; the folder set for the server in Cloud
   storage isn't used.
4. Sync now, to check it works, then turn on "Sync automatically".

Use the same server and folder on every device. The server is remembered by
its name in Cloud storage, so give it the same name on every device (or sync
`cloudstorage.lua` too). Each device gets a random ID the first time it
syncs.

This is separate from Reading statistics' own Cloud sync and its server
setting: choosing a server here doesn't change that one, nor the other way
round.

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
- **Server**: the WebDAV server from Cloud storage to use.
- **Folder on server**: the folder to sync in. Changing it (or the server)
  sends all of this device's statistics to the new place at the next sync.
- **Sync highlights and bookmarks**: on/off (off until you turn it on); see
  below.
- **Removed highlights waiting for you**: highlights and bookmarks removed
  in bulk on this device, waiting for you to say whether to remove them
  everywhere (see below).
- **Turn on Wi-Fi to sync**: for automatic syncs.
- **Status**: server and folder, last success, last attempt and error, devices seen, entries
  sent and received last time, totals, this device's ID, and with
  highlights and bookmarks on, their counts, changes waiting to be sent,
  books waiting to be updated, and removals waiting for you.
- **Rebuild from cloud**: imports every device's files again (see below).
- **Reset device ID**: see below.
- **Check for updates** and **Automatic updates**: see Updates.

## What's on the server

```
<folder on server>/                 /KOReader/Statistics unless changed
  v2/devices/<device-id>/
    meta.json                     device ID, model, format version, when written
    seg-0000000001.jsonl.zst      segment files, numbered 1, 2, 3, …
    seg-0000000002.jsonl.zst
    …
    ann-0000000001.jsonl.zst      highlights and bookmarks (when synced), numbered apart
    …
```

A segment is a text file compressed with zstd (`zstd -d` unpacks it), one
JSON object per line: a header (format and
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
(about 2 MB, about 170 KB compressed).

**0.2.2 and earlier** wrote uncompressed `seg-N.jsonl` files straight into
the folder (`<folder on server>/devices/…`). 0.2.3 doesn't read or write
those: when a device is updated, its next syncs send everything it has
(its own statistics and what it got from the others) to `v2/`. Devices
still on 0.2.2 carry on in the old place, and the two groups don't see each
other's new reading until every device is updated; nothing is lost, it
arrives once they are. Delete the old `devices/` folder once all devices
have synced with 0.2.3.

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

## Highlights and bookmarks

With **Sync highlights and bookmarks** on, KOReader's annotations (page
bookmarks, highlights, and notes on highlights) sync too, including edits
(note text, colour, style, adjusted ends) and removals.

- **Same file, same annotations.** A book's annotations go to the devices
  that have the same file (KOReader's partial MD5), because their positions
  only make sense in that file. Another edition, or a copy from elsewhere,
  doesn't share them. Reflowable books (EPUB and the like) and PDF/DjVu keep
  separate lists, as in KOReader: opening a book with the other engine
  doesn't touch the first list.
- **When they arrive.** For the book you're reading, right after a sync
  (once any menu or dialog is closed). Other books get theirs when they're
  next opened; until then the file browser's highlight counts and exports
  don't include them. Books first opened with KOReader's rendering from
  before 2020 are left out.
- **Turning it on** reads the highlights of every book in the reading
  history, so they're sent at the next sync, not only those of books you
  open later. That also happens on a device where it's turned on through
  synced settings, at the next start.
- **Newest change wins.** If the same highlight is changed on two devices,
  the later change wins, by the devices' clocks. A removal counts as a
  change: it wins over an earlier edit, and loses to a later one.
- **Removing many at once asks first.** If more than 5 and more than half of
  a book's highlights and bookmarks disappear at once, or all of them (for
  example the book's settings were reset or its `.sdr` folder deleted),
  they're not removed elsewhere straight away. You're asked:
  - **Restore them here**: they're put back on this device;
  - **Remove everywhere**: they're removed on the other devices too;
  - **Ask later**: nothing happens; you're asked again after the next sync
    or when the book is next opened or closed (also from the menu).
- **Notes are sent as plain text** to your server, as statistics are.

While this is on:

- **Turn off KOReader's "Export annotations on book closing"** (in the
  reader's Bookmarks settings): the import that goes with it deletes
  highlights that aren't in the exported file.
- **Don't sync books' settings folders** (`.sdr` folders, `docsettings/`,
  `hash/`) with Settings sync or any other file sync: the two would undo
  each other's changes.
- **"Write highlights into PDF"** puts a copy of each highlight into the PDF
  file itself. A device with that copy of the file would show it twice
  (once from the file, once synced). Leave it off for synced PDFs.

## Recovering

- **A device restored from a backup** (or a copy of another device's KOReader
  folder): use "Reset device ID" on it, so two devices don't share an ID.
  Even without, nothing is lost: segments are never overwritten, and a
  device that finds segments under its ID it doesn't know imports them.
- **Statistics missing on a device**: "Rebuild from cloud" re-imports every
  device's files. It only adds; it never deletes.
- **Starting over**: choose another folder on every device. Each device
  then uploads its whole history (including what it got from the others)
  there on its next syncs.
- **Logs**: messages start with `StatSync:` in KOReader's `crash.log`.
  Passwords are never logged.

## Where things are kept

In KOReader's `settings/` folder:

- `statsync_settings.lua`: the settings that are the same on every device:
  automatic sync on/off, highlights and bookmarks on/off, "Turn on Wi-Fi to sync", the chosen server's name
  (no password: that stays in Cloud storage's `cloudstorage.lua`), the
  folder, and `time_limit` (seconds before the network step is stopped,
  default 180; not in the menu). **This one is meant to be synced between
  devices**, e.g. with Settings sync: add `/statsync_settings.lua` to its
  `settings.txt`. A synced change takes effect at the next start.
- `statsync_device.lua`: this device's ID and sync status. **Never sync
  it**: devices sharing it would share an ID.
- `statsync.sqlite3`: what was sent and received, and with highlights and
  bookmarks on, the merged highlights of every book. Never sync it either.
  Safe to delete, at the cost of sending everything once more (turn
  highlights and bookmarks off and on again to read the reading history
  afresh).

So in `settings.txt` list `/statsync_settings.lua` exactly, not a pattern
such as `/statsync*` that would also match the other two.

Also: `cache/statsync/` (temporary files), and the updater's setting
(`statsync_updates` in `settings.reader.lua`, kept per device along with
when it last checked).

Earlier versions kept the shared settings in `statsync.lua`, with a copy of
the whole server entry (password included), and before that everything
under `statsync` in `settings.reader.lua`. On the first start they're
copied to the files above, keeping only the server's name and the folder
they synced to (`<server's Cloud storage folder>/statsync`). The old ones
are left as they were, so a device still on an older version keeps
working; delete `statsync.lua` once every device is updated (and take it out
of `settings.txt` if it was there).

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

See DESIGN.md for how it works and why, and ANNOTATIONS.md for highlights
and bookmarks.
