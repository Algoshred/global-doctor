#!/usr/bin/env bash
#
# Tenant Module E2E Tests
# =======================
#
# Tests tenant management, organizations, workspaces, and memberships
#
# Usage:
#   ./test-tenant.sh                    # Run all tests
#   ./test-tenant.sh tenants            # Run tenant tests only
#   ./test-tenant.sh organizations      # Run organization tests only
#   ./test-tenant.sh workspaces         # Run workspace tests only
#   ./test-tenant.sh memberships        # Run membership tests only
#   ./test-tenant.sh products           # Run product catalog tests only
#   ./test-tenant.sh featureflags       # Run tenant feature-flag tests only

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
# Navigate from global/modules/tenant/scripts/ up to workspaces-doctor root
DOCTOR_ROOT="$(cd "$MODULE_DIR/../.." && pwd)"
CORE_DIR="$DOCTOR_ROOT/core"
ENV_FILE="$CORE_DIR/env/e2e-env.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test data
TEST_TIMESTAMP="$(date +%s)"
TEST_TENANT_NAME="test-tenant-$TEST_TIMESTAMP"
TEST_ORG_NAME="test-org-$TEST_TIMESTAMP"
TEST_WORKSPACE_NAME="test-workspace-$TEST_TIMESTAMP"
TEST_MEMBER_USER_ID="e2e-member-$TEST_TIMESTAMP"
TEST_INVITE_EMAIL="e2e-member-$TEST_TIMESTAMP@example.com"
TEST_TENANT_ID=""
TEST_ORG_ID=""
TEST_WORKSPACE_ID=""
TEST_CREATED_TENANT="false"
E2E_USER_AUTH_TOKEN=""

# ============================================================================
# Utility Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# Load environment
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Environment file not found: $ENV_FILE"
        log_error "Run: make -C $CORE_DIR bootstrap-env"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$ENV_FILE"

    if [[ -z "${E2E_AUTH_TOKEN:-}" ]]; then
        log_error "E2E_AUTH_TOKEN not set in environment"
        exit 1
    fi

    # Support both E2E_GLOBAL_GATEWAY_URL and E2E_GLOBAL_GATEWAY
    if [[ -z "${E2E_GLOBAL_GATEWAY_URL:-}" ]]; then
        if [[ -n "${E2E_GLOBAL_GATEWAY:-}" ]]; then
            E2E_GLOBAL_GATEWAY_URL="$E2E_GLOBAL_GATEWAY"
        else
            E2E_GLOBAL_GATEWAY_URL="http://localhost:4000/global/graphql"
            log_warning "E2E_GLOBAL_GATEWAY_URL not set, using default: $E2E_GLOBAL_GATEWAY_URL"
        fi
    fi

    E2E_USER_AUTH_TOKEN="$E2E_AUTH_TOKEN"

    if [[ -n "${E2E_ADMIN_TOKEN:-}" ]]; then
        E2E_AUTH_TOKEN="$E2E_ADMIN_TOKEN"
        log_info "Using E2E_ADMIN_TOKEN for tenant admin operations"
    elif [[ -n "${E2E_ADMIN_EMAIL:-}" && -n "${E2E_ADMIN_PASSWORD:-}" ]]; then
        local admin_payload admin_response admin_token
        admin_payload=$(jq -nc \
            --arg email "$E2E_ADMIN_EMAIL" \
            --arg password "$E2E_ADMIN_PASSWORD" \
            '{query:"mutation SignIn($input: SignInInput!) { signIn(input: $input) { accessToken } }",variables:{input:{email:$email,password:$password}}}')
        admin_response=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$admin_payload" \
            "$E2E_GLOBAL_GATEWAY_URL")
        admin_token=$(printf '%s' "$admin_response" | jq -r '.data.signIn.accessToken // empty')
        if [[ -n "$admin_token" && "$admin_token" != "null" ]]; then
            E2E_AUTH_TOKEN="$admin_token"
            log_info "Signed in E2E_ADMIN_EMAIL for tenant admin operations"
        else
            log_warning "E2E_ADMIN_EMAIL sign-in failed; tenant admin tests will use E2E_AUTH_TOKEN"
        fi
    else
        log_warning "No E2E_ADMIN_TOKEN or E2E_ADMIN_EMAIL/E2E_ADMIN_PASSWORD configured; tenant admin tests may fail"
    fi

    log_info "Environment loaded successfully"
    log_info "Gateway URL: $E2E_GLOBAL_GATEWAY_URL"
}

# Execute GraphQL query
gql_query() {
    local query="$1"
    local variables="${2:-}"
    gql_query_with_token "$query" "$variables" "$E2E_AUTH_TOKEN"
}

gql_query_with_token() {
    local query="$1"
    local variables="${2:-}"
    local auth_token="${3:-$E2E_AUTH_TOKEN}"

    if [[ -z "$variables" ]]; then
        variables='{}'
    fi

    # Variables are already constructed as JSON in callers. Strip newlines only
    # to keep curl payloads single-line and avoid jq noise during doctor runs.
    local compact_vars
    compact_vars=$(printf '%s' "$variables" | tr -d '\n')
    local payload
    payload=$(jq -nc --arg query "$query" --arg vars "$compact_vars" '{query:$query, variables: ($vars | fromjson)}')

    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $auth_token" \
        -d "$payload" \
        "$E2E_GLOBAL_GATEWAY_URL")

    if [[ "${E2E_LOG_REQUESTS:-false}" == "true" ]]; then
        log_info "GraphQL Response: $response"
    fi

    echo "$response"
}

# Check if response has errors
has_errors() {
    local response="$1"
    echo "$response" | jq -e '.errors' > /dev/null 2>&1
}

# Extract data from response
extract_data() {
    local response="$1"
    local path="$2"
    printf '%s' "$response" | jq -r "$path" 2>/dev/null || true
}

# Test assertion
assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="${3:-Assertion failed}"

    if [[ "$actual" == "$expected" ]]; then
        return 0
    else
        log_error "$message"
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"

    if [[ -n "$value" && "$value" != "null" ]]; then
        return 0
    else
        log_error "$message"
        return 1
    fi
}

# Test wrapper
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    log_info "Running test: $test_name"

    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "✓ $test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "✗ $test_name"
        return 1
    fi
}

# ============================================================================
# Tenant Tests
# ============================================================================

test_create_tenant() {
    local query='
        mutation CreateTenant($input: CreateTenantInput!) {
            createTenant(input: $input) {
                id
                name
                slug
                status
                type
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg name "$TEST_TENANT_NAME" \
        --arg slug "test-tenant-$TEST_TIMESTAMP" \
        '{input:{name:$name,slug:$slug,type:"SHARED"}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Tenant creation failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    TEST_TENANT_ID=$(extract_data "$response" '.data.createTenant.id')
    TEST_CREATED_TENANT="true"
    assert_not_empty "$TEST_TENANT_ID" "Tenant ID should not be empty"
}

test_list_tenants() {
    local query='
        query ListTenants {
            tenants(limit: 10, offset: 0) {
                items {
                    id
                    name
                    status
                }
                total
            }
        }
    '

    local response
    response=$(gql_query "$query")

    if has_errors "$response"; then
        log_error "List tenants failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local tenant_count
    tenant_count=$(extract_data "$response" '.data.tenants.total')

    if [[ "$tenant_count" -gt 0 ]]; then
        log_success "Found $tenant_count tenants"
        return 0
    else
        log_error "No tenants found"
        return 1
    fi
}

test_tenant_lifecycle() {
    if [[ "$TEST_CREATED_TENANT" != "true" ]]; then
        log_error "Tenant lifecycle requires a tenant created by this test run"
        return 1
    fi

    local configure_query='
        mutation ConfigureTenant($id: ID!, $input: ConfigureTenantInput!) {
            configureTenant(id: $id, input: $input) { id config { region dataResidency } }
        }
    '
    local configure_vars
    configure_vars=$(jq -nc --arg id "$TEST_TENANT_ID" '{id:$id,input:{region:"ap-south-1",dataResidency:"IN"}}')
    local configure_response
    configure_response=$(gql_query "$configure_query" "$configure_vars")
    if has_errors "$configure_response"; then
        log_error "Configure tenant failed: $(extract_data "$configure_response" '.errors[0].message')"
        return 1
    fi

    local suspend_query='mutation SuspendTenant($id: ID!) { suspendTenant(id: $id) { id status } }'
    local activate_query='mutation ActivateTenant($id: ID!) { activateTenant(id: $id) { id status } }'
    local id_vars
    id_vars=$(jq -nc --arg id "$TEST_TENANT_ID" '{id:$id}')

    local suspend_response
    suspend_response=$(gql_query "$suspend_query" "$id_vars")
    if has_errors "$suspend_response"; then
        log_error "Suspend tenant failed: $(extract_data "$suspend_response" '.errors[0].message')"
        return 1
    fi
    assert_eq "$(extract_data "$suspend_response" '.data.suspendTenant.status')" "SUSPENDED" "Tenant should be suspended"

    local activate_response
    activate_response=$(gql_query "$activate_query" "$id_vars")
    if has_errors "$activate_response"; then
        log_error "Activate tenant failed: $(extract_data "$activate_response" '.errors[0].message')"
        return 1
    fi
    assert_eq "$(extract_data "$activate_response" '.data.activateTenant.status')" "ACTIVE" "Tenant should be active"
}

test_dedicated_tenant_provisioning() {
    if [[ "$TEST_CREATED_TENANT" != "true" ]]; then
        log_error "Dedicated provisioning requires a tenant created by this test run"
        return 1
    fi

    local endpoint="https://tenant-$TEST_TIMESTAMP.example.com"
    local provision_query='
        mutation ProvisionDedicatedTenant($input: ProvisionDedicatedTenantInput!) {
            provisionDedicatedTenant(input: $input) { id type status endpoint }
        }
    '
    local provision_vars
    provision_vars=$(jq -nc --arg tenantId "$TEST_TENANT_ID" '{input:{tenantId:$tenantId,region:"ap-south-1"}}')
    local provision_response
    provision_response=$(gql_query "$provision_query" "$provision_vars")
    if has_errors "$provision_response"; then
        log_error "Provision dedicated tenant failed: $(extract_data "$provision_response" '.errors[0].message')"
        return 1
    fi
    assert_eq "$(extract_data "$provision_response" '.data.provisionDedicatedTenant.type')" "DEDICATED" "Tenant should be dedicated"
    assert_eq "$(extract_data "$provision_response" '.data.provisionDedicatedTenant.status')" "PROVISIONING" "Tenant should be provisioning before endpoint"

    local endpoint_query='
        mutation SetTenantEndpoint($tenantId: ID!, $endpoint: String!) {
            setTenantEndpoint(tenantId: $tenantId, endpoint: $endpoint) { id endpoint status }
        }
    '
    local endpoint_vars
    endpoint_vars=$(jq -nc --arg tenantId "$TEST_TENANT_ID" --arg endpoint "$endpoint" '{tenantId:$tenantId,endpoint:$endpoint}')
    local endpoint_response
    endpoint_response=$(gql_query "$endpoint_query" "$endpoint_vars")
    if has_errors "$endpoint_response"; then
        log_error "Set tenant endpoint failed: $(extract_data "$endpoint_response" '.errors[0].message')"
        return 1
    fi
    assert_eq "$(extract_data "$endpoint_response" '.data.setTenantEndpoint.endpoint')" "$endpoint" "Tenant endpoint should match"
    assert_eq "$(extract_data "$endpoint_response" '.data.setTenantEndpoint.status')" "ACTIVE" "Tenant should be active after endpoint"
}

test_tenant_routing_info_denied_for_user_token() {
    if [[ -z "$TEST_TENANT_ID" ]]; then
        log_warning "Skipping routing denial test (no tenant ID)"
        return 0
    fi

    local query='query TenantRoutingInfo($tenantId: ID!) { tenantRoutingInfo(tenantId: $tenantId) { tenantId endpoint status } }'
    local variables
    variables=$(jq -nc --arg tenantId "$TEST_TENANT_ID" '{tenantId:$tenantId}')
    local response
    response=$(gql_query_with_token "$query" "$variables" "$E2E_USER_AUTH_TOKEN")

    if has_errors "$response"; then
        log_success "Routing info is denied for non-service token as expected"
        return 0
    fi

    log_error "Routing info should be denied unless the token is a service actor"
    return 1
}

test_feature_flag_evaluation() {
    ensure_test_hierarchy || return 1

    local query='
        query EvaluateFeatureFlags($input: EvaluateFeatureFlagsInput!) {
            evaluateFeatureFlags(input: $input) {
                evaluations { key value reason flagType }
            }
        }
    '
    local variables
    variables=$(jq -nc --arg workspaceId "$TEST_WORKSPACE_ID" '{input:{workspaceId:$workspaceId,keys:["tenant.create","tenant.edit"]}}')
    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Evaluate feature flags failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local evaluation_count
    evaluation_count=$(extract_data "$response" '.data.evaluateFeatureFlags.evaluations | length')
    assert_eq "$evaluation_count" "2" "Expected two tenant feature flag evaluations"
}

# ============================================================================
# Organization Tests
# ============================================================================

test_create_organization() {
    if [[ -z "$TEST_TENANT_ID" ]]; then
        log_warning "Skipping organization creation (no tenant ID)"
        return 0
    fi

    # Use existing org from E2E env only when it belongs to this test tenant.
    if [[ -n "${E2E_ORG_ID:-}" ]]; then
        local org_check
        org_check=$(gql_query "query { organization(id: \"${E2E_ORG_ID}\") { id name tenantId } }")
        if ! has_errors "$org_check"; then
            local found_org found_org_tenant
            found_org=$(extract_data "$org_check" '.data.organization.id')
            found_org_tenant=$(extract_data "$org_check" '.data.organization.tenantId')
            if [[ -n "$found_org" && "$found_org" != "null" && "$found_org_tenant" == "$TEST_TENANT_ID" ]]; then
                TEST_ORG_ID="$E2E_ORG_ID"
                log_success "Using existing organization from E2E env: $TEST_ORG_ID"
                return 0
            fi
        fi
        log_warning "E2E organization is unavailable or belongs to a different tenant, will create new one"
    fi

    local query='
        mutation CreateOrganization($input: CreateOrganizationInput!) {
            createOrganization(input: $input) {
                id
                name
                slug
                tenantId
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg tenantId "$TEST_TENANT_ID" \
        --arg name "$TEST_ORG_NAME" \
        --arg slug "test-org-$TEST_TIMESTAMP" \
        '{input:{tenantId:$tenantId,name:$name,slug:$slug}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Organization creation failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    TEST_ORG_ID=$(extract_data "$response" '.data.createOrganization.id')
    assert_not_empty "$TEST_ORG_ID" "Organization ID should not be empty"
}

test_list_organizations() {
    if [[ -z "$TEST_TENANT_ID" ]]; then
        log_warning "Skipping organization list (no tenant ID)"
        return 0
    fi

    local query='
        query ListOrganizations($filter: OrganizationFilterInput) {
            allOrganizations(filter: $filter) {
                items {
                    id
                    name
                    tenantId
                }
                total
            }
        }
    '

    local variables
    variables=$(jq -nc --arg tenantId "$TEST_TENANT_ID" '{filter:{tenantId:$tenantId}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "List organizations failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local org_count
    org_count=$(extract_data "$response" '.data.allOrganizations.total')
    log_success "Found $org_count organizations in tenant"
    return 0
}

# ============================================================================
# Workspace Tests
# ============================================================================

test_create_workspace() {
    if [[ -z "$TEST_ORG_ID" || -z "$TEST_TENANT_ID" ]]; then
        log_warning "Skipping workspace creation (no organization or tenant ID)"
        return 0
    fi

    local query='
        mutation CreateWorkspace($input: CreateWorkspaceInput!) {
            createWorkspace(input: $input) {
                id
                name
                slug
                organizationId
                status
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg tenantId "$TEST_TENANT_ID" \
        --arg organizationId "$TEST_ORG_ID" \
        --arg name "$TEST_WORKSPACE_NAME" \
        --arg slug "test-workspace-$TEST_TIMESTAMP" \
        '{input:{tenantId:$tenantId,organizationId:$organizationId,name:$name,slug:$slug}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Workspace creation failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    TEST_WORKSPACE_ID=$(extract_data "$response" '.data.createWorkspace.id')
    assert_not_empty "$TEST_WORKSPACE_ID" "Workspace ID should not be empty"
}

test_list_workspaces() {
    if [[ -z "$TEST_ORG_ID" ]]; then
        log_warning "Skipping workspace list (no organization ID)"
        return 0
    fi

    local query='
        query ListWorkspaces($filter: WorkspaceFilterInput) {
            allWorkspaces(filter: $filter) {
                items {
                    id
                    name
                    status
                    organizationId
                }
                total
            }
        }
    '

    local variables
    variables=$(jq -nc --arg organizationId "$TEST_ORG_ID" '{filter:{organizationId:$organizationId}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "List workspaces failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local ws_count
    ws_count=$(extract_data "$response" '.data.allWorkspaces.total')
    log_success "Found $ws_count workspaces in organization"
    return 0
}

# ============================================================================
# Product Catalog Tests
# ============================================================================

test_list_platform_products() {
    local query='
        query ListPlatformProducts {
            platformProducts {
                items {
                    id
                    name
                    slug
                    status
                }
                total
            }
        }
    '

    local response
    response=$(gql_query "$query")

    if has_errors "$response"; then
        log_error "List platform products failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local product_count
    product_count=$(extract_data "$response" '.data.platformProducts.total')

    if [[ "$product_count" -gt 0 ]]; then
        log_success "Found $product_count platform products"
        return 0
    else
        log_warning "No platform products found (might be expected)"
        return 0
    fi
}

# ============================================================================
# Membership Tests
# ============================================================================

ensure_test_hierarchy() {
    if [[ -z "$TEST_TENANT_ID" ]]; then
        test_create_tenant || return 1
    fi

    if [[ -z "$TEST_ORG_ID" ]]; then
        test_create_organization || return 1
    fi

    if [[ -z "$TEST_WORKSPACE_ID" ]]; then
        test_create_workspace || return 1
    fi

    return 0
}

test_add_organization_member() {
    ensure_test_hierarchy || return 1

    local query='
        mutation AddOrganizationMember($input: AddOrganizationMemberInput!) {
            addOrganizationMember(input: $input) {
                id
                organizationId
                userId
                role
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg organizationId "$TEST_ORG_ID" \
        --arg userId "$TEST_MEMBER_USER_ID" \
        '{input:{organizationId:$organizationId,userId:$userId,role:"MEMBER"}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Add organization member failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local added_user
    added_user=$(extract_data "$response" '.data.addOrganizationMember.userId')
    assert_eq "$added_user" "$TEST_MEMBER_USER_ID" "Organization member user ID should match"
}

test_list_organization_members() {
    ensure_test_hierarchy || return 1

    local query='
        query OrganizationMembers($organizationId: String!) {
            organizationMembers(organizationId: $organizationId, limit: 100, offset: 0) {
                items {
                    userId
                    role
                }
                total
            }
        }
    '

    local variables
    variables=$(jq -nc --arg organizationId "$TEST_ORG_ID" '{organizationId:$organizationId}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "List organization members failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local member_exists
    member_exists=$(printf '%s' "$response" | jq -r --arg userId "$TEST_MEMBER_USER_ID" '.data.organizationMembers.items[] | select(.userId == $userId) | .userId' 2>/dev/null | head -n 1)
    assert_eq "$member_exists" "$TEST_MEMBER_USER_ID" "Synthetic organization member should be returned"
}

test_invite_organization_member() {
    ensure_test_hierarchy || return 1

    local query='
        mutation InviteOrganizationMember($input: InviteOrganizationMemberInput!) {
            inviteOrganizationMember(input: $input) {
                id
                email
                status
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg organizationId "$TEST_ORG_ID" \
        --arg email "$TEST_INVITE_EMAIL" \
        '{input:{organizationId:$organizationId,email:$email,role:"MEMBER",message:"E2E membership coverage"}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Invite organization member failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local invited_email
    invited_email=$(extract_data "$response" '.data.inviteOrganizationMember.email')
    assert_eq "$invited_email" "$TEST_INVITE_EMAIL" "Organization invite email should match"
}

test_add_workspace_member() {
    ensure_test_hierarchy || return 1

    local query='
        mutation AddWorkspaceMember($input: AddWorkspaceMemberInput!) {
            addWorkspaceMember(input: $input) {
                id
                userId
                role
            }
        }
    '

    local variables
    variables=$(jq -nc \
        --arg workspaceId "$TEST_WORKSPACE_ID" \
        --arg userId "$TEST_MEMBER_USER_ID" \
        '{input:{workspaceId:$workspaceId,userId:$userId,role:"MEMBER"}}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Add workspace member failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local added_user
    added_user=$(extract_data "$response" '.data.addWorkspaceMember.userId')
    assert_eq "$added_user" "$TEST_MEMBER_USER_ID" "Workspace member user ID should match"
}

test_list_workspace_members() {
    ensure_test_hierarchy || return 1

    local query='
        query WorkspaceMembers($workspaceId: String!) {
            workspaceMembers(workspaceId: $workspaceId, limit: 100, offset: 0) {
                items {
                    userId
                    role
                }
                total
            }
        }
    '

    local variables
    variables=$(jq -nc --arg workspaceId "$TEST_WORKSPACE_ID" '{workspaceId:$workspaceId}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "List workspace members failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local member_exists
    member_exists=$(printf '%s' "$response" | jq -r --arg userId "$TEST_MEMBER_USER_ID" '.data.workspaceMembers.items[] | select(.userId == $userId) | .userId' 2>/dev/null | head -n 1)
    assert_eq "$member_exists" "$TEST_MEMBER_USER_ID" "Synthetic workspace member should be returned"
}

test_remove_workspace_member() {
    ensure_test_hierarchy || return 1

    local query='
        mutation RemoveWorkspaceMember($workspaceId: String!, $userId: String!) {
            removeWorkspaceMember(workspaceId: $workspaceId, userId: $userId)
        }
    '

    local variables
    variables=$(jq -nc --arg workspaceId "$TEST_WORKSPACE_ID" --arg userId "$TEST_MEMBER_USER_ID" '{workspaceId:$workspaceId,userId:$userId}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Remove workspace member failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local removed
    removed=$(extract_data "$response" '.data.removeWorkspaceMember')
    assert_eq "$removed" "true" "Workspace member should be removed"
}

test_remove_organization_member() {
    ensure_test_hierarchy || return 1

    local query='
        mutation RemoveOrganizationMember($organizationId: String!, $userId: String!) {
            removeOrganizationMember(organizationId: $organizationId, userId: $userId)
        }
    '

    local variables
    variables=$(jq -nc --arg organizationId "$TEST_ORG_ID" --arg userId "$TEST_MEMBER_USER_ID" '{organizationId:$organizationId,userId:$userId}')

    local response
    response=$(gql_query "$query" "$variables")

    if has_errors "$response"; then
        log_error "Remove organization member failed: $(extract_data "$response" '.errors[0].message')"
        return 1
    fi

    local removed
    removed=$(extract_data "$response" '.data.removeOrganizationMember')
    assert_eq "$removed" "true" "Organization member should be removed"
}

# ============================================================================
# Test Suites
# ============================================================================

run_tenant_tests() {
    log_info "Running Tenant Tests"
    run_test "Create tenant" test_create_tenant
    run_test "List tenants" test_list_tenants
    run_test "Tenant lifecycle" test_tenant_lifecycle
    run_test "Dedicated tenant provisioning" test_dedicated_tenant_provisioning
    run_test "Tenant routing info denied for user token" test_tenant_routing_info_denied_for_user_token
}

run_organization_tests() {
    log_info "Running Organization Tests"
    run_test "Create organization" test_create_organization
    run_test "List organizations" test_list_organizations
}

run_workspace_tests() {
    log_info "Running Workspace Tests"
    run_test "Create workspace" test_create_workspace
    run_test "List workspaces" test_list_workspaces
}

run_membership_tests() {
    log_info "Running Membership Tests"
    ensure_test_hierarchy || return 1
    run_test "Add organization member" test_add_organization_member
    run_test "List organization members" test_list_organization_members
    run_test "Invite organization member" test_invite_organization_member
    run_test "Add workspace member" test_add_workspace_member
    run_test "List workspace members" test_list_workspace_members
    run_test "Remove workspace member" test_remove_workspace_member
    run_test "Remove organization member" test_remove_organization_member
}

run_product_tests() {
    log_info "Running Product Catalog Tests"
    run_test "List platform products" test_list_platform_products
}

run_feature_flag_tests() {
    log_info "Running Tenant Feature Flag Tests"
    run_test "Evaluate tenant feature flags" test_feature_flag_evaluation
}

run_all_tests() {
    run_tenant_tests
    run_organization_tests
    run_workspace_tests
    run_membership_tests
    run_product_tests
    run_feature_flag_tests
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    log_info "Cleaning up test data..."
    log_info "Membership cleanup is handled by explicit remove-member tests."
    log_info "Tenant, organization, and workspace cleanup is intentionally skipped in canonical E2E runs because delete permissions vary by environment."
}

# ============================================================================
# Main
# ============================================================================

main() {
    log_info "Tenant Module E2E Tests"
    log_info "======================="

    # Load environment
    load_env

    # Determine which tests to run
    local test_suite="${1:-all}"

    case "$test_suite" in
        tenants)
            run_tenant_tests
            ;;
        organizations)
            run_organization_tests
            ;;
        workspaces)
            run_workspace_tests
            ;;
        memberships)
            run_membership_tests
            ;;
        products)
            run_product_tests
            ;;
        featureflags)
            run_feature_flag_tests
            ;;
        all)
            run_all_tests
            ;;
        *)
            log_error "Unknown test suite: $test_suite"
            log_info "Valid options: all, tenants, organizations, workspaces, memberships, products, featureflags"
            exit 1
            ;;
    esac

    # Cleanup
    cleanup

    # Print summary
    echo ""
    log_info "Test Summary"
    log_info "============"
    log_info "Total:  $TESTS_RUN"
    log_success "Passed: $TESTS_PASSED"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Failed: $TESTS_FAILED"
        exit 1
    else
        log_success "All tests passed!"
        exit 0
    fi
}

# Run main function
main "$@"
