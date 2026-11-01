# Example: DNS and proxy through Cloudflare

Made up: zone `example.com` in Cloudflare, Ploi web droplet `web-01` (public `203.0.113.10`, private `10.0.0.6`),
DB droplet `db-01` (private `10.0.0.5`) with no public DNS name at all. Profile
[`dev-budget`](../../config/profiles/dev-budget.conf).

**Why:**

- **Proxy the web names only.** Cloudflare's proxy speaks HTTP(S). An orange-cloud SSH or mail name stops
  working, and an orange-cloud DB name is worse: it publishes the DB's name and points at an address that
  must never be public. [`cf-dns.sh`](cf-dns.sh) refuses proxied non-HTTP names, any `db-*` name, and any
  private address, so the mistake fails in review, not in production.
- **Records in a file, applied by upsert.** [`records.txt`](records.txt) is the zone's intent, versioned
  with the repo. `bin/workbench cf dns upsert` is a no-op for an unchanged record, so re-running is safe. The
  default run only prints, `--check` previews against the zone, and `--yes` writes.
- **SSL mode Full (strict).** Cloudflare to origin is HTTPS with a *valid* certificate (Ploi's Let's Encrypt
  one). "Flexible" sends your users' traffic to the origin in clear text, and makes Laravel think every
  request is HTTP (redirect loops).
- **Lock the origin to Cloudflare.** Proxied records hide the IP until someone finds it (an old DNS record, a
  mail header, a scan). Authenticated Origin Pulls ([`nginx-cloudflare.conf`](nginx-cloudflare.conf)) make
  Nginx reject any TLS client that isn't Cloudflare. That check has no IP list to maintain.
- **The real client IP from `CF-Connecting-IP`, trusted only from Cloudflare's ranges.** `cf-dns.sh realip`
  generates the snippet from the published lists. A header trusted from anywhere would let anyone pick their
  IP.

```bash
examples/run.sh cloudflare-dns-proxy      # validate (offline): profile checks, plans, cf-dns.sh self-test
bin/workbench cf verify                   # the token works (scoped: Zone.DNS edit on this zone only)
bin/workbench cf zones
examples/cloudflare-dns-proxy/cf-dns.sh                      # print the upserts (offline)
examples/cloudflare-dns-proxy/cf-dns.sh --check              # each one with --dry-run against the zone
examples/cloudflare-dns-proxy/cf-dns.sh --yes                # write
bin/workbench cf dns list example.com --type A
# on web-01: the real-IP snippet, then the origin lock (nginx-cloudflare.conf), then test and reload
examples/cloudflare-dns-proxy/cf-dns.sh realip > /tmp/cloudflare-realip.conf
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh cloudflare-dns-proxy`: settings through `configure --dry-run`, plans, the self-test |
| [`records.txt`](records.txt) | the records: zone, type, name, content, `proxied`/`dns`, comment |
| [`cf-dns.sh`](cf-dns.sh) | checks the rules, then prints / previews / applies the upserts; `realip` makes the Nginx snippet |
| [`nginx-cloudflare.conf`](nginx-cloudflare.conf) | real client IP + Authenticated Origin Pulls in the Ploi site |

Checklist:

- [ ] SSL/TLS mode **Full (strict)**; "Always Use HTTPS" on; HSTS only after everything works over HTTPS
- [ ] `curl -sk --resolve app.example.com:443:203.0.113.10 https://app.example.com/` is refused (origin lock)
- [ ] the access log shows visitor IPs, not `172.64.x.x` / `104.x.x.x`
- [ ] the API token is scoped to `Zone.DNS:Edit` on `example.com` only, and it lives in the workbench credentials
      file (chmod 600), not in a shell profile

Lesson: issue the first certificate while the record is still DNS-only. With the proxy, Full (strict) and
"Always Use HTTPS" already on, Let's Encrypt's HTTP challenge is redirected to an origin that has no
certificate yet. You get a 526 and no certificate. Proxy after Ploi shows the certificate as active.
