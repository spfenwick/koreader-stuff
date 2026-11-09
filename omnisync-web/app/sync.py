"""Runs the ingester (ingest/ingest.lua) on a timer, and on demand.

Each run is a fresh LuaJIT process: it imports what's new and exits. When it
imported anything, the library is reloaded.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field

from .library import Library

log = logging.getLogger("omnisync-web")


@dataclass
class SyncState:
    running: bool = False
    last_started: float | None = None
    last_finished: float | None = None
    last_result: dict = field(default_factory=dict)
    last_error: str = ""
    runs: int = 0


class Syncer:
    def __init__(self, library: Library, cmd: list[str], interval: int, timeout: int = 600):
        self.library = library
        self.cmd = cmd
        self.interval = interval
        self.timeout = timeout
        self.state = SyncState()
        self._wake = asyncio.Event()
        self._lock = asyncio.Lock()
        self._task: asyncio.Task | None = None

    def start(self) -> None:
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()

    def trigger(self) -> None:
        self._wake.set()

    async def _loop(self) -> None:
        # Show whatever an earlier run left, before the first import finishes.
        await asyncio.to_thread(self.library.reload)
        while True:
            try:
                await self.run_once()
            except Exception:  # keep the loop alive whatever happens
                log.exception("sync failed")
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=self.interval)
            except asyncio.TimeoutError:
                pass
            self._wake.clear()

    async def run_once(self) -> None:
        async with self._lock:
            st = self.state
            st.running, st.last_started = True, time.time()
            try:
                proc = await asyncio.create_subprocess_exec(
                    *self.cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                try:
                    out, err = await asyncio.wait_for(proc.communicate(), timeout=self.timeout)
                except asyncio.TimeoutError:
                    proc.kill()
                    await proc.wait()
                    st.last_error = f"import took longer than {self.timeout} s and was stopped"
                    return
                result = {}
                lines = out.decode(errors="replace").strip().splitlines()
                if lines:
                    try:
                        result = json.loads(lines[-1])
                    except ValueError:
                        pass
                st.last_result = result
                errors = result.get("errors") or []
                if proc.returncode != 0 or errors:
                    tail = err.decode(errors="replace").strip().splitlines()[-5:]
                    st.last_error = "; ".join(errors) if errors else "\n".join(tail) or f"exit status {proc.returncode}"
                    log.warning("import failed: %s", st.last_error)
                else:
                    st.last_error = ""
                # A failed run may still have imported some segments first.
                if result.get("changed") or proc.returncode != 0 or self.library.loaded_at is None:
                    await asyncio.to_thread(self.library.reload)
                    log.info("imported %s", result.get("imported"))
            finally:
                st.running, st.last_finished = False, time.time()
                st.runs += 1
