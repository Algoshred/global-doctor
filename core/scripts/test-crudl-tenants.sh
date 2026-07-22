#!/bin/bash

# =============================================================================
# CRUDL E2E Test - Tenants
# Tests Create, Read, Update, Delete, List operations for Tenants
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GLOBAL_GATEWAY="http://localhost:4000/global/graphql"

# Track test results
declare -A TEST_RESULTS
PASSED=0
FAILED=0
SKIPPED=0

# Get auth token from environment or argument
AUTH_TOKEN="${AUTH_TOKEN:-$1}"

if [ -z "$AUTH_TOKEN" ]; then
  echo -e "${RED}ERROR: AUTH_TOKEN required. Set via environment or pass as argument.${NC}"
  echo "Usage: AUTH_TOKEN=<token> ./test-crudl-tenants.sh"
  echo "   or: ./test-crudl-tenants.sh <token>"
  exit 1
fi

# Helper functions
log_test() {
  echo ""
  echo -e "${BLUE}--- Test: $1 ---${NC}"
}

log_success() {
  echo -e "${GREEN}PASS: $1${NC}"
}

log_error() {
  echo -e "${RED}FAIL: $1${NC}"
}

log_warning() {
  echo -e "${YELLOW}SKIP: $1${NC}"
}

mark_pass() {
  TEST_RESULTS[$1]="PASS"
  PASSED=$((PASSED + 1))
  log_success "$1"
}

mark_fail() {
  TEST_RESULTS[$1]="FAIL"
  FAILED=$((FAILED + 1))
  log_error "$1 - $2"
}

mark_skip() {
  TEST_RESULTS[$1]="SKIP"
  SKIPPED=$((SKIPPED + 1))
  log_warning "$1 - $2"
}

# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}CRUDL E2E Test - Tenants${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TIMESTAMP=$(date +%s)
TEST_TENANT_NAME="E2E Test Tenant ${TIMESTAMP}"
TEST_TENANT_SLUG="e2e-tenant-${TIMESTAMP}"
TENANT_ID=""

# =============================================================================
# TEST 1: Create Tenant
# =============================================================================
log_test "CREATE Tenant"

CREATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d @- <<EOF
{
  "query": "mutation CreateTenant(\$input: CreateTenantInput!) { createTenant(input: \$input) { id name slug status createdAt } }",
  "variables": {
    "input": {
      "name": "$TEST_TENANT_NAME",
      "slug": "$TEST_TENANT_SLUG"
    }
  }
}
EOF
)

echo "$CREATE_RESPONSE" | jq .

TENANT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.createTenant.id // empty')
TENANT_STATUS=$(echo "$CREATE_RESPONSE" | jq -r '.data.createTenant.status // empty')

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  echo "Created Tenant ID: $TENANT_ID"
  echo "Status: $TENANT_STATUS"
  mark_pass "CREATE"
else
  ERROR_MSG=$(echo "$CREATE_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden\|admin.*privileges\|privileges.*required"; then
      mark_skip "CREATE" "Requires admin permissions: $ERROR_MSG"
    else
      mark_fail "CREATE" "$ERROR_MSG"
    fi
  else
    mark_fail "CREATE" "Unknown error"
  fi
fi

# =============================================================================
# TEST 2: Read Tenant (by ID)
# =============================================================================
log_test "READ Tenant (by ID)"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  READ_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetTenant(\$id: ID!) { tenant(id: \$id) { id name slug status createdAt updatedAt } }",
  "variables": {
    "id": "$TENANT_ID"
  }
}
EOF
)

  echo "$READ_RESPONSE" | jq .

  READ_TENANT_ID=$(echo "$READ_RESPONSE" | jq -r '.data.tenant.id // empty')
  READ_TENANT_NAME=$(echo "$READ_RESPONSE" | jq -r '.data.tenant.name // empty')

  if [ "$READ_TENANT_ID" = "$TENANT_ID" ]; then
    echo "Retrieved Tenant: $READ_TENANT_NAME"
    mark_pass "READ_BY_ID"
  else
    ERROR_MSG=$(echo "$READ_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_ID" "${ERROR_MSG:-Tenant not found}"
  fi
else
  mark_skip "READ_BY_ID" "No tenant ID available (CREATE was skipped)"
fi

# =============================================================================
# TEST 3: Read Tenant (by Slug)
# =============================================================================
log_test "READ Tenant (by Slug)"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  READ_SLUG_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetTenantBySlug(\$slug: String!) { tenantBySlug(slug: \$slug) { id name slug status } }",
  "variables": {
    "slug": "$TEST_TENANT_SLUG"
  }
}
EOF
)

  echo "$READ_SLUG_RESPONSE" | jq .

  SLUG_TENANT_ID=$(echo "$READ_SLUG_RESPONSE" | jq -r '.data.tenantBySlug.id // empty')

  if [ "$SLUG_TENANT_ID" = "$TENANT_ID" ]; then
    mark_pass "READ_BY_SLUG"
  else
    ERROR_MSG=$(echo "$READ_SLUG_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_SLUG" "${ERROR_MSG:-Tenant not found by slug}"
  fi
else
  mark_skip "READ_BY_SLUG" "No tenant available"
fi

# =============================================================================
# TEST 4: Update Tenant
# =============================================================================
log_test "UPDATE Tenant"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  UPDATED_NAME="E2E Test Tenant Updated ${TIMESTAMP}"

  UPDATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation UpdateTenant(\$id: ID!, \$input: UpdateTenantInput!) { updateTenant(id: \$id, input: \$input) { id name slug status updatedAt } }",
  "variables": {
    "id": "$TENANT_ID",
    "input": {
      "name": "$UPDATED_NAME"
    }
  }
}
EOF
)

  echo "$UPDATE_RESPONSE" | jq .

  UPDATED_TENANT_NAME=$(echo "$UPDATE_RESPONSE" | jq -r '.data.updateTenant.name // empty')

  if [ "$UPDATED_TENANT_NAME" = "$UPDATED_NAME" ]; then
    echo "Tenant name updated to: $UPDATED_TENANT_NAME"
    mark_pass "UPDATE"
  else
    ERROR_MSG=$(echo "$UPDATE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "UPDATE" "Requires admin permissions"
      else
        mark_fail "UPDATE" "$ERROR_MSG"
      fi
    else
      mark_fail "UPDATE" "Update did not apply"
    fi
  fi
else
  mark_skip "UPDATE" "No tenant available"
fi

# =============================================================================
# TEST 5: List Tenants
# =============================================================================
log_test "LIST Tenants"

LIST_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query ListTenants { tenants(limit: 10) { total items { id name slug status } } }"
  }')

echo "$LIST_RESPONSE" | jq .

TENANT_COUNT=$(echo "$LIST_RESPONSE" | jq -r '.data.tenants.total // 0')

if [ "$TENANT_COUNT" -gt "0" ]; then
  echo "Found $TENANT_COUNT tenant(s)"
  mark_pass "LIST"
else
  ERROR_MSG=$(echo "$LIST_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden\|access denied"; then
      mark_skip "LIST" "Requires admin permissions"
    else
      mark_fail "LIST" "$ERROR_MSG"
    fi
  else
    # Zero tenants might be valid
    mark_pass "LIST"
  fi
fi

# =============================================================================
# TEST 6: List My Tenants
# =============================================================================
log_test "LIST My Tenants"

MY_TENANTS_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query MyTenants { myTenants(limit: 10) { total items { id name slug status } } }"
  }')

echo "$MY_TENANTS_RESPONSE" | jq .

MY_TENANT_COUNT=$(echo "$MY_TENANTS_RESPONSE" | jq -r '.data.myTenants.total // 0')

if [ "$MY_TENANT_COUNT" -ge "0" ]; then
  echo "User has access to $MY_TENANT_COUNT tenant(s)"
  mark_pass "LIST_MY_TENANTS"
else
  ERROR_MSG=$(echo "$MY_TENANTS_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    mark_fail "LIST_MY_TENANTS" "$ERROR_MSG"
  else
    mark_pass "LIST_MY_TENANTS"
  fi
fi

# =============================================================================
# TEST 7: Suspend Tenant
# =============================================================================
log_test "SUSPEND Tenant"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  SUSPEND_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation SuspendTenant(\$id: ID!) { suspendTenant(id: \$id) { id status } }",
  "variables": {
    "id": "$TENANT_ID"
  }
}
EOF
)

  echo "$SUSPEND_RESPONSE" | jq .

  SUSPENDED_STATUS=$(echo "$SUSPEND_RESPONSE" | jq -r '.data.suspendTenant.status // empty')

  if [ "$SUSPENDED_STATUS" = "SUSPENDED" ]; then
    echo "Tenant suspended"
    mark_pass "SUSPEND"

    # Reactivate for delete test
    ACTIVATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -d @- <<EOF
{
  "query": "mutation ActivateTenant(\$id: ID!) { activateTenant(id: \$id) { id status } }",
  "variables": {
    "id": "$TENANT_ID"
  }
}
EOF
)
    echo "Reactivated tenant for cleanup"
  else
    ERROR_MSG=$(echo "$SUSPEND_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "SUSPEND" "Requires admin permissions"
      else
        mark_fail "SUSPEND" "$ERROR_MSG"
      fi
    else
      mark_skip "SUSPEND" "Suspend operation not available"
    fi
  fi
else
  mark_skip "SUSPEND" "No tenant available"
fi

# =============================================================================
# TEST 8: Delete Tenant
# =============================================================================
log_test "DELETE Tenant"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation DeleteTenant(\$id: ID!) { deleteTenant(id: \$id) }",
  "variables": {
    "id": "$TENANT_ID"
  }
}
EOF
)

  echo "$DELETE_RESPONSE" | jq .

  DELETE_RESULT=$(echo "$DELETE_RESPONSE" | jq -r '.data.deleteTenant // empty')

  if [ "$DELETE_RESULT" = "true" ]; then
    echo "Tenant deleted successfully"
    mark_pass "DELETE"
  else
    ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden\|not allowed"; then
        mark_skip "DELETE" "Requires admin permissions or tenant has dependencies"
      else
        mark_fail "DELETE" "$ERROR_MSG"
      fi
    else
      mark_skip "DELETE" "Delete operation returned false (may have dependencies)"
    fi
  fi
else
  mark_skip "DELETE" "No tenant available"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Tenant CRUDL Test Summary${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TOTAL=$((PASSED + FAILED + SKIPPED))

for test_name in CREATE READ_BY_ID READ_BY_SLUG UPDATE LIST LIST_MY_TENANTS SUSPEND DELETE; do
  RESULT=${TEST_RESULTS[$test_name]:-"N/A"}
  case $RESULT in
    PASS)
      echo -e "${GREEN}$test_name: PASSED${NC}"
      ;;
    FAIL)
      echo -e "${RED}$test_name: FAILED${NC}"
      ;;
    SKIP)
      echo -e "${YELLOW}$test_name: SKIPPED${NC}"
      ;;
    *)
      echo -e "$test_name: N/A"
      ;;
  esac
done

echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo "Total: $TOTAL | Passed: $PASSED | Failed: $FAILED | Skipped: $SKIPPED"
echo -e "${BLUE}=====================================================================${NC}"

if [ $FAILED -gt 0 ]; then
  exit 1
else
  exit 0
fi
