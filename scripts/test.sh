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
    concordance.koplugin/_meta.lua \
    concordance.koplugin/main.lua \
    concordance.koplugin/concordance/*.lua \
    athenaeum.koplugin/_meta.lua \
    athenaeum.koplugin/main.lua \
    athenaeum.koplugin/athenaeum/*.lua
"$lua_bin" tests/test_updatecore.lua
"$lua_bin" tests/test_plugin.lua
"$lua_bin" tests/test_athenaeum_migrate.lua
"$lua_bin" tests/test_concordance_settings.lua
# The rest of concordance.koplugin's tests need KOReader's sources and rclone:
# scripts/test-concordance.sh
# athenaeum.koplugin's tests need a KOReader emulator build:
# tests/athenaeum/run_tests.sh
