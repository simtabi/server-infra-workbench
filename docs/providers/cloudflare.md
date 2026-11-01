# Cloudflare (`workbench cf`)

**Why:** Cloudflare fronts the sites: DNS, TLS between visitors and the edge and between the edge and the origin,
cache and a first layer of blocking. The workbench manages that through the v4 REST API
(`https://api.cloudflare.com/client/v4`) with an API token, so a rollout can point DNS, set strict TLS, install an
Origin CA certificate and purge the cache without the dashboard.

## Least-privilege token

Use an **API token** (My Profile → API Tokens → Create Token → Custom), never the Global API Key, limited to the
zones you manage (Zone Resources → Include → Specific zone). Store it as `CLOUDFLARE_API_TOKEN`.

| Commands | Permission (zone scope) |
| --- | --- |
| `verify`, `zones`, `zone` | Zone → Zone → Read |
| `dns list` / `dns upsert`, `dns delete` | Zone → DNS → Read / Edit |
| `settings list`, `ssl <zone>` / `settings set`, `ssl <zone> <mode>` | Zone → Zone Settings → Read / Edit |
| `origin-certs list/create/revoke` | Zone → SSL and Certificates → Edit (Origin CA service keys are deprecated) |
| `purge` | Zone → Cache Purge → Purge |
| `firewall rules` / `firewall add`, `firewall delete` | Zone → Firewall Services → Read / Edit |
| `firewall waf` | Zone → Zone WAF → Read |

The live read-only test needs Zone:Read, DNS:Read and Zone Settings:Read. Set a TTL on the token and, if your
workstation has a stable address, Client IP Address Filtering.

## Commands

A zone is its name or its 32-character id. All take `--json`; writes take `--dry-run` and `--yes`;
destructive ones need `--force`.

- `bin/workbench cf verify` checks the token; `bin/workbench cf zones`, `bin/workbench cf zone example.com`
- `bin/workbench cf dns list example.com --type A`
- `bin/workbench cf dns upsert example.com A app <ip> --ttl 1 --proxied --comment "app droplet"` creates, updates
  or no-ops; refuses to guess when several records match.
- `bin/workbench cf dns delete example.com <record-id> --force`
- `bin/workbench cf settings list example.com` shows ssl, always_use_https, automatic_https_rewrites,
  min_tls_version, tls_1_3 and security_level.
- `bin/workbench cf settings set example.com min_tls_version 1.2` (weakening a setting needs `--force`;
  an unchanged value is a no-op)
- `bin/workbench cf ssl example.com` shows the mode; `bin/workbench cf ssl example.com strict` sets it.
- `bin/workbench cf origin-certs list example.com`
- `bin/workbench cf origin-certs create example.com --hostnames example.com,*.example.com --validity 5475 --out ~/.config/vps-server-workbench/example.com.key`
  makes the private key and CSR locally (the key never leaves the machine), writes the key to the file (mode 600)
  and the certificate next to it as `FILE.crt`.
- `bin/workbench cf origin-certs revoke example.com <cert-id> --force`
- `bin/workbench cf purge example.com --files https://example.com/app.css` (1 to 30 URLs);
  `bin/workbench cf purge example.com --everything --force`
- `bin/workbench cf firewall rules example.com` lists IP access rules;
  `bin/workbench cf firewall add example.com block <cidr> --target ip_range --comment "scanner"`;
  `bin/workbench cf firewall delete example.com <rule-id> --force`
- `bin/workbench cf firewall waf example.com` lists the custom WAF rules (read-only; edit them in the dashboard
  or as code, where review happens).

## Checklist

- [ ] Token is scoped to specific zones with the permissions above, not the Global API Key.
- [ ] SSL mode is `strict`, and the origin has a valid or Origin CA certificate (`origin-certs create`).
- [ ] `always_use_https` on, `min_tls_version` 1.2 or higher.
- [ ] Origin firewall only accepts 80/443 from Cloudflare's ranges when the record is proxied.
- [ ] After a deploy that changes assets, purge by URL; purge everything only when you mean it.

## Lessons learned

- **Flexible SSL is unsafe**: it is plain HTTP between Cloudflare and the origin, and with an HTTPS redirect on
  the origin it loops. Use `full (strict)` with an Origin CA certificate; `off` / `flexible` need `--force`.
- **Strict needs the certificate first**, or visitors get 526 errors. Install the origin certificate, then switch.
- **Origin CA private keys are generated locally.** Sending a CSR means Cloudflare never sees the key; the key is
  written once to the `--out` file, so keep that file (mode 600) and revoke the certificate if it is lost.
- **Purge everything is an origin load test.** Every request misses the cache until it warms up again, so it is
  destructive here and needs `--force`.
- **Upsert by type and name, never by content**, so re-running a rollout changes a record in place instead of
  adding a second A record that splits traffic.
