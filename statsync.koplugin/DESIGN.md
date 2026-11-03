# statsync design notes

Decisions, alternatives rejected, where the build differs from the task
description, and what couldn't be verified. Written against KOReader
`b166eb5` (2 Nov 2026) and koreader-base `12807ca` (1 Nov 2026).

## Files

| File | Runs in | Does |
|---|---|---|
| `main.lua` | main | Menu, event triggers, user messages |
| `statsync/plugin.lua` | main | Wires the engine to KOReader: settings, server, subprocess, network state, the statistics plugin |
| `statsync/engine.lua` | main | The sync cycle; one at a time plus one re-run |
| `statsync/store.lua` | main | Export diff, merge/import, totals, local state DB |
| `statsync/netjob.lua` | subprocess | Upload, discovery, downloads |
| `statsync/webdav.lua` | subprocess | WebDAV transport (`list`, `stat`, `get`, `put`, `put_new`, `mkdir`, `delete`) |
| `statsync/codec.lua` | both | JSON, segment format, validation |

## Where the KOReader source differs from the task description

1. **`frontend/ffi/util.lua` doesn't exist.** `runInSubProcess`,
   `isSubProcessDone` and `terminateSubProcess` are in koreader-base's
   `ffi/util.lua` (`require("ffi/util")`). Used as found there; the
   pattern (schedule a poll, reap with `isSubProcessDone`, `preventStandby`
   while it runs) follows coverbrowser's `bookinfomanager.lua`.
2. **The WebDAV provider can't be reused.** `WebDavApi.listFolder` drops
   files KOReader can't open (anything not a document, so every `.jsonl`)
   unless the user turned on "show unsupported files", and returns no ETags.
   `uploadFile` always names the remote file after the local file and can't
   do a conditional create. So statsync has its own small client
   (`webdav.lua`), using the same `socket.http` and the same server entries
   (`{name, type, address, username, password, url}`) as Cloud storage.
3. **`Cloud:sync` runs on the UI thread** (download, merge, upload, all
   synchronous). Not used.
4. **LuaSocket unescapes passwords**: with `user`/`password` fields,
   `http.lua` sends `url.unescape(password)`, so a password containing `%`
   is mangled (this affects the WebDAV provider too). statsync builds the
   `Authorization` header itself; the tests use a password with `%`, `:`
   and `ö`.
5. **zlib can't do gzip.** koreader-base's `ffi/zlib.lua` wraps only
   `compress2`/`uncompress` (zlib format, and decompression needs the
   output size up front); no `deflateInit2`/`inflateInit2`. So segments are
   **plain `.jsonl`**, as the task said to do in that case. See
   "Recommendations" for zstd.
6. **`insertDB` doesn't save the page on screen.** Its duration isn't known
   until the page is turned, so the flush before export (calling the
   statistics plugin's `insertDB()`, as its own `onSuspend` does) writes
   everything except the current page; that's picked up by a later sync.
7. **`insertDB` opens the database without a busy timeout.** It would throw
   if another process held a write lock. statsync only writes from the main
   process, synchronously, in transactions that begin and end within one
   call, so the two can't overlap. The subprocess never opens a database.
8. **`page_stat` rescales by `book.pages`**, the book's page count on this
   device. So the totals (`total_read_pages` especially) depend on local
   layout, and can differ between devices with identical `page_stat_data`.
   The tests check each device's stored totals against KOReader's own
   query on that device, which is what "totals match what KOReader
   computes" can mean.
9. **The built-in `onSync` merge keeps the local `total_pages`** when it
   takes the longer duration (`DO UPDATE SET duration = MAX(...)`).
   statsync takes the `total_pages` of the row with the longer duration, as
   specified. Mixing both syncs could flip `total_pages` back and forth;
   another reason not to run both.

## Decisions

### Merge

- Event key `(md5, page, start_time)`; longer duration wins, with its
  `total_pages`. **Ties** (same duration, different `total_pages`, which the
  task left open): the larger `total_pages` wins, so the result doesn't
  depend on order.
- Implemented row by row against `page_stat_data` (look up by
  `(id_book, page, start_time)` for each local book row with that md5; insert
  into the target row, or update in place). Tested: idempotence, every import
  order of three overlapping devices, ties, unicode, all against databases
  created and written by KOReader's own `createDB`/`insertDB`.

### Book identity (the unique key is `(title, authors, md5)`)

- The incoming md5 maps to the local row with the **latest `last_open`**
  (several rows can share an md5 after metadata edits). An event key that
  already exists under another row of the same md5 is updated there, never
  duplicated.
- **Deviation:** the task said metadata from the copy with the higher
  `last_open` wins. For books KOReader uses on this device, statsync keeps
  the local **title and authors** (KOReader's `getIdBookDB` finds the row by
  them: renaming it would make KOReader start a new, empty row next time
  the book is opened) and the local **`pages`** (see 8 above). Series,
  language and `last_open` follow the newer copy.
- Books **only known from other devices** (rows statsync created, recorded in
  `foreign_books`) follow the newest copy completely, with a tie-break on the
  metadata itself, so they converge whatever the order. Once KOReader opens
  the book here (its `last_open` changes), it's local. Limitation: that is
  detected by `last_open` changing, so a local open in the same second as the
  remote `last_open` would go unnoticed (harmless: the title would follow the
  remote one until the next change).
- Books without an md5 (possible for statistics migrated from very old
  versions) are not exported.

### Export diff

- `exported(md5, page, start_time, duration)` in `statsync.sqlite3`; an
  event is unexported if missing there or longer locally. One query with a
  `LEFT JOIN` on the attached state database. Neither `start_time` nor
  `rowid` decides what's exported.
- **Fingerprint shortcut (addition):** the diff scans everything (0.34 s on
  a desktop for 300k events, several times that on an e-reader), on every
  sync. Before it, statsync reads `count(*), max(rowid), total(duration)` of
  `page_stat_data` (0.03 s). If it equals the value recorded when
  everything was last known to be exported, the diff is skipped. The value
  is taken before the diff, so rows written during an upload change it; an
  import carries it forward inside its write transaction (nothing else can
  write then). `rowid` is only part of a change detector here: VACUUM
  renumbering just causes a full diff. A full diff also runs on every full
  listing (daily, and on "Sync now"). A false "unchanged" needs the same row
  count, highest rowid and total duration with different data, which
  KOReader's writes (inserts, deletions, durations that only grow) don't
  produce.
- Exports are capped at **20,000 events per segment** (~2 MB). A large
  first sync is several segments over several cycles; each cycle that made
  progress starts the next by itself.

### Segment format

- JSON Lines. Line 1 is a header with `format`, major `v` and `minor`; a
  reader rejects an unknown `v`. Unknown record types within a known `v`
  are skipped, which leaves room for `del` (below). **Addition:** a trailer
  `{"t":"end","books":n,"events":m}`; without it, or with wrong counts, the
  file is rejected as truncated. Book records come before their events.
- Strict validation (integers, non-negative, string fields, one header,
  nothing after the trailer). One bad line rejects the whole file; nothing
  of it is written (one transaction).
- **Own JSON codec** instead of KOReader's `json` (luajson, which needs
  LPeg): the on-disk format is pinned down (integer output, fixed key order,
  escaping of control characters including NUL from old MuPDF titles,
  surrogate pairs), event lines have a fast path, and the tests run without
  KOReader.

### Remote side

- **Upload:** PUT to `devices/<id>/.upload-<random>.part`, then `MOVE` with
  `Overwrite: F` (the server answers 412 if the name exists), then a
  `PROPFIND` (Depth 0) of the final name to check the size. Only then are the
  events marked exported. Leftover `.part` files of this device are deleted
  on the next full listing.
- **Sequence numbers are contiguous**: a device writes the first number not
  yet used. If that name is taken (restored from a backup, or an ID shared
  by two devices), it lists its folder and takes the first free number.
- **Discovery (deviation):** the task said to list `devices/` and every
  device folder with PROPFIND each time. Measured, that grows with history:
  ~12 KB per sync after a few months, megabytes after years. Now an
  ordinary sync lists `devices/` and, per device, GETs the next segment
  numbers after the ones already imported until one is missing (404); with
  nothing new that's one small request per device. A full listing of every
  folder runs on the first sync, on "Sync now" (and so on "Rebuild from
  cloud"), and once every 24 hours, and finds anything out of sequence
  (gaps, stray files). Downloads are checked against the listed size when
  known; the trailer catches truncation either way.
- A device imports **its own folder's** segments it doesn't know, which is
  how a device restored from an old backup gets its later data back.
  Segments it uploaded itself are recorded as seen when uploaded.
- **Bad segments** are recorded (`bad_segments`, with size, ETag and format
  version) and not downloaded again unless they change or the plugin's
  format version changes.

### Process model

- **Main process:** flush, export (writes `cache/statsync/pending.jsonl`),
  then fork. The child gets everything it needs (paths, the seen list) in
  its copied memory and writes its progress to `cache/statsync/result.json`
  (written to a temp name and renamed, after every step), so if it's killed
  at the **time limit (180 s)**, finished downloads and a verified upload
  still count. The main process polls every second with
  `UIManager:scheduleIn`.
- **Import:** one segment per UI tick, each in its own transaction, statistics
  database first, then the state database (seen, exported). **Deviation:**
  the task said one transaction for the whole import, but also short
  transactions; a first sync can be 300k events, so per segment. And the
  two databases can't share one atomic transaction: `statistics.sqlite3` is
  in WAL mode, where SQLite only guarantees multi-database commits per file.
  Committing statistics first means a crash in between at worst repeats an
  import (harmless), never marks unimported data as seen.
- **Single flight:** module-level engine (plugins are instantiated per
  FileManager/ReaderUI, `package.loaded` survives). Requests during a sync
  set one re-run flag.
- **Download budget:** 32 MB per cycle; the next cycle continues.
- **Offline:** `NetworkMgr:isConnected()` (cheap; `isOnline()` does a DNS
  lookup on the UI thread). Automatic syncs skip when offline unless
  "Turn on Wi-Fi to sync" is on, which uses `NetworkMgr:runWhenConnected`.
  **Assumption:** "Sync now" always uses `runWhenConnected`, i.e. follows
  KOReader's own "action when Wi-Fi is off" setting, like other network
  actions the user starts.
- **Automatic sync is off by default** (assumption: no network activity
  before the user has chosen to).
- **The server comes from Cloud storage, by name** (as in Settings sync):
  `statsync_settings.lua` keeps `{name, type}` and a folder (default
  `/KOReader/Statistics`, relative to the server's address), and the address
  and credentials are read from `cloudstorage.lua` when syncing. Nothing is
  shared with Reading statistics' own Cloud sync setting. With no server
  chosen, the first WebDAV server is used; a chosen one that's gone is an
  error, not a fallback to another (that could be a different place).
- **A changed server or folder resets the sync record.** The state database
  remembers the location (address without credentials, and folder). When it
  differs, `exported`, `seen_segments` and `bad_segments` are cleared, so
  the device publishes everything it has to the new place and imports
  everything there. Statistics themselves are untouched.
- The subprocess keeps the garbage collector running (stopping it would let
  a big download pile up garbage on a 512 MB e-reader). statsync closes all
  its database connections before forking, so the child can't finalize any
  of them; KOReader's own subprocesses don't do anything special here either.

## Measurements

`scripts/test-statsync.sh bench`, desktop (x86-64), local rclone WebDAV
server, three devices with ~100k events each (5 years, 40 books):

| Sync | Data up | Data down | Requests | Main-process CPU |
|---|---|---|---|---|
| First sync, publishing 100k events (6 cycles) | 9.5 MB | 7 KB | 34 | export 0.8 s |
| New device importing 300k events (1 cycle) | 1 KB | 28.4 MB | 25 | import 4.9 s |
| Incremental, one 30-page session, sender | 3.4 KB | 2.2 KB | 8 | export 0.37 s |
| Incremental, receiver | 0.1 KB | 5.0 KB | 6 | 0.09 s |
| Incremental, nothing new | 0.1 KB | 1.9 KB | 5 | 0.03 s |

~97 bytes per event uncompressed. An e-reader's CPU and flash are several
times slower: expect each 20,000-event segment import to block the screen
for a couple of seconds during a first sync. Not measured on a device.

## Not verified / not tested

- **No real device.** Nothing ran on a Kindle, Kobo or Android. In
  particular: `runInSubProcess` on Android,
  `NetworkMgr:isConnected()` on each platform, `/dev/urandom` access (falls
  back to `math.random`), menu placement (`sorting_hint = "tools"`), and the
  `Resume`/`NetworkConnected`/`CloseDocument` events in practice (their
  names are checked against the source).
- **Only one WebDAV server** (rclone). `MOVE` with `Overwrite: F` is RFC 4918
  behaviour, but servers vary (Nextcloud, Apache mod_dav, nginx dav,
  Synology). A server that ignores `Overwrite: F` could replace a segment
  in the (rare) case of a name clash. HTTPS (via LuaSec) wasn't tested.
- **KOReader's UI modules are stubbed** in `tests/test_statsync_plugin.lua`;
  the statistics plugin, ljsqlite3, subprocesses and server are real. The
  HTTP client in the tests is a small FFI one with LuaSocket's
  `http.request` interface (LuaSocket couldn't be built here), so
  LuaSocket's own behaviour (redirects, chunked encoding, timeouts) isn't
  covered.
- The `foreign_books` same-second limitation above.

## Deletions (designed, not implemented)

Record: `{"t":"del","md5":"…","before":<start_time>}`: every event of that
book with `start_time < before` is deleted, on every device, and stays
deleted whatever order files arrive in.

- Readers keep a `deletions(md5, before)` table (max `before` per md5). On
  importing a `del`, delete matching local rows and record it; on importing
  events, drop those covered by a recorded deletion. "Events minus all
  deletions" is still idempotent and order-independent.
- Writers: KOReader's "Reset statistics" deletes rows; statsync could detect
  that as keys in `exported` missing from `page_stat_data`, and emit `del`
  for the book with `before` = the newest deleted `start_time` + 1. Partial
  resets (a date range of a book) need a range form:
  `{"t":"del","md5":…,"from":…,"before":…}`.
- Format: a minor version. Older readers skip `del` lines, so they keep the
  events but don't send them again (they're already in their `exported`).
- Risks: device clocks. `start_time` is each device's wall clock; a device
  with a clock behind could record new events below another's `before`, and
  they'd be deleted. Also, deletion makes any mistake permanent everywhere,
  which this version can't do; I'd want an undo (e.g. deletions only apply
  to events from segments older than the `del`) before shipping it.

## Compaction (phase 3, designed, not implemented)

A designated device (setting) writes `snapshots/snap-<n>.jsonl`: the merged
events of all devices, with a header listing, per device, the last segment
number it includes. A new device imports the newest snapshot, marks the
covered segments as seen without downloading them, then continues normally.
Old segments are never rewritten. Merging is idempotent, so overlap between a
snapshot and segments is harmless.

Not implemented because it saves little: events from different devices
rarely share keys, so a snapshot is about as big as all segments together
(28 MB for the benchmark's new device); it only saves requests (25 → 1).
Compression would save far more (below).

## Recommendations and things I think are a bad idea

- **Compress with zstd (your call; changes the remote format).** gzip shrinks
  a 2 MB segment to 170 KB (11×). zlib can't do it (above), but koreader-base
  ships `ffi/zstd.lua` (`zstd_compress`/`zstd_uncompress`, frames that carry
  their size), used on every platform by `persist.lua` and coverbrowser. A
  `seg-N.jsonl.zst` (format version 2) would make first syncs about ten
  times smaller.
- **Running both syncs on the same devices** is a bad idea: the built-in one
  deletes, statsync doesn't, and they pick different `total_pages` (see 9).
- **"Higher `last_open` wins" for title/authors** would break KOReader's
  lookup of the book on the device that loses (see Book identity).
- **Comparing totals across devices** isn't meaningful for pages read
  (see 8); comparing `page_stat_data` is.
- **Device IDs live in `settings/statsync_device.lua`**, apart from the
  shared settings (`settings/statsync_settings.lua`) so the latter can be
  synced between devices. That file is new in 0.2.2 (with the server kept
  by name): earlier versions' `statsync.lua` is copied once and left alone,
  so devices on different versions syncing their settings don't read a
  format they don't know. Copying a whole KOReader folder to a new device still
  copies the ID. Two devices sharing an ID is safe here (no overwrites,
  unknown own segments get imported), but "Reset device ID" is still worth
  doing.
