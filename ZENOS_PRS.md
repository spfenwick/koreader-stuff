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
pill on the left): on a cover too small for it beside them, it's left out.
Painted on library mosaic items (`zen_renderer.lua`), list covers
(`browser_list_item_layout.lua`), Home strips (`strip_common.lua`: only
when the strip's "Show badges" is on), the featured book
(`featured_common.lua`) and the book switcher (`book_switcher_page.lua`),
the last two through `make_cover_widget`'s `decorate` (neither shows
ZenOS's own badges or has a setting for them). `statusChanged()` repaints
after a source's badges change.

Details settled in review (2026-11-26):
- The featured book and book switcher ask for the badge each time a cover
  is painted (every cover gets `decorate`), so a badge a source gives
  after Home or the switcher was built still shows.
- `BookSources.badge` logs a failing `badge()` once and skips that source
  until it calls `statusChanged()` or is registered again: `badge()` runs
  on every cover paint, so each failure would otherwise log per cover per
  repaint.
- List covers too small for the badge at full size
  (`SourceBadge.fits()`: the cap of 45% of the cover's shorter side would
  shrink it) get no badge, rather than one hiding much of the cover.
- Group and folder covers (several books, or none) get no badge; the API
  comment says so.
- In the detailed list, the source badge is the only badge on the cover:
  the list shows ZenOS's own (series, read status/progress, pages) as row
  text, and a source badge has no text form. Kept on the cover, rather
  than as an icon in the row's right column, by choice.
- No ZenOS setting turns the badges off: sources decide (Athenæum's
  `badge_cloud`, `badge_local`, `badge_noncloud`). A toggle was tried and
  removed; say so in the PR description in case a reviewer asks.
- The mosaic's "Show progress bar" used to sit under the bottom row of
  badges (the page count, the series number, and so the source badge):
  an existing ZenOS bug that CodeRabbit flagged on the source badge
  (2026-11-26). Fixed for the whole row in a separate commit on `custom`,
  "Lift badges above progress bar" (4a8120a3): while the bar is shown, the
  row moves up as one, to sit above the bar's top as it would above the
  cover's bottom edge (`bottom_row_lift()` in `zen_renderer.lua`;
  `SourceBadge.paint` takes the lift). It fixes ZenOS on its own, so it
  could go upstream as its own PR, ahead of or with this one.
- From CodeRabbit (2026-11-26): `SourceBadge.shift`'s gap is the space
  between the badges' 2px outlines, so the source badge and the series
  number don't touch on small covers; the book switcher passes its config
  to `SourceBadge.decorate`.
- The icon mask cache empties all at once at 64 entries, as ZenOS's other
  small caches do (`icon_packs.lua`, `folder_cover_files.lua`, …); a few
  icons × a few cover sizes stays well under that.

Known gaps, not fixed:
- `statusChanged()` rebuilds groupings and Home's cached data when a
  badge change only needs a repaint. A lighter `badgesChanged()` could
  repaint, call `SourceBadge.clear()` and reset the failed sources.

**Status (2026-11-26):** committed on ZenOS `custom` as "Book source
badges" (77f2e7c8 on 2026-11-26; amended in place, so find it by name; no
PR branch yet), to be opened once #911 and #912 are merged
(`common/source_badge.lua`, spec `spec/lua/unit/source_badge_spec.lua`).
Its specs pass, and luacheck finds nothing in its files (the zen-os
checkout's two `book_sources.lua` warnings, `reader_settings` shadowing,
are from 6b81afc2, before it).
Athenæum 0.9.20 gives `badge()`, assumes a ZenOS with it (Guard's startup
check turns badges off without it), and has dropped its Home badge hook,
the stack walk and its cover painting. Since 0.10.8 it paints no badges
of its own at all: KOReader's plain list rows and other non-ZenOS views
show none (the `BookList`/`Menu:paintTo` hooks, the row indent and their
startup check are gone). Not yet checked in the emulator with cloud books
(colour screens, night mode, small list rows).

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

**Status (2026-11-26, rebuilt):** a simpler version on `custom`,
uncommitted, no PR branch yet: about 255 net lines of ZenOS code (+296 −39)
plus specs, against about 275 for the discarded one. Simpler in kind more
than size: no item marking, no new contract for covers, one lookup function.
The code doesn't need #911 or #912, but it should land after #911: without
it, taps and long-presses in the file browser don't go to the sources, so a
generic source's book would try to open a missing file (Athenæum catches
opens itself). The single-client concern doesn't apply: book sources was
accepted with Athenæum as its only client outside ZenOS.

- A source may declare `fileless = true`: its `books()` only has books with
  no file on the device, all owned by it. That's the opt-in for folder
  listings, and it lets ZenOS count those books without checking for files.
- `BookSources.booksWithoutFile(folders, present, fileless_only)`: the
  owned books in the given folders that the scan didn't find as files.
  Without `present` (a count), fileless sources' books only. Looked up in an
  index by folder per source, built on first use after the books changed
  (`revision`: sources already call `changed()`), with `owns()` asked while
  building it. A book may give `attr` for the date and size sorts (kept
  through metadata edits; each result gets its own copy).
- Folder listings and counts (`browser_flat_view_compat.lua`'s
  `getPathList` wrapper, or `getList` on KOReader before 2026.07): after
  KOReader's walk, the fileless sources' books in that folder, through
  `show_file`, as items (with `doc_props` from `BookSources.docProps`, so
  series grouping, which only trusts CoverBrowser's rows, sees them) or
  `true`. File browser only, not other file choosers.
- Flat view (`scan_flat`): all sources' owned books without a file in the
  folders walked (it knows every file it saw).
- Folder covers (`folder_cover.lua`): count, cover images and "all
  finished" include them; the descriptor and "all finished" caches key on
  the sources' `listingKey` and `statusRevision`. The folder long-press
  dialog's book count includes them too.
- `getDocProps` answers a fileless source's book from `bookInfo()` without
  querying CoverBrowser's database (the speed Athenæum's
  `withCloudDocProps` gave).
- Select mode: the file browser's selection never takes a book without a
  file (`BookSources.selectable`, a guard on `selected_files` set when
  select mode starts, "Select all files in folder" leaves them undimmed;
  tapping one in select mode, in the file browser or a group view, says
  "Not on this device: can't be selected"). Its actions are file operations
  (delete, move, copy, status). Collections' and search's select modes are
  left alone. The cost: cloud books can't be added to a collection in bulk
  from the file browser. Group views could select source books before this
  change too.
- `spec/lua/unit/book_listing_scans_spec.lua` classifies every file in
  ZenOS that reads folders (`lfs.dir`, `BookWalker.walk`): "asks" the
  sources, a known "gap", or "not_books". A new scan fails it until it's
  classified; an "asks" file that stops asking fails it. Known gaps:
  `cover_utils.lua`'s fallback when there's no file chooser, and To Be
  Read's folder scope (`tbr_index.lua`: whether books without a file belong
  there is undecided).

Timing (desktop emulator, 2,150 fileless books in the library folder, 50
sibling folders; best of 3):

| | Athenæum's hooks | ZenOS, no index | ZenOS, with index |
|---|---|---|---|
| Count 50 folders (one listing of their parent) | 4 ms | 116 ms | 4 ms |
| List the library by name / by title | 12 / 19 ms | 23 / 29 ms | 19 / 33 ms |
| Library folder cover | 0 ms (missed them) | 42 ms | 43 ms |

The listing is slower than Athenæum's hooks by about 10 ms here (likely
0.1–0.2 s on a Kobo), on a cache miss only (after a catalog change or a
download, #4). The folder cover costs what a folder of 2,150 files does.

Specs in `book_sources_spec.lua`, `filebrowser_flat_view_compat_spec.lua`,
`folder_cover_spec.lua` and `book_listing_scans_spec.lua`; Lua suite 3182
pass (the 2 updater specs fail without it too); luacheck finds nothing new.

Athenæum 0.10.12 requires this (Guard's startup check:
`booksWithoutFile`; no fallback for a ZenOS without it). Its source is
`fileless` and gives `attr`. Its listing hooks are gone: `addCloudItems`,
the count padding and its check, the `getList` fallback for ZenOS's flat
view, and `withCloudDocProps` (ZenOS's `getDocProps` shortcut does that
now). It keeps a `getPathList` hook (`getList` before KOReader 2026.07) for
the "Rebuilding library…" message only; it adds nothing.
`tests/athenaeum/e2e_search.py` checks listing, count, folder cover, flat
view of the library and of the folder above it, select mode and search.

**Plugins lose:** done in Athenæum as above, once this ZenOS is released.

Search is #7 (built on top of this). ZenOS
lists items with no file behind them, for sources that ask; the paths that
need a file are taps and long-presses (#911), file operations (the
selection guard) and folder scans (the scan spec).

History: the first version (below) was built and discarded on 2026-11-26:
about 275 lines of ZenOS code for a single source. Athenæum 0.10.7 went back
to adding the cloud books itself (`addCloudItems`, the count padding,
`withCloudDocProps`), asking the browser's `show_file` so the status filter
applies. 0.10.10 moved its hook to `getPathList` (KOReader 2026.07 and
later), which put it inside ZenOS's flat view wrapper: ZenOS's flat walk
(`scan_flat`, `BookWalker.walk`) replaces `getPathList` and never reaches the
hook, so the library folder lost its cloud books in ZenOS's flat view.
0.10.11 added the `getList` fallback for that. The notes below describe the
discarded version.

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

So Athenæum hooks KOReader's search (`athenaeum/search.lua`). Since
2026-11-26 (0.10.9) it does inside the plugin what the fix below would do in ZenOS:
its `FileSearcher:getList` hook (inside ZenOS's wrapper, so called once per
search root) asks the same `isFileMatch` about each cloud book in the
searched folder and adds those that match in KOReader's result shape, so
cloud books are matched by KOReader's rules or ZenOS's, whichever is on.
`doSearch` runs with the cloud books' metadata answered from the book
sources (`withCloudDocProps`), and drops cached results when the cloud books
changed; `onShowSearchResults` sets their `doc_props`; `onMenuSelect` /
`onMenuHold` show a cloud result's details. Before, it matched cloud books
itself (title, authors, series) and added them after the results, which
fell behind each change to ZenOS's matching (substring/whole-word setting,
separators, search roots).

What it relies on: `getList` doing the matching and returning `{ name,
fullpath, attributes }` entries; getList's preparation of the search text
(lowercase, wildcards), copied because it's a local; ZenOS calling the
original `getList` once per root; metadata matching reading
`getDocProps`.

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
  `changed()` should drop them (Athenæum's `doSearch` hook drops them when
  its catalog generation changed).
- `no_metadata_count` ("N files without metadata"): source books have
  metadata, so they shouldn't add to it.

**Plugins lose:** `athenaeum/search.lua` apart from its setting ("Include
cloud books in file search", which would then have to become a source
option or go, as `zenos_groups` did in #6), including the copy of getList's
search text preparation. Every source's books become searchable, not just
Athenæum's.

**Status (2026-11-26):** built on `custom`, uncommitted, on top of #6
(bc964b14); no PR branch yet. It needs #6 (`fileless`, `booksWithoutFile`)
and should land after #911, like #6. No new hooks: the books are added
where ZenOS's search patch (`modules/filebrowser/patches/search.lua`)
already calls or overrides KOReader's search, so it only works with ZenOS's
Search feature on. With it off, KOReader's own search finds files only
(decided 2026-11-26: KOReader's `doSearch` is the only other caller of
`getList`, and reaching it would need a hook).
- `common/book_sources.lua`, no hooks:
  - `searchResults(searcher, root, search_string, found)`: the fileless
    sources' books a search of root finds, as getList's `{ name, fullpath,
    attr }` entries. Folders as KOReader's walk covers them (root; with
    subfolders, every folder below it reached through shown, non-hidden
    folders, not its skipped system folders), paths in `found` left out,
    the walk's filters (`._`, `hasProvider` unless unsupported files are
    shown, `show_file`), and the searcher's own `isFileMatch` with the text
    getList would pass. Content search off and `no_metadata_count` put
    back while they're matched. Fileless sources only, as in folder
    listings: a non-fileless source's books may have files the walk skipped
    on purpose (the Kindle library is under `/mnt/base-us`).
  - `prepareFolderIndex()`; `booksWithoutFile` also
    takes a function for `folders`.
- `search.lua`, at its existing call points:
  - its `getList` loop over the home folders: after each folder's
    `orig_getList`, `searchResults` for that folder (a failure leaves the
    files found);
  - its search dialog's `_doSearch`: `prepareFolderIndex()` before the
    search's subprocess forks (it already drops cached results each time);
  - its `onShowSearchResults` override: results a source owns with no file
    (`ownsWithoutFile`, as the tap check) get `doc_props`
    (`BookSources.docProps`);
  - its results menu `onMenuSelect` override: a result a source owns with
    no file goes to `BookSources.open` (long-press already goes to
    `showFileDialog`, which asks the sources since #911). Search's select
    mode is left alone.
Specs: 5 in `book_sources_spec.lua`, 3 in `filebrowser_search_spec.lua`,
and 8 in `integration/book_sources_search_spec.lua`. The integration spec
runs KOReader's real `FileSearcher:getList` (UI dependencies stubbed) over
a temporary folder tree and checks that `searchResults` covers the same
folders (with and without subfolders, hidden folders shown or not, an
excluded folder) and prepares the same search text (plain, patterns, `*`);
it reads getList's `sys_folders` from KOReader's source and checks that
those are skipped. That covers what `searchResults` copies from getList's
locals: a KOReader change there fails it when ZenOS's pinned KOReader is
updated (checked by breaking each copied rule in turn). Lua suite 3198 pass
(the 2 updater specs fail without it too); luacheck finds nothing new.

Timing (desktop emulator, i5-8259U; 2,150 fileless books in the home
folder, a third in series, with tags; ZenOS's search, substring; best of 3;
scratch script):

| | Athenæum's hook (`custom` HEAD) | ZenOS (this change) |
|---|---|---|
| getList, metadata on, no match | 92 ms | 74 ms |
| getList, metadata on, "river" (256 results) | 77 ms | 72 ms |
| getList, metadata on, author (105 results) | 86 ms | 78 ms |
| getList, file names only, no match | 26 ms | 33 ms |
| Folder index, after a catalog change | – | 11 ms |
| Whole search (subprocess, results shown) | 139–154 ms | 136–157 ms |

The whole search takes 142–154 ms with no cloud books at all, so the
subprocess and showing the results cost more than the cloud books do, and
the difference is lost in noise here. The cloud books cost what Athenæum's
hook did: about 75 ms with metadata on, roughly 0.75–1.5 s on a Kobo by the
10–20× factor assumed for #6 (not measured on the device). The folder index
is built once per catalog change, before the subprocess, and reused.

Athenæum 0.10.13 dropped `athenaeum/search.lua` (its `getList`, `doSearch`,
`onShowSearchResults`, `onMenuSelect` / `onMenuHold` hooks and the copy of
the search text preparation), `Virtual.withProps`, and the "Include cloud
books in file search" setting (as `zenos_groups` went in #6: `books()`
decides). Guard's "search" feature now only checks for `searchResults`; a
ZenOS without it leaves cloud books out of search and says so in Status,
and the library still works. `tests/athenaeum/e2e_search.py` passes
against `custom` plus this change (its KOReader-search cases now expect
files only, and its ZenOS cases set `_zen_search_paths` as ZenOS's dialog
does).

## 8. ZenOS builds the Library's folder contents itself

**In ZenOS:** the Authors, Series, Tags and To Be Read views are ZenOS pages
built from data (`db_bookinfo.lua`: CoverBrowser's database plus
`BookSources.books()`), so source books just work there. The Library tab is
KOReader's `FileChooser` inside `FileManager`. ZenOS already owns most of
it (`browser_item_table_cache.lua` wraps `genItemTableFromPath`, plus its
rendering, series grouping, flat view, filters and folder covers), but on
a cache miss it still asks KOReader to build the folder's contents:
`getList` → `getPathList` → `getListItem`, one item at a time. Every
KOReader listing hook (ZenOS's from #6, Athenæum's `getPathList` hook and
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

**Plugins lose:** Athenæum's `getList` hook and its `hasBookBeenOpened` /
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
