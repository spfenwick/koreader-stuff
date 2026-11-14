"""Prototype C: does ZenOS's cached folder listing keep up with the catalog?

Scenarios, each in its own temporary KOReader home:
  live     catalog changes while the library is shown: with and without
           Virtual.refresh() (which updates the folder's timestamp)
  restart  quit and start again: same catalog, and a catalog changed by a
           "sync" in the previous session
  removed  quit, then start again without the plugin: do cloud books linger?
  scale    a catalog the size of a real library (--catalog, from proto_a):
           listing time, memory, and the first page of covers

    python3 tests/athenaeum/proto_c.py --koreader <emulator>/koreader \
        --zenos ~/Documents/GitHub/zen_os.koplugin --out /tmp/proto-c \
        [--catalog /tmp/proto-a/catalog.json --cover /tmp/proto-a/cover.webp]
"""

from __future__ import annotations

import argparse
import json
import shutil
import socket
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_b  # noqa: E402
from PIL import Image  # noqa: E402

EXTRA_COMMANDS = """
    if kind == "athenaeum_listing" then
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if not fc then return { ok = false, error = "file chooser unavailable" } end
        local paths = {}
        for _i, item in ipairs(fc.item_table or {}) do
            if item.is_file then paths[#paths + 1] = item.path end
        end
        return { ok = true, path = fc.path, files = paths,
            cache = fc._zen_last_item_table_cache_result,
            lua_kb = math.floor(collectgarbage("count")) }
    end
    if kind == "athenaeum_set_catalog" and type(params.fixture) == "string" then
        local Virtual = package.loaded["athenaeum/virtual"]
        if not Virtual then return { ok = false, error = "plugin not loaded" } end
        local data = dofile(params.fixture)
        local started = require("ui/time").now()
        Virtual.setCatalog(Virtual.folder, data.books)
        if params.refresh == "touch" then
            Virtual.refresh()
        elseif params.refresh == "path" then
            local FileManager = require("apps/filemanager/filemanager")
            FileManager.instance.file_chooser:refreshPath()
        end
        return { ok = true, ms = require("ui/time").to_ms(require("ui/time").now() - started) }
    end
    if kind == "athenaeum_refresh_path" then
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        local started = require("ui/time").now()
        fc:refreshPath()
        return { ok = true, ms = require("ui/time").to_ms(require("ui/time").now() - started) }
    end
    if kind == "athenaeum_quit" then
        UIManager:nextTick(function()
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then FileManager.instance:onClose() end
            UIManager:quit()
        end)
        return { ok = true }
    end
"""


def small_catalog(names: list[str]) -> list[dict]:
    by_name = {b["title"]: b for b in proto_b.CLOUD_BOOKS}
    extra = {
        "Third Cloud Book": {
            "id": "0b8f6c1e-3333-4a1a-9c11-000000000003", "title": "Third Cloud Book",
            "authors": ["New Author"], "summary": "Added by a sync.", "tags": ["Fiction"],
            "language": "en", "added": 1_730_000_000, "size": 100_000, "colour": (60, 60, 160),
        },
    }
    by_name.update(extra)
    return [dict(by_name[n]) for n in names]


def write_fixture(path: Path, library: Path, books: list[dict], covers: Path,
                  shared_cover: Path | None = None) -> list[str]:
    covers.mkdir(parents=True, exist_ok=True)
    out = []
    for book in books:
        book = dict(book)
        colour = book.pop("colour", None)
        if shared_cover is not None:
            book["cover"] = str(shared_cover)
        elif colour is not None:
            cover = covers / f"{book['id']}.jpg"
            if not cover.exists():
                proto_b.make_cover(cover, book["title"], colour)
            book["cover"] = str(cover)
        if book.get("cover"):
            with Image.open(book["cover"]) as image:
                book["cover_w"], book["cover_h"] = image.size
        out.append(book)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("return " + proto_b.lua({"library_dir": str(library), "books": out}) + "\n",
                    encoding="utf-8")
    return [f"{library}/cloud-{b['id']}.epub" for b in out]


class Session:
    """One KOReader home, which may be launched several times."""

    def __init__(self, args, zd, fx, name: str):
        self.args, self.zd, self.name = args, zd, name
        self.tmp = Path(tempfile.mkdtemp(prefix=f"athenaeum-c-{name}-"))
        self.ko_home = self.tmp / "home"
        self.ko_home.mkdir()
        self.library, self.local = proto_b.stage_library(self.tmp, fx)
        self.fixture = self.ko_home / "settings" / "athenaeum" / "fixture.lua"
        self.covers = self.tmp / "covers"
        self.process = None
        self.launches = 0

    def set_fixture(self, books: list[dict], shared_cover: Path | None = None) -> list[str]:
        return write_fixture(self.fixture, self.library, books, self.covers, shared_cover)

    def start(self, include_plugin: bool = True) -> None:
        self.launches += 1
        runtime_root = self.tmp / f"rt{self.launches}"
        runtime_root.mkdir()
        self.runtime = proto_b.stage_runtime(
            self.args.koreader, self.args.zenos,
            self.args.zenos / "spec/python/zen_ui_test_driver.koplugin", runtime_root,
            include_plugin=include_plugin)
        self.socket = self.tmp / f"driver{self.launches}.sock"
        self.started_at = time.monotonic()
        self.process = self.zd.launch(self.runtime, self.ko_home, self.socket,
                                      library_dir=self.library,
                                      initialize_settings=(self.launches == 1))
        self.zd.wait_for_socket(self.socket, timeout=60)
        self.driver = self.zd.ZenDriver(self.socket)

    def cmd(self, kind: str, **params) -> dict:
        # ZenOS's driver gives up after 10 s; a big listing can take longer.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(300)
            client.connect(str(self.socket))
            client.sendall((json.dumps({"type": kind, "params": params}) + "\n").encode())
            line = client.makefile("r", encoding="utf-8").readline()
        return json.loads(line)

    def rss_mb(self) -> float | None:
        try:
            for line in Path(f"/proc/{self.process.pid}/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    return round(int(line.split()[1]) / 1024, 1)
        except OSError:
            return None
        return None

    def listing(self) -> dict:
        return self.cmd("athenaeum_listing")

    def wait_listing(self, predicate, what: str, timeout: float = 90) -> dict:
        return proto_b.wait_for(lambda: (lambda r: r if r.get("ok") and predicate(r) else None)(
            self.listing()), timeout, what)

    def shot(self, label: str) -> str:
        path = self.args.out / f"{self.name}-{label}.png"
        time.sleep(0.5)
        self.cmd("screenshot", output=str(path))
        return str(path)

    def quit(self, settle: float = 4.0) -> dict:
        time.sleep(settle)  # ZenOS saves cached listings 2 s after building them
        try:
            self.cmd("athenaeum_quit")
        except ValueError:
            pass  # the driver flushes pending UI work, so KOReader quits before replying
        try:
            self.process.wait(timeout=20)
            graceful = True
        except Exception:  # noqa: BLE001
            self.zd.stop(self.process)
            graceful = False
        return {"graceful": graceful}

    def persisted_cache_mentions(self, needle: str) -> int:
        total = 0
        for path in (self.ko_home / "settings").rglob("*"):
            if path.is_file() and "cache" in path.name.lower():
                try:
                    total += path.read_text(errors="replace").count(needle)
                except OSError:
                    pass
        return total

    def close(self) -> None:
        if self.process and self.process.poll() is None:
            self.zd.stop(self.process)
        if not self.args.keep:
            shutil.rmtree(self.tmp, ignore_errors=True)


def summary(listing: dict, expected: list[str], unexpected: list[str]) -> dict:
    files = set(listing.get("files") or [])
    return {
        "cache": (listing.get("cache") or {}).get("cache"),
        "elapsed_ms": round((listing.get("cache") or {}).get("elapsed_ms") or 0, 1),
        "has_expected": all(p in files for p in expected),
        "missing": [p.rsplit("/", 1)[-1] for p in expected if p not in files],
        "stale_present": [p.rsplit("/", 1)[-1] for p in unexpected if p in files],
        "files": len(files),
    }


def scenario_live(args, zd, fx) -> dict:
    s = Session(args, zd, fx, "live")
    result: dict = {}
    try:
        a = s.set_fixture(small_catalog(["Cloud Atlas", "Brave Remote World"]))
        s.start()
        s.wait_listing(lambda r: all(p in r["files"] for p in a), "catalog A listed")
        result["A"] = summary(s.listing(), a, [])
        b_books = small_catalog(["Brave Remote World", "Third Cloud Book"])
        fixture_b = s.tmp / "fixture-b.lua"
        b = write_fixture(fixture_b, s.library, b_books, s.covers)
        removed = [p for p in a if p not in b]
        r = s.cmd("athenaeum_set_catalog", fixture=str(fixture_b), refresh="path")
        result["B_refresh_without_timestamp"] = {**summary(s.listing(), b, removed), "ms": r.get("ms")}
        r = s.cmd("athenaeum_set_catalog", fixture=str(fixture_b), refresh="touch")
        result["B_after_Virtual_refresh"] = {**summary(s.listing(), b, removed), "ms": r.get("ms")}
        result["screenshot"] = s.shot("after-refresh")
    finally:
        s.close()
    return result


def scenario_restart(args, zd, fx) -> dict:
    s = Session(args, zd, fx, "restart")
    result: dict = {}
    try:
        a = s.set_fixture(small_catalog(["Cloud Atlas", "Brave Remote World"]))
        s.start()
        s.wait_listing(lambda r: all(p in r["files"] for p in a), "catalog A listed")
        result["run1"] = summary(s.listing(), a, [])
        result["run1_quit"] = s.quit()
        result["persisted_mentions_of_cloud_books"] = s.persisted_cache_mentions("cloud-0b8f6c1e")
        # Run 2: same catalog.
        s.start()
        result["run2_same_catalog"] = summary(
            s.wait_listing(lambda r: len(r["files"]) > 0, "run 2 listing"), a, [])
        # A sync in this session changes the catalog, then quit.
        b_books = small_catalog(["Brave Remote World", "Third Cloud Book"])
        fixture_b = s.tmp / "fixture-b.lua"
        b = write_fixture(fixture_b, s.library, b_books, s.covers)
        removed = [p for p in a if p not in b]
        s.cmd("athenaeum_set_catalog", fixture=str(fixture_b), refresh="touch")
        result["run2_after_sync"] = summary(s.listing(), b, removed)
        result["run2_quit"] = s.quit()
        # Run 3: the plugin starts with the synced catalog.
        s.set_fixture(b_books)
        s.start()
        result["run3_after_synced_restart"] = summary(
            s.wait_listing(lambda r: len(r["files"]) > 0, "run 3 listing"), b, removed)
    finally:
        s.close()
    return result


def scenario_removed(args, zd, fx) -> dict:
    s = Session(args, zd, fx, "removed")
    result: dict = {}
    try:
        a = s.set_fixture(small_catalog(["Cloud Atlas", "Brave Remote World"]))
        s.start()
        s.wait_listing(lambda r: all(p in r["files"] for p in a), "catalog A listed")
        result["run1_quit"] = s.quit()
        s.start(include_plugin=False)
        listing = s.wait_listing(lambda r: len(r["files"]) > 0, "listing without plugin")
        result["without_plugin"] = summary(listing, [str(p) for p in s.local], a)
        result["screenshot"] = s.shot("without-plugin")
    finally:
        s.close()
    return result


def scenario_scale(args, zd, fx) -> dict:
    if not args.catalog:
        return {"skipped": "no --catalog"}
    catalog = json.loads(Path(args.catalog).read_text())
    books = []
    for entry in catalog:
        books.append({
            "id": entry["uuid"], "title": entry["title"], "authors": entry["authors"],
            "series": entry.get("series"), "series_index": entry.get("series_position"),
            "summary": entry.get("summary"), "tags": entry.get("tags"),
            "language": (entry.get("languages") or [None])[0],
            "size": max((f["size"] for f in entry["formats"]), default=0),
            "added": int(time.mktime(time.strptime(entry["updated"][:19], "%Y-%m-%dT%H:%M:%S"))),
        })
    s = Session(args, zd, fx, "scale")
    result: dict = {"cloud_books": len(books)}
    try:
        virtual = s.set_fixture(books, shared_cover=Path(args.cover) if args.cover else None)
        s.start()
        built = lambda r: (r.get("cache") or {}).get("items", 0) >= len(virtual)
        first = s.wait_listing(built, "full listing", 180)
        result["startup_to_listing_s"] = round(time.monotonic() - s.started_at, 1)
        result["first_listing"] = summary(first, [], [])
        result["lua_kb"] = first.get("lua_kb")
        result["rss_mb_after_listing"] = s.rss_mb()
        for mode in ("mosaic_image", "list_image_meta"):
            s.cmd("set_library_display_mode", mode=mode)
            started = time.monotonic()
            try:
                s.wait_listing(built, "listing")
                result[mode] = {"seconds": round(time.monotonic() - started, 2),
                                "screenshot": s.shot(mode), "rss_mb": s.rss_mb()}
                started = time.monotonic()
                covers = s.cmd("file_chooser_cover_state")
                result[mode]["all_items_book_info"] = {
                    "covers": covers.get("covers"),
                    "seconds": round(time.monotonic() - started, 2), "rss_mb": s.rss_mb()}
            except TimeoutError as exc:
                result[mode] = {"error": str(exc)}
        r = s.cmd("athenaeum_refresh_path")
        result["refresh_cached_ms"] = r.get("ms")
        result["refresh_cached"] = summary(s.listing(), [], [])
        r = s.cmd("athenaeum_set_catalog", fixture=str(s.fixture), refresh="touch")
        result["rebuild_after_sync_ms"] = r.get("ms")
        result["rebuild_after_sync"] = summary(s.listing(), [], [])
        result["lua_kb_after"] = s.listing().get("lua_kb")
        result["rss_mb_after_rebuild"] = s.rss_mb()
        result["quit"] = s.quit()
        s.start()
        started = time.monotonic()
        restart = s.wait_listing(built, "restart listing", 180)
        result["restart_listing"] = summary(restart, [], [])
        result["restart_startup_to_listing_s"] = round(time.monotonic() - s.started_at, 1)
        result["rss_mb_after_restart"] = s.rss_mb()
    finally:
        s.close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--zenos", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--catalog", help="catalog.json from proto_a.py, for the scale test")
    parser.add_argument("--cover", help="one cover image used for every book in the scale test")
    parser.add_argument("--only", nargs="*")
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.koreader, args.zenos = args.koreader.resolve(), args.zenos.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.zenos / "spec/python"))
    import fixtures as fx  # noqa: E402
    import zen_driver as zd  # noqa: E402

    proto_b.DRIVER_EXTENSION += EXTRA_COMMANDS
    report: dict = {}
    scenarios = {"live": scenario_live, "restart": scenario_restart,
                 "removed": scenario_removed, "scale": scenario_scale}
    for name, fn in scenarios.items():
        if args.only and name not in args.only:
            continue
        try:
            report[name] = fn(args, zd, fx)
        except Exception as exc:  # noqa: BLE001
            report[name] = {"error": repr(exc)}
        (args.out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
