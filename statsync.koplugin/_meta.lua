local _ = require("gettext")

return {
    fullname = _("Statistics sync"),
    version = "0.3.0",
    description = _([[Syncs reading statistics, and optionally highlights and bookmarks, between devices through a WebDAV server. Each device writes its own files, and merges the others' into its statistics.]]),
}
