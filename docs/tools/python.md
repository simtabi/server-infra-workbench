# Python package (`src/python`)

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

Without the dispatcher: `PYTHONPATH=src/python/src python3 -m vps_server_workbench ping ...`, or
`pip install -e src/python` and then `workbench-py ping ...`.

`ping` only opens a TCP connection; it sends no credentials and reads nothing from the database. For a
full check from a web server (DNS, firewall, the real client), use
[`src/shell/web/check-db-reach.sh`](../../src/shell/web/check-db-reach.sh).

## Layout

| Path | What |
|---|---|
| `src/python/src/vps_server_workbench/cli.py` | argparse entry point (`ping`, `plans`) |
| `src/python/src/vps_server_workbench/probe.py` | `tcp_probe(host, port, timeout)` returning a small result object |
| `src/python/src/vps_server_workbench/envfile.py` | strict `KEY=VALUE` reader (quotes, comments; never `source`s or executes) |
| `src/python/src/vps_server_workbench/plan_finder.py` | `PloiDoPlanFinder` (fluent library) and the `plans` command |
| `src/python/tests/` | `unittest` tests, offline (a local listening socket stands in for a server) |

## Checks

```bash
make py-lint    # py_compile on src/python and tests/docs; ruff check + format --check when ruff is installed
make py-test    # PYTHONPATH=src/python/src python3 -m unittest discover -s src/python/tests
```

Both skip with a note when Python 3.12+ is missing, so `make ci` still runs everywhere. Ruff settings
are in `src/python/pyproject.toml`.

## Adding a command

1. Put the logic in a new module under `src/vps_server_workbench/` with no I/O at import time.
2. Add a subparser in `cli.py`; validate input there and return exit code 2 on bad input.
3. Add `tests/test_<module>.py`. Tests must not touch the network or a real server.
4. Document it on this page.

If the command needs a platform API, add it to the PHP core instead and call `bin/workbench do|cf|ploi|gcp`.

## `plans`: droplet plans per region through Ploi

Lists which DigitalOcean droplet plans you can create in each region **through Ploi**: Ploi reports the
plans and regions for your DO credentials, DigitalOcean's `/v2/sizes` reports where each size runs, and only
pairs both agree on are shown. Read-only (two GETs per API).

```bash
mkdir -p ~/.config/vps-server-workbench
cp config/ploi-do-plan-finder.env.example ~/.config/vps-server-workbench/plans.env
chmod 600 ~/.config/vps-server-workbench/plans.env     # add PLOI_API_TOKEN and DO_API_TOKEN
bin/workbench plans --env-file ~/.config/vps-server-workbench/plans.env \
  --regions atl1,nyc3 --min-memory-mb 2048 --output-format markdown
bin/workbench plans --plan-filter s- --max-price 24 --sort-by memory --output-format json
```

Every setting comes from a flag, then an environment variable, then the `--env-file` (default `.env` in
the current directory); flags win. Filters: `--regions`, `--exclude-regions`, `--plan-filter`,
`--min/max-vcpus`, `--min/max-memory-mb`, `--max-price`; output: `--sort-by price|memory|vcpus|plan`,
`--output-format table|markdown|csv|json`, `--output-file`. Exit 1 with a clear message when a token is
missing. `bin/workbench plans --help` lists everything; library use is in the module docstring.
Never keep the env file inside the repository.
