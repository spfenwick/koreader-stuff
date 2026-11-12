# Concordance web

A web app for browsing what Concordance keeps on the server: books, highlights
and notes, reading statistics, collections and the reading history. It runs
as a Docker container on the machine that holds the WebDAV files, and only
reads them.

- **Home**: reading time today, this week, month and year, streaks, a
  calendar of the last 12 months, books being read, recent highlights.
- **Books**: filter by status, collection, author, series or tag, search, and
  sort. Tabs beside it list the **Authors**, **Series** (each in series
  order) and **Tags**, with their books. A book's page
  has its review, rating, status, series, tags, collections, reading time per day or week,
  highlights by chapter (downloadable as Markdown), bookmarks, sessions and
  files.
- **Highlights**: every highlight and note, newest first, with search and a
  color filter.
- **Statistics**: per year or all time, with a calendar, time per month,
  time of day, day of the week, and books by time read. Click a day for what
  was read that day.
- **Versions** (linked from Status and a book's Files): books known in more
  than one file, with how they were matched: the shared book ID, which
  files have the same text, which devices reported each file.
- **Status**: devices, the last import, and files that couldn't be read.
- **Settings**: book covers, descriptions, tags and series from a Calibre-Web Automated
  (or Calibre-Web) server (see [Covers](#covers)).

## How it works

```
WebDAV folder (read-only)              container
<folder>/Reading/devices/<id>/   ──►   ingest/ingest.lua (LuaJIT, every 60 s)
  seg-, ann-, book-, id-*.jsonl.zst      the plugin's own stores merge new files into
                                         /cache/statistics.sqlite3  (KOReader's schema)
                                         /cache/state.sqlite3       (the plugin's merged state)
                                       app/ (Starlette): reads those, serves the pages
```

The ingester runs the plugin's own modules (`concordance.koplugin/concordance/`):
the same merge rules, identity groups and packs a device uses, so the web
app shows what a device would. It acts like a device that only receives: it
never writes to the Reading folder and doesn't appear there as a device.

Each run imports only files it hasn't seen, then exits. A file that can't be
read is recorded and skipped until it changes. `/cache` can be deleted at any
time; the next run rebuilds it from the server's files.

## Running it

The image is published to `ghcr.io/spfenwick/concordance-web` (for amd64 and
arm64). With `compose.yaml` from this folder:

```sh
export READING_DIR=/srv/webdav/KOReader/Reading
docker compose pull && docker compose up -d     # the published image
docker compose up -d --build                    # or build it here
```

Then open `http://<server>:8080`. Or without compose:

```sh
docker run -d --name concordance-web -p 8080:8080 -e TZ=Pacific/Auckland \
  -v /srv/webdav/KOReader/Reading:/data/reading:ro -v concordance-web-cache:/cache \
  ghcr.io/spfenwick/concordance-web:latest
```

Image tags: `latest` (newest build from main), `web-X.Y.Z` (this app's version,
shown at the bottom of every page), `concordance-X.Y.Z` (built with that
Concordance version's code), `sha-<commit>`.

| Setting | Default | |
|---|---|---|
| `READING_DIR` | (required) | The host folder holding Concordance's `Reading/` (`<folder on server>/Reading`), mounted read-only |
| `TZ` | `Pacific/Auckland` | Time zone for days and "today" |
| `SYNC_INTERVAL` | `60` | Seconds between checks for new files. "Check for new data" on Status checks right away |
| `WEB_USERNAME`, `WEB_PASSWORD` | unset | Set both to require a password (HTTP basic auth) |

The container runs as UID 1000, which needs read access to `READING_DIR`
and write access to `/cache`. A named volume (as in `compose.yaml`) is set up
that way; a host folder needs `chown -R 1000:1000` first.
Without a password, put it behind a reverse proxy that handles sign-in, or
keep it on your own network. `/health` is open, for monitoring.

The image fetches a few KOReader files (lua-ljsqlite3, FFI headers, sha2,
the statistics plugin's schema) at the commits the plugin is tested
against; see the `ARG`s in the `Dockerfile`.

## Covers

Under Settings, enter your CWA server's OPDS address (the one KOReader's
OPDS catalog uses, e.g. `https://books.example.com/opds`) and its login, then
"Save and test". The app reads the catalog (all books, page by page) and
matches books by their Calibre UUID: OPDS entries are identified by it, and
Concordance's book identity records it from each EPUB. Files carrying a
`calibre:<id>` identifier match by ID too. Books without a match keep the
coloured spine.

Book descriptions and tags come from the catalog too. Series come from the
catalog's series feeds (`/opds/series`), which list each series' books in
order. Calibre-Web Automated doesn't put the series number in the catalog, so
books are listed in that order without "#3". Calibre-Web's entry text does
include the number. A description, series or tags (keywords) edited in
KOReader (custom metadata) come first.

- The app fetches covers itself and keeps them in `/cache/covers/`, so the
  browser never needs the CWA login. Each is checked for changes (by ETag)
  after a week; the catalog is read again daily, or on "Read the catalog
  again".
- Only books a device has sent book identity for can match (Concordance 0.6 or
  later, "Highlights and books" on), and PDFs carry no UUID.
- The login is kept in `/cache/settings.json`, readable only by the app's
  user. Anyone who can use the web interface can change the server it
  fetches from, so protect the interface (password or proxy).

## Publishing the image

`.github/workflows/web-image.yml` builds the image on every push to main
that changes `concordance-web/` or the plugin's modules, tests it
(`tests/smoke.sh`: sample data, every page), then pushes it for amd64 and
arm64. Pull requests are built and tested but not pushed. To publish without
a change, run it from Actions → "Concordance web image" → Run workflow.

Test a local build the same way: `docker build -f concordance-web/Dockerfile -t
concordance-web .` from the repository root, then `concordance-web/tests/smoke.sh`.

## Developing

Without Docker, using the KOReader checkouts the plugin's tests use
(`.cache/koreader-src`, made by `scripts/test-concordance.sh`):

```sh
K=$PWD/../.cache/koreader-src
export CONCORDANCE_LIB=$PWD/../concordance.koplugin KOREADER_BASE=$K/koreader-base \
       KOREADER_STATS=$K/koreader/plugins/statistics.koplugin/main.lua
luajit tests/make_fixture.lua /tmp/osw/Reading      # sample data: 2 devices, 6 files, a year of reading
python3 tests/fake_cwa.py &                          # a stand-in CWA: http://127.0.0.1:8790/opds, reader / secret
pip install -r requirements.txt
CONCORDANCE_READING_DIR=/tmp/osw/Reading CONCORDANCE_DATA_DIR=/tmp/osw/cache uvicorn app.main:app --reload
```

## Limits

- **No page numbers for highlights in EPUBs.** Devices don't send them (they
  depend on each device's layout), so highlights are listed by chapter, in
  reading order.
- **Pages read depend on layout.** Each device counts pages on its own
  layout. Progress is shown as a share of the book, which carries across
  devices.
- **Book titles** come from custom metadata if set, otherwise from the
  file's statistics or highlights records. Files the plugin's book identity
  joins (same UUID) are one book, with highlights and readings listed per
  file.
- **Read only.** Editing notes or statuses here would mean the app becoming a
  sending device with its own ID; not built.
