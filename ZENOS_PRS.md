# ZenOS PRs that would simplify the plugins

Changes to ZenOS that would fix something in ZenOS itself *and* let
Athenæum or Concordance drop a hook. Written 2026-11-19, against the
book-sources work (`book-source-enhancements` in the zen-os fork, not yet
merged upstream). Base each PR on upstream's `dev`, or on that branch once
it merges.

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

**Plugins lose:** in `athenaeum/zenos_source.lua`, `wrapOpenFile`,
`wrapFileDialog` and `ensureOutermost` (re-wrapping outermost whenever ZenOS
rebuilds a grouping). In `athenaeum/virtual.lua`, `cancelZenOSOpeningBanner`
(the `__ZEN_UI_CANCEL_OPENING_BANNER` global).

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

## 4. `BookSources.moved(old, new)` (lower priority)

**In ZenOS:** nothing; a source can't say a book's path changed.

**Fix:** ZenOS updates its own open views (group item file lists, series
items, To Be Read) when told a path moved.

**Plugins lose:** `replaceInViews` and `swapInItem` in
`athenaeum/zenos_source.lua`, which edit ZenOS's private fields
(`_zen_files`, `series_items`, `_zen_tbr_refresh`). The case for ZenOS on
its own is weaker here.

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
