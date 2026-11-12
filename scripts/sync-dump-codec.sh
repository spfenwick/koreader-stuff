#!/bin/sh
# Copies concordance.koplugin/concordance/codec.lua into
# tools/concordance-dump.lua (between its BEGIN and END lines), so the tool
# runs on its own. The tests fail if the copy differs from codec.lua.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
src=concordance.koplugin/concordance/codec.lua
tool=tools/concordance-dump.lua
begin='-- BEGIN concordance/codec.lua'
end='-- END concordance/codec.lua'
grep -qxF -- "$begin" "$tool" && grep -qxF -- "$end" "$tool" || { echo "$tool: BEGIN/END lines missing" >&2; exit 1; }
tmp=$(mktemp "$tool.XXXXXX")
awk -v src="$src" -v b="$begin" -v e="$end" '
    $0 == b { print; while ((getline line < src) > 0) print line; skip = 1; next }
    $0 == e { skip = 0 }
    !skip { print }
' "$tool" > "$tmp"
chmod +x "$tmp"
mv "$tmp" "$tool"
echo "updated $tool"
