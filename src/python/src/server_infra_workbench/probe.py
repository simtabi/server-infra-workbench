"""TCP reachability probe: no credentials, no protocol, just "does the port accept a connection"."""

from __future__ import annotations

import socket
import time
from dataclasses import asdict, dataclass

_HOST_OK = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")


@dataclass(frozen=True)
class ProbeResult:
    host: str
    port: int
    open: bool
    millis: float
    error: str | None = None

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def validate(host: str, port: int | str) -> tuple[str, int]:
    """Return (host, port) or raise ValueError on anything that is not a plain host and a 1-65535 port."""
    if not host or len(host) > 253 or not set(host) <= _HOST_OK:
        raise ValueError(f"invalid host: {host!r}")
    try:
        p = int(port)
    except (TypeError, ValueError):
        raise ValueError(f"invalid port: {port!r}") from None
    if not 1 <= p <= 65535:
        raise ValueError(f"port out of range: {p}")
    return host, p


def tcp_probe(host: str, port: int, timeout: float = 3.0) -> ProbeResult:
    host, port = validate(host, port)
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            ok, err = True, None
    except OSError as exc:
        ok, err = False, exc.__class__.__name__
    return ProbeResult(host, port, ok, round((time.monotonic() - start) * 1000, 1), err)
