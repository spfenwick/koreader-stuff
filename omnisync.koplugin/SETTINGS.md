# OmniSync: settings

Keeps KOReader's settings, chosen plugins and patches, dictionaries, fonts
and style tweaks the same on several devices, through a Dropbox or WebDAV
server from Cloud storage. (This was SuperSync, and before that Settings sync.)
See [README.md](README.md) for installing and the menu.

List what to sync in `settings/omnisync/sync.txt` (below). Tools →
OmniSync → "Sync settings" syncs; "Preview settings sync" shows what a
sync would change without changing it ("Sync now" there runs it). A sync
runs in the background, and tapping the message cancels it; running it
again finishes the job. It's also a gesture: General → "OmniSync: sync
settings". Settings sync only runs when you ask for it.

## What's synced

What `settings/omnisync/sync.txt` lists, from anywhere in KOReader's
folder. The list itself is always synced, first, so the rest of the sync
uses the newest one: change it on any device and the others get it.

```
# One pattern per line, from KOReader's folder.
/settings/gestures.lua
/settings/ZenOS/**
/plugins/assistant.koplugin/configuration.lua
/patches/2-fold-8-fix.lua
< /fonts/**
/data/dict/**
/styletweaks/**
```

Every line starts with `/`, KOReader's folder: `*` matches within a name,
`**` across folders, `?` one character, `{a,b}` either, and lines starting
with `#` are comments. Anything not listed is left alone on both sides. A
line that can't be used (one not starting with `/`, say) is reported by the
sync and skipped.

A line starting with `<` names files that are only ever pulled from the
server, such as fonts (see below).

On the server, under `<folder>/Files`:

| | |
|---|---|
| `files/` | the files, laid out as in KOReader's folder |
| `manifest.tsv` | every synced file and its checksum |

**Never synced**, whatever the list says (a sync's log says when it
skipped one):

- OmniSync's own `settings/omnisync/device.lua` (this device's ID),
  `state.sqlite3` (its sync database) and `settings-sync/` (settings sync's
  state). `settings/omnisync/settings.lua` and the list are synced.
- `cache/`.
- The plugins from this repository (`omnisync.koplugin`,
  `knuthplass.koplugin`): they update themselves from GitHub, and a sync
  would fight the updater over their folders.

Don't list `patches/1-knuthplass-engine.lua` (or a pattern such as
`/patches/*.lua` that matches it): the Knuth–Plass plugin writes it for
each device itself.

**When pulled files are used:** plugins, patches, fonts, dictionaries
(`data/dict/`) and style tweaks are written straight away; all but the
style tweaks need a restart, which the sync offers. Everything else
(settings, and files elsewhere in KOReader's folder) is put in place at
the next start (see below).

## How it decides

Each device remembers what every file was when it last synced
(`settings/omnisync/settings-sync/state.tsv`), so it can tell which side changed a
file:

- **Changed on one side:** the change is copied to the other, deletions
  included.
- **A file this device never had** is downloaded. It isn't taken as
  deleted here, so adding a line to the list on a device that doesn't have
  the file yet is safe.
- **Changed on both sides:** the newer one is kept, and the other is saved
  in `settings/omnisync/settings-sync/conflicts/`. A sync says when this happens.
- **Changed on one side, deleted on the other:** the change is kept.

**Files only ever pulled** (lines starting with `<`, such as fonts) come
from the server's `files/` folder (put them there yourself, e.g. fonts in
`files/fonts/`) and are never uploaded or deleted: a file is downloaded
when it's new or has changed on the server, files put on one device stay
there, and a file deleted on a device isn't downloaded again unless it
changes on the server. The manifest has each file's checksum, so a device
that already has a file (the same checksum) doesn't download it. As these
files are put on the server by hand, a file changed there is noticed by its
size or the server's ID for the file.

## Moving to another server

Copy the whole folder (with `manifest.tsv`) from the old server to the new
one, then choose the new server under OmniSync → Server on each
device. Syncing then carries on without uploading or downloading anything.
The new server has its own IDs for the files only ever pulled (fonts), so
the first sync takes those the same size as in the manifest as the same
files and notes their new IDs. A font you also replaced with one of exactly
the same size while moving would be missed.

**Settings files** are put in place the next time KOReader starts, before
any plugin reads them, because KOReader keeps files like `gestures.lua` in
memory and would otherwise write the old values back. A sync that pulls
settings asks to restart. Until then a full sync is refused (it would send
the old ones back), and the menu offers to discard them, which keeps this
device's settings; the next sync sends them.

Before a sync, KOReader saves its settings, so what's synced is what's in
use. Files are downloaded to a temporary name and then put in place, so a
file in use (such as a font) is replaced rather than rewritten.

## A folder without a manifest

A folder on the server without `manifest.tsv` is new to the sync (or not
copied there yet). What a device remembers from its last sync is about
another folder then, so it's set aside: the sync is like a first sync,
uploading this device's files and deleting nothing. (Earlier, every file
synced before looked deleted on the server, and was deleted here.)

## The first sync

- The first device to sync adds its files to the manifest. On Dropbox,
  files the scripts already put there aren't uploaded again if they're the
  same: the plugin checks them against Dropbox's checksums ("already on the
  server" in the preview). Others are uploaded. On WebDAV, which has no
  checksums, they're all uploaded once.
- Sync first from the device whose settings you want to keep; other
  devices then download what's different, and where both had a file that
  differs, the newer is kept and the other saved in `conflicts/`.

## From the earlier layout

Settings sync used to have three lists in `koreader/omnisync/`
(`settings.txt`, `plugins.txt`, `patches.txt`, each relative to its
folder, with `//` for files elsewhere) and fonts, dictionaries and style
tweaks always synced, on the server under `<folder>/Settings`. On the first
start of this version, each device makes `sync.txt` from its three lists
(keeping them in `settings-sync/old-lists/`), adds `< /fonts/**`,
`/data/dict/**` and `/styletweaks/**`, and moves the rest of
`koreader/omnisync/` into `settings/omnisync/settings-sync/`.

The server's files are copied to the new layout by hand, once, with
`scripts/convert-settings-layout.sh` (run on the server; it leaves
`Settings/` in place). It makes the same `sync.txt` from the server's copy
of the lists, so devices and server agree and nothing is sent again. Run
it just before updating the devices: changes synced to `Settings/` after it
ran aren't in `Files/`.

## Limits

- Dropbox and WebDAV only (Cloud storage's FTP isn't supported).
- On Dropbox, files over 150 MB can't be uploaded.
- File names can't contain tabs or line breaks.
- Device clocks decide which change is newer in a conflict.
