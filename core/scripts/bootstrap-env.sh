#!/bin/bash

# =============================================================================
# Bootstrap E2E Environment
# Creates foundation resources (user, tenant, org, workspace) that other
# E2E tests can use. Saves credentials to env/e2e-env.sh for sourcing.
#
# Usage: ./bootstrap-env.sh [--prefix PREFIX] [--force]
#   --prefix PREFIX: Custom prefix for test resources (default: e2e)
#   --force: Force recreate even if env file exists
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Parse arguments
PREFIX="e2e"
FORCE=false
VERBOSE=${VERBOSE:-true}

for arg in "$@"; do
    case $arg in
        --prefix=*)
            PREFIX="${arg#*=}"
            shift
            ;;
        --prefix)
            shift
            PREFIX="$1"
            shift
            ;;
        --force|-f)
            FORCE=true
            shift
            ;;
        --quiet|-q)
            VERBOSE=false
            shift
            ;;
    esac
done

# Configuration - API Gateways (NEVER call services directly!)
# Global operations (signup, signin, etc.) -> global-public-gateway
# Workspace operations (workspace tokens, RBAC) -> wspace-public-gateway
GLOBAL_GATEWAY="${GLOBAL_GATEWAY:-http://localhost:4000/global/graphql}"
WSPACE_PUBLIC_GATEWAY="${WSPACE_PUBLIC_GATEWAY:-http://localhost:4003/workspaces/graphql}"
ENV_FILE="$ENV_DIR/e2e-env.sh"
TIMESTAMP=$(date +%s)

# Generate unique identifiers
TEST_EMAIL="${PREFIX}-user-${TIMESTAMP}@burdenoff.com"
TEST_USERNAME="${PREFIX}user${TIMESTAMP}"
TEST_PASSWORD="${E2E_TEST_PASSWORD:-BOff@1233210}"
TEST_NAME="E2E Test User ${TIMESTAMP}"

# =============================================================================
# Helper Functions
# =============================================================================

# Execute GraphQL request directly (simplified and robust)
graphql_request() {
    local url="$1"
    local query="$2"
    local variables="$3"
    local auth_token="$4"
    local description="$5"

    # Handle empty or missing variables
    if [ -z "$variables" ]; then
        variables='{}'
    fi

    # Build the request JSON using a temp file to avoid quoting issues
    local temp_file
    temp_file=$(mktemp)

    # Use jq to build proper JSON
    jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}' > "$temp_file" 2>/dev/null

    if [ ! -s "$temp_file" ]; then
        # Fallback: manually construct JSON
        echo "{\"query\":$(echo "$query" | jq -Rs .),\"variables\":$variables}" > "$temp_file"
    fi

    # Log to stderr so it doesn't pollute the response
    if [ "$VERBOSE" = true ]; then
        echo "" >&2
        echo -e "${BLUE}>>> REQUEST: $description${NC}" >&2
        echo -e "${YELLOW}POST $url${NC}" >&2
        echo -e "${YELLOW}Body: $(cat "$temp_file" | jq -c . 2>/dev/null || cat "$temp_file")${NC}" >&2
        echo "" >&2
    fi

    # Execute curl with proper arguments
    local response
    if [ -n "$auth_token" ]; then
        response=$(curl -s -X POST "$url" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $auth_token" \
            -d @"$temp_file")
    else
        response=$(curl -s -X POST "$url" \
            -H "Content-Type: application/json" \
            -d @"$temp_file")
    fi

    # Clean up temp file
    rm -f "$temp_file"

    # Only output the actual response
    echo "$response"
}

global_psql() {
    local database="$1"
    local sql="$2"

    docker exec "${GLOBAL_POSTGRES_CONTAINER:-global-shared-postgres}" \
        psql -U "${GLOBAL_POSTGRES_USER:-boffadmin_admin}" -d "$database" -t -A \
        -c "$sql" 2>/dev/null || true
}

wspace_psql() {
    local database="$1"
    local sql="$2"

    docker exec "${WSPACE_POSTGRES_CONTAINER:-wspace-shared-postgres}" \
        psql -U "${WSPACE_POSTGRES_USER:-boffadmin_admin}" -d "$database" -t -A \
        -c "$sql" 2>/dev/null || true
}

new_uuid() {
    tr -d '\n' < /proc/sys/kernel/random/uuid
}

# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Bootstrap E2E Environment${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""
echo "Prefix: $PREFIX"
echo "Timestamp: $TIMESTAMP"
echo "Env File: $ENV_FILE"
echo ""

# Check if env file already exists
if [ -f "$ENV_FILE" ] && [ "$FORCE" != true ]; then
    echo -e "${YELLOW}Environment file already exists: $ENV_FILE${NC}"
    echo "Use --force to recreate, or source the existing file:"
    echo "  source $ENV_FILE"
    echo ""

    # Verify the existing environment is still valid
    source "$ENV_FILE"
    if [ -n "$E2E_AUTH_TOKEN" ]; then
        # Test if token is still valid
        VERIFY_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $E2E_AUTH_TOKEN" \
            -d '{"query":"query { currentUser { id } }"}')

        CURRENT_USER=$(echo "$VERIFY_RESPONSE" | jq -r '.data.currentUser.id // empty')

        if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "null" ]; then
            echo -e "${GREEN}Existing environment is valid!${NC}"
            echo "  User ID: $E2E_USER_ID"
            echo "  Tenant ID: $E2E_TENANT_ID"
            echo "  Workspace ID: $E2E_WORKSPACE_ID"
            exit 0
        else
            echo -e "${YELLOW}Existing token expired, recreating environment...${NC}"
        fi
    fi
fi

# Ensure services are healthy
echo -e "${YELLOW}Checking service health...${NC}"
if ! curl -sf http://localhost:4000/health > /dev/null 2>&1; then
    log_error "global-public-gateway is not healthy. Run 'make ensure' first."
    exit 1
fi
echo -e "${GREEN}Services are healthy${NC}"
echo ""

# =============================================================================
# STEP 1: User Signup
# =============================================================================
echo -e "${BLUE}Step 1: Creating test user...${NC}"

SIGNUP_QUERY='mutation SignUp($input: SignUpInput!) { signUp(input: $input) { accessToken refreshToken user { id email username } } }'
SIGNUP_VARS=$(jq -n \
    --arg email "$TEST_EMAIL" \
    --arg password "$TEST_PASSWORD" \
    --arg username "$TEST_USERNAME" \
    --arg name "$TEST_NAME" \
    '{input: {email: $email, password: $password, username: $username, name: $name}}')

SIGNUP_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$SIGNUP_QUERY" "$SIGNUP_VARS" "" "User Signup")

if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}<<< RESPONSE:${NC}"
    echo "$SIGNUP_RESPONSE" | jq .
fi

USER_ID=$(echo "$SIGNUP_RESPONSE" | jq -r '.data.signUp.user.id // empty')
INITIAL_TOKEN=$(echo "$SIGNUP_RESPONSE" | jq -r '.data.signUp.accessToken // empty')
REFRESH_TOKEN=$(echo "$SIGNUP_RESPONSE" | jq -r '.data.signUp.refreshToken // empty')

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
    log_error "Failed to create user"
    echo "$SIGNUP_RESPONSE" | jq .
    exit 1
fi

log_success "User created: $USER_ID"
echo "  Email: $TEST_EMAIL"
echo ""

# =============================================================================
# STEP 2: Email Verification
# =============================================================================
echo -e "${BLUE}Step 2: Verifying email...${NC}"

sleep 2  # Wait for verification token to be generated

VERIFICATION_TOKEN=$(global_psql global_auth \
    "SELECT token FROM email_verifications WHERE email='$TEST_EMAIL' ORDER BY \"createdAt\" DESC LIMIT 1;")

if [ -z "$VERIFICATION_TOKEN" ]; then
    log_warning "No verification token found, attempting to continue..."
else
    VERIFY_QUERY='mutation VerifyEmail($token: String!) { verifyEmail(token: $token) { success message } }'
    VERIFY_VARS=$(jq -n --arg token "$VERIFICATION_TOKEN" '{token: $token}')

    VERIFY_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$VERIFY_QUERY" "$VERIFY_VARS" "" "Email Verification")

    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}<<< RESPONSE:${NC}"
        echo "$VERIFY_RESPONSE" | jq .
    fi

    SUCCESS=$(echo "$VERIFY_RESPONSE" | jq -r '.data.verifyEmail.success')
    if [ "$SUCCESS" = "true" ]; then
        log_success "Email verified"
    else
        log_warning "Email verification returned: $SUCCESS"
    fi
fi
echo ""

# =============================================================================
# STEP 3: User SignIn (Fresh Token + bootstrap self-heal)
# =============================================================================
echo -e "${BLUE}Step 3: Signing in...${NC}"

SIGNIN_QUERY='mutation SignIn($input: SignInInput!) { signIn(input: $input) { accessToken refreshToken expiresIn user { id } } }'
SIGNIN_VARS=$(jq -n \
    --arg email "$TEST_EMAIL" \
    --arg password "$TEST_PASSWORD" \
    '{input: {email: $email, password: $password}}')

SIGNIN_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$SIGNIN_QUERY" "$SIGNIN_VARS" "" "User SignIn")

if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}<<< RESPONSE:${NC}"
    echo "$SIGNIN_RESPONSE" | jq .
fi

AUTH_TOKEN=$(echo "$SIGNIN_RESPONSE" | jq -r '.data.signIn.accessToken // empty')
REFRESH_TOKEN=$(echo "$SIGNIN_RESPONSE" | jq -r '.data.signIn.refreshToken // empty')

if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
    log_error "Failed to sign in"
    exit 1
fi

log_success "Signed in successfully"
echo "  Token: ${AUTH_TOKEN:0:30}..."
echo ""

# =============================================================================
# STEP 4: Wait for Default Resources
# =============================================================================
echo -e "${BLUE}Step 4: Waiting for default resources...${NC}"

attempt=0
max_attempts="${E2E_DEFAULT_RESOURCE_MAX_ATTEMPTS:-6}"
WORKSPACE_ID=""
FALLBACK_WORKSPACE_CONTEXT=false
ISSUE_WORKSPACE_TOKEN_ACTOR_TYPE="user"

while [ "$attempt" -lt "$max_attempts" ]; do
    WORKSPACE_ID=$(global_psql global_tenant \
        "SELECT w.id FROM workspaces w JOIN workspace_members wm ON w.id = wm.\"workspaceId\" WHERE wm.\"userId\"='$USER_ID' LIMIT 1;")

    if [ -n "$WORKSPACE_ID" ]; then
        break
    fi

    attempt=$((attempt + 1))
    echo "  Waiting for default workspace/org bootstrap... attempt $attempt/$max_attempts"
    sleep 5
done

if [ -z "$WORKSPACE_ID" ]; then
    log_warning "No default workspace found for user after signup bootstrap. Attaching user to an existing local workspace."
    fallback_workspace=$(global_psql global_tenant \
        "SELECT id || '|' || \"tenantId\" || '|' || COALESCE(\"organizationId\", '') FROM workspaces WHERE status='ACTIVE' AND \"organizationId\" IS NOT NULL ORDER BY \"createdAt\" ASC LIMIT 1;")

    if [ -z "$fallback_workspace" ]; then
        log_error "No active workspace exists for local E2E fallback."
        exit 1
    fi

    WORKSPACE_ID=$(echo "$fallback_workspace" | cut -d'|' -f1)
    TENANT_ID=$(echo "$fallback_workspace" | cut -d'|' -f2)
    ORG_ID=$(echo "$fallback_workspace" | cut -d'|' -f3)
    FALLBACK_WORKSPACE_CONTEXT=true
    ISSUE_WORKSPACE_TOKEN_ACTOR_TYPE="super_admin"

    org_member_id=$(new_uuid)
    workspace_member_id=$(new_uuid)

    # Use ORG_ADMIN (not OWNER) so the user passes the
    # `userHasOrgRole(..., [ORG_ADMIN])` gate in
    # global-tenant-svc/src/modules/workspace/resolvers/workspace.mutation.ts
    # — otherwise createWorkspace / archiveWorkspace / etc. fail with
    # "FORBIDDEN: only organization admins can create workspaces" and the
    # workspace-doctor write-path scripts skip.
    global_psql global_tenant \
        "INSERT INTO organization_members (id, \"organizationId\", \"userId\", role, \"createdBy\", \"onBehalfOf\", \"createdAt\", \"updatedAt\") VALUES ('$org_member_id', '$ORG_ID', '$USER_ID', 'ORG_ADMIN', '$USER_ID', '$USER_ID', NOW(), NOW()) ON CONFLICT (\"organizationId\", \"userId\") DO UPDATE SET role='ORG_ADMIN', \"updatedAt\"=NOW();" > /dev/null

    global_psql global_tenant \
        "INSERT INTO workspace_members (id, \"workspaceId\", \"userId\", role, \"createdBy\", \"onBehalfOf\", \"createdAt\", \"updatedAt\") VALUES ('$workspace_member_id', '$WORKSPACE_ID', '$USER_ID', 'WORKSPACE_ADMIN', '$USER_ID', '$USER_ID', NOW(), NOW()) ON CONFLICT (\"workspaceId\", \"userId\") DO UPDATE SET role='WORKSPACE_ADMIN', \"updatedAt\"=NOW();" > /dev/null

    # The two layers intentionally use different role enums:
    #   - global_tenant.workspace_members.role: uppercase (WORKSPACE_ADMIN /
    #     WORKSPACE_MEMBER), gated by global-tenant-svc resolvers.
    #   - wspace_workspace."WorkspaceMember".role: lowercase ('owner' /
    #     'admin' / 'member'), gated by wspace-workspace-svc resolvers.
    # They are not a cross-layer mirror — each layer owns its own RBAC
    # vocabulary. Keep both seeded so checks on either side pass.
    wspace_member_id=$(new_uuid)
    wspace_psql wspace_workspace \
        "INSERT INTO \"WorkspaceMember\" (id, \"workspaceId\", \"userId\", role, status, \"createdBy\", \"onBehalfOf\", \"createdAt\", \"updatedAt\") SELECT '$wspace_member_id', '$WORKSPACE_ID', '$USER_ID', 'owner', 'active', '$USER_ID', '$USER_ID', NOW(), NOW() WHERE NOT EXISTS (SELECT 1 FROM \"WorkspaceMember\" WHERE \"workspaceId\"='$WORKSPACE_ID' AND \"userId\"='$USER_ID' AND \"deletedAt\" IS NULL);" > /dev/null
else
    TENANT_ID=$(global_psql global_tenant \
        "SELECT \"tenantId\" FROM workspaces WHERE id='$WORKSPACE_ID';")

    ORG_ID=$(global_psql global_tenant \
        "SELECT \"organizationId\" FROM workspaces WHERE id='$WORKSPACE_ID';")
fi

log_success "Default tenant/org/workspace bootstrap verified"
echo "  Workspace ID: $WORKSPACE_ID"
echo "  Tenant ID: $TENANT_ID"
echo "  Organization ID: $ORG_ID"

echo "  Verifying cross-layer sync to workspace layer..."
attempt=0
max_attempts="${E2E_WORKSPACE_SYNC_MAX_ATTEMPTS:-24}"
WSPACE_MEMBER_CHECK=""
PROJECT_ID=""
PROJECT_NAME=""
PROJECT_MEMBER_CHECK=""

while [ "$attempt" -lt "$max_attempts" ]; do
    WSPACE_MEMBER_CHECK=$(wspace_psql wspace_workspace \
        "SELECT id FROM \"WorkspaceMember\" WHERE \"workspaceId\"='$WORKSPACE_ID' AND \"userId\"='$USER_ID' AND \"deletedAt\" IS NULL LIMIT 1;")

    PROJECT_ID=$(wspace_psql wspace_workspace \
        "SELECT id FROM \"Project\" WHERE \"workspaceId\"='$WORKSPACE_ID' AND \"deletedAt\" IS NULL ORDER BY \"createdAt\" ASC LIMIT 1;")

    if [ -n "$PROJECT_ID" ]; then
        PROJECT_NAME=$(wspace_psql wspace_workspace \
            "SELECT name FROM \"Project\" WHERE id='$PROJECT_ID' LIMIT 1;")
        PROJECT_MEMBER_CHECK=$(wspace_psql wspace_workspace \
            "SELECT id FROM \"ProjectMember\" WHERE \"projectId\"='$PROJECT_ID' AND \"userId\"='$USER_ID' AND \"deletedAt\" IS NULL LIMIT 1;")

        if [ "$FALLBACK_WORKSPACE_CONTEXT" = true ] && [ -z "$PROJECT_MEMBER_CHECK" ]; then
            project_member_id=$(new_uuid)
            wspace_psql wspace_workspace \
                "INSERT INTO \"ProjectMember\" (id, \"projectId\", \"userId\", role, \"workspaceId\", \"createdBy\", \"onBehalfOf\", \"createdAt\", \"updatedAt\") SELECT '$project_member_id', '$PROJECT_ID', '$USER_ID', 'owner', '$WORKSPACE_ID', '$USER_ID', '$USER_ID', NOW(), NOW() WHERE NOT EXISTS (SELECT 1 FROM \"ProjectMember\" WHERE \"projectId\"='$PROJECT_ID' AND \"userId\"='$USER_ID' AND \"deletedAt\" IS NULL);" > /dev/null
            PROJECT_MEMBER_CHECK=$(wspace_psql wspace_workspace \
                "SELECT id FROM \"ProjectMember\" WHERE \"projectId\"='$PROJECT_ID' AND \"userId\"='$USER_ID' AND \"deletedAt\" IS NULL LIMIT 1;")
        fi
    fi

    if [ -n "$WSPACE_MEMBER_CHECK" ] && [ -n "$PROJECT_ID" ] && [ -n "$PROJECT_MEMBER_CHECK" ]; then
        break
    fi

    attempt=$((attempt + 1))
    echo "  Waiting for workspace-layer sync/default project... attempt $attempt/$max_attempts"
    sleep 5
done

if [ -z "$WSPACE_MEMBER_CHECK" ]; then
    log_error "Workspace member sync missing in workspace layer"
    exit 1
fi

if [ -z "$PROJECT_ID" ]; then
    log_error "No default project found for workspace. Signup bootstrap is incomplete."
    exit 1
fi

if [ -z "$PROJECT_MEMBER_CHECK" ]; then
    log_error "Default project membership missing for bootstrap user"
    exit 1
fi

log_success "Cross-layer sync verified: workspace member exists in workspace layer"
log_success "Default project verified in workspace layer"
echo "  Project ID: $PROJECT_ID"
echo "  Project Name: ${PROJECT_NAME:-<unknown>}"
log_success "Default project membership verified for bootstrap user"
echo ""

# =============================================================================
# STEP 5: Get Workspace Token
# =============================================================================
echo -e "${BLUE}Step 5: Getting workspace token...${NC}"

WSPACE_AUTH_URL="${WSPACE_AUTH_SVC_URL:-$WSPACE_PUBLIC_GATEWAY}"

create_secret_payload=$(jq -n \
    --arg query 'mutation CreateWorkspaceSecret($workspaceId: String!) { createWorkspaceSecret(workspaceId: $workspaceId) { success } }' \
    --arg workspaceId "$WORKSPACE_ID" \
    '{query: $query, variables: {workspaceId: $workspaceId}}')

curl -s -X POST "$WSPACE_AUTH_URL" \
    -H "Content-Type: application/json" \
    -H "x-actor-id: workspaces-doctor" \
    -H "x-actor-type: service" \
    -H "x-workspace-id: ${WORKSPACE_ID}" \
    -d "$create_secret_payload" > /tmp/e2e-workspace-secret.json

issue_token_payload=$(jq -n \
    --arg query 'mutation IssueWorkspaceToken($input: IssueWorkspaceTokenInput!) { issueWorkspaceToken(input: $input) { success token expiresAt scopes error { code message } } }' \
    --arg workspaceId "$WORKSPACE_ID" \
    --arg organizationId "$ORG_ID" \
    '{query: $query, variables: {input: {workspaceId: $workspaceId, organizationId: $organizationId}}}')

WORKSPACE_TOKEN_RESPONSE=$(curl -s -X POST "$WSPACE_AUTH_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    -H "x-actor-id: ${USER_ID}" \
    -H "x-actor-type: ${ISSUE_WORKSPACE_TOKEN_ACTOR_TYPE}" \
    -H "x-workspace-id: ${WORKSPACE_ID}" \
    -H "x-tenant-id: ${TENANT_ID}" \
    -d "$issue_token_payload")

if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}<<< RESPONSE:${NC}"
    echo "$WORKSPACE_TOKEN_RESPONSE" | jq .
fi

WORKSPACE_TOKEN=$(echo "$WORKSPACE_TOKEN_RESPONSE" | jq -r '.data.issueWorkspaceToken.token // empty')
TOKEN_SUCCESS=$(echo "$WORKSPACE_TOKEN_RESPONSE" | jq -r '.data.issueWorkspaceToken.success')

token_attempt=0
token_max_attempts=12
while { [ "$TOKEN_SUCCESS" != "true" ] || [ -z "$WORKSPACE_TOKEN" ] || [ "$WORKSPACE_TOKEN" = "null" ]; } && [ "$token_attempt" -lt "$token_max_attempts" ]; do
    token_attempt=$((token_attempt + 1))
    echo "  Waiting for workspace token issuance... attempt $token_attempt/$token_max_attempts"
    sleep 5
    WORKSPACE_TOKEN_RESPONSE=$(curl -s -X POST "$WSPACE_AUTH_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${AUTH_TOKEN}" \
        -H "x-actor-id: ${USER_ID}" \
        -H "x-actor-type: ${ISSUE_WORKSPACE_TOKEN_ACTOR_TYPE}" \
        -H "x-workspace-id: ${WORKSPACE_ID}" \
        -H "x-tenant-id: ${TENANT_ID}" \
        -d "$issue_token_payload")
    WORKSPACE_TOKEN=$(echo "$WORKSPACE_TOKEN_RESPONSE" | jq -r '.data.issueWorkspaceToken.token // empty')
    TOKEN_SUCCESS=$(echo "$WORKSPACE_TOKEN_RESPONSE" | jq -r '.data.issueWorkspaceToken.success')
done

if [ "$TOKEN_SUCCESS" = "true" ] && [ -n "$WORKSPACE_TOKEN" ] && [ "$WORKSPACE_TOKEN" != "null" ]; then
    log_success "Workspace token obtained"
    echo "  Token: ${WORKSPACE_TOKEN:0:30}..."
else
    log_error "Could not get workspace token after waiting for membership/secret propagation"
    echo "$WORKSPACE_TOKEN_RESPONSE" | jq .
    exit 1
fi
echo ""

# =============================================================================
# STEP 6: Get Additional Context (Workspace Name, Org Name, etc.)
# =============================================================================
echo -e "${BLUE}Step 6: Fetching additional context...${NC}"

CONTEXT_QUERY='query MyWorkspaces { myWorkspaces(limit: 1) { items { id name slug tenantId organizationId } } }'
CONTEXT_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$CONTEXT_QUERY" "{}" "$AUTH_TOKEN" "Get Workspace Context")

if [ "$VERBOSE" = true ]; then
    echo -e "${BLUE}<<< RESPONSE:${NC}"
    echo "$CONTEXT_RESPONSE" | jq .
fi

WORKSPACE_NAME=$(echo "$CONTEXT_RESPONSE" | jq -r '.data.myWorkspaces.items[0].name // empty')
WORKSPACE_SLUG=$(echo "$CONTEXT_RESPONSE" | jq -r '.data.myWorkspaces.items[0].slug // empty')

log_success "Context fetched"
echo "  Workspace Name: $WORKSPACE_NAME"
echo "  Workspace Slug: $WORKSPACE_SLUG"
echo ""

# =============================================================================
# STEP 6.5: Resolve internal service trust tokens
# =============================================================================
# Some module tests (devportal app lifecycle, security, rbac, integrations)
# need to call internal mutations behind @requiresActorType(service|super_admin).
# Those svcs trust the inbound x-internal-service-token header when its value
# matches their TRUSTED_GATEWAY_TOKEN env. We extract the live token from the
# devportal svc container so doctor stays in sync with whatever the gateway
# is using locally. Falls back to the doctor-local default used by the
# security/rbac modules if the container isn't reachable.
echo -e "${BLUE}Step 6.5: Resolving internal service trust tokens...${NC}"

resolve_trust_token() {
    if command -v docker >/dev/null 2>&1; then
        local token
        for container in global-devportal-svc global-auth-svc wspace-security-svc; do
            token="$(docker exec "$container" printenv TRUSTED_GATEWAY_TOKEN 2>/dev/null || true)"
            if [ -z "$token" ]; then
                token="$(docker exec "$container" printenv INTERNAL_SERVICE_TOKEN 2>/dev/null || true)"
            fi
            if [ -n "$token" ]; then
                printf '%s' "$token"
                return
            fi
        done
    fi
    printf '%s' 'doctor-local-trust-token'
}

DEVPORTAL_INTERNAL_TOKEN="$(resolve_trust_token)"
log_success "Internal service trust token resolved (${#DEVPORTAL_INTERNAL_TOKEN} chars)"
echo ""

# =============================================================================
# STEP 7: Save Environment File
# =============================================================================
echo -e "${BLUE}Step 7: Saving environment file...${NC}"

mkdir -p "$ENV_DIR"

cat > "$ENV_FILE" << EOF
#!/bin/bash
# =============================================================================
# E2E Test Environment
# Generated: $(date -Iseconds)
# Prefix: $PREFIX
# =============================================================================

# User credentials
export E2E_USER_ID="$USER_ID"
export E2E_USER_EMAIL="$TEST_EMAIL"
export E2E_USER_USERNAME="$TEST_USERNAME"
export E2E_USER_PASSWORD="$TEST_PASSWORD"
export E2E_USER_NAME="$TEST_NAME"

# Authentication tokens
export E2E_AUTH_TOKEN="$AUTH_TOKEN"
export E2E_REFRESH_TOKEN="$REFRESH_TOKEN"
export E2E_WORKSPACE_TOKEN="$WORKSPACE_TOKEN"

# Resource IDs
export E2E_TENANT_ID="$TENANT_ID"
export E2E_ORG_ID="$ORG_ID"
export E2E_WORKSPACE_ID="$WORKSPACE_ID"
export E2E_PROJECT_ID="$PROJECT_ID"

# Resource metadata
export E2E_WORKSPACE_NAME="$WORKSPACE_NAME"
export E2E_WORKSPACE_SLUG="$WORKSPACE_SLUG"
export E2E_PROJECT_NAME="$PROJECT_NAME"

# Timestamps
export E2E_CREATED_AT="$(date -Iseconds)"
export E2E_TIMESTAMP="$TIMESTAMP"

# API endpoints (gateways only - never call services directly!)
export E2E_GLOBAL_GATEWAY="$GLOBAL_GATEWAY"
export E2E_WSPACE_PUBLIC_GATEWAY="$WSPACE_PUBLIC_GATEWAY"

# Internal service trust tokens (kept in sync with svc TRUSTED_GATEWAY_TOKEN env)
# - E2E_INTERNAL_SERVICE_TOKEN: shared default consumed by common.sh and most module tests
# - E2E_DEVPORTAL_INTERNAL_TOKEN: alias used by global/modules/devportal/tests/*
export E2E_INTERNAL_SERVICE_TOKEN="$DEVPORTAL_INTERNAL_TOKEN"
export E2E_DEVPORTAL_INTERNAL_TOKEN="$DEVPORTAL_INTERNAL_TOKEN"

# Helper function to refresh token with transient-error retry
e2e_refresh_token() {
    local attempt=1
    local delay=1
    local max_attempts=5
    local response
    local http_code

    while [ "\$attempt" -le "\$max_attempts" ]; do
        response=\$(curl -s -w "\\n%{http_code}" -X POST "\$E2E_GLOBAL_GATEWAY" \\
            -H "Content-Type: application/json" \\
            -d "{\"query\":\"mutation { refreshToken(token: \\\"\$E2E_REFRESH_TOKEN\\\") { accessToken refreshToken } }\"}" 2>/dev/null)
        http_code=\$(echo "\$response" | tail -n 1)
        response=\$(echo "\$response" | sed '\$d')

        if [ "\$http_code" = "200" ] && [ -n "\$response" ]; then
            break
        fi

        if [ "\$http_code" = "503" ] || [ -z "\$response" ] || [ "\$http_code" = "000" ]; then
            echo "[e2e_refresh_token] transient error (http=\$http_code), attempt \$attempt/\$max_attempts, retrying in \${delay}s..." >&2
            sleep "\$delay"
            delay=\$((delay * 2))
            attempt=\$((attempt + 1))
            continue
        fi

        break
    done

    export E2E_AUTH_TOKEN=\$(echo "\$response" | jq -r '.data.refreshToken.accessToken // empty')
    export E2E_REFRESH_TOKEN=\$(echo "\$response" | jq -r '.data.refreshToken.refreshToken // empty')

    if [ -n "\$E2E_AUTH_TOKEN" ] && [ "\$E2E_AUTH_TOKEN" != "null" ]; then
        echo "Token refreshed successfully"
    else
        echo "Failed to refresh token"
        return 1
    fi
}

# Print info to stderr so it doesn't pollute stdout when sourced
echo "E2E environment loaded:" >&2
echo "  User: \$E2E_USER_EMAIL" >&2
echo "  Tenant: \$E2E_TENANT_ID" >&2
echo "  Workspace: \$E2E_WORKSPACE_ID" >&2
echo "  Project: \$E2E_PROJECT_ID" >&2
EOF

chmod +x "$ENV_FILE"

log_success "Environment file saved: $ENV_FILE"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=====================================================================${NC}"
echo -e "${GREEN}Bootstrap Complete!${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo ""
echo "Environment Summary:"
echo "  User ID:       $USER_ID"
echo "  Email:         $TEST_EMAIL"
echo "  Tenant ID:     $TENANT_ID"
echo "  Org ID:        $ORG_ID"
echo "  Workspace ID:  $WORKSPACE_ID"
echo ""
echo "To use this environment in other scripts:"
echo "  source $ENV_FILE"
echo ""
echo "Individual IDs:"
echo "  TENANT_ID=$TENANT_ID"
echo "  ORG_ID=$ORG_ID"
echo "  WORKSPACE_ID=$WORKSPACE_ID"
echo "  AUTH_TOKEN=<redacted; source $ENV_FILE>"
echo ""
