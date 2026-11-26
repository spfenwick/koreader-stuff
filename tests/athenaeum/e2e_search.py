"""Cloud books in file search, in the real app (KOReader + ZenOS), with the
test catalog (no server). ZenOS's search adds its fileless book sources'
books to each home folder's results (BookSources.searchResults, after
KOReader's walk), so they're matched as files are:

- ZenOS's rules (substring, whole words), by file name and by metadata only
  (a tag), which is read in the search's subprocess; with ZenOS's search
  off, KOReader's search finds files only;
- a whole-word search nothing matches: "No results";
- ZenOS's search over several home folders, the library under the second;
- tapping a cloud result shows its details (ZenOS asks the source); Guard
  reports search as working;
- ZenOS lists the cloud books: a folder count (getList without collate)
  includes them, and so does the library folder's cover (count, cover
  images);
- ZenOS's flat view ("Show all files from subfolders"): the library folder
  and the folder above it show and count its cloud books once;
- select mode: cloud books can't be selected (tapped, or "select all").

Needs a ZenOS that lists book sources' books without a file
(booksWithoutFile) and whose search adds them (searchResults):
ZenOS's custom branch with those changes (git archive custom | tar -x -C
<dir>, plus the changes if uncommitted).

    python3 tests/athenaeum/e2e_search.py --koreader <emulator>/koreader \\
        --zenos <zen-os export> --out /tmp/e2e-search
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
        elseif params.zen then
            -- As ZenOS's search dialog sets them (its getList searches each).
            fs._zen_search_paths = { params.path }
            FileSearcher.search_path = params.path
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
    if kind == "srch_count" then
        local fc = require("apps/filemanager/filemanager").instance.file_chooser
        local Virtual = package.loaded["athenaeum/virtual"]
        local r = table.pack and table.pack(fc:getList(params.path)) or { fc:getList(params.path) }
        local files = r[2] or {}
        local all_true = true
        for _i, f in ipairs(files) do if f ~= true then all_true = false end end
        local BookSources = package.loaded["common/book_sources"]
        local zenos_lists = type(BookSources) == "table" and type(BookSources.booksWithoutFile) == "function"
        -- The library folder's cover, as the folder above shows it.
        local FolderCover = require("modules/filebrowser/folder_cover")
        if type(FolderCover.clear) == "function" then FolderCover.clear() end
        local entries, _physical, cover_count = FolderCover.previewEntries(fc,
            { path = params.path, attr = { mode = "directory" } }, 4)
        local cover_cloud = 0
        for _i, e in ipairs(entries or {}) do
            if Virtual.isVirtual(e.path) then cover_cloud = cover_cloud + 1 end
        end
        return { ok = true, files = #files, all_true = all_true, zenos_lists = zenos_lists,
            cover_count = cover_count, cover_cloud = cover_cloud }
    end
    if kind == "flat" then
        local fc = require("apps/filemanager/filemanager").instance.file_chooser
        local FileChooser = require("ui/widget/filechooser")
        local cfg = require("config/manager").get()
        cfg.browser_flat_view = cfg.browser_flat_view or {}
        cfg.browser_flat_view.enabled = params.on
        if params.home then G_reader_settings:saveSetting("home_dir", params.home) end
        for _i, p in ipairs(params.invalidate or {}) do
            if type(FileChooser._zen_invalidate_item_table_path) == "function" then
                pcall(FileChooser._zen_invalidate_item_table_path, fc, p)
            end
        end
        fc:changeToPath(params.path)
        local Virtual = package.loaded["athenaeum/virtual"]
        local cloud = {}
        for _i, item in ipairs(fc.item_table or {}) do
            if item.is_file and Virtual.isVirtual(item.path) then cloud[#cloud + 1] = item.path end
        end
        local counted = { fc:getList(params.path) }
        local BookSources = package.loaded["common/book_sources"]
        return { ok = true, cloud = #cloud, count = #(counted[2] or {}),
            zenos_lists = type(BookSources) == "table" and type(BookSources.booksWithoutFile) == "function" }
    end
    if kind == "select" then
        local fm = require("apps/filemanager/filemanager").instance
        local fc = fm.file_chooser
        local Virtual = package.loaded["athenaeum/virtual"]
        local BookSources = package.loaded["common/book_sources"]
        fc:changeToPath(params.path)
        if fm.selected_files then fm:onToggleSelectMode() end
        fm:onToggleSelectMode()
        local cloud_item, local_item
        for _i, item in ipairs(fc.item_table or {}) do
            if item.is_file and Virtual.isVirtual(item.path) then cloud_item = cloud_item or item
            elseif item.is_file then local_item = local_item or item end
        end
        if cloud_item then fc:onFileSelect(cloud_item) end
        local tapped = cloud_item and fm.selected_files[cloud_item.path] == true or false
        local tapped_dim = cloud_item and cloud_item.dim == true or false
        fc:selectAllFilesInFolder(true)
        local cloud_selected, selected = 0, 0
        for path in pairs(fm.selected_files) do
            selected = selected + 1
            if Virtual.isVirtual(path) then cloud_selected = cloud_selected + 1 end
        end
        fm:onToggleSelectMode()
        return { ok = true, guarded = type(BookSources) == "table" and type(BookSources.selectable) == "function",
            tapped = tapped, tapped_dim = tapped_dim, cloud_selected = cloud_selected, selected = selected,
            has_cloud = cloud_item ~= nil }
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
    report["count"] = s.cmd("srch_count", path=lib)
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
    # ZenOS's flat view: the library folder, then (as home) the folder above it.
    parent = str(Path(lib).parent)
    report["flat_library"] = s.cmd("flat", on=True, path=lib, invalidate=[lib, parent])
    report["flat_parent"] = s.cmd("flat", on=True, home=parent, path=parent, invalidate=[lib, parent])
    report["flat_off"] = s.cmd("flat", on=False, home=lib, path=lib, invalidate=[lib, parent])
    # Select mode: books without a file can't be selected (a ZenOS with the guard).
    report["select"] = s.cmd("select", path=lib)
finally:
    s.close()
(args.out / "report.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
expected = {
    "zen_substring_remote": ["Brave Remote World"],
    "zen_substring_remot": ["Brave Remote World"], "zen_tag_only": ["Brave Remote World"],
    "zen_roots": ["Cloud Atlas"],
}
failed = [k for k, v in expected.items() if not isinstance(report.get(k), dict) or report[k]["cloud"] != v]
# ZenOS's search off: KOReader's search, files only.
for k in ("ko_title", "ko_tag_only"):
    v = report.get(k)
    if isinstance(v, dict) and v["cloud"]:
        failed.append(k)
if report.get("zen_wholeword_remot") != "no results":
    failed.append("zen_wholeword_remot")
count = report.get("count") or {}
# ZenOS lists the cloud books: counts, the library folder's cover (count and
# cover images), flat view of the library and the folder above it.
if not count.get("zenos_lists"):
    failed.append("ZenOS doesn't list book sources' books (needs booksWithoutFile)")
if not (count.get("files") == 4 and count.get("all_true")):
    failed.append("count")
if not (count.get("cover_count") == 4 and count.get("cover_cloud", 0) >= 1):
    failed.append("folder cover")
flat = report.get("flat_library") or {}
if not (flat.get("cloud") == 2 and flat.get("count") == 4):
    failed.append("flat_library")
if (report.get("flat_parent") or {}).get("cloud") != 2:
    failed.append("flat_parent")
off = report.get("flat_off") or {}
if not (off.get("cloud") == 2 and off.get("count") == 4):
    failed.append("flat_off")
sel = report.get("select") or {}
if not (sel.get("guarded") and sel.get("has_cloud") and not sel.get("tapped") and not sel.get("tapped_dim")
        and sel.get("cloud_selected") == 0):
    failed.append("select")
if not report.get("tap_details"):
    failed.append("tap_details")
if any(isinstance(v, dict) and "search_ok" in v and not v["search_ok"] for v in report.values()) or report.get("status"):
    failed.append("search turned off")
print("FAILED: " + ", ".join(failed) if failed else "all passed")
sys.exit(1 if failed else 0)
