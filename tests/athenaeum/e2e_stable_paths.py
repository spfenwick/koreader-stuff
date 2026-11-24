"""One path per book (STABLE_PATHS_PLAN.md), end to end under ZenOS.

1. A catalog database is seeded (first launch), then KOReader starts again
   with 0.9's history entries ("<folder>/cloud-<id>.epub"): they must move
   to the books' paths ("Author - Title.epub", the file for a downloaded
   book), once.
2. Cloud books are listed at their names, in "List (basic)" too.
3. A download goes to the cloud entry's path; the history entry opens it.
4. Deleting it from ZenOS's Authors view (long-press, Delete, confirm): the
   book is a cloud book again at the same path, still in the open list
   and in the history.

No network: downloads come from a local HTTP server, and syncs are off.

    python3 tests/athenaeum/e2e_stable_paths.py \\
        --koreader ~/Documents/GitHub/koreader/koreader-emulator-x86_64-linux-gnu-debug/koreader \\
        --zenos <ZenOS custom branch, exported> --out /tmp/e2e-stable-paths
"""

from __future__ import annotations

import argparse
import http.server
import io
import json
import shutil
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import proto_b  # noqa: E402

A = "5ab1e000-0000-4000-8000-00000000000a"  # cloud, in 0.9's history; downloaded, then deleted
B = "5ab1e000-0000-4000-8000-00000000000b"  # cloud, in 0.9's history
K = "5ab1e000-0000-4000-8000-00000000000c"  # on the device, in 0.9's history as a cloud entry
P = "5ab1e000-0000-4000-8000-00000000000d"  # PDF only
D = "5ab1e000-0000-4000-8000-00000000000e"  # same author and title as A
GONE = "5ab1e000-0000-4000-8000-0000000000ff"  # in 0.9's history, not in the catalog


def epub_bytes(uuid: str, title: str, author: str) -> bytes:
    opf = f"""<?xml version='1.0' encoding='UTF-8'?>
<package version='3.0' unique-identifier='id' xmlns='http://www.idpf.org/2007/opf'
 xmlns:dc='http://purl.org/dc/elements/1.1/'>
  <metadata>
    <dc:identifier id='id'>urn:uuid:{uuid}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest><item id='c' href='c.xhtml' media-type='application/xhtml+xml'/></manifest>
  <spine><itemref idref='c'/></spine>
</package>"""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        z.writestr("META-INF/container.xml", """<?xml version='1.0'?>
<container version='1.0' xmlns='urn:oasis:names:tc:opendocument:xmlns:container'>
<rootfiles><rootfile full-path='content.opf' media-type='application/oebps-package+xml'/></rootfiles>
</container>""")
        z.writestr("content.opf", opf)
        z.writestr("c.xhtml", f"<html xmlns='http://www.w3.org/1999/xhtml'><body><p>{title}</p></body></html>")
    return buf.getvalue()


BOOKS = [
    {"uuid": A, "title": "Cloud Story", "authors": ["Ann Author"], "added": 1_700_000_000,
     "formats": [{"type": "application/epub+zip", "href": f"/dl/{A}.epub", "size": 2000}]},
    {"uuid": B, "title": "Second Tale", "authors": ["Bo Writer"], "added": 1_700_000_100,
     "formats": [{"type": "application/epub+zip", "href": f"/dl/{B}.epub", "size": 2000}]},
    {"uuid": K, "title": "Kept", "authors": ["Local Reader"], "added": 1_700_000_200,
     "formats": [{"type": "application/epub+zip", "href": f"/dl/{K}.epub", "size": 2000}]},
    {"uuid": P, "title": "Paper Only", "authors": ["Pat Penn"], "added": 1_700_000_300,
     "formats": [{"type": "application/pdf", "href": f"/dl/{P}.pdf", "size": 2000}]},
    {"uuid": D, "title": "Cloud Story", "authors": ["Ann Author"], "added": 1_700_000_400,
     "formats": [{"type": "application/epub+zip", "href": f"/dl/{D}.epub", "size": 2000}]},
]

EXTRA = """
    if kind == "sp_seed" then
        local Library = package.loaded["athenaeum/library"]
        local Store = require("athenaeum/store")
        local store = Store.open(Library.dbPath(Library.server()), false)
        store:upsertBooks(params.books, 1)
        store:close()
        Library.load()
        return { ok = true }
    end
    if kind == "sp_state" then
        local Library = package.loaded["athenaeum/library"]
        local Virtual = package.loaded["athenaeum/virtual"]
        local rh = require("readhistory")
        local hist = {}
        for _i, e in ipairs(rh.hist) do
            hist[#hist + 1] = { file = e.file, time = e.time, dim = e.dim or false,
                select_enabled = e.select_enabled or false, text = e.text }
        end
        local cloud = {}
        for _i, b in ipairs(Virtual.books) do cloud[#cloud + 1] = { id = b.id, path = b.path } end
        local matched = { _ = false }
        for id, p in pairs(Library.matched or {}) do matched[id] = p end
        local s = Library.settings()
        return { ok = true, loaded = Library.isLoaded() or false, cloud = cloud, matched = matched,
            hist = hist, history_cloud = s.history_cloud or {},
            downloading = package.loaded["athenaeum/downloads"].busy() or false }
    end
    if kind == "sp_download" then
        return { ok = package.loaded["athenaeum/library"].download(params.id) == true }
    end
    if kind == "sp_windows" then
        local out = {}
        for _i, entry in ipairs(UIManager._window_stack) do
            local w = entry.widget
            local items = {}
            if type(w) == "table" and type(w.item_table) == "table" then
                for _j, it in ipairs(w.item_table) do
                    items[#items + 1] = { text = tostring(it.text), path = it.path or it.file or false,
                        n = it._zen_files and #it._zen_files or false }
                end
            end
            out[#out + 1] = { name = tostring(w and (w.name or w.title) or "?"), items = items }
        end
        return { ok = true, windows = out }
    end
    if kind == "sp_select" then
        local top = UIManager._window_stack[#UIManager._window_stack].widget
        for _i, it in ipairs(top.item_table or {}) do
            if type(it.text) == "string" and it.text:find(params.text, 1, true) then
                top:onMenuSelect(it)
                UIManager:forceRePaint()
                return { ok = true }
            end
        end
        return { ok = false, error = "no such item" }
    end
    if kind == "sp_delete_from_top" then
        local top = UIManager._window_stack[#UIManager._window_stack].widget
        local target
        for _i, it in ipairs(top.item_table or {}) do
            if (it.path or it.file) == params.path then target = it end
        end
        if not target then return { ok = false, error = "item not in the top list" } end
        top:onMenuHold(target)
        local function press(text)
            local w = UIManager._window_stack[#UIManager._window_stack].widget
            local b = find_descendant(w, function(x)
                return type(x.text) == "string" and x.text:find(text, 1, true) ~= nil
                    and type(x.callback) == "function"
            end)
            if not b then return false end
            b.callback()
            return true
        end
        -- ZenOS's book menu: Edit > Delete, then KOReader's confirmation.
        if not press("Edit") then return { ok = false, error = "no Edit in the book's menu" } end
        if not press("Delete") then return { ok = false, error = "no Delete under Edit" } end
        if not press("Delete") then return { ok = false, error = "no Delete to confirm" } end
        UIManager:forceRePaint()
        return { ok = true }
    end
    if kind == "sp_display_mode" then
        local fm = require("apps/filemanager/filemanager").instance
        local ok, err = pcall(fm.onSetDisplayMode, fm, params.mode)
        local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
        if type(open_tab) == "function" then pcall(open_tab, "books") end
        return { ok = ok, error = not ok and tostring(err) or nil }
    end
    if kind == "sp_quit" then
        UIManager:nextTick(function()
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then FileManager.instance:onClose() end
            UIManager:quit()
        end)
        return { ok = true }
    end
"""


class Handler(http.server.BaseHTTPRequestHandler):
    files: dict[str, bytes] = {}

    def do_GET(self):  # noqa: N802
        body = self.files.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/epub+zip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


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
    proto_b.DRIVER_EXTENSION += EXTRA

    Handler.files = {f"/dl/{b['uuid']}.epub": epub_bytes(b["uuid"], b["title"], b["authors"][0])
                     for b in BOOKS}
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/opds"

    tmp = Path(tempfile.mkdtemp(prefix="athenaeum-stable-"))
    ko_home, library = tmp / "home", tmp / "library"
    ko_home.mkdir()
    library.mkdir()
    (library / "Local Reader - Kept.epub").write_bytes(epub_bytes(K, "Kept", "Local Reader"))
    settings = ko_home / "settings"
    (settings / "athenaeum").mkdir(parents=True)
    (settings / "athenaeum" / "settings.lua").write_text(
        "return " + proto_b.lua({"folder": str(library)}) + "\n")
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

    def shot(label: str) -> str:
        path = args.out / f"{label}.png"
        time.sleep(1)
        cmd("screenshot", output=str(path))
        return str(path)

    def st() -> dict:
        return cmd("sp_state")

    def entry(s: dict, path: str) -> dict | None:
        return next((e for e in s["hist"] if e["file"] == path), None)

    lib = str(library)
    legacy = lambda i: f"{lib}/cloud-{i}.epub"  # noqa: E731
    path_a = f"{lib}/Ann Author - Cloud Story.epub"
    try:
        # 1. Seed the catalog, then start again with 0.9's history.
        launch()
        proto_b.wait_for(lambda: st().get("loaded") or None, 60, "first load")
        cmd("sp_seed", books=BOOKS)
        quit_()
        (ko_home / "history.lua").write_text("return " + proto_b.lua([
            {"time": 1_700_000_900, "file": legacy(A)},
            {"time": 1_700_000_800, "file": legacy(B)},
            {"time": 1_700_000_700, "file": legacy(K)},
            {"time": 1_700_000_600, "file": legacy(GONE)},
        ]) + "\n")
        launch()
        s = proto_b.wait_for(lambda: (lambda r: r if r.get("loaded") and r["cloud"] else None)(st()),
                             60, "load with migration")
        report["after_migration"] = s
        cloud = {c["id"]: c["path"] for c in s["cloud"]}
        checks["names"] = cloud == {
            A: path_a, B: f"{lib}/Bo Writer - Second Tale.epub", P: f"{lib}/Pat Penn - Paper Only.pdf",
            D: f"{lib}/Ann Author - Cloud Story (2).epub"}
        checks["kept_matched"] = s["matched"].get(K) == f"{lib}/Local Reader - Kept.epub"
        ea, eb, ek, eg = (entry(s, p) for p in (path_a, f"{lib}/Bo Writer - Second Tale.epub",
                                                f"{lib}/Local Reader - Kept.epub", legacy(GONE)))
        checks["migrated_cloud_a"] = bool(ea and ea["time"] == 1_700_000_900 and not ea["select_enabled"]
                                         and not ea["dim"])
        checks["migrated_cloud_b"] = bool(eb and eb["time"] == 1_700_000_800)
        checks["migrated_to_file_k"] = bool(ek and ek["select_enabled"] and ek["time"] == 1_700_000_700)
        checks["gone_left_greyed"] = bool(eg and eg["dim"])
        checks["no_legacy_left"] = not any(entry(s, legacy(i)) for i in (A, B, K))

        # 2. Listed at their names: List (basic) and the classic list texts.
        cmd("activate_navbar_tab", id="books")
        time.sleep(2)
        report["basic_mode"] = cmd("sp_display_mode", mode="list_image_filename")
        time.sleep(2)
        items = cmd("file_chooser_items").get("file_chooser", {}).get("items", [])
        report["basic_list_items"] = [{k: i.get(k) for k in ("text", "path")} for i in items]
        report["basic_list_texts"] = proto_b.texts(cmd("visible_ui").get("ui"), [])
        report["basic_list_screenshot"] = shot("1-basic-list")
        checks["basic_list_shows_names"] = (
            any(i.get("text") == "Ann Author - Cloud Story.epub" for i in items)
            and not any("cloud-" in (i.get("text") or "") for i in items))
        cmd("sp_display_mode", mode="list_image_meta")
        time.sleep(2)
        report["detailed_list_screenshot"] = shot("2-detailed-list")

        # 3. Download A: to its cloud entry's path.
        cmd("sp_download", id=A)
        s = proto_b.wait_for(lambda: (lambda r: r if r["matched"].get(A) and not r["downloading"] else None)(st()),
                             60, "download")
        report["after_download"] = {"matched": s["matched"].get(A), "entry": entry(s, path_a),
                                    "cloud_a": any(c["id"] == A for c in s["cloud"])}
        checks["download_at_cloud_path"] = s["matched"].get(A) == path_a and Path(path_a).is_file()
        ea = entry(s, path_a)
        checks["download_entry_opens"] = bool(ea and ea["select_enabled"] and ea["time"] == 1_700_000_900)
        checks["download_one_entry"] = sum(1 for e in s["hist"] if "Cloud Story" in e["file"]) == 1
        report["after_download_screenshot"] = shot("3-after-download")

        # 4. Delete A from ZenOS's Authors view.
        cmd("activate_navbar_tab", id="authors")
        time.sleep(2)
        report["authors_windows"] = cmd("sp_windows")
        report["authors_select"] = cmd("sp_select", text="Ann Author")
        time.sleep(2)
        before = cmd("sp_windows")
        report["author_books_before"] = before["windows"][-1]
        report["author_books_before_screenshot"] = shot("4-author-books-before")
        report["delete"] = cmd("sp_delete_from_top", path=path_a)
        time.sleep(3)
        after = cmd("sp_windows")
        report["author_books_after"] = after["windows"][-1]
        report["author_books_after_screenshot"] = shot("5-author-books-after-delete")
        checks["deleted_file_gone"] = not Path(path_a).exists()
        checks["still_in_author_view"] = any(i["path"] == path_a for i in after["windows"][-1]["items"])
        s = st()
        report["after_delete"] = {"entry": entry(s, path_a),
                                  "cloud_a": next((c["path"] for c in s["cloud"] if c["id"] == A), None)}
        checks["cloud_again_same_path"] = report["after_delete"]["cloud_a"] == path_a
        ea = entry(s, path_a)
        checks["history_kept_as_cloud"] = bool(ea and not ea["select_enabled"] and not ea["dim"]
                                               and ea["time"] == 1_700_000_900)
        log = ko_home / "crash.log"
        report["log"] = [line for line in (log.read_text(errors="replace").splitlines() if log.exists() else [])
                         if "Athenaeum" in line or "ERROR" in line or "traceback" in line][-60:]
    finally:
        if state["process"] is not None:
            zd.stop(state["process"])
        server.shutdown()
        if not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    report["all_passed"] = all(checks.values())
    (args.out / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({"checks": checks, "all_passed": report["all_passed"]}, indent=2))
    return 0 if report["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
