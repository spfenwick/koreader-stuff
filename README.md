# koreader-stuff

KOReader plugins for syncing your reading between devices, browsing an
online library, and better justified text, plus a web app for the reading
data.

| | What it does | Docs |
| --- | --- | --- |
| <img src="assets/logos/concordance.svg" width="20" alt=""> **Concordance** (`concordance.koplugin`) | Keeps settings, reading statistics, highlights, bookmarks, book status, collections and history the same on every device, through your own WebDAV (or Dropbox) server | [README](concordance.koplugin/README.md) |
| **Concordance web** (`concordance-web/`) | A web app that shows what Concordance keeps on the server: books, highlights, reading statistics | [README](concordance-web/README.md) |
| <img src="assets/logos/athenaeum.svg" width="20" alt=""> **Athenaeum** (`athenaeum.koplugin`, formerly Cloud library) | Lists every book in your Calibre-Web Automated library in the file browser, downloaded or not (needs ZenOS) | [User guide](USER_GUIDE.md#athenaeum) |
| **Knuth–Plass justification** (`knuthplass.koplugin`) | Knuth–Plass paragraph line breaking, with a custom KOReader engine it installs itself | [README](knuthplass.koplugin/README.md) |

See the [user guide](USER_GUIDE.md) for using Athenaeum and Concordance,
together or on their own.

## Concordance web

The image is `ghcr.io/spfenwick/concordance-web` (amd64 and arm64). Run it
on the machine that holds Concordance's WebDAV files; it only reads them.

```sh
docker run -d --name concordance-web -p 8080:8080 -e TZ=Pacific/Auckland \
  -v /srv/webdav/KOReader/Reading:/data/reading:ro -v concordance-web-cache:/cache \
  ghcr.io/spfenwick/concordance-web:latest
```

Then open `http://<server>:8080`. Mount your server's
`<folder on server>/Reading` (by default `KOReader/Reading`) at
`/data/reading`. Set `WEB_USERNAME` and `WEB_PASSWORD` to require a
password.

| Tag | |
| --- | --- |
| `latest` | The newest build from main |
| `concordance-X.Y.Z` | Built with Concordance X.Y.Z's code |
| `sha-<commit>` | Every build |

[concordance-web/README.md](concordance-web/README.md) has the full
settings, a `compose.yaml` and what each page shows.

## Installing the plugins

Download a plugin's zip from [Releases](https://github.com/spfenwick/koreader-stuff/releases),
unzip it into KOReader's `plugins/` folder and restart KOReader. After that,
each plugin updates itself: Tools → the plugin → Check for updates, or
Automatic updates (once a day, asking first by default). Concordance checks
for Athenaeum's updates too.

## Development

```sh
scripts/test.sh                   # all plugins' quick tests
scripts/test-concordance.sh       # Concordance's statistics and highlights tests (LuaJIT, rclone)
tests/athenaeum/run_tests.sh      # Athenaeum (needs a KOReader emulator build)
```

Releases: see [RELEASING.md](RELEASING.md).

## License

AGPL-3.0, the same as KOReader.
