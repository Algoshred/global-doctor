#!/bin/bash

# =============================================================================
# CRUDL E2E Test Runner
# Runs comprehensive CRUDL tests for all core resources:
# - Users (create, read, update, delete, list)
# - Tenants (create, read, update, delete, list)
# - Organizations (create, read, update, delete, list)
# - Workspaces (create, read, update, delete, list)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
GLOBAL_GATEWAY="http://localhost:4000/global/graphql"

# Track overall results
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
declare -A SUITE_RESULTS

# =============================================================================
echo ""
echo -e "${MAGENTA}======================================================================${NC}"
echo -e "${MAGENTA}     CRUDL E2E Test Suite - Core Resources${NC}"
echo -e "${MAGENTA}======================================================================${NC}"
echo ""

# Check if services are healthy
echo -e "${BLUE}Checking service health...${NC}"

GATEWAY_HEALTH=$(curl -sf http://localhost:4000/health 2>/dev/null || echo "unhealthy")
if [ "$GATEWAY_HEALTH" != "unhealthy" ]; then
  echo -e "${GREEN}Global Gateway (4000): OK${NC}"
else
  echo -e "${RED}Global Gateway (4000): UNHEALTHY${NC}"
  echo "Please ensure services are running: make e2e-start"
  exit 1
fi

AUTH_HEALTH=$(curl -sf http://localhost:4011/health 2>/dev/null || echo "unhealthy")
if [ "$AUTH_HEALTH" != "unhealthy" ]; then
  echo -e "${GREEN}Global Auth Service (4011): OK${NC}"
else
  echo -e "${YELLOW}Global Auth Service (4011): Not available${NC}"
fi

TENANT_HEALTH=$(curl -sf http://localhost:4023/health 2>/dev/null || echo "unhealthy")
if [ "$TENANT_HEALTH" != "unhealthy" ]; then
  echo -e "${GREEN}Global Tenant Service (4023): OK${NC}"
else
  echo -e "${YELLOW}Global Tenant Service (4023): Not available${NC}"
fi

echo ""

# =============================================================================
# STEP 1: Create a test user and get auth token
# =============================================================================
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Setup: Creating test user for CRUDL tests${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TIMESTAMP=$(date +%s)
SETUP_EMAIL="e2e-crudl-${TIMESTAMP}@burdenoff.com"
SETUP_USERNAME="e2ecrudl${TIMESTAMP}"
SETUP_PASSWORD="${E2E_TEST_PASSWORD:-${E2E_USER_PASSWORD:-BOff@1233210!A}}"
SETUP_NAME="E2E CRUDL Test User ${TIMESTAMP}"

SIGNUP_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "query": "mutation SignUp(\$input: SignUpInput!) { signUp(input: \$input) { accessToken refreshToken user { id email } } }",
  "variables": {
    "input": {
      "email": "$SETUP_EMAIL",
      "password": "$SETUP_PASSWORD",
      "username": "$SETUP_USERNAME",
      "name": "$SETUP_NAME"
    }
  }
}
EOF
)

AUTH_TOKEN=$(echo "$SIGNUP_RESPONSE" | jq -r '.data.signUp.accessToken // empty')
USER_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.data.signUp.user.id // empty')

if [ -n "$USER_ID" ] && { [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; }; then
  sleep 2
  VERIFICATION_TOKEN=$(docker exec "${GLOBAL_POSTGRES_CONTAINER}" psql -U "${GLOBAL_POSTGRES_USER}" -d global_auth -t -A \
    -c "SELECT token FROM email_verifications WHERE email='$SETUP_EMAIL' ORDER BY \"createdAt\" DESC LIMIT 1;" 2>/dev/null || true)

  if [ -n "$VERIFICATION_TOKEN" ]; then
    curl -s -X POST "$GLOBAL_GATEWAY" \
      -H "Content-Type: application/json" \
      -d @- <<EOF >/dev/null
{
  "query": "mutation VerifyEmail(\$token: String!) { verifyEmail(token: \$token) { success } }",
  "variables": { "token": "$VERIFICATION_TOKEN" }
}
EOF
  fi

  SIGNIN_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "query": "mutation SignIn(\$input: SignInInput!) { signIn(input: \$input) { accessToken user { id email } } }",
  "variables": {
    "input": {
      "email": "$SETUP_EMAIL",
      "password": "$SETUP_PASSWORD"
    }
  }
}
EOF
)

  AUTH_TOKEN=$(echo "$SIGNIN_RESPONSE" | jq -r '.data.signIn.accessToken // empty')
fi

if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
  echo -e "${RED}Failed to create test user. Response:${NC}"
  echo "$SIGNUP_RESPONSE" | jq .
  exit 1
fi

echo -e "${GREEN}Test user created successfully${NC}"
echo "  User ID: $USER_ID"
echo "  Email: $SETUP_EMAIL"
echo ""

# Wait for async events (workspace creation, etc.)
echo "Waiting 5 seconds for async events to process..."
sleep 5

# Get tenant and org context from user's default workspace
CONTEXT_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query MyWorkspaces { myWorkspaces(limit: 1) { items { id tenantId organizationId } } }"
  }')

TENANT_ID=$(echo "$CONTEXT_RESPONSE" | jq -r '.data.myWorkspaces.items[0].tenantId // empty')
ORG_ID=$(echo "$CONTEXT_RESPONSE" | jq -r '.data.myWorkspaces.items[0].organizationId // empty')

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  echo -e "${GREEN}Got user context:${NC}"
  echo "  Tenant ID: $TENANT_ID"
  echo "  Organization ID: $ORG_ID"
else
  echo -e "${YELLOW}Warning: Could not get user context. Some tests may be skipped.${NC}"
fi

echo ""

# Export variables for test scripts
export AUTH_TOKEN
export ADMIN_TOKEN="${ADMIN_TOKEN:-}"  # Admin token for admin operations (optional)
export TENANT_ID
export ORG_ID

# =============================================================================
# Run test suites
# =============================================================================

run_test_suite() {
  local suite_name="$1"
  local script_name="$2"

  echo ""
  echo -e "${MAGENTA}======================================================================${NC}"
  echo -e "${MAGENTA}Running: $suite_name${NC}"
  echo -e "${MAGENTA}======================================================================${NC}"
  echo ""

  if [ -x "${SCRIPT_DIR}/${script_name}" ]; then
    if "${SCRIPT_DIR}/${script_name}"; then
      SUITE_RESULTS[$suite_name]="PASS"
      echo -e "${GREEN}Suite $suite_name: COMPLETED${NC}"
    else
      SUITE_RESULTS[$suite_name]="FAIL"
      echo -e "${RED}Suite $suite_name: FAILED${NC}"
    fi
  else
    echo -e "${YELLOW}Script ${script_name} not found or not executable${NC}"
    SUITE_RESULTS[$suite_name]="SKIP"
  fi
}

# =============================================================================
# TEST SUITE 1: Users CRUDL
# =============================================================================
run_test_suite "Users CRUDL" "test-crudl-users.sh"

# =============================================================================
# TEST SUITE 2: Tenants CRUDL
# =============================================================================
run_test_suite "Tenants CRUDL" "test-crudl-tenants.sh"

# =============================================================================
# TEST SUITE 3: Organizations CRUDL
# =============================================================================
run_test_suite "Organizations CRUDL" "test-crudl-organizations.sh"

# =============================================================================
# TEST SUITE 4: Workspaces CRUDL
# =============================================================================
run_test_suite "Workspaces CRUDL" "test-crudl-workspaces.sh"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${MAGENTA}======================================================================${NC}"
echo -e "${MAGENTA}     CRUDL E2E Test Suite - Final Summary${NC}"
echo -e "${MAGENTA}======================================================================${NC}"
echo ""

SUITE_PASSED=0
SUITE_FAILED=0
SUITE_SKIPPED=0

for suite_name in "Users CRUDL" "Tenants CRUDL" "Organizations CRUDL" "Workspaces CRUDL"; do
  RESULT=${SUITE_RESULTS[$suite_name]:-"SKIP"}
  case $RESULT in
    PASS)
      echo -e "${GREEN}$suite_name: PASSED${NC}"
      SUITE_PASSED=$((SUITE_PASSED + 1))
      ;;
    FAIL)
      echo -e "${RED}$suite_name: FAILED${NC}"
      SUITE_FAILED=$((SUITE_FAILED + 1))
      ;;
    SKIP)
      echo -e "${YELLOW}$suite_name: SKIPPED${NC}"
      SUITE_SKIPPED=$((SUITE_SKIPPED + 1))
      ;;
  esac
done

echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo "Test Suites: $((SUITE_PASSED + SUITE_FAILED + SUITE_SKIPPED))"
echo "  Passed: $SUITE_PASSED"
echo "  Failed: $SUITE_FAILED"
echo "  Skipped: $SUITE_SKIPPED"
echo -e "${BLUE}=====================================================================${NC}"
echo ""
echo "Test User (for cleanup):"
echo "  User ID: $USER_ID"
echo "  Email: $SETUP_EMAIL"
echo "  Tenant ID: $TENANT_ID"
echo "  Organization ID: $ORG_ID"
echo ""

if [ $SUITE_FAILED -gt 0 ]; then
  echo -e "${RED}Some test suites failed!${NC}"
  exit 1
else
  echo -e "${GREEN}All test suites completed successfully!${NC}"
  exit 0
fi
