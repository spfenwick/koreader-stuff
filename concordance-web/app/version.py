"""Concordance web's own version, shown at the bottom of every page. Raise it
with each change worth telling apart (the image is also tagged web-X.Y.Z).

CONCORDANCE_VERSION is the version of the plugin code the ingester runs (its
_meta.lua, copied into the image beside it), shown beside it."""

import os
import re
from pathlib import Path

VERSION = "0.2.5"


def _concordance_version() -> str | None:
    lib = os.environ.get("CONCORDANCE_LIB")
    candidates = [Path(lib) / "_meta.lua"] if lib else []
    # Run from the repository: the plugin's folder beside concordance-web.
    here = Path(__file__).resolve().parents
    if len(here) > 2:
        candidates.append(here[2] / "concordance.koplugin" / "_meta.lua")
    for path in candidates:
        try:
            m = re.search(r'version\s*=\s*"([\w.+-]+)"', path.read_text())
        except OSError:
            continue
        if m:
            return m.group(1)
    return None


CONCORDANCE_VERSION = _concordance_version()
