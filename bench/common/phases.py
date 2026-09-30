"""Phase markers: the benchmark writes when each phase starts and ends (wall clock, UTC epoch
seconds) so the 1 Hz counter samples and the Grafana annotations can be joined to it."""

from __future__ import annotations

import json
import sys
import time


class PhaseLog:
    def __init__(self, emit: bool = True, clock=time.time):
        self._emit = emit
        self._clock = clock
        self._open: dict[str, float] = {}
        self._done: list[dict] = []

    def begin(self, name: str) -> None:
        if name in self._open:
            raise ValueError(f"phase {name!r} already open")
        t = self._clock()
        self._open[name] = t
        self._print({"name": name, "event": "start", "t": t})

    def end(self, name: str) -> None:
        if name not in self._open:
            raise ValueError(f"phase {name!r} was never begun")
        t = self._clock()
        self._done.append({"name": name, "t_start": self._open.pop(name), "t_end": t})
        self._print({"name": name, "event": "end", "t": t})

    def to_list(self) -> list[dict]:
        return [dict(d) for d in self._done]

    def _print(self, d: dict) -> None:
        if self._emit:
            print("PHASE " + json.dumps(d), file=sys.stdout, flush=True)
