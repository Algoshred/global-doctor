# =============================================================================
# global-doctor — Backend E2E Testing & Diagnostics
# =============================================================================
#
# Self-contained E2E testing for the global/tenant control plane. Backend-only
# (GraphQL/curl) per platform convention — no Playwright/UI suites live here.
#
# Suites are ported from workspaces-doctor/global/modules, which already
# proved this exact harness against the local dev stack; global-doctor keeps
# its own copy so this repo's CI doesn't depend on a sibling repo's checkout.
#
# Prerequisite: the global dev stack must already be running (the module
# state services + global-{auth,tenant,rbac}-svc + global-public-gateway +
# wspace-public-gateway), e.g. via `make reset` in ~/products/dev/.
#
# Usage: make <target>
# =============================================================================

.PHONY: help setup test test-crudl test-modules test-all bootstrap-env teardown-env show-env logs logs-follow logs-clean

SHELL := /bin/bash
DOCTOR_ROOT := $(shell pwd)
CORE_DIR := $(DOCTOR_ROOT)/core
MODULES_DIR := $(DOCTOR_ROOT)/modules
SCRIPTS_DIR := $(CORE_DIR)/scripts
ENV_DIR := $(CORE_DIR)/env
PRODUCTS_ROOT := $(HOME)/products

LOGS_DIR := $(DOCTOR_ROOT)/logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
LOG_FILE := $(LOGS_DIR)/e2e-$(TIMESTAMP).log

export DOCTOR_ROOT
export PRODUCTS_ROOT
export E2E_LOG_FILE
export E2E_VERBOSE
export E2E_LOG_REQUESTS

$(shell mkdir -p $(LOGS_DIR))
$(shell mkdir -p $(ENV_DIR))

BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

define run_with_logging
	@mkdir -p $(LOGS_DIR)
	@echo "Logging to: $(LOG_FILE)"
	@set -o pipefail; E2E_LOG_FILE="$(LOG_FILE)" E2E_VERBOSE=true E2E_LOG_REQUESTS=true DOCTOR_ROOT="$(DOCTOR_ROOT)" PRODUCTS_ROOT="$(PRODUCTS_ROOT)" $(1) 2>&1 | tee -a $(LOG_FILE)
endef

# ========================================
# Help
# ========================================

help: ## Show this help message
	@echo -e ""
	@echo -e "$(BLUE)global-doctor - Backend E2E Testing & Diagnostics$(NC)"
	@echo -e "===================================================="
	@echo -e ""
	@echo -e "$(YELLOW)Quick Start:$(NC)"
	@echo -e "  $(GREEN)bootstrap-env$(NC)   Create test user/tenant/org/workspace (run this first)"
	@echo -e "  $(GREEN)test-all$(NC)        Run every suite (core flow + CRUDL + modules)"
	@echo -e ""
	@echo -e "$(YELLOW)Core Tests:$(NC)"
	@echo -e "  $(GREEN)test$(NC)            Full auth/tenant/workspace provisioning flow"
	@echo -e "  $(GREEN)test-crudl$(NC)      CRUDL tests: users, tenants, organizations, workspaces"
	@echo -e ""
	@echo -e "$(YELLOW)Module Suites (see modules/ — auth, tenant, rbac):$(NC)"
	@echo -e "  $(GREEN)test-modules$(NC)    Run all module suites"
	@echo -e "  (per-suite: make -C modules test-auth / test-tenant / test-rbac)"
	@echo -e ""
	@echo -e "$(YELLOW)Environment:$(NC)"
	@echo -e "  $(GREEN)bootstrap-env$(NC)   Create test user, tenant, org, workspace"
	@echo -e "  $(GREEN)teardown-env$(NC)    Clean up environment resources"
	@echo -e "  $(GREEN)show-env$(NC)        Show current environment variables"
	@echo -e ""
	@echo -e "$(YELLOW)Logging:$(NC)"
	@echo -e "  $(GREEN)logs$(NC)            Show latest log file"
	@echo -e "  $(GREEN)logs-follow$(NC)     Follow log in real-time"
	@echo -e ""
	@echo -e "$(YELLOW)Prerequisite:$(NC) the global dev stack must already be running"
	@echo -e "(module state services + global-{auth,tenant,rbac}-svc + gateways)."
	@echo -e ""

# ========================================
# Quick Start
# ========================================

setup: bootstrap-env ## First-time setup: bootstrap the test environment
	@echo -e "$(GREEN)Setup complete! Run 'make test' to run E2E tests.$(NC)"

# ========================================
# Core Tests
# ========================================

test: ## Run the full auth/tenant/workspace provisioning flow
	@echo -e "$(BLUE)Running core E2E test...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/run-e2e-test-full.sh)

test-crudl: ## Run CRUDL E2E tests for core resources
	@echo -e "$(BLUE)Running CRUDL E2E tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/run-crudl-tests.sh)

test-modules: ## Run all module E2E suites (auth, tenant, rbac)
	@echo -e "$(BLUE)Running all module suites...$(NC)"
	@$(MAKE) -C $(MODULES_DIR) test-all

test-all: test test-crudl test-modules ## Run every suite (core flow + CRUDL + modules)
	@echo -e ""
	@echo -e "$(GREEN)All global-doctor E2E tests completed!$(NC)"

# ========================================
# Environment Management
# ========================================

bootstrap-env: ## Create foundation resources (user, tenant, org, workspace)
	@echo -e "$(BLUE)Bootstrapping E2E environment...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/bootstrap-env.sh)
	@echo -e ""
	@echo -e "$(GREEN)Environment bootstrapped!$(NC)"
	@echo -e "To use in other scripts: source $(ENV_DIR)/e2e-env.sh"

teardown-env: ## Clean up environment resources
	@echo -e "$(BLUE)Tearing down E2E environment...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/teardown-env.sh --force)
	@echo -e ""
	@echo -e "$(GREEN)Environment torn down!$(NC)"

show-env: ## Show current environment variables
	@echo -e "$(BLUE)Current E2E Environment:$(NC)"
	@if [ -f "$(ENV_DIR)/e2e-env.sh" ]; then \
		. $(ENV_DIR)/e2e-env.sh && \
		echo "  User:      $$E2E_USER_EMAIL ($$E2E_USER_ID)" && \
		echo "  Tenant:    $$E2E_TENANT_ID" && \
		echo "  Org:       $$E2E_ORG_ID" && \
		echo "  Workspace: $$E2E_WORKSPACE_ID"; \
	else \
		echo -e "$(RED)No environment bootstrapped. Run: make bootstrap-env$(NC)"; \
	fi

# ========================================
# Logging Utilities
# ========================================

logs: ## Show latest log file
	@if ls $(LOGS_DIR)/e2e-*.log 1> /dev/null 2>&1; then \
		latest=$$(ls -t $(LOGS_DIR)/e2e-*.log | head -1); \
		echo -e "$(BLUE)Latest log: $$latest$(NC)"; \
		tail -100 "$$latest"; \
	else \
		echo -e "$(YELLOW)No log files found in $(LOGS_DIR)$(NC)"; \
	fi

logs-follow: ## Follow the latest log file
	@latest=$$(ls -t $(LOGS_DIR)/e2e-*.log 2>/dev/null | head -1); \
	if [ -n "$$latest" ]; then tail -f "$$latest"; else echo "No log files found."; fi

logs-clean: ## Remove log files older than 7 days
	@find $(LOGS_DIR) -name "e2e-*.log" -mtime +7 -delete 2>/dev/null || true
	@echo -e "$(GREEN)Old logs cleaned$(NC)"
