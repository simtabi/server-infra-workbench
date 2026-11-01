# Example: two web nodes behind a load balancer

Made up: app `app.example.com` on Ploi web nodes `web-01` (`10.0.0.6`) and `web-02` (`10.0.0.7`) behind a DO
Load Balancer, prd on DO Managed Postgres with a standby, sessions/cache/queues in DO Managed Valkey, uploads in
Spaces, VPC `10.0.0.0/20`. Profile [`production-ha`](../../config/profiles/production-ha.conf) (`WEB_NODES=2`,
`LOAD_BALANCER=1`). The DB side is the [managed-postgres-prd](../managed-postgres-prd/README.md) example. This
one is the web tier.

**Why:**

- **The load balancer ends TLS.** If each node had its own Let's Encrypt certificate, every renewal would race:
  the HTTP-01 challenge lands on whichever node the LB picks, so half the renewals fail. The LB holds one
  certificate and forwards plain HTTP over the VPC. Nodes accept port 80 from the LB only (DO firewall
  source: the load balancer), and nothing else is public.
- **Nothing on a node's disk that a request needs.** Sessions, cache, locks and queues go in Managed Valkey;
  uploads in Spaces ([`app.env.example`](app.env.example)). Otherwise a user's next request can land on the
  other node and lose its session, or get a 404 for a file uploaded on the first.
- **Trust the LB, and only the LB.** `trustProxies(at: VPC_CIDR)` ([`trust-proxies.php`](trust-proxies.php))
  makes `https://` URLs, secure cookies and the client IP right. `at: '*'` would let anyone set
  `X-Forwarded-For` and pass as any IP. Nginx's `set_real_ip_from` ([`nginx-lb.conf`](nginx-lb.conf)) does
  the same for logs and rate limits.
- **One node at a time.** [`rolling-deploy.sh`](rolling-deploy.sh) deploys `web-01`, waits until it serves the
  new commit on `/version`, then deploys `web-02`. If it fails, it stops, and the other node is still on the
  last good release. `migrate --isolated` takes a lock in the shared cache, so a migration never runs twice
  at once. Migrations must be backward compatible (expand, then contract) because for a minute the nodes run
  different releases against the same schema.
- **The scheduler on one node.** `schedule:work` runs as a daemon on `web-01` only, and tasks that must not
  overlap use `->onOneServer()` (a lock in Valkey). Queue workers (Horizon) run on both.
- **Health check on `/up`, per node.** Laravel's `/up` boots the app. The LB takes a node out after 3 failed
  checks. The deploy's own `HEALTHCHECK_CMD` asks *this* node on loopback, never the LB, so a broken
  `web-02` can't pass because `web-01` answered.

```bash
examples/run.sh ha-two-web-lb      # validate (offline): profile checks, plans, the assembled deploy script
bin/siwo configure --profile production-ha --client <you> --set APP=shop --set ALERT_EMAIL=<you@example.com> \
  --set VPC_CIDR=10.0.0.0/20
# DO control panel: the load balancer (HTTPS 443 -> HTTP 80, certificate, health check HTTP :80 /up, both droplets
# in the VPC), Managed Valkey (trusted sources: both nodes), the Spaces bucket with a key limited to it
bin/siwo do firewall-apply web --vpc 10.0.0.0/20 --droplet <web-01-id>,<web-02-id> --dry-run
bin/siwo do uptime check-create shop-prd https://app.example.com/up --dry-run
# every deploy: the commit you merged, node by node (dry run first)
examples/ha-two-web-lb/rolling-deploy.sh --domain app.example.com --sha "$(git rev-parse origin/main)" \
  web-01=<server-id>:<site-id> web-02=<server-id>:<site-id>
```

| File | Use |
|---|---|
| [`example.conf`](example.conf) | `examples/run.sh ha-two-web-lb`: settings through `configure --dry-run`, plans |
| [`app.env.example`](app.env.example) | shared state off the nodes: Valkey, Spaces (secrets empty here) |
| [`ploi-deploy.settings.sh`](ploi-deploy.settings.sh) | the same SETTINGS on both nodes: `migrate --isolated`, `REVISION`, a node-local health check |
| [`nginx-lb.conf`](nginx-lb.conf) | the site as the default server on port 80, real client IP from the VPC |
| [`trust-proxies.php`](trust-proxies.php) | `bootstrap/app.php`: trust the load balancer's network only, plus the `/version` route |
| [`rolling-deploy.sh`](rolling-deploy.sh) | deploy one node, wait for the commit, then the next; dry run unless `--yes` |

Checklist:

- [ ] both nodes show `Healthy` in the load balancer, and stopping PHP on one keeps the site up
- [ ] `curl -sI http://<web-01 public IP>/` times out (port 80 only from the LB)
- [ ] log in, then take `web-01` out of the LB: still logged in (sessions in Valkey)
- [ ] upload a file, then take the node out: still served (Spaces)
- [ ] the scheduler daemon exists on `web-01` only (`bin/siwo ploi daemons <server-id>` on both)

Lesson: the LB's health check sends no `Host` header. If the site isn't Nginx's `default_server` on the node,
the check hits Ploi's catch-all page, gets a 200, and the LB keeps sending traffic to a node whose app is down.
