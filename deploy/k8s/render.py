#!/usr/bin/env python3
"""matrix.yaml -> deploy/k8s/rendered/<run_id>/manifests.yaml (+ watcher pods).

render.py                # write rendered/ (and delete cells that no longer exist)
render.py --check        # exit 1 if rendered/ differs from what matrix.yaml produces
render.py --list         # print the run cells
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from dataclasses import asdict, dataclass, field

import jinja2
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
MATRIX = os.path.join(HERE, "matrix.yaml")
RENDERED = os.path.join(HERE, "rendered")
FRAGMENTS = os.path.join(HERE, "fragments")


@dataclass
class RunCell:
    run_id: str
    experiment: str
    entrypoint: str
    transport: str
    nnodes: int
    nproc: int
    gpus: int
    rails: int
    imex: bool
    repeat: int
    env: dict = field(default_factory=dict)
    args: list = field(default_factory=list)
    label: str = ""

    @property
    def job_name(self) -> str:
        return f"compass-{self.run_id}"

    @property
    def mem_limit_gi(self) -> int:
        # host-side NCCL state grows with the world size and /dev/shm counts against the limit
        return max(64, 8 * self.nnodes * self.nproc)

    @property
    def variant_json(self) -> str:
        return json.dumps(
            {"transport": self.transport, "rails": self.rails, "label": self.label}, sort_keys=True
        )

    def to_dict(self) -> dict:
        d = asdict(self)
        d.update(job_name=self.job_name, mem_limit_gi=self.mem_limit_gi, variant_json=self.variant_json)
        return d


def load_matrix(path: str = MATRIX) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def expand_matrix(m: dict) -> list[RunCell]:
    d, transports = m["defaults"], m["transports"]
    cells: list[RunCell] = []
    for e in m["experiments"]:
        t = transports[e["transport"]]
        nproc = int(e.get("nproc_per_node", d["nproc_per_node"]))
        rails = int(e.get("rails", t["rails"]))
        env = dict(d.get("common_env", {}))
        env.update(t.get("env", {}))
        env.update(e.get("env", {}))
        imex = bool(e.get("imex", t["imex"]))
        if not imex:
            # Without the IMEX channel NCCL refuses to start with MNNVL on ("MNNVL is available but
            # not working"); a single-tray cell rides intra-tray NVLink and never needs it.
            env["NCCL_MNNVL_ENABLE"] = "0"
        repeats = int(e.get("repeats", 1))
        for r in range(repeats):
            run_id = e["id"] if repeats == 1 else f"{e['id']}-r{r}"
            cells.append(
                RunCell(
                    run_id=run_id,
                    experiment=e["experiment"],
                    entrypoint=e["entrypoint"],
                    transport=e["transport"],
                    nnodes=int(e["nnodes"]),
                    nproc=nproc,
                    gpus=int(e.get("gpus", nproc)),
                    rails=rails,
                    imex=bool(e.get("imex", t["imex"])),
                    repeat=r,
                    env={k: str(v) for k, v in env.items()},
                    args=[str(x) for x in e.get("args", [])],
                    label=str(e.get("label", "")),
                )
            )
    ids = [c.run_id for c in cells]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise ValueError(f"duplicate run ids: {sorted(dupes)}")
    return cells


def jinja_env() -> jinja2.Environment:
    return jinja2.Environment(
        loader=jinja2.FileSystemLoader(FRAGMENTS),
        undefined=jinja2.StrictUndefined,
        trim_blocks=False,
        lstrip_blocks=False,
        keep_trailing_newline=True,
    )


def render_cell(cell: RunCell, d: dict, env: jinja2.Environment | None = None) -> str:
    env = env or jinja_env()
    ctx = {"cell": cell.to_dict(), "d": d}
    ctx["cell"]["job_name"] = cell.job_name
    docs = [env.get_template("claim-gpu.yaml.j2").render(**ctx)]
    if cell.rails > 0:
        docs.append(env.get_template("claim-nic.yaml.j2").render(**ctx))
    docs.append(env.get_template("job.yaml.j2").render(**ctx))
    return "\n---\n".join(doc.rstrip("\n") + "\n" for doc in docs)


def render_watcher(d: dict, node: str, node_ip: str, env: jinja2.Environment | None = None) -> str:
    env = env or jinja_env()
    return env.get_template("watcher.yaml.j2").render(
        d=d, node=node, node_ip=node_ip, node_short=node.split(".")[0].replace("_", "-").lower()[-40:]
    )


def render_all(matrix_path: str = MATRIX, out_dir: str = RENDERED, write: bool = True) -> dict[str, str]:
    m = load_matrix(matrix_path)
    env = jinja_env()
    out: dict[str, str] = {}
    for cell in expand_matrix(m):
        out[cell.run_id] = render_cell(cell, m["defaults"], env)
    if write:
        for stale in os.listdir(out_dir) if os.path.isdir(out_dir) else []:
            if stale not in out and os.path.isdir(os.path.join(out_dir, stale)):
                shutil.rmtree(os.path.join(out_dir, stale))
        for run_id, text in out.items():
            os.makedirs(os.path.join(out_dir, run_id), exist_ok=True)
            with open(os.path.join(out_dir, run_id, "manifests.yaml"), "w") as f:
                f.write(text)
    return out


def check(matrix_path: str = MATRIX, out_dir: str = RENDERED) -> list[str]:
    """Names of cells whose committed manifests differ (or are missing/extra)."""
    want = render_all(matrix_path, out_dir, write=False)
    bad = []
    for run_id, text in want.items():
        p = os.path.join(out_dir, run_id, "manifests.yaml")
        if not os.path.exists(p) or open(p).read() != text:
            bad.append(run_id)
    for extra in os.listdir(out_dir) if os.path.isdir(out_dir) else []:
        if extra not in want and os.path.isdir(os.path.join(out_dir, extra)):
            bad.append(extra + " (stale)")
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--matrix", default=MATRIX)
    ap.add_argument("--out", default=RENDERED)
    a = ap.parse_args(argv)
    if a.list:
        for c in expand_matrix(load_matrix(a.matrix)):
            print(
                f"{c.run_id:<22} {c.experiment} {c.entrypoint:<9} {c.transport:<8} nodes={c.nnodes} nproc={c.nproc} gpus={c.gpus} rails={c.rails} imex={int(c.imex)} {' '.join(c.args)}"
            )
        return 0
    if a.check:
        bad = check(a.matrix, a.out)
        if bad:
            print(
                "rendered/ is stale for: " + ", ".join(bad) + "\nrun: python deploy/k8s/render.py",
                file=sys.stderr,
            )
            return 1
        print("rendered/ is up to date")
        return 0
    out = render_all(a.matrix, a.out)
    print(f"rendered {len(out)} cell(s) into {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
