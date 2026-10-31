# vps-server-workbench - dev front door. Run from the repo root:  make <target>
#
# SCRIPTS is every shell script in the repo, found by extension, so a new script
# is linted without editing this file. PHP and Python targets skip (exit 0) with
# a note when php, composer or python3 is missing, so `make ci` works anywhere.
SHELL   := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' -not -path '*/vendor/*' | sort) bin/workbench
PHP_OK   = command -v php >/dev/null 2>&1 && php -r 'exit(PHP_VERSION_ID >= 80400 ? 0 : 1);'
PY_OK    = command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))'

.PHONY: help lint syntax shellcheck fmt-check compose-check links mermaid test it ci \
        php-install php-lint php-test php py-lint py-test python

help:  ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

syntax: ## bash -n on every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; echo "bash -n ok  $$f"; done

shellcheck: ## shellcheck every script (install: brew install shellcheck / apt install shellcheck)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; exit 1; }
	shellcheck -x $(SCRIPTS)

lint: syntax shellcheck ## syntax + shellcheck

fmt-check: ## shfmt diff (advisory, not part of ci; settings in .editorconfig)
	@command -v shfmt >/dev/null 2>&1 || { echo "shfmt not installed - skipping"; exit 0; }
	@shfmt -d $(SCRIPTS) && echo "shfmt ok" || echo "shfmt: differences above (advisory)"

php-install: ## composer install for src/php (locked versions)
	@if ! { $(PHP_OK); } || ! command -v composer >/dev/null 2>&1; then echo "php 8.4+ or composer not installed - skipping php"; exit 0; fi; \
	  [ -f src/php/vendor/autoload.php ] || composer install --working-dir=src/php --no-interaction --no-progress --prefer-dist

php-lint: php-install ## pint --test + phpstan (level max, strict rules)
	@if ! { $(PHP_OK); } || [ ! -f src/php/vendor/autoload.php ]; then echo "php not available - skipping php-lint"; exit 0; fi; \
	  cd src/php && vendor/bin/pint --test && vendor/bin/phpstan analyse --no-progress --memory-limit=512M

php-test: php-install ## phpunit (mocked HTTP, no network)
	@if ! { $(PHP_OK); } || [ ! -f src/php/vendor/autoload.php ]; then echo "php not available - skipping php-test"; exit 0; fi; \
	  cd src/php && vendor/bin/phpunit --no-coverage

php: php-lint php-test ## all PHP checks

py-lint: ## py_compile everything, plus ruff when installed
	@if ! { $(PY_OK); }; then echo "python 3.12+ not installed - skipping py-lint"; exit 0; fi; \
	  python3 -m compileall -q src/python/src src/python/tests tests/docs >/dev/null && echo "py_compile ok"; \
	  if command -v ruff >/dev/null 2>&1; then ruff check src/python && ruff format --check src/python; else echo "ruff not installed - skipped style check"; fi

py-test: ## unittest for src/python
	@if ! { $(PY_OK); }; then echo "python 3.12+ not installed - skipping py-test"; exit 0; fi; \
	  PYTHONPATH=src/python/src python3 -m unittest discover -s src/python/tests

python: py-lint py-test ## all Python checks

compose-check: ## docker compose config for stacks/caddy, stacks/addons, stacks/monitor; caddy validate; promtool (needs docker)
	@command -v docker >/dev/null 2>&1 || { echo "docker not installed - skipping"; exit 0; }
	cd stacks/caddy && SITE_DOMAIN=example.com docker compose config -q && echo "compose ok  stacks/caddy"
	@for d in stacks/addons/*/; do n=$$(basename $$d); \
	  { cat $$d/addon.env.example; printf 'ADDON_BIND=127.0.0.1\nADDON_DATA_DIR=/tmp/vsw-cc\nRUSTFS_ACCESS_KEY=x\nRUSTFS_SECRET_KEY=y\nSEAWEED_ADMIN_PASSWORD=z\n'; } \
	    | sed 's/[[:space:]]*#.*//' > /tmp/vsw-cc-$$n.env; \
	  (cd $$d && docker compose --env-file /tmp/vsw-cc-$$n.env config -q) && echo "compose ok  stacks/addons/$$n" || { rm -f /tmp/vsw-cc-$$n.env; exit 1; }; \
	  if [ -f $$d/compose.bridge.yml ]; then (cd $$d && docker compose --env-file /tmp/vsw-cc-$$n.env -f docker-compose.yml -f compose.bridge.yml config -q) \
	    && echo "compose ok  stacks/addons/$$n (bridge)" || { rm -f /tmp/vsw-cc-$$n.env; exit 1; }; fi; rm -f /tmp/vsw-cc-$$n.env; done
	@for d in stacks/monitor/*/; do n=$$(basename $$d); \
	  { cat $$d/monitor.env.example; printf 'MONITOR_BIND=127.0.0.1\nMONITOR_AGENT_BIND=10.0.0.2\nMONITOR_TEXTFILE_DIR=/tmp/vsw-cc\nBESZEL_AGENT_LISTEN=10.0.0.2:45876\nNODE_EXPORTER_LISTEN=10.0.0.2:9100\nBESZEL_ADMIN_EMAIL=a@example.com\nBESZEL_ADMIN_PASSWORD=x\nGRAFANA_ADMIN_PASSWORD=y\nBESZEL_KEY=k\nPG_EXPORTER_DSN=x\nPGBOUNCER_EXPORTER_DSN=x\n'; } \
	    | sed 's/[[:space:]]*#.*//' > /tmp/vsw-cc-m-$$n.env; \
	  (cd $$d && docker compose --env-file /tmp/vsw-cc-m-$$n.env config -q) && echo "compose ok  stacks/monitor/$$n" || { rm -f /tmp/vsw-cc-m-$$n.env; exit 1; }; \
	  if [ -f $$d/compose.host.yml ]; then (cd $$d && docker compose --env-file /tmp/vsw-cc-m-$$n.env -f docker-compose.yml -f compose.host.yml config -q) \
	    && echo "compose ok  stacks/monitor/$$n (host network)" || { rm -f /tmp/vsw-cc-m-$$n.env; exit 1; }; fi; rm -f /tmp/vsw-cc-m-$$n.env; done
	@docker run --rm --entrypoint promtool -v "$$PWD/stacks/monitor/prometheus/rules:/r:ro" $$(sed -n "s/^PROMETHEUS_IMAGE=//p" stacks/monitor/prometheus/monitor.env.example) \
	  check rules /r/vsw.yml >/dev/null && echo "promtool ok stacks/monitor/prometheus/rules" || { echo "promtool check rules FAILED"; exit 1; }
	@for f in stacks/caddy/conf/Caddyfile stacks/caddy/variants/*.Caddyfile; do \
	  docker run --rm -e SITE_DOMAIN=example.com -v "$$PWD/$$f:/c/Caddyfile:ro" $${CADDY_IMAGE:-caddy:2.11} \
	    caddy validate --config /c/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
	    && echo "caddy ok    $$f" || { echo "caddy validate FAILED: $$f"; exit 1; }; done

links: ## check relative links and #anchors in all Markdown
	python3 tests/docs/check-links.py .
	python3 tests/docs/gen-config-keys.py --check

mermaid: ## render every Mermaid block to /tmp/vsw-mermaid (needs node; downloads mermaid-cli)
	bash tests/docs/render-mermaid.sh

test: ## offline smoke tests (no servers touched)
	bash tests/shell/smoke.sh
	bash tests/shell/smoke-db.sh
	bash tests/shell/smoke-addons.sh
	bash tests/shell/smoke-server.sh
	bash tests/shell/smoke-net.sh
	bash tests/shell/smoke-progress.sh
	bash tests/shell/smoke-monitor.sh
	python3 stacks/monitor/prometheus/grafana/dashboards.py --check

it: ## Docker integration tests: upgrade, add-ons, server tools, DB features (verify-full, metrics, migrate-managed, pg-major-upgrade), monitoring (~20 min)
	bash tests/shell/run-suites.sh tests/shell/upgrade-it.sh tests/shell/addons-it.sh tests/shell/server-it.sh \
	  tests/shell/db-features-it.sh tests/shell/monitor-it.sh

client-check: ## fail if a .client-denylist term (or a built-in one) is in a tracked file or commit message
	tests/shell/client-check.sh

ci: lint test client-check php python links compose-check ## the gate CI runs
