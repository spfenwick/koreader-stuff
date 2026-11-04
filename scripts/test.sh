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
    supersync.koplugin/_meta.lua \
    supersync.koplugin/main.lua \
    supersync.koplugin/supersync/*.lua
"$lua_bin" tests/test_updatecore.lua
"$lua_bin" tests/test_plugin.lua
"$lua_bin" tests/test_supersync_settings.lua
# The rest of supersync.koplugin's tests need KOReader's sources and rclone:
# scripts/test-supersync.sh
