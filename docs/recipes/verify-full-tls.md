# Recipe: switch database TLS to verify-full

**Why:** `TLS_MODE=require` encrypts but does not prove who answered. Anyone in the path, or a wrong
`DB_HOST`, gets your password. With `verify-full` the client checks that the certificate chains to *our*
CA and names the host it dialled.

**Design:** the manager makes a private CA on the DB server. The key (`/opt/db/tls/ca.key`, 600) never leaves
it. Server certificates cover every bind IP plus `postgres` (PgBouncer checks the server too). They are
reissued when an IP is missing from the SAN or the certificate expires within 30 days.

## Steps

1. In the server config set `TLS_MODE=verify-full` (and optionally `TLS_CA_WEB_PATH`, the CA's path on the
   web hosts). Run `upgrade --dry-run`, then `upgrade`, through `remote-run.sh`.
2. Copy the **public** CA to each web host:
   `sudo /root/docker-db-server-manager.sh tls-ca --out /tmp/siw-db-ca.crt`, then put it at `/etc/ssl/certs/vsw-db-ca.crt` (644) on the web host.
3. `sudo /root/docker-db-server-manager.sh env` now prints `DB_SSLMODE=verify-full` and `DB_SSLROOTCERT=...`. Put both in the Laravel `.env`
   (Laravel reads `DB_SSLMODE` as `sslmode`; add `'sslrootcert' => env('DB_SSLROOTCERT')` to the `pgsql` connection in
   `config/database.php` if it is not there), then deploy.
4. Check from the web host: `psql "host=10.0.0.5 port=6432 user=app dbname=app sslmode=verify-full sslrootcert=/etc/ssl/certs/vsw-db-ca.crt" -c 'select 1'`.

## Checklist

- [ ] `doctor`: "verify-full: server certificate chains to the CA"
- [ ] CA on every web host, app `.env` updated
- [ ] A connection with a wrong CA fails (the test does this)

## Lessons learned

- `DB_HOST` must be the IP (or name) in the certificate. With verify-full, a hostname the SAN doesn't list
  fails, by design.
- Only the CA certificate is public. If `ca.key` ever leaves the server, rotate it (delete `/opt/db/tls`
  and run `upgrade`).
