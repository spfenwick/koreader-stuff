# ZenOS PRs that would simplify the plugins

Changes to ZenOS that would fix something in ZenOS itself *and* let
Athenæum or Concordance drop a hook. Written 2026-11-19, against the
book-sources work (`book-source-enhancements` in the zen-os fork, merged
upstream as #892 on 2026-11-17). Base each PR on upstream's `dev`.

Each entry: what's wrong in ZenOS, the fix, and what goes away in the
plugins. When one merges, remove the plugin code and update this file.

Suggested order: 1, 2, 3, 4. The first two are small.

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

**Status (2026-11-24):** committed on ZenOS branch `book-source-long-press`
(from upstream `dev`; commit a55c77ee, pushed to the fork, PR not opened
yet) and on `custom` (07553f7a). `BookSources.open` and `showContextMenu`
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

**Plugins lose:** the `rh:reload(true)` workaround (and its comment) in
`concordance/histsync.lua` and `athenaeum/history.lua`.

## 3. Home refreshes itself when the sources report changes

**In ZenOS:** there's no public way to tell Home a book changed. Both
plugins reach into `FileManager.instance.zenos`, then
`shared_state.get(…, "home")`, and call `invalidateBookCache`,
`rebuildActive` and `isActiveOnTop` themselves.

**Fix:** `BookSources.changed(paths)` and `statusChanged()` invalidate Home's
cache for those paths and rebuild it (now if it's on top, else when it's
next shown). Add `BookSources.historyChanged(paths)` and a public
`isHomeOnTop()`. The Kindle source gets Home refreshes for free.

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
  Athenæum's `swapInItem` does for open views);
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

**Status (2026-11-24):** not started. Time a download's listing before and
after in the emulator.

**Plugins lose:** `replaceInViews` and `swapInItem` in
`athenaeum/zenos_source.lua`, which edit ZenOS's private fields
(`_zen_files`, `series_items`, `_zen_tbr_refresh`), and the full listing
rebuild after every download. Kindle and any other source that moves files
get the same.

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
