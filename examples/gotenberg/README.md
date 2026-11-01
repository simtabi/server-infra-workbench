# Example: Gotenberg (HTML / Office to PDF) next to the app

Made up: Gotenberg on the web node bound to `127.0.0.1`, basic auth on, private-IP fetches denied (so a
crafted HTML page cannot make it read your VPC).

**Why on the web node:** PDF rendering is bursty and CPU-heavy; keeping it off the DB node protects the DB.
The configurator refuses a 2 GB web node for PHP + Gotenberg (~2.5 GB), so this example sets `WEB_DROPLET_MB=4096`.

```bash
examples/run.sh gotenberg                   # configure checks + `addon plan gotenberg`
bin/siwo addon install gotenberg --role web --yes                   # on the web node
bin/siwo env init --env stg --site <site> --addons                  # merges GOTENBERG_URL/USERNAME/PASSWORD
```

The basic-auth password is generated at install (`secrets.env`, 600) and merged into the app `.env`
without being printed. Add-on details: [add-ons](../../docs/tools/addons.md).
