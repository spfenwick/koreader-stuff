# OmniSync: settings

Keeps KOReader's settings, chosen plugins and patches, dictionaries, fonts
and style tweaks the same on several devices, through a Dropbox or WebDAV
server from Cloud storage. (This was SuperSync, and before that Settings sync.)
See [README.md](README.md) for installing and the menu.

Put the lists of what to sync in `koreader/omnisync/` (below). Tools →
OmniSync → "Sync settings" syncs; "Preview settings sync" shows what a
sync would change without changing it ("Sync now" there runs it). A sync
runs in the background, and tapping the message cancels it; running it
again finishes the job. It's also a gesture: General → "OmniSync: sync
settings". Settings sync only runs when you ask for it.

## What's synced

| On the server (under `<folder>/Settings`) | On the device | |
|---|---|---|
| `lists/` | `koreader/omnisync/settings.txt`, `plugins.txt`, `patches.txt` | first, so the rest use the new lists |
| `settings/` | what `settings.txt` lists in `settings/` (and with `//`, elsewhere) | put in place at the next start |
| `plugins/` | what `plugins.txt` lists in `plugins/` | |
| `patches/` | what `patches.txt` lists in `patches/` | |
| `fonts/` | `fonts/` | from the server only |
| `dict/` | `data/dict/` | |
| `styletweaks/` | `styletweaks/` | |
| `manifest.tsv` | | every synced file and its checksum |

Each list has one pattern per line, relative to its folder and starting
with `/`, so it matches only at the top of the folder: `*` matches within
a name, `**` across folders, `?` one character, `{a,b}` either, and lines
starting with `#` are comments. Anything not listed is left alone on both
sides. Without a list, that folder isn't synced.

`settings.txt`:

```
/gestures.lua
/ZenOS/**
//plugins/assistant.koplugin/configuration.lua
```

A line starting with `//` names a file elsewhere in KOReader's folder,
such as a setting a plugin keeps in its own folder. It's synced like the
other settings (put in place at the next start), and kept on the server
under `settings/@koreader/`. It has to be the exact path of one file, not
a pattern, and not in `settings/` (list those with a single `/`) or
`omnisync/`. Only `settings.txt` can have these lines.

`plugins.txt`:

```
/assistant.koplugin/**
```

OmniSync's own `settings/omnisync/device.lua` (this device's ID) and
`settings/omnisync/state.sqlite3` (its sync database) are never synced,
even if `settings.txt` matches them; `settings/omnisync/settings.lua` is.

Don't list the plugins from this repository (`omnisync.koplugin`,
`knuthplass.koplugin`): they update themselves from GitHub, and a sync
would fight the updater over their folders.

`patches.txt`:

```
/2-fold-8-fix.lua
/2-disable-unreadable-folder-warning.lua
```

Don't list `1-knuthplass-engine.lua` (or a pattern such as `/*.lua` that
matches it): the Knuth–Plass plugin writes it for each device itself.

## How it decides

Each device remembers what every file was when it last synced
(`koreader/omnisync/state.tsv`), so it can tell which side changed a
file:

- **Changed on one side:** the change is copied to the other, deletions
  included.
- **A file this device never had** is downloaded. It isn't taken as
  deleted here, so adding a line to a list on a device that doesn't have
  the file yet is safe.
- **Changed on both sides:** the newer one is kept, and the other is saved
  in `koreader/omnisync/conflicts/`. A sync says when this happens.
- **Changed on one side, deleted on the other:** the change is kept.

**Fonts** come from the server's `fonts/` folder (put them there yourself)
and are never uploaded or deleted: a font is downloaded when it's new or
has changed on the server, fonts installed on one device stay there, and a
font deleted on a device isn't downloaded again unless it changes on the
server. The manifest has each font's checksum, so a device that already has
a font (the same checksum) doesn't download it. As fonts are put on the
server by hand, a font changed there is noticed by its size or the
server's ID for the file.

## Moving to another server

Copy the whole folder (with `manifest.tsv`) from the old server to the new
one, then choose the new server under OmniSync → Server on each
device. Syncing then carries on without uploading or downloading anything.
The new server has its own IDs for the fonts, so the first sync takes fonts
the same size as in the manifest as the same fonts and notes their new IDs.
A font you also replaced with one of exactly the same size while moving
would be missed.

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

## Limits

- Dropbox and WebDAV only (Cloud storage's FTP isn't supported).
- On Dropbox, files over 150 MB can't be uploaded.
- File names can't contain tabs or line breaks.
- Device clocks decide which change is newer in a conflict.
