import importlib.util
import os
import pathlib
import sys

import pytest
import yaml

HERE = pathlib.Path(__file__).resolve().parent.parent / "deploy" / "k8s"
spec = importlib.util.spec_from_file_location("render", HERE / "render.py")
render = importlib.util.module_from_spec(spec)
sys.modules["render"] = render  # dataclasses need the module registered before exec
spec.loader.exec_module(render)


@pytest.fixture(scope="module")
def matrix():
    return render.load_matrix()


@pytest.fixture(scope="module")
def cells(matrix):
    return {c.run_id: c for c in render.expand_matrix(matrix)}


def test_cell_counts(cells):
    by_exp = {}
    for c in cells.values():
        by_exp[c.experiment] = by_exp.get(c.experiment, 0) + 1
    assert (
        by_exp["E1"] == 6
        and by_exp["E2"] == 3
        and by_exp["E3"] == 5
        and by_exp["E4"] == 15
        and by_exp["E5"] == 7
    )


def _docs(cells, matrix, run_id):
    return list(yaml.safe_load_all(render.render_cell(cells[run_id], matrix["defaults"])))


def _job(docs):
    return next(d for d in docs if d["kind"] == "Job")


def test_no_cell_uses_host_network(cells, matrix):
    for run_id in cells:
        job = _job(_docs(cells, matrix, run_id))
        assert "hostNetwork" not in job["spec"]["template"]["spec"], run_id


def test_nvlink_cell_shape(cells, matrix):
    docs = _docs(cells, matrix, "e1-nvlink")
    kinds = [d["kind"] for d in docs]
    assert kinds == ["ResourceClaimTemplate", "Service", "Job"]
    job = _job(docs)
    tmpl = job["spec"]["template"]
    assert tmpl["metadata"]["annotations"]["cdi.k8s.io/imex"] == "nvidia.com/imex-channel=all"
    assert tmpl["spec"]["runtimeClassName"] == "nvidia"
    assert (
        job["spec"]["completionMode"] == "Indexed"
        and job["spec"]["completions"] == 2 == job["spec"]["parallelism"]
    )
    env = {e["name"]: e.get("value") for e in tmpl["spec"]["containers"][0]["env"]}
    assert env["MASTER_ADDR"] == "compass-e1-nvlink-0.compass-e1-nvlink" and env["NCCL_MNNVL_ENABLE"] == "1"
    assert not any("rails" in rc["name"] for rc in tmpl["spec"]["resourceClaims"])
    shm = next(v for v in tmpl["spec"]["volumes"] if v["name"] == "shm")
    assert shm["emptyDir"]["sizeLimit"] == "32Gi"


def test_rdma_cell_shape(cells, matrix):
    docs = _docs(cells, matrix, "e2-rails2")
    nic = next(
        d for d in docs if d["kind"] == "ResourceClaimTemplate" and d["metadata"]["name"].endswith("-rails")
    )
    req = nic["spec"]["spec"]["devices"]["requests"][0]["exactly"]
    assert req["deviceClassName"] == "dra.net" and req["count"] == 2
    cfg = nic["spec"]["spec"]["devices"]["config"][0]["opaque"]
    assert cfg["driver"] == "dra.net" and cfg["parameters"]["interface"]["type"] == "IPVLAN"
    job = _job(docs)
    tmpl = job["spec"]["template"]
    assert "annotations" not in tmpl["metadata"]  # no IMEX on the RDMA path
    env = {e["name"]: e.get("value") for e in tmpl["spec"]["containers"][0]["env"]}
    assert env["NCCL_MNNVL_ENABLE"] == "0" and env["EXPECT_HCAS"] == "2" and "NCCL_IB_GID_INDEX" not in env
    assert "NCCL_P2P_NET_CHUNKSIZE" not in env
    caps = tmpl["spec"]["containers"][0]["securityContext"]["capabilities"]["add"]
    assert "IPC_LOCK" in caps
    assert "bench gid --export" in tmpl["spec"]["containers"][0]["args"][0]


def test_single_node_training_cells_have_no_anti_affinity_and_right_gpu_count(cells, matrix):
    docs = _docs(cells, matrix, "e3-g2")
    gpu = next(d for d in docs if d["kind"] == "ResourceClaimTemplate")
    assert gpu["spec"]["spec"]["devices"]["requests"][0]["exactly"]["count"] == 2
    job = _job(docs)
    assert "affinity" not in job["spec"]["template"]["spec"] and job["spec"]["completions"] == 1
    env = {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["NPROC_PER_NODE"] == "2"


def test_e4_repeats_have_distinct_ids_and_qps_env(cells):
    ids = [c for c in cells if c.startswith("e4-qps2")]
    assert ids == [f"e4-qps2-r{i}" for i in range(5)]
    assert cells["e4-qps2-r3"].repeat == 3 and cells["e4-qps2-r3"].env["NCCL_IB_QPS_PER_CONNECTION"] == "2"
    assert cells["e4-qps1-r0"].env.get("NCCL_IB_SPLIT_DATA_ON_QPS") is None


def test_every_rendered_doc_is_well_formed(cells, matrix):
    for run_id in cells:
        for d in _docs(cells, matrix, run_id):
            assert d["apiVersion"] and d["kind"] and d["metadata"]["name"], run_id
            assert d["metadata"]["namespace"] == matrix["defaults"]["namespace"]


def test_committed_rendered_is_current():
    assert render.check() == [], "run: python deploy/k8s/render.py"


def test_duplicate_ids_rejected(matrix):
    m = yaml.safe_load(yaml.safe_dump(matrix))
    m["experiments"].append(dict(m["experiments"][0]))
    with pytest.raises(ValueError):
        render.expand_matrix(m)


def test_watcher_manifest(matrix):
    pod = yaml.safe_load(render.render_watcher(matrix["defaults"], "gpu-3uwoq-6g3ya-1", "172.16.56.42"))
    assert pod["spec"]["nodeName"] == "gpu-3uwoq-6g3ya-1" and "hostNetwork" not in pod["spec"]
    assert "--dcgm-url" in pod["spec"]["containers"][0]["args"]
    assert os.path.basename(pod["spec"]["volumes"][0]["hostPath"]["path"]) == "sys"
