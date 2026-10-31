# vps-server-workbench - dev front door. Run from the repo root:  make <target>
#
# SCRIPTS is every shell script in the repo, found by extension, so a new script
# is linted without editing this file. PHP and Python targets skip (exit 0) with
# a note when php, composer or python3 is missing, so `make ci` works anywhere.
SHELL   := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' -not -path '*/vendor/*' | sort) bin/workbench
PHP_OK   = command -v php >/dev/null 2>&1 && php -r 'exit(PHP_VERSION_ID >= 80400 ? 0 : 1);'
PY_OK    = command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))'

.PHONY: help lint syntax shellcheck fmt-check compose-check links mermaid test it ci ci-local secrets-check docs-commands \
        php-install php-lint php-test php py-lint py-test python

help:  ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

GITLEAKS_IMAGE := zricethezav/gitleaks:v8.30.1
SHELLCHECK_VERSION := 0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:v$(SHELLCHECK_VERSION)

secrets-check: ## no hardcoded secrets: repo scanner (tracked files) + gitleaks (full history, .gitleaks.toml)
	python3 tests/security/no-hardcoded-secrets.py --self-test
	python3 tests/security/no-hardcoded-secrets.py
	@if command -v gitleaks >/dev/null 2>&1; then gitleaks git --no-banner --redact --config .gitleaks.toml --log-opts=--all .; \
	  elif command -v docker >/dev/null 2>&1; then docker run --rm -v "$$PWD:/repo" -w /repo $(GITLEAKS_IMAGE) git --no-banner --redact --config .gitleaks.toml --log-opts=--all /repo; \
	  else echo "gitleaks not installed and no docker - skipping the history scan"; fi

syntax: ## bash -n on every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; echo "bash -n ok  $$f"; done

# One shellcheck version everywhere: a local binary of exactly this version, otherwise the pinned image.
# ubuntu-latest ships an older shellcheck, so CI and laptops used to disagree on findings.
shellcheck: ## shellcheck every script with the pinned version (local binary if it matches, else docker)
	@v="$$(shellcheck --version 2>/dev/null | sed -n 's/^version: //p')"; \
	  if [ "$$v" = "$(SHELLCHECK_VERSION)" ] && [ -z "$(SHELLCHECK_DOCKER)" ]; then echo "shellcheck $$v (local)"; shellcheck -x $(SCRIPTS); \
	  elif command -v docker >/dev/null 2>&1; then echo "shellcheck $(SHELLCHECK_VERSION) ($(SHELLCHECK_IMAGE))"; \
	    docker run --rm -v "$$PWD:/mnt" -w /mnt $(SHELLCHECK_IMAGE) -x $(SCRIPTS); \
	  else echo "need shellcheck $(SHELLCHECK_VERSION) (found: $${v:-none}) or docker"; exit 1; fi

ci-local: ## the CI gate exactly as the workflow runs it (pinned shellcheck image, same make ci)
	@echo "php: $$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo missing) (CI 8.4)  python: $$(python3 -c 'import platform;print(platform.python_version())' 2>/dev/null || echo missing) (CI 3.14)"
	$(MAKE) ci SHELLCHECK_DOCKER=1

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
	  { cat $$d/addon.env.example; printf 'ADDON_BIND=127.0.0.1\nADDON_DATA_DIR=/tmp/vsw-cc\nRUSTFS_ACCESS_KEY=x\nRUSTFS_SECRET_KEY=%s\nSEAWEED_ADMIN_PASSWORD=%s\n' $$(openssl rand -hex 12) $$(openssl rand -hex 12); } \
	    | sed 's/[[:space:]]*#.*//' > /tmp/vsw-cc-$$n.env; \
	  (cd $$d && docker compose --env-file /tmp/vsw-cc-$$n.env config -q) && echo "compose ok  stacks/addons/$$n" || { rm -f /tmp/vsw-cc-$$n.env; exit 1; }; \
	  if [ -f $$d/compose.bridge.yml ]; then (cd $$d && docker compose --env-file /tmp/vsw-cc-$$n.env -f docker-compose.yml -f compose.bridge.yml config -q) \
	    && echo "compose ok  stacks/addons/$$n (bridge)" || { rm -f /tmp/vsw-cc-$$n.env; exit 1; }; fi; rm -f /tmp/vsw-cc-$$n.env; done
	@for d in stacks/monitor/*/; do n=$$(basename $$d); \
	  { cat $$d/monitor.env.example; printf 'MONITOR_BIND=127.0.0.1\nMONITOR_AGENT_BIND=10.0.0.2\nMONITOR_TEXTFILE_DIR=/tmp/vsw-cc\nBESZEL_AGENT_LISTEN=10.0.0.2:45876\nNODE_EXPORTER_LISTEN=10.0.0.2:9100\nBESZEL_ADMIN_EMAIL=a@example.com\nBESZEL_ADMIN_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nBESZEL_KEY=k\n' $$(openssl rand -hex 12) $$(openssl rand -hex 12); } \
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
	python3 tests/docs/check-config-examples.py .

docs-commands: php-install ## every documented command/subcommand/--flag exists (vs --help); every Markdown table row matches its header
	python3 tests/docs/check-commands.py .
	python3 tests/docs/check-tables.py .

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
	bash examples/run.sh --all

it: ## Docker integration tests: upgrade, add-ons, server tools, DB features (verify-full, metrics, migrate-managed, pg-major-upgrade), PITR restore (posix and S3 via Garage + TLS), a 3-node Garage cluster, monitoring, WireGuard between two hosts (~13 min)
	bash tests/shell/run-suites.sh tests/shell/upgrade-it.sh tests/shell/addons-it.sh tests/shell/server-it.sh \
	  tests/shell/db-features-it.sh tests/shell/pitr-it.sh tests/shell/pitr-s3-it.sh \
	  tests/shell/garage-cluster-it.sh tests/shell/monitor-it.sh tests/shell/wg-it.sh

client-check: ## fail if a .client-denylist term (or a built-in one) is in a tracked file or commit message
	tests/shell/client-check.sh

ci: secrets-check lint test client-check php python links docs-commands compose-check ## the gate CI runs
