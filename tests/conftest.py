import pathlib

import pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


@pytest.fixture(scope="session")
def fixtures() -> pathlib.Path:
    return FIXTURES


@pytest.fixture
def sysfs_ib(tmp_path):
    """A fake /sys/class/infiniband with two rail VFs; rail1 carries an extra (ipvlan) address."""
    root = tmp_path / "infiniband"

    def dev(name, entries):
        base = root / name / "ports" / "1"
        (base / "gids").mkdir(parents=True)
        (base / "gid_attrs" / "types").mkdir(parents=True)
        (base / "gid_attrs" / "ndevs").mkdir(parents=True)
        (base / "counters").mkdir()
        (base / "hw_counters").mkdir()
        (base / "state").write_text("4: ACTIVE\n")
        for i, (gid, typ, ndev) in enumerate(entries):
            (base / "gids" / str(i)).write_text(gid + "\n")
            (base / "gid_attrs" / "types" / str(i)).write_text(typ + "\n")
            (base / "gid_attrs" / "ndevs" / str(i)).write_text(ndev + "\n")
        (base / "counters" / "port_xmit_data").write_text("1000\n")
        (base / "counters" / "port_rcv_data").write_text("2000\n")
        (base / "counters" / "port_xmit_wait").write_text("7\n")
        (base / "hw_counters" / "out_of_sequence").write_text("3\n")
        (base / "hw_counters" / "np_cnp_sent").write_text("0\n")
        (root / name / "device" / "net" / name).mkdir(parents=True)

    zero = "0000:0000:0000:0000:0000:0000:0000:0000"
    dev(
        "rdma_vf_rail0",
        [
            ("fe80:0000:0000:0000:00f1:b2ff:fe95:d2ec", "IB/RoCE v1", "rdma_vf_rail0"),
            ("fe80:0000:0000:0000:00f1:b2ff:fe95:d2ec", "RoCE v2", "rdma_vf_rail0"),
            ("fdcd:8300:a1af:70ed:00f1:b2ff:fe95:d2ec", "IB/RoCE v1", "rdma_vf_rail0"),
            ("fdcd:8300:a1af:70ed:00f1:b2ff:fe95:d2ec", "RoCE v2", "rdma_vf_rail0"),
            (zero, "", ""),
        ],
    )
    dev(
        "rdma_vf_rail1",
        [
            ("fe80:0000:0000:0000:0005:9dff:fe23:eae0", "IB/RoCE v1", "rdma_vf_rail1"),
            ("fe80:0000:0000:0000:0005:9dff:fe23:eae0", "RoCE v2", "rdma_vf_rail1"),
            ("fdcd:8300:a2af:70ed:0005:9dff:fe23:eae0", "IB/RoCE v1", "rdma_vf_rail1"),
            ("fdcd:8300:a2af:70ed:0005:9dff:fe23:eae0", "RoCE v2", "rdma_vf_rail1"),
            ("fe80:0000:0000:0000:0005:9dff:fe23:eae1", "IB/RoCE v1", "net1"),
            ("fe80:0000:0000:0000:0005:9dff:fe23:eae1", "RoCE v2", "net1"),
            ("fdcd:8300:a2af:70ed:0005:9dff:fe23:eae1", "IB/RoCE v1", "net1"),
            ("fdcd:8300:a2af:70ed:0005:9dff:fe23:eae1", "RoCE v2", "net1"),
        ],
    )
    return root
