# Book data sync design

Syncing what you set by hand about a book, apart from highlights and
reading progress: its status, rating and review, custom metadata,
handmade table of contents and hidden flows, and the collections it's in
(favorites included). A third stream next to the
statistics and annotations, synced with annotations (same menu item, same
automatic setting). Written against the same KOReader revision as
ANNOTATIONS.md.

Implemented in `omnisync/bookformat.lua` (properties, segment format),
`omnisync/bookstore.lua` (merged state, change detection, export and
import) and `omnisync/booksync.lua` (in KOReader: reading and writing
sidecars, the open book).

Not covered: reading progress (KOReader's progress sync does that), custom
covers (image files), display settings (font, margins, zoom: they belong
to each device's screen).

## What's synced

Each item is a property of a book (by KOReader's partial MD5, like the
other streams):

| Property | Where KOReader keeps it | Value |
|---|---|---|
| `status` | sidecar `summary.status` | `reading`, `abandoned` (on hold), `complete` |
| `rating` | sidecar `summary.rating` | 1–5 |
| `note` | sidecar `summary.note` | the review |
| `meta.<key>` | `custom_metadata.lua`, `custom_props` | title, authors, series, series_index, keywords, language, description |
| `toc.<kind>` | sidecar `handmade_toc`, `handmade_toc_enabled` | `{ enabled, items }` |
| `flows.<kind>` | sidecar `handmade_flow_points`, `handmade_flows_enabled` | `{ enabled, items }` |
| `coll.<id>` | `settings/collection.lua` | `true`: the book is in collection `<id>` |
| `hist` | `history.lua` | when the book was last opened (epoch seconds) |

Collections themselves are on a record that isn't a book, MD5
`collections`: `coll.<id>` → `{ "name": … }`. See
[Collections and favorites](#collections-and-favorites).

`<kind>` is `rolling` (EPUB and other reflowable books: positions are
XPointers) or `paging` (PDF, DjVu: page numbers), as for annotations; a
book opened with both engines keeps two lists. In reflowable books the
items' `page` depends on the layout, so it's not sent; KOReader recomputes
it on open.

The status's date (`summary.modified`) isn't a property: it's set to when
the status changed, from the record's time.

## Remote format

`book-NNNNNNNNNN.jsonl.zst` in each device folder, next to `seg-` and
`ann-`, with its own numbering:

```
{"t":"h","format":"statsync-book","v":1,"minor":0,"device":"…","created":…}
{"t":"b","md5":"…","title":"…","authors":"…"}
{"t":"p","md5":"…","prop":"status","upd":…,"dev":"…","v":"complete"}
{"t":"x","md5":"…","prop":"rating","upd":…,"dev":"…"}
{"t":"end","books":n,"records":m}
```

- `p` sets a property, `x` clears it. `upd` is when the change was made,
  `dev` the device that made it.
- Same rules as the other streams: unknown major `v` rejected, unknown
  record types skipped, trailer required, one bad line rejects the file.
  Known properties are validated (a status that isn't one of the three, a
  rating out of range, a TOC item without its position); unknown ones are
  kept and passed on but never applied, so a later version can add some.
- A separate stream rather than new records in annotation segments: older
  versions would mark those segments as seen without reading them, and
  never pick the book data up after upgrading.
- Cost: one more request per device on an ordinary sync (asking for each
  device's next `book-` file).

## Merging

Last writer wins per property, by `(upd, dev, hash)`, clears included, as
for annotations: idempotent, order independent, and a late old record
can't bring back a cleared value.

KOReader keeps no times for these properties, so:

- **A change is dated when it's noticed**: when the book closes, before a
  sync for the open book, or when a changed sidecar is read again.
- **Values a device already had before it first looked at a book are
  older than that**: the summary's properties are dated from
  `summary.modified`, custom metadata from the file's time, the TOC and
  flows 0. They win only over what the merged state lacks or holds older,
  so a device joining late doesn't override what the others sent.
- **"reading" where there was no status is the weakest**: KOReader sets it
  whenever a book without a status is opened. It never beats a status
  from elsewhere. A change from another status to "reading" is a real
  change.
- **A missing status is never a clear.** Every opened book has one.

### Versions of a book

Files that are the same book (they share a UUID, see
[IDENTITY.md](IDENTITY.md)) share status, rating, review and custom
metadata: a book's merged value is the winner across the records of all
its files, by the same rule. The TOC and flows hold positions, so they stay
with their own file. Changes are still recorded and sent under the book's
own MD5; nothing already on the server changes.

The joined files are kept in `id_groups`, rebuilt from the identity facts
at the end of each sync. When a group changes, its books' closed-book
writes are looked at again and they count as changed for the open book,
so a link that arrives after the values did needs nothing more.

### Reset settings

KOReader's "Reset settings" (and a deleted `.sdr` folder) leaves a sidecar
without a status, rating, review or TOC. That isn't the user clearing them
everywhere: a sidecar without a status, or with KOReader's reset marker
(`docsettings_reset_done`), is looked at as if for the first time. Nothing
is cleared, and the merged values are put back. In the reader, the check is
made when KOReader reads the book's settings (`ReadSettings`), before it
fills in "reading" and removes the reset marker.

## Local changes

- **The open book:** on `ReaderReady` (after KOReader's own setup), on
  close, and before each sync. Values come from the open book: `summary`
  from its settings, the TOC and flows from `ReaderHandMade`, custom
  metadata from its file.
- **Closed books:** before each sync of annotations, the sidecars of books
  in the reading history (and books seen before) are checked by size and
  time (sidecar and custom metadata file); those that changed are read
  again. That catches changes made in the file browser (status, rating,
  review, metadata), by other tools, or by writes from OmniSync itself
  (which then compare equal). The first time, every sidecar is read.
- `book_local` holds what each property was when last looked at (`""` for
  none); a different value is a change, a value gone is a clear (except
  the status, and except after a reset, above).

## Applying merged changes

- **The open book**, on open and after a sync (unless a menu or dialog is
  over the reader: then retried every 2 seconds for 3 minutes, as for
  annotations):
  - status, rating, review: into its `summary` table (KOReader saves it on
    close); the file browser's cached status and rating are updated.
  - custom metadata: its custom metadata file is written as KOReader's book
    information dialog does (a copy of the original props kept, the file
    removed when nothing is customized any more), and the open book's
    title and authors updated. `InvalidateMetadataCache` and
    `BookMetadataChanged` are sent.
  - TOC and flows: `ReaderHandMade`'s lists set, then what KOReader does
    once a book is ready (page numbers, flows, TOC, `UpdateToc`, and for
    flows `InitScrollPageStates`).
- **Closed books** with a known path (from the reading history or an
  earlier open), after each sync: status, rating, review and custom
  metadata are written into the sidecar with `DocSettings`, as the file
  browser's status buttons do, and the file browser's cache for the book
  reset. Before writing, the sidecar is read again and its own changes
  recorded, so a change made meanwhile isn't overwritten. Books without a
  sidecar (never opened on the device) are not written; they get the
  values on first open. The TOC and flows wait for the book to be opened.
  (Annotations are written into closed books the same way: see
  ANNOTATIONS.md.)

## Collections and favorites

Implemented in `omnisync/collsync.lua`, with its queries in
`bookstore.lua`. KOReader keeps every collection in one file,
`settings/collection.lua`, by name and by file path. Neither works across
devices (paths differ, names change), so:

- **Membership is a book property**, `coll.<id>` under the book's MD5,
  set (`true`) or cleared, last writer wins as for the rest. Versions of a
  book share it (`BookFormat.isGroupProp`): a book favourited as one
  edition is a favourite as the other.
- **Collections are properties of the `collections` record**: `coll.<id>`
  → `{ name }`, cleared when the collection is removed. MD5 `collections`
  isn't hex, so it can't be a book; older versions keep it as an unknown
  book with unknown properties and pass it on.
- **IDs**: KOReader keys collections by name, so the ID goes into the
  collection's settings in `collection.lua` (`omnisync_id`), which
  KOReader keeps and carries over when the collection is renamed.
  Favorites is always `favorites`. A collection without an ID gets the
  first 16 hex digits of its name's MD5, so collections of the same name
  made on two devices before they synced are one; if that ID belongs to a
  collection of another name, it gets a random one.
- **Only membership and names** are synced. The order of books and of
  collections, sorting, filters and connected folders stay each device's
  own (connected folders are paths). A book a connected folder adds is an
  ordinary membership.

Dates, as for the other properties:

- The first time a device looks at its collections, what's in them is as
  old as can be (time 0), so it only adds where the merged state has
  nothing (a union) and never undoes a removal made elsewhere.
- After that, a collection not looked at before, and a book not seen
  before in a collection that was, are changes made now. So a collection
  made again with the name of one removed earlier stays.

When things are looked at and applied:

- **Before each sync** with book data: the books in collections get their
  MD5s (from the book data's known files, a cache by file size and time
  `coll_files`, the sidecar's `partial_md5_checksum`, or computed from the
  file as KOReader does), a chunk per UI tick; then the collections are
  compared with what was seen last time (`book_local`).
- **After the sync**, unless a menu or dialog is open (KOReader's
  collection views keep their own copy and write it when closed; retried
  every 2 seconds for 3 minutes): removals, then renames, then new
  collections, so names freed are free for the others; then books are put
  in and taken out. KOReader allows one collection per name: a collection
  arriving with a name taken here by another is given a free one
  ("Name (2)"), which is then a rename like any other, so every device
  ends up with the same names.
- **When a book is opened**, it's put in the collections it belongs to.
- Books are found where book data knows them (books opened on this device)
  and among books already in collections. A book on this device that's
  never been opened and isn't in a collection is put in its collections
  when it's first opened.
- **A book file gone from this device** isn't a removal from its
  collections (KOReader drops missing files from them): what this device
  saw of that book's collections is forgotten, and when the file comes
  back it's put back in.

Settings sync shouldn't also sync `settings/collection.lua`: the two would
fight over it.

## Reading history

Implemented in `omnisync/histsync.lua`, with its query in `bookstore.lua`
(`history()`). KOReader keeps the history in `history.lua`: a list of
`{ time, file }`, newest first, by full path, at most `history_size`
entries (500). It also uses it for the file it reopens on startup
(`lastfile`, the first entry whose file exists) and touches each opened
file's access time ("sort by last read").

- **The property is `hist`**, the time the book was last opened, under the
  book's MD5. Both the value and the record's `upd` are that time, so the
  latest opening wins wherever it was recorded; the usual tie-break
  applies. Versions of a book share it (`GROUP_PROPS`).
- **Only openings are synced.** An entry can leave the history because the
  user removed it, because of the size limit, or because the file is gone
  (with "auto-remove deleted files" on); these can't be told apart, and
  none of them is a reason to remove it elsewhere. So `hist` is never
  cleared.
- **Local changes**, before each sync with book data: each entry whose file
  exists gets its MD5 (as for collections, `coll_files` as the cache,
  found a chunk per UI tick before the sync), and its time is recorded,
  dated by itself.
- **Applying**, after the sync (unless a menu or dialog is open: KOReader's
  History view works on its own copy; retried every 2 seconds for 3
  minutes): every book whose merged `hist` differs from what this device
  last saw (`book_local`) is put into the history at its time, unless the
  history already has it as new or newer. Its file's access time is set
  too. Then `book_local` holds the merged value, so a book removed here
  isn't put back until a newer opening arrives. The history is saved with
  KOReader's own `_reduce` and `_flush` (which also sets `lastfile`).
- **Where the book is**: a file the sync knows for the book or one of its
  versions (`book_files`, `coll_files`); else, through Cloud library
  (`package.loaded["cloudlibrary/library"].pathForUuids`, when it's
  loaded), the book's UUIDs from book identity: the downloaded file, or
  the book's cloud entry (a path that isn't a file). A cloud entry isn't
  dimmed but has `select_enabled` false, so KOReader never picks it to
  reopen. A book found neither way isn't marked seen, and is looked for
  again after the next sync.
- **The open book**: KOReader's `updateLastBookTime` sets the first
  entry's time when the book closes, taking it for the open book. So
  while a book is open, nothing is put at or above its entry; those wait
  (not marked seen) for the sync that closing it starts.

Settings sync shouldn't also sync `history.lua`.

## Local state (in `omnisync/state.sqlite3`)

```
book_merged(md5, prop, updated, device, deleted, hash, value)  -- merged truth
book_local(md5, prop, hash)                -- this device's copy, as last seen
book_outbox(md5, prop, updated)            -- changes waiting to be sent
book_books(md5, title, authors, write)     -- write: closed-book values to write here
book_files(path, md5, sig)                 -- where the book is; sidecar size and time
coll_files(path, md5, sig)                 -- books in collections or the history; file size and time
id_groups(md5, grp)                        -- versions of a book (kept by idstore.lua)
```

Segments imported are recorded in `seen_segments`/`bad_segments`, so
"Rebuild from server" and a change of server or folder cover this stream
too (a change of server or folder also queues the whole merged state
again).

## Tests

`tests/test_omnisync_coll.lua`: collections (KOReader's ReadCollection
stood in for): first sync as a union, IDs from names, rename, removal,
a collection made again, files gone and back, busy and retried, name
clashes, versions of a book. `tests/test_omnisync_book.lua`: the format, merge order independence and
idempotence, first-look and "reading" rules, clears, reset sidecars,
closed-book writes (summary and custom metadata files, real files with
`DocSettings` stood in for), refresh by signature, and applying to an open
book (status over KOReader's "reading", TOC with page numbers recomputed,
title). `tests/test_omnisync_integration.lua` syncs book data between
devices through the engine, subprocess and rclone, including a corrupt
segment and a rebuild. `tests/test_omnisync_plugin.lua` checks the status
from the reading history is sent. Nothing ran on a device.
