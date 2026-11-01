# bin/

`siwo` (Server + Infrastructure + WOrkbench) is the one entry point for everything in this repository.
`bin/workbench` is its old name, kept as a deprecated shim that forwards to `siwo` with a notice
([ADR 0014](../docs/adr/0014-rename-to-server-infra-workbench.md)). It only resolves paths and execs
the real tool, so every tool keeps its own flags.

```bash
bin/siwo list                         # every tool and where it lives
bin/siwo db remote-run --help         # shell tools: bin/siwo <area> <tool>  -> src/shell/<area>/<tool>.sh
bin/siwo do droplets                  # platform APIs (PHP core in src/php)
bin/siwo plans --regions nyc3         # Python helpers (src/python)
```

Reference: [docs/tools/cli.md](../docs/tools/cli.md).
