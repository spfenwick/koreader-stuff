--[[
File names for catalog books: a book's path is where its file is, or
where its file would be (STABLE_PATHS_PLAN.md).

Each book has a stem ("Author, Author - Title", with " (2)"... on a clash)
and a suffix ("epub", "pdf", "kepub.epub"), kept in the catalog (file_stem,
file_ext). The stem is given once and doesn't follow later title changes,
as a downloaded file's name doesn't. A book on the device takes its file's
name.

Stems are unique in the folder whatever the suffix: a stem is taken if a
book file in the folder has it, or another book was given it. So a book
can change format without needing a new number. (Two files already on the
device may share a stem, "A - T.epub" and "A - T.pdf"; matched books keep
their files' names.) Compared ignoring ASCII case, since FAT does.
]]

local Names = {}

--- A file name's stem and suffix: "A - T.epub" -> "A - T", "epub";
-- "A - T.kepub.epub" -> "A - T", "kepub.epub". The suffix keeps its case.
function Names.split(name)
    local stem, suffix = name:match("^(.+)%.([Kk][Ee][Pp][Uu][Bb]%.[Ee][Pp][Uu][Bb])$")
    if stem then return stem, suffix end
    stem, suffix = name:match("^(.+)%.([^.]+)$")
    if stem then return stem, suffix end
    return name, ""
end

--- The file name for a stem and suffix.
function Names.join(stem, suffix)
    if suffix == nil or suffix == "" then return stem end
    return stem .. "." .. suffix
end

local function key(stem) return stem:lower() end

--- Gives every book a stem and suffix. Changes the books (file_stem,
-- file_ext) and returns what changed: { { id, stem, ext, old_stem,
-- old_ext }, … }, in the books' order.
--   books       catalog books ({ id, file_stem, file_ext, … })
--   matched     { [id] = path } of the books on the device
--   file_names  every book file's name in the folder
--   opts.base(book)    the stem to start from ("Author - Title")
--   opts.suffix(book)  the suffix for a book that has none yet
function Names.assign(books, matched, file_names, opts)
    local taken = {}
    for _i, name in ipairs(file_names) do taken[key((Names.split(name)))] = true end
    local changes, pending = {}, {}
    local function set(book, stem, ext)
        if book.file_stem == stem and book.file_ext == ext then return end
        changes[#changes + 1] = { id = book.id, stem = stem, ext = ext,
            old_stem = book.file_stem, old_ext = book.file_ext }
        book.file_stem, book.file_ext = stem, ext
    end
    for _i, book in ipairs(books) do
        local path = matched[book.id]
        if path then
            -- On the device: the file's name (its stem is taken already).
            set(book, Names.split(path:match("[^/]*$")))
        elseif book.file_stem and book.file_ext and not taken[key(book.file_stem)] then
            taken[key(book.file_stem)] = true
        else
            -- No name yet, or its stem is now another file's or book's.
            pending[#pending + 1] = book
        end
    end
    for _i, book in ipairs(pending) do
        local base = opts.base(book)
        local stem, n = base, 1
        while taken[key(stem)] do
            n = n + 1
            stem = string.format("%s (%d)", base, n)
        end
        taken[key(stem)] = true
        set(book, stem, book.file_ext or opts.suffix(book))
    end
    return changes
end

return Names
