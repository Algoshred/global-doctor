# Burdenoff Products - Auth Module E2E Tests
# ============================================
#
# E2E tests for authentication module operations:
# - Token management (tokenInfo, refreshToken)
# - Password management (changePassword)
# - Profile updates
# - MFA flows
# - Session management
# - Account actions
#
# Prerequisites: Run 'make bootstrap-env' from doctor root first

.PHONY: help test test-tokens test-password test-mfa test-sessions test-account test-email-routing
.DEFAULT_GOAL := help

# Configuration
SHELL := /bin/bash
SCRIPTS_DIR := $(shell pwd)/scripts
DOCTOR_ROOT := $(shell dirname $(shell dirname $(shell pwd)))
CORE_DIR := $(DOCTOR_ROOT)/core
ENV_FILE := $(CORE_DIR)/env/e2e-env.sh
LOGS_DIR := $(DOCTOR_ROOT)/logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
LOG_FILE := $(LOGS_DIR)/e2e-auth-$(TIMESTAMP).log

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
	@echo -e "$(BLUE)Auth Module E2E Tests$(NC)"
	@echo -e "======================"
	@echo -e ""
	@echo -e "$(YELLOW)Prerequisites:$(NC)"
	@echo -e "  Run 'make bootstrap-env' from doctor root first"
	@echo -e ""
	@echo -e "$(YELLOW)Test Targets:$(NC)"
	@echo -e "  $(GREEN)test$(NC)              Run all auth E2E tests"
	@echo -e "  $(GREEN)test-tokens$(NC)       Test token operations (tokenInfo, refreshToken)"
	@echo -e "  $(GREEN)test-password$(NC)     Test password operations (changePassword)"
	@echo -e "  $(GREEN)test-mfa$(NC)          Test MFA flows (setup, enable, verify, disable)"
	@echo -e "  $(GREEN)test-sessions$(NC)     Test session management (signOut)"
	@echo -e "  $(GREEN)test-account$(NC)      Test account actions (profile, deactivate)"
	@echo -e "  $(GREEN)test-email-routing$(NC) Validate auth email routing through channel-svc"
	@echo -e ""
	@echo -e "$(YELLOW)Utilities:$(NC)"
	@echo -e "  $(GREEN)check-env$(NC)         Verify environment is bootstrapped"
	@echo -e "  $(GREEN)logs$(NC)              Show latest log file"
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

test: check-env ## Run all auth E2E tests
	@echo -e "$(BLUE)Running all auth E2E tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh && $(SCRIPTS_DIR)/test-auth-channel-routing.sh)

test-tokens: check-env ## Test token operations
	@echo -e "$(BLUE)Running token tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh tokens)

test-password: check-env ## Test password operations
	@echo -e "$(BLUE)Running password tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh password)

test-mfa: check-env ## Test MFA flows
	@echo -e "$(BLUE)Running MFA tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh mfa)

test-sessions: check-env ## Test session management
	@echo -e "$(BLUE)Running session tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh sessions)

test-account: check-env ## Test account actions
	@echo -e "$(BLUE)Running account tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth.sh account)

test-email-routing: check-env ## Validate auth email routing through channel-svc
	@echo -e "$(BLUE)Running auth email routing tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	$(call run_with_logging, $(SCRIPTS_DIR)/test-auth-channel-routing.sh)

# ========================================
# Utilities
# ========================================

logs: ## Show latest log file
	@if ls $(LOGS_DIR)/e2e-auth-*.log 1> /dev/null 2>&1; then \
		latest=$$(ls -t $(LOGS_DIR)/e2e-auth-*.log | head -1); \
		echo -e "$(BLUE)Latest log: $$latest$(NC)"; \
		tail -100 "$$latest"; \
	else \
		echo -e "$(YELLOW)No log files found$(NC)"; \
	fi
