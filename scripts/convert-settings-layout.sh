#!/bin/sh
# Copies OmniSync's settings sync files on the server into the new layout,
# leaving the old ones in place:
#
#   <folder>/Settings/            old: manifest.tsv, lists/, settings/,
#                                 settings/@koreader/, plugins/, patches/,
#                                 fonts/, dict/, styletweaks/
#   <folder>/Files/manifest.tsv    new: one line per file, by its path in
#                                 KOReader's folder
#   <folder>/Files/files/<path>    new: the files, laid out as in KOReader's folder
#   <folder>/Files/files/settings/omnisync/sync.txt   the single list
#
# Usage: sh convert-settings-layout.sh /path/to/<folder>   (e.g. .../KOReader)
# Run it on the server, as the user the WebDAV server runs as. Devices make
# the same list from their own copies of the old lists (Migrate.convertLists
# in omnisync.koplugin/omnisync/migrate.lua): the two must stay byte for
# byte the same (tests/test_omnisync_settings.lua checks).
set -eu

folder=${1:?usage: $0 /path/to/folder-on-server}
old="$folder/Settings"
new="$folder/Files"
files="$new/files"

[ -f "$old/manifest.tsv" ] || { echo "no $old/manifest.tsv" >&2; exit 1; }
[ ! -e "$new" ] || { echo "$new exists already; remove it to start again" >&2; exit 1; }

mkdir -p "$files/settings/omnisync"

# 1. The files. Copies keep their times; the old ones stay where they are.
copy() { # copy <old subfolder> <new subfolder>
    if [ -d "$old/$1" ]; then
        mkdir -p "$files/$2"
        cp -a "$old/$1/." "$files/$2/"
    fi
}
copy settings settings
copy plugins plugins
copy patches patches
copy fonts fonts
copy dict data/dict
copy styletweaks styletweaks
# Files that settings.txt named with //: in their own place in KOReader's folder.
if [ -d "$files/settings/@koreader" ]; then
    cp -a "$files/settings/@koreader/." "$files/"
    rm -rf "$files/settings/@koreader"
fi
# SuperSync's own settings file: its OmniSync replacement is uploaded by the
# devices at their next sync.
rm -f "$files/settings/supersync_settings.lua"
# Half-written uploads.
find "$files" -name '*.supersync-part' -o -name '*.omnisync-part' | while read -r f; do rm -f "$f"; done

# 2. The single list, from the three old ones (missing ones add nothing).
list="$files/settings/omnisync/sync.txt"
convert() { # convert <list> <folder prefix>
    [ -f "$old/lists/$1" ] || return 0
    printf '# From %s\n' "$1"
    tr -d '\r' < "$old/lists/$1" | while IFS= read -r line || [ -n "$line" ]; do
        t=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$t" in
            ''|'#'*|';'*) printf '%s\n' "$line" ;;
            /supersync_settings.lua) if [ "$2" = settings ]; then printf '/settings/omnisync/settings.lua\n'; fi ;;
            //*) if [ "$2" = settings ]; then printf '%s\n' "${t#/}"; fi ;;
            /*) printf '/%s%s\n' "$2" "$t" ;;
            *) printf '/%s/%s\n/%s/**/%s\n' "$2" "$t" "$2" "$t" ;;
        esac
    done
}
{
    printf '# What OmniSync syncs: one pattern per line, from KOReader'"'"'s folder.\n'
    printf '# A line starting with < is only ever pulled from the server.\n\n'
    convert settings.txt settings
    convert plugins.txt plugins
    convert patches.txt patches
    printf '# Synced in every folder before\n< /fonts/**\n/data/dict/**\n/styletweaks/**\n'
} > "$list"

# 3. The manifest: path, md5, size, time, device, server ID (left empty:
# the copies have new ones, filled in at the next sync).
size=$(wc -c < "$list" | tr -d ' ')
hash=$(md5sum "$list" | cut -d' ' -f1)
{
    printf '#\tOmniSync manifest\t3\n'
    awk -F '\t' -v OFS='\t' '
        $1 == "#" || $1 == "lists" || $3 == "" { next }
        $1 == "settings" && $2 == "supersync_settings.lua" { next }
        $1 == "settings" && substr($2, 1, 10) == "@koreader/" { p = substr($2, 11) }
        $1 == "settings" && substr($2, 1, 10) != "@koreader/" { p = "settings/" $2 }
        $1 == "plugins" || $1 == "patches" || $1 == "fonts" || $1 == "styletweaks" { p = $1 "/" $2 }
        $1 == "dict" { p = "data/dict/" $2 }
        p != "" { print p, $3, $4, $5, $6, ""; p = "" }
    ' "$old/manifest.tsv"
    printf 'settings/omnisync/sync.txt\t%s\t%s\t%s\tserver\t\n' "$hash" "$size" "$(date +%s)"
} > "$new/manifest.tsv.part"
# Entries whose file isn't on the server (deleted there by hand) are left
# out: as if never synced. Then sorted, as the plugin writes it.
tab=$(printf '\t')
{
    head -n 1 "$new/manifest.tsv.part"
    tail -n +2 "$new/manifest.tsv.part" | LC_ALL=C sort | while IFS= read -r line; do
        p=${line%%"$tab"*}
        if [ -f "$files/$p" ]; then
            printf '%s\n' "$line"
        else
            printf 'left out, not on the server: %s\n' "$p" >&2
        fi
    done
} > "$new/manifest.tsv"
rm "$new/manifest.tsv.part"

echo "Done: $(($(wc -l < "$new/manifest.tsv") - 1)) files in $new/manifest.tsv"
echo "The list ($list):"
cat "$list"
