import pytest

from bench.common import bw, schedule, sizes

MiB, GiB = 1 << 20, 1 << 30


@pytest.mark.parametrize(
    "s,expect",
    [
        ("1Mi", MiB),
        ("1MiB", MiB),
        ("512M", 512 * MiB),
        ("8Gi", 8 * GiB),
        ("4KiB", 4096),
        ("12345", 12345),
        (77, 77),
    ],
)
def test_parse_size(s, expect):
    assert sizes.parse_size(s) == expect


@pytest.mark.parametrize("bad", ["1.5Gi", "1Zi", "", "Mi"])
def test_parse_size_rejects(bad):
    with pytest.raises(ValueError):
        sizes.parse_size(bad)


def test_sweep_1mib_to_8gib_is_14_points():
    pts = sizes.sweep(MiB, 8 * GiB)
    assert len(pts) == 14 and pts[0] == MiB and pts[-1] == 8 * GiB


def test_parse_sizes_forms():
    assert sizes.parse_sizes("1Mi:4Mi") == [MiB, 2 * MiB, 4 * MiB]
    assert sizes.parse_sizes("16Mi,512Mi,4Gi") == [16 * MiB, 512 * MiB, 4 * GiB]
    assert sizes.parse_sizes("512Mi") == [512 * MiB]


@pytest.mark.parametrize("n", [4096, MiB, 512 * MiB, 8 * GiB, 12345])
def test_format_roundtrip(n):
    assert sizes.parse_size(sizes.format_size(n)) == n


@pytest.mark.parametrize(
    "n,it",
    [(16 * MiB, 100), (16 * MiB + 1, 50), (128 * MiB, 50), (512 * MiB, 20), (2 * GiB, 10), (8 * GiB, 5)],
)
def test_iters_for(n, it):
    assert schedule.iters_for(n) == it


def test_warmup_monotone_non_increasing():
    pts = sizes.sweep(MiB, 8 * GiB)
    w = [schedule.warmup_for(p) for p in pts]
    assert w == sorted(w, reverse=True)


def test_algbw_and_busbw():
    assert bw.algbw_gbs(1e9, 1.0) == pytest.approx(1.0)
    assert bw.busbw_gbs(1e9, 1.0, 8) == pytest.approx(2 * 7 / 8)
    assert bw.busbw_gbs(1e9, 1.0, 2) == pytest.approx(1.0)
    assert bw.busbw_gbs(1e9, 1.0, 1) == 0.0
    assert bw.busbw_gbs(8e9, 1.0, 8, "all_gather") == pytest.approx(7.0)
    with pytest.raises(ValueError):
        bw.busbw_gbs(1, 1.0, 8, "bogus")
    with pytest.raises(ValueError):
        bw.algbw_gbs(1, 0.0)
