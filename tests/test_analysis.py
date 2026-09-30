import os

import pandas as pd
import pytest

from analysis import charts, counters, load, summary, tables
from analysis.__main__ import main as analysis_main


@pytest.fixture(scope="module")
def results(fixtures):
    return load.load_results(str(fixtures / "results"))


def test_load_and_frames(results):
    assert len(results) >= 20
    sw, tr, idx = load.to_sweep_frame(results), load.to_training_frame(results), load.index_frame(results)
    assert set(sw.experiment) >= {"E1", "E2", "E4", "E5"} and len(tr) == 5 and len(idx) == len(results)
    assert (sw.qps.isin([1, 2, 4])).all()


def test_e1_and_e2_tables(results):
    sw = load.to_sweep_frame(results)
    t1 = tables.e1_table(sw)
    assert "nvlink" in t1.columns and "rdma" in t1.columns and t1["size"].iloc[0] == "1MiB" and len(t1) == 14
    t2 = tables.e2_table(sw)
    assert list(t2.columns) == ["bytes", "size", "rails1", "rails2", "rails4"]
    t2 = t2.dropna()  # the E1 rdma sweep covers 14 sizes, the rail cells only 3
    assert len(t2) == 3 and (t2["rails4"] > t2["rails2"]).all() and (t2["rails2"] > t2["rails1"]).all()
    ts = tables.e1_small_table(sw)
    assert "nvlink_us" in ts.columns and ts["size"].iloc[0] == "4KiB"


def test_e3_scaling_efficiency(results):
    t = tables.e3_scaling(load.to_training_frame(results))
    one = t[t.gpus == 1].iloc[0]
    assert one.efficiency == pytest.approx(1.0) and one.speedup == pytest.approx(1.0)
    eight = t[(t.gpus == 8) & (t.transport == "nvlink")].iloc[0]
    assert eight.efficiency == pytest.approx(744 / 800, rel=1e-3)


def test_e4_before_after(results):
    t = tables.e4_before_after(load.to_sweep_frame(results))
    assert set(t.qps) == {1, 2, 4} and (t.n == 5).all()
    base = t[(t.qps == 1)]
    assert base.delta_pct.abs().max() < 1e-9 and base.p_value.isna().all()
    assert t[(t.qps == 4)].p_value.notna().all()


def test_counters_pipeline(fixtures):
    df = counters.parse_counters_csv(str(fixtures / "results" / "e1-rdma" / "counters.tray-0.csv"))
    r = counters.rates(df)
    xmit = r[r.metric == "port_xmit_data"]
    assert (xmit.rate_per_s >= 0).all() and xmit.rate_per_s.max() > 1e9
    phases = [{"name": "timed-1MiB", "t_start": 1000.0, "t_end": 1040.0}]
    j = counters.join_phases(r, phases)
    assert set(j.phase) == {"idle", "timed-1MiB"}
    s = counters.per_phase_summary(j)
    hot = s[(s.phase == "timed-1MiB") & (s.metric == "port_xmit_data")]
    assert hot.gbps.mean() == pytest.approx(16.0, rel=0.05)
    assert s[s.metric == "sm_active"].gbps.isna().all()
    assert s[s.metric == "np_cnp_sent"].rate_per_s.notna().all()


def test_charts_write_pngs(results, tmp_path):
    sw, tr = load.to_sweep_frame(results), load.to_training_frame(results)
    outs = [
        charts.size_vs_busbw(sw, str(tmp_path / "a.png")),
        charts.rails_vs_busbw(sw, str(tmp_path / "b.png")),
        charts.scaling_efficiency(tables.e3_scaling(tr), str(tmp_path / "c.png")),
        charts.before_after_box(sw, str(tmp_path / "d.png")),
        charts.small_message_latency(sw, str(tmp_path / "e.png")),
    ]
    for o in outs:
        assert os.path.getsize(o) > 1024


def test_summary_and_readme(tmp_path):
    t = {"e1_size_vs_transport": pd.DataFrame({"size": ["1MiB"], "nvlink": [40.0]})}
    text = summary.build_summary(t, {}, str(tmp_path / "SUMMARY.md"))
    assert "E1 — all-reduce" in text and "1MiB" in text and "_no data yet_" in text
    readme = tmp_path / "README.md"
    readme.write_text("# x\n\nintro\n")
    summary.update_readme("BLOCK1", str(readme))
    summary.update_readme("BLOCK2", str(readme))
    s = readme.read_text()
    assert (
        s.count(summary.START) == 1 and "BLOCK2" in s and "BLOCK1" not in s and s.startswith("# x\n\nintro")
    )


def test_cli_end_to_end(fixtures, tmp_path):
    rc = analysis_main(
        [str(fixtures / "results"), "--out", str(tmp_path), "--readme", str(tmp_path / "none.md")]
    )
    assert rc == 0
    assert (tmp_path / "SUMMARY.md").exists() and (tmp_path / "index.csv").exists()
    assert (tmp_path / "charts" / "size_vs_busbw.png").exists() and (
        tmp_path / "charts" / "counters_e1-rdma.png"
    ).exists()
    assert (tmp_path / "tables" / "e4_before_after.csv").exists()
