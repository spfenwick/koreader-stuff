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

Downloaded books show the catalog's current title, authors, series and tags, so an edit made in Calibre-Web Automated reaches books already on the device at the next sync, without changing their files. Metadata you edit on the device (KOReader's Book information, or ZenOS's editor) still comes first. Language and description stay the file's own.

### Setting up

1. Add your library's catalog in KOReader's OPDS catalog plugin (with its username and password).
2. Athenæum → **Catalog**: choose it. This runs a full sync.
3. Athenæum → **Folder**: where cloud books are listed and downloaded to. It defaults to KOReader's download folder. Books already in this folder (not its subfolders) are recognised as catalog books, so they aren't listed twice.

### Same settings on every device

Athenæum keeps the settings that can be the same everywhere in `settings/athenaeum/shared.lua`: the catalog, badges, ZenOS tabs, showing cloud books and the sync schedule. The library folder and the updater stay in `settings/athenaeum/settings.lua`, one per device. To share them with Concordance's settings sync, add this line to `settings/concordance/sync.txt`:

```
/settings/athenaeum/shared.lua
```

Sync first from the device whose settings you want to keep. The catalog is shared by its URL and username, so add it to every device's OPDS catalogs with the same URL and username (each device keeps its own password). A device whose OPDS catalog has a different URL or username shows no cloud books: correct it in KOReader's OPDS catalog rather than choosing the catalog again in Athenæum, which would change it on every device.

### Browsing cloud books

- **In the library folder**: cloud books sit beside downloaded ones, in list or mosaic view, sorted the same way.
- **Covers** download as you browse, plus a batch after each sync. A full sync notices a changed cover when the book's file changed with it; for others, use Refresh all covers.
- **Badges** on the cover show where a book is: a cloud for cloud-only books; with Concordance, the cloud carries a check, play or pause mark when the book is finished, being read or on hold on another device.
- **Reading status**: with Concordance, ZenOS also shows a cloud book's status from your other devices, as it does for a downloaded book: its status badge, the status filters, Home and To Be Read. Changing the status of a cloud book needs the book downloaded; once it is, the status on this device is the one shown.
- **ZenOS tabs**: cloud books appear in Authors, Series and Tags, on Home, and in the reading history. Books in a series are numbered in the order the server lists them, so a gap or a number such as 2.5 shows as the next whole number.
- **File search** finds cloud books as it finds files when ZenOS's Search is on: by file name and, with metadata search on, by title, author, series and tags. They're sorted with the files found. ZenOS does this itself, so it needs a ZenOS version that includes it; KOReader's own search (ZenOS's Search off) finds files only.

### Downloading

Tap a cloud book to see its details: title, authors, series, year, pages, formats, a summary, and (with Concordance) its status, rating and when it was last read. From there:

- **Download** saves it to the library folder, in the best format (EPUB first, then KEPUB, PDF, CBZ…). A **Download EPUB / PDF…** button appears when there's a choice.
- **Download & read** opens it as soon as it arrives.

Downloads run in the background, one at a time. Files are named like KOReader's OPDS downloads ("Author - Title.epub") and dated when the book was added to the library, so they stay in place when sorted by date. Delete a downloaded book and it turns back into a cloud book.

### Keeping up to date

| Sync | What it does | Runs (default) |
| --- | --- | --- |
| Quick sync | Adds books new to the catalog. Becomes a full sync if the number of books changed | When the file browser opens (at start-up and after closing a book), on wake-up and when Wi-Fi connects |
| Full sync | Rereads the whole catalog: edited and removed books, series, titles. A catalog that comes back empty removes nothing | Weekly (by default), two minutes after the automatic sync that finds it due, so it doesn't slow start-up or wake-up |

Automatic quick syncs can be turned off (**Quick sync automatically**); full sync can be daily, weekly or never. Neither turns Wi-Fi on. Run either by hand from the menu, or assign **Athenæum: quick sync** to a gesture.

### Menu

| Item | What it does |
| --- | --- |
| Quick sync now / Full sync now | Sync immediately |
| Download missing covers | Fetch every cover not on the device yet, in the background |
| Refresh all covers | Check every cover with the server and fetch the changed ones |
| Mark cloud books | Cloud badge on cloud-only books (on) |
| Mark books on this device | Check mark on downloaded catalog books (off) |
| Mark books not in the catalog | Crossed-out cloud on folder books missing from the catalog (off) |
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

Automatic syncs run when a book is opened (only if Wi-Fi is already on) or closed, on wake-up, when the network connects, and 20 seconds after KOReader starts. Highlights and books also sync a few seconds after you change a book's status, rating, review or metadata (only if Wi-Fi is already on). They run in the background, so reading isn't interrupted. Without a network they're skipped and the next sync catches up, unless you turn on **Turn on Wi-Fi for automatic syncs**.

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
- When a file changed on both sides, the sync asks which to keep: the server's versions, this device's, or the newest. The others are saved in `settings/concordance/settings-sync/conflicts/`. "Decide later" leaves them as they are until the next sync.
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
| Sync Settings → Sync now / Preview changes / Log | Settings sync |
| Statistics, Highlights and books | Sync now, and Sync automatically (on) |
| Server, Folder on server | Where your data is kept |
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

- **Downloaded books show it too, before you open them.** In ZenOS, a book downloaded into the library but not opened here yet shows its status and rating from your other devices. Once you open it, it has its own, kept in step by Concordance.
- **Details show your history.** A cloud book's details sheet adds a line such as "Finished · ★★★★☆ · Last read 12 Oct 2026 on Kobo Forma".
- **Mark cloud books from their details.** A cloud book's details sheet has a **Read status** menu, as in ZenOS's book menu (Unread, Reading, On hold or Finished), so you can mark a book you've read elsewhere (on paper, say) without downloading it. It syncs like any other status. Unread removes the book's status on every device, so it shows as new; opening it again marks it as reading.
- **History includes cloud books.** A book you read on another device appears in History under its title even if it isn't downloaded here; tap it to see its details and download it, or long-press it to remove it from History (in ZenOS, also from Home's Recently read). Once downloaded, the entry becomes the file.
- **Metadata edits sync.** With Concordance syncing (a WebDAV server set up), ZenOS's metadata editor keeps an EPUB's edits in KOReader's custom metadata rather than writing them into the file, so they reach your other devices. On library books they show over the catalog's metadata.
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
