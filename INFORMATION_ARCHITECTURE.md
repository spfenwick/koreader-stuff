# Information architecture: Concordance, Athenæum and ZenOS

Review of 2026-11-17. Sources read: Concordance's DESIGN.md, IDENTITY.md and
BOOKDATA.md; Athenæum's `store.lua`, `library.lua`, `zenos_source.lua` and
`history.lua`; ZenOS's `common/book_sources.lua`,
`modules/filebrowser/metadata/service.lua` and `stats_tabs/books.lua`
(branch `custom`); concordance-web's README.

## How it's organised now

| Kind of data | Authoritative source | Local copy | Synced by |
|---|---|---|---|
| Static metadata (title, authors, series, tags, cover) | CWA, via OPDS | Athenæum's catalog DB, CoverBrowser cache, the EPUB's own OPF | Athenæum (reads the catalog) |
| Your metadata overrides | `custom_metadata.lua` | same | Concordance `meta.<key>` |
| Dynamic per-book data (status, rating, review, annotations, TOC, collections, history) | Sidecar or KOReader settings file on each device | `book_merged` in `state.sqlite3` holds the combined value | Concordance |
| Reading statistics | `statistics.sqlite3` on each device | same | Concordance `seg-` files |
| Progress | kosync server | sidecar | kosync, with Concordance's hook for other versions of a book |
| Identity (which files are the same book) | Concordance `id-` facts, plus links from Athenæum | `id_groups`, `id_pos` | Concordance |

What works well:

- **Each kind of data has a clear owner.** Athenæum owns the catalog and
  Concordance owns everything that changes as you read.
- **Identity sits in one place, Concordance.** Athenæum only supplies links,
  and the two plugins find each other through `package.loaded` in both
  directions, so neither needs the other.
- **Records on the server are never rewritten.** Joining happens on each
  device when the data is read, which makes ingesting on the server
  (concordance-web) straightforward.

## Inconsistencies and gaps, most serious first

### 1. Metadata edits go to three places, and only one of them syncs

- **EPUB files:** ZenOS's editor writes edits into the EPUB itself
  (`service.lua:615–631`) and then clears the matching `custom_props`. That
  causes three problems:
  - The edit never reaches other devices or CWA.
  - Concordance's check of closed books reads the cleared overrides as
    clears and sends them to other devices. Confirmed 2026-11-19 with a
    probe on Concordance's book-sync test harness: a book with a synced
    custom title and series, edited in ZenOS (authors only), sent two clears;
    the other device's `custom_metadata.lua` was removed and it showed its
    own file's title again. The edit itself (authors) was never sent. ZenOS
    clears every metadata key, not just the edited ones. A book with no
    overrides sends nothing.
  - The file's partial MD5 no longer matches its sidecar's MD5, which is the
    "file replaced in place" case. That book then loses position-level
    (level 2) joining.
- **KOReader's own book info dialog** writes `custom_metadata.lua`, which
  does sync.
- ~~Cloud books get a sidecar at their virtual path.~~ Correction: the
  editor refuses paths that aren't files (`service.lua`, `M.load`), so cloud
  books can't be edited at all.

**Fixed 2026-11-18 in Athenæum for the library folder; moved to Concordance
for every EPUB 2026-11-19 (Concordance 0.3.7, Athenæum 0.9.9; no ZenOS
change):** `concordance/metadatahook.lua` wraps ZenOS's `editsEmbedded`.
While book data can sync (a WebDAV server is set up), every EPUB keeps its
edits in `custom_metadata.lua`, so the edit syncs and no clears go out.
Athenæum's library-only hook (`Library.installMetadataHook`, Guard feature
`metadata`) is removed. If ZenOS drops `editsEmbedded`, the hook isn't
installed and Concordance reports it on its Status screen.
`tests/test_concordance_book.lua` covers the hook and checks that an edit
sends the change, not clears.

Still open:
- Books edited before the fix still have the edit embedded and a changed
  MD5.
- Cloud books can't be edited (above).
- ~~Whether CWA or the device should be the canonical place for edits.~~
  Settled with #2: CWA is the base, device edits are overrides on top.

### 2. Catalog changes don't reach books already downloaded

When a book is edited in CWA, the catalog and concordance-web show the new
metadata. A copy already on a device keeps its old embedded OPF, and ZenOS
shows that. Identity copes with the new MD5, but nothing refreshes what the
device displays.

**Fixed 2026-11-19 (Athenæum 0.9.10, no ZenOS change):** library books are
shown with the catalog's title, authors, series and tags, without touching
the file. Athenæum hooks KOReader's `FileManagerBookInfo.extendProps`, the
one place custom metadata is merged over a book's own: the catalog goes in
under the custom metadata, so the order is device override, then catalog,
then the file's OPF. The reader, CoverBrowser's cache (and so ZenOS's
groupings), history and search all go through it. After each catalog load,
`Library.refreshCatalogMetadata` updates CoverBrowser rows cached earlier
and tells ZenOS which books changed. Not overlaid: language (the reader
picks hyphenation by it) and description (not in the catalog listing). A
series number is used only when the catalog has one (CWA's feed doesn't).
This settles #1's open question: CWA is the canonical base, and device edits
are overrides on top that sync between devices but never go back to CWA.
Limitation: a field removed in the catalog stays in a cached row until
CoverBrowser re-extracts the book.

ZenOS's book-source rule (in its unmerged book-sources PR) now matches:
it used to put only edits made in ZenOS's editor on this device over a
source's metadata, so overrides from KOReader's Book information or synced
by Concordance were hidden. It now indexes any custom metadata announced
with KOReader's `InvalidateMetadataCache` event, which KOReader's dialog,
Concordance (`BookSync:_writeMeta`) and ZenOS's editor all send. So
everywhere the order is: custom metadata, then the source or catalog,
then the file.

### 3. Five different rules for deciding two things are the same book

- Concordance identity: UUID plus body signature.
- Concordance's title fallback for statistics (`Store.titleKey`).
- Athenæum's matcher: UUID, or title for files in the folder.
- concordance-web: UUID or `calibre:<id>`.
- ZenOS's stats tab for cloud books: catalog title and authors matched
  against the statistics `book` table (`stats_tabs/books.lua`).

The ZenOS rule is the weakest. Statistics titles are the file's title at
first open, or a custom title, so they often won't match the catalog's.
Asking Concordance by UUID would be better, either through the planned
`groupFor` or a stats lookup.

### 4. Two ways of putting cloud books into the reading history

Concordance writes cloud entries into `history.lua`, and Athenæum patches
`ReadHistory` (`_read`, `_flush`, `clearMissing`) to keep them there. ZenOS
now has a `book_sources.history()` hook built for exactly this, with its own
dismissal handling, but Athenæum doesn't use it. Choose one. The hook is
cleaner, but without the patches cloud books would disappear from KOReader's
own History view.

**Decided 2026-11-19: keep the patches; Athenæum doesn't supply
`history()`.** Cloud entries stay in `ReadHistory.hist`, because every
history view reads it. ZenOS's History tab is KOReader's `FileManagerHistory`
restyled, so it reads `ReadHistory.hist` directly. Only Home and the book
switcher go through `book_sources.mergeHistory`. With the hook alone, cloud
books would drop out of ZenOS's History tab as well as KOReader's. Removing
an entry already works: ZenOS's "Remove from history" removes it from
`ReadHistory` and calls `dismissHistory`, and Concordance doesn't put it back
unless the book is read again later. The cost is that Athenæum depends on
`ReadHistory` internals, which Guard turns off if they change.

**Added 2026-11-24: `history()` for the sync gap only.** Concordance doesn't
put books read elsewhere into `ReadHistory` while a menu or a book is open
(or in ZenOS's incognito mode); it waits for the next chance. Athenæum's
`history()` gives ZenOS just those waiting books
(`Identity.pendingHistory()`, kept by `HistSync:pending()`), so Home and the
book switcher show them meanwhile. Once they're in `ReadHistory`,
`mergeHistory` skips them. It never lists a book Concordance already put
in, so an entry removed from the history doesn't come back through it.

**Changed 2026-11-25 (Athenæum 0.10.0): one path per book.** A cloud
entry used to be at `<folder>/cloud-<id>.epub` and became the file's path
when the book was downloaded, so every download and delete swapped paths
in the history, collections and ZenOS's views. Now a book's path is where
its file is or would be ("Author - Title.epub", kept in the catalog DB as
`file_stem` / `file_ext`): the history entry stays put and only whether it
opens a file changes. Paths change only in rare cases, all through
`Library.booksMoved`. Identity is still the catalog ID and Concordance's
UUID/MD5 matching, never the path. Collections still lose a deleted book
(KOReader's collections can't hold a path without a file). See
STABLE_PATHS_PLAN.md.

### 5. Athenæum gives ZenOS less than the book-source contract allows

Its `status()` returns only `{status}`.

- `bookState` already has `rating`, and ZenOS's book details would show it.
- No `finished_at` is passed, so ZenOS's "finished this month/year" doesn't
  count books finished on another device. `bookState` doesn't return the date
  of the status change, although the merged record holds it (`updated`).

**Partly fixed 2026-11-18 (Athenæum 0.9.2):** `status()` now gives the
rating as well, and answers for the library's downloaded books that haven't
been opened here, not just cloud books.

**Fixed 2026-11-19:** Concordance's `bookState` now returns `status_at`, the
time of the winning status record (`updated`). Athenæum passes it to ZenOS
as `finished_at` for finished books, so books finished on another device
count in "finished this month/year". The date is when Concordance first
noticed the change (book closed, sync, or sidecar re-read), not the exact
moment the book was finished.

### 6. Two separate OPDS readers

Athenæum (on the device) and concordance-web (on the server) each read and
match the catalog themselves. concordance-web already runs Concordance's Lua
modules, but it doesn't run Athenæum's matcher, so their rules can drift
apart.

**Resolved 2026-11-19 (concordance-web 0.2.7):** the premise was mostly out
of date. The server has no book files, so it can't run a file matcher; it
already gets Athenæum's matches: title matches and PDFs arrive as
Concordance `link` facts in `id_uuids`, beside each EPUB's own UUID. The one
rule only the server had, matching a file by its `calibre:<id>`, is removed:
a Calibre book ID is only unique within one library, so it mostly matched
files from another library to the wrong book. Both sides now match a file to
a catalog book the same way: its UUID, or Athenæum's link. Each still reads
the catalog's metadata itself, which is fine: they both key it by the entry's
UUID.

### 7. Smaller points

- The review (`summary.note`) is synced but isn't available to cloud books.
- ZenOS counts "progress without a status" as reading, while Concordance
  treats a "reading" status as the weakest value. That's consistent today,
  but only because progress isn't synced (a deliberate decision).

## Suggested order

1. ~~#1~~ (clears fixed; canonical place for edits still open).
2. ~~#5~~ (done).
3. ~~#4~~ (decided: keep the patches).
