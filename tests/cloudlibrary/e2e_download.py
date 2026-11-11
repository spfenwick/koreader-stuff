"""Downloads and the Wi-Fi redraw, end to end at a Kobo Forma's screen size.

1. Offline redraw: after the first sync, KOReader is told it's offline, a
   page of older books is drawn (placeholders, nothing asked for), then
   "Wi-Fi connected" is broadcast: their covers must arrive by themselves.
2. Download: a small EPUB's details sheet has Download buttons; pressing
   Download puts "Author - Title.epub" in the folder, dated when the book
   was added, and its cloud entry goes away. "Download & read" opens the
   book in the reader.

    CL_URL=… CL_USER=… CL_PASS=… python3 tests/cloudlibrary/e2e_download.py \
        --koreader <emulator>/koreader --zenos ~/Documents/GitHub/zen_os.koplugin \
        --catalog /tmp/proto-a/catalog.json --out /tmp/e2e-download

Downloads two small books into a temporary folder (deleted afterwards).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_covers  # noqa: E402
import proto_b  # noqa: E402
import proto_c  # noqa: E402

EXTRA = """
    if kind == "cl_set_online" then
        local NetworkMgr = require("ui/network/manager")
        if params.online then
            if NetworkMgr._cl_orig_isConnected then
                NetworkMgr.isConnected = NetworkMgr._cl_orig_isConnected
                NetworkMgr._cl_orig_isConnected = nil
            end
            if params.broadcast then
                UIManager:broadcastEvent(require("ui/event"):new("NetworkConnected"))
            end
        else
            NetworkMgr._cl_orig_isConnected = NetworkMgr._cl_orig_isConnected or NetworkMgr.isConnected
            NetworkMgr.isConnected = function() return false end
        end
        return { ok = true }
    end
    if kind == "cl_goto_page" then
        local fc = require("apps/filemanager/filemanager").instance.file_chooser
        fc:onGotoPage(params.page)
        return { ok = true, page = fc.page, pages = fc.page_num }
    end
    if kind == "cl_redraw" then
        local fc = require("apps/filemanager/filemanager").instance.file_chooser
        fc:updateItems(1, true)
        return { ok = true }
    end
    if kind == "cl_details" then
        local Virtual = package.loaded["cloudlibrary/virtual"]
        local path = Virtual.folder .. "/cloud-" .. params.id .. ".epub"
        Virtual.showDetails(path)
        return { ok = true, shown = Virtual.by_path[path] ~= nil }
    end
    if kind == "cl_details_buttons" then
        local Library = package.loaded["cloudlibrary/library"]
        local rows = Library.detailsButtons(params.id, Library.bookDetails(params.id), function() end)
        local texts = {}
        for r, row in ipairs(rows) do
            for c, b in ipairs(row) do
                table.insert(texts, { row = r, col = c, text = b.text, enabled = b.enabled ~= false })
            end
        end
        if params.press then rows[params.row][params.col].callback() end
        return { ok = true, buttons = texts }
    end
    if kind == "cl_book_state" then
        local Virtual = package.loaded["cloudlibrary/virtual"]
        local Library = package.loaded["cloudlibrary/library"]
        local Downloads = package.loaded["cloudlibrary/downloads"]
        local path = Virtual.folder .. "/cloud-" .. params.id .. ".epub"
        local file = Library.matched and Library.matched[params.id]
        local lfs = require("libs/libkoreader-lfs")
        local ReaderUI = package.loaded["apps/reader/readerui"]
        return { ok = true, cloud_entry = Virtual.by_path[path] ~= nil, file = file or false,
            file_mtime = file and lfs.attributes(file, "modification") or false,
            downloading = Downloads.busy(),
            reader_open = ReaderUI ~= nil and ReaderUI.instance ~= nil,
            reader_file = ReaderUI and ReaderUI.instance and ReaderUI.instance.document
                and ReaderUI.instance.document.file or false }
    end
"""


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
    proto_b.DRIVER_EXTENSION += proto_c.EXTRA_COMMANDS + e2e_covers.EXTRA + EXTRA

    catalog = json.loads(args.catalog.read_text())
    small = sorted((b for b in catalog if len(b["formats"]) == 1 and "epub" in b["formats"][0]["type"]
                    and 50_000 < b["formats"][0]["size"] < 600_000),
                   key=lambda b: b["formats"][0]["size"])
    book_a, book_b = small[0], small[1]
    report: dict = {"book_a": [book_a["title"], book_a["formats"][0]["size"]],
                    "book_b": [book_b["title"], book_b["formats"][0]["size"]]}

    s = proto_c.Session(args, zd, fx, "dl")
    try:
        settings = s.ko_home / "settings"
        (settings / "ZenOS").mkdir(parents=True, exist_ok=True)
        (settings / "ZenOS" / "config.lua").write_text("return { updater = { update_auto_check = false } }\n")
        server = {"title": "My eBooks", "url": os.environ["CL_URL"],
                  "username": os.environ["CL_USER"], "password": os.environ["CL_PASS"]}
        (settings / "opds.lua").write_text("return " + proto_b.lua({"servers": [server]}) + "\n")
        (s.ko_home / "settings.reader.lua").write_text("return " + proto_b.lua({
            "home_dir": str(s.library),
            "cloudlibrary": {"server": {"url": server["url"], "username": server["username"]},
                             "folder": str(s.library)},
        }) + "\n")
        s.launches = 1
        root = s.tmp / "rt1"
        root.mkdir()
        s.runtime = proto_b.stage_runtime(args.koreader, args.zenos,
                                          args.zenos / "spec/python/zen_ui_test_driver.koplugin", root)
        s.socket = s.tmp / "driver1.sock"
        s.started_at = time.monotonic()
        s.process = zd.launch(s.runtime, s.ko_home, s.socket, library_dir=s.library,
                              initialize_settings=False, env_overrides=e2e_covers.FORMA)
        zd.wait_for_socket(s.socket, timeout=60)

        def visible():
            return s.cmd("cloudlibrary_visible")

        proto_b.wait_for(lambda: (lambda v: v if (v.get("last_result") or {}).get("sync") else None)(visible()),
                         300, "first sync")
        s.cmd("set_library_display_mode", mode="mosaic_image")
        time.sleep(1)

        # 1. Offline, then Wi-Fi connects.
        s.cmd("cl_set_online", online=False)
        page = s.cmd("cl_goto_page", page=120)
        report["offline_page"] = page
        time.sleep(2)
        v = visible()
        cloud = [i for i in v["items"] if i["virtual"]]
        report["offline"] = {"cloud_on_screen": len(cloud), "with_cover": sum(i["cover"] for i in cloud),
                             "covers_busy": v.get("covers_busy")}
        report["offline_screenshot"] = s.shot("offline")
        started = time.monotonic()
        s.cmd("cl_set_online", online=True, broadcast=True)

        def covered():
            v = visible()
            cloud = [i for i in v["items"] if i["virtual"]]
            return v if cloud and all(i["cover"] or i["failed"] for i in cloud) else None
        try:
            v = proto_b.wait_for(covered, 60, "covers after Wi-Fi connected")
            cloud = [i for i in v["items"] if i["virtual"]]
            report["after_connect"] = {"seconds": round(time.monotonic() - started, 1),
                                       "with_cover": sum(i["cover"] for i in cloud), "cloud_on_screen": len(cloud)}
        except TimeoutError as exc:
            report["after_connect"] = {"error": str(exc)}
        report["after_connect_screenshot"] = s.shot("after-connect")

        # 2. Details sheet and Download.
        s.cmd("cl_details", id=book_a["uuid"])
        time.sleep(1)
        report["details_screenshot"] = s.shot("details")
        s.cmd("cloudlibrary_close_top")
        buttons = s.cmd("cl_details_buttons", id=book_a["uuid"])["buttons"]
        report["details_buttons"] = [b["text"] for b in buttons]
        started = time.monotonic()
        s.cmd("cl_details_buttons", id=book_a["uuid"], press=True, row=1, col=1)  # Download
        st = proto_b.wait_for(lambda: (lambda r: r if r.get("file") and not r.get("downloading") else None)(
            s.cmd("cl_book_state", id=book_a["uuid"])), 120, "download")
        report["download"] = {
            "seconds": round(time.monotonic() - started, 1),
            "file": st["file"].rsplit("/", 1)[-1],
            "cloud_entry_gone": not st["cloud_entry"],
            "file_dated_when_added": st["file_mtime"],
            "file_size": Path(st["file"]).stat().st_size,
        }
        report["listing_after"] = s.listing().get("cache")
        report["after_download_screenshot"] = s.shot("after-download")

        # Download & read.
        s.cmd("cl_details_buttons", id=book_b["uuid"], press=True, row=2, col=1)
        st = proto_b.wait_for(lambda: (lambda r: r if r.get("reader_open") else None)(
            s.cmd("cl_book_state", id=book_b["uuid"])), 120, "download & read")
        report["download_and_read"] = {"reader_file": str(st["reader_file"]).rsplit("/", 1)[-1],
                                       "cloud_entry_gone": not st["cloud_entry"]}
        time.sleep(2)
        report["reader_screenshot"] = s.shot("reader")
        timings = s.cmd("cloudlibrary_timings").get("text", "")
        report["timings_download"] = [line for line in timings.splitlines()
                                      if "download" in line.lower() or "DOWNLOAD" in line][:6]
    finally:
        s.close()
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
