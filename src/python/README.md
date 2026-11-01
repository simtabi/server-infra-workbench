# src/python — server-infra-workbench (Python)

A deliberately small package: standard library only, `src/` layout, `unittest` tests. It exists so Python
automation has a home with lint and tests already wired; platform APIs (DigitalOcean, Ploi, Cloudflare,
GCP) live in the [PHP core](../php) and are not duplicated here.

```bash
bin/workbench py ping --env config/web-db.env.example     # reads DB_HOST / DB_PORT
bin/workbench py ping 10.0.0.5 6432 --timeout 2 --json
make py-test                                              # unittest, offline
```

Reference: [docs/tools/python.md](../../docs/tools/python.md).
