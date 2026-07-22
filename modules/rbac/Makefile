# Burdenoff Products - RBAC Module E2E Tests (PBAC)
# ============================================
#
# E2E tests for Policy-Based Access Control (PBAC) module:
# - Role management (CRUD, hierarchy)
# - Role default permissions
# - Actor role assignments (single, bulk)
# - Permission overrides (actor-level, role-level)
# - Permission checking (single, batch, effective, self-service)
# - Action definitions and resource types
# - Audit log and change history
# - Billing role initialization
#
# Prerequisites: Run 'make bootstrap-env' from doctor root first

.PHONY: help test test-roles test-defaults test-assignments test-overrides test-checking test-actions test-audit test-billing check-env logs
.DEFAULT_GOAL := help

# Configuration
SHELL := /bin/bash
SCRIPTS_DIR := $(shell pwd)/scripts
DOCTOR_ROOT := $(shell dirname $(shell dirname $(shell pwd)))
CORE_DIR := $(DOCTOR_ROOT)/core
ENV_FILE := $(CORE_DIR)/env/e2e-env.sh
LOGS_DIR := $(DOCTOR_ROOT)/logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
LOG_FILE := $(LOGS_DIR)/e2e-rbac-$(TIMESTAMP).log

# Ensure logs directory exists
$(shell mkdir -p $(LOGS_DIR))

# Colors
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

# Logging wrapper
define run_with_logging
	@mkdir -p $(LOGS_DIR)
	@echo "Logging to: $(LOG_FILE)"
	@E2E_LOG_FILE="$(LOG_FILE)" E2E_VERBOSE=true E2E_LOG_REQUESTS=true $(1) 2>&1 | tee -a $(LOG_FILE)
endef

# ========================================
# Help
# ========================================

help: ## Show this help
	@echo -e ""
	@echo -e "$(BLUE)RBAC Module E2E Tests (PBAC)$(NC)"
	@echo -e "=============================="
	@echo -e ""
	@echo -e "$(YELLOW)Prerequisites:$(NC)"
	@echo -e "  Run 'make bootstrap-env' from doctor root first"
	@echo -e ""
	@echo -e "$(YELLOW)Test Targets:$(NC)"
	@echo -e "  $(GREEN)test$(NC)               Run all RBAC E2E tests"
	@echo -e "  $(GREEN)test-roles$(NC)         Test role CRUD and hierarchy"
	@echo -e "  $(GREEN)test-defaults$(NC)      Test role default permission CRUD"
	@echo -e "  $(GREEN)test-assignments$(NC)   Test actor role assignments (single, bulk)"
	@echo -e "  $(GREEN)test-overrides$(NC)     Test permission overrides (actor + role)"
	@echo -e "  $(GREEN)test-checking$(NC)      Test permission checking (single, batch, effective)"
	@echo -e "  $(GREEN)test-actions$(NC)       Test action definitions and resource types"
	@echo -e "  $(GREEN)test-audit$(NC)         Test audit log and change history"
	@echo -e "  $(GREEN)test-billing$(NC)       Test billing role initialization"
	@echo -e ""
	@echo -e "$(YELLOW)Utilities:$(NC)"
	@echo -e "  $(GREEN)check-env$(NC)          Verify environment is bootstrapped"
	@echo -e "  $(GREEN)logs$(NC)               Show latest log file"
	@echo -e ""

# ========================================
# Environment Check
# ========================================

check-env: ## Verify environment is bootstrapped
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo -e "$(RED)Environment not bootstrapped!$(NC)"; \
		echo -e "Run: make bootstrap-env from doctor root"; \
		exit 1; \
	fi
	@source $(ENV_FILE) && \
		if [ -z "$$E2E_AUTH_TOKEN" ]; then \
			echo -e "$(RED)No auth token in environment!$(NC)"; \
			exit 1; \
		fi
	@echo -e "$(GREEN)Environment check passed$(NC)"

# ========================================
# Test Targets
# ========================================

test: check-env ## Run all RBAC E2E tests
	@echo -e "$(BLUE)Running all RBAC E2E tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh)

test-roles: check-env ## Test role CRUD and hierarchy
	@echo -e "$(BLUE)Running role tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh roles)

test-defaults: check-env ## Test role default permissions
	@echo -e "$(BLUE)Running default permission tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh defaults)

test-assignments: check-env ## Test actor role assignments
	@echo -e "$(BLUE)Running assignment tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh assignments)

test-overrides: check-env ## Test permission overrides
	@echo -e "$(BLUE)Running override tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh overrides)

test-checking: check-env ## Test permission checking
	@echo -e "$(BLUE)Running permission checking tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh checking)

test-actions: check-env ## Test action definitions and resource types
	@echo -e "$(BLUE)Running action definition tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh actions)

test-audit: check-env ## Test audit log and change history
	@echo -e "$(BLUE)Running audit tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh audit)

test-billing: check-env ## Test billing role initialization
	@echo -e "$(BLUE)Running billing role tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-rbac.sh billing)

# ========================================
# Utilities
# ========================================

logs: ## Show latest log file
	@if ls $(LOGS_DIR)/e2e-rbac-*.log 1> /dev/null 2>&1; then \
		latest=$$(ls -t $(LOGS_DIR)/e2e-rbac-*.log | head -1); \
		echo -e "$(BLUE)Latest log: $$latest$(NC)"; \
		tail -100 "$$latest"; \
	else \
		echo -e "$(YELLOW)No log files found$(NC)"; \
	fi
