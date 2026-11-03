local _ = require("gettext")

return {
    fullname = _("Statistics sync"),
    version = "0.2.2",
    description = _([[Syncs reading statistics between devices through a WebDAV server. Each device writes its own files, and merges the others' into its statistics.]]),
}
