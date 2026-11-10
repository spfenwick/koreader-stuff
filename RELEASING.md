# Releasing the plugins

Each plugin (`knuthplass`, `concordance`, `cloudlibrary`) has its own version
(`version` in its `_meta.lua`) and its own releases, tagged
`<plugin>-vX.Y.Z`. Installed copies update themselves from GitHub with the
updater the plugins share (`shared/updatecore.lua`): once a day when online
(off / notify / install, set in each plugin's menu), or on "Check for
updates".

## Publishing a release

1. Set `version` in the plugin's `_meta.lua` (semantic versioning: the
   updater only installs a higher version).
2. Commit and push to main. That's all: a push to main that changes a
   plugin's `_meta.lua` releases every plugin whose version has no
   `<plugin>-v<version>` release yet, tagging the commit pushed. Change
   both plugins' versions in one push and both are released.

To release without a push to main (or again after a failed run): push a tag
`<plugin>-v<version>` (e.g. `concordance-v1.0.0`) yourself, or run Actions →
"Release plugin" → Run workflow on main, choosing the plugin (this creates
the tag).

The workflow (`.github/workflows/release.yml`) checks the tag matches
`_meta.lua` (or that the version isn't released yet), runs every plugin's
tests once (`scripts/test.sh` and
`scripts/test-concordance.sh`), zips `<plugin>.koplugin`, publishes it with a
`plugin.json` (version, URL, SHA-256) on the versioned release, and then
copies `plugin.json` to the plugin's rolling release, named after the plugin
(`releases/download/<plugin>/plugin.json`). The updater only reads that file,
so a release is visible to devices only once its zip is up.

Knuth–Plass releases up to 0.5.1 were tagged `vX.Y.Z`. Its rolling release
(`knuthplass`) didn't change, so copies installed from those keep updating.

Concordance replaced Settings sync (`rclonesync`) and Statistics sync
(`statsync`), as SuperSync, and was then renamed OmniSync (`omnisync`), and
then Concordance (`concordance`, versions from 0.1.0 again). Their releases
stay as they were; installed copies of them don't update to Concordance,
which is installed by hand once (it takes over OmniSync's data, see
`concordance.koplugin/README.md`).

## The shared updater

`shared/updatecore.lua` is the canonical copy. Each plugin carries an
identical copy under its own module name (`knuthplass_updatecore.lua`,
`concordance/updatecore.lua`, `cloudlibrary/updatecore.lua`): plugins share
Lua's module cache, so with one name, whichever plugin loaded first would
supply the updater for all of them, perhaps an older one. After changing it,
run `scripts/sync-updatecore.sh`; `tests/test_updatecore.lua` fails while a
copy differs. A change to the updater is released with each plugin's next
release.

## On devices

- The first version of a plugin with the updater (Knuth–Plass already has
  it; Concordance has it from its first release; Cloud library from 0.1.0)
  has to be copied to the device by hand.
- Concordance's settings sync never syncs these plugins' folders (even if
  `sync.txt` lists them): the sync and the updater would both write them.
  Settings sync is for settings, patches and plugins not published here.
