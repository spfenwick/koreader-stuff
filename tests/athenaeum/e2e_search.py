"""Cloud books in file search, in the real app (KOReader + ZenOS), with the
test catalog (no server). athenaeum/search.lua puts them into the search's
own walk, so they're matched as files are:

- KOReader's rules (ZenOS's search off) and ZenOS's (substring, whole
  words), by file name and by metadata only (a tag), which is read in the
  search's subprocess;
- a whole-word search nothing matches: "No results";
- ZenOS's search over several home folders, the library under the second;
- tapping a cloud result shows its details; the search hooks stay on.

Use ZenOS's custom branch (git archive custom | tar -x -C <dir>).

    python3 tests/athenaeum/e2e_search.py --koreader <emulator>/koreader         --zenos <zen-os export> --out /tmp/e2e-search
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

EXTRA = r"""
    if kind == "srch" then
        local fm = require("apps/filemanager/filemanager").instance
        local fs = fm.filesearcher
        local FileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        if fs.booklist_menu then fs.booklist_menu.close_callback() end
        local cfg = require("config/manager").get()
        cfg.search = cfg.search or {}
        cfg.search.substring = params.substring
        cfg.features.search = params.zen
        FileSearcher.search_string = params.query
        FileSearcher.search_hash = nil
        fs.include_subfolders = true
        fs.case_sensitive = false
        fs.use_patterns = false
        fs.include_metadata = true
        if params.roots then
            fs._zen_search_paths = params.roots
            FileSearcher.search_path = params.roots[1]
        else
            fs._zen_search_paths = nil
            FileSearcher.search_path = params.path
        end
        require("ui/trapper"):wrap(function() fs:doSearch() end)
        return { ok = true }
    end
    if kind == "srch_results" then
        local fs = require("apps/filemanager/filemanager").instance.filesearcher
        local menu = fs.booklist_menu
        local Virtual = package.loaded["athenaeum/virtual"]
        local out = {}
        if menu then
            for _i, item in ipairs(menu.item_table or {}) do
                out[#out + 1] = { path = item.path, cloud = Virtual.isVirtual(item.path),
                    title = item.doc_props and item.doc_props.display_title or false }
            end
        end
        local Guard = package.loaded["athenaeum/guard"]
        return { ok = true, open = menu ~= nil, items = out, search_ok = Guard.ok("search"),
            status = Guard.statusText() }
    end
    if kind == "srch_tap" then
        local menu = require("apps/filemanager/filemanager").instance.filesearcher.booklist_menu
        for _i, item in ipairs(menu.item_table) do
            if item.path == params.path then menu:onMenuSelect(item) return { ok = true } end
        end
        return { ok = false }
    end
"""

p = argparse.ArgumentParser()
p.add_argument("--koreader", type=Path, required=True)
p.add_argument("--zenos", type=Path, required=True)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--keep", action="store_true")
args = p.parse_args()
args.koreader, args.zenos = args.koreader.resolve(), args.zenos.resolve()
args.out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(args.zenos / "spec/python"))
import fixtures as fx  # noqa
import zen_driver as zd  # noqa
proto_b.DRIVER_EXTENSION += proto_c.EXTRA_COMMANDS + EXTRA
s = proto_c.Session(args, zd, fx, "search")
report = {}
try:
    virtual = s.set_fixture(proto_c.small_catalog(["Cloud Atlas", "Brave Remote World"]))
    s.start()
    s.cmd("activate_navbar_tab", id="books")
    time.sleep(6); report["listing_files"] = s.listing().get("files")
    lib = str(s.library)
    parent = str(Path(lib).parent)
    def run(label, **kw):
        s.cmd("srch", **kw)
        try:
            proto_b.wait_for(lambda: (lambda r: r if r.get("open") else None)(s.cmd("srch_results")), 12, label)
        except TimeoutError:
            report[label] = "no results"
            s.cmd("athenaeum_close_top")
            return []
        time.sleep(1)
        r = s.cmd("srch_results")
        items = r["items"] if isinstance(r["items"], list) else []
        report[label] = {"cloud": sorted(i["title"] for i in items if i["cloud"]),
                         "local": len([i for i in items if not i["cloud"]]), "search_ok": r["search_ok"]}
        return items
    # KOReader's rules (ZenOS's search off).
    run("ko_title", query="atlas", path=lib, zen=False, substring=True)
    # ZenOS's rules: substring, then whole words.
    run("zen_substring_remote", query="remote", path=lib, zen=True, substring=True)
    run("zen_substring_remot", query="remot", path=lib, zen=True, substring=True)
    run("zen_wholeword_remot", query="remot", path=lib, zen=True, substring=False)
    # Metadata only: a tag (the file names don't have it).
    run("zen_tag_only", query="classics", path=lib, zen=True, substring=True)
    run("ko_tag_only", query="classics", path=lib, zen=False, substring=True)
    # ZenOS several roots: library under the second one.
    items = run("zen_roots", query="cloud", roots=["/nonexistent-root", parent], zen=True, substring=True)
    cloud = next((i for i in items if i["cloud"]), None)
    if cloud:
        s.cmd("srch_tap", path=cloud["path"])
        time.sleep(1)
        report["tap_details"] = s.cmd("athenaeum_state").get("last_details") == cloud["path"]
        report["tap_shot"] = s.shot("tap")
        s.cmd("athenaeum_close_top")
    report["status"] = s.cmd("srch_results").get("status")
finally:
    s.close()
(args.out / "report.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
expected = {
    "ko_title": ["Cloud Atlas"], "zen_substring_remote": ["Brave Remote World"],
    "zen_substring_remot": ["Brave Remote World"], "zen_tag_only": ["Brave Remote World"],
    "ko_tag_only": ["Brave Remote World"], "zen_roots": ["Cloud Atlas"],
}
failed = [k for k, v in expected.items() if not isinstance(report.get(k), dict) or report[k]["cloud"] != v]
if report.get("zen_wholeword_remot") != "no results":
    failed.append("zen_wholeword_remot")
if not report.get("tap_details"):
    failed.append("tap_details")
if any(isinstance(v, dict) and not v.get("search_ok") for v in report.values()) or report.get("status"):
    failed.append("search turned off")
print("FAILED: " + ", ".join(failed) if failed else "all passed")
sys.exit(1 if failed else 0)
