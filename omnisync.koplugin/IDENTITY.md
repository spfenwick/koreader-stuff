# Book identity across file versions (plan)

Status: plan, not built. Written 2026-11-06.

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
MD5 so never repeated. To be measured on the Forma before building on it
(a 1 MB EPUB should be well under a second).

Files that aren't EPUB: no book ID from the file in this version. Cloud
library can supply one (below); PDFs then join at level 1 only (page
positions survive a metadata rewrite, but nothing here checks it).

## Sync format: a fourth stream

`id-NNNNNNNNNN.jsonl.zst` in each device folder, own numbering, same
rules as the other streams (header, trailer, strict validation, unknown
major version rejected):

```
{"t":"h","format":"statsync-id","v":1,"minor":0,"device":"…","created":…}
{"t":"i","md5":"…","uuids":["333d496c-…","dd15c660-…"],"sig":"…","src":"opf",
 "title":"…","authors":"…","ids":["calibre:4644","isbn:9780195056440"]}
{"t":"end","records":n}
```

- A record is a fact about a file: "the file with this MD5 carries this
  book ID and body signature". Facts don't change, so the merged state is
  a grow-only set: no timestamps, no deletions, order-independent and
  idempotent by construction.
- `src`: `opf` (read from the file) or `link` (supplied by another plugin,
  e.g. Cloud library matching a PDF by title). For one MD5, `opf` wins
  over `link`; two different `opf` records for one MD5 can't happen
  (same bytes); two `link`s naming different catalog books leave the MD5
  unjoined.
- Separate stream, not new fields in existing `b` records, for the
  reason given in BOOKDATA.md: older versions would mark those segments
  seen without reading the new part.
- Each device sends a record for every book it has an MD5 for (sidecars in
  the history, plus files Cloud library reports), the first time it sees
  that MD5. A few hundred bytes per book, once.

## Local state

```
id_files(md5, sig, src, title, authors, ids)        -- merged facts
id_uuids(md5, uuid)                                 -- UUIDs per file
id_outbox(md5)                                       -- facts not yet sent
id_scanned(path, size, mtime, md5)                   -- files read for IDs
```

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

### Progress (level 2, optional, last)

KOReader's progress sync keys by MD5 too, on its own server, so this is a
hook into the KOSync plugin rather than OmniSync's data: when opening a
grouped book, if the server has no progress for this MD5, ask for the
other MD5s in its level-2 group and take the furthest/newest. Read-only,
fallback only; a few extra requests on open. Decide after the rest is in
use.

## Cloud library's side

Cloud library stays a separate plugin and uses OmniSync when it's present
(feature-detected on `ui.omnisync`, as with ZenOS).

OmniSync exposes:

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

1. Matcher prefix fix in Cloud library (independent, small).
2. Identity stream: OPF reading, signature, `id-` segments, merged
   facts, a Status line ("Books known in more than one version: n").
   No joining yet; run it on the devices for a while and check the groups.
3. Book data joining (level 1).
4. Statistics joining, including the late-link move.
5. Annotations, TOC and flows joining (level 2).
6. Cloud library: links, `bookState`, badges and details.
7. Progress fallback, if still wanted.

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
- Signature cost on the Forma, and whether CWA rewrites ever touch body
  markup (e.g. its EPUB fixer on import): test a few more edits, including
  a cover change.
- Whether KOReader keeps the old `partial_md5_checksum` when a file at the
  same path is replaced (ANNOTATIONS.md says the MD5 is fixed at first
  open); if so a re-download in place keeps the old identity and only
  fresh devices diverge.
