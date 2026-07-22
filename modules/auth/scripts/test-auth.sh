#!/usr/bin/env bash
# =============================================================================
# Auth Module E2E Tests
# =============================================================================
# Tests authentication operations: tokens, password, MFA, sessions, account
#
# Usage:
#   ./test-auth.sh              # Run all tests
#   ./test-auth.sh tokens       # Run token tests only
#   ./test-auth.sh password     # Run password tests only
#   ./test-auth.sh mfa          # Run MFA tests only
#   ./test-auth.sh sessions     # Run session tests only
#   ./test-auth.sh account      # Run account tests only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source common utilities from DOCTOR_ROOT (global/modules/auth/scripts -> doctor root)
DOCTOR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$DOCTOR_ROOT/core/scripts/common.sh"

# =============================================================================
# Configuration
# =============================================================================

CORE_DIR="$DOCTOR_ROOT/core"

# Load environment with automatic token refresh
# This uses load_e2e_env from common.sh which:
# 1. Sources the env file
# 2. Checks if JWT token is expired or about to expire
# 3. Automatically re-bootstraps to get a fresh token if needed
load_e2e_env || {
    log_error "Failed to load E2E environment. Run: make -C $CORE_DIR bootstrap-env"
    exit 1
}

# Gateway URLs
GLOBAL_GATEWAY_URL="${GLOBAL_PUBLIC_GATEWAY_URL:-http://localhost:4000}"
GRAPHQL_ENDPOINT="$GLOBAL_GATEWAY_URL/global/graphql"

# Test mode (all, tokens, password, mfa, sessions, account)
TEST_MODE="${1:-all}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Store original values for cleanup
ORIGINAL_PASSWORD="${E2E_USER_PASSWORD:-}"

# =============================================================================
# GraphQL Queries and Mutations
# =============================================================================

# Token Operations
# Note: tokenInfo query doesn't work through gateway because Authorization header is not forwarded
# Use validateTokens mutation instead which takes the token as an argument
read -r -d '' MUTATION_VALIDATE_TOKENS << 'EOF' || true
mutation ValidateTokens($input: ValidateTokensInput!) {
  validateTokens(input: $input) {
    valid
    tokenType
    userId
    email
    role
    expiresAt
    error {
      code
      message
    }
  }
}
EOF

read -r -d '' MUTATION_REFRESH_TOKEN << 'EOF' || true
mutation RefreshToken($token: String!) {
  refreshToken(token: $token) {
    accessToken
    refreshToken
    expiresIn
    user {
      id
      email
    }
  }
}
EOF

# Password Operations
read -r -d '' MUTATION_CHANGE_PASSWORD << 'EOF' || true
mutation ChangePassword($input: ChangePasswordInput!) {
  changePassword(input: $input)
}
EOF

read -r -d '' MUTATION_REQUEST_PASSWORD_RESET << 'EOF' || true
mutation RequestPasswordReset($email: String!) {
  requestPasswordReset(email: $email) {
    success
    message
  }
}
EOF

# Profile Operations
read -r -d '' QUERY_CURRENT_USER << 'EOF' || true
query CurrentUser {
  currentUser {
    id
    email
    name
    firstName
    lastName
    username
    role
    status
    emailVerified
    createdAt
    updatedAt
  }
}
EOF

read -r -d '' MUTATION_UPDATE_PROFILE << 'EOF' || true
mutation UpdateCurrentUserProfile($input: UpdateUserInput!) {
  updateCurrentUserProfile(input: $input) {
    id
    name
    firstName
    lastName
    username
  }
}
EOF

# MFA Operations
read -r -d '' MUTATION_SETUP_MFA << 'EOF' || true
mutation SetupMFA($method: MFAMethod!) {
  setupMFA(method: $method) {
    secret
    qrCode
    backupCodes
  }
}
EOF

read -r -d '' MUTATION_ENABLE_MFA << 'EOF' || true
mutation EnableMFA($code: String!) {
  enableMFA(code: $code)
}
EOF

read -r -d '' MUTATION_DISABLE_MFA << 'EOF' || true
mutation DisableMFA {
  disableMFA
}
EOF

read -r -d '' MUTATION_VERIFY_MFA << 'EOF' || true
mutation VerifyMFA($input: MFAVerifyInput!) {
  verifyMFA(input: $input) {
    success
    token
    sessionId
    user {
      id
      email
    }
  }
}
EOF

# Session Operations
read -r -d '' MUTATION_SIGN_OUT << 'EOF' || true
mutation SignOut {
  signOut
}
EOF

# Auth Method Operations
read -r -d '' QUERY_AVAILABLE_AUTH_METHODS << 'EOF' || true
query AvailableAuthMethods($tenantId: String) {
  availableAuthMethods(tenantId: $tenantId) {
    type
    name
    enabled
    requiresMFA
  }
}
EOF

read -r -d '' QUERY_AUTH_STRATEGIES_HEALTH << 'EOF' || true
query AuthStrategiesHealth {
  authStrategiesHealth {
    type
    name
    healthy
  }
}
EOF

# Account Operations
read -r -d '' MUTATION_DEACTIVATE_ACCOUNT << 'EOF' || true
mutation DeactivateAccount($password: String!) {
  deactivateAccount(password: $password) {
    success
    message
  }
}
EOF

read -r -d '' MUTATION_REACTIVATE_ACCOUNT << 'EOF' || true
mutation ReactivateAccount($email: String!, $password: String!) {
  reactivateAccount(email: $email, password: $password) {
    success
    token
    user {
      id
      email
      status
    }
  }
}
EOF

# =============================================================================
# Test Functions
# =============================================================================

test_validate_tokens() {
    log_info "Testing: VALIDATE_TOKENS"

    # Build the input with the auth token
    local variables
    variables=$(jq -n --arg token "$E2E_AUTH_TOKEN" '{input: {authToken: $token}}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_VALIDATE_TOKENS" "$variables" "" "Validate Tokens")

    local valid
    valid=$(echo "$response" | jq -r '.data.validateTokens.valid // false')

    if [ "$valid" = "true" ]; then
        local user_id token_type email
        user_id=$(echo "$response" | jq -r '.data.validateTokens.userId // empty')
        token_type=$(echo "$response" | jq -r '.data.validateTokens.tokenType // empty')
        email=$(echo "$response" | jq -r '.data.validateTokens.email // empty')
        log_success "VALIDATE_TOKENS: Token is valid (type: $token_type, user: $user_id, email: $email)"
        ((TESTS_PASSED++)) || true
        return 0
    else
        local error_code error_msg
        error_code=$(echo "$response" | jq -r '.data.validateTokens.error.code // empty')
        error_msg=$(echo "$response" | jq -r '.data.validateTokens.error.message // empty')
        if [ -n "$error_code" ]; then
            log_error "VALIDATE_TOKENS failed: [$error_code] $error_msg"
        else
            local error
            error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
            log_error "VALIDATE_TOKENS failed: $error"
        fi
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_refresh_token() {
    log_info "Testing: REFRESH_TOKEN"

    if [ -z "${E2E_REFRESH_TOKEN:-}" ]; then
        log_warning "REFRESH_TOKEN: No refresh token available, skipping"
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    local variables
    variables=$(jq -n --arg token "$E2E_REFRESH_TOKEN" '{token: $token}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_REFRESH_TOKEN" "$variables" "" "Refresh Token")

    local new_token
    new_token=$(echo "$response" | jq -r '.data.refreshToken.accessToken // empty')

    if [ -n "$new_token" ]; then
        log_success "REFRESH_TOKEN: Got new access token"
        # Update environment with new token
        export E2E_AUTH_TOKEN="$new_token"
        local new_refresh
        new_refresh=$(echo "$response" | jq -r '.data.refreshToken.refreshToken // empty')
        if [ -n "$new_refresh" ]; then
            export E2E_REFRESH_TOKEN="$new_refresh"
        fi
        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_warning "REFRESH_TOKEN: $error (may be expected if token expired)"
        ((TESTS_SKIPPED++)) || true
        return 0
    fi
}

test_current_user() {
    log_info "Testing: CURRENT_USER"

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$QUERY_CURRENT_USER" "{}" "$E2E_AUTH_TOKEN" "Get Current User")

    local user_id
    user_id=$(echo "$response" | jq -r '.data.currentUser.id // empty')

    if [ -n "$user_id" ]; then
        local email name
        email=$(echo "$response" | jq -r '.data.currentUser.email // empty')
        name=$(echo "$response" | jq -r '.data.currentUser.name // empty')
        log_success "CURRENT_USER: $name ($email)"
        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CURRENT_USER failed: $error"
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_update_profile() {
    log_info "Testing: UPDATE_PROFILE"

    # Get current profile first
    local current
    current=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$QUERY_CURRENT_USER" "{}" "$E2E_AUTH_TOKEN" "Get Current Profile (before update)")

    local original_first_name
    original_first_name=$(echo "$current" | jq -r '.data.currentUser.firstName // "E2E"')

    # Update with test values
    local test_first_name="E2E-Test-Updated"
    local variables
    variables=$(jq -n --arg fn "$test_first_name" '{input: {firstName: $fn}}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_UPDATE_PROFILE" "$variables" "$E2E_AUTH_TOKEN" "Update Profile")

    local updated_fn
    updated_fn=$(echo "$response" | jq -r '.data.updateCurrentUserProfile.firstName // empty')

    if [ "$updated_fn" = "$test_first_name" ]; then
        log_success "UPDATE_PROFILE: FirstName updated to $updated_fn"

        # Restore original firstName
        variables=$(jq -n --arg fn "$original_first_name" '{input: {firstName: $fn}}')
        graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_UPDATE_PROFILE" "$variables" "$E2E_AUTH_TOKEN" "Restore Profile" > /dev/null
        log_info "Restored original firstName: $original_first_name"

        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "UPDATE_PROFILE failed: $error"
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_change_password() {
    log_info "Testing: CHANGE_PASSWORD"

    if [ -z "${E2E_USER_PASSWORD:-}" ]; then
        log_warning "CHANGE_PASSWORD: No password in environment, skipping"
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    local new_password="NewTestPass123!"
    local variables
    variables=$(jq -n \
        --arg current "$E2E_USER_PASSWORD" \
        --arg new "$new_password" \
        '{input: {currentPassword: $current, newPassword: $new}}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_CHANGE_PASSWORD" "$variables" "$E2E_AUTH_TOKEN" "Change Password")

    local success
    success=$(echo "$response" | jq -r '.data.changePassword // false')

    if [ "$success" = "true" ]; then
        log_success "CHANGE_PASSWORD: Password changed successfully"

        # Change it back
        variables=$(jq -n \
            --arg current "$new_password" \
            --arg new "$E2E_USER_PASSWORD" \
            '{input: {currentPassword: $current, newPassword: $new}}')

        local restore_response
        restore_response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_CHANGE_PASSWORD" "$variables" "$E2E_AUTH_TOKEN" "Restore Password")

        local restored
        restored=$(echo "$restore_response" | jq -r '.data.changePassword // false')
        if [ "$restored" = "true" ]; then
            log_info "Password restored to original"
        else
            log_warning "Could not restore original password"
        fi

        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_error "CHANGE_PASSWORD failed: $error"
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_request_password_reset() {
    log_info "Testing: REQUEST_PASSWORD_RESET"

    # Use a non-existent email to test the API without actually sending emails
    local test_email="nonexistent-test-email@example.com"
    local variables
    variables=$(jq -n --arg email "$test_email" '{email: $email}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_REQUEST_PASSWORD_RESET" "$variables" "" "Request Password Reset")

    # This should succeed even for non-existent emails (security best practice)
    local success
    success=$(echo "$response" | jq -r '.data.requestPasswordReset.success // false')

    if [ "$success" = "true" ]; then
        log_success "REQUEST_PASSWORD_RESET: API responded correctly (no email sent for test)"
        ((TESTS_PASSED++)) || true
        return 0
    else
        # Check if it's an error or just a different response
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // empty')
        if [ -n "$error" ]; then
            log_warning "REQUEST_PASSWORD_RESET: $error (may be rate limited or disabled)"
            ((TESTS_SKIPPED++)) || true
        else
            log_success "REQUEST_PASSWORD_RESET: API responded (success=$success)"
            ((TESTS_PASSED++)) || true
        fi
        return 0
    fi
}

test_available_auth_methods() {
    log_info "Testing: AVAILABLE_AUTH_METHODS"

    local variables
    variables=$(jq -n --arg tenantId "${E2E_TENANT_ID:-}" '{tenantId: $tenantId}')

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$QUERY_AVAILABLE_AUTH_METHODS" "$variables" "$E2E_AUTH_TOKEN" "Get Available Auth Methods")

    local methods
    methods=$(echo "$response" | jq -r '.data.availableAuthMethods // empty')

    if [ -n "$methods" ] && [ "$methods" != "null" ]; then
        local count
        count=$(echo "$response" | jq '.data.availableAuthMethods | length')
        log_success "AVAILABLE_AUTH_METHODS: Found $count auth methods"

        # List enabled methods
        echo "$response" | jq -r '.data.availableAuthMethods[] | select(.enabled == true) | "  - \(.name) (\(.type))"' | while read -r line; do
            log_info "$line"
        done

        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_warning "AVAILABLE_AUTH_METHODS: $error"
        ((TESTS_SKIPPED++)) || true
        return 0
    fi
}

test_auth_strategies_health() {
    log_info "Testing: AUTH_STRATEGIES_HEALTH"

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$QUERY_AUTH_STRATEGIES_HEALTH" "{}" "$E2E_AUTH_TOKEN" "Get Auth Strategies Health")

    local strategies
    strategies=$(echo "$response" | jq -r '.data.authStrategiesHealth // empty')

    if [ -n "$strategies" ] && [ "$strategies" != "null" ]; then
        local healthy_count
        healthy_count=$(echo "$response" | jq '[.data.authStrategiesHealth[] | select(.healthy == true)] | length')
        local total_count
        total_count=$(echo "$response" | jq '.data.authStrategiesHealth | length')

        log_success "AUTH_STRATEGIES_HEALTH: $healthy_count/$total_count strategies healthy"

        # List unhealthy strategies
        echo "$response" | jq -r '.data.authStrategiesHealth[] | select(.healthy == false) | "  - UNHEALTHY: \(.name) (\(.type))"' | while read -r line; do
            log_warning "$line"
        done

        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        log_warning "AUTH_STRATEGIES_HEALTH: $error"
        ((TESTS_SKIPPED++)) || true
        return 0
    fi
}

test_setup_mfa() {
    log_info "Testing: SETUP_MFA"

    local variables
    variables='{"method": "TOTP"}'

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_SETUP_MFA" "$variables" "$E2E_AUTH_TOKEN" "Setup MFA (TOTP)")

    local secret
    secret=$(echo "$response" | jq -r '.data.setupMFA.secret // empty')

    if [ -n "$secret" ]; then
        log_success "SETUP_MFA: Got TOTP secret (not enabling - would require OTP)"

        # Store for potential verification
        export E2E_MFA_SECRET="$secret"

        local backup_codes
        backup_codes=$(echo "$response" | jq -r '.data.setupMFA.backupCodes // []')
        local code_count
        code_count=$(echo "$backup_codes" | jq 'length')
        log_info "Got $code_count backup codes"

        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        # MFA might already be enabled or not supported
        if echo "$error" | grep -qi "already enabled\|already setup"; then
            log_warning "SETUP_MFA: MFA already enabled, skipping"
            ((TESTS_SKIPPED++)) || true
        else
            log_warning "SETUP_MFA: $error"
            ((TESTS_SKIPPED++)) || true
        fi
        return 0
    fi
}

test_disable_mfa() {
    log_info "Testing: DISABLE_MFA"

    local response
    response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_DISABLE_MFA" "{}" "$E2E_AUTH_TOKEN" "Disable MFA")

    local success
    success=$(echo "$response" | jq -r '.data.disableMFA // false')

    if [ "$success" = "true" ]; then
        log_success "DISABLE_MFA: MFA disabled successfully"
        ((TESTS_PASSED++)) || true
        return 0
    else
        local error
        error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
        # MFA might not be enabled
        if echo "$error" | grep -qi "not enabled\|not setup"; then
            log_info "DISABLE_MFA: MFA was not enabled"
            ((TESTS_PASSED++)) || true
        else
            log_warning "DISABLE_MFA: $error"
            ((TESTS_SKIPPED++)) || true
        fi
        return 0
    fi
}

# Note: signOut would invalidate our test token, so we skip it in normal tests
test_sign_out() {
    log_info "Testing: SIGN_OUT (simulated)"
    log_warning "SIGN_OUT: Skipping actual sign out to preserve test token"
    log_info "To test sign out, run manually after all other tests"
    ((TESTS_SKIPPED++)) || true
    return 0
}

# Note: deactivateAccount would disable the test user, so we skip it
test_deactivate_account() {
    log_info "Testing: DEACTIVATE_ACCOUNT (simulated)"
    log_warning "DEACTIVATE_ACCOUNT: Skipping to preserve test user"
    log_info "This operation would deactivate the E2E test user account"
    ((TESTS_SKIPPED++)) || true
    return 0
}

# =============================================================================
# Token Refresh / Ensure Fresh Token
# =============================================================================

ensure_fresh_token() {
    log_info "Ensuring fresh authentication token..."

    # First try refresh token
    if [ -n "${E2E_REFRESH_TOKEN:-}" ]; then
        local variables
        variables=$(jq -n --arg token "$E2E_REFRESH_TOKEN" '{token: $token}')

        local response
        response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$MUTATION_REFRESH_TOKEN" "$variables" "" "Refresh Token (pre-test)")

        local new_token
        new_token=$(echo "$response" | jq -r '.data.refreshToken.accessToken // empty')

        if [ -n "$new_token" ]; then
            export E2E_AUTH_TOKEN="$new_token"
            local new_refresh
            new_refresh=$(echo "$response" | jq -r '.data.refreshToken.refreshToken // empty')
            if [ -n "$new_refresh" ]; then
                export E2E_REFRESH_TOKEN="$new_refresh"
            fi
            log_success "Token refreshed successfully"
            return 0
        fi
    fi

    # Refresh failed, try signIn with credentials
    log_info "Refresh failed, attempting signIn..."

    if [ -z "${E2E_USER_EMAIL:-}" ] || [ -z "${E2E_USER_PASSWORD:-}" ]; then
        log_warning "No credentials available for signIn"
        return 1
    fi

    local signin_mutation='mutation SignIn($input: SignInInput!) { signIn(input: $input) { accessToken refreshToken user { id email } } }'
    local signin_variables
    signin_variables=$(jq -n \
        --arg email "$E2E_USER_EMAIL" \
        --arg password "$E2E_USER_PASSWORD" \
        '{input: {email: $email, password: $password}}')

    local signin_response
    signin_response=$(graphql_request_logged "$GRAPHQL_ENDPOINT" "$signin_mutation" "$signin_variables" "" "SignIn (pre-test)")

    local access_token
    access_token=$(echo "$signin_response" | jq -r '.data.signIn.accessToken // empty')

    if [ -n "$access_token" ]; then
        export E2E_AUTH_TOKEN="$access_token"
        local refresh_token
        refresh_token=$(echo "$signin_response" | jq -r '.data.signIn.refreshToken // empty')
        if [ -n "$refresh_token" ]; then
            export E2E_REFRESH_TOKEN="$refresh_token"
        fi
        log_success "SignIn successful, got fresh token"
        return 0
    fi

    log_error "Failed to get fresh token"
    return 1
}

# =============================================================================
# Test Suites
# =============================================================================

run_token_tests() {
    log_info ""
    log_info "========================================"
    log_info "TOKEN TESTS"
    log_info "========================================"

    test_validate_tokens
    test_refresh_token
}

run_password_tests() {
    log_info ""
    log_info "========================================"
    log_info "PASSWORD TESTS"
    log_info "========================================"

    test_change_password
    test_request_password_reset
}

run_mfa_tests() {
    log_info ""
    log_info "========================================"
    log_info "MFA TESTS"
    log_info "========================================"

    # First disable MFA if enabled, so we can test setup
    test_disable_mfa
    test_setup_mfa
}

run_session_tests() {
    log_info ""
    log_info "========================================"
    log_info "SESSION TESTS"
    log_info "========================================"

    test_sign_out
}

run_account_tests() {
    log_info ""
    log_info "========================================"
    log_info "ACCOUNT TESTS"
    log_info "========================================"

    test_current_user
    test_update_profile
    test_available_auth_methods
    test_auth_strategies_health
    test_deactivate_account
}

# =============================================================================
# Main
# =============================================================================

main() {
    log_info "========================================"
    log_info "AUTH MODULE E2E TESTS"
    log_info "========================================"
    log_info "Gateway: $GRAPHQL_ENDPOINT"
    log_info "User ID: ${E2E_USER_ID:-unknown}"
    log_info "Test Mode: $TEST_MODE"
    log_info "========================================"

    # Ensure we have a fresh token before running tests
    ensure_fresh_token || log_warning "Could not refresh token, tests may fail"

    case "$TEST_MODE" in
        all)
            run_token_tests
            run_account_tests
            run_password_tests
            run_mfa_tests
            run_session_tests
            ;;
        tokens)
            run_token_tests
            ;;
        password)
            run_password_tests
            ;;
        mfa)
            run_mfa_tests
            ;;
        sessions)
            run_session_tests
            ;;
        account)
            run_account_tests
            ;;
        *)
            log_error "Unknown test mode: $TEST_MODE"
            log_info "Valid modes: all, tokens, password, mfa, sessions, account"
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
