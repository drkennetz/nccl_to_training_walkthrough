"""Per-iteration timings on every rank and the cross-rank statistics (the 'rank variance')."""

from __future__ import annotations

import statistics
from dataclasses import asdict, dataclass, field


@dataclass
class IterTimings:
    rank: int
    host: str
    local_rank: int
    seconds: list[float] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _p50(xs: list[float]) -> float:
    return float(statistics.median(xs))


def rank_stats(all_: list[IterTimings]) -> dict:
    """Aggregate per-rank per-iteration timings.

    mean_s/p50_s/min_s/max_s are over every (rank, iteration) sample. The rank_* fields are
    over the per-rank MEANS, and spread_pct = (max_rank_mean - min_rank_mean) / p50_rank_mean.
    slowest_rank names the straggler.
    """
    if not all_ or not any(t.seconds for t in all_):
        raise ValueError("no timings")
    flat = [s for t in all_ for s in t.seconds]
    means = {t.rank: statistics.fmean(t.seconds) for t in all_ if t.seconds}
    rank_means = list(means.values())
    p50_rank = _p50(rank_means)
    slowest = max(means, key=means.get)
    return {
        "mean_s": statistics.fmean(flat),
        "p50_s": _p50(flat),
        "min_s": min(flat),
        "max_s": max(flat),
        "rank_mean_min_s": min(rank_means),
        "rank_mean_max_s": max(rank_means),
        "rank_mean_p50_s": p50_rank,
        "spread_pct": 100.0 * (max(rank_means) - min(rank_means)) / p50_rank if p50_rank else 0.0,
        "slowest_rank": slowest,
        "ranks": len(means),
    }
