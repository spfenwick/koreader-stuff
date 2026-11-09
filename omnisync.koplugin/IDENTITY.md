# Book identity across file versions (plan)

Status: steps 1 to 3 built: Cloud library's matcher fix, the identity
stream (2026-11-06), and book data joining (2026-11-08); and step 7,
progress across versions (2026-11-10). Steps 4 to 6 are a plan. Sections below say where the build
differs from the plan.

## The problem

Every stream (statistics, annotations, book data) and KOReader's progress
sync identify a book by the partial MD5 of its file. Calibre-Web Automated
rewrites a book's stored EPUB when its metadata is edited (tested
2026-11-06: changing tags on one book re-ran it through Calibre 9.17,
EPUB 2 → 3; package file, nav, TOC and every chapter's `<head>` rewritten;
body text and element structure of all 101 chapter files unchanged). Every
later download has a new MD5; files already on devices keep the old one.
Devices that downloaded the book on either side of an edit then hold two
"different" books, and nothing they record about it merges.

The same table also answers what Cloud library needs: which synced data
belongs to a catalog book that isn't on this device.

## Two levels of "same book"

1. **Same book**: the files carry the same book ID. Safe for anything
   that's about the book, not about places in it: reading statistics
   (time per page is close enough across a metadata rewrite), status,
   rating, review, custom metadata.
2. **Same positions**: same book *and* the same body structure, so an
   XPointer made in one file points at the same text in the other. Needed
   for annotations, handmade TOC and flows, and progress. A metadata
   rewrite keeps this; a replaced edition (Calibre keeps the UUID when you
   swap in a better file) doesn't.

### The book ID

The UUIDs among the EPUB's `dc:identifier`s. The tested book had two, both
unchanged by the rewrite:

| | Calibre 6 file | Calibre 9 rewrite |
|---|---|---|
| package unique identifier | `opf:scheme="uuid"` `dd15c660…` | `id="uuid_id"` `uuid:dd15c660…` |
| Calibre library UUID (= the OPDS entry ID, `urn:uuid:333d496c…`) | `opf:scheme="calibre"` `333d496c…` | plain `uuid:333d496c…` |

So the scheme doesn't survive the rewrite, and the server's ID can't be
picked out by form alone. Rule: strip `urn:uuid:` / `uuid:`, lowercase,
keep everything that's a UUID; **two files are the same book if they
share any UUID**. With Cloud library present, the shared UUID that's a
catalog ID names the group (the `book_id` in the API below); without it, the
smallest shared UUID.

Non-UUID identifiers (ISBN, `calibre:<n>`, Amazon, Google) never join: an
ISBN is shared by different files. They're recorded for display only.

Guards: a group isn't joined, and is logged, if its files' titles and
first authors both differ after normalising, or if it reaches more than
8 MD5s.

### The body signature

Computed once per MD5 from the EPUB: for each spine item in order, its
`<body>`'s element tag sequence and its text with whitespace collapsed,
hashed together (MD5 of the stream). Attributes, `<head>`, the package
file and nav files are left out, as the tested rewrite changed only
those. This mirrors what crengine's XPointers depend on (spine position,
element path, text offsets).

Cost: one unzip and scan of the whole book, in the subprocess, cached by
MD5 so never repeated. Measured 2026-11-06 on the Kobo Forma with
`tools/2-omnisync-signature-timing.lua` (30 of 132 EPUBs, 0–83 MB): median
0.25 s, 90th percentile 0.82 s, max 1.0 s per book; it follows the amount
of text, not the file size (the 83 MB book, mostly images, took 0.64 s;
The Divine Comedy, 1.4 MB, 0.93 s). Nearly all of it is the chapter scan.
A first scan of a 132-book device: about 45 s, once, in the background.
For comparison, KOReader's partial MD5 takes about 0.01 s.

Files that aren't EPUB: no book ID from the file in this version. Cloud
library can supply one (below); PDFs then join at level 1 only (page
positions survive a metadata rewrite, but nothing here checks it).

## Sync format: a fourth stream

`id-NNNNNNNNNN.jsonl.zst` in each device folder, own numbering, same
rules as the other streams (header, trailer, strict validation, unknown
major version rejected):

```
{"t":"h","format":"statsync-id","v":1,"minor":0,"device":"…","created":…}
{"t":"i","md5":"…","src":"file","uuids":["333d496c-…","dd15c660-…"],"sig":"…",
 "title":"…","authors":"…","ids":["calibre:4644","isbn:9780195056440"]}
{"t":"end","records":n}
```

- A record is a fact about a file: "the file with this MD5 carries this
  book ID and body signature". Facts don't change, so the merged state is
  a grow-only set: no timestamps, no deletions, order-independent and
  idempotent by construction.
- `src`: `file` (read from the file with that MD5), `sidecar` (see below)
  or `link` (supplied by another plugin, e.g. Cloud library matching a
  PDF by title; reserved, not built). For one MD5, `file` wins over
  `link`; two different `file` records for one MD5 can't happen (same
  bytes); two `link`s naming different catalog books leave the MD5
  unjoined.
- As built: implemented in `omnisync/idformat.lua` (format),
  `omnisync/idscan.lua` (reading files) and `omnisync/idstore.lua`
  (state). Packs keep each distinct record once.
- Separate stream, not new fields in existing `b` records, for the
  reason given in BOOKDATA.md: older versions would mark those segments
  seen without reading the new part.
- Each device sends a record for every book it has an MD5 for, the first
  time it sees that MD5. A few hundred bytes per book, once. As built:
  the EPUBs book data knows about (books opened on this device, from
  `book_files`); files Cloud library reports come with step 6.
- As built, reading files: the main process lists them and picks those not
  read before or changed since (path, size, time or sidecar MD5); the
  sync's subprocess reads them after the network step, for up to 60 s (5 s
  when the sync was asked for by hand) and never past ¾ of the network
  time limit. What it found is recorded when the sync finishes and sent
  with the next one. A 132-book device takes about 45 s in all, so the
  first automatic sync or two finish the job. Files that can't be read or
  have no UUID give no facts and aren't read again until they change.

### Which MD5 a record names

KOReader fixes a book's MD5 in its sidecar when the book is first opened
and keeps it when the file is replaced in place (checked 2026-11-06 on the
Forma: after replacing *Owned by the Alphas* with the rewritten download,
the sidecar still held the old file's `5c3574ce…`; the new file's partial
MD5 is `87f17347…`). Deleting the book in KOReader deletes the sidecar, so
a re-download after that gets the new file's MD5 on first open.

So a sidecar's MD5 may name a file that's no longer on disk. The other
streams file everything under the sidecar's MD5, so that stays the key.
But the UUIDs and signature are read from the file on disk, which may be
a different version or edition. When the file's own partial MD5 differs
from the sidecar's, send two facts: one under the file's own MD5 (its
UUIDs and signature), and one under the sidecar's MD5 with the same UUIDs
and **no signature** (`sig` left out: positions unknown). The sidecar's MD5
then joins its group at level 1. At level 2 it only joins if another
device recorded that MD5's signature from the original file.

## Local state

As built:

```
id_facts(md5, fact, src, uuids, sig, title, authors, ids, device)  -- merged facts
id_uuids(uuid, md5)                                  -- UUIDs per file
id_outbox(md5, fact)                                 -- facts not yet sent
id_scanned(path, md5, size, mtime)                   -- files read, as they were
```

`fact` is a fixed form of (md5, src, uuids, sig), so the same fact from
two devices is stored once; a fact received from another device leaves
this device's outbox.

Groups are connected components over shared UUIDs (union-find over
`id_uuids`, rebuilt in memory when facts change: a few thousand rows).
Level 2 is a group further split by `sig`.

## How each stream uses it

The principle: **records on the server stay under the MD5 they were made
with.** Joining happens on each device when merged data is read or
applied. No existing segment changes, devices without this version keep
working (they just don't join), and a link that arrives late needs no
rewrite of anything already sent.

### Book data (level 1)

When reading the merged value of a property for a local book, take the
last writer across all MD5s in its group, by the usual `(upd, dev, hash)`.
A change made here is still recorded under this file's MD5. Smallest
change of the three; do it first.

As built: the properties joined are `BookFormat.GROUP_PROPS` (status,
rating, review, custom metadata); the TOC and flows wait for level 2.
`IdStore:refreshGroups()` keeps `id_groups(md5, grp)` (groups passing the
guards only) at the end of each sync and returns the MD5s whose group
changed; `BookStore:regroup()` then looks again at their closed-book
writes, and they go into `run.book_affected` so the open book is
refreshed. Whether a local value changed is judged against the joined
value, so clearing a value that came from another version is recorded
even when this file's own records already hold an older clear.

### Statistics (level 1)

Today an incoming MD5 with no local book becomes a `foreign_books` row.
With identity:

- On import, an incoming MD5 in the same group as a local book's MD5 is
  merged into that local row (the existing "maps to the local row with the
  latest `last_open`" rule, widened from one MD5 to the group).
- When a link arrives after the events did: move the foreign row's
  `page_stat_data` into the local row (same dedup on
  `(page, start_time)`, longer duration wins), delete the foreign row,
  and **mark the moved events exported** under the local MD5, so they
  aren't sent back as this device's own (devices without the link would
  count them twice).
- Totals then come out right with KOReader's own queries, since they're
  per book row.

Caveat: `page` numbers are only comparable if the two files paginate
alike; KOReader rescales by `book.pages` anyway, and statistics are
already approximate across devices (DESIGN.md, item 8).

### Annotations, handmade TOC and flows (level 2)

When applying merged annotations to a local book, read
`ann_merged` for every MD5 with the same book ID **and** body signature.
Keys are creation times, so the same item never appears under two MD5s
except when one device replaced its file; then the usual last writer
rule picks one.

A local book without a signature yet (not scanned) joins nothing at this
level until it has one.

Records from a group member with a *different* signature (another
edition) are not applied. They could be shown later ("3 highlights from
another edition of this book"); out of scope here.

### Progress (level 2)

KOReader's progress sync keys by MD5 too, on its own server, so this is a
hook into the progress sync plugin (kosync.koplugin) rather than OmniSync's
data. As built (`omnisync/progresshook.lua`, installed at start when that
plugin is enabled): its client's `get_progress` is wrapped. When the book's
MD5 has level-2 peers (`IdStore:positionPeers`: same joined group, same body
signature), their positions are fetched too, one request each after this
MD5's, and the newest by the server's timestamp is handed back as if the
server had returned it. With no timestamps, this MD5's own position is
kept, else the furthest. The progress sync plugin then does what it always
does: same position, nothing; newer or older, jump or ask, by its settings.

- Not only a fallback, as first planned: once each version has a position
  of its own, a fallback would never look at the other one again.
- Read-only: pushes still go to this file's MD5 alone.
- This MD5's request failing (no network) is reported as before, without
  asking for the others. A peer's request failing is skipped.
- Books without peers make the one request they always did. A sidecar's
  MD5 without a signature of its own (a file replaced in place) has no
  peers, as for annotations.
- With "file name" chosen as progress sync's book identity, the key is
  a hash of the file name, which matches no MD5 here: nothing changes.

## Cloud library's side

Cloud library stays a separate plugin and uses OmniSync when it's present
(feature-detected on `ui.omnisync`, as with ZenOS).

Built so far, the other way round: Cloud library exposes
`Library.pathForUuids(uuids)` (the downloaded file or the cloud entry of
the catalog book with one of those UUIDs), which OmniSync's history sync
calls through `package.loaded["cloudlibrary/library"]` (see BOOKDATA.md,
Reading history).

OmniSync exposes (planned):

```
identity:groupFor(book_id)      -> { md5, ... }        level 1; book_id = any UUID in the group
identity:bookState(book_id)     -> { status, rating, last_read, devices }
identity:link(md5, book_id)     -- a match made outside the file (src "link")
identity:changed()              -- event after new facts or merged data
```

Cloud library then:

1. **Fixes its matcher**: strip `uuid:` as well as `urn:uuid:` (the
   rewritten test book has `uuid:…` and no longer matches by UUID today).
2. **Reports links** for local files it matched by title (PDFs, files
   without a UUID): partial MD5 from the sidecar if present, else
   `util.partialMD5(path)` (a few KB read), stored in `local_files`.
3. **Shows state on cloud-only books**: finished / reading / on hold
   badge, rating, "last read on <device>" in the details sheet, from
   `bookState`. Redraw on `changed()`.
4. **Downloads into an existing identity**: after downloading a book whose
   group already has data, open it and everything applies through the
   normal paths (annotations at level 2 once its signature is computed;
   compute it right after the download, before first open).

## Order of work

1. Matcher prefix fix in Cloud library (independent, small). **Done** (Cloud library 0.2.3).
2. Identity stream: OPF reading, signature, `id-` segments, merged
   facts, a Status line ("Books known in more than one version: n").
   No joining yet; run it on the devices for a while and check the groups.
   **Built.** The status screen shows files known and read, books in more
   than one version, books with different editions under one ID, and
   groups held back by the guards.
3. Book data joining (level 1). **Built** (2026-11-08).
4. Statistics joining, including the late-link move.
5. Annotations, TOC and flows joining (level 2).
6. Cloud library: links, `bookState`, badges and details.
7. Progress across versions. **Built** (2026-11-10), before 4 to 6.

Each step is shippable on its own; 2 changes no behaviour.

## Tests

- Unit: book ID parsing for all three prefix forms, unique-identifier vs
  other identifiers, signature equal across the tested rewrite (keep a
  stripped-down pair of fixture EPUBs: same body, Calibre 6 vs 9
  packaging) and different for a changed paragraph.
- Merge: id facts in every order and duplicated; `opf` beats `link`;
  conflicting links unjoined; guard on group size and titles.
- Statistics: link before and after events; moved events not re-exported;
  totals match KOReader's own query; a device without the link still sees
  no double counting.
- Annotations: two devices on the two versions converge; another edition
  in the group gets nothing.
- Integration (rclone WebDAV, as now): device A on old file, device B on
  rewritten file, both directions, plus a third device that only has the
  book in Cloud library and sees its status.

## Open questions

- Checked on one book: the OPDS entry ID is the Calibre library UUID,
  not the package unique identifier. Check a few books imported different
  ways (CWA ingest, Calibre desktop) to see whether both are always present.
- Edits keep the body (checked 2026-11-06): a tag edit and a cover change
  each rewrote the file (re-saved by Calibre 9.17), changing the MD5, but
  left the body signature unchanged (cover change: 86 of 88 spine files
  byte-identical, title page and jacket differ only in attributes).
  Unchecked: CWA's EPUB fixer on import, and format conversions.
