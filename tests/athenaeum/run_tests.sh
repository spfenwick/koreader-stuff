#!/bin/sh
# Runs tests/athenaeum/test_athenaeum.lua in a KOReader emulator's
# LuaJIT (it needs KOReader's SQLite, libarchive and luxl).
#   KOREADER_DIR=<koreader-emulator-…/koreader> tests/athenaeum/run_tests.sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dir=${KOREADER_DIR:-}
if [ -z "$dir" ]; then
    for candidate in "$repo"/../koreader/koreader-emulator-*/koreader; do
        if [ -x "$candidate/luajit" ]; then dir=$candidate; break; fi
    done
fi
if [ -z "$dir" ] || [ ! -x "$dir/luajit" ]; then
    echo "Set KOREADER_DIR to a KOReader emulator's koreader folder." >&2
    exit 2
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/athenaeum-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"
cd "$dir"
# KOReader's libraries log to stdout; keep only the test's own lines.
KO_HOME="$tmp/home" SDL_VIDEODRIVER=dummy ./luajit "$repo/tests/athenaeum/test_athenaeum.lua" "$repo" "$tmp" \
    > "$tmp/out.log" 2> "$tmp/err.log" && status=0 || status=$?
grep -h "^athenaeum:\|^FAIL\|rror" "$tmp/out.log" "$tmp/err.log" || true
if [ "$status" -ne 0 ] && ! grep -q "^athenaeum:" "$tmp/out.log"; then
    tail -n 20 "$tmp/err.log" "$tmp/out.log"
fi
exit "$status"
