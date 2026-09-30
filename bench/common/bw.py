"""Collective bandwidth conventions (the same as the vendor collective benchmarks).

all_reduce:  algbw = bytes / t ;  busbw = algbw * 2(n-1)/n
all_gather / reduce_scatter / all_to_all: busbw = total_bytes * (n-1)/n / t with total = n * bytes_per_rank
"""

from __future__ import annotations


def algbw_gbs(nbytes: int, seconds: float) -> float:
    if seconds <= 0:
        raise ValueError("seconds must be > 0")
    return nbytes / seconds / 1e9


def bus_factor(world: int, collective: str = "all_reduce") -> float:
    if world < 1:
        raise ValueError("world must be >= 1")
    if world == 1:
        return 0.0
    if collective == "all_reduce":
        return 2.0 * (world - 1) / world
    if collective in ("all_gather", "reduce_scatter", "all_to_all"):
        return (world - 1) / world
    raise ValueError(f"unknown collective {collective!r}")


def busbw_gbs(nbytes: int, seconds: float, world: int, collective: str = "all_reduce") -> float:
    """Bus bandwidth in GB/s. `nbytes` is the per-rank buffer for all_reduce and the TOTAL
    (gathered / exchanged) buffer for the other collectives, as in the vendor tools."""
    return algbw_gbs(nbytes, seconds) * bus_factor(world, collective)
