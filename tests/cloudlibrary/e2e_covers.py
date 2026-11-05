"""Covers end to end, at a Kobo Forma's screen size (1440x1920, 300 dpi):
the plugin syncs a real catalog, covers of the books on screen download on
demand, a background job prefetches more, and after a restart covers come
from disk.

    CL_URL=… CL_USER=… CL_PASS=… python3 tests/cloudlibrary/e2e_covers.py \
        --koreader <emulator>/koreader --zenos ~/Documents/GitHub/zen_os.koplugin --out /tmp/e2e-covers
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_b  # noqa: E402
import proto_c  # noqa: E402

FORMA = {"EMULATE_READER_W": "1440", "EMULATE_READER_H": "1920", "EMULATE_READER_DPI": "300"}

EXTRA = """
    if kind == "cloudlibrary_timings" then
        local Timing = package.loaded["cloudlibrary/timing"]
        local text = Timing.text()
        if params.show then
            UIManager:show(require("ui/widget/textviewer"):new{
                title = "Cloud library timings", text = text, monospace_font = false })
        end
        return { ok = true, text = text }
    end
    if kind == "cloudlibrary_visible" then
        local Virtual = package.loaded["cloudlibrary/virtual"]
        local Covers = package.loaded["cloudlibrary/covers"]
        local Library = package.loaded["cloudlibrary/library"]
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        local items, seen = {}, {}
        local function walk(w, depth)
            if type(w) ~= "table" or seen[w] or depth > 40 then return end
            seen[w] = true
            local e = w.entry
            if type(e) == "table" and e.path and type(w.dimen) == "table" and w.dimen.x then
                local b = Virtual.by_path[e.path]
                items[#items + 1] = { path = e.path, virtual = b ~= nil,
                    cover = b and b.cover ~= nil or false, failed = b and b.cover_failed ~= nil or false }
            end
            for _i, c in ipairs(w) do walk(c, depth + 1) end
        end
        if fc then walk(fc.item_group or fc, 0) end
        local job = Library.job
        return { ok = true, page = fc and fc.page, items = items, covers_busy = Covers.busy(),
            library_job = job and job.mode or false, stats = Library.stats,
            last_result = Library.last_result, lua_kb = math.floor(collectgarbage("count")) }
    end
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

    s = proto_c.Session(args, zd, fx, "covers")
    report: dict = {}

    def launch() -> None:
        s.launches += 1
        root = s.tmp / f"rt{s.launches}"
        root.mkdir()
        s.runtime = proto_b.stage_runtime(args.koreader, args.zenos,
                                          args.zenos / "spec/python/zen_ui_test_driver.koplugin", root)
        s.socket = s.tmp / f"driver{s.launches}.sock"
        s.started_at = time.monotonic()
        s.process = zd.launch(s.runtime, s.ko_home, s.socket, library_dir=s.library,
                              initialize_settings=False, env_overrides=FORMA)
        zd.wait_for_socket(s.socket, timeout=60)

    def visible() -> dict:
        return s.cmd("cloudlibrary_visible")

    def wait_covers(label: str, timeout: float = 120) -> dict:
        started = time.monotonic()
        def done():
            v = visible()
            cloud = [i for i in v.get("items", []) if i["virtual"]]
            if cloud and all(i["cover"] or i["failed"] for i in cloud):
                return v
            return None
        try:
            v = proto_b.wait_for(done, timeout, label)
        except TimeoutError:
            v = visible()
        cloud = [i for i in v.get("items", []) if i["virtual"]]
        return {
            "seconds": round(time.monotonic() - started, 1),
            "cloud_on_screen": len(cloud),
            "with_cover": sum(1 for i in cloud if i["cover"]),
            "failed": sum(1 for i in cloud if i["failed"]),
            "local_on_screen": sum(1 for i in v.get("items", []) if not i["virtual"]),
            "page": v.get("page"),
        }

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
        s.launches = 0
        launch()

        started = time.monotonic()
        def synced():
            v = visible()
            r = v.get("last_result") or {}
            return v if r.get("sync") or r.get("error") else None
        v = proto_b.wait_for(synced, 300, "first sync")
        report["first_sync_seconds"] = round(time.monotonic() - started, 1)
        report["first_sync"] = (v.get("last_result") or {}).get("sync")

        s.cmd("set_library_display_mode", mode="mosaic_image")
        report["grid_page1"] = wait_covers("covers on page 1")
        report["grid_page1"]["screenshot"] = s.shot("grid-page1")
        report["grid_page1"]["rss_mb"] = s.rss_mb()

        s.cmd("file_chooser_next_page")
        report["grid_page2"] = wait_covers("covers on page 2")
        report["grid_page2"]["screenshot"] = s.shot("grid-page2")

        s.cmd("set_library_display_mode", mode="list_image_meta")
        report["list_page1"] = wait_covers("covers in list view")
        report["list_page1"]["screenshot"] = s.shot("list-page1")

        # The prefetch job that follows a sync.
        started = time.monotonic()
        def prefetch_done():
            v = visible()
            r = v.get("last_result") or {}
            return v if not v.get("library_job") and r.get("mode") == "prefetch" else None
        try:
            v = proto_b.wait_for(prefetch_done, 300, "cover prefetch")
            report["prefetch"] = {"seconds_after_list": round(time.monotonic() - started, 1),
                                  "result": (v.get("last_result") or {}).get("covers"),
                                  "stats": v.get("stats")}
        except TimeoutError as exc:
            report["prefetch"] = {"error": str(exc), "state": visible().get("library_job")}
        report["rss_mb_before_quit"] = s.rss_mb()
        report["timings_text"] = s.cmd("cloudlibrary_timings", show=True).get("text")
        time.sleep(1)
        report["timings_screenshot"] = s.shot("timings")
        s.cmd("cloudlibrary_close_top")
        report["quit"] = s.quit()

        # Restart: covers come from disk.
        launch()
        time.sleep(2)
        s.cmd("set_library_display_mode", mode="mosaic_image")
        report["restart_page1"] = wait_covers("covers after restart", 30)
        v = visible()
        report["restart_page1"]["covers_busy"] = v.get("covers_busy")
        report["restart_page1"]["screenshot"] = s.shot("restart-grid")
        report["restart_rss_mb"] = s.rss_mb()
        report["restart_timings_text"] = s.cmd("cloudlibrary_timings").get("text")
    finally:
        s.close()
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
