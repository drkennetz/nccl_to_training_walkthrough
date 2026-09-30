import pytest

from bench import gid


def test_classify_gid():
    assert gid.classify_gid("fe80:0000:0000:0000:00f1:b2ff:fe95:d2ec") == "link-local"
    assert gid.classify_gid("fdcd:8300:a1af:70ed:00f1:b2ff:fe95:d2ec") == "global"
    assert gid.classify_gid("0000:0000:0000:0000:0000:ffff:0a00:0001") == "ipv4-mapped"
    assert gid.classify_gid("0000:0000:0000:0000:0000:0000:0000:0000") == "zero"
    assert gid.classify_gid("garbage") == "other"


def test_plain_vf_picks_index_3(sysfs_ib):
    table = gid.read_gid_table("rdma_vf_rail0", root=str(sysfs_ib))
    assert [e.index for e in table] == [0, 1, 2, 3]  # the zero entry is skipped
    assert gid.pick_index(table).index == 3


def test_ipvlan_child_address_picks_index_7(sysfs_ib):
    table = gid.read_gid_table("rdma_vf_rail1", root=str(sysfs_ib))
    assert gid.pick_index(table).index == 7  # newest global v2 entry wins without hints
    assert gid.pick_index(table, want_ndev="net1").index == 7
    assert gid.pick_index(table, want_ndev="rdma_vf_rail1").index == 3
    assert gid.pick_index(table, want_addr="fdcd:8300:a2af:70ed:5:9dff:fe23:eae1").index == 7


def test_pick_index_rejects_table_without_global_v2():
    table = [
        gid.GidEntry(0, "fe80::1", "RoCE v2", "x", "link-local"),
        gid.GidEntry(1, "fdcd::1", "IB/RoCE v1", "x", "global"),
    ]
    with pytest.raises(LookupError):
        gid.pick_index(table)


def test_discover_reports_inconsistency_across_hcas(sysfs_ib):
    r = gid.discover(["rdma_vf_rail0", "rdma_vf_rail1"], root=str(sysfs_ib))
    assert r["chosen"] == {"rdma_vf_rail0": 3, "rdma_vf_rail1": 7}
    assert r["consistent"] is False and r["index"] is None
    r2 = gid.discover(["rdma_vf_rail0", "rdma_vf_rail1"], root=str(sysfs_ib), want_ndev="rdma_vf_rail")
    assert r2["consistent"] is False  # no exact ndev match -> falls back to newest, still 3 vs 7
    r3 = gid.discover(["rdma_vf_rail0"], root=str(sysfs_ib))
    assert r3["consistent"] and r3["index"] == 3


def test_cli_export(sysfs_ib, capsys):
    rc = gid.main(["--root", str(sysfs_ib), "--hca", "rdma_vf_rail0", "--export"])
    assert rc == 0 and capsys.readouterr().out.strip() == "export NCCL_IB_GID_INDEX=3"
    rc = gid.main(["--root", str(sysfs_ib), "--hca", "rdma_vf_rail0", "--hca", "rdma_vf_rail1", "--export"])
    assert rc == 1
    rc = gid.main(["--root", str(sysfs_ib), "--hca", "rdma_vf_rail1"])
    out = capsys.readouterr().out
    assert rc == 0 and "<-- chosen" in out and "NCCL_IB_GID_INDEX=7" in out
    assert gid.main(["--root", str(sysfs_ib / "empty")]) == 2
