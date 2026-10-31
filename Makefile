# vps-server-workbench - dev front door. Run from the repo root:  make <target>
#
# Plain bash + docker compose. SCRIPTS is every shell script in the repo, found
# by extension, so a new script is linted without editing this file.
SHELL   := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' -not -path '*/vendor/*' | sort) bin/vsw

.PHONY: help lint syntax shellcheck compose-check links mermaid test it ci

help:  ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

syntax: ## bash -n on every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; echo "bash -n ok  $$f"; done

shellcheck: ## shellcheck every script (install: brew install shellcheck / apt install shellcheck)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; exit 1; }
	shellcheck -x $(SCRIPTS)

lint: syntax shellcheck ## syntax + shellcheck

compose-check: ## docker compose config + caddy validate for stacks/caddy (needs docker)
	@command -v docker >/dev/null 2>&1 || { echo "docker not installed - skipping"; exit 0; }
	cd stacks/caddy && SITE_DOMAIN=example.com docker compose config -q && echo "compose ok  stacks/caddy"
	@for f in stacks/caddy/conf/Caddyfile stacks/caddy/variants/*.Caddyfile; do \
	  docker run --rm -e SITE_DOMAIN=example.com -v "$$PWD/$$f:/c/Caddyfile:ro" $${CADDY_IMAGE:-caddy:2.11} \
	    caddy validate --config /c/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
	    && echo "caddy ok    $$f" || { echo "caddy validate FAILED: $$f"; exit 1; }; done

links: ## check relative links and #anchors in all Markdown
	python3 tests/docs/check-links.py .

mermaid: ## render every Mermaid block to /tmp/vsw-mermaid (needs node; downloads mermaid-cli)
	bash tests/docs/render-mermaid.sh

test: ## offline smoke tests (no servers touched)
	bash tests/shell/smoke.sh

it: ## Docker integration test of the guided upgrade (throwaway containers, ~3 min)
	bash tests/shell/upgrade-it.sh

ci: lint test links compose-check ## the gate CI runs
