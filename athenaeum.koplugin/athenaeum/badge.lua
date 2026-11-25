--[[
Cover badges, in a circle on the bottom-right corner of the cover:
- cloud: a cloud on books that are only in the online library (default on);
  it shows only that the book is in the cloud, not its reading status (ZenOS
  shows that in its own status badge);
- local: a check mark on local books that are in the catalog (default off);
- noncloud: a crossed-out cloud on books in the library folder that aren't
  in the catalog (default off).

ZenOS paints them: the book source's badge(path) (see
athenaeum/zenos_source.lua) gives Badge.icon(Badge.kind(path)), and ZenOS
draws that icon in its badge colours wherever it draws the book's cover.
Views ZenOS doesn't draw (KOReader's plain list, its own lists) show no
badge.
]]

local Badge = {
    local_enabled = false,
    cloud_enabled = true,
    noncloud_enabled = false,
    isOnDevice = nil, -- function(path) -> true for local books in the catalog
    isCloud = nil,    -- function(path) -> true for cloud-only books
    isNonCloud = nil, -- function(path) -> true for local books not in the catalog
}

-- The plugin's own cloud icons (KOReader has none).
local ICONS = (debug.getinfo(1, "S").source:match("^@(.*)/athenaeum/[^/]*$") or ".") .. "/icons/"
local CLOUD_ICON = ICONS .. "cloud.svg"
local KIND_ICONS = {
    ["local"] = ICONS .. "check.svg",
    cloud = CLOUD_ICON,
    noncloud = ICONS .. "cloud-off.svg",
}

--- Which badge a path gets: "cloud", "local", "noncloud" or nil.
function Badge.kind(path)
    if Badge.cloud_enabled and Badge.isCloud and Badge.isCloud(path) then return "cloud" end
    if Badge.local_enabled and Badge.isOnDevice and Badge.isOnDevice(path) then return "local" end
    if Badge.noncloud_enabled and Badge.isNonCloud and Badge.isNonCloud(path) then return "noncloud" end
end

--- The SVG file for a badge kind (from Badge.kind).
function Badge.icon(kind)
    return KIND_ICONS[kind] or CLOUD_ICON
end

return Badge
