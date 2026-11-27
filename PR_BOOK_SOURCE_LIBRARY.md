## Library sources: book sources' books in the Library, search and folder covers

Book sources' books already appear in Authors, Series, Tags, Languages, Home, To Be Read and the book switcher. They didn't appear in the Library tab. A book with no file at its path (a cloud catalogue's, for example) was missing from its folder's listing, the flat view, folder covers and file search, unless the plugin added it by hooking KOReader's `FileChooser` and `FileSearcher`.

This PR lets a source declare itself a **library source** (`library = true`). ZenOS then lists, counts, searches and shows covers for that source's books in the same places it does for files. Other sources are unchanged: their books stay in the groupings and don't appear in the Library tab.

### What ZenOS gets

- **The Library tab and search match the other views.** A library source's books are listed like files, so filters, sorts, series grouping and folder covers apply. A book that is also a scanned file is listed once. Plugins no longer need their own hooks into KOReader's file chooser and search.
- **Guarded.** Select mode never takes a book with no file, and `book_listing_scans_spec` fails on any new folder scan that doesn't ask the book sources.
- **Fast with large libraries** (about 2,000 cloud books). On a Kobo, a cold Library open sorted by last read went from 4.89 s to 2.13 s. Local covers no longer wait behind a source's downloads (4.6 s → 1.08 s in the emulator).

### The contract, in short

- A library source's paths are in the library. Its books are meant to be ones the scan doesn't find: books not downloaded yet, or books whose files are kept elsewhere (the path then has no file behind it).
- It's opt-in because ZenOS takes the source's word for these books. It doesn't look their paths up on disk, takes their `getDocProps()` from `bookInfo()` alone, and matches them in search by name and metadata, never content.
- `owns()` must claim the books, and `listingKey()` must cover their folders and the folders above them.
- For every source, a book's path is its identity. History, collections (To Be Read, Favorites) and metadata edits are kept by path, and `changed({ old, new })` only refreshes ZenOS's caches and views. So sources should keep paths stable.

### Commits

1. `12817403` **Library book source contract.** Adds the `library` declaration and the contract docs. Adds `BookSources.booksWithoutFile`, which returns the library sources' owned books in the given folders, leaving out the files the scan found. It looks them up in an index rebuilt when the sources call `changed()`. Adds `ownsWithoutFile`. `getDocProps` answers these books from `bookInfo()` without querying CoverBrowser's database.
2. `1af5eb08` **List library sources' books in folders and the flat view.** Adds the books to folder listings, the flat view, folder covers (count, images, "all finished") and the folder's book count. Counts leave out books that are also files there. The long-press count keeps the paths it walks. A count-only listing reads the folder's names once, and only when the folder holds library books. Adds `book_listing_scans_spec`.
3. `887f8ec7` **Keep source books without a file out of selections.** Select mode drops them, "Select all files in folder" leaves them undimmed, and tapping one in select mode explains why.
4. `3d60fb97` **Include library sources' books in search results.** ZenOS's search wrapper adds matching books for each searched folder. It uses the searcher's own `isFileMatch` (file name or metadata), the walk's filters and KOReader's result shape. Results get `doc_props`, and tapping one opens it through the source. An integration spec runs KOReader's real `FileSearcher:getList`, so a KOReader change to the rules copied here fails when the pinned KOReader is updated.
5. `390eaa14` **Don't hold up cover extraction for a source's cover downloads.** `cover_preload` hands a source's own cover requests straight down instead of queueing them behind CoverBrowser. It checks CoverBrowser's own subprocesses to decide whether extraction is running. The cover poll still uses `isExtractingInBackground()`, so CoverBrowser keeps polling while a source downloads.
6. `0566dda5` **Don't look up library sources' books when sorting by last read.** `BookSources.isLibraryBook(path)` answers from the sources alone, with no disk access, and sorting by last read skips `realpath()` for those paths. Other paths get a cheap `stat` first.

### Notes

- Without a library source, the cost is negligible. Each folder listing or count, each path in a last-read sort, and each selected path gets one extra call, and each takes under 0.4 µs on the desktop. That's with no sources registered, and with one source that doesn't set `library` (like the Kindle one). The calls only check the sources' flags and `owns()`.
- Search integration needs ZenOS's Search feature to be on. KOReader's own search still finds files only.
- Known gaps, recorded in the scan spec: `cover_utils.lua`'s fallback when there's no file chooser, and To Be Read's folder scope.
- Home's cover upgrades still wait for a source's downloads.
- The count-only listing's extra read of a folder's names took 1.3 ms for 2,150 names on the desktop (warm). It covers only real files, so for a cloud library it's usually far smaller. It hasn't been measured on a Kobo.
- The Kindle library source doesn't set `library`. Its books are real files outside the library, and its listed path for a KFX book changes once the book is converted.
- New code that takes a listed item's path to the disk must allow for items with no file. Taps and long-presses (#911), file operations (the selection guard) and folder scans (the spec) are covered.

### Testing

- `./spec/run lua`: 3,210 passed, 0 failed, at the last commit. The contract, flat-view and search commits pass on their own too. New specs are in `book_sources_spec`, `filebrowser_flat_view_compat_spec`, `folder_cover_spec`, `book_listing_scans_spec`, `filebrowser_search_spec`, `filebrowser_item_table_cache_spec`, `filebrowser_cover_preload_spec` and `integration/book_sources_search_spec`.
- Emulator, with a source of 2,150 books with no file: listing, counts, folder covers, the flat view, select mode, search, and cover downloads from a local server with a 1 s delay. This was run before the flag was renamed. Since then the only behaviour changes are that other sources' books are no longer added to the flat view, and that counts leave out books that are also files.
- Kobo: cold Library open sorted by last read.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
