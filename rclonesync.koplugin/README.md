# Settings sync (rclonesync.koplugin)

Keeps KOReader's settings, chosen plugins and patches, dictionaries, fonts
and style tweaks the same on several devices, through a Dropbox or WebDAV
server. It needs nothing installed beyond KOReader: it uses the servers
set up in KOReader's Cloud storage, and does the syncing itself.

## Install

1. Copy `rclonesync.koplugin` into KOReader's `plugins/` folder and restart
   KOReader.
2. Add your Dropbox or WebDAV server in Cloud storage (file browser → Cloud
   storage), if it isn't there already. Settings sync uses the first one,
   or the one chosen under Settings sync → Server.
3. Put the lists of what to sync in `koreader/rclonesync/` (see below).

The menu is in Tools → "Settings sync", in both the file browser and the
reader:

- **Sync**: everything below.
- **Preview sync**: shows what a sync would change, without changing it.
- **Server** and **Folder on server** (`/KOReader/Settings` by default).
- **Show last log**.

Sync can be assigned to a gesture (General → "Settings sync: sync"). A sync runs in the background, and
tapping the message cancels it; running it again finishes the job.

## What's synced

| On the server (under the folder) | On the device | |
|---|---|---|
| `lists/` | `koreader/rclonesync/settings.txt`, `plugins.txt`, `patches.txt` | first, so the rest use the new lists |
| `settings/` | what `settings.txt` lists in `settings/` | put in place at the next start |
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
```

`plugins.txt`:

```
/rclonesync.koplugin/**
/assistant.koplugin/configuration.lua
```

`patches.txt`:

```
/2-fold-8-fix.lua
/2-disable-unreadable-folder-warning.lua
```

Don't list `1-knuthplass-engine.lua` (or a pattern such as `/*.lua` that
matches it): the Knuth–Plass plugin writes it for each device itself.

## How it decides

Each device remembers what every file was when it last synced
(`koreader/rclonesync/state.tsv`), so it can tell which side changed a
file:

- **Changed on one side:** the change is copied to the other, deletions
  included.
- **A file this device never had** is downloaded. It isn't taken as
  deleted here, so adding a line to a list on a device that doesn't have
  the file yet is safe.
- **Changed on both sides:** the newer one is kept, and the other is saved
  in `koreader/rclonesync/conflicts/`. A sync says when this happens.
- **Changed on one side, deleted on the other:** the change is kept.

**Fonts** come from the server's `fonts/` folder (put them there yourself)
and are never uploaded or deleted: a font is downloaded when it's new or
has changed on the server, fonts installed on one device stay there, and a
font deleted on a device isn't downloaded again unless it changes on the
server.

**Settings files** are put in place the next time KOReader starts, before
any plugin reads them, because KOReader keeps files like `gestures.lua` in
memory and would otherwise write the old values back. A sync that pulls
settings asks to restart. Until then a full sync is refused (it would send
the old ones back), and the menu offers to discard them, which keeps this
device's settings; the next sync sends them.

Before a sync, KOReader saves its settings, so what's synced is what's in
use. Files are downloaded to a temporary name and then put in place, so a
file in use (such as a font) is replaced rather than rewritten.

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
