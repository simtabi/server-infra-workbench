# Python package (`python/`)

A deliberately small, standard-library-only package (`vps_server_workbench`, `src/` layout, Python 3.12+).
It gives Python automation a home with lint and tests already wired. **Platform APIs are not here**:
DigitalOcean, Cloudflare, Ploi and GCP live in the [PHP core](platform-api.md) so there is one client per
platform, not two.

## Run it

```bash
bin/workbench py ping 10.0.0.5 6432                          # TCP check, exit 0 open / 1 closed / 2 bad input
bin/workbench py ping --env /home/ploi/example.com/.env       # reads DB_HOST and DB_PORT from the file
bin/workbench py ping 10.0.0.5 5432 --timeout 2 --json        # {"host": ..., "port": ..., "open": ..., "millis": ...}
```

Without the dispatcher: `PYTHONPATH=python/src python3 -m vps_server_workbench ping ...`, or
`pip install -e python` and then `workbench-py ping ...`.

`ping` only opens a TCP connection; it sends no credentials and reads nothing from the database. For a
full check from a web server (DNS, firewall, the real client), use
[`shell/web/check-db-reach.sh`](../../shell/web/check-db-reach.sh).

## Layout

| Path | What |
|---|---|
| `python/src/vps_server_workbench/cli.py` | argparse entry point (`ping`) |
| `python/src/vps_server_workbench/probe.py` | `tcp_probe(host, port, timeout)` returning a small result object |
| `python/src/vps_server_workbench/envfile.py` | strict `KEY=VALUE` reader (quotes, comments; never `source`s or executes) |
| `python/tests/` | `unittest` tests, offline (a local listening socket stands in for a server) |

## Checks

```bash
make py-lint    # py_compile on python/, tools/ and tests/docs; ruff check + format --check when ruff is installed
make py-test    # PYTHONPATH=python/src python3 -m unittest discover -s python/tests
```

Both skip with a note when Python 3.12+ is missing, so `make ci` still runs everywhere. Ruff settings
are in `python/pyproject.toml`.

## Adding a command

1. Put the logic in a new module under `src/vps_server_workbench/` with no I/O at import time.
2. Add a subparser in `cli.py`; validate input there and return exit code 2 on bad input.
3. Add `tests/test_<module>.py`. Tests must not touch the network or a real server.
4. Document it on this page.

If the command needs a platform API, add it to the PHP core instead and call `bin/workbench do|cf|ploi|gcp`.

## Related

The standalone [Ploi + DigitalOcean plan finder](../../tools/ploi-do-plan-finder/README.md) predates the
package and keeps its own `.env`; it is left as is.
