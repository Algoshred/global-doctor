#!/bin/bash

# =============================================================================
# Teardown E2E Environment
# Cleans up resources created by bootstrap-env.sh
#
# Usage: ./teardown-env.sh [--force] [--keep-user]
#   --force: Skip confirmation prompt
#   --keep-user: Keep the test user (only clean up workspaces/orgs)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Parse arguments
FORCE=false
KEEP_USER=false
VERBOSE=${VERBOSE:-true}

for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE=true
            shift
            ;;
        --keep-user)
            KEEP_USER=true
            shift
            ;;
        --quiet|-q)
            VERBOSE=false
            shift
            ;;
    esac
done

# Configuration
GLOBAL_GATEWAY="http://localhost:4000/global/graphql"
ENV_FILE="$ENV_DIR/e2e-env.sh"

# =============================================================================
echo ""
echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}Teardown E2E Environment${NC}"
echo -e "${BLUE}=====================================================================${NC}"
echo ""

# Check if env file exists
if [ ! -f "$ENV_FILE" ]; then
    log_warning "No environment file found: $ENV_FILE"
    echo "Nothing to teardown. Run 'make bootstrap-env' first."
    exit 0
fi

# Load environment
source "$ENV_FILE"

echo "Environment to teardown:"
echo "  User:      $E2E_USER_EMAIL"
echo "  User ID:   $E2E_USER_ID"
echo "  Tenant:    $E2E_TENANT_ID"
echo "  Org:       $E2E_ORG_ID"
echo "  Workspace: $E2E_WORKSPACE_ID"
echo ""

# Confirmation
if [ "$FORCE" != true ]; then
    echo -e "${RED}WARNING: This will delete the following resources:${NC}"
    if [ "$KEEP_USER" != true ]; then
        echo "  - Test user account"
    fi
    echo "  - Created workspaces (if any)"
    echo "  - Environment file"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

# =============================================================================
# Helper function for GraphQL requests
# =============================================================================
graphql_request() {
    local url="$1"
    local query="$2"
    local variables="$3"
    local auth_token="$4"
    local description="$5"

    local data=$(jq -n --arg q "$query" --argjson v "${variables:-"{}"}" '{query: $q, variables: $v}')

    if [ "$VERBOSE" = true ]; then
        echo ""
        echo -e "${BLUE}>>> REQUEST: $description${NC}"
        echo -e "${YELLOW}POST $url${NC}"
        echo -e "${YELLOW}Body: $(echo "$data" | jq -c .)${NC}"
        echo ""
    fi

    local response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $auth_token" \
        -d "$data")

    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}<<< RESPONSE:${NC}"
        echo "$response" | jq .
    fi

    echo "$response"
}

# =============================================================================
# STEP 1: Sign out from all sessions
# =============================================================================
echo -e "${BLUE}Step 1: Signing out from all sessions...${NC}"

if [ -n "$E2E_AUTH_TOKEN" ]; then
    SIGNOUT_QUERY='mutation SignOut { signOut }'
    SIGNOUT_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$SIGNOUT_QUERY" "{}" "$E2E_AUTH_TOKEN" "Sign Out")
    log_success "Signed out"
else
    log_warning "No auth token, skipping signout"
fi
echo ""

# =============================================================================
# STEP 2: Archive/Delete created workspaces (if any additional ones)
# =============================================================================
echo -e "${BLUE}Step 2: Archiving any additional workspaces...${NC}"

# First, try to get a fresh token by signing in again
SIGNIN_QUERY='mutation SignIn($input: SignInInput!) { signIn(input: $input) { accessToken } }'
SIGNIN_VARS=$(jq -n \
    --arg email "$E2E_USER_EMAIL" \
    --arg password "$E2E_USER_PASSWORD" \
    '{input: {email: $email, password: $password}}')

SIGNIN_RESPONSE=$(curl -s -X POST "$GLOBAL_GATEWAY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$SIGNIN_QUERY" --argjson v "$SIGNIN_VARS" '{query: $q, variables: $v}')")

FRESH_TOKEN=$(echo "$SIGNIN_RESPONSE" | jq -r '.data.signIn.accessToken // empty')

if [ -n "$FRESH_TOKEN" ] && [ "$FRESH_TOKEN" != "null" ]; then
    # List user's workspaces
    LIST_QUERY='query { myWorkspaces(limit: 100) { items { id name status } } }'
    LIST_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$LIST_QUERY" "{}" "$FRESH_TOKEN" "List Workspaces")

    WORKSPACE_COUNT=$(echo "$LIST_RESPONSE" | jq -r '.data.myWorkspaces.items | length')
    log_info "Found $WORKSPACE_COUNT workspace(s)"

    # Archive each workspace
    for ws_id in $(echo "$LIST_RESPONSE" | jq -r '.data.myWorkspaces.items[].id'); do
        ARCHIVE_QUERY='mutation ArchiveWorkspace($id: ID!) { archiveWorkspace(id: $id) { id status } }'
        ARCHIVE_VARS=$(jq -n --arg id "$ws_id" '{id: $id}')
        ARCHIVE_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$ARCHIVE_QUERY" "$ARCHIVE_VARS" "$FRESH_TOKEN" "Archive Workspace $ws_id")

        STATUS=$(echo "$ARCHIVE_RESPONSE" | jq -r '.data.archiveWorkspace.status // empty')
        if [ "$STATUS" = "ARCHIVED" ]; then
            log_success "Archived workspace: $ws_id"
        else
            log_warning "Could not archive workspace: $ws_id"
        fi
    done
else
    log_warning "Could not get fresh token, skipping workspace cleanup"
fi
echo ""

# =============================================================================
# STEP 3: Deactivate user account (optional)
# =============================================================================
if [ "$KEEP_USER" != true ]; then
    echo -e "${BLUE}Step 3: Deactivating user account...${NC}"

    if [ -n "$FRESH_TOKEN" ] && [ "$FRESH_TOKEN" != "null" ]; then
        DEACTIVATE_QUERY='mutation DeactivateAccount($password: String!) { deactivateAccount(password: $password) { success message } }'
        DEACTIVATE_VARS=$(jq -n --arg password "$E2E_USER_PASSWORD" '{password: $password}')
        DEACTIVATE_RESPONSE=$(graphql_request "$GLOBAL_GATEWAY" "$DEACTIVATE_QUERY" "$DEACTIVATE_VARS" "$FRESH_TOKEN" "Deactivate Account")

        SUCCESS=$(echo "$DEACTIVATE_RESPONSE" | jq -r '.data.deactivateAccount.success')
        if [ "$SUCCESS" = "true" ]; then
            log_success "User account deactivated"
        else
            log_warning "Could not deactivate user account"
        fi
    else
        log_warning "No fresh token, skipping user deactivation"
    fi
else
    echo -e "${BLUE}Step 3: Keeping user account (--keep-user)${NC}"
fi
echo ""

# =============================================================================
# STEP 4: Clean up database entries (direct cleanup for orphaned data)
# =============================================================================
echo -e "${BLUE}Step 4: Cleaning up database entries...${NC}"

# Clean up verification tokens
if docker exec "${GLOBAL_POSTGRES_CONTAINER}" psql -U "${GLOBAL_POSTGRES_USER}" -d global_auth -c \
    "DELETE FROM email_verifications WHERE email='$E2E_USER_EMAIL';" 2>/dev/null; then
    log_success "Cleaned up verification tokens"
else
    log_warning "Could not clean up verification tokens"
fi

# Clean up workspace tokens
if [ -n "$E2E_WORKSPACE_ID" ]; then
    if docker exec "${WSPACE_POSTGRES_CONTAINER}" psql -U "${WSPACE_POSTGRES_USER}" -d wspace_auth -c \
        "DELETE FROM workspace_tokens WHERE \"workspaceId\"='$E2E_WORKSPACE_ID';" 2>/dev/null; then
        log_success "Cleaned up workspace tokens"
    else
        log_warning "Could not clean up workspace tokens"
    fi
fi
echo ""

# =============================================================================
# STEP 5: Remove environment file
# =============================================================================
echo -e "${BLUE}Step 5: Removing environment file...${NC}"

if [ -f "$ENV_FILE" ]; then
    rm "$ENV_FILE"
    log_success "Removed: $ENV_FILE"
else
    log_warning "Environment file already removed"
fi
echo ""

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=====================================================================${NC}"
echo -e "${GREEN}Teardown Complete!${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo ""
echo "Cleaned up:"
echo "  - User sessions signed out"
echo "  - Workspaces archived"
if [ "$KEEP_USER" != true ]; then
    echo "  - User account deactivated"
fi
echo "  - Database cleanup performed"
echo "  - Environment file removed"
echo ""
echo "To create a fresh environment:"
echo "  make bootstrap-env"
echo ""
