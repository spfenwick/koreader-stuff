#!/bin/sh
# Tests for supersync.koplugin's statistics and annotations sync.
#
#   scripts/test-supersync.sh           unit tests + integration test
#   scripts/test-supersync.sh unit      unit tests only
#   scripts/test-supersync.sh bench     5-year benchmark (slow)
#
# Needs LuaJIT, libsqlite3, LuaFileSystem, and for the integration test and
# benchmark, rclone (as the WebDAV server). KOReader's sources are used for
# its statistics plugin and lua-ljsqlite3: set KOREADER_SRC to a folder with
# koreader/ and koreader-base/ checkouts, or they're cloned into .cache/.
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
lua_bin=${LUA:-$(command -v luajit || true)}
if [ -z "$lua_bin" ]; then
    echo "supersync tests need LuaJIT (or set LUA=)." >&2
    exit 1
fi

if [ -z "${KOREADER_SRC:-}" ]; then
    KOREADER_SRC="$repo_dir/.cache/koreader-src"
    for r in koreader koreader-base; do
        if [ ! -d "$KOREADER_SRC/$r" ]; then
            mkdir -p "$KOREADER_SRC"
            git clone -q --depth 1 "https://github.com/koreader/$r" "$KOREADER_SRC/$r"
        fi
    done
fi
export KOREADER_SRC
STATSYNC_TMP=${STATSYNC_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/statsync-test.XXXXXX")}
export STATSYNC_TMP

"$lua_bin" tests/check_lua_syntax.lua supersync.koplugin/*.lua supersync.koplugin/supersync/*.lua

what=${1:-all}
case "$what" in
    unit) "$lua_bin" tests/test_supersync.lua && "$lua_bin" tests/test_supersync_ann.lua ;;
    bench) "$lua_bin" tests/bench_supersync.lua ;;
    *)
        "$lua_bin" tests/test_supersync.lua
        "$lua_bin" tests/test_supersync_ann.lua
        "$lua_bin" tests/test_supersync_integration.lua
        "$lua_bin" tests/test_supersync_plugin.lua
        ;;
esac
