"""python -m bench {allreduce,ddp,watcher,sysinfo,gid} ..."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "allreduce":
        from bench.allreduce import main as m
    elif cmd == "ddp":
        from bench.ddp_train import main as m
    elif cmd == "watcher":
        from bench.watcher import main as m
    elif cmd == "sysinfo":
        from bench.sysinfo import main as m
    elif cmd == "gid":
        from bench.gid import main as m
    else:
        print(f"unknown subcommand {cmd!r}; " + __doc__, file=sys.stderr)
        return 2
    return m(rest)


if __name__ == "__main__":
    sys.exit(main())
