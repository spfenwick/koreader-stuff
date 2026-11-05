# OmniSync: statistics, highlights and bookmarks

Syncs KOReader's reading statistics (the page-by-page reading times behind
Reading statistics), and highlights, notes and page bookmarks, between any
number of devices, through a WebDAV server. (This was SuperSync, and before that
Statistics sync.) See [README.md](README.md) for installing, the menu
and when it syncs.

Unlike Reading statistics' own "Cloud sync", which uploads and downloads the
whole `statistics.sqlite3`, each device here writes only its own files, which
are never changed once written, and merges the other devices' files into its
database. A sync sends only what's new.

**Don't also use Reading statistics' own "Sync now" on the same devices.**
It keeps working (OmniSync doesn't change it), but the two syncs disagree
about deletions: the built-in one propagates them, this one never does, so
mixing them gives confusing results.

## What's on the server

```
<folder on server>/Statistics/    /KOReader/Statistics unless changed
  devices/<device-id>/
    meta.json                     device ID, model, format version, when written
    seg-0000000001.jsonl.zst      segment files, numbered 1, 2, 3, …
    seg-0000000002.jsonl.zst
    …
    ann-0000000001.jsonl.zst      highlights and bookmarks, numbered apart
    …
    book-0000000001.jsonl.zst     book status and details, numbered apart
    …
```

**Packs:** most syncs upload a small file, so once a day each device packs
its own small files into one, once it has at least 100 of a kind: up to
500 in a pack. The pack is an ordinary file, the device's next one, and
every device imports it like any other (what it already has changes
nothing). A week later the device deletes the small files the pack holds,
so a device that joins later downloads one file instead of hundreds. A
file's number is never used again once it's been used, so a gap in the
numbers is normal.

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

(Statistics sync kept these in a `v2/` subfolder, as its 0.2.2 and
earlier wrote uncompressed `seg-N.jsonl` files straight into the folder.
OmniSync doesn't use the subfolder, and doesn't read the uncompressed
files.)

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
  file. An interrupted upload leaves no partial segment. The only files
  ever deleted are a device's own small segments, a week after it packed
  them (see Packs above).
- **Only new data moves.** An ordinary sync lists `devices/` and asks each
  device for its next segment by name; with nothing new that's one small
  request per device. On servers that change a folder's date when a file
  arrives in it, a folder whose date hasn't changed since this device last
  went through it is skipped, so a sync with nothing new is one request in
  all. (Each device checks this first: after an upload, its own folder's
  date must have changed. rclone, for one, doesn't do this.) Once a day
  (and on a sync by hand) every device folder is listed in full, to find
  anything out of sequence.
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

KOReader's annotations (page bookmarks, highlights, and notes on
highlights) sync, including edits (note text, colour, style, adjusted ends)
and removals.

- **Same file, same annotations.** A book's annotations go to the devices
  that have the same file (KOReader's partial MD5), because their positions
  only make sense in that file. Another edition, or a copy from elsewhere,
  doesn't share them. Reflowable books (EPUB and the like) and PDF/DjVu keep
  separate lists, as in KOReader: opening a book with the other engine
  doesn't touch the first list.
- **When they arrive.** Right after a sync: for the book you're reading
  once any menu or dialog is closed, and written into other books opened on
  that device before. A book never opened on a device gets them when first
  opened. A book opened with both engines (a PDF also opened as
  reflowable, say) keeps a second list, which gets them when opened that
  way. Books first opened with KOReader's rendering from before 2020 are
  left out.
- **The first sync** of highlights on a device first reads the highlights
  of every book in the reading history, so they're sent too, not only
  those of books you open later.
- **Newest change wins.** If the same highlight is changed on two devices,
  the later change wins, by the devices' clocks. A removal counts as a
  change: it wins over an earlier edit, and loses to a later one.
- **Removing many at once asks first.** If more than 5 of a book's
  highlights and bookmarks disappear at once (for example the book's
  settings were reset or its `.sdr` folder deleted), they're not removed
  elsewhere straight away. 5 or fewer are removed everywhere at the next
  sync, even if they were all the book had. When more go, you're asked:
  - **Restore them here**: they're put back on this device;
  - **Remove everywhere**: they're removed on the other devices too;
  - **Ask later**: nothing happens; you're asked again after the next sync
    or when the book is next opened or closed (also from the menu).
- **Notes are sent as plain text** to your server, as statistics are.

So:

- **Turn off KOReader's "Export annotations on book closing"** (in the
  reader's Bookmarks settings): the import that goes with it deletes
  highlights that aren't in the exported file.
- **Don't sync books' settings folders** (`.sdr` folders, `docsettings/`,
  `hash/`) with OmniSync's settings sync or any other file sync: the two would undo
  each other's changes.
- **"Write highlights into PDF"** puts a copy of each highlight into the PDF
  file itself. A device with that copy of the file would show it twice
  (once from the file, once synced). Leave it off for synced PDFs.

## Book status and details

Synced with highlights and bookmarks (same menu item, same automatic
setting):

- the book's **status** (reading, on hold, finished), **rating** and
  **review**;
- **custom metadata** set in Book information (title, authors, series,
  series index, keywords, language, description), not custom covers;
- the **handmade table of contents** and **hidden flows**.

As for highlights, they go to devices with the same file. Each item syncs
on its own, and the newest change wins.

- **When they arrive.** Status, rating, review and metadata: right after a
  sync, also into books that aren't open (books opened on that device
  before), so the file browser shows them. The table of contents and
  hidden flows: right away for the book you're reading, otherwise when
  it's next opened.
- **Changes made in the file browser** (marking a book finished, rating
  it, editing its metadata) are picked up at the next sync.
- **A device's first sync doesn't override the others**: what a device
  had before it first synced counts as old, and the "reading" status
  KOReader gives a book when it's first opened never replaces a status set
  elsewhere.
- **Resetting a book's settings** (or deleting its `.sdr` folder) doesn't
  clear anything on other devices: the synced values come back instead.
- **Reviews are sent as plain text** to your server.

Details in [BOOKDATA.md](BOOKDATA.md).

## Recovering

- **A device restored from a backup** (or a copy of another device's KOReader
  folder): use "Reset device ID" on it, so two devices don't share an ID.
  Even without, nothing is lost: segments are never overwritten, and a
  device that finds segments under its ID it doesn't know imports them.
- **Statistics missing on a device**: "Rebuild statistics and highlights
  from cloud" re-imports every device's files. It only adds; it never deletes.
- **Starting over**: choose another folder on every device. Each device
  then uploads its whole history (including what it got from the others)
  there on its next syncs.
- **Logs**: messages start with `StatSync:` in KOReader's `crash.log`.
  Passwords are never logged.
