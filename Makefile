# global-doctor — backend E2E diagnostic wrapper
#
# This repo is intentionally backend-only. Playwright UI tests live in the
# app/website/microfe repos. Add bash/shell test scripts here as backend
# coverage is built out.

SHELL := /bin/bash

.PHONY: help test test-all

help: ## Show this help message
	@grep -E '^[a-zA-Z0-9:_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

test: ## Run backend E2E tests (placeholder — none defined yet)
	@echo "global-doctor is backend-only. No backend shell tests are defined yet."
	@echo "Add shell tests under this repo and wire them to this target."

test-all: test ## Run all backend E2E tests (alias for test)
