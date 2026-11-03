local _ = require("gettext")

return {
    fullname = _("Knuth–Plass justification"),
    -- Compared with the latest release by the updater; keep it in step
    -- with the release tag (knuthplass-vX.Y.Z).
    version = "0.6.0",
    description = _([[Settings for Knuth–Plass paragraph line breaking in CREngine builds that support it. Settings are stored per book and can be used from gestures and Profiles.]]),
}
