"""Human-readable byte sizes and the message-size sweep."""

from __future__ import annotations

import re

_UNITS = {
    "": 1,
    "b": 1,
    "k": 1 << 10,
    "ki": 1 << 10,
    "kib": 1 << 10,
    "m": 1 << 20,
    "mi": 1 << 20,
    "mib": 1 << 20,
    "g": 1 << 30,
    "gi": 1 << 30,
    "gib": 1 << 30,
}
_RE = re.compile(r"^\s*(\d+)\s*([kmg]?i?b?)\s*$", re.IGNORECASE)


def parse_size(s: str | int) -> int:
    """'1Mi', '1MiB', '512M', '8Gi' or a bare integer -> bytes (power-of-two units)."""
    if isinstance(s, int):
        return s
    m = _RE.match(s)
    if not m:
        raise ValueError(f"unparseable size {s!r}; use e.g. 1Mi, 512MiB, 8Gi or bytes")
    n, unit = int(m.group(1)), m.group(2).lower()
    if unit and unit not in _UNITS:
        raise ValueError(f"unknown unit in {s!r}")
    return n * _UNITS.get(unit, 1)


def format_size(n: int) -> str:
    """Bytes -> the shortest exact power-of-two form ('1MiB', '8GiB', '4KiB', '12345B')."""
    for unit, mult in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= mult and n % mult == 0:
            return f"{n // mult}{unit}"
    return f"{n}B"


def sweep(lo: int, hi: int, factor: int = 2) -> list[int]:
    """Geometric sweep lo, lo*factor, ... <= hi (inclusive when it lands exactly)."""
    if lo <= 0 or hi < lo or factor < 2:
        raise ValueError("sweep needs 0 < lo <= hi and factor >= 2")
    out, n = [], lo
    while n <= hi:
        out.append(n)
        n *= factor
    return out


def parse_sizes(spec: str) -> list[int]:
    """'1Mi:8Gi' -> geometric sweep; '16Mi,512Mi,4Gi' -> explicit list; '512Mi' -> [512Mi]."""
    if ":" in spec:
        lo, hi = spec.split(":", 1)
        return sweep(parse_size(lo), parse_size(hi))
    return [parse_size(p) for p in spec.split(",") if p.strip()]
