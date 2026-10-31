# Gotenberg add-on

HTML, Markdown and Office files to PDF (Chromium + LibreOffice) behind a small HTTP API.

- Image `gotenberg/gotenberg:8.39.0`. The `-chromium` and `-libreoffice` variants are smaller if you need
  only one engine; set `GOTENBERG_IMAGE`.
- Default role `web`. It binds `127.0.0.1:3000`, has a 1 GB memory limit and 1 CPU, uses tmpfs `/tmp`,
  runs as a non-root user, and has webhooks off.
- **SSRF guard**: `--chromium-deny-private-ips`, `--libreoffice-deny-private-ips` and
  `--api-download-from-deny-private-ips` are on (`GOTENBERG_DENY_PRIVATE_IPS=true`). Rendered HTML cannot
  fetch `10.x`, `127.x` or the `169.254.169.254` metadata service. Send assets inline (as files in the
  request) rather than as internal URLs.
- On `db` or `dedicated` roles it binds the VPC address and turns basic auth on with generated credentials.
- Laravel: `GOTENBERG_URL=http://127.0.0.1:3000`, for example with `gotenberg/gotenberg-php`.

```bash
addon.sh install gotenberg
curl -s -o out.pdf -F files=@index.html http://127.0.0.1:3000/forms/chromium/convert/html
```
