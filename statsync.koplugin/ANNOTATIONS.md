# Annotation sync design

Syncing bookmarks, highlights and notes between devices, as a second
stream next to the statistics in statsync. Written against KOReader
`426e932` (20 Oct 2026); file and line references are to that revision.

Implemented in `statsync/annformat.lua` (records, keys, segment format),
`statsync/annstore.lua` (merged state, change detection, held deletions,
export and import) and `statsync/annsync.lua` (in the reader: open, close,
live apply, history scan, the question). Where the build differs from the
design below, it says so under "As built".

## Goals

1. Bookmarks, highlights and notes made on one device appear on the others,
   in the same book, at the same place.
2. Edits (note text, colour, style, adjusted boundaries) and deletions sync
   too. A deleted highlight must not come back.
3. Same guarantees as the statistics: per-device immutable files on plain
   WebDAV, files can be merged in any order and more than once, only new
   changes are sent, network work in a subprocess, no retry queue.
4. A mistake on one device (a reset sidecar, a different engine) must not
   wipe annotations everywhere.

Not covered: reading progress (KOReader's progress sync does that), book
files, vocabulary, statistics' `highlights`/`notes` counts.

## How KOReader stores annotations

- **Where.** One `annotations` list per book, in the book's sidecar
  (`metadata.<ext>.lua`). The sidecar is in `<book>.sdr/` next to the book,
  in `docsettings/<path>.sdr/`, or in `hash/<md5[1..2]>/<md5>.sdr/`,
  following `document_metadata_folder` (`frontend/docsettings.lua:118`).
  There's no database of annotations.
- **What's in it.** Since KOReader's 2024 change from separate
  `bookmarks` and `highlights` tables, the one list holds all three kinds:
  page bookmarks (no `drawer`, no `pos0`/`pos1`), highlights (`drawer` set),
  and notes (a highlight with `note` set). "Annotations" in this note means
  all of them, and they all sync the same way.
- **Fields** (`readerannotation.lua:66`): `datetime` (creation, local time
  `"%Y-%m-%d %H:%M:%S"`, "not changeable"), `datetime_updated`, `drawer`,
  `color`, `text`, `text_edited`, `note`, `note_format`, `chapter`,
  `pageno`, `pageref`, `page`, `pos0`, `pos1`, `epubcfi`, `pboxes`, `ext`.
  Page bookmarks have only `page`, `text`, `chapter`, `datetime`
  (`readerbookmark.lua:385`).
- **Positions.** For reflowable books (CREngine, "rolling") `page`, `pos0`
  and `pos1` are XPointer strings. For PDF/DjVu ("paging") `page` is a
  number and `pos0`/`pos1` are tables of page coordinates.
- **Two lists per sidecar.** The rolling and paging formats can't be mixed.
  Opening a book with the other engine moves the current list aside as
  `annotations_rolling` or `annotations_paging` and loads the other one
  (`readerannotation.lua:120`).
- **No ID.** KOReader itself matches items by `datetime` + `pos0` + `pos1`
  (rolling) or `datetime` + `page` + coordinates (paging)
  (`readerannotation.lua:455`).
- **While a book is open** the list lives in `ReaderAnnotation.annotations`
  and is written back on save and close (`onSaveSettings`), overwriting the
  sidecar's copy.
- **Changes** go through the `AnnotationsModified` event, which sets
  `datetime_updated` for edits, including boundary adjustments
  (`readerhighlight.lua:1065`). Additions and removals carry
  `index_modified` and the `nb_highlights_added`/`nb_notes_added` counts
  the statistics plugin uses (`statistics.koplugin/main.lua:2677`).
- **Outside changes.** KOHighlights sets `annotations_externally_modified`,
  which makes KOReader recompute page numbers and re-sort on the next open
  (`readerannotation.lua:117`).
- **KOReader's own export/import** (`<book>.annotations.lua`) isn't a merge:
  an item missing from a newer export is deleted (`readerannotation.lua:328`).
  Not reused.

## Identity

### Books: the partial MD5

The book key is the `partial_md5_checksum` from the sidecar, the same value
the statistics records already carry.

- Positions are only valid in the file they were made in, and the MD5
  identifies that file. Different files of the same book (another edition,
  another source) don't share annotations: their XPointers wouldn't point at
  the same text.
- Title and authors aren't part of the key. They differ between devices for
  the same file (Calibre edits, the PDF trailing-`\0` quirk) and would only
  cause missed matches. They're sent for display only.
- No filename matching: two files with the same name would get each other's
  highlights at the wrong places.
- Limitation: the MD5 is fixed when a device first opens a book. A device
  that first opened a copy later rewritten by Calibre has a different MD5
  from one that first opened the rewritten copy. Rare; clearing one
  device's sidecar for that book fixes it.

### Annotations: creation time, plus position when needed

Key = `(md5, kind, datetime)`, where `kind` is `rolling` or `paging`.

- `datetime` doesn't change, and annotations are created one at a time by
  hand, so within one book two items rarely share a second. Keeping the
  position out of the key means an adjusted highlight is an edit of the same
  item, not a deletion plus an addition.
- **Collisions.** If a book has several items with the same `datetime`
  (possible after KOHighlights merges, or two very quick bookmarks), those
  items get `datetime` + `pos0` + `pos1` as their key, KOReader's own match
  rule. Adjusting one of those is then a delete plus an add. The rule is
  applied the same way on every device, so they agree on keys.
- The key is sent as a string (`"2026-11-04 09:15:02"` or
  `"2026-11-04 09:15:02|<pos0>|<pos1>"`, PDF coordinates written with fixed
  precision), so receivers never recompute it from data they may hold
  differently.

### DOM versions

Not handled. Every book here was first opened after 2020, so all are on a
DOM version with normalised XPointers (≥ 20200223), which stay valid in
later versions. As a guard, books with `cre_dom_version` < 20200223 are
skipped and logged, with no conversion.

## Data model

The merged state is a **last-writer-wins map** per `(md5, kind)`:
`key → { updated, device, deleted, fields }`.

- **Add or edit** record: the item's fields and `updated`.
- **Deletion** record ("tombstone"): the key and `updated`, no fields.
- **Merge:** for each key keep the record with the highest
  `(updated, device, content hash)`. A deletion is a record like any other,
  so an edit newer than a deletion brings the item back, and a deletion
  newer than an edit removes it.
- This is idempotent, commutative and associative, so segments can be
  applied in any order, more than once, as with statistics.
- Tombstones are kept forever (they're small). Without them, an old segment
  arriving late would bring a deleted item back.

### `updated` (the clock)

- Adds and edits: `datetime_updated`, or `datetime` for unedited items,
  converted to epoch seconds **on the device that made it**, using that
  device's time zone. Devices in different zones then compare correctly.
- If an item's content changed but its `datetime_updated` didn't move past
  the last published value (edits by KOHighlights or other tools), the time
  of detection is used instead.
- Deletions: KOReader doesn't record when an item was deleted, so the time
  the deletion was detected is used. That's at or after the actual
  deletion, so a deletion tends to beat a concurrent edit on another device.
- **Risk:** a device whose clock is wrong can lose edits or deletions, or
  override newer ones. Accepted, as for statistics: KOReader devices set
  their clocks from the network.

### Fields sent

All fields except device-local ones, so fields KOReader adds later sync
without a format change:

- **Not sent:** `pageno` and `pageref`. They depend on layout and are
  recomputed on each device (`updateAnnotations(true)`).
- **Sent:** everything else, including `pboxes` and `ext` for PDFs (page
  coordinates are the same on every device for the same file).

## Remote layout and format

A separate stream in each device folder, with its own numbering and seen
tracking:

```
<folder>/v2/devices/<device-id>/
  meta.json
  seg-0000000001.jsonl.zst      statistics (unchanged)
  ann-0000000001.jsonl.zst      annotations
```

Separate files rather than new record types in the statistics segments:
older plugin versions would mark those segments as seen without reading the
annotations, and never pick them up after upgrading.

Segment lines (JSON Lines, then zstd, as for statistics):

```
{"t":"h","format":"statsync-ann","v":1,"minor":0,"device":"…","created":…}
{"t":"b","md5":"…","title":"…","authors":"…"}
{"t":"a","md5":"…","kind":"rolling","key":"…","upd":…,"f":{…fields…}}
{"t":"x","md5":"…","kind":"rolling","key":"…","upd":…}
{"t":"end","books":n,"records":m}
```

- Same rules as statistics: unknown major `v` rejected, unknown record
  types skipped, trailer required, one bad line rejects the file.
- `f` is a JSON object of the item's fields. `pos0`/`pos1` tables are
  objects; the codec's key ordering keeps the content hash stable.
- Upload, MOVE without overwrite, probing for the next segment by name,
  daily full listing, download budget and bad-segment records are reused
  as they are, with the `ann-` prefix.

## Local state (in `statsync.sqlite3`)

As built:

```
ann_merged(md5, kind, key, updated, device, deleted, hash, fields)   -- merged truth
ann_local(md5, kind, key, hash, upd)   -- what this device's list held last time
ann_books(md5, kind, title, authors, path, observed, pending, held_at)
ann_held(md5, kind, key)               -- deletions waiting for the user
ann_outbox(md5, kind, key, updated)    -- changes waiting to be sent
```

- `ann_books` replaces the planned `ann_pending` and `ann_files`: per book
  and kind, whether this device has looked at its list yet (`observed`),
  whether merged changes are waiting for it (`pending`), and where it was
  last seen.
- `ann_outbox` replaces `ann_exported`: a change is queued when it's made
  here, and leaves the queue once a confirmed upload holds it (or a newer
  record from elsewhere replaces it). Imported records are never queued, so
  nothing is echoed back.
- Segments imported are recorded in the statistics' `seen_segments` and
  `bad_segments` (the `ann-` names can't clash with `seg-`; bad ones carry
  the annotation format's version), so "Rebuild from cloud" and a change of
  server or folder cover both streams. A change of server or folder also
  queues the whole merged state again, as the statistics are all sent
  again.
- Republished records keep the device that made the change (`dev` in each
  record), so ties between equal timestamps are broken the same way
  everywhere.

- `ann_merged` holds the full merged state of every book, so changes can be
  applied to books opened later, and a reset sidecar can be restored.
- `ann_local` is what tells a local deletion from a remote addition that
  hasn't been applied yet: a key in `ann_local` but missing from the
  sidecar was deleted here; a key in `ann_merged` but not in `ann_local`
  is new from elsewhere.

## Detecting local changes

When a book closes (`onCloseDocument`, before the sidecar is written, from
the in-memory list), before each sync for the open book, and on the
initial scan:

1. Build the current map `key → hash(fields)` from the loaded list. The
   list's kind is taken from the engine (`ui.rolling`/`ui.paging`).
2. Compare with `ann_local` for that `(md5, kind)` only. The other kind's
   list wasn't loaded, so its items aren't "missing".
3. New key or changed hash: an add/edit record into `ann_merged` (if newer)
   and the next segment.
4. Key in `ann_local` but gone: a deletion record.
5. Update `ann_local`.

### Guard against mass deletion

A reset or deleted sidecar, a sidecar copied over from an old backup, or
"Reset" in book settings all look like the user deleted everything. So when
more than 5 items **and** more than half of a book's items vanish in one
comparison (or all of them, for a book with a known merged state), no
deletion records are made straight away. The user is asked instead:

> 12 of 15 highlights and bookmarks in "Book title" were removed on this
> device. Remove them on your other devices too?
>
> [Restore them here]  [Remove everywhere]  [Ask later]

- **Restore them here:** the merged state is applied back to the book (as
  for a remote change), and nothing is sent.
- **Remove everywhere:** deletion records are made and sent as usual.
- **Ask later** (or dismissing the dialog): nothing is sent and nothing
  restored; the book stays held and the question comes back at the next
  close or sync. Held books are listed in the status screen, where the
  question can be answered too.
- The question is asked when the change is detected: on opening or closing
  the book (a reset sidecar is noticed on open), or after the initial scan;
  and again after each sync while anything is held. Automatic syncs never
  decide on their own.
- While a book is held, its other changes (additions, edits, deletions
  below the threshold) still sync normally.

### Changes made outside the reader

KOHighlights, or a sidecar edited or copied while the book was closed, are
seen at the next open or scan, as ordinary local changes (the guard above
applies). Until then they don't sync.

## Applying merged changes

### The open book (live)

After an import that touched the open book's `(md5, kind)`:

1. For each key whose merged record differs from the loaded item: replace,
   add (via `ReaderAnnotation:addItem`, which sorts it in) or remove it.
2. Call `updateAnnotations(true, true)`, send `AnnotationsModified` with
   the `nb_highlights_added`/`nb_notes_added` deltas (so the statistics
   plugin's counts and the file browser's `has_annotations` stay right),
   and redraw.
3. Update `ann_local` to the result, so these changes aren't sent back.

Never while a menu or dialog is over the reader, or text is selected: then
it's retried every 2 seconds for up to 3 minutes (so "Sync now", which keeps
the menu open, still applies once the menu closes), and after that left for
the next sync, close or open.

### Other books: on next open (default)

- Books with merged changes not yet in their sidecar are listed in
  `ann_pending`.
- On `ReaderReady` for such a book: detect local changes first (above),
  then apply merged changes as for the open book.
- Robust: KOReader loads the sidecar itself, nothing writes to a file it
  owns. Works for books never opened on this device (no sidecar until the
  first open, no known path).
- Cost: until a book is opened, its highlight count in the file browser and
  exports (e.g. to Readwise or Joplin) don't include synced annotations.

### Other books: straight into the sidecar (not planned)

For books with a known path (`ann_files`, from reading history and opens):
open the sidecar with `DocSettings:open`, merge, set
`annotations_externally_modified`, flush. KOReader then recomputes page
numbers and re-sorts on the next open, as it does for KOHighlights. Skipped
for the open book and for sidecars whose list is the other kind. More work
and more risk (writing files KOReader owns, the three sidecar locations,
`.old` backups); only worth it if up-to-date counts and exports matter.

## Sync cycle

The statistics cycle, with annotation steps alongside:

```
flush stats → detect open book's annotation changes
→ export stats segment + annotation segment
→ network (subprocess): both streams up, both down
→ import stats segments, then annotation segments (one per UI tick)
→ apply to the open book; mark other books pending
```

- One subprocess, one time limit, one single-flight lock for both streams.
- Annotation sync has its own on/off switch. **As built: on by default**
  (the design had it off, as notes go to the server in plain text, as
  statistics do; changed at the user's request). Turning it off is kept
  in the shared settings as `annotations = false`.
- "Rebuild from cloud" re-imports both streams. A changed server or folder
  resets both streams' records.

### Initial scan

Annotations of books that aren't opened would otherwise never be published.
Before the first sync with annotation sync on (after installing or
updating, or turning it on again), triggered by whatever starts that sync:

- Walk the reading history; for each file with a sidecar, read
  `partial_md5_checksum` and the `annotations` list, record the path in
  `ann_files`, and run change detection.
- About 20 books per UI tick, so a large history doesn't freeze the screen.
- Sidecars without `annotations` (not opened since KOReader's 2024 format
  change) are skipped; KOReader converts them on the next open.
- If two devices start with copies of the same sidecar, their records have
  the same keys and contents, so the merge collapses them.

## Interactions

- **Settings sync** must not sync sidecars (`docsettings/`, `hash/`,
  `.sdr` folders) for the same books, or the two would fight. Its
  `settings.txt` doesn't list them; don't add `//` lines for them.
- **KOReader's annotation export/import** on close
  (`annotations_export_*`): turn it off; its import deletes items
  missing from the export.
- **"Write highlights into PDF"**: a highlight written into the PDF file
  would appear twice on a device that has the same PDF with the
  embedded annotation and the synced one. Recommend leaving it off, or skip
  syncing PDFs where it's on.
- **KOHighlights**: works, through the outside-changes path.
- **Statistics' highlight and note counts**: updated through
  `AnnotationsModified` for the open book; for other books, when opened.

## As built: other details

- **Items that don't fit their list** (an XPointer in a PDF list, a page
  number in a reflowable one) are left out when a list is read. Sent, they
  would make every other device reject the whole segment.
- **Annotation fields are Lua data**, not always JSON-shaped: a multi-page
  PDF highlight's `ext` is keyed by page number. Tables with such keys are
  sent as `{"~lua":[[key, value], …]}` and rebuilt on reading.
- **The other kind's list** is read by the history scan too (the sidecar
  holds it as `annotations_rolling` or `annotations_paging`), so both are
  published; in the reader only the loaded one is compared.
- **Applying** changes items in place, removes, appends, then calls
  KOReader's `updateAnnotations(true, true)` (page numbers, sort) and sends
  `AnnotationsModified` with `index_modified` set, so KOReader doesn't stamp
  the applied items as edited.

## Tests

- Merge: every order of three devices' segments gives the same state;
  importing twice changes nothing; edit vs deletion, newest wins either way;
  late old segments don't resurrect deleted items.
- Keys: same-second collisions, boundary adjustment as an edit, the same
  key computed on every device.
- Detection: the other kind's list isn't treated as deleted; a mass
  deletion is held until the user answers, and each answer does what it
  says; an emptied sidecar asks too.
- Applying: open book live (count deltas, sort order, redraw), pending
  books on open, never-opened books.
- Format: validation as for statistics, unknown fields kept and passed on,
  PDF coordinates round-trip exactly.
- Integration: real KOReader `ReaderAnnotation` code where it can run
  headless, real sidecars written by `DocSettings`, rclone as server.

As built: `tests/test_statsync_ann.lua` runs KOReader's own
`ReaderAnnotation` (sorting, page numbers, `AnnotationsModified`) on a
stand-in CREngine document, with simulated sidecars;
`tests/test_statsync_integration.lua` syncs annotations between devices
through the real engine, subprocess and rclone; `tests/test_statsync_plugin.lua`
covers the menu, history scan, live apply, close and the question with
KOReader's UI stubbed. `DocSettings` itself isn't exercised (stubbed), and
nothing ran on a device.

## Decided

1. "Newest change wins", with its reliance on device clocks, is acceptable.
2. Books that aren't open get synced changes when they're next opened only;
   writing their sidecars directly isn't planned.
3. Mass deletions are the user's choice: they're asked whether to restore
   or remove everywhere (see "Guard against mass deletion").

