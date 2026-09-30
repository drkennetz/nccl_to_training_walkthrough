"""Iteration and warm-up counts per message size, so one size stays about a minute.

Copied from the KTLO multi-node ladder so the figures are comparable with that record.
"""

from __future__ import annotations

MiB = 1 << 20
GiB = 1 << 30


def iters_for(nbytes: int) -> int:
    if nbytes <= 16 * MiB:
        return 100
    if nbytes <= 128 * MiB:
        return 50
    if nbytes <= 512 * MiB:
        return 20
    if nbytes <= 2 * GiB:
        return 10
    return 5


def warmup_for(nbytes: int) -> int:
    if nbytes <= 128 * MiB:
        return 20
    if nbytes <= 2 * GiB:
        return 10
    return 3
