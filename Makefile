# ---------------------------------------------------------------------------
# Entrypoint layer.
#
# This Makefile deliberately contains NO logic. Every target is a one-line call
# into a script under scripts/, so that CI, DevSpace, Ansible and a human all
# invoke the exact same code path — CI running `make check` is what guarantees
# CI cannot drift from what a developer runs locally.
#
# Primary target platform: Linux. macOS is best-effort. See scripts/lib/common.sh.
#
# Run `make help` to list every target.
# ---------------------------------------------------------------------------

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

ENV ?= dev

.PHONY: help preflight bootstrap up down build deploy dev test lint lint-iac \
        openapi smoke load check demo clean

help:  ## Show this help
	@printf '\n  %s\n\n' "csv-app — DevOps case study"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@printf '\n  %s\n\n' "Variables: ENV=dev|prod (current: $(ENV))"

preflight:  ## Check required tooling is installed
	@scripts/preflight.sh

bootstrap:  ## Install missing dev tooling (Linux first-class, macOS best-effort)
	@scripts/bootstrap.sh

up:  ## Start minikube with the required addons
	@scripts/minikube-up.sh

down:  ## Stop and delete the local cluster
	@scripts/minikube-down.sh

build:  ## Build the app image into minikube's Docker daemon
	@scripts/build-image.sh

deploy:  ## Deploy via Ansible + Helm (ENV=dev|prod)
	@scripts/deploy.sh "$(ENV)"

config:  ## Render Ansible config to values.generated.yaml without deploying (ENV=dev|prod)
	@scripts/render-config.sh "$(ENV)"

dev:  ## Start the DevSpace inner loop (hot reload)
	@scripts/dev.sh

test:  ## Run unit + API tests
	@scripts/test.sh

lint:  ## Lint and type-check the application code
	@scripts/lint.sh

lint-iac:  ## Lint helm, terraform, ansible, yaml and shell
	@scripts/lint-iac.sh

openapi:  ## Regenerate docs/openapi.yaml from the FastAPI app
	@scripts/gen-openapi.sh

smoke:  ## End-to-end: upload the sample CSV and assert it reached object storage
	@scripts/smoke-test.sh

load:  ## Generate load and watch the HPA scale
	@scripts/load-test.sh

check:  ## Everything CI runs (lint + test + lint-iac)
	@$(MAKE) --no-print-directory lint test lint-iac

demo:  ## One command: up -> build -> deploy -> smoke
	@$(MAKE) --no-print-directory up build deploy smoke

clean:  ## Remove build artifacts and caches
	@scripts/clean.sh
