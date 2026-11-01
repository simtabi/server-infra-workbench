"""Command line: `python -m server_infra_workbench ping|plans|configure|profile ...` (or `bin/siwo py ...`)."""

from __future__ import annotations

import argparse
import json
import sys

from server_infra_workbench import __version__, compat, envfile
from server_infra_workbench.probe import tcp_probe


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="siwo py", description="server-infra-workbench Python helpers")
    p.add_argument("--version", action="version", version=__version__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser(
        "plans", help="droplet plans per region available through Ploi (see: plans --help)", add_help=False
    )
    ping = sub.add_parser("ping", help="TCP check of a host:port, or DB_HOST/DB_PORT from an env file")
    ping.add_argument("host", nargs="?")
    ping.add_argument("port", nargs="?")
    ping.add_argument("--env", help="KEY=VALUE file with DB_HOST and DB_PORT (e.g. a web .env)")
    ping.add_argument("--timeout", type=float, default=3.0)
    ping.add_argument("--json", action="store_true", help="machine-readable output")
    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    for note in compat.notices():
        print(note, file=sys.stderr)
    if argv[:1] == ["plans"]:
        from server_infra_workbench import plan_finder

        return plan_finder.main(argv[1:])
    if argv[:1] in (["configure"], ["profile"]):
        from server_infra_workbench import configure

        return configure.main(argv)
    args = _parser().parse_args(argv)
    host, port = args.host, args.port
    if args.env:
        values = envfile.load(args.env)
        host = host or values.get("DB_HOST")
        port = port or values.get("DB_PORT")
    if not host or not port:
        print("ping: need HOST PORT or --env FILE with DB_HOST and DB_PORT", file=sys.stderr)
        return 2
    if not 0 < args.timeout <= 60:
        print("ping: --timeout must be between 0 and 60 seconds", file=sys.stderr)
        return 2
    try:
        result = tcp_probe(host, port, args.timeout)
    except ValueError as exc:
        print(f"ping: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(result.to_dict()))
    else:
        state = "open" if result.open else f"closed ({result.error})"
        print(f"{result.host}:{result.port} {state} in {result.millis} ms")
    return 0 if result.open else 1
