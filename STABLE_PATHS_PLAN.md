# Plan: one path per book (Athenæum)

Written 2026-11-25. Not started.

## The problem

A catalog book has two identities in KOReader, depending on where it is:

- **On the device:** its file's path, `<folder>/Author - Title.epub`. The
  name is chosen once, at download (`Downloads.fileName`), and never follows
  later title changes.
- **In the cloud:** a made-up path, `<folder>/cloud-<id>.epub`
  (`virtual.lua`, `history.lua`).

Everything in KOReader and ZenOS is keyed on the path: history, collections,
To Be Read, ZenOS's cover and metadata caches, open group views. So every
download and delete switches the book's path, and a lot of code exists only
to carry state across that switch:

- `History.reconcile`: deleted file → cloud entry, cloud entry →
  downloaded file, plus `History.deleting` / `History.deleted`
- `history.lua`: `idOf`, `cloudPathFor` and the `cloud-` prefix parsing,
  `nameOf` / `label` (naming cloud entries, since their paths can't)
- `library.lua`: `showCloudInViews`, `cloudPathFor`, `homePaths`, and the
  `ZenSource.moved` calls in `Library.downloaded` and the delete hooks
- `zenos_source.lua`: `ZenSource.moved`, and ZenOS's `BookSources.moved`
  (ZENOS_PRS.md #4), which exists for this case
- Symptoms: "List (basic)" shows `cloud-<uuid>`. Any view that shows file
  names needs special handling.

## The rule

**A book's path is where its file is, or where its file would be.** The
first time a catalog book is seen, it gets a file name: the one
`Downloads.fileName` would give it, made unique in the folder. That name is
stored with the book and doesn't change when the catalog's title changes,
just like a downloaded file's name. The cloud entry is that path. Download
writes the file there, and delete brings the cloud entry back at the same
path.

The catalog ID stays the book's identity for Athenæum and Concordance (as
now). It becomes a field stored against the path, not part of the path.

## Design

### Stored name

A name has two parts, the same for every format:
`<stem>.<ext>`, e.g. `Author - Title.epub` or `Author - Title.pdf`.

- Schema 9: `file_stem` and `file_ext` columns in `books`.
- **The stem is the book's.** It's assigned once, using the current rules
  ("Author, Author - Title", FAT-safe), and never changes with the title or
  the format. A pure, unit-tested function assigns it,
  `Downloads.fileStem(book, folder, taken)`.
- **A stem clash gets a number** (`Author - Title (2)`). Clashes are
  checked on stems, not whole names: a stem is taken if any file in the
  folder or any assigned stem has it, whatever the extension. So a format
  change never needs a new number, and two books never share a stem.
- **The extension follows the format.** It starts as that of the format
  `Library.download` picks by default from the book's own formats
  (`Downloads.PREFERRED`), so a PDF-only book is `.pdf` from the start. It
  becomes whatever format is downloaded. KOReader picks how to open a file
  from its extension, so it must match the file's format.
- **Download uses the stored extension's format** when the book has it, so
  download → delete → download always lands on the same path.
- `Downloads.fileName` becomes `stem .. "." .. ext` (".kepub.epub" for
  KEPUB, as now).
- **When:** in `Library.load`, for books without a name, in one
  transaction. That's cheap (about 2,000 string operations on first run,
  then only new books), and it means every listed book has a name. The sync
  job doesn't need to change.
- **Matched books adopt their file's name.** When the matcher links a book
  to a file whose name differs (downloaded before this change, renamed by
  the user, copied from elsewhere), the stored stem and extension become
  the file's. So "path = file's path if on device, else stored name" holds for
  every book.

### Path changes become rare, and go through one routine

They still happen in a few cases:

- downloading a format other than the stored extension's (e.g. the PDF of
  a book that also has an EPUB): `Author - Title.epub` →
  `Author - Title.pdf`. The stem stays, and the stored extension becomes
  `pdf`. Deleting the file then brings the cloud entry back at the `.pdf`
  path, so there's no second move. This is the same rename KOReader
  itself handles, and the same kind of switch every download does today.
- the book's file renamed outside KOReader (e.g. over USB): on the next
  load the book adopts the new name, and its history and collection
  entries follow (an ordinary file's entry would just grey out)
- one of two copies deleted: the book adopts the other copy's name, and
  its entries move there instead of becoming a cloud entry
- an unrelated file turning up at an assigned name (see Risks)
- the one-time migration

Not used for: download and delete (same path; ZenOS is told the book
changed), title changes (the name is fixed), or renames inside KOReader
(KOReader updates history and collections itself; Athenæum only adopts the
name). Changing the library folder setting changes every path, but
downloaded files don't move with it, so old entries grey out as they do
today. That's out of scope.

`Library.bookMoved(old, new)` handles all of them:

- `ReadHistory:updateItem(old, new)`
- `ReadCollection:updateItem(old, new)`
- the saved `history_cloud` list
- `ZenSource.moved(old, new)`

That one routine replaces the download- and delete-specific code above.

### Download and delete (the common case)

The path doesn't change, but what's behind it does: catalog metadata
versus the file's metadata, cover, badge, and whether it opens. So:

- `ZenSource.changed({ path })` (ZenOS drops cached metadata and covers,
  and redraws)
- The history entry for the path: `select_enabled` and `dim` follow
  whether the file exists. This is a small loop, not a swap.
- `Library.unmatch` / `restoreMatched` stay, so the cloud entry is listed
  again at once after a delete. They no longer patch views.

### History before the catalog loads

Today `History.isCloudPath` recognises the `cloud-` prefix. Instead, the
saved `history_cloud` entries carry the catalog ID (`{ file, time, id }`),
and a path counts as a cloud entry if it's listed there and isn't a file.
`History.restore` and `undim` work as now.

### Listing

- `Virtual.setCatalog` builds `book.path` from `file_stem` and `file_ext`. `book.filename`
  and `PREFIX` go away.
- Don't list a cloud entry whose path is a real file the matcher didn't
  link to the book. `FileChooser:getList` already has the folder's files,
  so build a set from those (no extra stat calls).
- `signature()` includes the stem and extension, so ZenOS's cached listings (keyed on
  `listingKey`) are rebuilt after the migration.

### Migration from `cloud-<id>.epub`

This runs once, after the first load that has names (setting
`paths_version = 2`). For each catalog book, call
`Library.bookMoved(old_cloud_path, its path)`. This covers:

- KOReader's history (`history.lua` in settings)
- `history_cloud`
- collections, including ZenOS's To Be Read collection. Also check whether
  `zenos_tbr_order` stores paths.

Old entries for books no longer in the catalog stay greyed out, as now.
Concordance stores no cloud paths (`pathForUuids` is asked on each sync).
Confirm that while implementing. Keep the migration code for a few
releases.

## What goes away

- `history.lua`: `PREFIX`, `idOf`, `cloudPathFor`, `nameOf` / `label`,
  `History.deleting` / `History.deleted`, and the swaps in
  `History.reconcile`. What's left of reconcile: grey out books gone from
  the catalog, and the `select_enabled` / `dim` loop.
- `library.lua`: `cloudPathFor`, `showCloudInViews`, the path half of
  `homePaths`, and the `ZenSource.moved` calls in `Library.downloaded` and
  the delete hooks (replaced by `ZenSource.changed`).
- `virtual.lua`: `PREFIX`, `book.filename`.
- The `display_filename` idea (reverted 2026-11-25) isn't needed.
- ZENOS_PRS.md #4 (`BookSources.moved`): Athenæum still uses it, but only
  for rare path changes. Re-check whether it's worth keeping in the PR.

## What stays

- The matcher (files named the old way, renamed files, second copies).
- The catalog ID as identity, and Concordance's UUID/MD5 matching (not
  path-based).
- `unmatch` / `restoreMatched`.
- The DocSettings guard (no sidecar is written for a cloud entry), and the
  `hasBookBeenOpened` / `isFileInCollections` shortcuts.

## Risks to check

1. **ZenOS after a delete.** `group_view.lua`'s `refresh_after_delete`
   takes a deleted path out of open Authors/Series/... views if the file is
   gone. The cloud entry now has the same path, so it vanishes until
   `ZenSource.changed` makes ZenOS rebuild open group pages on the next
   tick. Check in the emulator. If it flickers or stays gone, the ZenOS
   fix is small: skip the removal when `BookSources.owns(path)`.
2. **Caches keyed on the path.** CoverBrowser's database has no row for
   the cloud entry and gets one when the file is extracted. ZenOS's caches
   hold the source's metadata until `changed()`. Every download and delete
   must call it, and so must the migration.
3. **An unrelated file at an assigned name** (e.g. the user copies in a
   different book with the same "Author - Title"). The listing skips the
   cloud entry (see Listing). On the next load the book gets a new name
   through `bookMoved`.
4. **KOReader's own delete** removes the file from collections
   (`ReadCollection:removeItems`). It does that today too. With a stable
   path we could keep the book in its collections as a cloud entry, but
   that's out of scope.
5. **Filename limits:** FAT-unsafe characters and long titles (255 bytes).
   `util.getSafeFilename` handles both. Add tests with long CJK titles.

## Steps

Each step should leave the plugin working, with tests. Run
`tests/athenaeum/run_tests.sh`, `scripts/test.sh` and
`scripts/test-concordance.sh` each time.

1. Schema 9, `file_stem` / `file_ext`, stem assignment with clashes checked
   on stems, adopting matched files' names. Unit tests: uniqueness, adoption, title change keeps the
   name, long and unsafe titles.
2. `Library.bookMoved`, with unit tests for history, collections and
   `history_cloud`.
3. Virtual and listing use stored names; skip real files; signature
   includes names. Migration (`paths_version`) in the same release, so no
   release has both schemes.
4. Download and delete without path swaps; the history `select_enabled`
   loop; saved history with IDs.
5. Remove dead code. Update the doc comments in `virtual.lua`,
   `history.lua` and `zenos_source.lua`, plus INFORMATION_ARCHITECTURE.md
   and ZENOS_PRS.md.
6. Emulator e2e: basic list names, download and delete from the folder,
   Home, Authors/Series (risk 1), History, To Be Read, collections, and
   migration from a profile with `cloud-` entries. Then on the Kobo.

## Decisions (2026-11-25)

- **Name scheme:** "Author - Title.<ext>" for every format, as downloads
  are named now. The stem is fixed per book, and a clash gets a number
  appended (` (2)`, ` (3)`...).
- **Other formats:** only the extension changes, through `bookMoved`, when
  a different format is downloaded (see above).
- **Migration:** Athenæum has one user, so there's no compatibility window.
  Keep the migration until it has run on that user's devices, then remove
  it along with the `cloud-` prefix.
- **Version:** 0.10.0.
- The UUID-as-file-name alternative was considered and dropped: files would
  be unreadable outside Athenæum, and too many KOReader views show file
  names.
