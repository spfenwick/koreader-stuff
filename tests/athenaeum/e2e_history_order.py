"""ZenOS's "last read" order after the history changes in the middle, end
to end (the plugins tell ZenOS with BookSources.historyChanged instead of
re-reading the history; ZENOS_PRS.md #2).

ZenOS keeps an index of the history's times while the history's length and
first and last entries stay the same, so an entry retimed or moved in the
middle needs the notification. With the library sorted by last read:

1. A middle entry retimed in place, as Concordance does when a book read
   elsewhere is already in the history: ZenOS told (as Concordance's
   refreshAfterHistory does), ZenOS redraws the file browser itself.
2. A middle entry moved to another catalog book's path (Athenaeum's
   History.moved), then the caller's redraw straight away.

Each step runs again without the notification ("control"), which must show
the stale order, or the check proves nothing.

    python3 tests/athenaeum/e2e_history_order.py \\
        --koreader ~/Documents/GitHub/koreader/koreader-emulator-x86_64-linux-gnu-debug/koreader \\
        --zenos <ZenOS custom branch, exported> --out /tmp/e2e-history-order
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_stable_paths as sp  # noqa: E402
import proto_b  # noqa: E402

EXTRA = """
    -- As if history.lua were saved in the second it was last read (likely
    -- on FAT32's 2 s times): KOReader's reload() then keeps its tables.
    local function sameSecond()
        local rh = require("readhistory")
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        rh.last_read_time = lfs.attributes(DataStorage:getDataDir() .. "/history.lua", "modification")
    end
    if kind == "ho_collate" then
        G_reader_settings:saveSetting("collate", params.collate)
        local fm = require("apps/filemanager/filemanager").instance
        fm.file_chooser:refreshPath()
        return { ok = true }
    end
    if kind == "ho_order" then
        local fm = require("apps/filemanager/filemanager").instance
        local out = {}
        for _i, it in ipairs(fm.file_chooser.item_table or {}) do
            if it.path and not it.is_go_up then out[#out + 1] = it.path end
        end
        return { ok = true, order = out, path = fm.file_chooser.path }
    end
    if kind == "ho_retime" then
        local rh = require("readhistory")
        local i = rh:getIndexByFile(params.path)
        if not i then return { ok = false, error = "not in the history" } end
        rh.hist[i].time = params.time
        table.sort(rh.hist, function(a, b) return a.time > b.time end)
        rh:_flush()
        sameSecond()
        if params.notify then
            require("common/book_sources").historyChanged({ params.path })
        else
            require("apps/filemanager/filemanager").instance.file_chooser:refreshPath()
        end
        return { ok = true }
    end
    if kind == "ho_move" then
        local ZenSource = require("athenaeum/zenos_source")
        local real = ZenSource.historyChanged
        if not params.notify then ZenSource.historyChanged = function() end end
        local ok, err = pcall(require("athenaeum/history").moved, { { params.old, params.new } })
        ZenSource.historyChanged = real
        sameSecond()
        if not ok then return { ok = false, error = tostring(err) } end
        -- The caller's redraw, straight away.
        require("apps/filemanager/filemanager").instance.file_chooser:refreshPath()
        return { ok = true }
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
    import zen_driver as zd  # noqa: E402
    proto_b.DRIVER_EXTENSION += sp.EXTRA + EXTRA

    tmp = Path(tempfile.mkdtemp(prefix="athenaeum-hist-order-"))
    ko_home, library = tmp / "home", tmp / "library"
    ko_home.mkdir()
    library.mkdir()
    lib = str(library)
    (library / "Local Reader - Kept.epub").write_bytes(sp.epub_bytes(sp.K, "Kept", "Local Reader"))
    url = "http://127.0.0.1:9/opds"  # never fetched: syncs are off
    settings = ko_home / "settings"
    (settings / "athenaeum").mkdir(parents=True)
    (settings / "athenaeum" / "settings.lua").write_text(
        "return " + proto_b.lua({"folder": lib}) + "\n")
    (settings / "athenaeum" / "shared.lua").write_text("return " + proto_b.lua({
        "server": {"url": url, "username": "test"}, "quick_sync": "never", "full_sync": "never",
        "auto_sync": False}) + "\n")
    (settings / "opds.lua").write_text("return " + proto_b.lua(
        {"servers": [{"title": "Test", "url": url, "username": "test", "password": "test"}]}) + "\n")
    (settings / "ZenOS").mkdir()
    (settings / "ZenOS" / "config.lua").write_text("return { updater = { update_auto_check = false } }\n")

    report: dict = {"checks": {}}
    checks = report["checks"]
    state: dict = {"process": None, "socket": None, "n": 0}

    def cmd(kind: str, **params) -> dict:
        import socket as s
        with s.socket(s.AF_UNIX, s.SOCK_STREAM) as client:
            client.settimeout(120)
            client.connect(str(state["socket"]))
            client.sendall((json.dumps({"type": kind, "params": params}) + "\n").encode())
            return json.loads(client.makefile("r", encoding="utf-8").readline())

    def launch() -> None:
        state["n"] += 1
        root = tmp / f"rt{state['n']}"
        root.mkdir()
        runtime = proto_b.stage_runtime(args.koreader, args.zenos,
                                        args.zenos / "spec/python/zen_ui_test_driver.koplugin", root)
        state["socket"] = tmp / f"driver{state['n']}.sock"
        state["process"] = zd.launch(runtime, ko_home, state["socket"], library_dir=library,
                                     initialize_settings=state["n"] == 1)
        zd.wait_for_socket(state["socket"], timeout=60)

    def quit_() -> None:
        time.sleep(3)
        try:
            cmd("sp_quit")
        except (ValueError, OSError):
            pass
        try:
            state["process"].wait(timeout=20)
        except Exception:  # noqa: BLE001
            zd.stop(state["process"])

    def order() -> list[str]:
        return [p.removeprefix(lib + "/") for p in cmd("ho_order")["order"]]

    def shot(label: str) -> str:
        path = args.out / f"{label}.png"
        time.sleep(1)
        cmd("screenshot", output=str(path))
        return str(path)

    a, b, k = "Ann Author - Cloud Story.epub", "Bo Writer - Second Tale.epub", "Local Reader - Kept.epub"
    d, p = "Ann Author - Cloud Story (2).epub", "Pat Penn - Paper Only.pdf"
    # The first and last entries (A, K) and the length stay the same throughout.
    history = [
        {"time": 1_700_001_000, "file": f"{lib}/{a}"},
        {"time": 1_700_000_900, "file": f"{lib}/{b}"},
        {"time": 1_700_000_850, "file": f"{lib}/{d}"},
        {"time": 1_700_000_800, "file": f"{lib}/{k}"},
    ]

    def start(label: str) -> None:
        (ko_home / "history.lua").write_text("return " + proto_b.lua(history) + "\n")
        launch()
        proto_b.wait_for(lambda: (lambda r: r if r.get("loaded") and r["cloud"] else None)(cmd("sp_state")),
                         60, "load")
        cmd("activate_navbar_tab", id="books")
        time.sleep(2)
        cmd("ho_collate", collate="access")
        time.sleep(2)
        report[f"{label}_start"] = order()

    try:
        launch()
        proto_b.wait_for(lambda: cmd("sp_state").get("loaded") or None, 60, "first load")
        cmd("sp_seed", books=sp.BOOKS)
        quit_()

        for notify in (True, False):
            label = "notified" if notify else "control"
            start(label)
            checks[f"{label}_sorted_by_last_read"] = report[f"{label}_start"][:4] == [a, b, d, k]

            # 1. Retime D (third) to between A and B.
            cmd("ho_retime", path=f"{lib}/{d}", time=1_700_000_950, notify=notify)
            time.sleep(2)  # ZenOS redraws on the next tick
            report[f"{label}_after_retime"] = order()
            shot(f"{label}-1-after-retime")
            retimed = report[f"{label}_after_retime"][:4] == [a, d, b, k]
            checks[f"{label}_retime"] = retimed if notify else not retimed

            # 2. Move B (third now) to P's path (P never read).
            cmd("ho_move", old=f"{lib}/{b}", new=f"{lib}/{p}", notify=notify)
            report[f"{label}_after_move"] = order()
            shot(f"{label}-2-after-move")
            moved = report[f"{label}_after_move"][:4] == [a, d, p, k]
            checks[f"{label}_move"] = moved if notify else not moved
            quit_()
            # The control run must start from the same history and catalog.
            for f in ("history.lua",):
                (ko_home / f).unlink(missing_ok=True)
            settings_file = ko_home / "settings" / "athenaeum" / "settings.lua"
            settings_file.write_text("return " + proto_b.lua({"folder": lib}) + "\n")

        log = ko_home / "crash.log"
        report["log"] = [line for line in (log.read_text(errors="replace").splitlines() if log.exists() else [])
                         if "Athenaeum" in line or "ERROR" in line or "traceback" in line][-60:]
    finally:
        if state["process"] is not None:
            zd.stop(state["process"])
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    report["all_passed"] = all(checks.values())
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({"checks": checks, "all_passed": report["all_passed"]}, indent=2))
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
