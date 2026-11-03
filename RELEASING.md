# Releasing the plugins

Each plugin (`knuthplass`, `rclonesync`, `statsync`) has its own version
(`version` in its `_meta.lua`) and its own releases, tagged
`<plugin>-vX.Y.Z`. Installed copies update themselves from GitHub with the
updater the plugins share (`shared/updatecore.lua`): once a day when online
(off / notify / install, set in each plugin's menu), or on "Check for
updates".

## Publishing a release

1. Set `version` in the plugin's `_meta.lua` (semantic versioning: the
   updater only installs a higher version).
2. Commit and push to main.
3. Either push a tag `<plugin>-v<version>` (e.g. `statsync-v0.2.2`), or run
   Actions → "Release plugin" → Run workflow on main, choosing the plugin
   (this creates the tag).

The workflow (`.github/workflows/release.yml`) checks the tag matches
`_meta.lua`, runs every plugin's tests (`scripts/test.sh` and
`scripts/test-statsync.sh`), zips `<plugin>.koplugin`, publishes it with a
`plugin.json` (version, URL, SHA-256) on the versioned release, and then
copies `plugin.json` to the plugin's rolling release, named after the plugin
(`releases/download/<plugin>/plugin.json`). The updater only reads that file,
so a release is visible to devices only once its zip is up.

Knuth–Plass releases up to 0.5.1 were tagged `vX.Y.Z`. Its rolling release
(`knuthplass`) didn't change, so copies installed from those keep updating.

## The shared updater

`shared/updatecore.lua` is the canonical copy. Each plugin carries an
identical copy under its own module name (`knuthplass_updatecore.lua`,
`rclonesync_updatecore.lua`, `statsync/updatecore.lua`): plugins share
Lua's module cache, so with one name, whichever plugin loaded first would
supply the updater for all of them, perhaps an older one. After changing it,
run `scripts/sync-updatecore.sh`; `tests/test_updatecore.lua` fails while a
copy differs. A change to the updater is released with each plugin's next
release.

## On devices

- The first version of a plugin with the updater (Knuth–Plass already has
  it; Settings sync 0.2.0 and Statistics sync 0.2.2 have it from their first
  release) has to be copied to the device by hand.
- Don't list these plugins in Settings sync's `plugins.txt`: the sync and the
  updater would both write their folders. Settings sync is for settings,
  patches and plugins not published here.
