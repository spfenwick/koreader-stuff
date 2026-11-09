#!/bin/sh
# Smoke test for a built image: writes the sample Reading folder with the
# image's own LuaJIT and plugin code, starts the app on it, and checks the
# import and every page.
#
#   omnisync-web/tests/smoke.sh [image]     (default: omnisync-web)
set -eu

image=${1:-omnisync-web}
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
    -e LUA_PATH="/opt/omnisync-web/ingest/?.lua;;" \
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
            /collections /status /health; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base$path")
    echo "$code $path"
    [ "$code" = 200 ] || fail=1
done
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

if [ "$fail" != 0 ]; then
    docker logs "$name" >&2
    exit 1
fi
echo "smoke: ok"
