from bench import watcher


def test_ib_counters_from_fake_sysfs(sysfs_ib):
    c = watcher.ib_counters("rdma_vf_rail0", root=str(sysfs_ib))
    assert c["port_xmit_data"] == 4000 and c["port_rcv_data"] == 8000  # 4-byte lanes -> bytes
    assert c["port_xmit_wait"] == 7 and c["out_of_sequence"] == 3 and c["np_cnp_sent"] == 0


def test_parse_ethtool_stats_keeps_selected_keys():
    text = "NIC statistics:\n     rx_packets: 10\n     rx_out_of_buffer: 5\n     rx_prio3_pause: 12\n     tx_prio3_pause: 0\n     rx_discards_phy: 1\n     bogus: x\n"
    s = watcher.parse_ethtool_stats(text)
    assert s == {"rx_out_of_buffer": 5, "rx_prio3_pause": 12, "tx_prio3_pause": 0, "rx_discards_phy": 1}


def test_parse_dcgm_exposition():
    text = """# HELP DCGM_FI_PROF_NVLINK_TX_BYTES x
DCGM_FI_PROF_NVLINK_TX_BYTES{gpu="0",UUID="GPU-1",device="nvidia0",Hostname="h"} 1.2e+09
DCGM_FI_PROF_NVLINK_RX_BYTES{gpu="0",UUID="GPU-1",device="nvidia0"} 3
DCGM_FI_DEV_POWER_USAGE{gpu="1",UUID="GPU-2",device="nvidia1"} 512.5
DCGM_FI_DEV_GPU_TEMP{gpu="1"} 40
DCGM_FI_PROF_SM_ACTIVE{gpu="1"} NaN
"""
    rows = watcher.parse_dcgm_exposition(text)
    assert ("gpu0", "nvlink_tx_bytes", 1.2e9) in rows and ("gpu1", "power_w", 512.5) in rows
    assert not any(m == "gpu_temp" for _, m, _ in rows)
    assert any(m == "sm_active" for _, m, _ in rows)  # NaN parses as float nan


def test_sample_once_rows(sysfs_ib):
    cfg = watcher.WatcherConfig("node1", ["rdma_vf_rail0"], [], "", str(sysfs_ib))
    rows = watcher.sample_once(cfg, ts="2026-09-30T00:00:00Z")
    metrics = {(r.source, r.metric) for r in rows}
    assert ("ib_counter", "port_xmit_data") in metrics and ("ib_hw_counter", "out_of_sequence") in metrics
    assert rows[0].csv().startswith("2026-09-30T00:00:00Z,node1,ib_counter,rdma_vf_rail0,")
