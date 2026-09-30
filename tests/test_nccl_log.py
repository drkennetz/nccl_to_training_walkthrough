from bench.common.nccl_log import classify_path, merge_counts, parse_nccl_log


def test_mnnvl_log(fixtures):
    c = parse_nccl_log(str(fixtures / "nccl_logs" / "mnnvl.log"))
    assert c.mnnvl_channels == 3 and c.net_socket_channels == 0 and c.net_ib_channels == 0
    assert c.p2p_channels == 5 and c.mnnvl == "1" and c.nccl_version == "2.27.5+cuda13.0"
    assert c.network == "Socket"  # the bootstrap/OOB network, not the data path
    assert classify_path(c) == "nvlink"
    assert c.ranks_reporting == 1 and c.sample


def test_ib_gdr_log(fixtures):
    c = parse_nccl_log(str(fixtures / "nccl_logs" / "ib_gdr.log"))
    assert c.net_ib_channels == 3 and c.net_ib_gdr_channels == 3 and c.net_socket_channels == 0
    assert c.hcas == ["rdma_vf_rail0", "rdma_vf_rail1", "rdma_vf_rail2", "rdma_vf_rail3"]
    assert c.network == "IB" and c.mnnvl == "0"
    assert classify_path(c) == "rdma_gdr"


def test_ib_without_gdr_is_rdma(fixtures):
    c = parse_nccl_log(str(fixtures / "nccl_logs" / "ib_nogdr.log"))
    assert c.net_ib_channels == 2 and c.net_ib_gdr_channels == 1
    assert classify_path(c) == "rdma"


def test_socket_log(fixtures):
    c = parse_nccl_log(str(fixtures / "nccl_logs" / "socket.log"))
    assert c.net_socket_channels == 2 and classify_path(c) == "tcp"


def test_missing_file_is_unknown(tmp_path):
    c = parse_nccl_log(str(tmp_path / "nope.log"))
    assert c.ranks_reporting == 0 and classify_path(c) == "unknown"


def test_merge_sums_and_keeps_first_network(fixtures):
    a = parse_nccl_log(str(fixtures / "nccl_logs" / "ib_gdr.log"))
    b = parse_nccl_log(str(fixtures / "nccl_logs" / "ib_nogdr.log"))
    m = merge_counts([a, b])
    assert m.net_ib_channels == 5 and m.ranks_reporting == 2 and m.network == "IB"
    assert m.hcas[0] == "rdma_vf_rail0" and len(m.hcas) == 4
    assert classify_path(m) == "rdma"  # one non-GDR channel demotes the whole run
