# ZenOS PRs that would simplify the plugins

Changes to ZenOS that would fix something in ZenOS itself *and* let
Athenæum or Concordance drop a hook. Written 2026-11-19, against the
book-sources work (`book-source-enhancements` in the zen-os fork, merged
upstream as #892 on 2026-11-17). Base each PR on upstream's `dev`.

Each entry: what's wrong in ZenOS, the fix, and what goes away in the
plugins. When one merges, remove the plugin code and update this file.

Suggested order: 1, 3, 4, 5 (2 is no longer needed by the plugins).

Open upstream (2026-11-25):
- [#911](https://github.com/xZenLabs/zen-os/pull/911) "Ask book sources when
  opening or long-pressing a book anywhere" (branch `book-source-long-press`):
  #1.
- [#912](https://github.com/xZenLabs/zen-os/pull/912) "Refresh open views
  when book sources report changes" (branch `refresh-views`): #3 and the
  views half of #4 (without `moved()`).

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

## 4. `BookSources.moved(old, new)`, without a listing rebuild

**In ZenOS:** a source can't say a book's path changed. And a download
always rebuilds the library folder's whole listing (about 2,150 entries on
the Kobo, with "Rebuilding library…"), because ZenOS's cached listing
(`browser_item_table_cache.lua`) is keyed on two things the download
changes:

1. the stable key, which includes `BookSources.listingKey`. Athenæum's
   key (`Virtual.catalog_sig`) changes because the book leaves the cloud
   list (`Library.downloaded` → `Library.load` → `setCatalog`);
2. the folder's `directory_signature` (mtime, ctime, size, inode), which
   changes when the file is written.

Either one misses the cache, and `Virtual.refresh()` → `refreshPath` then
rebuilds the whole listing.

There's no way around this in the plugin:
- Keeping `listingKey` unchanged after a download doesn't help, because the
  folder signature still changes. ctime can't be set back, and touching
  the folder was removed in 0.5.x.
- Editing the cached listing means reaching ZenOS's `shared_cache` (a local)
  through `debug.getupvalue`, and faking the saved copy too. Too fragile.
- Skipping the refresh after a download only delays the rebuild: the next
  listing still misses, and `history_reorder` (the "back from the reader"
  path) needs the stable key to match.

**Fix:** when told a path moved, ZenOS updates its own open views (group
item file lists, series items, To Be Read) *and* its cached listings of the
folder, in memory and the saved copy. It:
- swaps the old entry for the file's entry, inside series groups too (what
  `moved()` now does for open views);
- moves that one entry if the sort needs it. Sorting by date added or last
  read leaves it in place (Athenæum sets a downloaded file's date to the
  date the book was added); sorting by name can move it, since the file is
  named "Author - Title";
- stores the current key, so the next listing is a cache hit.

This could be a `FileChooser:_zen_update_item_table(path, edit)` that
`moved()` uses.

Things to watch:
- The re-key must happen after the file is renamed into place, or the
  FAT32 2 s window in `changed_near_scan` marks the listing stale.
- Download & read: the first open creates the `.sdr` folder, changing the
  folder again. When sorting by last read, `history_reorder` ignores that
  as long as the stable key matches, so it shouldn't rebuild. Not checked
  for other sort orders.

**Status (2026-11-24):** the views half was committed on ZenOS `custom`
(856d8434): `BookSources.moved(old, new)` swaps the path
in ZenOS's open views (group pages and their book lists, To Be Read, other
open lists) and redraws the file browser when it shows either folder.
Athenæum assumes a ZenOS with it; its `replaceInViews`, `swapInItem` and
`ZenSource.downloaded` are gone. Still to do: updating ZenOS's cached
listings so a download doesn't rebuild the whole folder. Time a download's
listing before and after in the emulator.

**Update (2026-11-25, Athenæum 0.10.0, STABLE_PATHS_PLAN.md):** a book's
path is now where its file is or would be ("Author - Title.epub"), so a
download or a delete keeps the path. Athenæum tells ZenOS `changed({ path
})` for those, not `moved()`, and calls `moved()` only when a book's path
really changes: a file renamed outside KOReader, one of two copies
deleted, a file taking a cloud book's name. (Also the one-off move from
0.9's `cloud-<id>` paths, removed 2026-11-25 once every device had run
it.)

**Update (2026-11-25, later):** Athenæum no longer calls `moved()` at all.
Its rare path changes happen during a catalog load, and `changed({ old,
new, … })` does the rest of what `moved()` does (the views are rebuilt);
all it loses is a book staying selected in select mode across the move.
So the `moved()` half of this PR isn't needed by Athenæum. It's on ZenOS
`custom` already; keep it only if another source (Kindle) wants it.
- The listing half matters more now. A download still rebuilds the whole
  listing (the folder signature and `listingKey` change as before), but
  the cached entry needn't be swapped for another path: updating the one
  entry in place (its metadata, cover and badge) and re-keying the cache
  is enough. Check whether `changed({ path })` can do it, rather than a
  new call.

**Status (2026-11-25):** the views half is in
[#912](https://github.com/xZenLabs/zen-os/pull/912) (with #3) as views
refreshing on `changed(paths)`; `moved()` itself was left out (see the
update above), and it's gone from `custom` too. The listing half is still to
do.

**Plugins lose:** `replaceInViews` and `swapInItem` in
`athenaeum/zenos_source.lua`, which edit ZenOS's private fields
(`_zen_files`, `series_items`, `_zen_tbr_refresh`), and the full listing
rebuild after every download. Kindle and any other source that moves files
get the same.

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
bottom-right corner. The series number moves left of it. Painted on library
mosaic items (`zen_renderer.lua`), list covers
(`browser_list_item_layout.lua`), Home strips (`strip_common.lua`: with or
without the strip's own badges) and the featured book
(`featured_common.lua`, through `make_cover_widget`'s `decorate`).
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
