"""Settings made in the web interface, kept in <data dir>/settings.json.

The file is readable only by the app's user: it holds the CWA password.
"""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path

DEFAULTS = {"cwa_url": "", "cwa_username": "", "cwa_password": ""}


class Settings:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self.values = dict(DEFAULTS)
        try:
            data = json.loads(self.path.read_text())
            if isinstance(data, dict):
                self.values.update({k: v for k, v in data.items() if k in DEFAULTS and isinstance(v, str)})
        except (OSError, ValueError):
            pass

    def get(self, key: str) -> str:
        with self.lock:
            return self.values.get(key, "")

    def update(self, **changes: str) -> None:
        with self.lock:
            self.values.update({k: v for k, v in changes.items() if k in DEFAULTS})
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(self.values, f, indent=2)
            os.replace(tmp, self.path)
