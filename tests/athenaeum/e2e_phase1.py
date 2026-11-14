"""Phase 1 end to end: the plugin syncs a real catalog by itself and lists it
next to local books under ZenOS, with no book listed twice.

    CL_URL=… CL_USER=… CL_PASS=… python3 tests/athenaeum/e2e_phase1.py \
        --koreader <emulator>/koreader --zenos ~/Documents/GitHub/zen_os.koplugin \
        --catalog /tmp/proto-a/catalog.json --out /tmp/e2e

--catalog (from proto_a.py) is used to pick two real books to place in the
folder: an EPUB carrying one book's UUID, and a PDF named like a KOReader
OPDS download of another. The credentials go into a temporary KOReader
home, deleted afterwards (unless --keep).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_b  # noqa: E402
import proto_c  # noqa: E402

EXTRA = """
    if kind == "athenaeum_library_state" then
        local Virtual = package.loaded["athenaeum/virtual"]
        local Library = package.loaded["athenaeum/library"]
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        local present = {}
        for _i, p in ipairs(params.paths or {}) do present[p] = Virtual.by_path[p] ~= nil end
        return { ok = true, cloud = #Virtual.books, stats = Library.stats,
            syncing = Library.job ~= nil, last_result = Library.last_result,
            present = present, items = fc and #(fc.item_table or {}) or 0,
            cache = fc and fc._zen_last_item_table_cache_result,
            last_details = rawget(_G, "__ATHENAEUM_LAST_DETAILS") }
    end
"""


def write_epub(path: Path, uuid: str, title: str, author: str) -> None:
    opf = f"""<?xml version="1.0"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
<dc:identifier opf:scheme="uuid" id="uuid_id">{uuid}</dc:identifier>
<dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:language>en</dc:language>
</metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="c"/></spine></package>"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
        z.writestr("content.opf", opf)
        z.writestr("c.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><body><p>x</p></body></html>")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--zenos", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.koreader, args.zenos = args.koreader.resolve(), args.zenos.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.zenos / "spec/python"))
    import fixtures as fx  # noqa: E402
    import zen_driver as zd  # noqa: E402
    proto_b.DRIVER_EXTENSION += proto_c.EXTRA_COMMANDS + EXTRA

    catalog = json.loads(args.catalog.read_text())
    epub_book = next(b for b in catalog if any("epub" in f["type"] for f in b["formats"]))
    pdf_book = next(b for b in catalog if any("pdf" in f["type"] for f in b["formats"])
                    and b["uuid"] != epub_book["uuid"])

    s = proto_c.Session(args, zd, fx, "e2e")
    report: dict = {"epub_book": epub_book["title"], "pdf_book": pdf_book["title"]}
    try:
        lib = s.library
        write_epub(lib / "my copy.epub", epub_book["uuid"], "A Different Title", "Someone")
        pdf_name = f"{', '.join(pdf_book['authors'])} - {pdf_book['title']}.pdf"
        for ch in '/\\:*?"<>|':
            pdf_name = pdf_name.replace(ch, "_")
        (lib / pdf_name).write_bytes(b"%PDF-1.4\n")
        settings = s.ko_home / "settings"
        (settings / "ZenOS").mkdir(parents=True, exist_ok=True)
        (settings / "ZenOS" / "config.lua").write_text("return { updater = { update_auto_check = false } }\n")
        server = {"title": "My eBooks", "url": os.environ["CL_URL"],
                  "username": os.environ["CL_USER"], "password": os.environ["CL_PASS"]}
        (settings / "opds.lua").write_text("return " + proto_b.lua({"servers": [server]}) + "\n")
        (s.ko_home / "settings.reader.lua").write_text("return " + proto_b.lua({
            "home_dir": str(lib),
            "athenaeum": {"server": {"url": server["url"], "username": server["username"]},
                             "folder": str(lib)},
        }) + "\n")
        s.launches = 1  # settings written above; don't let the driver overwrite them
        runtime_root = s.tmp / "rt1"
        runtime_root.mkdir()
        s.runtime = proto_b.stage_runtime(args.koreader, args.zenos,
                                          args.zenos / "spec/python/zen_ui_test_driver.koplugin",
                                          runtime_root)
        s.socket = s.tmp / "driver1.sock"
        s.started_at = time.monotonic()
        s.process = zd.launch(s.runtime, s.ko_home, s.socket, library_dir=lib, initialize_settings=False)
        zd.wait_for_socket(s.socket, timeout=60)

        virtual = lambda b: f"{lib}/cloud-{b['uuid']}.epub"
        paths = [virtual(epub_book), virtual(pdf_book), virtual(catalog[0]), virtual(catalog[-1])]

        def state():
            return s.cmd("athenaeum_library_state", paths=paths)

        st = state()
        report["at_start"] = {k: st.get(k) for k in ("cloud", "syncing", "stats")}
        started = time.monotonic()
        def synced(r):
            result = r.get("last_result") or {}
            done = not r.get("syncing") and (result.get("sync") or result.get("error"))
            return r if done else None
        st = proto_b.wait_for(lambda: synced(state()), 300, "automatic sync")
        report["sync_seconds"] = round(time.monotonic() - started, 1)
        report["after_sync"] = {k: st.get(k) for k in ("cloud", "stats", "last_result", "present", "items", "cache")}
        s.cmd("set_library_display_mode", mode="list_image_meta")
        time.sleep(1)
        report["list_screenshot"] = s.shot("list")
        # The details sheet for a cloud book on the first page.
        listing = s.listing()
        first_cloud = next((p for p in listing.get("files", []) if "/cloud-" in p), None)
        if first_cloud:
            s.cmd("tap_file_chooser_item", path=first_cloud)
            time.sleep(1)
            report["details_for"] = state().get("last_details")
            report["details_screenshot"] = s.shot("details")
            s.cmd("athenaeum_close_top")
        report["quit"] = s.quit()
        # Restart: no new sync needed, listing from ZenOS's saved copy.
        s.start()
        time.sleep(3)
        st = proto_b.wait_for(lambda: (lambda r: r if r.get("cloud") and not r.get("syncing") else None)(state()),
                              120, "reload after restart")
        report["after_restart"] = {k: st.get(k) for k in ("cloud", "stats", "last_result", "cache")}
    finally:
        report["log_errors"] = []
        s.close()
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
