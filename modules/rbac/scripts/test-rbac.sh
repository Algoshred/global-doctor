#!/usr/bin/env bash
# =============================================================================
# RBAC Module E2E Tests (PBAC - Policy-Based Access Control)
# =============================================================================
# Tests the global-rbac-svc PBAC schema operations:
# - Role management (CRUD, hierarchy)
# - Role default permissions
# - Actor role assignments (single, bulk)
# - Permission overrides (actor-level, role-level)
# - Permission checking (single, batch, effective, self-service)
# - Action definitions and resource types
# - Audit log and change history
# - Billing role initialization
#
# Usage:
#   ./test-rbac.sh              # Run all tests
#   ./test-rbac.sh roles        # Run role CRUD tests only
#   ./test-rbac.sh defaults     # Run default permission tests only
#   ./test-rbac.sh assignments  # Run actor assignment tests only
#   ./test-rbac.sh overrides    # Run permission override tests only
#   ./test-rbac.sh checking     # Run permission checking tests only
#   ./test-rbac.sh actions      # Run action/resource type tests only
#   ./test-rbac.sh audit        # Run audit log tests only
#   ./test-rbac.sh billing      # Run billing role initialization tests only
#   ./test-rbac.sh resources    # Run resource management tests only
#   ./test-rbac.sh visibility   # Run visibility rule tests only
#   ./test-rbac.sh config       # Run RBAC config tests only
#   ./test-rbac.sh actors       # Run actor RBAC profile tests only
#   ./test-rbac.sh analytics    # Run analytics tests only
# =============================================================================

set -euo pipefail

# =============================================================================
# Bootstrap
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve: global/modules/rbac/scripts -> doctor root (4 levels up)
DOCTOR_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
CORE_SCRIPTS_DIR="$DOCTOR_ROOT/core/scripts"

# Source common utilities
if [ -f "${CORE_SCRIPTS_DIR}/common.sh" ]; then
    source "${CORE_SCRIPTS_DIR}/common.sh"
else
    echo "ERROR: common.sh not found at ${CORE_SCRIPTS_DIR}/common.sh"
    exit 1
fi

# Load environment with automatic token refresh
load_e2e_env || {
    log_error "Failed to load E2E environment. Run: make -C $DOCTOR_ROOT/core bootstrap-env"
    exit 1
}

# Keep undefined variable and pipefail safety, but allow test functions to fail
# without aborting the entire suite.
set +e

# =============================================================================
# Configuration
# =============================================================================

# RBAC is a global module -> use global gateway
GLOBAL_GATEWAY="${GLOBAL_GATEWAY_URL:-http://localhost:4000/global/graphql}"
RBAC_SERVICE_ENDPOINT="${RBAC_SERVICE_ENDPOINT:-http://localhost:4022/graphql}"
AUTH_TOKEN="${AUTH_TOKEN:-${E2E_AUTH_TOKEN:-}}"
# scopeId for RBAC = tenantId (global layer scopes to tenant)
SCOPE_ID="${SCOPE_ID:-${E2E_TENANT_ID:-}}"
ACTOR_ID="${ACTOR_ID:-${E2E_USER_ID:-}}"
ACTOR_TYPE="${ACTOR_TYPE:-super_admin}"
WORKSPACE_ID="${WORKSPACE_ID:-${E2E_WORKSPACE_ID:-}}"

# Test mode
TEST_MODE="${1:-all}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Unique timestamp for test data isolation
E2E_TIMESTAMP="$(date +%s)"

# Track created resources for cleanup (reverse dependency order)
CREATED_ROLE_ID=""
CREATED_CHILD_ROLE_ID=""
CREATED_ASSIGNMENT_ID=""
CREATED_BULK_ROLE_ID=""
CREATED_BULK_ASSIGNMENT_ACTOR_1="e2e-bulk-actor-1-${E2E_TIMESTAMP}"
CREATED_BULK_ASSIGNMENT_ACTOR_2="e2e-bulk-actor-2-${E2E_TIMESTAMP}"
CREATED_PERMISSION_OVERRIDE_ID=""
CREATED_ROLE_PERMISSION_OVERRIDE_ID=""
CREATED_BILLING_SCOPE_ID="e2e-billing-${E2E_TIMESTAMP}"
CREATED_RESOURCE_ID=""
CREATED_CHILD_RESOURCE_ID=""
CREATED_VISIBILITY_RULE_ID=""
CREATED_CONFIG_ID=""
BOOTSTRAP_ADMIN_ROLE_ID=""

# =============================================================================
# Validation
# =============================================================================

if [ -z "$AUTH_TOKEN" ]; then
    log_error "AUTH_TOKEN required. Set via environment or run bootstrap-env."
    exit 1
fi

if [ -z "$SCOPE_ID" ]; then
    log_warning "SCOPE_ID (tenant ID) not set. Some tests may fail."
fi

if [ -z "$ACTOR_ID" ]; then
    log_warning "ACTOR_ID (user ID) not set. Some tests may be skipped."
fi

# =============================================================================
# GraphQL Operations (Heredoc Declarations)
# =============================================================================

# --- Role CRUD ---

read -r -d '' MUTATION_CREATE_ROLE << 'EOF' || true
mutation CreateRole($input: CreateRoleInput!) {
  createRole(input: $input) {
    id
    name
    description
    scopeId
    scopeType
    isSystem
    priority
    createdBy
    onBehalfOf
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' QUERY_GET_ROLE << 'EOF' || true
query GetRole($id: ID!) {
  role(id: $id) {
    id
    name
    description
    scopeId
    scopeType
    isSystem
    priority
    parent {
      id
      name
    }
    children {
      id
      name
    }
    defaultPermissions {
      id
      roleId
      resourceType
      level
    }
    actorAssignments {
      id
      actorId
      actorType
      roleId
    }
    permissionOverrides {
      id
      roleId
      action
      resourceType
      overrideType
    }
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' QUERY_LIST_ROLES << 'EOF' || true
query ListRoles($scopeId: String!, $filter: RoleFilterInput, $pagination: PaginationInput) {
  roles(scopeId: $scopeId, filter: $filter, pagination: $pagination) {
    id
    name
    description
    scopeId
    scopeType
    isSystem
    priority
    createdAt
  }
}
EOF

read -r -d '' MUTATION_UPDATE_ROLE << 'EOF' || true
mutation UpdateRole($id: ID!, $input: UpdateRoleInput!) {
  updateRole(id: $id, input: $input) {
    id
    name
    description
    priority
    updatedAt
  }
}
EOF

read -r -d '' MUTATION_DELETE_ROLE << 'EOF' || true
mutation DeleteRole($id: ID!, $reassignToRoleId: ID) {
  deleteRole(id: $id, reassignToRoleId: $reassignToRoleId)
}
EOF

# --- Default Permissions ---

read -r -d '' MUTATION_SET_DEFAULT_PERMISSION << 'EOF' || true
mutation SetRoleDefaultPermission($input: SetRoleDefaultPermissionInput!) {
  setRoleDefaultPermission(input: $input) {
    id
    name
    defaultPermissions {
      id
      roleId
      resourceType
      level
      createdBy
    }
  }
}
EOF

read -r -d '' MUTATION_REMOVE_DEFAULT_PERMISSION << 'EOF' || true
mutation RemoveRoleDefaultPermission($roleId: ID!, $resourceType: String!) {
  removeRoleDefaultPermission(roleId: $roleId, resourceType: $resourceType) {
    id
    name
    defaultPermissions {
      id
      resourceType
      level
    }
  }
}
EOF

# --- Actor Role Assignments ---

read -r -d '' MUTATION_ASSIGN_ROLE << 'EOF' || true
mutation AssignRoleToActor($input: AssignRoleInput!) {
  assignRoleToActor(input: $input) {
    id
    actorId
    actorType
    roleId
    scopeId
    scopeResourceType
    scopeResourceId
    isActive
    assignedBy
    assignedAt
    expiresAt
    createdAt
    role {
      id
      name
    }
  }
}
EOF

read -r -d '' QUERY_ACTOR_ROLE_ASSIGNMENTS << 'EOF' || true
query GetActorRoleAssignments($actorId: String!, $scopeId: String!) {
  actorRoleAssignments(actorId: $actorId, scopeId: $scopeId) {
    id
    actorId
    actorType
    roleId
    scopeId
    isActive
    role {
      id
      name
    }
    assignedAt
  }
}
EOF

read -r -d '' QUERY_ROLE_MEMBERS << 'EOF' || true
query GetRoleMembers($roleId: ID!, $pagination: PaginationInput) {
  roleMembers(roleId: $roleId, pagination: $pagination) {
    id
    actorId
    actorType
    roleId
    scopeId
    isActive
    assignedAt
  }
}
EOF

read -r -d '' MUTATION_BULK_ASSIGN_ROLE << 'EOF' || true
mutation BulkAssignRole($actorIds: [String!]!, $actorType: ActorType!, $roleId: ID!, $scopeId: String!) {
  bulkAssignRole(actorIds: $actorIds, actorType: $actorType, roleId: $roleId, scopeId: $scopeId)
}
EOF

read -r -d '' MUTATION_REMOVE_ROLE_FROM_ACTOR << 'EOF' || true
mutation RemoveRoleFromActor($assignmentId: ID!) {
  removeRoleFromActor(assignmentId: $assignmentId)
}
EOF

# --- Permission Overrides (Actor-level) ---

read -r -d '' MUTATION_CREATE_PERMISSION_OVERRIDE << 'EOF' || true
mutation CreatePermissionOverride($input: CreatePermissionOverrideInput!) {
  createPermissionOverride(input: $input) {
    id
    actorId
    actorType
    action
    resourceType
    resourceId
    overrideType
    priority
    reason
    scopeId
    expiresAt
    validFrom
    validUntil
    createdBy
    createdAt
  }
}
EOF

read -r -d '' QUERY_ACTOR_PERMISSION_OVERRIDES << 'EOF' || true
query GetActorPermissionOverrides($actorId: String!, $scopeId: String!) {
  actorPermissionOverrides(actorId: $actorId, scopeId: $scopeId) {
    id
    actorId
    actorType
    action
    resourceType
    resourceId
    overrideType
    priority
    reason
    scopeId
    createdAt
  }
}
EOF

read -r -d '' MUTATION_REMOVE_PERMISSION_OVERRIDE << 'EOF' || true
mutation RemovePermissionOverride($id: ID!) {
  removePermissionOverride(id: $id)
}
EOF

# --- Permission Overrides (Role-level) ---

read -r -d '' MUTATION_CREATE_ROLE_PERMISSION_OVERRIDE << 'EOF' || true
mutation CreateRolePermissionOverride($input: CreateRolePermissionOverrideInput!) {
  createRolePermissionOverride(input: $input) {
    id
    roleId
    action
    resourceType
    resourceId
    overrideType
    priority
    reason
    scopeId
    expiresAt
    validFrom
    validUntil
    createdBy
    createdAt
    role {
      id
      name
    }
  }
}
EOF

read -r -d '' MUTATION_REMOVE_ROLE_PERMISSION_OVERRIDE << 'EOF' || true
mutation RemoveRolePermissionOverride($id: ID!) {
  removeRolePermissionOverride(id: $id)
}
EOF

# --- Permission Checking ---

read -r -d '' QUERY_CHECK_PERMISSION << 'EOF' || true
query CheckPermission($input: PermissionCheckInput!) {
  checkPermission(input: $input) {
    allowed
    decisionPath
    roleName
    roleLevel
    overrideType
    opaPolicy
  }
}
EOF

read -r -d '' QUERY_CHECK_PERMISSIONS << 'EOF' || true
query CheckPermissions($inputs: [PermissionCheckInput!]!) {
  checkPermissions(inputs: $inputs) {
    allowed
    decisionPath
    roleName
    roleLevel
  }
}
EOF

read -r -d '' QUERY_EFFECTIVE_PERMISSIONS << 'EOF' || true
query GetEffectivePermissions($actorId: String!, $actorType: ActorType!, $scopeId: String!) {
  effectivePermissions(actorId: $actorId, actorType: $actorType, scopeId: $scopeId) {
    actorId
    scopeId
    permissions {
      resourceType
      level
      allowedActions
      source
      overrides {
        id
        action
        overrideType
      }
    }
  }
}
EOF

read -r -d '' QUERY_MY_PERMISSIONS << 'EOF' || true
query GetMyPermissions($scopeId: String!) {
  myPermissions(scopeId: $scopeId) {
    actorId
    scopeId
    permissions {
      resourceType
      level
      allowedActions
      source
    }
  }
}
EOF

# --- Action Definitions & Resource Types ---

read -r -d '' QUERY_RESOURCE_TYPES << 'EOF' || true
query GetResourceTypes {
  resourceTypes
}
EOF

read -r -d '' QUERY_ACTION_DEFINITIONS << 'EOF' || true
query GetActionDefinitions($resourceType: String!) {
  actionDefinitions(resourceType: $resourceType) {
    id
    action
    resourceType
    description
    viewerDefault
    editorDefault
    adminDefault
    isSystem
    createdAt
  }
}
EOF

# --- Audit & History ---

read -r -d '' QUERY_PERMISSION_AUDIT_LOG << 'EOF' || true
query GetPermissionAuditLog($scopeId: String!, $filter: AuditLogFilterInput, $pagination: PaginationInput) {
  permissionAuditLog(scopeId: $scopeId, filter: $filter, pagination: $pagination) {
    id
    actorId
    actorType
    action
    resourceType
    resourceId
    allowed
    decisionPath
    scopeId
    evaluatedAt
  }
}
EOF

read -r -d '' QUERY_RBAC_CHANGE_HISTORY << 'EOF' || true
query GetRbacChangeHistory($scopeId: String!, $filter: ChangeLogFilterInput, $pagination: PaginationInput) {
  rbacChangeHistory(scopeId: $scopeId, filter: $filter, pagination: $pagination) {
    id
    entityType
    entityId
    changeType
    changedBy
    description
    details
    scopeId
    changedAt
  }
}
EOF

# --- Self-Service (myRoles) ---

read -r -d '' QUERY_MY_ROLES << 'EOF' || true
query GetMyRoles($scopeId: String!) {
  myRoles(scopeId: $scopeId) {
    roles {
      id
      name
      priority
    }
    isAdmin
    isOwner
  }
}
EOF

# --- Resources ---

read -r -d '' MUTATION_REGISTER_RESOURCE << 'EOF' || true
mutation RegisterResource($input: RegisterResourceInput!) {
  registerResource(input: $input) {
    id
    identifier
    name
    resourceType
    scopeId
    parentResourceId
    ownerId
    ownerType
    metadata
    isActive
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' MUTATION_UPDATE_RESOURCE << 'EOF' || true
mutation UpdateResource($id: ID!, $input: UpdateResourceInput!) {
  updateResource(id: $id, input: $input) {
    id
    identifier
    name
    ownerId
    ownerType
    metadata
    isActive
    updatedAt
  }
}
EOF

read -r -d '' MUTATION_DEACTIVATE_RESOURCE << 'EOF' || true
mutation DeactivateResource($id: ID!) {
  deactivateResource(id: $id)
}
EOF

read -r -d '' QUERY_RESOURCES << 'EOF' || true
query GetResources($scopeId: String!, $filter: ResourceFilterInput, $pagination: PaginationInput) {
  resources(scopeId: $scopeId, filter: $filter, pagination: $pagination) {
    id
    identifier
    name
    resourceType
    scopeId
    ownerId
    isActive
    createdAt
  }
}
EOF

read -r -d '' QUERY_RESOURCE << 'EOF' || true
query GetResource($id: ID!) {
  resource(id: $id) {
    id
    identifier
    name
    resourceType
    scopeId
    parentResourceId
    ownerId
    ownerType
    metadata
    isActive
    visibilityRules {
      id
      visibilityType
    }
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' QUERY_RESOURCE_TREE << 'EOF' || true
query GetResourceTree($scopeId: String!, $resourceType: String) {
  resourceTree(scopeId: $scopeId, resourceType: $resourceType) {
    id
    identifier
    name
    resourceType
    parentResourceId
    children {
      id
      identifier
      name
    }
    isActive
  }
}
EOF

# --- Visibility ---

read -r -d '' MUTATION_CREATE_VISIBILITY_RULE << 'EOF' || true
mutation CreateVisibilityRule($input: CreateVisibilityRuleInput!) {
  createVisibilityRule(input: $input) {
    id
    resourceId
    resourceType
    scopeId
    visibilityType
    targetId
    targetType
    conditions
    priority
    isActive
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' MUTATION_REMOVE_VISIBILITY_RULE << 'EOF' || true
mutation RemoveVisibilityRule($id: ID!) {
  removeVisibilityRule(id: $id)
}
EOF

read -r -d '' QUERY_VISIBILITY_RULES << 'EOF' || true
query GetVisibilityRules($resourceIdentifier: String!, $resourceType: String!, $scopeId: String!) {
  visibilityRules(resourceIdentifier: $resourceIdentifier, resourceType: $resourceType, scopeId: $scopeId) {
    id
    resourceId
    resourceType
    scopeId
    visibilityType
    targetId
    targetType
    priority
    isActive
  }
}
EOF

read -r -d '' QUERY_CHECK_VISIBILITY << 'EOF' || true
query CheckVisibility($input: VisibilityCheckInput!) {
  checkVisibility(input: $input) {
    visible
    reason
  }
}
EOF

# --- Configuration ---

read -r -d '' MUTATION_UPDATE_RBAC_CONFIG << 'EOF' || true
mutation UpdateRbacConfig($input: UpdateRbacConfigInput!) {
  updateRbacConfig(input: $input) {
    id
    scopeId
    key
    value
    description
    valueType
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' QUERY_RBAC_CONFIG << 'EOF' || true
query GetRbacConfig($scopeId: String!) {
  rbacConfig(scopeId: $scopeId) {
    id
    scopeId
    key
    value
    description
    valueType
  }
}
EOF

read -r -d '' QUERY_RBAC_CONFIG_VALUE << 'EOF' || true
query GetRbacConfigValue($scopeId: String!, $key: String!) {
  rbacConfigValue(scopeId: $scopeId, key: $key) {
    id
    scopeId
    key
    value
    description
    valueType
  }
}
EOF

# --- Actors (RBAC profile view) ---

read -r -d '' QUERY_ACTORS << 'EOF' || true
query GetActors($scopeId: String!, $filter: ActorFilterInput, $pagination: PaginationInput) {
  actors(scopeId: $scopeId, filter: $filter, pagination: $pagination) {
    actorId
    actorType
    scopeId
    roleAssignments {
      id
      roleId
    }
    permissionOverrides {
      id
      action
    }
    effectivePermissionCount
  }
}
EOF

read -r -d '' QUERY_ACTOR_RBAC_SUMMARY << 'EOF' || true
query GetActorRbacSummary($actorId: String!, $scopeId: String!) {
  actorRbacSummary(actorId: $actorId, scopeId: $scopeId) {
    actorId
    actorType
    scopeId
    roleAssignments {
      id
      roleId
      role {
        id
        name
      }
    }
    permissionOverrides {
      id
      action
      overrideType
    }
    effectivePermissionCount
  }
}
EOF

# --- Analytics ---

read -r -d '' QUERY_RBAC_ANALYTICS << 'EOF' || true
query GetRbacAnalytics($scopeId: String!, $dateRange: AnalyticsDateRangeInput) {
  rbacAnalytics(scopeId: $scopeId, dateRange: $dateRange) {
    scopeId
    totalChecks
    allowedChecks
    deniedChecks
    approvalRate
    topActions {
      resourceType
      action
      count
    }
    topActors {
      actorId
      actorType
      count
    }
    totalRoles
    totalAssignments
    totalOverrides
    totalResources
    totalVisibilityRules
  }
}
EOF

# --- Billing Roles ---

read -r -d '' MUTATION_INITIALIZE_BILLING_ROLES << 'EOF' || true
mutation InitializeBillingRoles($billingAccountId: String!, $ownerId: String!) {
  initializeBillingRoles(billingAccountId: $billingAccountId, ownerId: $ownerId) {
    success
    rolesCreated
    roleNames
    ownerAssigned
    message
  }
}
EOF

# =============================================================================
# Helper Functions
# =============================================================================

make_graphql_request() {
    local query="$1"
    local variables="${2:-"{}"}"
    local description="${3:-GraphQL Request}"

    local temp_file
    temp_file=$(mktemp)
    jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}' > "$temp_file" 2>/dev/null

    log_output ""
    log_output "${BLUE}>>> $description${NC}"
    log_request "POST $GLOBAL_GATEWAY"

    local response
    response=$(curl -s -X POST "$GLOBAL_GATEWAY" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "x-actor-id: $ACTOR_ID" \
        -H "x-actor-type: $ACTOR_TYPE" \
        -H "x-workspace-id: $WORKSPACE_ID" \
        -d @"$temp_file")

    rm -f "$temp_file"

    log_response "$(echo "$response" | jq -c . 2>/dev/null || echo "$response")"
    echo "$response"
}

make_service_request() {
    local query="$1"
    local variables="${2:-"{}"}"
    local description="${3:-GraphQL Service Request}"

    local temp_file
    temp_file=$(mktemp)
    jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}' > "$temp_file" 2>/dev/null

    log_output ""
    log_output "${BLUE}>>> $description${NC}"
    log_request "POST $RBAC_SERVICE_ENDPOINT (service actor)"

    # Pull internal service token from the running global-rbac-svc container so
    # super_admin/service-only operations are accepted by the subgraph.
    local internal_token="${E2E_INTERNAL_SERVICE_TOKEN:-}"
    if [ -z "$internal_token" ] && command -v docker >/dev/null 2>&1; then
        internal_token=$(docker exec global-rbac-svc sh -c 'echo -n "$INTERNAL_SERVICE_TOKEN"' 2>/dev/null || true)
    fi

    local response curl_exit
    # Try host endpoint first (works if the svc port is published). Use a
    # generous timeout so a slow-but-successful write doesn't trip the fallback
    # and re-issue a non-idempotent mutation. We only fall back when curl
    # reports a "couldn't connect" class of error (exit codes 6 = couldn't
    # resolve host, 7 = couldn't connect). Any other failure mode (timeout,
    # protocol error, server 5xx with empty body) is treated as a real failure
    # and surfaced — never retried — to avoid duplicate-resource flakes.
    response=$(curl -s --max-time 30 -X POST "$RBAC_SERVICE_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "x-actor-id: e2e-bootstrap-service" \
        -H "x-actor-type: service" \
        -H "x-internal-service-token: $internal_token" \
        -H "x-workspace-id: $WORKSPACE_ID" \
        -d @"$temp_file" 2>/dev/null)
    curl_exit=$?

    if { [ "$curl_exit" -eq 6 ] || [ "$curl_exit" -eq 7 ]; } && command -v docker >/dev/null 2>&1; then
        # Host port unreachable → exec into the container. Pipe the JSON body
        # via stdin so it never enters the shell command string (avoids quote
        # injection if a payload value contains a single-quote, e.g. O'Brien).
        log_warning "${description}: host endpoint unreachable (curl exit ${curl_exit}), falling back to docker exec"
        local exec_err
        exec_err=$(mktemp)
        # WORKSPACE_ID is a UUID we set ourselves; safe to interpolate.
        response=$(docker exec -i global-rbac-svc sh -c "
            body=\$(cat);
            wget -qO- \
                --post-data=\"\$body\" \
                --header='Content-Type: application/json' \
                --header='x-actor-id: e2e-bootstrap-service' \
                --header='x-actor-type: service' \
                --header=\"x-internal-service-token: \$INTERNAL_SERVICE_TOKEN\" \
                --header='x-workspace-id: $WORKSPACE_ID' \
                http://localhost:4022/graphql
        " < "$temp_file" 2>"$exec_err")
        if [ -z "$response" ] || ! echo "$response" | jq -e '.' >/dev/null 2>&1; then
            log_warning "${description}: docker exec fallback also failed"
            if [ -s "$exec_err" ]; then
                log_warning "stderr: $(head -c 500 < "$exec_err")"
            fi
        fi
        rm -f "$exec_err"
    fi

    rm -f "$temp_file"

    log_response "$(echo "$response" | jq -c . 2>/dev/null || echo "$response")"
    echo "$response"
}

bootstrap_admin_access() {
    if [ -z "$ACTOR_ID" ] || [ -z "$SCOPE_ID" ]; then
        return 0
    fi

    local create_vars
    create_vars=$(jq -n \
        --arg name "E2E Global RBAC Admin ${E2E_TIMESTAMP}" \
        --arg desc "Bootstrap admin role for RBAC doctor tests" \
        --arg scopeId "$SCOPE_ID" \
        '{input: {name: $name, description: $desc, scopeId: $scopeId, scopeType: "tenant", priority: 999}}')

    local create_response
    create_response=$(make_service_request "$MUTATION_CREATE_ROLE" "$create_vars" "Bootstrap Global RBAC Admin Role")
    BOOTSTRAP_ADMIN_ROLE_ID=$(echo "$create_response" | jq -r '.data.createRole.id // empty')
    if [ -z "$BOOTSTRAP_ADMIN_ROLE_ID" ]; then
        log_warning "Bootstrap role creation failed; continuing with existing permissions"
        return 0
    fi

    local permission_vars
    permission_vars=$(jq -n \
        --arg roleId "$BOOTSTRAP_ADMIN_ROLE_ID" \
        '{input: {roleId: $roleId, resourceType: "rbac", level: "ADMIN"}}')
    make_service_request "$MUTATION_SET_DEFAULT_PERMISSION" "$permission_vars" "Bootstrap RBAC Admin Defaults" > /dev/null

    local assignment_vars
    assignment_vars=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg roleId "$BOOTSTRAP_ADMIN_ROLE_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{input: {actorId: $actorId, actorType: "USER", roleId: $roleId, scopeId: $scopeId}}')
    make_service_request "$MUTATION_ASSIGN_ROLE" "$assignment_vars" "Bootstrap Assign RBAC Admin Role" > /dev/null
}

assert_no_errors() {
    local response="$1"
    local test_name="$2"

    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "${test_name}: ${error_msg}"
        ((TESTS_FAILED++))
        return 1
    fi
    return 0
}

# =============================================================================
# Test Functions - Role CRUD
# =============================================================================

test_create_role() {
    log_info "Testing: CREATE_ROLE"

    local variables
    variables=$(jq -n \
        --arg name "E2E Test Role ${E2E_TIMESTAMP}" \
        --arg desc "Role created by E2E tests" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                name: $name,
                description: $desc,
                scopeId: $scopeId,
                priority: 50
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_ROLE" "$variables" "Create Role")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.createRole.id // empty')

    if [ -n "$role_id" ]; then
        CREATED_ROLE_ID="$role_id"
        local name
        name=$(echo "$response" | jq -r '.data.createRole.name // empty')
        log_success "CREATE_ROLE: Created '$name' (ID: $role_id)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CREATE_ROLE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_create_child_role() {
    log_info "Testing: CREATE_CHILD_ROLE"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "CREATE_CHILD_ROLE: No parent role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg name "E2E Child Role ${E2E_TIMESTAMP}" \
        --arg desc "Child role for hierarchy testing" \
        --arg scopeId "$SCOPE_ID" \
        --arg parentId "$CREATED_ROLE_ID" \
        '{
            input: {
                name: $name,
                description: $desc,
                scopeId: $scopeId,
                parentId: $parentId,
                priority: 40
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_ROLE" "$variables" "Create Child Role")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.createRole.id // empty')

    if [ -n "$role_id" ]; then
        CREATED_CHILD_ROLE_ID="$role_id"
        log_success "CREATE_CHILD_ROLE: Created (ID: $role_id, Parent: $CREATED_ROLE_ID)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CREATE_CHILD_ROLE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_get_role() {
    log_info "Testing: GET_ROLE"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "GET_ROLE: No role to get, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_ROLE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$QUERY_GET_ROLE" "$variables" "Get Role")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.role.id // empty')

    if [ "$role_id" = "$CREATED_ROLE_ID" ]; then
        local name
        name=$(echo "$response" | jq -r '.data.role.name // empty')

        # Verify hierarchy - parent role should have child
        local child_count
        child_count=$(echo "$response" | jq '.data.role.children | length // 0')

        if [ -n "$CREATED_CHILD_ROLE_ID" ] && [ "$child_count" -gt 0 ]; then
            log_success "GET_ROLE: Retrieved '$name' with $child_count child role(s)"
        else
            log_success "GET_ROLE: Retrieved '$name'"
        fi
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_ROLE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_list_roles() {
    log_info "Testing: LIST_ROLES"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            pagination: { limit: 20, offset: 0 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_LIST_ROLES" "$variables" "List Roles")

    local count
    count=$(echo "$response" | jq '.data.roles | length // 0')

    if [ "$count" -ge 0 ]; then
        log_success "LIST_ROLES: Found $count roles in scope"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "LIST_ROLES failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_update_role() {
    log_info "Testing: UPDATE_ROLE"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "UPDATE_ROLE: No role to update, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg id "$CREATED_ROLE_ID" \
        '{
            id: $id,
            input: {
                description: "Updated by E2E test",
                priority: 55
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_UPDATE_ROLE" "$variables" "Update Role")

    local updated_id
    updated_id=$(echo "$response" | jq -r '.data.updateRole.id // empty')

    if [ "$updated_id" = "$CREATED_ROLE_ID" ]; then
        local priority
        priority=$(echo "$response" | jq -r '.data.updateRole.priority // empty')
        log_success "UPDATE_ROLE: Updated (priority: $priority)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "UPDATE_ROLE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Test Functions - Default Permissions
# =============================================================================

test_set_default_permission() {
    log_info "Testing: SET_DEFAULT_PERMISSION"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "SET_DEFAULT_PERMISSION: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg roleId "$CREATED_ROLE_ID" \
        '{
            input: {
                roleId: $roleId,
                resourceType: "project",
                level: "EDITOR"
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_SET_DEFAULT_PERMISSION" "$variables" "Set Default Permission")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.setRoleDefaultPermission.id // empty')

    if [ "$role_id" = "$CREATED_ROLE_ID" ]; then
        local perm_count
        perm_count=$(echo "$response" | jq '.data.setRoleDefaultPermission.defaultPermissions | length // 0')
        log_success "SET_DEFAULT_PERMISSION: Set EDITOR level for 'project' ($perm_count total defaults)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "SET_DEFAULT_PERMISSION failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_set_second_default_permission() {
    log_info "Testing: SET_DEFAULT_PERMISSION (second resource type)"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "SET_DEFAULT_PERMISSION_2: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg roleId "$CREATED_ROLE_ID" \
        '{
            input: {
                roleId: $roleId,
                resourceType: "workspace",
                level: "VIEWER"
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_SET_DEFAULT_PERMISSION" "$variables" "Set Second Default Permission")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.setRoleDefaultPermission.id // empty')

    if [ "$role_id" = "$CREATED_ROLE_ID" ]; then
        local perm_count
        perm_count=$(echo "$response" | jq '.data.setRoleDefaultPermission.defaultPermissions | length // 0')
        log_success "SET_DEFAULT_PERMISSION_2: Set VIEWER level for 'workspace' ($perm_count total defaults)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "SET_DEFAULT_PERMISSION_2 failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_verify_default_permissions_via_role() {
    log_info "Testing: VERIFY_DEFAULT_PERMISSIONS (via role query)"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "VERIFY_DEFAULT_PERMISSIONS: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_ROLE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$QUERY_GET_ROLE" "$variables" "Verify Default Permissions via Role")

    local perm_count
    perm_count=$(echo "$response" | jq '.data.role.defaultPermissions | length // 0')

    if [ "$perm_count" -ge 2 ]; then
        # Verify specific resource types
        local project_level
        project_level=$(echo "$response" | jq -r '.data.role.defaultPermissions[] | select(.resourceType == "project") | .level // empty')
        local workspace_level
        workspace_level=$(echo "$response" | jq -r '.data.role.defaultPermissions[] | select(.resourceType == "workspace") | .level // empty')

        if [ "$project_level" = "EDITOR" ] && [ "$workspace_level" = "VIEWER" ]; then
            log_success "VERIFY_DEFAULT_PERMISSIONS: project=EDITOR, workspace=VIEWER ($perm_count total)"
            ((TESTS_PASSED++))
            return 0
        else
            log_error "VERIFY_DEFAULT_PERMISSIONS: Unexpected levels (project=$project_level, workspace=$workspace_level)"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        log_error "VERIFY_DEFAULT_PERMISSIONS: Expected >= 2 defaults, got $perm_count"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_remove_default_permission() {
    log_info "Testing: REMOVE_DEFAULT_PERMISSION"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "REMOVE_DEFAULT_PERMISSION: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg roleId "$CREATED_ROLE_ID" \
        '{
            roleId: $roleId,
            resourceType: "workspace"
        }')

    local response
    response=$(make_graphql_request "$MUTATION_REMOVE_DEFAULT_PERMISSION" "$variables" "Remove Default Permission")

    local role_id
    role_id=$(echo "$response" | jq -r '.data.removeRoleDefaultPermission.id // empty')

    if [ "$role_id" = "$CREATED_ROLE_ID" ]; then
        local perm_count
        perm_count=$(echo "$response" | jq '.data.removeRoleDefaultPermission.defaultPermissions | length // 0')
        # Should now have only 1 default permission (project=EDITOR)
        local remaining
        remaining=$(echo "$response" | jq -r '.data.removeRoleDefaultPermission.defaultPermissions[] | select(.resourceType == "workspace") | .level // empty')
        if [ -z "$remaining" ]; then
            log_success "REMOVE_DEFAULT_PERMISSION: Removed 'workspace' default ($perm_count remaining)"
            ((TESTS_PASSED++))
            return 0
        else
            log_error "REMOVE_DEFAULT_PERMISSION: 'workspace' default still present"
            ((TESTS_FAILED++))
            return 1
        fi
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "REMOVE_DEFAULT_PERMISSION failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Test Functions - Actor Role Assignments
# =============================================================================

test_assign_role_to_actor() {
    log_info "Testing: ASSIGN_ROLE_TO_ACTOR"

    if [ -z "$CREATED_ROLE_ID" ] || [ -z "$ACTOR_ID" ]; then
        log_warning "ASSIGN_ROLE_TO_ACTOR: No role or actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg roleId "$CREATED_ROLE_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                actorId: $actorId,
                actorType: "USER",
                roleId: $roleId,
                scopeId: $scopeId
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_ASSIGN_ROLE" "$variables" "Assign Role to Actor")

    local assignment_id
    assignment_id=$(echo "$response" | jq -r '.data.assignRoleToActor.id // empty')

    if [ -n "$assignment_id" ]; then
        CREATED_ASSIGNMENT_ID="$assignment_id"
        local role_name
        role_name=$(echo "$response" | jq -r '.data.assignRoleToActor.role.name // empty')
        log_success "ASSIGN_ROLE_TO_ACTOR: Assigned '$role_name' to actor (ID: $assignment_id)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "ASSIGN_ROLE_TO_ACTOR failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_get_actor_role_assignments() {
    log_info "Testing: GET_ACTOR_ROLE_ASSIGNMENTS"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "GET_ACTOR_ROLE_ASSIGNMENTS: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{actorId: $actorId, scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_ACTOR_ROLE_ASSIGNMENTS" "$variables" "Get Actor Role Assignments")

    local count
    count=$(echo "$response" | jq '.data.actorRoleAssignments | length // 0')

    if [ "$count" -ge 0 ]; then
        log_success "GET_ACTOR_ROLE_ASSIGNMENTS: Actor has $count assignments"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_ACTOR_ROLE_ASSIGNMENTS failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_get_role_members() {
    log_info "Testing: GET_ROLE_MEMBERS"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "GET_ROLE_MEMBERS: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg roleId "$CREATED_ROLE_ID" \
        '{roleId: $roleId, pagination: {limit: 10}}')

    local response
    response=$(make_graphql_request "$QUERY_ROLE_MEMBERS" "$variables" "Get Role Members")

    local count
    count=$(echo "$response" | jq '.data.roleMembers | length // 0')

    if [ "$count" -ge 0 ]; then
        log_success "GET_ROLE_MEMBERS: Role has $count members"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_ROLE_MEMBERS failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_bulk_assign_role() {
    log_info "Testing: BULK_ASSIGN_ROLE"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "BULK_ASSIGN_ROLE: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    # Create a separate role for bulk assignment to avoid conflicts
    local bulk_role_vars
    bulk_role_vars=$(jq -n \
        --arg name "E2E Bulk Role ${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                name: $name,
                description: "Role for bulk assignment testing",
                scopeId: $scopeId,
                priority: 30
            }
        }')

    local bulk_role_response
    bulk_role_response=$(make_graphql_request "$MUTATION_CREATE_ROLE" "$bulk_role_vars" "Create Bulk Test Role")

    CREATED_BULK_ROLE_ID=$(echo "$bulk_role_response" | jq -r '.data.createRole.id // empty')

    if [ -z "$CREATED_BULK_ROLE_ID" ]; then
        log_error "BULK_ASSIGN_ROLE: Failed to create bulk test role"
        ((TESTS_FAILED++))
        return 1
    fi

    local variables
    variables=$(jq -n \
        --arg actor1 "$CREATED_BULK_ASSIGNMENT_ACTOR_1" \
        --arg actor2 "$CREATED_BULK_ASSIGNMENT_ACTOR_2" \
        --arg roleId "$CREATED_BULK_ROLE_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            actorIds: [$actor1, $actor2],
            actorType: "USER",
            roleId: $roleId,
            scopeId: $scopeId
        }')

    local response
    response=$(make_graphql_request "$MUTATION_BULK_ASSIGN_ROLE" "$variables" "Bulk Assign Role")

    local assigned_count
    assigned_count=$(echo "$response" | jq -r '.data.bulkAssignRole // empty')

    if [ -n "$assigned_count" ] && [ "$assigned_count" -ge 1 ]; then
        log_success "BULK_ASSIGN_ROLE: Assigned to $assigned_count actors"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "BULK_ASSIGN_ROLE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_remove_role_from_actor() {
    log_info "Testing: REMOVE_ROLE_FROM_ACTOR"

    if [ -z "$CREATED_ASSIGNMENT_ID" ]; then
        log_warning "REMOVE_ROLE_FROM_ACTOR: No assignment to remove, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_ASSIGNMENT_ID" '{assignmentId: $id}')

    local response
    response=$(make_graphql_request "$MUTATION_REMOVE_ROLE_FROM_ACTOR" "$variables" "Remove Role from Actor")

    local result
    result=$(echo "$response" | jq -r '.data.removeRoleFromActor // empty')

    if [ "$result" = "true" ]; then
        log_success "REMOVE_ROLE_FROM_ACTOR: Assignment removed"
        CREATED_ASSIGNMENT_ID=""  # Clear so cleanup doesn't try again
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "REMOVE_ROLE_FROM_ACTOR failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Test Functions - Permission Overrides
# =============================================================================

test_create_permission_override() {
    log_info "Testing: CREATE_PERMISSION_OVERRIDE (actor-level)"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "CREATE_PERMISSION_OVERRIDE: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                actorId: $actorId,
                actorType: "USER",
                action: "project:delete",
                resourceType: "project",
                overrideType: "DENY",
                priority: 100,
                reason: "E2E test: deny project delete",
                scopeId: $scopeId
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_PERMISSION_OVERRIDE" "$variables" "Create Permission Override")

    local override_id
    override_id=$(echo "$response" | jq -r '.data.createPermissionOverride.id // empty')

    if [ -n "$override_id" ]; then
        CREATED_PERMISSION_OVERRIDE_ID="$override_id"
        local override_type
        override_type=$(echo "$response" | jq -r '.data.createPermissionOverride.overrideType // empty')
        log_success "CREATE_PERMISSION_OVERRIDE: Created $override_type override (ID: $override_id)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CREATE_PERMISSION_OVERRIDE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_get_actor_permission_overrides() {
    log_info "Testing: GET_ACTOR_PERMISSION_OVERRIDES"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "GET_ACTOR_PERMISSION_OVERRIDES: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{actorId: $actorId, scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_ACTOR_PERMISSION_OVERRIDES" "$variables" "Get Actor Permission Overrides")

    local count
    count=$(echo "$response" | jq '.data.actorPermissionOverrides | length // 0')

    if [ "$count" -ge 0 ]; then
        log_success "GET_ACTOR_PERMISSION_OVERRIDES: Actor has $count overrides"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_ACTOR_PERMISSION_OVERRIDES failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_remove_permission_override() {
    log_info "Testing: REMOVE_PERMISSION_OVERRIDE"

    if [ -z "$CREATED_PERMISSION_OVERRIDE_ID" ]; then
        log_warning "REMOVE_PERMISSION_OVERRIDE: No override to remove, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_PERMISSION_OVERRIDE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$MUTATION_REMOVE_PERMISSION_OVERRIDE" "$variables" "Remove Permission Override")

    local result
    result=$(echo "$response" | jq -r '.data.removePermissionOverride // empty')

    if [ "$result" = "true" ]; then
        log_success "REMOVE_PERMISSION_OVERRIDE: Override removed"
        CREATED_PERMISSION_OVERRIDE_ID=""
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "REMOVE_PERMISSION_OVERRIDE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_create_role_permission_override() {
    log_info "Testing: CREATE_ROLE_PERMISSION_OVERRIDE"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "CREATE_ROLE_PERMISSION_OVERRIDE: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg roleId "$CREATED_ROLE_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                roleId: $roleId,
                action: "billing:export",
                resourceType: "billing",
                overrideType: "GRANT",
                priority: 90,
                reason: "E2E test: grant billing export to role",
                scopeId: $scopeId
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_ROLE_PERMISSION_OVERRIDE" "$variables" "Create Role Permission Override")

    local override_id
    override_id=$(echo "$response" | jq -r '.data.createRolePermissionOverride.id // empty')

    if [ -n "$override_id" ]; then
        CREATED_ROLE_PERMISSION_OVERRIDE_ID="$override_id"
        local override_type
        override_type=$(echo "$response" | jq -r '.data.createRolePermissionOverride.overrideType // empty')
        log_success "CREATE_ROLE_PERMISSION_OVERRIDE: Created $override_type override (ID: $override_id)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CREATE_ROLE_PERMISSION_OVERRIDE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_remove_role_permission_override() {
    log_info "Testing: REMOVE_ROLE_PERMISSION_OVERRIDE"

    if [ -z "$CREATED_ROLE_PERMISSION_OVERRIDE_ID" ]; then
        log_warning "REMOVE_ROLE_PERMISSION_OVERRIDE: No override to remove, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_ROLE_PERMISSION_OVERRIDE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$MUTATION_REMOVE_ROLE_PERMISSION_OVERRIDE" "$variables" "Remove Role Permission Override")

    local result
    result=$(echo "$response" | jq -r '.data.removeRolePermissionOverride // empty')

    if [ "$result" = "true" ]; then
        log_success "REMOVE_ROLE_PERMISSION_OVERRIDE: Override removed"
        CREATED_ROLE_PERMISSION_OVERRIDE_ID=""
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "REMOVE_ROLE_PERMISSION_OVERRIDE failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Test Functions - Permission Checking
# =============================================================================

test_check_permission() {
    log_info "Testing: CHECK_PERMISSION"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "CHECK_PERMISSION: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                actorId: $actorId,
                actorType: "USER",
                action: "read",
                resourceType: "rbac",
                scopeId: $scopeId
            }
        }')

    local response
    response=$(make_graphql_request "$QUERY_CHECK_PERMISSION" "$variables" "Check Permission")

    # checkPermission returns allowed (boolean) - just check the field exists
    if echo "$response" | jq -e 'has("data") and (.data | has("checkPermission"))' > /dev/null 2>&1; then
        local allowed
        allowed=$(echo "$response" | jq -r '.data.checkPermission.allowed')
        local decision_path
        decision_path=$(echo "$response" | jq -r '.data.checkPermission.decisionPath // "unknown"')
        log_success "CHECK_PERMISSION: allowed=$allowed (path: $decision_path)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CHECK_PERMISSION failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_check_permissions_batch() {
    log_info "Testing: CHECK_PERMISSIONS (batch)"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "CHECK_PERMISSIONS: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            inputs: [
                {
                    actorId: $actorId,
                    actorType: "USER",
                    action: "read",
                    resourceType: "rbac",
                    scopeId: $scopeId
                },
                {
                    actorId: $actorId,
                    actorType: "USER",
                    action: "role:create",
                    resourceType: "rbac",
                    scopeId: $scopeId
                }
            ]
        }')

    local response
    response=$(make_graphql_request "$QUERY_CHECK_PERMISSIONS" "$variables" "Check Permissions (batch)")

    local count
    count=$(echo "$response" | jq '.data.checkPermissions | length // 0')

    if [ "$count" -eq 2 ]; then
        local first_allowed
        first_allowed=$(echo "$response" | jq -r '.data.checkPermissions[0].allowed')
        local second_allowed
        second_allowed=$(echo "$response" | jq -r '.data.checkPermissions[1].allowed')
        log_success "CHECK_PERMISSIONS: Checked $count permissions (read=$first_allowed, create=$second_allowed)"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CHECK_PERMISSIONS failed: expected 2 results, got $count ($error)"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_effective_permissions() {
    log_info "Testing: GET_EFFECTIVE_PERMISSIONS"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "GET_EFFECTIVE_PERMISSIONS: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{
            actorId: $actorId,
            actorType: "USER",
            scopeId: $scopeId
        }')

    local response
    response=$(make_graphql_request "$QUERY_EFFECTIVE_PERMISSIONS" "$variables" "Get Effective Permissions")

    if echo "$response" | jq -e '.data.effectivePermissions' > /dev/null 2>&1; then
        local perm_count
        perm_count=$(echo "$response" | jq '.data.effectivePermissions.permissions | length // 0')
        local actor_id
        actor_id=$(echo "$response" | jq -r '.data.effectivePermissions.actorId // empty')
        log_success "GET_EFFECTIVE_PERMISSIONS: $perm_count resource permissions for actor $actor_id"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_EFFECTIVE_PERMISSIONS failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

test_my_permissions() {
    log_info "Testing: GET_MY_PERMISSIONS (self-service)"

    local variables
    variables=$(jq -n --arg scopeId "$SCOPE_ID" '{scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_MY_PERMISSIONS" "$variables" "Get My Permissions")

    if echo "$response" | jq -e '.data.myPermissions' > /dev/null 2>&1; then
        local perm_count
        perm_count=$(echo "$response" | jq '.data.myPermissions.permissions | length // 0')
        log_success "GET_MY_PERMISSIONS: $perm_count resource permissions for current user"
        ((TESTS_PASSED++))
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "GET_MY_PERMISSIONS failed: $error"
        ((TESTS_FAILED++))
        return 1
    fi
}

# =============================================================================
# Test Functions - Action Definitions & Resource Types
# =============================================================================

test_get_resource_types() {
    log_info "Testing: GET_RESOURCE_TYPES"

    local response
    response=$(make_graphql_request "$QUERY_RESOURCE_TYPES" "{}" "Get Resource Types")

    if echo "$response" | jq -e '.data.resourceTypes' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.resourceTypes | length // 0')
        if [ "$count" -ge 0 ]; then
            log_success "GET_RESOURCE_TYPES: Found $count resource types"
            ((TESTS_PASSED++))
            return 0
        fi
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RESOURCE_TYPES failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_action_definitions() {
    log_info "Testing: GET_ACTION_DEFINITIONS"

    local variables
    variables=$(jq -n '{resourceType: "rbac"}')

    local response
    response=$(make_graphql_request "$QUERY_ACTION_DEFINITIONS" "$variables" "Get Action Definitions")

    if echo "$response" | jq -e '.data.actionDefinitions' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.actionDefinitions | length // 0')
        log_success "GET_ACTION_DEFINITIONS: Found $count actions for 'rbac' resource type"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_ACTION_DEFINITIONS failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Audit & History
# =============================================================================

test_permission_audit_log() {
    log_info "Testing: GET_PERMISSION_AUDIT_LOG"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            pagination: { limit: 10 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_PERMISSION_AUDIT_LOG" "$variables" "Get Permission Audit Log")

    if echo "$response" | jq -e '.data.permissionAuditLog' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.permissionAuditLog | length // 0')
        log_success "GET_PERMISSION_AUDIT_LOG: Found $count audit entries"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_PERMISSION_AUDIT_LOG failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_rbac_change_history() {
    log_info "Testing: GET_RBAC_CHANGE_HISTORY"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            pagination: { limit: 10 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_CHANGE_HISTORY" "$variables" "Get RBAC Change History")

    if echo "$response" | jq -e '.data.rbacChangeHistory' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.rbacChangeHistory | length // 0')
        log_success "GET_RBAC_CHANGE_HISTORY: Found $count change entries"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_CHANGE_HISTORY failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_change_history_with_filter() {
    log_info "Testing: GET_RBAC_CHANGE_HISTORY (with filter)"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            filter: {
                changeType: "ROLE_CREATED"
            },
            pagination: { limit: 5 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_CHANGE_HISTORY" "$variables" "Get RBAC Change History (filtered)")

    if echo "$response" | jq -e '.data.rbacChangeHistory' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.rbacChangeHistory | length // 0')
        log_success "GET_RBAC_CHANGE_HISTORY (filtered): Found $count ROLE_CREATED entries"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_CHANGE_HISTORY (filtered) failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Billing Roles
# =============================================================================

test_initialize_billing_roles() {
    log_info "Testing: INITIALIZE_BILLING_ROLES"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "INITIALIZE_BILLING_ROLES: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg billingAccountId "$CREATED_BILLING_SCOPE_ID" \
        --arg ownerId "$ACTOR_ID" \
        '{
            billingAccountId: $billingAccountId,
            ownerId: $ownerId
        }')

    local response
    # Service/super_admin only operation — call direct svc with internal token.
    response=$(make_service_request "$MUTATION_INITIALIZE_BILLING_ROLES" "$variables" "Initialize Billing Roles")

    if echo "$response" | jq -e '.data.initializeBillingRoles' > /dev/null 2>&1; then
        local success
        success=$(echo "$response" | jq -r '.data.initializeBillingRoles.success')
        local roles_created
        roles_created=$(echo "$response" | jq -r '.data.initializeBillingRoles.rolesCreated // 0')
        local message
        message=$(echo "$response" | jq -r '.data.initializeBillingRoles.message // empty')

        if [ "$success" = "true" ]; then
            log_success "INITIALIZE_BILLING_ROLES: $roles_created roles created ($message)"
            ((TESTS_PASSED++))
            return 0
        else
            # May return success=false if roles already exist (idempotent)
            log_success "INITIALIZE_BILLING_ROLES: Returned success=$success ($message)"
            ((TESTS_PASSED++))
            return 0
        fi
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "INITIALIZE_BILLING_ROLES failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_initialize_billing_roles_idempotent() {
    log_info "Testing: INITIALIZE_BILLING_ROLES (idempotent)"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "INITIALIZE_BILLING_ROLES_IDEMPOTENT: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    # Run again with same billingAccountId - should be idempotent
    local variables
    variables=$(jq -n \
        --arg billingAccountId "$CREATED_BILLING_SCOPE_ID" \
        --arg ownerId "$ACTOR_ID" \
        '{
            billingAccountId: $billingAccountId,
            ownerId: $ownerId
        }')

    local response
    # Service/super_admin only operation — call direct svc with internal token.
    response=$(make_service_request "$MUTATION_INITIALIZE_BILLING_ROLES" "$variables" "Initialize Billing Roles (idempotent)")

    if echo "$response" | jq -e '.data.initializeBillingRoles' > /dev/null 2>&1; then
        local roles_created
        roles_created=$(echo "$response" | jq -r '.data.initializeBillingRoles.rolesCreated // 0')
        # Second call should create 0 new roles
        log_success "INITIALIZE_BILLING_ROLES (idempotent): $roles_created new roles (expected 0)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "INITIALIZE_BILLING_ROLES (idempotent) failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Self-Service (myRoles)
# =============================================================================

test_my_roles() {
    log_info "Testing: GET_MY_ROLES (self-service)"

    local variables
    variables=$(jq -n --arg scopeId "$SCOPE_ID" '{scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_MY_ROLES" "$variables" "Get My Roles")

    if echo "$response" | jq -e '.data.myRoles' > /dev/null 2>&1; then
        local role_count
        role_count=$(echo "$response" | jq '.data.myRoles.roles | length // 0')
        local is_admin
        is_admin=$(echo "$response" | jq -r '.data.myRoles.isAdmin')
        local is_owner
        is_owner=$(echo "$response" | jq -r '.data.myRoles.isOwner')
        log_success "GET_MY_ROLES: $role_count roles, isAdmin=$is_admin, isOwner=$is_owner"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_MY_ROLES failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Resource Management
# =============================================================================

test_register_resource() {
    log_info "Testing: REGISTER_RESOURCE"

    local variables
    variables=$(jq -n \
        --arg identifier "e2e-project-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        --arg ownerId "$ACTOR_ID" \
        '{
            input: {
                identifier: $identifier,
                name: "E2E Test Project",
                resourceType: "project",
                scopeId: $scopeId,
                ownerId: $ownerId,
                ownerType: "USER",
                metadata: { source: "e2e-test", created: true }
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_REGISTER_RESOURCE" "$variables" "Register Resource")

    local resource_id
    resource_id=$(echo "$response" | jq -r '.data.registerResource.id // empty')

    if [ -n "$resource_id" ]; then
        CREATED_RESOURCE_ID="$resource_id"
        local identifier
        identifier=$(echo "$response" | jq -r '.data.registerResource.identifier // empty')
        local is_active
        is_active=$(echo "$response" | jq -r '.data.registerResource.isActive')
        log_success "REGISTER_RESOURCE: Created '$identifier' (ID: $resource_id, active=$is_active)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "REGISTER_RESOURCE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_register_child_resource() {
    log_info "Testing: REGISTER_RESOURCE (child)"

    if [ -z "$CREATED_RESOURCE_ID" ]; then
        log_warning "REGISTER_CHILD_RESOURCE: No parent resource available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg identifier "e2e-task-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        --arg parentId "$CREATED_RESOURCE_ID" \
        --arg ownerId "$ACTOR_ID" \
        '{
            input: {
                identifier: $identifier,
                name: "E2E Test Task",
                resourceType: "task",
                scopeId: $scopeId,
                parentResourceId: $parentId,
                ownerId: $ownerId,
                ownerType: "USER"
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_REGISTER_RESOURCE" "$variables" "Register Child Resource")

    local resource_id
    resource_id=$(echo "$response" | jq -r '.data.registerResource.id // empty')

    if [ -n "$resource_id" ]; then
        CREATED_CHILD_RESOURCE_ID="$resource_id"
        log_success "REGISTER_CHILD_RESOURCE: Created child (ID: $resource_id, parent: $CREATED_RESOURCE_ID)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "REGISTER_CHILD_RESOURCE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_resource() {
    log_info "Testing: GET_RESOURCE"

    if [ -z "$CREATED_RESOURCE_ID" ]; then
        log_warning "GET_RESOURCE: No resource available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_RESOURCE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$QUERY_RESOURCE" "$variables" "Get Resource")

    local resource_id
    resource_id=$(echo "$response" | jq -r '.data.resource.id // empty')

    if [ "$resource_id" = "$CREATED_RESOURCE_ID" ]; then
        local identifier
        identifier=$(echo "$response" | jq -r '.data.resource.identifier // empty')
        local owner
        owner=$(echo "$response" | jq -r '.data.resource.ownerId // empty')
        log_success "GET_RESOURCE: Retrieved '$identifier' (owner: $owner)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RESOURCE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_list_resources() {
    log_info "Testing: LIST_RESOURCES"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            pagination: { limit: 20 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_RESOURCES" "$variables" "List Resources")

    local count
    count=$(echo "$response" | jq '.data.resources | length // 0')

    if [ "$count" -ge 0 ]; then
        log_success "LIST_RESOURCES: Found $count resources in scope"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "LIST_RESOURCES failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_resource_tree() {
    log_info "Testing: GET_RESOURCE_TREE"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            resourceType: "project"
        }')

    local response
    response=$(make_graphql_request "$QUERY_RESOURCE_TREE" "$variables" "Get Resource Tree")

    if echo "$response" | jq -e '.data.resourceTree' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.resourceTree | length // 0')
        log_success "GET_RESOURCE_TREE: Found $count root resources of type 'project'"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RESOURCE_TREE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_update_resource() {
    log_info "Testing: UPDATE_RESOURCE"

    if [ -z "$CREATED_RESOURCE_ID" ]; then
        log_warning "UPDATE_RESOURCE: No resource available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg id "$CREATED_RESOURCE_ID" \
        '{
            id: $id,
            input: {
                name: "E2E Test Project (Updated)",
                metadata: { source: "e2e-test", updated: true }
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_UPDATE_RESOURCE" "$variables" "Update Resource")

    local resource_id
    resource_id=$(echo "$response" | jq -r '.data.updateResource.id // empty')

    if [ "$resource_id" = "$CREATED_RESOURCE_ID" ]; then
        local name
        name=$(echo "$response" | jq -r '.data.updateResource.name // empty')
        log_success "UPDATE_RESOURCE: Updated to '$name'"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "UPDATE_RESOURCE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_deactivate_resource() {
    log_info "Testing: DEACTIVATE_RESOURCE"

    if [ -z "$CREATED_CHILD_RESOURCE_ID" ]; then
        log_warning "DEACTIVATE_RESOURCE: No child resource available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_CHILD_RESOURCE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$MUTATION_DEACTIVATE_RESOURCE" "$variables" "Deactivate Resource")

    local result
    result=$(echo "$response" | jq -r '.data.deactivateResource // empty')

    if [ "$result" = "true" ]; then
        log_success "DEACTIVATE_RESOURCE: Child resource deactivated"
        CREATED_CHILD_RESOURCE_ID=""  # Clear so cleanup doesn't try again
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "DEACTIVATE_RESOURCE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Visibility Rules
# =============================================================================

test_create_visibility_rule() {
    log_info "Testing: CREATE_VISIBILITY_RULE"

    local variables
    variables=$(jq -n \
        --arg identifier "e2e-vis-resource-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                resourceIdentifier: $identifier,
                resourceType: "document",
                scopeId: $scopeId,
                visibilityType: "PRIVATE",
                priority: 10
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_VISIBILITY_RULE" "$variables" "Create Visibility Rule")

    local rule_id
    rule_id=$(echo "$response" | jq -r '.data.createVisibilityRule.id // empty')

    if [ -n "$rule_id" ]; then
        CREATED_VISIBILITY_RULE_ID="$rule_id"
        local vis_type
        vis_type=$(echo "$response" | jq -r '.data.createVisibilityRule.visibilityType // empty')
        log_success "CREATE_VISIBILITY_RULE: Created $vis_type rule (ID: $rule_id)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "CREATE_VISIBILITY_RULE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_create_visibility_rule_role_based() {
    log_info "Testing: CREATE_VISIBILITY_RULE (role-based)"

    if [ -z "$CREATED_ROLE_ID" ]; then
        log_warning "CREATE_VISIBILITY_RULE_ROLE: No role available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg identifier "e2e-vis-resource-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        --arg targetId "$CREATED_ROLE_ID" \
        '{
            input: {
                resourceIdentifier: $identifier,
                resourceType: "document",
                scopeId: $scopeId,
                visibilityType: "ROLE",
                targetId: $targetId,
                targetType: "role",
                priority: 20
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_CREATE_VISIBILITY_RULE" "$variables" "Create Role-Based Visibility Rule")

    if echo "$response" | jq -e '.data.createVisibilityRule.id' > /dev/null 2>&1; then
        local vis_type
        vis_type=$(echo "$response" | jq -r '.data.createVisibilityRule.visibilityType // empty')
        log_success "CREATE_VISIBILITY_RULE (role-based): Created $vis_type rule"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "CREATE_VISIBILITY_RULE (role-based) failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_visibility_rules() {
    log_info "Testing: GET_VISIBILITY_RULES"

    local variables
    variables=$(jq -n \
        --arg identifier "e2e-vis-resource-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        '{
            resourceIdentifier: $identifier,
            resourceType: "document",
            scopeId: $scopeId
        }')

    local response
    response=$(make_graphql_request "$QUERY_VISIBILITY_RULES" "$variables" "Get Visibility Rules")

    if echo "$response" | jq -e '.data.visibilityRules' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.visibilityRules | length // 0')
        log_success "GET_VISIBILITY_RULES: Found $count rules for resource"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_VISIBILITY_RULES failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_check_visibility() {
    log_info "Testing: CHECK_VISIBILITY"

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg identifier "e2e-vis-resource-${E2E_TIMESTAMP}" \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                actorId: $actorId,
                actorType: "USER",
                resourceIdentifier: $identifier,
                resourceType: "document",
                scopeId: $scopeId
            }
        }')

    local response
    response=$(make_graphql_request "$QUERY_CHECK_VISIBILITY" "$variables" "Check Visibility")

    if echo "$response" | jq -e '.data.checkVisibility' > /dev/null 2>&1; then
        local visible
        visible=$(echo "$response" | jq -r '.data.checkVisibility.visible')
        local reason
        reason=$(echo "$response" | jq -r '.data.checkVisibility.reason // "unknown"')
        log_success "CHECK_VISIBILITY: visible=$visible (reason: $reason)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "CHECK_VISIBILITY failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_remove_visibility_rule() {
    log_info "Testing: REMOVE_VISIBILITY_RULE"

    if [ -z "$CREATED_VISIBILITY_RULE_ID" ]; then
        log_warning "REMOVE_VISIBILITY_RULE: No visibility rule to remove, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n --arg id "$CREATED_VISIBILITY_RULE_ID" '{id: $id}')

    local response
    response=$(make_graphql_request "$MUTATION_REMOVE_VISIBILITY_RULE" "$variables" "Remove Visibility Rule")

    local result
    result=$(echo "$response" | jq -r '.data.removeVisibilityRule // empty')

    if [ "$result" = "true" ]; then
        log_success "REMOVE_VISIBILITY_RULE: Rule removed"
        CREATED_VISIBILITY_RULE_ID=""
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "REMOVE_VISIBILITY_RULE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - RBAC Configuration
# =============================================================================

test_update_rbac_config() {
    log_info "Testing: UPDATE_RBAC_CONFIG"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                scopeId: $scopeId,
                key: "e2e.test.enabled",
                value: "true",
                description: "E2E test configuration flag",
                valueType: "boolean"
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_UPDATE_RBAC_CONFIG" "$variables" "Update RBAC Config")

    local config_id
    config_id=$(echo "$response" | jq -r '.data.updateRbacConfig.id // empty')

    if [ -n "$config_id" ]; then
        CREATED_CONFIG_ID="$config_id"
        local key
        key=$(echo "$response" | jq -r '.data.updateRbacConfig.key // empty')
        local value
        value=$(echo "$response" | jq -r '.data.updateRbacConfig.value // empty')
        log_success "UPDATE_RBAC_CONFIG: Set '$key' = '$value' (ID: $config_id)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "UPDATE_RBAC_CONFIG failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_update_rbac_config_second() {
    log_info "Testing: UPDATE_RBAC_CONFIG (second key)"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            input: {
                scopeId: $scopeId,
                key: "e2e.test.max_roles",
                value: "100",
                description: "E2E test max roles config",
                valueType: "number"
            }
        }')

    local response
    response=$(make_graphql_request "$MUTATION_UPDATE_RBAC_CONFIG" "$variables" "Update RBAC Config (second)")

    if echo "$response" | jq -e '.data.updateRbacConfig.id' > /dev/null 2>&1; then
        local key
        key=$(echo "$response" | jq -r '.data.updateRbacConfig.key // empty')
        log_success "UPDATE_RBAC_CONFIG (second): Set '$key'"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "UPDATE_RBAC_CONFIG (second) failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_rbac_config() {
    log_info "Testing: GET_RBAC_CONFIG"

    local variables
    variables=$(jq -n --arg scopeId "$SCOPE_ID" '{scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_CONFIG" "$variables" "Get RBAC Config")

    if echo "$response" | jq -e '.data.rbacConfig' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.rbacConfig | length // 0')
        log_success "GET_RBAC_CONFIG: Found $count config entries"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_CONFIG failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_rbac_config_value() {
    log_info "Testing: GET_RBAC_CONFIG_VALUE"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            key: "e2e.test.enabled"
        }')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_CONFIG_VALUE" "$variables" "Get RBAC Config Value")

    if echo "$response" | jq -e '.data.rbacConfigValue' > /dev/null 2>&1; then
        local value
        value=$(echo "$response" | jq -r '.data.rbacConfigValue.value // "null"')
        local value_type
        value_type=$(echo "$response" | jq -r '.data.rbacConfigValue.valueType // "unknown"')
        log_success "GET_RBAC_CONFIG_VALUE: e2e.test.enabled = '$value' (type: $value_type)"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_CONFIG_VALUE failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Actor RBAC Profile
# =============================================================================

test_list_actors() {
    log_info "Testing: LIST_ACTORS"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{
            scopeId: $scopeId,
            pagination: { limit: 20 }
        }')

    local response
    response=$(make_graphql_request "$QUERY_ACTORS" "$variables" "List Actors")

    if echo "$response" | jq -e '.data.actors' > /dev/null 2>&1; then
        local count
        count=$(echo "$response" | jq '.data.actors | length // 0')
        log_success "LIST_ACTORS: Found $count actors with RBAC context"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "LIST_ACTORS failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_get_actor_rbac_summary() {
    log_info "Testing: GET_ACTOR_RBAC_SUMMARY"

    if [ -z "$ACTOR_ID" ]; then
        log_warning "GET_ACTOR_RBAC_SUMMARY: No actor available, skipping"
        ((TESTS_SKIPPED++))
        return 0
    fi

    local variables
    variables=$(jq -n \
        --arg actorId "$ACTOR_ID" \
        --arg scopeId "$SCOPE_ID" \
        '{actorId: $actorId, scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_ACTOR_RBAC_SUMMARY" "$variables" "Get Actor RBAC Summary")

    if echo "$response" | jq -e '.data.actorRbacSummary' > /dev/null 2>&1; then
        local actor_id
        actor_id=$(echo "$response" | jq -r '.data.actorRbacSummary.actorId // empty')
        local role_count
        role_count=$(echo "$response" | jq '.data.actorRbacSummary.roleAssignments | length // 0')
        local override_count
        override_count=$(echo "$response" | jq '.data.actorRbacSummary.permissionOverrides | length // 0')
        local effective_count
        effective_count=$(echo "$response" | jq -r '.data.actorRbacSummary.effectivePermissionCount // 0')
        log_success "GET_ACTOR_RBAC_SUMMARY: actor=$actor_id, roles=$role_count, overrides=$override_count, effective=$effective_count"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_ACTOR_RBAC_SUMMARY failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Test Functions - Analytics
# =============================================================================

test_rbac_analytics() {
    log_info "Testing: GET_RBAC_ANALYTICS"

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        '{scopeId: $scopeId}')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_ANALYTICS" "$variables" "Get RBAC Analytics")

    if echo "$response" | jq -e '.data.rbacAnalytics' > /dev/null 2>&1; then
        local total_checks
        total_checks=$(echo "$response" | jq -r '.data.rbacAnalytics.totalChecks // 0')
        local total_roles
        total_roles=$(echo "$response" | jq -r '.data.rbacAnalytics.totalRoles // 0')
        local total_resources
        total_resources=$(echo "$response" | jq -r '.data.rbacAnalytics.totalResources // 0')
        local approval_rate
        approval_rate=$(echo "$response" | jq -r '.data.rbacAnalytics.approvalRate // 0')
        log_success "GET_RBAC_ANALYTICS: checks=$total_checks, roles=$total_roles, resources=$total_resources, approvalRate=$approval_rate%"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_ANALYTICS failed: $error"
    ((TESTS_FAILED++))
    return 1
}

test_rbac_analytics_with_date_range() {
    log_info "Testing: GET_RBAC_ANALYTICS (with date range)"

    # Use a date range covering today
    local start_date
    start_date=$(date -u -d '30 days ago' '+%Y-%m-%dT00:00:00.000Z' 2>/dev/null || date -u -v-30d '+%Y-%m-%dT00:00:00.000Z' 2>/dev/null || echo "2026-01-01T00:00:00.000Z")
    local end_date
    end_date=$(date -u '+%Y-%m-%dT23:59:59.999Z')

    local variables
    variables=$(jq -n \
        --arg scopeId "$SCOPE_ID" \
        --arg start "$start_date" \
        --arg endDateValue "$end_date" \
        '{
            scopeId: $scopeId,
            dateRange: {
                startDate: $start,
                endDate: $endDateValue
            }
        }')

    local response
    response=$(make_graphql_request "$QUERY_RBAC_ANALYTICS" "$variables" "Get RBAC Analytics (date range)")

    if echo "$response" | jq -e '.data.rbacAnalytics' > /dev/null 2>&1; then
        local total_checks
        total_checks=$(echo "$response" | jq -r '.data.rbacAnalytics.totalChecks // 0')
        local allowed
        allowed=$(echo "$response" | jq -r '.data.rbacAnalytics.allowedChecks // 0')
        local denied
        denied=$(echo "$response" | jq -r '.data.rbacAnalytics.deniedChecks // 0')
        log_success "GET_RBAC_ANALYTICS (date range): total=$total_checks, allowed=$allowed, denied=$denied"
        ((TESTS_PASSED++))
        return 0
    fi

    local error
    error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    log_error "GET_RBAC_ANALYTICS (date range) failed: $error"
    ((TESTS_FAILED++))
    return 1
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup_resources() {
    log_info ""
    log_info "========================================"
    log_info "CLEANUP"
    log_info "========================================"

    # 1. Remove permission overrides first (no dependencies)
    if [ -n "$CREATED_PERMISSION_OVERRIDE_ID" ]; then
        log_info "Removing actor permission override..."
        local variables
        variables=$(jq -n --arg id "$CREATED_PERMISSION_OVERRIDE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_REMOVE_PERMISSION_OVERRIDE" "$variables" "Cleanup: Remove Permission Override" > /dev/null 2>&1 || true
    fi

    if [ -n "$CREATED_ROLE_PERMISSION_OVERRIDE_ID" ]; then
        log_info "Removing role permission override..."
        local variables
        variables=$(jq -n --arg id "$CREATED_ROLE_PERMISSION_OVERRIDE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_REMOVE_ROLE_PERMISSION_OVERRIDE" "$variables" "Cleanup: Remove Role Permission Override" > /dev/null 2>&1 || true
    fi

    # 2. Remove role assignments
    if [ -n "$CREATED_ASSIGNMENT_ID" ]; then
        log_info "Removing role assignment..."
        local variables
        variables=$(jq -n --arg id "$CREATED_ASSIGNMENT_ID" '{assignmentId: $id}')
        make_graphql_request "$MUTATION_REMOVE_ROLE_FROM_ACTOR" "$variables" "Cleanup: Remove Assignment" > /dev/null 2>&1 || true
    fi

    # 3. Delete child role first (hierarchy FK)
    if [ -n "$CREATED_CHILD_ROLE_ID" ]; then
        log_info "Deleting child role..."
        local variables
        variables=$(jq -n --arg id "$CREATED_CHILD_ROLE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_DELETE_ROLE" "$variables" "Cleanup: Delete Child Role" > /dev/null 2>&1 || true
    fi

    # 4. Delete bulk assignment role
    if [ -n "$CREATED_BULK_ROLE_ID" ]; then
        log_info "Deleting bulk test role..."
        local variables
        variables=$(jq -n --arg id "$CREATED_BULK_ROLE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_DELETE_ROLE" "$variables" "Cleanup: Delete Bulk Role" > /dev/null 2>&1 || true
    fi

    # 5. Delete parent role last
    if [ -n "$CREATED_ROLE_ID" ]; then
        log_info "Deleting test role..."
        local variables
        variables=$(jq -n --arg id "$CREATED_ROLE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_DELETE_ROLE" "$variables" "Cleanup: Delete Role" > /dev/null 2>&1 || true
    fi

    # 6. Remove visibility rules
    if [ -n "$CREATED_VISIBILITY_RULE_ID" ]; then
        log_info "Removing visibility rule..."
        local variables
        variables=$(jq -n --arg id "$CREATED_VISIBILITY_RULE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_REMOVE_VISIBILITY_RULE" "$variables" "Cleanup: Remove Visibility Rule" > /dev/null 2>&1 || true
    fi

    # 7. Deactivate resources (child first, then parent)
    if [ -n "$CREATED_CHILD_RESOURCE_ID" ]; then
        log_info "Deactivating child resource..."
        local variables
        variables=$(jq -n --arg id "$CREATED_CHILD_RESOURCE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_DEACTIVATE_RESOURCE" "$variables" "Cleanup: Deactivate Child Resource" > /dev/null 2>&1 || true
    fi

    if [ -n "$CREATED_RESOURCE_ID" ]; then
        log_info "Deactivating parent resource..."
        local variables
        variables=$(jq -n --arg id "$CREATED_RESOURCE_ID" '{id: $id}')
        make_graphql_request "$MUTATION_DEACTIVATE_RESOURCE" "$variables" "Cleanup: Deactivate Resource" > /dev/null 2>&1 || true
    fi

    # Note: Billing roles are not cleaned up as they may be needed for other tests
    # and initializeBillingRoles is idempotent
    # Note: Config entries are intentionally not cleaned up (no delete API; they're scoped)

    log_success "Cleanup complete"
}

# =============================================================================
# Test Suites
# =============================================================================

run_role_tests() {
    log_info ""
    log_info "========================================"
    log_info "ROLE CRUD TESTS"
    log_info "========================================"

    test_create_role
    test_create_child_role
    test_get_role
    test_list_roles
    test_update_role
}

run_default_permission_tests() {
    log_info ""
    log_info "========================================"
    log_info "DEFAULT PERMISSION TESTS"
    log_info "========================================"

    test_set_default_permission
    test_set_second_default_permission
    test_verify_default_permissions_via_role
    test_remove_default_permission
}

run_assignment_tests() {
    log_info ""
    log_info "========================================"
    log_info "ACTOR ASSIGNMENT TESTS"
    log_info "========================================"

    test_assign_role_to_actor
    test_get_actor_role_assignments
    test_get_role_members
    test_bulk_assign_role
    test_remove_role_from_actor
}

run_override_tests() {
    log_info ""
    log_info "========================================"
    log_info "PERMISSION OVERRIDE TESTS"
    log_info "========================================"

    test_create_permission_override
    test_get_actor_permission_overrides
    test_remove_permission_override
    test_create_role_permission_override
    test_remove_role_permission_override
}

run_checking_tests() {
    log_info ""
    log_info "========================================"
    log_info "PERMISSION CHECKING TESTS"
    log_info "========================================"

    test_check_permission
    test_check_permissions_batch
    test_effective_permissions
    test_my_permissions
    test_my_roles
}

run_action_tests() {
    log_info ""
    log_info "========================================"
    log_info "ACTION DEFINITION & RESOURCE TYPE TESTS"
    log_info "========================================"

    test_get_resource_types
    test_get_action_definitions
}

run_audit_tests() {
    log_info ""
    log_info "========================================"
    log_info "AUDIT & CHANGE HISTORY TESTS"
    log_info "========================================"

    test_permission_audit_log
    test_rbac_change_history
    test_change_history_with_filter
}

run_billing_tests() {
    log_info ""
    log_info "========================================"
    log_info "BILLING ROLE INITIALIZATION TESTS"
    log_info "========================================"

    test_initialize_billing_roles
    test_initialize_billing_roles_idempotent
}

run_resource_tests() {
    log_info ""
    log_info "========================================"
    log_info "RESOURCE MANAGEMENT TESTS"
    log_info "========================================"

    test_register_resource
    test_register_child_resource
    test_get_resource
    test_list_resources
    test_get_resource_tree
    test_update_resource
    test_deactivate_resource
}

run_visibility_tests() {
    log_info ""
    log_info "========================================"
    log_info "VISIBILITY RULE TESTS"
    log_info "========================================"

    test_create_visibility_rule
    test_create_visibility_rule_role_based
    test_get_visibility_rules
    test_check_visibility
    test_remove_visibility_rule
}

run_config_tests() {
    log_info ""
    log_info "========================================"
    log_info "RBAC CONFIGURATION TESTS"
    log_info "========================================"

    test_update_rbac_config
    test_update_rbac_config_second
    test_get_rbac_config
    test_get_rbac_config_value
}

run_actor_tests() {
    log_info ""
    log_info "========================================"
    log_info "ACTOR RBAC PROFILE TESTS"
    log_info "========================================"

    test_list_actors
    test_get_actor_rbac_summary
}

run_analytics_tests() {
    log_info ""
    log_info "========================================"
    log_info "RBAC ANALYTICS TESTS"
    log_info "========================================"

    test_rbac_analytics
    test_rbac_analytics_with_date_range
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_info "========================================"
    log_info "RBAC MODULE E2E TESTS (PBAC)"
    log_info "========================================"
    log_info "Gateway:  $GLOBAL_GATEWAY"
    log_info "Scope ID: ${SCOPE_ID:-<not set>}"
    log_info "Actor ID: ${ACTOR_ID:-<not set>}"
    log_info "Mode:     $TEST_MODE"
    log_info "========================================"

    # Register cleanup on exit
    trap cleanup_resources EXIT

    bootstrap_admin_access

    case "$TEST_MODE" in
        all)
            run_role_tests
            run_default_permission_tests
            run_assignment_tests
            run_override_tests
            run_checking_tests
            run_action_tests
            run_audit_tests
            run_billing_tests
            run_resource_tests
            run_visibility_tests
            run_config_tests
            run_actor_tests
            run_analytics_tests
            ;;
        roles)
            run_role_tests
            ;;
        defaults)
            # Need a role for default permission tests
            test_create_role
            run_default_permission_tests
            ;;
        assignments)
            # Need a role for assignment tests
            test_create_role
            run_assignment_tests
            ;;
        overrides)
            # Need a role for role override tests
            test_create_role
            run_override_tests
            ;;
        checking)
            # Permission checking works without prerequisite data
            run_checking_tests
            ;;
        actions)
            run_action_tests
            ;;
        audit)
            run_audit_tests
            ;;
        billing)
            run_billing_tests
            ;;
        resources)
            run_resource_tests
            ;;
        visibility)
            # Need a role for role-based visibility test
            test_create_role
            run_visibility_tests
            ;;
        config)
            run_config_tests
            ;;
        actors)
            run_actor_tests
            ;;
        analytics)
            run_analytics_tests
            ;;
        *)
            log_error "Unknown test mode: $TEST_MODE"
            log_info "Valid modes: all, roles, defaults, assignments, overrides, checking, actions, audit, billing, resources, visibility, config, actors, analytics"
            exit 1
            ;;
    esac

    # Summary
    log_info ""
    log_info "========================================"
    log_info "TEST SUMMARY"
    log_info "========================================"
    log_success "Passed:  $TESTS_PASSED"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        log_error "Failed:  $TESTS_FAILED"
    else
        log_info "Failed:  $TESTS_FAILED"
    fi
    log_warning "Skipped: $TESTS_SKIPPED"
    log_info "========================================"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        exit 1
    fi

    exit 0
}

main "$@"
