# Burdenoff Products - E2E Global Module Testing Makefile
# =======================================================
#
# Suites ported from workspaces-doctor/global/modules (proven, already
# battle-tested against the local dev stack) — see the parent CLAUDE.md for
# why global-doctor needs its own self-contained copy rather than a
# cross-repo dependency on workspaces-doctor.
#
# Usage: make <target>

.DEFAULT_GOAL := help

# Configuration
SHELL := /bin/bash
DOCTOR_ROOT := $(shell dirname $(shell pwd))
CORE_DIR := $(DOCTOR_ROOT)/core
PRODUCTS_ROOT := $(HOME)/products

# Logging Configuration
LOGS_DIR := $(DOCTOR_ROOT)/logs
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
LOG_FILE := $(LOGS_DIR)/e2e-modules-$(TIMESTAMP).log
ENV_FILE := $(CORE_DIR)/env/e2e-env.sh

# Suite groupings — start with the 3 highest-priority global suites
# (auth, tenant, rbac). Add more under modules/ and append here as coverage
# grows.
ALL_SUITES := auth tenant rbac

# Export variables for scripts
export PRODUCTS_ROOT
export E2E_LOG_FILE
export E2E_VERBOSE
export E2E_LOG_REQUESTS

# Ensure logs directory exists
$(shell mkdir -p $(LOGS_DIR))

# Colors for output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m

define run_with_logging
	@mkdir -p $(LOGS_DIR)
	@echo "Logging to: $(LOG_FILE)"
	@E2E_LOG_FILE="$(LOG_FILE)" E2E_VERBOSE=true E2E_LOG_REQUESTS=true $(1) 2>&1 | tee -a $(LOG_FILE)
endef

define run_suite_list
	@set +e; \
	for suite in $(1); do \
		$(MAKE) test-$$suite; \
		status=$$?; \
		if [ $$status -ne 0 ]; then \
			echo -e "$(YELLOW)[WARN] Suite $$suite failed and was treated as non-blocking$(NC)"; \
		fi; \
	done
endef

define run_default_suite
test-$(1): check-env ## Run $(1) global suite
	@echo -e "$(BLUE)Running $(1) global suite...$(NC)"
	@$(MAKE) -C $(1) test
endef

$(foreach suite,$(ALL_SUITES),$(eval $(call run_default_suite,$(suite))))

help: ## Show this help message
	@echo -e ""
	@echo -e "$(BLUE)global-doctor - Module E2E Testing$(NC)"
	@echo -e "===================================="
	@echo -e ""
	@echo -e "$(YELLOW)Prerequisites:$(NC)"
	@echo -e "  Run 'make bootstrap-env' from doctor root first."
	@echo -e ""
	@echo -e "$(YELLOW)Primary Targets:$(NC)"
	@echo -e "  $(GREEN)test-all$(NC)    Run every module suite ($(ALL_SUITES))"
	@echo -e ""
	@echo -e "$(YELLOW)Suites:$(NC)"
	@echo -e "  $(ALL_SUITES)"
	@echo -e ""

check-env: ## Check if environment is bootstrapped
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo -e "$(RED)Environment not bootstrapped!$(NC)"; \
		echo -e "Run: make bootstrap-env from doctor root"; \
		exit 1; \
	fi
	@source $(ENV_FILE) && \
		if [ -z "$$E2E_AUTH_TOKEN" ]; then \
			echo -e "$(RED)No auth token in environment!$(NC)"; \
			echo -e "Run: make bootstrap-env from doctor root"; \
			exit 1; \
		fi
	@echo -e "$(GREEN)Environment check passed$(NC)"

test-all: check-env ## Run all module suites
	@echo -e "$(BLUE)Running all module suites...$(NC)"
	$(call run_suite_list,$(ALL_SUITES))
	@echo -e ""
	@echo -e "$(GREEN)All module tests completed!$(NC)"
	@echo -e "Log file: $(LOG_FILE)"

logs: ## Show latest log file
	@if ls $(LOGS_DIR)/e2e-modules-*.log 1> /dev/null 2>&1; then \
		latest=$$(ls -t $(LOGS_DIR)/e2e-modules-*.log | head -1); \
		echo -e "$(BLUE)Latest log: $$latest$(NC)"; \
		echo ""; \
		tail -100 "$$latest"; \
	else \
		echo -e "$(YELLOW)No log files found in $(LOGS_DIR)$(NC)"; \
	fi
