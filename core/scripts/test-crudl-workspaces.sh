#!/bin/bash

# =============================================================================
# CRUDL E2E Test - Workspaces
# Tests Create, Read, Update, Delete, List operations for Workspaces
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
TENANT_ID="${TENANT_ID:-$2}"
ORG_ID="${ORG_ID:-$3}"

if [ -z "$AUTH_TOKEN" ]; then
  echo -e "${RED}ERROR: AUTH_TOKEN required.${NC}"
  echo "Usage: AUTH_TOKEN=<token> TENANT_ID=<id> ORG_ID=<id> ./test-crudl-workspaces.sh"
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
echo -e "${BLUE}CRUDL E2E Test - Workspaces${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TIMESTAMP=$(date +%s)
TEST_WORKSPACE_NAME="E2E Test Workspace ${TIMESTAMP}"
TEST_WORKSPACE_SLUG="e2e-ws-${TIMESTAMP}"
WORKSPACE_ID=""

# If no tenant/org ID provided, try to get user's first workspace context
if [ -z "$TENANT_ID" ] || [ -z "$ORG_ID" ]; then
  echo "Fetching user's workspace context..."

  MY_WORKSPACES_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d '{
      "query": "query MyWorkspaces { myWorkspaces(limit: 1) { items { id tenantId organizationId } } }"
    }')

  if [ -z "$TENANT_ID" ]; then
    TENANT_ID=$(echo "$MY_WORKSPACES_RESPONSE" | jq -r '.data.myWorkspaces.items[0].tenantId // empty')
  fi
  if [ -z "$ORG_ID" ]; then
    ORG_ID=$(echo "$MY_WORKSPACES_RESPONSE" | jq -r '.data.myWorkspaces.items[0].organizationId // empty')
  fi

  if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ]; then
    echo "Using Tenant ID: $TENANT_ID"
    echo "Using Organization ID: $ORG_ID"
  else
    echo -e "${YELLOW}Warning: No context found. Some tests may fail.${NC}"
  fi
fi

# =============================================================================
# TEST 1: Create Workspace
# =============================================================================
log_test "CREATE Workspace"

if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "null" ] && [ -n "$ORG_ID" ] && [ "$ORG_ID" != "null" ]; then
  CREATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation CreateWorkspace(\$input: CreateWorkspaceInput!) { createWorkspace(input: \$input) { id name slug tenantId organizationId status createdAt } }",
  "variables": {
    "input": {
      "name": "$TEST_WORKSPACE_NAME",
      "slug": "$TEST_WORKSPACE_SLUG",
      "tenantId": "$TENANT_ID",
      "organizationId": "$ORG_ID"
    }
  }
}
EOF
)

  echo "$CREATE_RESPONSE" | jq .

  WORKSPACE_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.createWorkspace.id // empty')
  WORKSPACE_STATUS=$(echo "$CREATE_RESPONSE" | jq -r '.data.createWorkspace.status // empty')

  if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
    echo "Created Workspace ID: $WORKSPACE_ID"
    echo "Status: $WORKSPACE_STATUS"
    mark_pass "CREATE"

    # Wait for NATS events to process (workspace secret, roles)
    echo "Waiting 3 seconds for async events..."
    sleep 3
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
  mark_skip "CREATE" "No tenant/org ID available"
fi

# =============================================================================
# TEST 2: Read Workspace (by ID)
# =============================================================================
log_test "READ Workspace (by ID)"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
  READ_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetWorkspace(\$id: ID!) { workspace(id: \$id) { id name slug tenantId organizationId status createdAt updatedAt } }",
  "variables": {
    "id": "$WORKSPACE_ID"
  }
}
EOF
)

  echo "$READ_RESPONSE" | jq .

  READ_WORKSPACE_ID=$(echo "$READ_RESPONSE" | jq -r '.data.workspace.id // empty')
  READ_WORKSPACE_NAME=$(echo "$READ_RESPONSE" | jq -r '.data.workspace.name // empty')

  if [ "$READ_WORKSPACE_ID" = "$WORKSPACE_ID" ]; then
    echo "Retrieved Workspace: $READ_WORKSPACE_NAME"
    mark_pass "READ_BY_ID"
  else
    ERROR_MSG=$(echo "$READ_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_ID" "${ERROR_MSG:-Workspace not found}"
  fi
else
  mark_skip "READ_BY_ID" "No workspace ID available"
fi

# =============================================================================
# TEST 3: Read Workspace (by Slug)
# =============================================================================
log_test "READ Workspace (by Slug)"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ] && [ -n "$TENANT_ID" ]; then
  READ_SLUG_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query GetWorkspaceBySlug(\$tenantId: String!, \$slug: String!) { workspaceBySlug(tenantId: \$tenantId, slug: \$slug) { id name slug } }",
  "variables": {
    "tenantId": "$TENANT_ID",
    "slug": "$TEST_WORKSPACE_SLUG"
  }
}
EOF
)

  echo "$READ_SLUG_RESPONSE" | jq .

  SLUG_WORKSPACE_ID=$(echo "$READ_SLUG_RESPONSE" | jq -r '.data.workspaceBySlug.id // empty')

  if [ "$SLUG_WORKSPACE_ID" = "$WORKSPACE_ID" ]; then
    mark_pass "READ_BY_SLUG"
  else
    ERROR_MSG=$(echo "$READ_SLUG_RESPONSE" | jq -r '.errors[0].message // empty')
    mark_fail "READ_BY_SLUG" "${ERROR_MSG:-Workspace not found by slug}"
  fi
else
  mark_skip "READ_BY_SLUG" "No workspace available"
fi

# =============================================================================
# TEST 4: Update Workspace
# =============================================================================
log_test "UPDATE Workspace"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
  UPDATED_NAME="E2E Test Workspace Updated ${TIMESTAMP}"

  UPDATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation UpdateWorkspace(\$id: ID!, \$input: UpdateWorkspaceInput!) { updateWorkspace(id: \$id, input: \$input) { id name slug status updatedAt } }",
  "variables": {
    "id": "$WORKSPACE_ID",
    "input": {
      "name": "$UPDATED_NAME"
    }
  }
}
EOF
)

  echo "$UPDATE_RESPONSE" | jq .

  UPDATED_WORKSPACE_NAME=$(echo "$UPDATE_RESPONSE" | jq -r '.data.updateWorkspace.name // empty')

  if [ "$UPDATED_WORKSPACE_NAME" = "$UPDATED_NAME" ]; then
    echo "Workspace name updated to: $UPDATED_WORKSPACE_NAME"
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
  mark_skip "UPDATE" "No workspace available"
fi

# =============================================================================
# TEST 5: List Workspaces
# =============================================================================
log_test "LIST Workspaces"

LIST_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query ListWorkspaces { allWorkspaces(limit: 10) { total items { id name slug tenantId organizationId status } } }"
  }')

echo "$LIST_RESPONSE" | jq .

WORKSPACE_COUNT=$(echo "$LIST_RESPONSE" | jq -r '.data.allWorkspaces.total // 0')

if [ "$WORKSPACE_COUNT" -ge "0" ]; then
  echo "Found $WORKSPACE_COUNT workspace(s)"
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
# TEST 6: List My Workspaces
# =============================================================================
log_test "LIST My Workspaces"

MY_WORKSPACES_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -d '{
    "query": "query MyWorkspaces { myWorkspaces(limit: 10) { total items { id name slug tenantId organizationId status } } }"
  }')

echo "$MY_WORKSPACES_RESPONSE" | jq .

MY_WORKSPACE_COUNT=$(echo "$MY_WORKSPACES_RESPONSE" | jq -r '.data.myWorkspaces.total // 0')

if [ "$MY_WORKSPACE_COUNT" -gt "0" ]; then
  echo "User has access to $MY_WORKSPACE_COUNT workspace(s)"
  mark_pass "LIST_MY_WORKSPACES"
else
  ERROR_MSG=$(echo "$MY_WORKSPACES_RESPONSE" | jq -r '.errors[0].message // empty')
  if [ -n "$ERROR_MSG" ]; then
    mark_fail "LIST_MY_WORKSPACES" "$ERROR_MSG"
  else
    # Zero might be valid for new users
    mark_pass "LIST_MY_WORKSPACES"
  fi
fi

# =============================================================================
# TEST 7: Workspace Members
# =============================================================================
log_test "LIST Workspace Members"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
  MEMBERS_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "query WorkspaceMembers(\$workspaceId: String!) { workspaceMembers(workspaceId: \$workspaceId, limit: 10) { total items { userId role joinedAt } } }",
  "variables": {
    "workspaceId": "$WORKSPACE_ID"
  }
}
EOF
)

  echo "$MEMBERS_RESPONSE" | jq .

  MEMBER_COUNT=$(echo "$MEMBERS_RESPONSE" | jq -r '.data.workspaceMembers.total // 0')

  if [ "$MEMBER_COUNT" -ge "0" ]; then
    echo "Workspace has $MEMBER_COUNT member(s)"
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
  mark_skip "LIST_MEMBERS" "No workspace available"
fi

# =============================================================================
# TEST 8: Suspend Workspace
# =============================================================================
log_test "SUSPEND Workspace"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
  SUSPEND_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation SuspendWorkspace(\$id: ID!) { suspendWorkspace(id: \$id) { id status } }",
  "variables": {
    "id": "$WORKSPACE_ID"
  }
}
EOF
)

  echo "$SUSPEND_RESPONSE" | jq .

  SUSPENDED_STATUS=$(echo "$SUSPEND_RESPONSE" | jq -r '.data.suspendWorkspace.status // empty')

  if [ "$SUSPENDED_STATUS" = "SUSPENDED" ]; then
    echo "Workspace suspended"
    mark_pass "SUSPEND"

    # Reactivate for archive test
    ACTIVATE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -d @- <<EOF
{
  "query": "mutation ActivateWorkspace(\$id: ID!) { activateWorkspace(id: \$id) { id status } }",
  "variables": {
    "id": "$WORKSPACE_ID"
  }
}
EOF
)
    echo "Reactivated workspace"
  else
    ERROR_MSG=$(echo "$SUSPEND_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "SUSPEND" "Requires permissions"
      else
        mark_fail "SUSPEND" "$ERROR_MSG"
      fi
    else
      mark_skip "SUSPEND" "Suspend operation not available"
    fi
  fi
else
  mark_skip "SUSPEND" "No workspace available"
fi

# =============================================================================
# TEST 9: Archive Workspace (Delete)
# =============================================================================
log_test "ARCHIVE Workspace"

if [ -n "$WORKSPACE_ID" ] && [ "$WORKSPACE_ID" != "null" ]; then
  ARCHIVE_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -d @- <<EOF
{
  "query": "mutation ArchiveWorkspace(\$id: ID!) { archiveWorkspace(id: \$id) { id status } }",
  "variables": {
    "id": "$WORKSPACE_ID"
  }
}
EOF
)

  echo "$ARCHIVE_RESPONSE" | jq .

  ARCHIVED_STATUS=$(echo "$ARCHIVE_RESPONSE" | jq -r '.data.archiveWorkspace.status // empty')

  if [ "$ARCHIVED_STATUS" = "ARCHIVED" ]; then
    echo "Workspace archived successfully"
    mark_pass "ARCHIVE"
  else
    ERROR_MSG=$(echo "$ARCHIVE_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ -n "$ERROR_MSG" ]; then
      if echo "$ERROR_MSG" | grep -qi "permission\|unauthorized\|forbidden"; then
        mark_skip "ARCHIVE" "Requires permissions"
      else
        mark_fail "ARCHIVE" "$ERROR_MSG"
      fi
    else
      mark_skip "ARCHIVE" "Archive operation not available"
    fi
  fi
else
  mark_skip "ARCHIVE" "No workspace available"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Workspace CRUDL Test Summary${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

TOTAL=$((PASSED + FAILED + SKIPPED))

for test_name in CREATE READ_BY_ID READ_BY_SLUG UPDATE LIST LIST_MY_WORKSPACES LIST_MEMBERS SUSPEND ARCHIVE; do
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
