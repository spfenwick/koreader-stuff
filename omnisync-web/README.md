# OmniSync web

A web app for browsing what OmniSync keeps on the server: books, highlights
and notes, reading statistics, collections and the reading history. It runs
as a Docker container on the machine that holds the WebDAV files, and only
reads them.

- **Home**: reading time today, this week, month and year, streaks, a
  calendar of the last 12 months, books being read, recent highlights.
- **Books**: filter by status or collection, search, and sort. A book's page
  has its review, rating, status, collections, reading time per day or week,
  highlights by chapter (downloadable as Markdown), bookmarks, sessions and
  files.
- **Highlights**: every highlight and note, newest first, with search and a
  color filter.
- **Statistics**: per year or all time, with a calendar, time per month,
  time of day, day of the week, and books by time read. Click a day for what
  was read that day.
- **Status**: devices, the last import, and files that couldn't be read.

## How it works

```
WebDAV folder (read-only)              container
<folder>/Reading/devices/<id>/   ──►   ingest/ingest.lua (LuaJIT, every 60 s)
  seg-, ann-, book-, id-*.jsonl.zst      the plugin's own stores merge new files into
                                         /cache/statistics.sqlite3  (KOReader's schema)
                                         /cache/state.sqlite3       (the plugin's merged state)
                                       app/ (Starlette): reads those, serves the pages
```

The ingester runs the plugin's own modules (`omnisync.koplugin/omnisync/`):
the same merge rules, identity groups and packs a device uses, so the web
app shows what a device would. It acts like a device that only receives: it
never writes to the Reading folder and doesn't appear there as a device.

Each run imports only files it hasn't seen, then exits. A file that can't be
read is recorded and skipped until it changes. `/cache` can be deleted at any
time; the next run rebuilds it from the server's files.

## Running it

The image is published to `ghcr.io/spfenwick/omnisync-web` (for amd64 and
arm64). With `compose.yaml` from this folder:

```sh
export READING_DIR=/srv/webdav/KOReader/Reading
docker compose pull && docker compose up -d     # the published image
docker compose up -d --build                    # or build it here
```

Then open `http://<server>:8080`. Or without compose:

```sh
docker run -d --name omnisync-web -p 8080:8080 -e TZ=Pacific/Auckland \
  -v /srv/webdav/KOReader/Reading:/data/reading:ro -v omnisync-web-cache:/cache \
  ghcr.io/spfenwick/omnisync-web:latest
```

Image tags: `latest` (newest build from main), `omnisync-X.Y.Z` (built with
that OmniSync version's code), `sha-<commit>`.

| Setting | Default | |
|---|---|---|
| `READING_DIR` | (required) | The host folder holding OmniSync's `Reading/` (`<folder on server>/Reading`), mounted read-only |
| `TZ` | `Pacific/Auckland` | Time zone for days and "today" |
| `SYNC_INTERVAL` | `60` | Seconds between checks for new files. "Check for new data" on Status checks right away |
| `WEB_USERNAME`, `WEB_PASSWORD` | unset | Set both to require a password (HTTP basic auth) |

The container runs as UID 1000, which needs read access to `READING_DIR`.
Without a password, put it behind a reverse proxy that handles sign-in, or
keep it on your own network. `/health` is open, for monitoring.

The image fetches a few KOReader files (lua-ljsqlite3, FFI headers, sha2,
the statistics plugin's schema) at the commits the plugin is tested
against; see the `ARG`s in the `Dockerfile`.

## Publishing the image

`.github/workflows/web-image.yml` builds the image on every push to main
that changes `omnisync-web/` or the plugin's modules, tests it
(`tests/smoke.sh`: sample data, every page), then pushes it for amd64 and
arm64. Pull requests are built and tested but not pushed. To publish without
a change, run it from Actions → "OmniSync web image" → Run workflow.

Test a local build the same way: `docker build -f omnisync-web/Dockerfile -t
omnisync-web .` from the repository root, then `omnisync-web/tests/smoke.sh`.

## Developing

Without Docker, using the KOReader checkouts the plugin's tests use
(`.cache/koreader-src`, made by `scripts/test-omnisync.sh`):

```sh
K=$PWD/../.cache/koreader-src
export OMNISYNC_LIB=$PWD/../omnisync.koplugin KOREADER_BASE=$K/koreader-base \
       KOREADER_STATS=$K/koreader/plugins/statistics.koplugin/main.lua
luajit tests/make_fixture.lua /tmp/osw/Reading      # sample data: 2 devices, 6 files, a year of reading
pip install -r requirements.txt
OMNISYNC_READING_DIR=/tmp/osw/Reading OMNISYNC_DATA_DIR=/tmp/osw/cache uvicorn app.main:app --reload
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
