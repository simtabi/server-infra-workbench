# vps-hosting-management - dev front door. Run from the repo root:  make <target>
#
# Plain bash + docker compose. SCRIPTS is every shell script in the repo, found
# by extension, so a new script is linted without editing this file.
SHELL   := /bin/bash
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' | sort)

.PHONY: help lint syntax shellcheck compose-check test ci

help:  ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

syntax: ## bash -n on every script
	@for f in $(SCRIPTS); do bash -n "$$f" || exit 1; echo "bash -n ok  $$f"; done

shellcheck: ## shellcheck every script (install: brew install shellcheck / apt install shellcheck)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck is not installed"; exit 1; }
	shellcheck -x $(SCRIPTS)

lint: syntax shellcheck ## syntax + shellcheck

compose-check: ## validate the compose examples (needs docker)
	@command -v docker >/dev/null 2>&1 || { echo "docker not installed - skipping"; exit 0; }
	cd compose/caddy && SITE_DOMAIN=example.com docker compose config -q && echo "compose ok  compose/caddy"

test: ## offline smoke tests (no servers touched)
	bash tests/smoke.sh

ci: lint test ## the gate CI runs
