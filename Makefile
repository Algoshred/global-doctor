# global-doctor — E2E diagnostic wrapper

SHELL := /bin/bash
E2E_ENV := /home/ubuntu/products/workspaces/workspaces-doctor/core/env/e2e-env.sh
WITH_ENV = source $(E2E_ENV) && (e2e_refresh_token >/tmp/global-doctor-refresh.log 2>&1 || true) &&

.PHONY: help setup test test-all test\:headed report

help: ## Show this help message
	@grep -E '^[a-zA-Z0-9:_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Install Playwright browsers
	bun install
	bun run setup

test: ## Run the Playwright E2E suite
	@$(WITH_ENV) bun run test

test-all: test ## Run all Playwright E2E tests (alias for test)

test\:headed: ## Run the suite in headed mode
	@$(WITH_ENV) bun run test:headed

report: ## Open the HTML test report
	bun run report
