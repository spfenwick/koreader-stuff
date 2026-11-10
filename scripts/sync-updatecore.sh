#!/bin/sh
# Copies shared/updatecore.lua (the updater the plugins share) into each
# plugin, under the module name it uses there. The tests fail if a copy
# differs from shared/updatecore.lua.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
for target in \
    knuthplass.koplugin/knuthplass_updatecore.lua \
    concordance.koplugin/concordance/updatecore.lua \
    cloudlibrary.koplugin/cloudlibrary/updatecore.lua
do
    cp shared/updatecore.lua "$target"
    echo "updated $target"
done
