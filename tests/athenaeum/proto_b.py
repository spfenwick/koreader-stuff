"""Prototype B: do cloud-only books render and open like local ones under ZenOS?

Runs the KOReader emulator with ZenOS, CoverBrowser, the ZenOS test driver
and athenaeum.koplugin, a library folder with two real EPUBs, and a test
catalog with two cloud-only books. Saves screenshots and a JSON report.

    python3 tests/athenaeum/proto_b.py \
        --koreader ~/Documents/GitHub/koreader/koreader-emulator-x86_64-linux-gnu-debug/koreader \
        --zenos ~/Documents/GitHub/zen_os.koplugin \
        --out /tmp/proto-b

Uses ZenOS's own driver (spec/python) and test-driver plugin. Nothing in
the KOReader or ZenOS folders is changed: the runtime is staged in a
temporary folder with symlinks, and settings go to a temporary KO_HOME.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[2]
PLUGIN = REPO / "athenaeum.koplugin"

CLOUD_BOOKS = [
    {
        "id": "0b8f6c1e-1111-4a1a-9c11-000000000001",
        "title": "Cloud Atlas",
        "authors": ["David Mitchell"],
        "series": None,
        "summary": "Six nested stories.",
        "tags": ["Fiction"],
        "language": "en",
        "added": 1_717_200_000,
        "size": 1_234_567,
        "colour": (180, 60, 40),
    },
    {
        "id": "0b8f6c1e-2222-4a1a-9c11-000000000002",
        "title": "Brave Remote World",
        "authors": ["Remote Author"],
        "series": "Remote Series",
        "series_index": 2,
        "summary": "A book that only exists on the server.",
        "tags": ["Fiction", "Classics"],
        "language": "en",
        "added": 1_719_800_000,
        "size": 765_432,
        "colour": (40, 110, 70),
    },
]


def lua_string(text: str) -> str:
    """A Lua string literal: UTF-8 as is, quotes and control characters escaped."""
    out = []
    for ch in text:
        if ch in ('"', "\\"):
            out.append("\\" + ch)
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def lua(value: object) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, list):
        return "{" + ", ".join(lua(v) for v in value) + "}"
    if isinstance(value, dict):
        return "{" + ", ".join(f"[{lua_string(k)}] = {lua(v)}" for k, v in value.items()
                               if v is not None) + "}"
    raise TypeError(type(value))


def make_cover(path: Path, title: str, colour: tuple[int, int, int]) -> None:
    image = Image.new("RGB", (300, 450), colour)
    draw = ImageDraw.Draw(image)
    draw.rectangle((12, 12, 287, 437), outline=(255, 255, 255), width=4)
    draw.text((30, 200), title, fill=(255, 255, 255))
    draw.text((30, 230), "(cloud)", fill=(255, 255, 255))
    image.save(path, "JPEG", quality=90)


DRIVER_EXTENSION = """
    if kind == "athenaeum_hold_item" and type(params.path) == "string" then
        local FileManager = require("apps/filemanager/filemanager")
        local fc = FileManager.instance and FileManager.instance.file_chooser
        if not fc then return { ok = false, error = "file chooser unavailable" } end
        local item = find_descendant(fc.item_group or fc, function(widget)
            local entry = widget.entry
            return type(entry) == "table" and (entry.path or entry.file) == params.path
                and type(widget.dimen) == "table" and widget.dimen.x ~= nil
                and type(widget.onHoldSelect) == "function"
        end)
        if not item then return { ok = false, error = "visible item unavailable" } end
        local d = item.dimen
        item:onHoldSelect(nil, {
            pos = require("ui/geometry"):new{ x = d.x + math.floor(d.w / 2),
                y = d.y + math.floor(d.h / 2), w = 0, h = 0 },
            time = require("ui/time").now(),
        })
        return { ok = true }
    end
    if kind == "athenaeum_state" then
        local windows, banner = {}, false
        for _i, window in ipairs(UIManager._window_stack) do
            local w = window.widget
            if w then
                windows[#windows + 1] = w.name or w.title or tostring(w.id or "?")
                if w._zen_opening_banner then banner = true end
            end
        end
        local ReaderUI = package.loaded["apps/reader/readerui"]
        return { ok = true, last_details = rawget(_G, "__ATHENAEUM_LAST_DETAILS"),
            banner = banner, windows = windows,
            reader_open = ReaderUI ~= nil and ReaderUI.instance ~= nil }
    end
    if kind == "athenaeum_close_top" then
        local top = UIManager._window_stack[#UIManager._window_stack]
        if top and top.widget and not top.widget.covers_fullscreen then
            UIManager:close(top.widget)
            UIManager:forceRePaint()
            return { ok = true }
        end
        return { ok = false, error = "no dialog on top" }
    end
"""


def stage_runtime(koreader: Path, zenos: Path, driver_plugin: Path, root: Path,
                  include_plugin: bool = True) -> Path:
    runtime = root / "runtime"
    runtime.mkdir()
    for item in koreader.iterdir():
        if item.name != "plugins":
            (runtime / item.name).symlink_to(item)
    plugins = runtime / "plugins"
    plugins.mkdir()
    for item in (koreader / "plugins").iterdir():
        if item.name not in ("zenos.koplugin", "zen_ui.koplugin", "zen_ui_test_driver.koplugin",
                             "athenaeum.koplugin"):
            (plugins / item.name).symlink_to(item)
    shutil.copytree(zenos, plugins / "zenos.koplugin",
                    ignore=shutil.ignore_patterns(".git", "spec", "dist", ".luarocks"))
    shutil.copytree(driver_plugin, plugins / "zen_ui_test_driver.koplugin")
    driver_main = plugins / "zen_ui_test_driver.koplugin" / "main.lua"
    marker = '    return { ok = false, error = "unknown command" }\n'
    source = driver_main.read_text(encoding="utf-8")
    if source.count(marker) != 1:
        raise RuntimeError("can't extend the ZenOS test driver: its command dispatch changed")
    driver_main.write_text(source.replace(marker, DRIVER_EXTENSION + marker), encoding="utf-8")
    if include_plugin:
        (plugins / "athenaeum.koplugin").symlink_to(PLUGIN)
    return runtime


def stage_library(root: Path, zen_fixtures) -> tuple[Path, list[Path]]:
    library = root / "library"
    library.mkdir()
    cover = root / "local-cover.png"
    Image.new("RGB", (60, 90), (32, 96, 192)).save(cover)
    cover_bytes = cover.read_bytes()
    local = []
    for index, title in enumerate(["Alpha", "Zulu"], start=1):
        path = library / f"{title}.epub"
        zen_fixtures._write_zip(path, zen_fixtures._epub_members(title, "Local Series", index,
                                                                 cover_bytes))
        local.append(path)
    return library, local


def write_catalog(ko_home: Path, library: Path, root: Path) -> list[str]:
    covers = root / "covers"
    covers.mkdir()
    books = []
    for book in CLOUD_BOOKS:
        book = dict(book)
        cover = covers / f"{book['id']}.jpg"
        make_cover(cover, book["title"], book.pop("colour"))
        book["cover"] = str(cover)
        books.append(book)
    settings = ko_home / "settings" / "athenaeum"
    settings.mkdir(parents=True, exist_ok=True)
    (settings / "fixture.lua").write_text(
        "return " + lua({"library_dir": str(library), "books": books}) + "\n", encoding="utf-8")
    return [f"{library}/cloud-{b['id']}.epub" for b in CLOUD_BOOKS]


def texts(node: object, out: list[str]) -> list[str]:
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("text", "title") and isinstance(value, str) and value.strip():
                out.append(value)
            else:
                texts(value, out)
    elif isinstance(node, list):
        for child in node:
            texts(child, out)
    return out


def wait_for(predicate, timeout: float, what: str):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.25)
    raise TimeoutError(f"timed out waiting for {what}")


class Run:
    def __init__(self, args, zd, zen_fixtures, name: str):
        self.args, self.zd, self.name = args, zd, name
        self.tmp = Path(tempfile.mkdtemp(prefix=f"athenaeum-{name}-"))
        self.runtime = stage_runtime(args.koreader, args.zenos,
                                     args.zenos / "spec/python/zen_ui_test_driver.koplugin", self.tmp)
        self.ko_home = self.tmp / "home"
        self.ko_home.mkdir()
        self.library, self.local = stage_library(self.tmp, zen_fixtures)
        self.virtual = write_catalog(self.ko_home, self.library, self.tmp)
        self.socket = self.tmp / "driver.sock"
        self.process = zd.launch(self.runtime, self.ko_home, self.socket, library_dir=self.library)
        zd.wait_for_socket(self.socket, timeout=60)
        self.driver = zd.ZenDriver(self.socket)

    def items(self) -> list[dict]:
        response = self.driver.command("file_chooser_items")
        return response.get("file_chooser", {}).get("items", []) if response.get("ok") else []

    def wait_listing(self) -> list[dict]:
        want = set(self.virtual) | {str(p) for p in self.local}
        return wait_for(lambda: (lambda items: items if want <= {i.get("path") for i in items}
                                 else None)(self.items()), 60, "library listing with cloud books")

    def wait_covers(self) -> dict:
        def done():
            r = self.driver.command("file_chooser_cover_state")
            c = r.get("covers") or {}
            return c if r.get("ok") and c.get("files") and c.get("fetched") == c.get("files") else None
        return wait_for(done, 60, "covers")

    def shot(self, label: str) -> str:
        path = self.args.out / f"{self.name}-{label}.png"
        time.sleep(0.5)
        self.driver.command("checkpoint", name=label)
        self.driver.screenshot(path)
        return str(path)

    def visible_texts(self) -> list[str]:
        return texts(self.driver.visible_ui().get("ui"), [])

    def log_lines(self) -> list[str]:
        log = self.ko_home / "crash.log"
        if not log.exists():
            return []
        return [line for line in log.read_text(errors="replace").splitlines()
                if "Athenaeum" in line or "athenaeum" in line or "ERROR" in line
                or "stack traceback" in line]

    def close(self) -> None:
        self.zd.stop(self.process)
        if not self.args.keep:
            shutil.rmtree(self.tmp, ignore_errors=True)


def scenario_render_and_tap(args, zd, fx, report: dict) -> None:
    run = Run(args, zd, fx, "render")
    result: dict = {"virtual_paths": run.virtual}
    try:
        result["plugin_loaded"] = run.driver.plugin_loaded("athenaeum")
        result["zenos_loaded"] = run.driver.plugin_loaded("zenos")
        for mode in ("mosaic_image", "list_image_meta"):
            r = run.driver.command("set_library_display_mode", mode=mode)
            entry: dict = {"set_mode": r}
            items = run.wait_listing()
            entry["items"] = [{k: i.get(k) for k in ("text", "path", "title", "authors", "series",
                                                     "dim", "mandatory")} for i in items]
            try:
                entry["covers"] = run.wait_covers()
            except TimeoutError as exc:
                entry["covers_error"] = str(exc)
            entry["screenshot"] = run.shot(mode)
            entry["visible_texts"] = run.visible_texts()
            result[mode] = entry
        state = lambda: run.driver.command("athenaeum_state")
        # Tap a cloud book (list mode).
        target = run.virtual[0]
        result["tap"] = run.driver.command("tap_file_chooser_item", path=target)
        time.sleep(1)
        result["after_tap_state"] = state()
        result["after_tap_texts"] = run.visible_texts()
        result["after_tap_screenshot"] = run.shot("after-tap")
        result["tap_opened_details"] = result["after_tap_state"].get("last_details") == target
        result["close_after_tap"] = run.driver.command("athenaeum_close_top")
        time.sleep(0.5)
        result["after_close_state"] = state()
        result["after_close_screenshot"] = run.shot("after-close")
        # Long-press the other cloud book (mosaic mode).
        run.driver.command("set_library_display_mode", mode="mosaic_image")
        run.wait_listing()
        hold_target = run.virtual[1]
        result["hold"] = run.driver.command("athenaeum_hold_item", path=hold_target)
        time.sleep(1)
        result["after_hold_state"] = state()
        result["after_hold_texts"] = run.visible_texts()
        result["after_hold_screenshot"] = run.shot("after-hold")
        result["hold_opened_details"] = result["after_hold_state"].get("last_details") == hold_target
        run.driver.command("athenaeum_close_top")
        time.sleep(0.5)
        result["virtual_sidecars"] = sorted(str(x) for x in run.library.glob("cloud-*.sdr"))
        # A local book still opens in the reader.
        result["open_local"] = run.driver.open_book(run.local[0])
        result["local_reader"] = wait_for(lambda: (lambda st: st if st.get("reader_open") else None)(
            state()), 30, "reader for a local book")
        result["local_reader_screenshot"] = run.shot("local-reader")
    finally:
        result["log"] = run.log_lines()
        run.close()
    report["render_and_tap"] = result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--koreader", type=Path, required=True)
    parser.add_argument("--zenos", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--keep", action="store_true", help="keep temporary folders")
    args = parser.parse_args()
    args.koreader, args.zenos = args.koreader.resolve(), args.zenos.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.zenos / "spec/python"))
    import fixtures as zen_fixtures  # noqa: E402  (ZenOS's)
    import zen_driver as zd  # noqa: E402

    report: dict = {}
    for scenario in (scenario_render_and_tap,):
        try:
            scenario(args, zd, zen_fixtures, report)
        except Exception as exc:  # keep going, report it
            report[scenario.__name__ + "_error"] = repr(exc)
    (args.out / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
