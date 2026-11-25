# ZenOS PRs that would simplify the plugins

Changes to ZenOS that would fix something in ZenOS itself *and* let
Athenæum or Concordance drop a hook. Written 2026-11-19, against the
book-sources work (`book-source-enhancements` in the zen-os fork, merged
upstream as #892 on 2026-11-17). Base each PR on upstream's `dev`.

Each entry: what's wrong in ZenOS, the fix, and what goes away in the
plugins. When one merges, remove the plugin code and update this file.

Suggested order: 1, 3, 4, 5, 6, 7, then 8 after talking to the maintainer (2 is no longer
needed by the plugins).

Open upstream (2026-11-25):
- [#911](https://github.com/xZenLabs/zen-os/pull/911) "Ask book sources when
  opening or long-pressing a book anywhere" (branch `book-source-long-press`):
  #1.
- [#912](https://github.com/xZenLabs/zen-os/pull/912) "Refresh open views
  when book sources report changes" (branch `refresh-views`): #3 and the
  views part of #4.

Next: #5 (badges), once those two are merged.

## 1. Opens and long-presses ask the book sources everywhere

**In ZenOS:** only Home asks `BookSources.open` / `showContextMenu`
(`home_page.lua`). To Be Read and collections (`collections.lua`, three
`showFileDialog` calls) and end-of-book "next in series" (`end_book.lua`,
`filemanagerutil.openFile`) go straight to KOReader's path, so a source's
book (Kindle's too) opens or long-presses differently there.

**Fix:** ask the sources inside ZenOS's existing wrappers:
`filemanagerutil.openFile` in `modules/filebrowser/patches/status_on_open.lua`
and `showFileDialog` in `modules/filebrowser/patches/context_menu.lua`. That
covers every caller. When a source handles an open, ZenOS cancels its own
opening banner.

**Status (2026-11-25):** PR open upstream,
[#911](https://github.com/xZenLabs/zen-os/pull/911) (branch
`book-source-long-press`, from upstream `dev`, with CodeRabbit fixes), and on
`custom` (986a2ec9). `BookSources.open` and `showContextMenu`
are asked from the `openFile` and `showFileDialog` wrappers; they guard
against re-entry (a source's handler that opens a file or shows ZenOS's
dialog, as the Kindle source does, gets ZenOS's own), and `open` cancels the
opening banner when a source handles it. Dialogs the Kindle library asks for
itself (`_zen_kindle_book`) aren't sent back to it.

Athenæum 0.9.15 assumes a ZenOS with this change (no feature detection:
install the ZenOS update first) and has dropped the hooks below, plus its
file browser tap and long-press hooks (`installSelectAndHold`,
`isVirtualItem` in `athenaeum/virtual.lua`); checked in the emulator
2026-11-24. Still there: `cancelZenOSOpeningBanner`, since Athenæum's own
History view hook and search results show details without going through the
sources.

**Plugins lose:** in `athenaeum/zenos_source.lua`, `wrapOpenFile`,
`wrapFileDialog` and `ensureOutermost` (re-wrapping outermost whenever ZenOS
rebuilds a grouping). In `athenaeum/virtual.lua`, `cancelZenOSOpeningBanner`
(the `__ZEN_UI_CANCEL_OPENING_BANNER` global), once nothing shows details
outside the sources (see the status above).

## 2. History changes in the middle are noticed

**In ZenOS:** the "last read" index memo
(`browser_item_table_cache.lua`, `history_time_map`) compares only the
history's length and its first and last entries. Home's dataset signature
(`home_page.lua`, `home_dataset_signature`) has the same blind spot. An
entry moved or retimed in the middle goes unnoticed until the history is
reloaded.

**Fix:** a cheap fingerprint (e.g. the sum of the entries' `time`), or a
revision bumped from `ReadHistory:_flush`. Neither needs the realpath walk
the memo exists to avoid.

**Status (2026-11-25): not needed by the plugins.** #3's
`BookSources.historyChanged` drops the memo (on the `refresh-views` PR
branch, #912, even with no file browser open, e.g. in the reader; `custom` drops it
only when the file browser exists). Both plugins now call it instead of
`rh:reload(true)`: Concordance's `refreshAfterHistory` tells ZenOS first and
leaves the file browser's redraw to it; Athenaeum's `History.reconcile` and
`History.moved` pass the paths they changed. Checked in the emulator
(`tests/athenaeum/e2e_history_order.py`, a retime and a move in the middle
of the history, sorted by last read; each also run without the
notification, which shows the stale order).

The memo goes stale only when nothing re-reads history.lua in between:
KOReader's `_flush` doesn't update `last_read_time`, so the next `reload()`
usually re-reads it (new tables, memo missed), unless the save falls in
the second it was last read (FAT32's 2 s times make that likelier on a
Kobo). Since stable paths (Athenaeum 0.10), a delete keeps the book's path
and time, so it never needed this.

A fix inside ZenOS would still help changes nobody reports (another
plugin, an edited history.lua), but that's optional.

## 3. Home refreshes itself when the sources report changes

**In ZenOS:** there's no public way to tell Home a book changed. Both
plugins reach into `FileManager.instance.zenos`, then
`shared_state.get(…, "home")`, and call `invalidateBookCache`,
`rebuildActive` and `isActiveOnTop` themselves.

**Fix:** `BookSources.changed(paths)` and `statusChanged()` invalidate Home's
cache for those paths and rebuild it (now if it's on top, else when it's
next shown). Add `BookSources.historyChanged(paths)` and a public
`isHomeOnTop()`. The Kindle source gets Home refreshes for free.

**Status (2026-11-25):** PR open upstream,
[#912](https://github.com/xZenLabs/zen-os/pull/912) (branch `refresh-views`,
with CodeRabbit fixes), and on `custom` (3b30448d). Athenæum and Concordance now use `BookSources.changed`,
`statusChanged`, `historyChanged` and `isHomeOnTop` and assume a ZenOS with
this change (no feature detection). Removed: Athenæum's `refreshHome`
(downloads and deletes call `ZenSource.changed(paths)`, "Remove from
history" calls `historyChanged`) and the "older ZenOS" fallback in
`statesChanged`; `homeOnTop` is now a wrapper over `isHomeOnTop`.
Concordance's `zenHome()`, its Home part of `refreshAfterHistory` (now
`historyChanged(paths)`) and the four `zenos:*` problem reports are gone.

**Plugins lose:** `refreshHome` and `homeOnTop` in
`athenaeum/zenos_source.lua`. In `concordance/plugin.lua`, `zenHome()`,
Home's part of `refreshAfterHistory`, and the `zenos:home`,
`zenos:isActiveOnTop`, `zenos:invalidate` and `zenos:rebuild` problem
reports.

The largest of these, and the one upstream is most likely to want to
discuss.

## 4. A download updates the cached listing instead of rebuilding it

**Done:** ZenOS's open views (group pages and their book lists, To Be
Read, the file browser) refresh when a source calls `changed(paths)`. This
is in [#912](https://github.com/xZenLabs/zen-os/pull/912), with #3.
Athenæum's `replaceInViews`, `swapInItem` and `ZenSource.downloaded`,
which edited ZenOS's private fields, are gone. A `moved(old, new)` call
isn't needed: since Athenæum 0.10 (STABLE_PATHS_PLAN.md) a book keeps its
path when it's downloaded or deleted, and the rare real path changes happen
during a catalog load, where `changed({ old, new, … })` covers them.

**Still to do in ZenOS:** a download rebuilds the library folder's whole
listing (about 2,150 entries on the Kobo, with "Rebuilding library…").
ZenOS's cached listing (`browser_item_table_cache.lua`) is keyed on two
things a download changes:

1. the stable key, which includes `BookSources.listingKey`. Athenæum's
   key (`Virtual.catalog_sig`) changes because the book leaves the cloud
   list;
2. the folder's `directory_signature` (mtime, ctime, size, inode), which
   changes when the file is written.

The plugin can't avoid this. The folder signature changes whatever the key
does (ctime can't be set back). Editing the cache would mean reaching
ZenOS's `shared_cache` local through `debug.getupvalue`. Skipping the
refresh only delays the rebuild, and `history_reorder` (back from the
reader) needs the key to match.

**Fix:** on `changed({ path })` for a book in a cached listing, ZenOS
updates that one entry in place (metadata, cover, badge), in memory and in
the saved copy. It moves the entry only if the sort needs it, and stores the
current key so the next listing is a cache hit. Sorting by date added or
last read leaves it in place: Athenæum sets a downloaded file's date to the
date the book was added. Sorting by name can't move it either, because the
path doesn't change.

Things to watch:
- Re-key after the file is renamed into place, or the FAT32 2 s window in
  `changed_near_scan` marks the listing stale.
- Download & read: the first open creates the `.sdr` folder, changing the
  folder again. Sorted by last read, `history_reorder` ignores that while
  the key matches. Not checked for other sort orders.
- Time a download's listing before and after in the emulator.

**Plugins lose:** the full listing rebuild after every download. Kindle and
any other source get the same.

## 5. Book sources give cover badges

**In ZenOS:** a source can't mark its books' covers. Athenæum paints its
badges after ZenOS does: it wraps `BookList`/`Menu:paintTo` and searches
the widget tree for each item's cover, and for Home it wraps
`cover_common.make_cover_widget` and walks `debug.getinfo` up the call
stack, looking for `/patches/home/widgets/` in the callers' file names.
Both break without an error when ZenOS reorganises its files or widgets.
Painting after ZenOS also lands on ZenOS's own badges: Athenæum's goes in
the bottom-right corner, where ZenOS puts the series number.

**Fix:** an optional source function `badge(path)` → `{ icon = svg path }`
and `BookSources.badge(path)`. A new `common/source_badge.lua` paints the
icon's dark shapes in ZenOS's badge colours and size (`getBadgeColor`,
`getBadgeTextColor`, `getBadgeScale`), in a circle in the cover's
bottom-right corner. When ZenOS's series number is there, it stays in the
corner and the source badge moves left of it. The source badge never
covers ZenOS's badges along the bottom (the series number, the page-count
pill on the left): on a cover too small for it beside them, it's left out. Painted on library mosaic items
(`zen_renderer.lua`), list covers (`browser_list_item_layout.lua`), Home
strips (`strip_common.lua`: only when the strip's "Show badges" is on), the
featured book (`featured_common.lua`) and the book switcher
(`book_switcher_page.lua`), the last two through `make_cover_widget`'s
`decorate` (neither shows ZenOS's own badges or has a setting for them).
`statusChanged()` repaints after a source's badges change.

**Status (2026-11-25):** committed on ZenOS `custom` (f79e8702, "Book
source badges"; no PR branch yet), to be opened once #911 and #912 are
merged (`common/source_badge.lua`, spec `spec/lua/unit/source_badge_spec.lua`).
Athenæum 0.9.20 gives `badge()`, assumes a ZenOS with it (Guard's startup
check turns badges off without it), and has dropped its Home badge hook,
the stack walk and its cover painting; it paints only KOReader's plain list
rows (no covers) itself. Not yet checked in the emulator with cloud books.

**Plugins lose:** `Badge.installHome`, `forHome`, `badgeHomeCover`,
`coverRect` and `Badge.place` in `athenaeum/badge.lua`.

## 6. Book sources' books without a file appear in folder listings

**In ZenOS (before):** a source's books appeared in the Authors, Series, Tags
and Languages tabs, Home, To Be Read and the book switcher, but not in a
folder's listing. `listingKey()` only keyed ZenOS's listing cache; the
source had to add the books itself, "e.g. by wrapping FileChooser:getList".
Athenæum did that with its most fragile hook: building items with
KOReader's `getListItem`, faking file attributes, padding counts with
`true`, swapping `ui.bookinfo.getDocProps` for the metadata sorts, and
bypassing `show_file`, so the status filter didn't apply to cloud books.

**Fix:** no new source function. A book in a source's `books()` whose path
has no file on disk is listed in its parent folder, as a file would be:
- through `show_file`, so the status filter (from `status()`) applies;
- built with `getListItem`, with `doc_props` from `bookInfo()` or the
  book's `info`, so every sort and the series grouping work;
- counted in the folders above, and in flat view;
- skipped when the path is already listed as a real file.

A book entry may give `attr = { size, modification, access, change }` for
the date and size sorts. Books with a file (the Kindle library's) are listed
where they are, as before. `listingKey()` stays: it keys the saved listing
cache, which outlives a run.

**Status (2026-11-26):** dropped. Built on ZenOS `custom` and then
discarded: about 275 lines of ZenOS code, and a rule that any listed item
may have no file behind it, for a single source. Athenæum 0.10.7 is back to
adding the cloud books itself (`addCloudItems`, the count padding and
`withCloudDocProps` in its `getList` hook). The "Include cloud books in
Authors, Series and Tags" (`zenos_groups`) and "Show cloud books" (`show`)
settings are gone: cloud books are always listed, and always in the groups.
It now asks the
browser's `show_file` too, so the status filter applies to cloud books, in
the listing and the count. The rest of what the ZenOS change fixed is lost
again: flat view and folder covers (count, images, "all finished") don't
see cloud books. The notes below
describe the discarded version, in case it's revisited.

ZenOS (`common/book_sources.lua` unless noted):
- `folderBooks(folder)`: `books()` indexed by folder, only books their own
  source `owns()` (so taps, long-presses and file operations go to the
  source; a book without a file never reaches code that needs one). Rebuilt
  when `revision()` changes, so a source must call `changed()` when its
  books do. A path given twice is listed twice (no dedupe across sources:
  only one source has books without a file).
- `visibleFolderBooks(chooser, folder, present)`: the ones without a file
  that pass `show_file`. Every ZenOS scan that lists a folder's books uses
  it: `addToListing` (the `getPathList` wrapper, `installListingIntegration`),
  the flat view's `scan_flat`, and folder covers (`folder_cover.lua`: count,
  cover images, "all finished", and the descriptor cache key includes
  `listingKey`). Before, folder covers scanned with `lfs.dir` and missed
  them: a wrong count with a status filter, cloud books never used for the
  images, and a folder marked finished while it held unread cloud books.
- `addToListing` marks items `_zen_source = id`, adds a folder once per
  listing (either install order works).
- Covers stay the source's business: CoverBrowser asks to extract a book
  whose `bookInfo()` leaves `cover_fetched` nil, and a source that fetches
  covers some other way catches that itself (Athenæum hooks
  `extractInBackground` / `isExtractingInBackground`). A `fetchCovers`
  contract with a `COVER_WAIT` timeout was tried and taken out again: one
  source used it, and it moved Athenæum's own "downloading" state into a
  timer in ZenOS.
- `getDocProps` skips CoverBrowser's database for a book without a file.
- Specs: unit specs for all of the above; `book_listing_scans_spec.lua`
  classifies every `lfs.dir` user in ZenOS and fails on a new one (a book
  scan must ask the book sources); `integration/book_sources_listing_spec.lua`
  runs KOReader's real `filechooser.lua` (only device, BookList's base and
  UIManager stubbed) and checks counts, `getListItem` items and filters, so
  a KOReader change there fails when ZenOS's pinned KOReader is updated.
  Lua suite: all pass apart from 2 updater specs that fail without these
  changes too.

Athenæum 0.10.3 (uncommitted) needs a ZenOS with it (Guard's startup check:
`addToListing`, `folderBooks`). It dropped `addCloudItems`,
`withCloudDocProps`, the count padding and the "Include cloud books in Authors, Series and
Tags" setting (`zenos_groups`): `books()` gives the folder listing too, so
the two can't differ. `books()` gives `attr` (date added, size). Its
`getList` hook remains, slimmed down: the "Rebuilding library…" message
and the badge indent for plain list rows, on items ZenOS built. Still its
own: the `extractInBackground` / `isExtractingInBackground` hooks (cloud
covers are downloaded; 0.10.4–0.10.5 used a ZenOS `fetchCovers` instead,
back in Athenæum since 0.10.6), the `hasBookBeenOpened` / `isFileInCollections` shortcuts
(`getListItem` asks both per item) and its search results (#7).

Emulator: a test source (scratch script) listed by name and title, the
status filter, a subfolder's count, flat view; Athenæum's covers
downloaded from a local server (through `fetchCovers`, before 0.10.6), with no extraction
errors (scratch script); `e2e_stable_paths.py` and `e2e_history_order.py`
pass.

Remaining fragility in ZenOS, for the PR description:
- ZenOS lists items with no file. The paths that need a file are covered
  (taps, long-presses and file operations go to the owning source; covers
  by the source's own extraction hook; book scans through
  `visibleFolderBooks`, enforced by the scan spec), but new code that takes
  a listed item's path to the disk must allow for it.
- `lfs.dir` users classified as "not a book scan" in the spec are trusted
  to be right (e.g. `cover_utils.lua`'s fallback without a file chooser).

## 7. Book sources' books without a file appear in search results

**In ZenOS:** #6 lists a source's books without a file in folder listings,
but not in file search. KOReader's `FileSearcher:getList` walks folders
itself with `lfs.dir` and never calls `FileChooser:getPathList`, and
ZenOS's search patch (`modules/filebrowser/patches/search.lua`) only runs
that walk once per search root. So search finds real files only. Tapping or
long-pressing a result with no file does nothing: KOReader's
`FileSearcher:onMenuSelect` / `onMenuHold` return early when the path
doesn't exist, before `filemanagerutil.openFile` / `showFileDialog`, where
ZenOS asks the sources (#1).

So Athenæum hooks KOReader's search (`athenaeum/search.lua`): it adds the
matching cloud books (title, authors, series, with KOReader's case and
wildcard options) after the files found, shows them instead of "No
results", and shows a cloud result's details on tap and long-press. Those
are `onShowSearchResults`, `showSearchResultsMessage`, `onMenuSelect` and
`onMenuHold` hooks, relying on the static `FileSearcher.search_results`,
`self._manager` and the order of those calls, which KOReader reworks fairly
often.

**Fix:** in ZenOS's `FileManagerFileSearcher:getList` wrapper, for each
folder searched (with subfolders when the search includes them), add the
sources' books without a file (`BookSources.folderBooks`, skipping paths
the walk found) whose file name matches, or, with metadata search on, whose
`info` matches (`bookinfo:findInProps`, as KOReader does for files). They
go through `show_file` and come back in KOReader's result shape (`{ name,
fullpath, attributes }`, attributes from `attr`), so KOReader builds the
items and sorts them with the rest. Tap and long-press on a result with no
file that a source owns go to `BookSources.open` / `showContextMenu`.

Things to watch:
- KOReader caches results (`search_hash` / `search_results`): a source's
  `changed()` should drop them, or a book downloaded since shows twice
  (Athenæum's hook re-checks cached results today).
- `no_metadata_count` ("N files without metadata"): source books have
  metadata, so they shouldn't add to it.

**Plugins lose:** `athenaeum/search.lua` apart from its setting ("Include
cloud books in file search", which would then have to become a source
option or go, as `zenos_groups` did in #6), and with it `Virtual.listItem`
(search's only user) and the `getListItem` dependency in Guard's startup
check. Every source's books become searchable, not just Athenæum's.

Not started.

## 8. ZenOS builds the Library's folder contents itself

**In ZenOS:** the Authors, Series, Tags and To Be Read views are ZenOS pages
built from data (`db_bookinfo.lua`: CoverBrowser's database plus
`BookSources.books()`), so source books just work there. The Library tab is
KOReader's `FileChooser` inside `FileManager`. ZenOS already owns most of
it (`browser_item_table_cache.lua` wraps `genItemTableFromPath`, plus its
rendering, series grouping, flat view, filters and folder covers), but on
a cache miss it still asks KOReader to build the folder's contents:
`getList` → `getPathList` → `getListItem`, one item at a time. Every
KOReader listing hook (ZenOS's from #6, Athenæum's slim `getList` hook and
its `hasBookBeenOpened` / `isFileInCollections` shortcuts) sits in that
step.

**Fix:** keep KOReader's `FileChooser` as the frame, and on a cache miss
build the item table in ZenOS instead of calling KOReader's
`genItemTableFromPath`:
- the folder's files and subfolders from one `lfs.dir` read (the
  attributes it already reads);
- metadata from CoverBrowser's database for the whole folder
  (`db_bookinfo.getLightMetadata(directory)` already does this);
- the book sources' books without a file (`visibleFolderBooks`), with no
  `getListItem` stand-ins;
- the item fields set directly (`opened` from the folder's sidecars,
  collections once per listing), so no per-item `hasBookBeenOpened` /
  `isFileInCollections`;
- the filters in one place (hidden, unsupported, `exclude_files`, status).

Navigation, file operations, select mode, the long-press dialog and the
about 55 places where KOReader and its plugins call `refreshPath` or
`changeToPath` (search's "go to folder", history's "show in folder", OPDS
and Calibre after a download, Athenæum and Concordance) stay KOReader's.

**Why not a separate Library page** like the group views: it would have to
reimplement folder navigation, sorting, filters, display modes, select
mode, file operations and the long-press dialog, and keep a ZenOS page in
step with every `refreshPath` / `changeToPath` caller. Plugins and user
patches that hook the file chooser (CoverBrowser's display modes among
them) would stop affecting it. Probably as big as `group_view.lua` plus
most of `browser_item_table_cache.lua`, with the largest regression risk
of anything here.

Things to watch:
- KOReader's item shape and listing features become ZenOS's to follow:
  new sort orders, new filters, `show_filter` types.
- Patches and plugins that hook `getList` / `getPathList` stop affecting
  the Library.
- Edge cases KOReader handles today: unreadable folders on Android
  (`unreadable_dir_content`), folders reached through symlinks, hidden
  files, macOS `._` files, "show unsupported files", flat view.
- Check with the maintainer first: it moves the decision about what a
  folder contains from KOReader to ZenOS.

**Plugins lose:** Athenæum's slim `getList` hook (if ZenOS sets the
plain-row badge indent itself) and its `hasBookBeenOpened` /
`isFileInCollections` shortcuts. ZenOS loses the `getPathList` wrapper
and `getListItem` stand-ins from #6. Listings, folder counts, folder
covers, flat view and search (#7) could share one folder index instead of
each scanning folders. Likely faster on the Kobo (one directory read plus
one database query per folder, instead of per-item lookups for about
2,150 books).

#6 and #7 are useful either way: this would mostly reorganise their code,
not replace it. Probably a few hundred lines plus specs, mostly in
`browser_item_table_cache.lua` and a new item builder.

Not started.

## Not worth a PR

- **Each book once per tag** (dropped 2026-11-24): this listed ZenOS's
  `getGroupedByTags` as adding a book once per repeat of a tag in its
  keywords. That was never shown: the Kobo's CoverBrowser database has no
  book whose keywords repeat a tag after ZenOS's split and trim, and no
  repeated paths, so ZenOS lists each book once. Athenæum's `hookTags` /
  `dedupeTags` were removed in 0.9.14. If books show twice under a tag
  again, find the cause before raising anything. (A book whose file was
  saved under a second capitalisation has two CoverBrowser rows, and ZenOS
  lists it twice in every tab; that's a different problem.)

- **`editsEmbedded`** (`concordance/metadatahook.lua`): a ZenOS setting for
  writing edits into the EPUB would help users, but Concordance would still
  have to override it while sync is on.
- **Details sheet styling** (`athenaeum/details.lua`, ZenOS's
  `inline_icon_map` and `library_font`): a public style helper would be
  tidier, but the gain is small.
