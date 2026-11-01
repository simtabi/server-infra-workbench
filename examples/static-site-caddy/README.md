# Example: a static site with Caddy

Made up: `www.example.com` (and `example.com`) on a Docker web droplet `web-01` (`10.0.0.6`). The DB droplet of
profile [`dev-budget`](../../config/profiles/dev-budget.conf) is there for the apps next to it; the site itself
uses no database.

**Why:**

- **Caddy, not Nginx + Ploi, for files only.** A static site needs TLS and a file server, nothing else. Caddy
  gets and renews the certificate on its own (ACME), redirects HTTP to HTTPS, and serves HTTP/3, all from a
  20-line [`Caddyfile`](conf/Caddyfile). There's no PHP-FPM to patch and no app process to restart.
- **The repo's [Caddy stack](../../stacks/caddy), unchanged.** [`compose.static.yml`](compose.static.yml) is an
  overlay that only swaps the config folder and mounts the site. `up --no-deps caddy` starts just Caddy, not
  the stack's PHP, queue and scheduler services. Updating the stack (image pins, volumes) reaches this site
  too.
- **The site is mounted read-only.** Caddy can't write to it. A deploy is an `rsync` into `SITE_PATH`, with
  no restart. Caddy reads the files on each request.
- **Cache by file name.** Fingerprinted assets are cached for a year (`immutable`). HTML always revalidates,
  so a deploy is visible on the next load.
- **Keep the `caddy_data` volume.** It holds the certificates and the ACME account. Losing it means
  re-issuing, and Let's Encrypt rate limits (5 duplicate certificates a week) can take the site down for days.

```bash
examples/run.sh static-site-caddy      # validate (offline): profile checks, secrets scan
# validate the config with the pinned image, before any DNS exists (no ports, no certificates):
docker run --rm -e SITE_DOMAIN=www.example.com -v "$PWD/examples/static-site-caddy/conf:/etc/caddy:ro" \
  caddy:2.11 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# on web-01 (the repo checked out, DNS for both names pointing here, 80 + 443 open)
cp examples/static-site-caddy/stack.env.example stacks/caddy/.env      # then edit SITE_DOMAIN, SITE_PATH
cd stacks/caddy && docker compose -f docker-compose.yml -f ../../examples/static-site-caddy/compose.static.yml config -q \
  && docker compose -f docker-compose.yml -f ../../examples/static-site-caddy/compose.static.yml up -d --no-deps caddy
# after a Caddyfile edit: reload without dropping connections
docker compose exec -w /etc/caddy caddy caddy reload
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh static-site-caddy`: settings through `configure --dry-run` |
| [`conf/Caddyfile`](conf/Caddyfile) | file server, headers, cache rules, clean URLs, a 404 page |
| [`compose.static.yml`](compose.static.yml) | overlay on `stacks/caddy/docker-compose.yml`: this config + the site, read-only |
| [`stack.env.example`](stack.env.example) | `stacks/caddy/.env` for a static site |

Checklist:

- [ ] DNS A/AAAA for every name in `SITE_DOMAIN` points at `web-01` *before* the first `up` (ACME needs it)
- [ ] the DO firewall allows 80/tcp, 443/tcp and 443/udp (HTTP/3)
- [ ] test with `ACME_CA` = Let's Encrypt staging first, then switch and `docker compose up -d --no-deps caddy`
- [ ] `curl -I https://www.example.com/` shows `strict-transport-security` and no `server` header

Lesson: an empty or wrong `SITE_PATH` serves an empty site with a valid certificate, which looks like it works.
Check that `curl -fsS https://www.example.com/ | head` shows your HTML, not just a 200.
