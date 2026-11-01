# src/php — platform API library and CLI core

Typed PHP 8.4 clients for DigitalOcean, Cloudflare, Ploi and Google Compute Engine on one PSR-18 core, plus
the commands behind `bin/siwo do|cf|ploi|gcp`.

```bash
composer install --working-dir=src/php
bin/siwo credentials                 # which tokens are configured (never prints values)
bin/siwo do droplets
bin/siwo do snapshot 123456 --name db-pre-upgrade --dry-run
make php                                  # pint --test, phpstan (max), phpunit
```

Reference: [docs/tools/platform-api.md](../../docs/tools/platform-api.md) · CLI: [docs/tools/cli.md](../../docs/tools/cli.md)
