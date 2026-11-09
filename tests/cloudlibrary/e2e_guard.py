"""The plugin's safety net in the real app (KOReader + ZenOS), with the test
catalog (no server):

1. runtime: a KOReader function used inside the listing hook starts failing
   for cloud books. The library folder must keep working (local books
   only), with a notification and the reason in Status.
2. startup: a user patch changes FileSearcher:onShowSearchResults's
   parameters. Search isn't started; cloud books in the folder still work.

    python3 tests/cloudlibrary/e2e_guard.py --koreader <emulator>/koreader \
        --zenos ~/Documents/GitHub/zen_os.koplugin --out /tmp/e2e-guard
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_b  # noqa: E402
import proto_c  # noqa: E402

EXTRA = """
    if kind == "cl_sabotage_listing" then
        local FileChooser = require("ui/widget/filechooser")
        local real = FileChooser.getListItem
        FileChooser.getListItem = function(self, dirpath, f, fullpath, ...)
            if type(fullpath) == "string" and fullpath:find("/cloud-", 1, true) then
                error("simulated KOReader change")
            end
            return real(self, dirpath, f, fullpath, ...)
        end
        return { ok = true }
    end
    if kind == "cl_guard_state" then
        local Guard = package.loaded["cloudlibrary/guard"]
        local Library = package.loaded["cloudlibrary/library"]
        local Virtual = package.loaded["cloudlibrary/virtual"]
        local Search = package.loaded["cloudlibrary/search"]
        local texts = {}
        for _i, w in ipairs(UIManager._window_stack) do
            if w.widget and type(w.widget.text) == "string" then table.insert(texts, w.widget.text) end
        end
        return { ok = true, status = Guard.statusText(), library_ok = Guard.ok("library"),
            search_ok = Guard.ok("search"), search_installed = Search.installed,
            cloud_books = #Virtual.books, dialogs = texts }
    end
    if kind == "cl_refresh" then
        -- As after a sync that changed the catalog: ZenOS's cached listing
        -- is dropped and the folder listed again.
        local Virtual = package.loaded["cloudlibrary/virtual"]
        local FileChooser = require("ui/widget/filechooser")
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if fc and type(FileChooser._zen_invalidate_item_table_path) == "function" then
            pcall(FileChooser._zen_invalidate_item_table_path, fc, Virtual.folder)
        end
        local ok, err = pcall(Virtual.refresh)
        return { ok = ok, error = err and tostring(err) or nil }
    end
"""

PATCH = """-- Test: FileSearcher:onShowSearchResults with different parameters.
local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
local real = FileSearcher.onShowSearchResults
FileSearcher.onShowSearchResults = function(self) return real(self, true) end
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--zenos", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.koreader, args.zenos = args.koreader.resolve(), args.zenos.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.zenos / "spec/python"))
    import fixtures as fx  # noqa: E402
    import zen_driver as zd  # noqa: E402
    proto_b.DRIVER_EXTENSION += proto_c.EXTRA_COMMANDS + EXTRA
    report: dict = {}

    # 1. A hook starts failing at runtime.
    s = proto_c.Session(args, zd, fx, "guard-runtime")
    try:
        virtual = s.set_fixture(proto_c.small_catalog(["Cloud Atlas", "Brave Remote World"]))
        s.start()
        s.wait_listing(lambda r: all(p in r["files"] for p in virtual), "cloud books listed")
        report["before"] = proto_c.summary(s.listing(), virtual, [])
        s.cmd("cl_sabotage_listing")
        report["refresh"] = s.cmd("cl_refresh")
        time.sleep(1)
        listing = s.listing()
        report["after"] = proto_c.summary(listing, [str(p) for p in s.local], virtual)
        report["after"]["local_files"] = sum(1 for f in listing.get("files", []) if "/cloud-" not in f)
        report["guard"] = s.cmd("cl_guard_state")
        report["screenshot"] = s.shot("notification")
        s.cmd("cloudlibrary_close_top")
        report["still_works"] = s.cmd("cl_refresh")
        report["open_local"] = s.driver.open_book(s.local[0])
    finally:
        s.close()

    # 2. The startup check finds a changed function.
    s = proto_c.Session(args, zd, fx, "guard-startup")
    try:
        virtual = s.set_fixture(proto_c.small_catalog(["Cloud Atlas", "Brave Remote World"]))
        patches = s.ko_home / "patches"
        patches.mkdir(parents=True, exist_ok=True)
        (patches / "2-cloudlibrary-test-changed-search.lua").write_text(PATCH)
        s.start()
        s.wait_listing(lambda r: all(p in r["files"] for p in virtual), "cloud books listed")
        report["startup"] = s.cmd("cl_guard_state")
        report["startup"]["cloud_listed"] = proto_c.summary(s.listing(), virtual, [])["has_expected"]
    finally:
        s.close()

    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
