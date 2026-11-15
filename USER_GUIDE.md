# Athenæum & Concordance — User Guide

## Overview

Athenæum puts your whole online book collection in KOReader's file browser; Concordance keeps your reading the same on every device. Each works alone, and together they share what you've read across devices and book versions.

|  | Athenæum | Concordance |
| --- | --- | --- |
| What it does | Lists every book in your Calibre-Web Automated OPDS catalog, downloaded or not. Tested only with Calibre-Web Automated and may rely on its features; other OPDS servers may not work | Syncs settings, reading statistics, highlights, bookmarks, book status and history |
| Needs | ZenOS (with book sources) and an OPDS catalog in KOReader's OPDS plugin | A WebDAV server in Cloud storage (Dropbox works for settings only) |
| Menu | Athenæum | Tools → Concordance |
| Settings files | `settings/athenaeum/settings.lua` (this device), `settings/athenaeum/shared.lua` (can be synced) | `settings/concordance/` |

Concordance also has an optional web app, Concordance web, for browsing your books, highlights and reading statistics in a browser.

<a id="athenaeum"></a>

## Athenæum

<img src="assets/logos/athenaeum.svg" width="48" alt="">

Every book in your catalog appears in your library folder, whether it's on the device or not. Books not yet downloaded are "cloud books": they look and sort like real books, with covers, and download when you want them.

Athenæum was called Cloud library before version 0.8.0. Its old folder name, `cloudlibrary.koplugin`, is also used by another plugin, which made the two clash in package managers such as ZenPM.

### Moving from Cloud library

Cloud library updates itself to Athenæum like any other update (Check for updates, or automatically). When KOReader restarts after the update, Athenæum finishes the move by itself:

- Its folder is renamed from `plugins/cloudlibrary.koplugin` to `plugins/athenaeum.koplugin`.
- Its settings, catalogs and covers move from `settings/cloudlibrary/` to `settings/athenaeum/`. Nothing is downloaded again.
- Gestures, profiles and keyboard shortcuts set to **Cloud library: quick sync** become **Athenæum: quick sync**.
- If you also installed Athenæum by hand, the old `cloudlibrary.koplugin` folder is removed. Another plugin's `cloudlibrary.koplugin` is left alone.

Between installing the update and restarting, the running Cloud library may report that part of it was turned off: its files have already been replaced. Restart KOReader to finish. With Concordance installed, update it too: an older Concordance doesn't know the new name, so until it's updated, Athenæum checks for its own updates and Concordance doesn't use Athenæum's catalog (its matched files and cloud books).

### Setting up

1. Add your library's catalog in KOReader's OPDS catalog plugin (with its username and password).
2. Athenæum → **Catalog**: choose it. This runs a full sync.
3. Athenæum → **Folder**: where cloud books are listed and downloaded to. It defaults to KOReader's download folder. Books already in this folder (not its subfolders) are recognised as catalog books, so they aren't listed twice.

### Same settings on every device

Athenæum keeps the settings that can be the same everywhere in `settings/athenaeum/shared.lua`: the catalog, badges, search, ZenOS tabs, showing cloud books and the sync schedule. The library folder and the updater stay in `settings/athenaeum/settings.lua`, one per device. To share them with Concordance's settings sync, add this line to `settings/concordance/sync.txt`:

```
/settings/athenaeum/shared.lua
```

Sync first from the device whose settings you want to keep. The catalog is shared by its URL and username, so add it to every device's OPDS catalogs with the same URL and username (each device keeps its own password). A device whose OPDS catalog has a different URL or username shows no cloud books: correct it in KOReader's OPDS catalog rather than choosing the catalog again in Athenæum, which would change it on every device.

### Browsing cloud books

- **In the library folder**: cloud books sit beside downloaded ones, in list or mosaic view, sorted the same way.
- **Covers** download as you browse, plus a batch after each sync. A full sync notices a changed cover when the book's file changed with it; for others, use Refresh all covers.
- **Badges** on the cover show where a book is: a cloud for cloud-only books; with Concordance, the cloud carries a check, play or pause mark when the book is finished, being read or on hold on another device.
- **ZenOS tabs**: cloud books appear in Authors, Series and Tags, on Home, and in the reading history. Books in a series are numbered in the order the server lists them, so a gap or a number such as 2.5 shows as the next whole number.
- **File search** finds cloud books by title, author or series.

### Downloading

Tap a cloud book to see its details: title, authors, series, year, pages, formats, a summary, and (with Concordance) its status, rating and when it was last read. From there:

- **Download** saves it to the library folder, in the best format (EPUB first, then KEPUB, PDF, CBZ…). A **Download EPUB / PDF…** button appears when there's a choice.
- **Download & read** opens it as soon as it arrives.

Downloads run in the background, one at a time. Files are named like KOReader's OPDS downloads ("Author - Title.epub") and dated when the book was added to the library, so they stay in place when sorted by date. Delete a downloaded book and it turns back into a cloud book.

### Keeping up to date

| Sync | What it does | Runs (default) |
| --- | --- | --- |
| Quick sync | Adds books new to the catalog. Becomes a full sync if the number of books changed | Every hour, when the file browser opens or Wi-Fi connects |
| Full sync | Rereads the whole catalog: edited and removed books, series, titles. A catalog that comes back empty removes nothing | Weekly |

Quick sync can be every 1, 3, 6 or 12 hours, daily or never; full sync daily, weekly or never. Neither turns Wi-Fi on. Run either by hand from the menu, or assign **Athenæum: quick sync** to a gesture.

### Menu

| Item | What it does |
| --- | --- |
| Quick sync now / Full sync now | Sync immediately |
| Download missing covers | Fetch every cover not on the device yet, in the background |
| Refresh all covers | Check every cover with the server and fetch the changed ones |
| Show cloud books | Turn off before removing the plugin, so the file browser forgets cloud books |
| Mark cloud books | Cloud badge on cloud-only books (on) |
| Mark books on this device | Check mark on downloaded catalog books (off) |
| Mark books not in the catalog | Crossed-out cloud on folder books missing from the catalog (off) |
| Include cloud books in Authors, Series and Tags | ZenOS tabs (on) |
| Include cloud books in file search | (on) |
| Status | Catalog, folder, book and cover counts, last syncs and any problems |
| Timings | How long each step took, for tracking down slowness |
| Check for updates / Automatic updates | Handled together with Concordance when it's installed |

If a KOReader or ZenOS update breaks part of Athenæum, it turns that part off and says so; your books and the file browser keep working.

## Concordance

Concordance keeps KOReader the same on all your devices through your own server: your settings, reading time, highlights and the state of every book. Syncing only ever adds reading time, and a change made on one device (a deletion too) is made on the others, with the later change winning. Removing many highlights at once asks first.

This relies on two things: each device's clock being roughly right (KOReader sets it from the network), and a server and connection you trust, since what's on the server is what devices take.

### Setting up

1. Copy `concordance.koplugin` into `plugins/` and restart. Statistics need the Reading statistics plugin enabled.
2. Add your server in file browser → Cloud storage. Use WebDAV for everything; Dropbox works for settings only.
3. Tools → Concordance → **Server**: choose it. Give it the same name on every device.
4. Tools → Concordance → **Folder on server**: `/KOReader` unless you change it. Use the same folder on every device.
5. For settings sync, list what to sync in `settings/concordance/sync.txt` (below).

### What syncs

| What | Server | When |
| --- | --- | --- |
| Settings, plugins, patches, fonts, dictionaries, style tweaks | Dropbox or WebDAV | Only when you ask |
| Reading statistics (time per page) | WebDAV | Automatically |
| Highlights, notes and page bookmarks | WebDAV | Automatically |
| Book status, rating, review, custom metadata | WebDAV | Automatically |
| Handmade table of contents, hidden flows | WebDAV | Automatically |
| Collections, favorites and reading history | WebDAV | Automatically |

Automatic syncs run when a book is opened (only if Wi-Fi is already on) or closed, on wake-up, when the network connects, and 20 seconds after KOReader starts. With **Sync in the file browser** set (every 5, 15, 30 or 60 minutes; never by default), they also run that often while the file browser is shown and Wi-Fi is on. They run in the background, so reading isn't interrupted. Without a network they're skipped and the next sync catches up, unless you turn on **Turn on Wi-Fi for automatic syncs**.

### Settings sync

List one pattern per line in `settings/concordance/sync.txt`, starting from KOReader's folder:

```
/settings/gestures.lua
/settings/ZenOS/**
/styletweaks/**
/data/dict/**
< /fonts/**
```

- `*` matches within a name, `**` across folders, `#` starts a comment. Anything not listed is left alone.
- A line starting with `<` is pull only: put the files on the server yourself (fonts, say) and devices download them.
- The list itself syncs too, so change it on one device and the others follow.
- **Preview changes** shows what a sync would do without doing it.
- A file changed on both sides keeps the newer copy and saves the other in `settings/concordance/settings-sync/conflicts/`.
- A listed file you delete on one device is deleted on the server and the other devices.
- KOReader's main settings file, `settings.reader.lua`, is never synced: KOReader writes it back from memory, so a pulled copy would be lost.
- Pulled settings are put in place at the next start, and the sync offers to restart.

Sync first from the device whose settings you want to keep.

### Reading statistics

Each device uploads only its own new reading, and merges everyone else's. Your Reading statistics then show time read on every device. Statistics you reset on one device are not reset on the others.

Don't also use Reading statistics' own "Cloud sync" on the same devices: the two disagree about deletions.

### Highlights, notes and bookmarks

- Edits sync too: note text, colour, style and adjusted ends. If the same highlight changes on two devices, the later change wins.
- They arrive in the book you're reading right after a sync, and in other books the next time they're opened.
- Removing one removes it everywhere.
- **Removing many at once asks first.** If more than 5 of a book's highlights disappear together (say its settings were reset), you choose: **Restore them here**, **Remove everywhere** or **Ask later**. Five or fewer are removed everywhere without asking.
- Two highlights made in the same book in the same second on different devices count as one: one replaces the other.

Turn off KOReader's "Export annotations on book closing", and leave "Write highlights into PDF" off for synced PDFs.

### Book status, collections and history

- Mark a book finished, rate or review it, or edit its metadata on one device, and the others match. Clearing a rating or review, or taking a book out of a collection, clears it on the others too.
- Collections and favorites follow the book, not its folder, so devices can organise files differently. Each device keeps its own sort order.
- Books read on another device appear in this device's History at the time they were read: after that device has synced (on opening the book if its Wi-Fi is on, otherwise at its next sync) and this one syncs next. The latest book read anywhere is the one KOReader reopens.
- A device's first sync doesn't overwrite what other devices already have.

### Menu

Tools → Concordance, in the file browser and the reader:

| Item | What it does |
| --- | --- |
| Sync now | Statistics, highlights, bookmarks and book status |
| Settings → Sync now / Preview changes / Log | Settings sync |
| Statistics, Highlights and books | Sync now, and Sync automatically (on) |
| Server, Folder on server | Where your data is kept |
| Sync in the file browser | Never by default; every 5, 15, 30 or 60 minutes, only while Wi-Fi is on |
| Turn on Wi-Fi for automatic syncs | Off by default |
| Status | Server, last syncs and errors, devices seen, books in several versions |
| Troubleshooting → Rebuild from server | Imports every device's files again; deletes nothing |
| Troubleshooting → Reset device ID | For a device restored from another's backup |
| Check for updates / Automatic updates | Updates Concordance and Athenæum together |

Each sync is also a gesture under General ("Concordance: sync statistics and highlights", "Concordance: sync settings", and so on).

### Concordance web

An optional web app that shows what Concordance keeps on your server. It runs as a Docker container on the machine with the WebDAV files and only reads them.

- **Home**: reading time today, this week, month and year, streaks, a 12-month calendar, books in progress, recent highlights.
- **Books**: filter by status, collection, author, series or tag, search and sort, with tabs listing Authors, Series and Tags; each book shows its review, rating, reading time, highlights by chapter (downloadable as Markdown) and sessions.
- **Highlights**: every highlight and note, newest first, with search and a colour filter.
- **Statistics**: per year or all time, by month, time of day and day of the week.
- **Versions**: books known in more than one file, and how they were matched.
- Covers, descriptions, tags and series can come from your Calibre-Web Automated server.

Start it with `docker compose up -d`, setting `READING_DIR` to your server's `<folder>/Reading`, then open `http://<server>:8080`. Set `WEB_USERNAME` and `WEB_PASSWORD` to require a password. See [concordance-web/README.md](concordance-web/README.md).

## Using them together

With both installed, Athenæum knows what you've read on every device, and a book counts as one book however many times its file has changed.

### What you see

- **Cloud badges show reading state.** A cloud-only book's badge gets a check (finished), play (reading) or pause (on hold) mark from your other devices.
- **Details show your history.** A cloud book's details sheet adds a line such as "Finished · ★★★★☆ · Last read 12 Oct 2026 on Kobo Forma".
- **History includes cloud books.** A book you read on another device appears in History even if it isn't downloaded here; tap it to see its details and download it. Once downloaded, the entry becomes the file.
- **Downloads open where you left off.** A book Athenæum has just downloaded is matched at once, so it opens with its status and highlights from other devices.
- **One update check.** Concordance checks both plugins in one go and offers to install both; there's one restart prompt afterwards.

### Book versions

Editing a book on the server (a new cover, new tags) rewrites its file, so KOReader would see a new book. Concordance reads the book ID Calibre writes into each EPUB and treats files sharing it as versions of one book.

| Shared between versions | Same book ID | Same text too |
| --- | --- | --- |
| Status, rating, review, custom metadata | Yes | Yes |
| Reading statistics | Yes | Yes |
| Highlights, bookmarks, handmade table of contents, hidden flows | No | Yes |
| Reading position (with KOReader's Progress sync on) | No | Yes |

Highlights and positions only cross between versions with the same text, so a different edition keeps its own.

Files sharing a book ID count as one book when their titles agree, their text is the same, or they share both of Calibre's IDs. A retitled new edition with different text and only one ID in common is kept apart; so are different books that share an ID by mistake.

With Athenæum, catalog books in its folder are recognised whether or not they've been opened. A file with no book ID of its own (a PDF, or an EPUB without one) that Athenæum matches by title shares status, rating and statistics with its catalog book; an EPUB with its own ID goes by that instead. If Athenæum stops matching a file to a book, the device that made the match withdraws it at its next sync.

Tools → Concordance → **Status** shows how many books are known in more than one version; Concordance web's **Versions** page lists them.

## Tips and troubleshooting

| Problem | What to do |
| --- | --- |
| A cloud book shows an old cover | Athenæum → Refresh all covers |
| New books on the server don't appear | Athenæum → Quick sync now; for edited or removed books, Full sync now |
| Athenæum says part of it was turned off | Usually after a KOReader or ZenOS update. Check Athenæum → Status and `crash.log`, then update the plugin |
| Removing Athenæum | Turn off Show cloud books first, so the file browser forgets them |
| Statistics missing on a device | Concordance → Troubleshooting → Rebuild from server (adds only, never deletes) |
| Device restored from another device's backup | Concordance → Troubleshooting → Reset device ID |
| "Removed highlights waiting for you" in the menu | Choose whether to restore them here or remove them everywhere |
| Pulled settings waiting for a restart | Restart KOReader, or discard them from the menu to keep this device's settings |
| Moving to another server | Copy the whole folder to the new server, then choose it under Concordance → Server on each device |

Things to avoid:

- Don't sync books' `.sdr` folders, `docsettings/`, `history.lua` or `collection.lua` with settings sync or another file sync; Concordance already handles them.
- Don't copy Concordance or Athenæum between devices with settings sync; they update themselves.
- Reading statistics and history entries you remove on one device stay on the others: to clear statistics everywhere, reset them on every device and remove the server's files by hand. Other deletions (highlights, ratings, reviews, collections, listed settings files) do sync.
- Notes and reviews are sent as plain text to your server; passwords are never logged.

Log lines start with `Athenaeum:`, `Concordance:` or `StatSync:` in KOReader's `crash.log`.

For more detail, see [concordance.koplugin/README.md](concordance.koplugin/README.md), [SETTINGS.md](concordance.koplugin/SETTINGS.md), [STATISTICS.md](concordance.koplugin/STATISTICS.md) and [IDENTITY.md](concordance.koplugin/IDENTITY.md).
