# Settings sync (rclonesync.koplugin)

Pushes and pulls KOReader settings to a cloud remote with
[rclone](https://rclone.org), so several devices can share them. It
replaces the `PushSettings.sh` / `PullSettings.sh` / `PushTweaks.sh` /
`PullTweaks.sh` scripts and uses the same rclone folder. The remote layout
is close to the scripts', but not the same (see
[Moving from the scripts](#moving-from-the-scripts)).

## Install

1. Copy `rclonesync.koplugin` into KOReader's `plugins/` folder.
2. Keep (or create) the rclone folder next to KOReader's, as the scripts
   had it: `rclone` (the binary for the device), `rclone.conf`, and the
   lists of what to sync: `settings.txt`, `plugins.txt` and `patches.txt`.
   - Kobo: `.adds/rclone/` (next to `.adds/koreader/`)
   - Kindle: `/mnt/us/rclone/`
   - Linux: `~/.config/rclone/` (a system `rclone` on the PATH is used if
     the folder has no binary)
   - Android: `/sdcard/rclone/` (see below)

   `koreader/rclone/` and the plugin's own folder are also looked in, or
   choose any folder in the menu.
3. Restart KOReader.

The menu is in Tools → "Settings sync", in both the file browser and the
reader. The four actions can also be assigned to gestures (under General:
"Settings sync: Push settings" and so on).

## What's synced

| Remote (`<root>` = `/KOReader/Settings`) | Device | Direction |
|---|---|---|
| `rclone/settings.txt`, `plugins.txt`, `patches.txt` | rclone folder | both, first |
| `settings/` | what `settings.txt` lists in `settings/` | both |
| `plugins/` | what `plugins.txt` lists in `plugins/` | both |
| `patches/` | what `patches.txt` lists in `patches/` | both |
| `fonts/` | `fonts/` | pull only, nothing deleted |
| `dict/` | `data/dict/` | both |
| `styletweaks/` | `styletweaks/` | both |

"Style tweaks only" syncs just the lists and `styletweaks/`. As with
the scripts, everything except fonts is `rclone sync --checksum`: the
destination ends up matching the source, deletions included.

Each list has one rclone pattern per line, relative to its folder and
starting with `/`, so it matches only at the top of the folder:

`settings.txt`:

```
/gestures.lua
/ZenOS/**
```

`plugins.txt`:

```
/assistant.koplugin/configuration.lua
/bookshortcuts.koplugin/**
```

`patches.txt`:

```
/2-fold-8-fix.lua
/2-disable-unreadable-folder-warning.lua
```

Anything not listed is left alone on both sides: a pull doesn't delete it,
and a push doesn't send it. A list that's missing turns that folder's sync
off.

- **Settings** are KOReader's `settings/` folder. Files elsewhere in
  KOReader's folder (like `settings.reader.lua`) aren't synced.
- **Plugins:** list only the ones to share, so large plugins and the ones
  ZenPM updates stay out. A whole plugin is `/name.koplugin/**`; a plugin's
  settings file on its own is `/name.koplugin/file.lua`.
- **Patches:** don't list `1-knuthplass-engine.lua` (or a pattern such as
  `/*.lua` that matches it). The Knuth–Plass plugin writes it for each
  device itself.
- **Fonts** are only pulled, and a pull adds and updates fonts but never
  deletes any. Fonts installed on one device (and KOReader's own) stay
  there, and a font removed from the remote stays on devices that have it.
- **Icons** aren't synced.
- **A folder missing on the device** is skipped on push instead of emptying
  the remote copy.

## Moving from the scripts

- `settings.txt` entries are now relative to `settings/`:
  `/settings/gestures.lua` becomes `/gestures.lua`. Entries outside
  `settings/` (like `/plugins/assistant.koplugin/configuration.lua`) move to
  `plugins.txt` (`/assistant.koplugin/configuration.lua`).
- `plugins.txt` lists the plugins *to* sync. The scripts' commented-out
  plugin sync used it as a list of plugins *not* to sync.
- `patches.txt` is new. Without it, patches aren't synced.
- On the remote, settings are now at `<root>/settings/gestures.lua`, not
  `<root>/settings/settings/gestures.lua`. Push from one device first. The
  old copies under `<root>/settings/settings/` are left behind; delete
  that folder once every device uses the plugin. Devices still on the
  scripts won't pick up settings pushed by the plugin.

## Differences from the scripts

- **Pushing saves first.** KOReader writes its in-memory settings to disk
  before the push, so what's pushed is what's in use.
- **Pulled settings files go in place at the next start.** KOReader keeps
  files like `gestures.lua` in memory and would write the old values over
  freshly pulled ones. So a pull puts them in `koreader/rclonesync/staging/`
  and asks to restart. As KOReader starts, before any plugin reads its
  settings, the plugin copies them into place. Until then, "Push settings"
  is refused (it would send the old ones back), and the menu offers to
  discard them. Plugins, fonts, patches, dictionaries and style tweaks are
  pulled straight into place (a pulled plugin is used after the restart).
- **Wi-Fi** is turned on if needed (KOReader asks as usual).
- **Certificates:** rclone uses KOReader's own `data/ca-bundle.crt`, so
  there's no download from curl.se.
- **Output:** a summary when a sync finishes, the log when one fails, and
  "Show last log" in the menu (`koreader/rclonesync/last.log`). "Dry run"
  shows what would change without changing anything.
- **Remote:** chosen from the remotes in `rclone.conf` (the first by
  default). The folder on the remote can be changed too.
- **Not included:** `InstallPatch.sh`, which copied an engine over
  `libs/libkoreader-cre.so`. The Knuth–Plass plugin's updater now installs
  and updates the engine without replacing KOReader's own. The `.sh`
  scripts on the remote are left as they are.

## Android

Android won't run programs from shared storage. So the plugin copies
`rclone` (an `android-arm64` build) into the app's private storage, next
to the Knuth–Plass engine, and runs it from there. It copies it again when
the file changes. This is untested; if it fails, the log says so.
