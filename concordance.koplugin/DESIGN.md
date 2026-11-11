# Concordance design notes: statistics and annotations

Decisions, alternatives rejected, where the build differs from the task
description, and what couldn't be verified. Written against KOReader
`b166eb5` (2 Nov 2026) and koreader-base `12807ca` (1 Nov 2026).

## Files

| File | Runs in | Does |
|---|---|---|
| `main.lua` | main | Menu, event triggers, user messages |
| `concordance/plugin.lua` | main | Wires the engine to KOReader: settings, server, subprocess, network state, the statistics plugin |
| `concordance/engine.lua` | main | The sync cycle; one at a time plus one re-run |
| `concordance/store.lua` | main | Export diff, merge/import, totals, local state DB |
| `concordance/netjob.lua` | subprocess | Upload, discovery (with folder dates), downloads, packing |
| `concordance/pack.lua` | subprocess | Packs: merging a run of segments into one |
| `concordance/webdav.lua` | subprocess | WebDAV transport (`list`, `stat`, `get`, `put`, `put_new`, `mkdir`, `delete`) |
| `concordance/codec.lua` | both | JSON, segment format, validation |
| `concordance/annformat.lua` | both | Annotation records, keys, annotation segment format |
| `concordance/annstore.lua` | main | Annotations' merged state, change detection, held deletions, export/import |
| `concordance/annsync.lua` | main | Annotations in the reader: on open/close, live apply, history scan, the question |
| `concordance/bookformat.lua` | both | Book data properties, book data segment format |
| `concordance/bookstore.lua` | main | Book data's merged state, change detection, export/import |
| `concordance/booksync.lua` | main | Book data in KOReader: open book, sidecar refresh, writing closed books |
| `concordance/idformat.lua` | both | Book identity records, identity segment format |
| `concordance/idscan.lua` | subprocess | Reading an EPUB's UUIDs and body signature |
| `concordance/idstore.lua` | main | Book identity facts, files read, export/import, groups |
| `concordance/progresshook.lua` | main | KOReader's progress sync: positions from a book's other versions |

Highlights and bookmarks are designed in ANNOTATIONS.md, book data (status,
rating, review, custom metadata, handmade TOC) in BOOKDATA.md, book
identity in IDENTITY.md.

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
   do a conditional create. So Concordance has its own small client
   (`webdav.lua`), using the same `socket.http` and the same server entries
   (`{name, type, address, username, password, url}`) as Cloud storage.
3. **`Cloud:sync` runs on the UI thread** (download, merge, upload, all
   synchronous). Not used.
4. **LuaSocket unescapes passwords**: with `user`/`password` fields,
   `http.lua` sends `url.unescape(password)`, so a password containing `%`
   is mangled (this affects the WebDAV provider too). Concordance builds the
   `Authorization` header itself; the tests use a password with `%`, `:`
   and `ö`.
5. **zlib can't do gzip.** koreader-base's `ffi/zlib.lua` wraps only
   `compress2`/`uncompress` (zlib format, and decompression needs the
   output size up front); no `deflateInit2`/`inflateInit2`. Until 0.2.2
   segments were plain `.jsonl`. Since 0.2.3 they're **zstd**
   (`seg-N.jsonl.zst`), with the libzstd koreader-base ships (used by
   `persist.lua` and coverbrowser), through Concordance's own small wrapper
   (`zstd.lua`): `ffi/zstd.lua` raises on bad input and allocates whatever
   size a frame claims, and a downloaded file can be anything. Unpacking
   is refused above 32 MB. Compression happens in the main process after
   export, decompression just before each import (a few ms per segment).
   The segment format inside is unchanged (`v` 1). (Statistics sync put the
   compressed files in a `v2/` subfolder, so its 0.2.2 devices never saw
   them; Concordance, which those devices can't share a folder with anyway,
   puts them straight in `<folder>/Statistics/`, since OmniSync 0.5.0 `<folder>/Reading/`.)
6. **`insertDB` doesn't save the page on screen.** Its duration isn't known
   until the page is turned, so the flush before export (calling the
   statistics plugin's `insertDB()`, as its own `onSuspend` does) writes
   everything except the current page; that's picked up by a later sync.
7. **`insertDB` opens the database without a busy timeout.** It would throw
   if another process held a write lock. Concordance only writes from the main
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
   Concordance takes the `total_pages` of the row with the longer duration, as
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
  `last_open` wins. For books KOReader uses on this device, Concordance keeps
  the local **title and authors** (KOReader's `getIdBookDB` finds the row by
  them: renaming it would make KOReader start a new, empty row next time
  the book is opened) and the local **`pages`** (see 8 above). Series,
  language and `last_open` follow the newer copy.
- Books **only known from other devices** (rows Concordance created, recorded in
  `foreign_books`) follow the newest copy completely, with a tie-break on the
  metadata itself, so they converge whatever the order. Once KOReader opens
  the book here (its `last_open` changes), it's local. Limitation: that is
  detected by `last_open` changing, so a local open in the same second as the
  remote `last_open` would go unnoticed (harmless: the title would follow the
  remote one until the next change).
- Books without an md5 (possible for statistics migrated from very old
  versions) are not exported.

### Export diff

- `exported(md5, page, start_time, duration)` in `concordance/state.sqlite3`; an
  event is unexported if missing there or longer locally. One query with a
  `LEFT JOIN` on the attached state database. Neither `start_time` nor
  `rowid` decides what's exported.
- **Fingerprint shortcut (addition):** the diff scans everything (0.34 s on
  a desktop for 300k events, several times that on an e-reader), on every
  sync. Before it, Concordance reads `count(*), max(rowid), total(duration)` of
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

- **Main process:** flush, export (writes `cache/concordance/pending.jsonl`, and
  `pending.jsonl.zst` to upload),
  then fork. The child gets everything it needs (paths, the seen list) in
  its copied memory and writes its progress to `cache/concordance/result.json`
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
  "Turn on Wi-Fi for automatic syncs" is on, which uses `NetworkMgr:runWhenConnected`.
  **Assumption:** "Sync now" always uses `runWhenConnected`, i.e. follows
  KOReader's own "action when Wi-Fi is off" setting, like other network
  actions the user starts.
- **Automatic syncs are on by default**, for statistics and for
  annotations, each with its own setting. A sync is for statistics,
  annotations or both: the engine runs only the streams asked for (requests
  queued during a sync are merged), and each stream keeps its own time of
  its last full listing and last success.
- **The server comes from Cloud storage, by name**, and is the one settings
  sync uses: `concordance/settings.lua` keeps `{name, type}` and a folder
  (default `/KOReader`, relative to the server's address; statistics and
  annotations go in its `Reading/`, `Statistics/` before OmniSync 0.5.0), and the address and credentials
  are read from `cloudstorage.lua` when syncing. Statistics and annotations
  need a WebDAV server (settings sync also works with Dropbox). Nothing is
  shared with Reading statistics' own Cloud sync setting. With no server
  chosen, the first Dropbox or WebDAV server is used; a chosen one that's
  gone is an error, not a fallback to another (that could be a different
  place).
- **A changed server or folder resets the sync record.** The state database
  remembers the location (address without credentials, and folder). When it
  differs, `exported`, `seen_segments` and `bad_segments` are cleared, so
  the device publishes everything it has to the new place and imports
  everything there. Statistics themselves are untouched.
- **A moved folder isn't a new one.** A database without a location on
  record (see `Store:forgetLocation`) takes the next folder as the same
  place, its files copied there by hand.
  Writing to a folder that doesn't have this device's files would start
  numbering segments from 1 again, clashing with the copies; so a device
  that has segments on record (in `seen_segments`) and doesn't find its
  folder there stops before writing anything (`missing_own`), and forgets
  the location again. Asked for by the user, it offers to send everything
  instead (the location is set to a placeholder, so the next one is new).
- The subprocess keeps the garbage collector running (stopping it would let
  a big download pile up garbage on a 512 MB e-reader). Concordance closes all
  its database connections before forking, so the child can't finalize any
  of them; KOReader's own subprocesses don't do anything special here either.

## Measurements

`scripts/test-concordance.sh bench`, desktop (x86-64), local rclone WebDAV
server, three devices with ~100k events each (5 years, 40 books):

| Sync | Data up | Data down | Requests | Main-process CPU |
|---|---|---|---|---|
| First sync, publishing 100k events (6 cycles) | 0.8 MB | 7 KB | 34 | export 0.8 s |
| New device importing 300k events (1 cycle) | 1 KB | 2.4 MB | 25 | import 5.0 s |
| Incremental, one 30-page session, sender | 0.6 KB | 2.2 KB | 8 | export 0.41 s |
| Incremental, receiver | 0.1 KB | 2.2 KB | 6 | 0.07 s |
| Incremental, nothing new | 0.1 KB | 1.9 KB | 5 | 0.03 s |

~97 bytes per event uncompressed, ~8 compressed (the benchmark's data is
regular; real reading compresses about 8–11×). Before compression (0.2.2)
the first two rows were 9.5 MB and 28.4 MB. An e-reader's CPU and flash are several
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
- **KOReader's UI modules are stubbed** in `tests/test_concordance_plugin.lua`;
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
- Writers: KOReader's "Reset statistics" deletes rows; Concordance could detect
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

## Packs

Real use uploads a small segment after most reading sessions (a sync runs on
opening and closing a book, waking, connecting and starting), so a busy device writes
thousands a year. The daily full listing and a new device's first sync (one
request per segment) grow with them. So each device packs its own small
segments (`pack.lua`, step 5 of `netjob.lua`):

- **When:** on a full listing (daily), for each stream, once there are at
  least 100 small segments (64 KB or less compressed) after the last one
  packed. A pack takes up to 500 of them, and no more records than one
  upload holds (20,000 readings, 5,000 annotation or book data records), so
  importing it blocks the screen no longer than any segment. A pack that
  reaches that record limit is made however few segments it holds, so busy
  segments are packed in parts. Big segments (a first sync's) and gaps are
  left as they are; a run too short to pack that one of them ends will
  never grow, so it's left too and packing goes on past it. 64 KB is about
  12,000 readings (5 to 10 bytes each compressed; a 60-page session is
  about 600 bytes), so nearly every everyday segment counts as small.
- **What:** an ordinary segment, the device's next number, holding exactly
  what importing its segments would leave: statistics keep every book
  record and the longest of each reading; annotations and book data keep,
  per key, the records with the highest (updated, device) (the importer
  breaks ties by content hash). A bad segment adds nothing. Every device,
  any version, imports it like any segment: once each, and what it already
  had changes nothing. That's the cost of plain numbering (rather than a
  name saying which segments it holds): every device downloads and imports
  each pack once, a couple of seconds on an e-reader. In exchange, readers
  need nothing new, and old versions read packs.
- **Deleting:** at a full listing a week after making it
  (`status.packs`: name -> stream, first, last, time, done), the owner
  deletes the segments a pack holds, as long as the pack (or a later pack
  holding it) is on the server.
- **Numbering:** a number once used is never used again, as others may
  have imported its segment: a device writes the first free number above
  the highest it has used itself (its seen segments, or for a copy restored
  from an old backup, the highest pack its `meta.json` gives: `"packed"`,
  per stream). Free numbers below that are gaps, not to be filled. A
  device about to upload with no record of its own segments lists its
  folder first. Readers asking for the next number by name carry on once
  past a gap, after the highest number they have.

## Folder dates

An ordinary sync asks each device folder for its next segment by name: one
request per device and stream, even with nothing new. The listing of
`devices/` it makes anyway gives each folder's last-modified date, which on
most servers changes when a file is moved in or deleted. So a folder whose
date is the same as when this device last went through it completely (for
that stream, with everything imported) is skipped (`status.folders`):
with nothing new, an ordinary sync is that one listing.

- **Trust is earned:** dates are used only once this device's own folder
  has been seen to change date after an upload (`status.own_check`, then
  `status.folder_dates = "reliable"`). If it keeps its date, or a full
  listing finds a segment this device hasn't seen in a folder whose date
  didn't change, the dates are "unreliable" for good and every folder is
  asked as before. rclone serve webdav keeps reporting a folder's first
  date, and is caught by the first check.
- **The same second:** a date is relied on only when it's at least 2 s
  older than the server's clock (the listing's `Date` header), so a segment
  moved in during the same second as the listing isn't missed.
- **Nothing skipped** for a device with no seen segments in a folder (a
  rebuild from cloud), for a stream not gone through before, after a
  download failed or the download budget ran out, or on full listings,
  which still list every folder (and check the dates).

## Recommendations and things I think are a bad idea

- **Running both syncs on the same devices** is a bad idea: the built-in one
  deletes, Concordance doesn't, and they pick different `total_pages` (see 9).
- **"Higher `last_open` wins" for title/authors** would break KOReader's
  lookup of the book on the device that loses (see Book identity).
- **Comparing totals across devices** isn't meaningful for pages read
  (see 8); comparing `page_stat_data` is.
- **Device IDs live in `settings/concordance/device.lua`**, apart from the
  shared settings (`settings/concordance/settings.lua`) so the latter can be
  synced between devices. Copying a whole KOReader folder to a new device still
  copies the ID. Two devices sharing an ID is safe here (no overwrites,
  unknown own segments get imported), but "Reset device ID" is still worth
  doing.
