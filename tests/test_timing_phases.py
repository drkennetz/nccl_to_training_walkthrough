import pytest

from bench.common.phases import PhaseLog
from bench.common.timing import IterTimings, rank_stats


def test_rank_stats_names_the_straggler():
    t = [
        IterTimings(0, "a", 0, [1.0, 1.0, 1.0]),
        IterTimings(1, "a", 1, [1.0, 1.1, 1.0]),
        IterTimings(2, "b", 0, [1.5, 1.5, 1.5]),
    ]
    s = rank_stats(t)
    assert s["slowest_rank"] == 2
    assert s["rank_mean_max_s"] == pytest.approx(1.5)
    assert s["rank_mean_min_s"] == pytest.approx(1.0)
    assert s["ranks"] == 3
    assert s["min_s"] == 1.0 and s["max_s"] == 1.5
    assert s["spread_pct"] == pytest.approx(100 * 0.5 / (1.1 / 3 + 2 / 3), rel=1e-6)


def test_rank_stats_single_rank():
    s = rank_stats([IterTimings(0, "a", 0, [2.0, 2.0])])
    assert s["spread_pct"] == 0.0 and s["slowest_rank"] == 0


def test_rank_stats_empty():
    with pytest.raises(ValueError):
        rank_stats([])


def test_phases_intervals_are_ordered_and_closed():
    clock = iter([10.0, 12.0, 12.5, 20.0, 30.0, 31.0])
    p = PhaseLog(emit=False, clock=lambda: next(clock))
    p.begin("a")
    p.end("a")
    p.begin("b")
    p.end("b")
    out = p.to_list()
    assert out == [
        {"name": "a", "t_start": 10.0, "t_end": 12.0},
        {"name": "b", "t_start": 12.5, "t_end": 20.0},
    ]
    with pytest.raises(ValueError):
        p.end("zzz")
    p.begin("c")
    with pytest.raises(ValueError):
        p.begin("c")
