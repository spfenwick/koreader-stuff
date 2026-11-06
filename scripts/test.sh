#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_bin=${LUA:-}
if [ -z "$lua_bin" ]; then
    lua_bin=$(command -v luajit || command -v lua || true)
fi
if [ -z "$lua_bin" ]; then
    echo "Lua 5.1 or LuaJIT is required (or set LUA=/path/to/interpreter)." >&2
    exit 1
fi

cd "$repo_dir"
"$lua_bin" tests/check_lua_syntax.lua \
    knuthplass.koplugin/_meta.lua \
    knuthplass.koplugin/main.lua \
    knuthplass.koplugin/knuthplass_updater.lua \
    knuthplass.koplugin/knuthplass_engine.lua \
    knuthplass.koplugin/knuthplass_loader.lua \
    knuthplass.koplugin/knuthplass_updatecore.lua \
    shared/updatecore.lua \
    omnisync.koplugin/_meta.lua \
    omnisync.koplugin/main.lua \
    omnisync.koplugin/omnisync/*.lua \
    cloudlibrary.koplugin/_meta.lua \
    cloudlibrary.koplugin/main.lua \
    cloudlibrary.koplugin/cloudlibrary/*.lua
"$lua_bin" tests/test_updatecore.lua
"$lua_bin" tests/test_plugin.lua
"$lua_bin" tests/test_omnisync_settings.lua
# The rest of omnisync.koplugin's tests need KOReader's sources and rclone:
# scripts/test-omnisync.sh
# cloudlibrary.koplugin's tests need a KOReader emulator build:
# tests/cloudlibrary/run_tests.sh
