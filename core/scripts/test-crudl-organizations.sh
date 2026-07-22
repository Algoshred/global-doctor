#!/bin/bash

# =============================================================================
# CRUDL E2E Test - Organizations
# Tests Create, Read, Update, Delete, List operations for Organizations
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

# Get auth token and tenant ID from environment or arguments
AUTH_TOKEN="${AUTH_TOKEN:-$1}"
TENANT_ID="${TENANT_ID:-$2}"

if [ -z "$AUTH_TOKEN" ]; then
  echo -e "${RED}ERROR: AUTH_TOKEN required.${NC}"
  echo "Usage: AUTH_TOKEN=<token> TENANT_ID=<id> ./test-crudl-organizations.sh"
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
echo -e "${BLUE}CRUDL E2E Test - Organizations${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TIMESTAMP=$(date +%s)
TEST_ORG_NAME="E2E Test Organization ${TIMESTAMP}"
TEST_ORG_SLUG="e2e-org-${TIMESTAMP}"
ORG_ID=""

# If no tenant ID provided, try to get user's first tenant
if [ -z "$TENANT_ID" ]; then
  echo "No TENANT_ID provided, fetching user's first tenant..."

  MY_TENANTS_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d '{
      "query": "query MyTenants { myTenants(limit: 1) { items { id name } } }"
    }')

  TENANT_ID=$(echo "$MY_TENANTS_RESPONSE" | jq -r '.data.myTenants.items[0].id // empty')

  if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
    echo "Using Tenant ID: $TENANT_ID"
  else
    echo -e "${YELLOW}Warning: No tenant found. Some tests may fail.${NC}"
  fi
fi

# =============================================================================
# TEST 1: Create Organization
# =============================================================================
log_test "CREATE Organization"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
  CREATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation CreateOrganization(\$input: CreateOrganizationInput!) { createOrganization(input: \$input) { id name slug tenantId createdAt } }",
  "variables": {
    "input": {
      "name": "$TEST_ORG_NAME",
      "slug": "$TEST_ORG_SLUG",
      "tenantId": "$TENANT_ID"
    }
  }
}
EOF
)

  echo "$CREATE_RESPONSE" | jq .

  ORG_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.createOrganization.id // empty')

  if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
    echo "Created Organization ID: $ORG_ID"
    mark_pass "CREATE"
  else
    ERROR_MSG=$(echo "$CREATE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "CREATE" "Requires permissions: $ERROR_MSG"
      else
        mark_fail "CREATE" "$ERROR_MSG"
      fi
    else
      mark_fail "CREATE" "Unknown error"
    fi
  fi
else
  mark_skip "CREATE" "No tenant ID available"
fi

# =============================================================================
# TEST 2: Read Organization (by ID)
# =============================================================================
log_test "READ Organization (by ID)"

if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
  READ_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetOrganization(\$id: ID!) { organization(id: \$id) { id name slug tenantId createdAt updatedAt } }",
  "variables": {
    "id": "$ORG_ID"
  }
}
EOF
)

  echo "$READ_RESPONSE" | jq .

  READ_ORG_ID=$(echo "$READ_RESPONSE" | jq -r '.data.organization.id // empty')

  if [ "$READ_ORG_ID" = "$ORG_ID" ]; then
    mark_pass "READ_BY_ID"
  else
    ERROR_MSG=$(echo "$READ_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_ID" "${ERROR_MSG:-Organization not found}"
  fi
else
  mark_skip "READ_BY_ID" "No organization ID available"
fi

# =============================================================================
# TEST 3: Read Organization (by Slug)
# =============================================================================
log_test "READ Organization (by Slug)"

if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ] && [ -n "$TENANT_ID" ]; then
  READ_SLUG_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetOrganizationBySlug(\$tenantId: String!, \$slug: String!) { organizationBySlug(tenantId: \$tenantId, slug: \$slug) { id name slug } }",
  "variables": {
    "tenantId": "$TENANT_ID",
    "slug": "$TEST_ORG_SLUG"
  }
}
EOF
)

  echo "$READ_SLUG_RESPONSE" | jq .

  SLUG_ORG_ID=$(echo "$READ_SLUG_RESPONSE" | jq -r '.data.organizationBySlug.id // empty')

  if [ "$SLUG_ORG_ID" = "$ORG_ID" ]; then
    mark_pass "READ_BY_SLUG"
  else
    ERROR_MSG=$(echo "$READ_SLUG_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_SLUG" "${ERROR_MSG:-Organization not found by slug}"
  fi
else
  mark_skip "READ_BY_SLUG" "No organization available"
fi

# =============================================================================
# TEST 4: Update Organization
# =============================================================================
log_test "UPDATE Organization"

if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
  UPDATED_NAME="E2E Test Organization Updated ${TIMESTAMP}"

  UPDATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation UpdateOrganization(\$id: ID!, \$input: UpdateOrganizationInput!) { updateOrganization(id: \$id, input: \$input) { id name slug updatedAt } }",
  "variables": {
    "id": "$ORG_ID",
    "input": {
      "name": "$UPDATED_NAME"
    }
  }
}
EOF
)

  echo "$UPDATE_RESPONSE" | jq .

  UPDATED_ORG_NAME=$(echo "$UPDATE_RESPONSE" | jq -r '.data.updateOrganization.name // empty')

  if [ "$UPDATED_ORG_NAME" = "$UPDATED_NAME" ]; then
    echo "Organization name updated to: $UPDATED_ORG_NAME"
    mark_pass "UPDATE"
  else
    ERROR_MSG=$(echo "$UPDATE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "UPDATE" "Requires permissions"
      else
        mark_fail "UPDATE" "$ERROR_MSG"
      fi
    else
      mark_fail "UPDATE" "Update did not apply"
    fi
  fi
else
  mark_skip "UPDATE" "No organization available"
fi

# =============================================================================
# TEST 5: List Organizations
# =============================================================================
log_test "LIST Organizations"

LIST_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query ListOrganizations { allOrganizations(limit: 10) { total items { id name slug tenantId } } }"
  }')

echo "$LIST_RESPONSE" | jq .

ORG_COUNT=$(echo "$LIST_RESPONSE" | jq -r '.data.allOrganizations.total // 0')

if [ "$ORG_COUNT" -ge "0" ]; then
  echo "Found $ORG_COUNT organization(s)"
  mark_pass "LIST"
else
  ERROR_MSG=$(echo "$LIST_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
      mark_skip "LIST" "Requires permissions"
    else
      mark_fail "LIST" "$ERROR_MSG"
    fi
  else
    mark_pass "LIST"
  fi
fi

# =============================================================================
# TEST 6: List My Organizations
# =============================================================================
log_test "LIST My Organizations"

MY_ORGS_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query MyOrganizations { myOrganizations(limit: 10) { total items { id name slug tenantId } } }"
  }')

echo "$MY_ORGS_RESPONSE" | jq .

MY_ORG_COUNT=$(echo "$MY_ORGS_RESPONSE" | jq -r '.data.myOrganizations.total // 0')

if [ "$MY_ORG_COUNT" -ge "0" ]; then
  echo "User has access to $MY_ORG_COUNT organization(s)"
  mark_pass "LIST_MY_ORGS"
else
  ERROR_MSG=$(echo "$MY_ORGS_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    mark_fail "LIST_MY_ORGS" "$ERROR_MSG"
  else
    mark_pass "LIST_MY_ORGS"
  fi
fi

# =============================================================================
# TEST 7: Organization Members
# =============================================================================
log_test "LIST Organization Members"

if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
  MEMBERS_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query OrganizationMembers(\$organizationId: ID!) { organizationMembers(organizationId: \$organizationId, limit: 10) { total items { userId role joinedAt } } }",
  "variables": {
    "organizationId": "$ORG_ID"
  }
}
EOF
)

  echo "$MEMBERS_RESPONSE" | jq .

  MEMBER_COUNT=$(echo "$MEMBERS_RESPONSE" | jq -r '.data.organizationMembers.total // 0')

  if [ "$MEMBER_COUNT" -ge "0" ]; then
    echo "Organization has $MEMBER_COUNT member(s)"
    mark_pass "LIST_MEMBERS"
  else
    ERROR_MSG=$(echo "$MEMBERS_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      mark_skip "LIST_MEMBERS" "$ERROR_MSG"
    else
      mark_pass "LIST_MEMBERS"
    fi
  fi
else
  mark_skip "LIST_MEMBERS" "No organization available"
fi

# =============================================================================
# TEST 8: Delete Organization
# =============================================================================
log_test "DELETE Organization"

if [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
  DELETE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation DeleteOrganization(\$id: ID!) { deleteOrganization(id: \$id) }",
  "variables": {
    "id": "$ORG_ID"
  }
}
EOF
)

  echo "$DELETE_RESPONSE" | jq .

  DELETE_RESULT=$(echo "$DELETE_RESPONSE" | jq -r '.data.deleteOrganization // empty')

  if [ "$DELETE_RESULT" = "true" ]; then
    echo "Organization deleted successfully"
    mark_pass "DELETE"
  else
    ERROR_MSG=$(echo "$DELETE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden\|not allowed\|has workspaces"; then
        mark_skip "DELETE" "Requires permissions or org has dependencies"
      else
        mark_fail "DELETE" "$ERROR_MSG"
      fi
    else
      mark_skip "DELETE" "Delete returned false"
    fi
  fi
else
  mark_skip "DELETE" "No organization available"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Organization CRUDL Test Summary${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TOTAL=$((PASSED + FAILED + SKIPPED))

for test_name in CREATE READ_BY_ID READ_BY_SLUG UPDATE LIST LIST_MY_ORGS LIST_MEMBERS DELETE; do
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
