#!/bin/sh
# Smoke test for a built image: writes the sample Reading folder with the
# image's own LuaJIT and plugin code, starts the app on it, and checks the
# import and every page.
#
#   concordance-web/tests/smoke.sh [image]     (default: concordance-web)
set -eu

image=${1:-concordance-web}
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/osw-smoke.XXXXXX")
name="osw-smoke-$$"
port=${SMOKE_PORT:-18080}

cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# The fixture, written inside the image (it has LuaJIT, zstd and the plugin's modules).
docker run --rm --user "$(id -u):$(id -g)" -v "$here:/tests:ro" -v "$work:/work" \
    -e LUA_PATH="/opt/concordance-web/ingest/?.lua;;" \
    "$image" luajit /tests/make_fixture.lua /work/Reading
chmod -R a+rX "$work"

docker run -d --name "$name" -p "127.0.0.1:$port:8080" -v "$work/Reading:/data/reading:ro" \
    -v "$here:/tests:ro" "$image" >/dev/null

base="http://127.0.0.1:$port"
i=0
until curl -sf "$base/status" | grep -q '23 highlights'; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "smoke: data never appeared" >&2
        curl -s "$base/status" | sed -n '/<main/,/<\/main>/p' | sed 's/<[^>]*>//g' | grep -v '^\s*$' >&2 || true
        ls -lR "$work/Reading" >&2
        docker logs "$name" >&2
        exit 1
    fi
    sleep 1
done

book=$(curl -sf "$base/books" | grep -o '/book/[0-9a-f]\{32\}' | head -1)
fail=0
for path in / /books "$book" "$book/highlights.md" /highlights "/highlights?q=whale" /stats "/stats?year=all" \
            /collections /authors /series /tags "/books?author=Jane%20Austen" /versions /status /health; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base$path")
    echo "$code $path"
    [ "$code" = 200 ] || fail=1
done
# The app's version at the bottom of every page.
web_version=$(sed -n 's/^VERSION = "\([0-9][0-9.]*\)".*/\1/p' "$(dirname "$0")/../app/version.py")
if curl -sf "$base/" | grep -q "Concordance web $web_version<"; then
    echo "200 version $web_version shown"
else
    echo "smoke: version $web_version not shown at the bottom of the page" >&2
    fail=1
fi
# Versions: the two files of Pride and Prejudice, joined by their UUID, with different texts.
versions=$(curl -sf "$base/versions")
if echo "$versions" | grep -q '1a2b3c4d-0000-4000-8000-000000000001' && echo "$versions" | grep -q '2 texts'; then
    echo "200 versions listed"
    if echo "$versions" | grep -q 'class="level-title"'; then
        echo "200 file joined by title listed"
    else
        echo "versions: Frankenstein's older copy not joined by title" >&2; fail=1
    fi
    if echo "$versions" | grep -q 'class="level-id"'; then
        echo "200 files sharing only the book ID grouped"
    else
        echo "versions: Pride and Prejudice's editions not grouped by book ID" >&2; fail=1
    fi
    if echo "$versions" | grep -q 'Matched to its catalog book by Cloud library'; then
        echo "200 file linked by Cloud library listed"
    else
        echo "versions: Moby-Dick's PDF not joined through its link" >&2; fail=1
    fi
else
    echo "versions: Pride and Prejudice's files not listed" >&2; fail=1
fi
# Covers: a stand-in CWA server inside the container, set up through the settings form.
docker exec -d "$name" python3 /tests/fake_cwa.py 8790
sleep 1
saved=$(curl -s -o /dev/null -w '%{redirect_url}' -X POST -H 'Sec-Fetch-Site: same-origin' \
    -d 'cwa_url=http://127.0.0.1:8790/opds&cwa_username=reader&cwa_password=secret&action=save' "$base/settings")
case "$saved" in *notice=Connected*) echo "200 settings saved" ;; *) echo "settings: $saved" >&2; fail=1 ;; esac
cross=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Sec-Fetch-Site: cross-site' -d 'action=remove' "$base/settings")
[ "$cross" = 403 ] && echo "403 cross-site post refused" || { echo "cross-site post: $cross" >&2; fail=1; }
i=0
until curl -sf "$base/books" | grep -q 'class="cover"'; do
    i=$((i + 1))
    if [ "$i" -gt 30 ]; then echo "smoke: no covers matched" >&2; fail=1; break; fi
    sleep 1
done
cover=$(curl -sf "$base/books" | grep -o '/cover/[0-9a-f]\{32\}' | head -1)
ctype=$(curl -s -o /dev/null -w '%{content_type}' "$base$cover")
[ "$ctype" = image/png ] && echo "200 $cover" || { echo "cover $cover: $ctype" >&2; fail=1; }
# Tags and series: from the catalog (entries, Calibre-Web's entry text, series
# feeds) and from KOReader's own metadata (Middlemarch).
has() { # page, text, what it shows
    if curl -sf "$base$1" | grep -qF -- "$2"; then echo "200 $3"; else echo "$1: no \"$2\" ($3)" >&2; fail=1; fi
}
lacks() {
    if curl -sf "$base$1" | grep -qF -- "$2"; then echo "$1: \"$2\" shouldn't be there ($3)" >&2; fail=1; else echo "200 $3"; fi
}
has /tags 'href="/books?tag=Gothic"' "catalog tag listed"
has /tags 'href="/books?tag=Victorian"' "KOReader keyword listed"
lacks /tags 'Upstairs' "custom column not taken as a tag"
has /series 'Gothic Classics' "series from the series feeds"
has /series 'Sea Stories' "series from the entry text"
has /series 'Penguin Classics' "series set in KOReader"
has /authors 'href="/books?author=Jane%20Austen"' "authors listed"
has "/books?tag=gothic" 'Frankenstein' "books by tag"
lacks "/books?tag=gothic" 'Moby' "only books with the tag"
has "/books?series=Penguin%20Classics" 'Penguin Classics #2' "series number from KOReader"
moby=$(curl -sf "$base/books?q=moby" | grep -o '/book/[0-9a-f]\{32\}' | head -1)
has "$moby" 'Call me Ishmael.' "description from the entry text"
lacks "$moby" 'TAGS:' "entry text's tag line not in the description"
has "$moby" 'Sea Stories #1' "series number from the entry text"

if [ "$fail" != 0 ]; then
    docker logs "$name" >&2
    exit 1
fi
echo "smoke: ok"
