# ============================================================================
# Tenant Module E2E Tests Makefile
# ============================================================================
# Tests tenant management, organizations, workspaces, and memberships
# ============================================================================

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

# Directories
SCRIPTS_DIR := scripts
LOGS_DIR := logs
CORE_DIR := ../../core

# Environment
ENV_FILE := $(CORE_DIR)/env/e2e-env.sh

# Targets
.PHONY: help test test-tenants test-organizations test-workspaces test-memberships test-products test-product-mgmt test-shortcuts test-content-pages test-feature-flags test-deprecation test-pagination check-env logs clean

help: ## Show this help message
	@echo "$(BLUE)Tenant Module E2E Tests$(NC)"
	@echo ""
	@echo "$(GREEN)Available targets:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'

check-env: ## Validate environment setup
	@echo "$(BLUE)Checking environment...$(NC)"
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "$(RED)Environment file not found: $(ENV_FILE)$(NC)"; \
		echo "Run: make -C $(CORE_DIR) bootstrap-env"; \
		exit 1; \
	fi
	@. $(ENV_FILE) && \
	if [ -z "$$E2E_AUTH_TOKEN" ]; then \
		echo "$(RED)E2E_AUTH_TOKEN not set$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Environment validated$(NC)"

test: check-env ## Run all tenant E2E tests
	@echo "$(BLUE)Running all tenant E2E tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/*.sh 2>/dev/null || true
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh)

test-tenants: check-env ## Run tenant management tests
	@echo "$(BLUE)Running tenant management tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-tenant.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh tenants)

test-organizations: check-env ## Run organization tests
	@echo "$(BLUE)Running organization tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-tenant.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh organizations)

test-workspaces: check-env ## Run workspace tests
	@echo "$(BLUE)Running workspace tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-tenant.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh workspaces)

test-memberships: check-env ## Run membership tests
	@echo "$(BLUE)Running membership tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-tenant.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh memberships)

test-products: check-env ## Run product catalog tests
	@echo "$(BLUE)Running product catalog tests...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-tenant.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-tenant.sh products)

test-product-mgmt: check-env ## Run product-management E2E (Product/Shortcut/ContentPage/FeatureFlag CRUDL + RBAC)
	@echo "$(BLUE)Running product-management E2E...$(NC)"
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh)

test-shortcuts: check-env ## Run keyboard shortcut read tests
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh shortcuts)

test-content-pages: check-env ## Run content-page read tests
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh content-pages)

test-feature-flags: check-env ## Run feature-flag read + RBAC tests
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh feature-flags)

test-deprecation: check-env ## Verify deprecated mutations are removed from gateway
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh deprecation)

test-pagination: check-env ## Verify all list queries accept bounded limit/offset
	@chmod +x $(SCRIPTS_DIR)/test-product-mgmt.sh
	@$(call run_with_logging, $(SCRIPTS_DIR)/test-product-mgmt.sh pagination)

logs: ## Show test logs
	@if [ -d "$(LOGS_DIR)" ]; then \
		echo "$(BLUE)Recent test logs:$(NC)"; \
		ls -lt $(LOGS_DIR)/*.log 2>/dev/null | head -10; \
	else \
		echo "$(YELLOW)No logs found$(NC)"; \
	fi

clean: ## Clean test logs and temporary files
	@echo "$(YELLOW)Cleaning test artifacts...$(NC)"
	@rm -rf $(LOGS_DIR)
	@echo "$(GREEN)✓ Cleaned$(NC)"

# Helper function to run tests with logging
define run_with_logging
	mkdir -p $(LOGS_DIR) && \
	$(1) 2>&1 | tee $(LOGS_DIR)/test-$$(date +%Y%m%d-%H%M%S).log
endef

# ========================================
# Scale Audit Tests (2026-05-27)
# ========================================

.PHONY: test-scale-module-singletons test-scale-all

test-scale-module-singletons: ## Scale: tenant services are module-scope singletons
	@chmod +x $(SCRIPTS_DIR)/test-scale-module-singletons.sh
	$(SCRIPTS_DIR)/test-scale-module-singletons.sh

test-scale-all: test-scale-module-singletons ## All tenant scale tests
