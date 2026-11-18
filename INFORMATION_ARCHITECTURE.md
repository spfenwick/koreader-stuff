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
  - Concordance's check of closed books will probably read the cleared
    overrides as clears, and send those clears to other devices (inferred
    from BOOKDATA's "a value gone is a clear"; not tested).
  - The file's partial MD5 no longer matches its sidecar's MD5, which is the
    "file replaced in place" case. That book then loses position-level
    (level 2) joining.
- **KOReader's own book info dialog** writes `custom_metadata.lua`, which
  does sync.
- ~~Cloud books get a sidecar at their virtual path.~~ Correction: the
  editor refuses paths that aren't files (`service.lua`, `M.load`), so cloud
  books can't be edited at all.

**Fixed 2026-11-18, in Athenæum only (no ZenOS change):**
`Library.installMetadataHook()` wraps ZenOS's `editsEmbedded` (Guard feature
`metadata`). While Concordance is installed, EPUBs in the library folder keep
their edits in `custom_metadata.lua`, which Concordance syncs. Books outside
the library are left to ZenOS, so they still embed edits and still have the
problems above. This depends on a ZenOS internal; if ZenOS changes it, the
startup check turns the feature off and shows it on the Status screen. Still
open: whether CWA or the device should be the canonical place for edits.

### 2. Catalog changes don't reach books already downloaded

When a book is edited in CWA, the catalog and concordance-web show the new
metadata. A copy already on a device keeps its old embedded OPF, and ZenOS
shows that. Identity copes with the new MD5, but nothing refreshes what the
device displays.

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

### 5. Athenæum gives ZenOS less than the book-source contract allows

Its `status()` returns only `{status}`.

- `bookState` already has `rating`, and ZenOS's book details would show it.
- No `finished_at` is passed, so ZenOS's "finished this month/year" doesn't
  count books finished on another device. `bookState` doesn't return the date
  of the status change, although the merged record holds it (`updated`).

**Partly fixed 2026-11-18 (Athenæum 0.9.2):** `status()` now gives the
rating as well, and answers for the library's downloaded books that haven't
been opened here, not just cloud books. `finished_at` is still missing.

### 6. Two separate OPDS readers

Athenæum (on the device) and concordance-web (on the server) each read and
match the catalog themselves. concordance-web already runs Concordance's Lua
modules, but it doesn't run Athenæum's matcher, so their rules can drift
apart.

### 7. Smaller points

- The review (`summary.note`) is synced but isn't available to cloud books.
- ZenOS counts "progress without a status" as reading, while Concordance
  treats a "reading" status as the weakest value. That's consistent today,
  but only because progress isn't synced (a deliberate decision).

## Suggested order

1. #1: it can lose data and send clears to other devices.
2. #5: small, and fills in data ZenOS already supports.
3. #4.
