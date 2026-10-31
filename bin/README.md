# bin/

`workbench` is the one entry point for everything in this repository. It only resolves paths and execs
the real tool, so every tool keeps its own flags.

```bash
bin/workbench list                         # every tool and where it lives
bin/workbench db remote-run --help         # shell tools: bin/workbench <area> <tool>  -> src/shell/<area>/<tool>.sh
bin/workbench do droplets                  # platform APIs (PHP core in src/php)
bin/workbench plans --regions nyc3         # Python helpers (src/python)
```

Reference: [docs/tools/cli.md](../docs/tools/cli.md).
