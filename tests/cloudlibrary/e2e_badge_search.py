"""On-device badge and search, end to end at a Kobo Forma's screen size.

Downloads one small book by an author with several books in the catalog,
then checks: the badge on its cover (grid and list), and file search for
that author (the local copy first, then the cloud books), a search only
cloud books match (shown instead of "No results"), one nothing matches,
and tapping a cloud result (its details).

    CL_URL=… CL_USER=… CL_PASS=… python3 tests/cloudlibrary/e2e_badge_search.py \
        --koreader <emulator>/koreader --zenos ~/Documents/GitHub/zen_os.koplugin \
        --catalog /tmp/proto-a/catalog.json --out /tmp/e2e-badge
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_covers  # noqa: E402
import e2e_download  # noqa: E402
import proto_b  # noqa: E402
import proto_c  # noqa: E402

EXTRA = """
    if kind == "cl_show_file" then
        local fc = require("apps/filemanager/filemanager").instance.file_chooser
        for i, item in ipairs(fc.item_table or {}) do
            if item.path == params.path then
                local page = math.floor((i - 1) / fc.perpage) + 1
                fc:onGotoPage(page)
                return { ok = true, page = page, index = i }
            end
        end
        return { ok = false, error = "not listed" }
    end
    if kind == "cl_badge_state" then
        local Library = package.loaded["cloudlibrary/library"]
        local Badge = package.loaded["cloudlibrary/badge"]
        local n = 0
        for _p in pairs(Library.on_device) do n = n + 1 end
        return { ok = true, on_device = n, this = Library.on_device[params.path] == true,
            enabled = Badge.enabled }
    end
    if kind == "cl_search" then
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        local fs = fm.filesearcher
        local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        if fs.booklist_menu then fs.booklist_menu.close_callback() end
        FileSearcher.search_string = params.query
        FileSearcher.search_path = params.path
        FileSearcher.search_hash = nil
        fs.include_subfolders = true
        fs.case_sensitive = false
        fs.use_patterns = false
        fs.include_metadata = false
        require("ui/trapper"):wrap(function() fs:doSearch() end)
        return { ok = true }
    end
    if kind == "cl_search_results" then
        local fs = require("apps/filemanager/filemanager").instance.filesearcher
        local menu = fs.booklist_menu
        local out = {}
        if menu then
            for _i, item in ipairs(menu.item_table or {}) do
                table.insert(out, { path = item.path, cloud = item._cloudlibrary == true })
            end
        end
        local top = UIManager._window_stack[#UIManager._window_stack]
        local w = top and top.widget
        return { ok = true, open = menu ~= nil, items = out,
            top_text = w and (w.text or (w[1] and w[1].text)) or false }
    end
    if kind == "cl_search_tap" then
        local fs = require("apps/filemanager/filemanager").instance.filesearcher
        local menu = fs.booklist_menu
        for _i, item in ipairs(menu.item_table) do
            if item.path == params.path then
                menu:onMenuSelect(item)
                return { ok = true }
            end
        end
        return { ok = false }
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
    proto_b.DRIVER_EXTENSION += proto_c.EXTRA_COMMANDS + e2e_covers.EXTRA + e2e_download.EXTRA + EXTRA

    catalog = json.loads(args.catalog.read_text())
    by_author = collections.Counter(b["authors"][0] for b in catalog if b["authors"])
    candidates = sorted((b for b in catalog if b["authors"] and by_author[b["authors"][0]] >= 4
                         and len(b["formats"]) == 1 and "epub" in b["formats"][0]["type"]
                         and b["formats"][0]["size"] < 800_000), key=lambda b: b["formats"][0]["size"])
    book = candidates[0]
    author = book["authors"][0]
    surname = author.split()[-1]
    other = next(a for a, n in by_author.most_common() if n >= 3 and a != author
                 and surname.lower() not in a.lower())
    report: dict = {"book": book["title"], "author": author, "author_books": by_author[author],
                    "other_author": other, "other_books": by_author[other]}

    s = proto_c.Session(args, zd, fx, "badge")
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
                             "folder": str(s.library), "badge_local": True},
        }) + "\n")
        s.launches = 1
        root = s.tmp / "rt1"
        root.mkdir()
        s.runtime = proto_b.stage_runtime(args.koreader, args.zenos,
                                          args.zenos / "spec/python/zen_ui_test_driver.koplugin", root)
        s.socket = s.tmp / "driver1.sock"
        s.process = zd.launch(s.runtime, s.ko_home, s.socket, library_dir=s.library,
                              initialize_settings=False, env_overrides=e2e_covers.FORMA)
        zd.wait_for_socket(s.socket, timeout=60)
        proto_b.wait_for(lambda: (lambda v: v if (v.get("last_result") or {}).get("sync") else None)(
            s.cmd("cloudlibrary_visible")), 300, "first sync")

        # Download the book (a real EPUB, with its cover).
        s.cmd("cl_details_buttons", id=book["uuid"], press=True, row=1, col=2)
        st = proto_b.wait_for(lambda: (lambda r: r if r.get("file") and not r.get("downloading") else None)(
            s.cmd("cl_book_state", id=book["uuid"])), 120, "download")
        path = st["file"]
        report["file"] = path.rsplit("/", 1)[-1]
        report["badge_state"] = s.cmd("cl_badge_state", path=path)

        for mode in ("mosaic_image", "list_image_meta"):
            s.cmd("set_library_display_mode", mode=mode)
            time.sleep(1)
            report[mode] = s.cmd("cl_show_file", path=path)
            time.sleep(3)  # the local book's cover is extracted by CoverBrowser
            report[mode]["screenshot"] = s.shot("badge-" + mode)

        def search(query: str, label: str) -> dict:
            s.cmd("cl_search", query=query, path=str(s.library))
            def shown():
                r = s.cmd("cl_search_results")
                return r if r.get("open") or r.get("top_text") else None
            r = proto_b.wait_for(shown, 30, "search " + query)
            time.sleep(3)
            r = s.cmd("cl_search_results")
            items = r.get("items") or []
            if not isinstance(items, list):  # an empty Lua table arrives as {}
                items = []
            local = [i for i in items if not i["cloud"]]
            cloud = [i for i in items if i["cloud"]]
            first_cloud = next((n for n, i in enumerate(items) if i["cloud"]), len(items))
            out = {"results": len(items), "local": len(local), "cloud": len(cloud),
                   "local_first": all(not i["cloud"] for i in items[:first_cloud])
                   and all(i["cloud"] for i in items[first_cloud:]),
                   "message": r.get("top_text") if not r.get("open") else None,
                   "screenshot": s.shot("search-" + label)}
            return out, items

        report["search_author"], items = search(surname, "author")
        report["search_other"], other_items = search(other.split()[-1], "other")
        cloud_item = next((i for i in other_items if i["cloud"]), None)
        if cloud_item:
            s.cmd("cl_search_tap", path=cloud_item["path"])
            time.sleep(1)
            report["tap_details_shown"] = s.cmd("cloudlibrary_state").get("last_details") == cloud_item["path"]
            report["tap_screenshot"] = s.shot("search-tap")
            s.cmd("cloudlibrary_close_top")
        report["search_none"], _items = search("zzqxjv", "none")
    finally:
        s.close()
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
