--[[
Cloud books in KOReader's file search (which ZenOS also uses and styles).

KOReader searches the folder's files; cloud books aren't files, so:
- matching cloud books (title, authors, series) are added after the files
  found, when the library folder is within the search;
- if no files match but cloud books do, those are shown instead of
  "No results";
- tapping or long-pressing a cloud result shows its details (KOReader's own
  handlers ignore paths that don't exist).

Options follow KOReader's search: case sensitivity, and * and ? wildcards.
]]

local util = require("util")

local Search = {
    enabled = true,
    installed = false,
}

--- Returns match(text) for KOReader's search options.
function Search.matcher(search_string, case_sensitive, use_patterns)
    if search_string == "*" then return function() return true end end
    local s = case_sensitive and search_string or util.stringLower(search_string)
    if use_patterns then
        s = s:gsub("%.", "%%."):gsub("%*", ".*"):gsub("%?", ".")
    end
    return function(text)
        if type(text) ~= "string" or text == "" then return false end
        if not case_sensitive then text = util.stringLower(text) end
        if use_patterns then
            local ok, found = pcall(string.find, text, s)
            return ok and found ~= nil
        end
        return text:find(s, 1, true) ~= nil
    end
end

--- Cloud books matching the search, by title, authors or series.
function Search.cloudMatches(books, search_string, case_sensitive, use_patterns)
    local match = Search.matcher(search_string, case_sensitive, use_patterns)
    local out = {}
    for _i, b in ipairs(books) do
        if match(b.title) or match(b.series)
                or (b.authors and #b.authors > 0 and match(table.concat(b.authors, ", "))) then
            table.insert(out, b)
        end
    end
    return out
end

--- Is the library folder part of a search of search_path?
function Search.inScope(folder, search_path, include_subfolders)
    if not (folder and search_path) then return false end
    local base = search_path:gsub("/+$", "")
    if base == "" then base = "/" end
    if folder == base then return true end
    if not include_subfolders then return false end
    return base == "/" or folder:sub(1, #base + 1) == base .. "/"
end

function Search.install(Virtual)
    if Search.installed then return end
    local Guard = require("cloudlibrary/guard")
    if not Guard.ok("search") then return end -- failed the startup check
    local ok, FileSearcher = pcall(require, "apps/filemanager/filemanagerfilesearcher")
    if not ok or type(FileSearcher) ~= "table" then return end
    Search.installed = true

    local function cloudItems(searcher)
        if not (Search.enabled and Virtual.folder and #Virtual.books > 0) then return {} end
        if not Search.inScope(Virtual.folder, FileSearcher.search_path, searcher.include_subfolders) then
            return {}
        end
        local books = Search.cloudMatches(Virtual.books, FileSearcher.search_string or "",
            searcher.case_sensitive, searcher.use_patterns)
        if #books == 0 then return {} end
        local FileChooser = require("ui/widget/filechooser")
        local fc = searcher.ui and searcher.ui.file_chooser or FileChooser:new{ ui = searcher.ui }
        local collate = fc:getCollate()
        local files = {}
        for _i, b in ipairs(books) do table.insert(files, Virtual.listItem(fc, b, collate)) end
        Virtual.ensureOutermost()
        return fc:genItemTable({}, files)
    end

    -- Files first (as KOReader sorted them), then cloud books. Results
    -- shown again from KOReader's cache get the current cloud books: books
    -- downloaded since are dropped, books deleted since are added. (A
    -- deleted file itself is dropped by KOReader.)
    local function augment(searcher, results)
        if results._cloudlibrary then
            local kept = {}
            for _i, item in ipairs(results) do
                if not item._cloudlibrary then table.insert(kept, item) end
            end
            for i = #results, 1, -1 do results[i] = nil end
            for i, item in ipairs(kept) do results[i] = item end
        end
        for _i, item in ipairs(cloudItems(searcher)) do
            item._cloudlibrary = true
            table.insert(results, item)
        end
        results._cloudlibrary = true
        return results
    end
    Search.augment = augment -- for tests

    local Guard = require("cloudlibrary/guard")
    Guard.hook("search", FileSearcher, "onShowSearchResults", function(orig, self, not_cached, ...)
        if FileSearcher.search_results then augment(self, FileSearcher.search_results) end
        return orig(self, not_cached, ...)
    end, "FileSearcher:onShowSearchResults")

    Guard.hook("search", FileSearcher, "showSearchResultsMessage", function(orig, self, no_results, ...)
        if no_results and FileSearcher.search_results then
            augment(self, FileSearcher.search_results)
            if #FileSearcher.search_results > 0 then
                return self:onShowSearchResults(true)
            end
        end
        return orig(self, no_results, ...)
    end, "FileSearcher:showSearchResultsMessage")

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
