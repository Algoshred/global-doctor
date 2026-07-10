# global-doctor — E2E diagnostic wrapper

.PHONY: help setup test test:headed report

help: ## Show this help message
	@grep -E '^[a-zA-Z0-9:_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Install Playwright browsers
	bun install
	bun run setup

test: ## Run the Playwright E2E suite
	bun run test

test\:headed: ## Run the suite in headed mode
	bun run test:headed

report: ## Open the HTML test report
	bun run report
