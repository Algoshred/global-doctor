#!/usr/bin/env bash
# =============================================================================
# Common utility functions for E2E tests
# Workspaces-Doctor - Self-contained E2E Testing Framework
# =============================================================================

set -euo pipefail

# Colors for output
# Not marked readonly so scripts that define their own color constants can
# still source this file for shared helpers and DB container variables.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# Path Configuration (Self-Contained)
# =============================================================================

# Determine the repository root (workspaces-doctor)
_COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR_ROOT="${DOCTOR_ROOT:-$(cd "$_COMMON_SCRIPT_DIR/../.." && pwd)}"
CORE_DIR="${DOCTOR_ROOT}/core"
MODULES_DIR="${DOCTOR_ROOT}/modules"
ENV_DIR="${CORE_DIR}/env"
LOGS_DIR="${DOCTOR_ROOT}/logs"

# Products root (absolute path)
PRODUCTS_ROOT="${PRODUCTS_ROOT:-$HOME/products}"

# Canonical workspaces-doctor root (shared E2E bootstrap + env file)
WORKSPACES_DOCTOR_ROOT="${WORKSPACES_DOCTOR_ROOT:-$PRODUCTS_ROOT/workspaces/workspaces-doctor}"

# =============================================================================
# Shared Postgres Configuration
# =============================================================================
# The dev environment now uses consolidated Postgres containers that host
# multiple databases (one per service). These defaults keep all DB-aware
# scripts compatible without hardcoding legacy per-service container names.
export GLOBAL_POSTGRES_CONTAINER="${GLOBAL_POSTGRES_CONTAINER:-global-shared-postgres}"
export WSPACE_POSTGRES_CONTAINER="${WSPACE_POSTGRES_CONTAINER:-wspace-shared-postgres}"
export GLOBAL_POSTGRES_USER="${GLOBAL_POSTGRES_USER:-boffadmin_admin}"
export WSPACE_POSTGRES_USER="${WSPACE_POSTGRES_USER:-boffadmin_admin}"

# =============================================================================
# Logging Configuration
# =============================================================================

# Log file path (set by Makefile or default)
E2E_LOG_FILE="${E2E_LOG_FILE:-}"
E2E_VERBOSE="${E2E_VERBOSE:-true}"
E2E_LOG_REQUESTS="${E2E_LOG_REQUESTS:-true}"

# Logger name for log4net format
E2E_LOGGER_NAME="${E2E_LOGGER_NAME:-e2e.workspaces}"

# Initialize log file if set (log4net format doesn't need header)
init_log_file() {
    if [ -n "$E2E_LOG_FILE" ]; then
        local log_dir=$(dirname "$E2E_LOG_FILE")
        mkdir -p "$log_dir"
        # Start fresh - log4net parsers expect clean format
        : > "$E2E_LOG_FILE"
    fi
}

# Format timestamp in log4net style: YYYY-MM-DD HH:MM:SS,mmm
log4net_timestamp() {
    date '+%Y-%m-%d %H:%M:%S,000'
}

# Write log entry in log4net PatternLayout format
# Format: %date [%thread] %-5level %logger - %message
log4net_write() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(log4net_timestamp)
    # Pad level to 5 chars (left-aligned)
    printf -v padded_level "%-5s" "$level"
    echo "${timestamp} [main] ${padded_level} ${E2E_LOGGER_NAME} - ${message}" >> "$E2E_LOG_FILE"
}

# Write to both terminal (stderr) and log file (log4net format)
# Using stderr to avoid polluting stdout when functions capture output
log_output() {
    local message="$1"
    local level="${2:-INFO}"
    echo -e "$message" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        # Strip ANSI color codes and write in log4net format
        local clean_message
        clean_message=$(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')
        log4net_write "$level" "$clean_message"
    fi
}

# Logging functions with log4net levels
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "INFO" "$*"
    fi
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "INFO" "[SUCCESS] $*"
    fi
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "WARN" "$*"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "ERROR" "$*"
    fi
}

log_header() {
    echo -e "" >&2
    echo -e "${BLUE}=====================================================================${NC}" >&2
    echo -e "${BLUE}$*${NC}" >&2
    echo -e "${BLUE}=====================================================================${NC}" >&2
    echo -e "" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "INFO" "====================================================================="
        log4net_write "INFO" "$*"
        log4net_write "INFO" "====================================================================="
    fi
}

log_section() {
    echo -e "" >&2
    echo -e "${BLUE}--- $* ---${NC}" >&2
    echo -e "" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "INFO" "--- $* ---"
    fi
}

log_test() {
    echo -e "${CYAN}[TEST]${NC} $*" >&2
    if [ -n "$E2E_LOG_FILE" ]; then
        log4net_write "DEBUG" "[TEST] $*"
    fi
}

log_request() {
    if [ "$E2E_LOG_REQUESTS" = "true" ]; then
        echo -e "${CYAN}[REQUEST]${NC} $*" >&2
        if [ -n "$E2E_LOG_FILE" ]; then
            log4net_write "DEBUG" "[REQUEST] $*"
        fi
    fi
}

log_response() {
    if [ "$E2E_LOG_REQUESTS" = "true" ]; then
        echo -e "${MAGENTA}[RESPONSE]${NC} $*" >&2
        if [ -n "$E2E_LOG_FILE" ]; then
            log4net_write "DEBUG" "[RESPONSE] $*"
        fi
    fi
}

# =============================================================================
# HTTP Request Helpers with Logging
# =============================================================================

# Execute curl with request/response logging
# Usage: curl_logged [curl options...]
curl_logged() {
    local curl_cmd="curl $*"

    if [ "$E2E_LOG_REQUESTS" = "true" ]; then
        log_request "curl $*"
    fi

    local response
    response=$(curl "$@")
    local exit_code=$?

    if [ "$E2E_LOG_REQUESTS" = "true" ] && [ -n "$response" ]; then
        # Pretty print JSON if possible
        if echo "$response" | jq . > /dev/null 2>&1; then
            log_response "$(echo "$response" | jq -c .)"
        else
            log_response "$response"
        fi
    fi

    echo "$response"
    return $exit_code
}

# GraphQL request with full logging
# Usage: graphql_request_logged URL QUERY VARIABLES AUTH_TOKEN DESCRIPTION [WORKSPACE_TOKEN] [HEADER_NAME] [HEADER_VALUE]
# For workspace operations, pass AUTH_TOKEN for platform identity and WORKSPACE_TOKEN for workspace access.
# For global module operations that need custom headers (e.g., x-org-id), pass header name and value as args 6 and 7.
# The gateway expects:
#   Authorization: Bearer <auth_token>           (platform identity JWT from global-auth-svc)
#   X-Workspace-Authorization: Bearer <ws_token> (workspace access JWT from wspace-auth-svc)
# Custom header mode:
#   - args 6+7: arg 6 is treated as a header name and arg 7 as its value.
#   - args 6+7+8: arg 6 is workspace token and arg 7/8 are custom header name/value.
graphql_request_logged() {
    local url="$1"
    local query="$2"
    local variables="$3"
    # Default variables to empty JSON object if not provided or empty
    if [ -z "$variables" ]; then
        variables='{}'
    fi
    local auth_token="${4:-}"
    local description="${5:-GraphQL Request}"
    local arg6="${6:-}"
    local arg7="${7:-}"
    local arg8="${8:-}"
    
    # Determine if arg6 is a workspace token or a custom header name.
    local workspace_token=""
    local custom_header_name=""
    local custom_header_value=""
    if [ -n "$arg8" ]; then
        workspace_token="$arg6"
        custom_header_name="$arg7"
        custom_header_value="$arg8"
    elif [ -n "$arg7" ]; then
        custom_header_name="$arg6"
        custom_header_value="$arg7"
    else
        workspace_token="$arg6"
    fi

    # Trusted local-development fallback: when a workspace token is unavailable,
    # use x-workspace-id for workspace-layer gateway requests so module E2E tests
    # can still establish workspace context.
    if [ -z "$workspace_token" ] && [ -z "$custom_header_name" ] && [[ "$url" == *"/workspaces/graphql"* ]] && [ -n "${E2E_WORKSPACE_ID:-}" ]; then
        custom_header_name="x-workspace-id"
        custom_header_value="$E2E_WORKSPACE_ID"
    fi

    # Build the request JSON using a temp file to avoid quoting issues
    local temp_file
    temp_file=$(mktemp)

    # Use jq to build proper JSON - redirect stderr to avoid polluting output
    jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}' > "$temp_file" 2>/dev/null

    # Fallback if jq fails
    if [ ! -s "$temp_file" ]; then
        echo "{\"query\":$(echo "$query" | jq -Rs .),\"variables\":$variables}" > "$temp_file"
    fi

    log_output ""
    log_output "${BLUE}>>> $description${NC}"
    log_request "POST $url"

    if [ -n "$auth_token" ]; then
        log_request "Authorization: Bearer ${auth_token:0:20}..."
    fi
    if [ -n "$workspace_token" ]; then
        log_request "X-Workspace-Authorization: Bearer ${workspace_token:0:20}..."
    fi

    local use_direct_service_context=false
    if ([[ "$url" == http://localhost:* ]] && [[ "$url" == */graphql ]] && [[ "$url" != */workspaces/graphql ]] && [[ "$url" != */global/graphql ]]) || [[ "$url" == "http://localhost:4001/workspaces/graphql" ]] || [[ "$url" == "http://localhost:4002/global/graphql" ]]; then
        use_direct_service_context=true
        if [ -n "${E2E_USER_ID:-}" ]; then
            log_request "x-actor-id: ${E2E_USER_ID}"
            log_request "x-actor-type: user"
        fi
        if [ -n "${E2E_WORKSPACE_ID:-}" ]; then
            log_request "x-workspace-id: ${E2E_WORKSPACE_ID}"
        fi
        if [ -n "${E2E_TENANT_ID:-}" ]; then
            log_request "x-tenant-id: ${E2E_TENANT_ID}"
        fi
        if [ -n "${E2E_ORG_ID:-}" ]; then
            log_request "x-organization-id: ${E2E_ORG_ID}"
        fi
        if [ -n "${E2E_INTERNAL_SERVICE_TOKEN:-}" ]; then
            log_request "x-internal-service-token: [set]"
        fi
    fi

    # Log the body (compact JSON if possible)
    local body_for_log
    body_for_log=$(cat "$temp_file")
    local compact_body
    compact_body=$(echo "$body_for_log" | jq -c . 2>/dev/null) || compact_body="$body_for_log"
    log_request "Body: $compact_body"

    # Build curl command args as an array for safe handling
    local -a curl_args=(-s -X POST "$url" -H "Content-Type: application/json")

    if [ -n "$auth_token" ]; then
        curl_args+=(-H "Authorization: Bearer $auth_token")
    fi

    if [ -n "$workspace_token" ]; then
        curl_args+=(-H "X-Workspace-Authorization: Bearer $workspace_token")
    fi

    if [ -n "$custom_header_name" ] && [ -n "$custom_header_value" ]; then
        curl_args+=(-H "${custom_header_name}: ${custom_header_value}")
        log_request "${custom_header_name}: ${custom_header_value}"
    fi

    if [ "$use_direct_service_context" != true ] && [ "${E2E_INJECT_ACTOR_HEADERS:-true}" = "true" ]; then
        if [[ "$url" == *"/workspaces/graphql"* ]] || [[ "$url" == *"/global/graphql"* ]]; then
            if [ -n "${E2E_USER_ID:-}" ]; then
                curl_args+=(-H "x-actor-id: ${E2E_USER_ID}" -H "x-actor-type: user")
                log_request "x-actor-id: ${E2E_USER_ID}"
                log_request "x-actor-type: user"
            fi
            if [ -n "${E2E_ORG_ID:-}" ]; then
                curl_args+=(-H "x-org-id: ${E2E_ORG_ID}")
                log_request "x-org-id: ${E2E_ORG_ID}"
            fi
        fi
    fi

    if [ "$use_direct_service_context" = true ]; then
        if [ -n "${E2E_USER_ID:-}" ]; then
            curl_args+=(-H "x-actor-id: ${E2E_USER_ID}" -H "x-actor-type: user")
        fi
        if [ -n "${E2E_WORKSPACE_ID:-}" ]; then
            curl_args+=(-H "x-workspace-id: ${E2E_WORKSPACE_ID}")
        fi
        if [ -n "${E2E_TENANT_ID:-}" ]; then
            curl_args+=(-H "x-tenant-id: ${E2E_TENANT_ID}")
        fi
        if [ -n "${E2E_ORG_ID:-}" ]; then
            curl_args+=(-H "x-organization-id: ${E2E_ORG_ID}")
        fi
        if [ -n "${E2E_INTERNAL_SERVICE_TOKEN:-}" ]; then
            curl_args+=(-H "x-internal-service-token: ${E2E_INTERNAL_SERVICE_TOKEN}")
        fi
    fi

    curl_args+=(-d @"$temp_file")

    local response
    response=$(curl "${curl_args[@]}")

    # Clean up temp file
    rm -f "$temp_file"

    log_output ""
    log_response "$(echo "$response" | jq -c . 2>/dev/null || echo "$response")"
    log_output ""

    echo "$response"
}

# Expand tilde in paths (~ -> $HOME)
# Usage: expanded_path=$(expand_tilde "~/some/path")
expand_tilde() {
    local path="$1"
    # Replace leading ~ with $HOME
    if [[ "$path" == "~"* ]]; then
        echo "${HOME}${path:1}"
    else
        echo "$path"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if required commands exist
check_dependencies() {
    local deps=("$@")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        return 1
    fi

    return 0
}

# Run command with error handling
run_command() {
    local cmd="$*"
    log_info "Running: $cmd"

    if ! eval "$cmd"; then
        log_error "Command failed: $cmd"
        return 1
    fi

    return 0
}

# Check if directory exists and is accessible
check_directory() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        log_error "Directory not found: $dir"
        return 1
    fi

    if [ ! -r "$dir" ]; then
        log_error "Directory not readable: $dir"
        return 1
    fi

    return 0
}

# Get all workspace modules
get_workspace_modules() {
    find "$PRODUCTS_ROOT/wspace" -mindepth 1 -maxdepth 1 -type d ! -name ".*" | sort
}

# Get all global modules
get_global_modules() {
    find "$PRODUCTS_ROOT/global" -mindepth 1 -maxdepth 1 -type d ! -name ".*" ! -name ".ops" ! -name ".vscode" | sort
}

# Get all gateways
get_gateways() {
    if [ -d "$PRODUCTS_ROOT/gateways" ]; then
        find "$PRODUCTS_ROOT/gateways" -mindepth 1 -maxdepth 1 -type d ! -name ".*" | sort
    fi
}

# Get all microfrontends
get_microfrontends() {
    if [ -d "$PRODUCTS_ROOT/microfe" ]; then
        find "$PRODUCTS_ROOT/microfe" -mindepth 1 -maxdepth 1 -type d -name "microfe-*" | sort
    fi
}

# =============================================================================
# Service Status Check Functions (Idempotent Operations)
# =============================================================================

# Check if a Docker container is running by name
# Usage: is_container_running "container-name"
is_container_running() {
    local container_name="$1"
    docker ps --filter "name=^${container_name}$" --filter "status=running" --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"
}

# Check if a Docker container exists (running or stopped)
# Usage: container_exists "container-name"
container_exists() {
    local container_name="$1"
    docker ps -a --filter "name=^${container_name}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"
}

# Check if a service is healthy via HTTP health endpoint
# Usage: is_service_healthy "http://localhost:4000/health" [timeout_seconds]
is_service_healthy() {
    local url="$1"
    local timeout="${2:-5}"
    curl -sf --max-time "$timeout" "$url" > /dev/null 2>&1
}

# Check if a service running inside a Docker container is healthy
# Usage: is_service_container_healthy "container-name" "http://localhost:4000/health"
is_service_container_healthy() {
    local container="$1"
    local url="$2"
    if ! is_container_running "$container"; then
        return 1
    fi
    if docker exec "$container" wget -qO- "$url" > /dev/null 2>&1; then
        return 0
    fi
    if docker exec "$container" curl -sf "$url" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Check if a screen session exists
# Usage: is_screen_session_running "session-name"
is_screen_session_running() {
    local session_name="$1"
    screen -ls 2>/dev/null | grep -q "\.${session_name}[[:space:]]"
}

# Check if a tmux session exists
# Usage: is_tmux_session_running "session-name"
is_tmux_session_running() {
    local session_name="$1"
    tmux has-session -t "$session_name" 2>/dev/null
}

# Check if a port is listening
# Usage: is_port_listening 4000
is_port_listening() {
    local port="$1"
    if command_exists lsof; then
        lsof -i :"$port" -sTCP:LISTEN > /dev/null 2>&1
    elif command_exists ss; then
        ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"
    elif command_exists netstat; then
        netstat -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]"
    else
        # Fallback: try to connect
        (echo > /dev/tcp/localhost/"$port") 2>/dev/null
    fi
}

# Check PostgreSQL readiness via docker exec
# Usage: is_postgres_ready "container-name" "username" "database"
is_postgres_ready() {
    local container="$1"
    local user="${2:-postgres}"
    local db="${3:-postgres}"
    docker exec "$container" pg_isready -U "$user" -d "$db" > /dev/null 2>&1
}

# Start docker compose only if not already running
# Usage: start_compose_if_needed "/path/to/dir" "container-name-to-check" ["compose-name"] ["profile"]
start_compose_if_needed() {
    local compose_dir
    compose_dir="$(expand_tilde "$1")"
    local check_container="$2"
    local compose_name="${3:-$(basename "$compose_dir")}"
    local compose_profile="${4:-}"

    if is_container_running "$check_container"; then
        log_info "SKIP: $compose_name already running ($check_container)"
        return 0
    fi

    log_info "Starting: $compose_name..."
    local compose_args=()
    if [ -n "$compose_profile" ]; then
        compose_args+=(--profile "$compose_profile")
    fi
    if cd "$compose_dir" && docker compose "${compose_args[@]}" up -d; then
        log_success "Started: $compose_name"
        return 0
    else
        log_error "Failed to start: $compose_name"
        return 1
    fi
}

# Start screen session only if not already running and service not healthy
# Usage: start_screen_if_needed "session-name" "/path/to/dir" "health-url" "startup-command"
start_screen_if_needed() {
    local session_name="$1"
    local work_dir
    work_dir="$(expand_tilde "$2")"
    local health_url="$3"
    local startup_cmd="${4:-bun run dev}"

    # Check if service is already healthy
    if is_service_healthy "$health_url" 2; then
        log_info "SKIP: $session_name already healthy at $health_url"
        return 0
    fi

    # Check if screen session exists
    if is_screen_session_running "$session_name"; then
        log_warning "Session $session_name exists but service unhealthy - checking..."
        # Give it a moment and recheck
        sleep 2
        if is_service_healthy "$health_url" 3; then
            log_info "SKIP: $session_name now healthy"
            return 0
        fi
        log_warning "Killing unhealthy session: $session_name"
        screen -S "$session_name" -X quit 2>/dev/null || true
        sleep 1
    fi

    log_info "Starting: $session_name..."
    cd "$work_dir" && screen -dmS "$session_name" bash -c "$startup_cmd"
    log_success "Started screen session: $session_name"
    return 0
}

# Wait for service to become healthy with timeout
# Usage: wait_for_health "http://localhost:4000/health" 30 "service-name"
wait_for_health() {
    local url="$1"
    local timeout="${2:-30}"
    local name="${3:-service}"
    local elapsed=0
    local interval=2

    log_info "Waiting for $name to become healthy..."
    while [ $elapsed -lt $timeout ]; do
        if is_service_healthy "$url" 2; then
            log_success "$name is healthy"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "$name not healthy after ${timeout}s (may still be starting)"
    return 1
}

# =============================================================================
# JWT Token Management
# =============================================================================

# Check if JWT token is expired or about to expire (within buffer seconds)
# Usage: is_token_expired "$TOKEN" [buffer_seconds]
# Returns: 0 if expired/invalid, 1 if still valid
is_token_expired() {
    local token="$1"
    local buffer="${2:-60}"  # Default 60 second buffer before expiry

    if [ -z "$token" ]; then
        return 0  # No token = expired
    fi

    # Extract payload (second part of JWT)
    local payload
    payload=$(echo "$token" | cut -d'.' -f2 | tr '_-' '/+')

    # Pad base64 if needed
    local mod=$((${#payload} % 4))
    if [ $mod -eq 2 ]; then
        payload="${payload}=="
    elif [ $mod -eq 3 ]; then
        payload="${payload}="
    fi

    # Decode and extract expiration
    local exp
    exp=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.exp // 0' 2>/dev/null)

    if [ -z "$exp" ] || [ "$exp" = "0" ] || [ "$exp" = "null" ]; then
        return 0  # Can't parse = treat as expired
    fi

    # Get current time and compare
    local now
    now=$(date +%s)
    local expires_at=$((exp - buffer))

    if [ "$now" -ge "$expires_at" ]; then
        return 0  # Expired or about to expire
    fi

    return 1  # Still valid
}

# Get token expiration info for display
# Usage: get_token_expiry_info "$TOKEN"
get_token_expiry_info() {
    local token="$1"

    if [ -z "$token" ]; then
        echo "No token"
        return
    fi

    local payload
    payload=$(echo "$token" | cut -d'.' -f2 | tr '_-' '/+')

    local mod=$((${#payload} % 4))
    if [ $mod -eq 2 ]; then
        payload="${payload}=="
    elif [ $mod -eq 3 ]; then
        payload="${payload}="
    fi

    local exp iat
    exp=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.exp // 0' 2>/dev/null)
    iat=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.iat // 0' 2>/dev/null)

    if [ -z "$exp" ] || [ "$exp" = "0" ]; then
        echo "Invalid token"
        return
    fi

    local now
    now=$(date +%s)
    local remaining=$((exp - now))

    if [ "$remaining" -lt 0 ]; then
        echo "Expired $((-remaining)) seconds ago"
    else
        echo "Valid for $remaining seconds ($(date -d @$exp '+%H:%M:%S'))"
    fi
}

# Execute a curl GraphQL request with transient-error retry.
# Retries on empty responses, HTTP 503, or curl failures up to max_attempts
# with exponential backoff. Returns the response body on stdout.
# Usage: graphql_request_with_retry <url> <payload> <max_attempts> <description>
graphql_request_with_retry() {
    local url="$1"
    local payload="$2"
    local max_attempts="${3:-5}"
    local description="${4:-request}"
    local attempt=1
    local delay=1
    local response
    local http_code

    while [ "$attempt" -le "$max_attempts" ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "${payload}" 2>/dev/null)
        http_code=$(echo "$response" | tail -n 1)
        response=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ] && [ -n "$response" ]; then
            echo "$response"
            return 0
        fi

        if [ "$http_code" = "503" ] || [ -z "$response" ] || [ "$http_code" = "000" ]; then
            log_warning "[$description] transient error (http=$http_code), attempt $attempt/$max_attempts, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            attempt=$((attempt + 1))
            continue
        fi

        # Non-retryable response; return it anyway so callers can inspect errors
        echo "$response"
        return 0
    done

    log_error "[$description] failed after $max_attempts attempts"
    echo "$response"
    return 1
}

# Refresh E2E environment by re-bootstrapping
# Usage: refresh_e2e_env
refresh_e2e_env() {
    local bootstrap_script="$WORKSPACES_DOCTOR_ROOT/core/scripts/bootstrap-env.sh"
    local env_file="$WORKSPACES_DOCTOR_ROOT/core/env/e2e-env.sh"

    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        source "$env_file"

        if declare -F e2e_refresh_token > /dev/null 2>&1; then
            log_info "Attempting token refresh using stored refresh token..."
            if e2e_refresh_token > /tmp/e2e-refresh.log 2>&1; then
                sed -i "s|^export E2E_AUTH_TOKEN=.*|export E2E_AUTH_TOKEN=\"${E2E_AUTH_TOKEN}\"|" "$env_file"
                sed -i "s|^export E2E_REFRESH_TOKEN=.*|export E2E_REFRESH_TOKEN=\"${E2E_REFRESH_TOKEN}\"|" "$env_file"
                log_success "E2E auth token refreshed successfully"
                return 0
            fi

            log_warning "Stored refresh token flow failed, falling back to full bootstrap"
        fi

        if [ -n "${E2E_USER_EMAIL:-}" ] && [ -n "${E2E_USER_PASSWORD:-}" ]; then
            log_info "Attempting sign-in with stored E2E user credentials..."
            local signin_response
            local signin_payload
            signin_payload=$(jq -n \
                --arg email "${E2E_USER_EMAIL}" \
                --arg password "${E2E_USER_PASSWORD}" \
                '{query: "mutation SignIn($input: SignInInput!) { signIn(input: $input) { accessToken refreshToken } }", variables: {input: {email: $email, password: $password}}}')
            signin_response=$(graphql_request_with_retry "${E2E_GLOBAL_GATEWAY:-http://localhost:4000/global/graphql}" "${signin_payload}" 5 "E2E sign-in")

            local refreshed_access_token refreshed_refresh_token
            refreshed_access_token=$(echo "$signin_response" | jq -r '.data.signIn.accessToken // empty')
            refreshed_refresh_token=$(echo "$signin_response" | jq -r '.data.signIn.refreshToken // empty')

            if [ -n "$refreshed_access_token" ] && [ "$refreshed_access_token" != "null" ]; then
                E2E_AUTH_TOKEN="$refreshed_access_token"
                if [ -n "$refreshed_refresh_token" ] && [ "$refreshed_refresh_token" != "null" ]; then
                    E2E_REFRESH_TOKEN="$refreshed_refresh_token"
                    sed -i "s|^export E2E_REFRESH_TOKEN=.*|export E2E_REFRESH_TOKEN=\"${E2E_REFRESH_TOKEN}\"|" "$env_file"
                fi
                sed -i "s|^export E2E_AUTH_TOKEN=.*|export E2E_AUTH_TOKEN=\"${E2E_AUTH_TOKEN}\"|" "$env_file"
                log_success "E2E auth token refreshed via sign-in"
                return 0
            fi
        fi
    fi

    if [ ! -f "$bootstrap_script" ]; then
        log_error "Bootstrap script not found: $bootstrap_script"
        return 1
    fi

    log_info "Token expired or missing. Re-bootstrapping environment..."

    # Run bootstrap script and capture output
    if ! "$bootstrap_script" --force > /tmp/e2e-bootstrap.log 2>&1; then
        log_error "Failed to bootstrap environment. Check /tmp/e2e-bootstrap.log"
        return 1
    fi

    # Source the new environment
    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        source "$env_file"
        log_success "Environment refreshed successfully"
        return 0
    else
        log_error "Environment file not created by bootstrap"
        return 1
    fi
}

# Ensure a valid workspace token exists for the current E2E workspace context.
# Usage: ensure_workspace_token
ensure_workspace_token() {
    local env_file="$WORKSPACES_DOCTOR_ROOT/core/env/e2e-env.sh"

    if [ -z "${E2E_AUTH_TOKEN:-}" ] || [ -z "${E2E_WORKSPACE_ID:-}" ] || [ -z "${E2E_ORG_ID:-}" ]; then
        log_warning "Workspace token refresh skipped: missing auth/workspace/org context"
        return 1
    fi

    local gateway_url="${WSPACE_GATEWAY_URL:-${E2E_WORKSPACE_GATEWAY:-http://localhost:4003/workspaces/graphql}}"
    local token_payload
    token_payload=$(jq -n \
        --arg workspaceId "$E2E_WORKSPACE_ID" \
        --arg organizationId "$E2E_ORG_ID" \
        '{query: "mutation IssueWorkspaceToken($input: IssueWorkspaceTokenInput!) { issueWorkspaceToken(input: $input) { success token error { message } } }", variables: {input: {workspaceId: $workspaceId, organizationId: $organizationId}}}')

    local response
    local attempt=1
    local delay=1
    local max_attempts=5
    while [ "$attempt" -le "$max_attempts" ]; do
        response=$(curl -s -w "\n%{http_code}" -X POST "$gateway_url" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${E2E_AUTH_TOKEN}" \
            -H "x-actor-id: ${E2E_USER_ID}" \
            -H "x-actor-type: super_admin" \
            -H "x-workspace-id: ${E2E_WORKSPACE_ID}" \
            -d "$token_payload" 2>/dev/null)
        local http_code
        http_code=$(echo "$response" | tail -n 1)
        response=$(echo "$response" | sed '$d')

        if [ "$http_code" = "200" ] && [ -n "$response" ]; then
            break
        fi

        if [ "$http_code" = "503" ] || [ -z "$response" ] || [ "$http_code" = "000" ]; then
            log_warning "[workspace token] transient error (http=$http_code), attempt $attempt/$max_attempts, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
            attempt=$((attempt + 1))
            continue
        fi

        # Non-retryable response; stop retrying
        break
    done

    local new_workspace_token
    new_workspace_token=$(echo "$response" | jq -r '.data.issueWorkspaceToken.token // empty')

    if [ -z "$new_workspace_token" ] || [ "$new_workspace_token" = "null" ]; then
        local error_message
        error_message=$(echo "$response" | jq -r '.data.issueWorkspaceToken.error.message // .errors[0].message // "Unknown workspace token error"')
        local reset_at
        reset_at=$(echo "$response" | jq -r '.errors[0].extensions.resetAt // empty')

        if [ -n "$reset_at" ] && echo "$error_message" | grep -qi 'rate limit'; then
            local sleep_seconds
            sleep_seconds=$(python3 - <<'PY' "$reset_at"
from datetime import datetime, timezone
import sys

reset_at = sys.argv[1]
reset_at = reset_at.replace('Z', '+00:00')
target = datetime.fromisoformat(reset_at)
now = datetime.now(timezone.utc)
seconds = int((target - now).total_seconds()) + 1
print(max(seconds, 1))
PY
)
            log_warning "Workspace token issuance rate-limited. Waiting ${sleep_seconds}s before retrying..."
            sleep "$sleep_seconds"

            response=$(curl -s -X POST "$gateway_url" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${E2E_AUTH_TOKEN}" \
                -H "x-actor-id: ${E2E_USER_ID}" \
                -H "x-actor-type: super_admin" \
                -H "x-workspace-id: ${E2E_WORKSPACE_ID}" \
                -d "$token_payload")
            new_workspace_token=$(echo "$response" | jq -r '.data.issueWorkspaceToken.token // empty')
        fi
    fi

    if [ -z "$new_workspace_token" ] || [ "$new_workspace_token" = "null" ]; then
        local error_message
        error_message=$(echo "$response" | jq -r '.data.issueWorkspaceToken.error.message // .errors[0].message // "Unknown workspace token error"')
        log_warning "Failed to issue workspace token: $error_message"
        return 1
    fi

    E2E_WORKSPACE_TOKEN="$new_workspace_token"
    export E2E_WORKSPACE_TOKEN

    if [ -f "$env_file" ]; then
        sed -i "s|^export E2E_WORKSPACE_TOKEN=.*|export E2E_WORKSPACE_TOKEN=\"${E2E_WORKSPACE_TOKEN}\"|" "$env_file"
    fi

    log_success "Workspace token refreshed successfully"
    return 0
}

# Load E2E environment file with automatic token refresh
# Usage: load_e2e_env [--no-refresh]
load_e2e_env() {
    local no_refresh=false
    if [ "${1:-}" = "--no-refresh" ]; then
        no_refresh=true
    fi

    local env_file="$WORKSPACES_DOCTOR_ROOT/core/env/e2e-env.sh"

    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        source "$env_file"

        # Check if token is expired (with 60 second buffer)
        if [ "$no_refresh" = false ] && is_token_expired "${E2E_AUTH_TOKEN:-}" 60; then
            log_warning "JWT token expired or about to expire"
            if refresh_e2e_env; then
                # Re-source the updated file
                source "$env_file"
            else
                log_error "Failed to refresh token. Tests may fail with 'Not authenticated'"
            fi
        fi

        # Set common gateway URLs if not already set
        GLOBAL_GATEWAY_URL="${GLOBAL_GATEWAY_URL:-${E2E_GLOBAL_GATEWAY:-http://localhost:4000/global/graphql}}"
        WSPACE_GATEWAY_URL="${WSPACE_GATEWAY_URL:-http://localhost:4003/workspaces/graphql}"

        if [ "$no_refresh" = false ] && is_token_expired "${E2E_WORKSPACE_TOKEN:-}" 60; then
            log_warning "Workspace token expired or missing"
            if ! ensure_workspace_token; then
                log_warning "Workspace token refresh failed, re-bootstrapping environment..."
                if "$WORKSPACES_DOCTOR_ROOT/core/scripts/bootstrap-env.sh" --force > /tmp/e2e-bootstrap.log 2>&1; then
                    source "$env_file"
                else
                    log_error "Failed to refresh workspace token. Workspace tests may fail."
                fi
            fi
        fi

        export GLOBAL_GATEWAY_URL WSPACE_GATEWAY_URL
    else
        log_warning "E2E environment file not found. Running bootstrap..."
        if refresh_e2e_env; then
            # Source the newly created file
            source "$WORKSPACES_DOCTOR_ROOT/core/env/e2e-env.sh"

            GLOBAL_GATEWAY_URL="${GLOBAL_GATEWAY_URL:-${E2E_GLOBAL_GATEWAY:-http://localhost:4000/global/graphql}}"
            WSPACE_GATEWAY_URL="${WSPACE_GATEWAY_URL:-http://localhost:4003/workspaces/graphql}"

            export GLOBAL_GATEWAY_URL WSPACE_GATEWAY_URL
        else
            return 1
        fi
    fi
}

# Export functions
export -f log_info log_success log_warning log_error log_output log_header log_section log_test
export -f log_request log_response init_log_file log4net_timestamp log4net_write
export -f curl_logged graphql_request_logged
export -f command_exists check_dependencies run_command check_directory
export -f expand_tilde load_e2e_env
export -f get_workspace_modules get_global_modules get_gateways get_microfrontends
export -f is_container_running container_exists is_service_healthy
export -f is_service_container_healthy
export -f is_screen_session_running is_tmux_session_running is_port_listening
export -f is_postgres_ready start_compose_if_needed
export -f start_screen_if_needed wait_for_health
export -f is_token_expired get_token_expiry_info refresh_e2e_env ensure_workspace_token

# Export path variables
export DOCTOR_ROOT CORE_DIR MODULES_DIR ENV_DIR LOGS_DIR PRODUCTS_ROOT
