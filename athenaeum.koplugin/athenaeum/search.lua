--[[
Cloud books in KOReader's file search (which ZenOS also uses and styles).

KOReader's search walks the folders (FileSearcher:getList, in a
subprocess) and asks isFileMatch about each file. Cloud books aren't files,
so the walk never sees them. They're put into it instead: after the walk,
each cloud book in the searched folder is asked of the same isFileMatch, and
those that match are added to the files found, as the walk adds files. So
cloud books are matched exactly as files are, by KOReader's rules or, with
ZenOS's search on, by ZenOS's (its isFileMatch: normalized text, whole words
or substrings, metadata). KOReader then builds, sorts and caches the
results with the rest, and shows them, or "No results".

ZenOS's search covers the home folder and its additional home folders by
calling getList once per folder, with FileSearcher.search_path set to it;
this getList is inside ZenOS's, so each call is checked against its folder.

Also:
- isFileMatch's metadata search reads cloud books' metadata through
  getDocProps, which ZenOS answers from the book sources;
- results are searched again when the cloud books changed since they were
  cached (KOReader would show the cached ones);
- results carry the books' metadata (doc_props), as the library's items do;
- tapping or long-pressing a cloud result shows its details (KOReader's
  own handlers ignore paths that don't exist).

The search text is prepared as getList prepares it (lowercase unless case
sensitive; with "Use patterns", wildcards made Lua patterns): getList keeps
it in a local.
]]

local util = require("util")

local Search = {
    enabled = true,
    installed = false,
}

local function pack(...) return { n = select("#", ...), ... } end

--- Is the library folder part of a search of search_path?
function Search.inScope(folder, search_path, include_subfolders)
    if not (folder and search_path) then return false end
    local base = search_path:gsub("/+$", "")
    if base == "" then base = "/" end
    if folder == base then return true end
    if not include_subfolders then return false end
    return base == "/" or folder:sub(1, #base + 1) == base .. "/"
end

--- The search text as FileSearcher:getList hands it to isFileMatch.
function Search.query(searcher, search_string)
    if search_string == "*" then return search_string end
    if not searcher.case_sensitive then search_string = util.stringLower(search_string) end
    if searcher.use_patterns then
        search_string = search_string:gsub("%.", "%%%."):gsub("%*", "%.%*"):gsub("%?", "%.")
    end
    return search_string
end

--- The cloud books a search finds, as getList's entries:
-- { { name, path, attributes }, … }, leaving out paths in found (the walk
-- found a file there). searcher is the FileSearcher. search: { path,
-- string } (FileSearcher.search_path and search_string), FileChooser and
-- DocumentRegistry (the filters the walk applies to files).
function Search.cloudEntries(Virtual, searcher, found, search)
    if not (Search.enabled and Virtual.folder and #Virtual.books > 0) then return {} end
    if not Search.inScope(Virtual.folder, search.path, searcher.include_subfolders) then return {} end
    local FileChooser, DocumentRegistry = search.FileChooser, search.DocumentRegistry
    local query = Search.query(searcher, search.string or "")
    local out = {}
    -- Content search would open each book; a cloud book has no file. Its
    -- books add nothing to "N files without metadata": they have metadata,
    -- unless there's no CoverBrowser, which isn't theirs to report.
    local content, no_metadata = searcher.include_content, searcher.no_metadata_count
    searcher.include_content = false
    local ok, err = pcall(function()
        for _i, book in ipairs(Virtual.books) do
            local name, path = book.filename, book.path
            if name and path and not found[path] and not util.stringStartsWith(name, "._")
                    and (FileChooser.show_unsupported or DocumentRegistry:hasProvider(path))
                    and FileChooser:show_file(name)
                    and searcher:isFileMatch(name, path, query, true) then
                out[#out + 1] = { name, path, Virtual.attributes(book) }
            end
        end
    end)
    searcher.include_content, searcher.no_metadata_count = content, no_metadata
    if not ok then error(err, 0) end
    return out
end

--- KOReader reuses cached results for the same search: not once the cloud
-- books have changed (a book downloaded, deleted, added to the catalog).
-- generation: Virtual.generation.
function Search.dropStale(FileSearcher, generation)
    if Search.generation ~= generation then FileSearcher.search_hash = nil end
    Search.generation = generation
end

function Search.install(Virtual)
    if Search.installed then return end
    local Guard = require("athenaeum/guard")
    if not Guard.ok("search") then return end -- failed the startup check
    local ok, FileSearcher = pcall(require, "apps/filemanager/filemanagerfilesearcher")
    if not ok or type(FileSearcher) ~= "table" then return end
    Search.installed = true
    local FileChooser = require("ui/widget/filechooser")
    local DocumentRegistry = require("document/documentregistry")

    -- In the search's subprocess, once per folder searched (ZenOS calls it
    -- for each of its home folders).
    Guard.hook("search", FileSearcher, "getList", function(orig, self, ...)
        local r = pack(orig(self, ...))
        local files = r[2]
        if type(files) ~= "table" then return unpack(r, 1, r.n) end
        local found = {}
        for _i, entry in ipairs(files) do
            if type(entry) == "table" and type(entry[2]) == "string" then found[entry[2]] = true end
        end
        local search = { path = FileSearcher.search_path, string = FileSearcher.search_string,
            FileChooser = FileChooser, DocumentRegistry = DocumentRegistry }
        for _i, entry in ipairs(Search.cloudEntries(Virtual, self, found, search)) do
            files[#files + 1] = entry
        end
        return unpack(r, 1, r.n)
    end, "FileSearcher:getList")

    Guard.hook("search", FileSearcher, "doSearch", function(orig, self, ...)
        Search.dropStale(FileSearcher, Virtual.generation)
        return orig(self, ...)
    end, "FileSearcher:doSearch")

    Guard.hook("search", FileSearcher, "onShowSearchResults", function(orig, self, ...)
        for _i, item in ipairs(FileSearcher.search_results or {}) do
            local book = type(item) == "table" and Virtual.by_path[item.path]
            if book then
                item._athenaeum = true
                Virtual.withProps(item, book)
            end
        end
        return orig(self, ...)
    end, "FileSearcher:onShowSearchResults")

    -- Called with the results menu as self (its _manager is the searcher).
    for _i, name in ipairs({ "onMenuSelect", "onMenuHold" }) do
        Guard.hook("search", FileSearcher, name, function(orig, self, item, ...)
            local manager = self._manager or self
            if type(item) == "table" and Virtual.by_path[item.path] and not manager.selected_files then
                Virtual.showDetails(item.path)
                return true
            end
            return orig(self, item, ...)
        end, "FileSearcher:" .. name)
    end
end

return Search
