#!/usr/bin/env bash
#
# Product Management E2E Tests
# ============================
#
# Smoke + read-side tests for the products-module surface owned by
# global-tenant-svc (Product, KeyboardShortcut, ProductContentPage,
# FeatureFlag) — including the new pagination args and the removal of the
# deprecated `seedVibeControlsFeatureFlags` mutation.
#
# Mutations on global definitions are super-admin only; with a MEMBER token
# we assert the RBAC denial path returns FORBIDDEN.
#
# Usage:
#   ./test-product-mgmt.sh                     # run all
#   ./test-product-mgmt.sh products            # product reads only
#   ./test-product-mgmt.sh shortcuts           # shortcut reads only
#   ./test-product-mgmt.sh content-pages
#   ./test-product-mgmt.sh feature-flags
#   ./test-product-mgmt.sh deprecation         # confirm removed mutation rejected
#   ./test-product-mgmt.sh pagination          # confirm bounded-args accepted

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
DOCTOR_ROOT="$(cd "$MODULE_DIR/../.." && pwd)"
CORE_DIR="$DOCTOR_ROOT/core"
ENV_FILE="$CORE_DIR/env/e2e-env.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    log_error "Environment file not found: $ENV_FILE"
    log_error "Run: make -C $CORE_DIR bootstrap-env"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  E2E_GLOBAL_GATEWAY_URL="${E2E_GLOBAL_GATEWAY_URL:-${E2E_GLOBAL_GATEWAY:-http://localhost:4000/global/graphql}}"
  if [[ -z "${E2E_AUTH_TOKEN:-}" ]]; then
    log_error "E2E_AUTH_TOKEN not set"
    exit 1
  fi
  if [[ -z "${E2E_WORKSPACE_ID:-}" ]]; then
    log_warning "E2E_WORKSPACE_ID not set — workspace-scoped tests will be skipped"
  fi
}

gql() {
  local query="$1"
  local variables="${2:-}"
  if [[ -z "$variables" ]]; then
    variables='{}'
  fi
  local payload
  payload=$(jq -nc --arg q "$query" --arg v "$variables" '{query:$q, variables: ($v | fromjson)}')
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $E2E_AUTH_TOKEN" \
    -d "$payload" \
    "$E2E_GLOBAL_GATEWAY_URL"
}

has_errors() {
  echo "$1" | jq -e '.errors' >/dev/null 2>&1
}

extract() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null || true
}

run_test() {
  local name="$1" fn="$2"
  TESTS_RUN=$((TESTS_RUN+1))
  log_info "Running: $name"
  if $fn; then
    TESTS_PASSED=$((TESTS_PASSED+1))
    log_success "✓ $name"
  else
    TESTS_FAILED=$((TESTS_FAILED+1))
    log_error "✗ $name"
  fi
}

# --- Tests -----------------------------------------------------------------

test_list_platform_products_paginated() {
  local q='query($l:Int,$o:Int){ platformProducts(limit:$l,offset:$o){ items{id slug status} total hasMore } }'
  local v='{"l":5,"o":0}'
  local r; r=$(gql "$q" "$v")
  if has_errors "$r"; then
    log_error "platformProducts errored: $(extract "$r" '.errors[0].message')"
    return 1
  fi
  local total; total=$(extract "$r" '.data.platformProducts.total')
  [[ "$total" =~ ^[0-9]+$ ]] && return 0 || return 1
}

test_keyboard_shortcuts_paginated() {
  local q='query($l:Int,$o:Int){ keyboardShortcuts(limit:$l,offset:$o){ items{id shortcutKey} total hasMore } }'
  local v='{"l":10,"o":0}'
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_product_shortcuts_bounded_args() {
  # New pagination args; uses any valid product id if available, else passes a synthetic id (read-only — server returns []).
  local prod_q='query{ platformProducts(limit:1){ items{id} } }'
  local pr; pr=$(gql "$prod_q")
  local pid; pid=$(extract "$pr" '.data.platformProducts.items[0].id')
  [[ -z "$pid" || "$pid" == "null" ]] && pid="00000000-0000-0000-0000-000000000000"
  local q='query($p:ID!,$l:Int,$o:Int){ productShortcuts(productId:$p, limit:$l, offset:$o){ id shortcutKey } }'
  local v; v=$(jq -nc --arg p "$pid" '{p:$p, l:50, o:0}')
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_content_pages_paginated() {
  local q='query($l:Int,$o:Int){ contentPages(limit:$l,offset:$o){ items{id slug title} total hasMore } }'
  local v='{"l":10,"o":0}'
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_public_products() {
  # Public read path — no auth required, but reusing token is fine.
  local q='query{ publicProducts(limit:5){ items{slug name status} total } }'
  local r; r=$(gql "$q")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_workspace_overrides_paginated() {
  [[ -z "${E2E_WORKSPACE_ID:-}" ]] && { log_warning "no workspaceId; skipping"; return 0; }
  local q='query($w:String!,$l:Int,$o:Int){ workspaceFeatureFlagOverrides(workspaceId:$w, limit:$l, offset:$o){ id featureFlagId enabled } }'
  local v; v=$(jq -nc --arg w "$E2E_WORKSPACE_ID" '{w:$w, l:25, o:0}')
  local r; r=$(gql "$q" "$v")
  # MEMBER may be denied; treat denial as expected (RBAC enforced) but argument validation must succeed.
  if has_errors "$r"; then
    local code; code=$(extract "$r" '.errors[0].extensions.code')
    if [[ "$code" == "FORBIDDEN" || "$code" == "UNAUTHENTICATED" ]]; then
      log_info "workspaceFeatureFlagOverrides denied as expected ($code) — RBAC enforced"
      return 0
    fi
    log_error "$(extract "$r" '.errors[0].message')"
    return 1
  fi
  return 0
}

test_user_preferences_paginated() {
  [[ -z "${E2E_WORKSPACE_ID:-}" ]] && { log_warning "no workspaceId; skipping"; return 0; }
  local q='query($w:String!,$l:Int,$o:Int){ userFeatureFlagPreferences(workspaceId:$w, limit:$l, offset:$o){ id featureFlagId enabled } }'
  local v; v=$(jq -nc --arg w "$E2E_WORKSPACE_ID" '{w:$w, l:25, o:0}')
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_available_feature_previews_paginated() {
  [[ -z "${E2E_WORKSPACE_ID:-}" ]] && { log_warning "no workspaceId; skipping"; return 0; }
  local q='query($w:String!,$l:Int,$o:Int){ availableFeaturePreviews(workspaceId:$w, limit:$l, offset:$o){ id key name previewable } }'
  local v; v=$(jq -nc --arg w "$E2E_WORKSPACE_ID" '{w:$w, l:50, o:0}')
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  return 0
}

test_evaluate_feature_flags_workspace_scoped() {
  [[ -z "${E2E_WORKSPACE_ID:-}" ]] && { log_warning "no workspaceId; skipping"; return 0; }
  local q='query($i:EvaluateFeatureFlagsInput!){ evaluateFeatureFlags(input:$i){ evaluations{ key value reason } } }'
  local v; v=$(jq -nc --arg w "$E2E_WORKSPACE_ID" '{i:{workspaceId:$w, keys:["vibecontrols.overview"]}}')
  local r; r=$(gql "$q" "$v")
  has_errors "$r" && { log_error "$(extract "$r" '.errors[0].message')"; return 1; }
  local val; val=$(extract "$r" '.data.evaluateFeatureFlags.evaluations[0].key')
  [[ "$val" == "vibecontrols.overview" ]] || return 1
}

test_feature_flag_create_denied_for_member() {
  # MEMBER must be denied. Verifies actorTypes:["super_admin"] enforcement.
  local q='mutation($i:CreateFeatureFlagInput!){ createFeatureFlag(input:$i){ id key } }'
  local v='{"i":{"key":"e2e.doctor.denied.'$RANDOM'","name":"e2e doctor denied"}}'
  local r; r=$(gql "$q" "$v")
  if has_errors "$r"; then
    local code; code=$(extract "$r" '.errors[0].extensions.code')
    if [[ "$code" == "FORBIDDEN" || "$code" == "UNAUTHENTICATED" ]]; then
      return 0
    fi
    log_error "Unexpected error code: $code"
    return 1
  fi
  log_error "createFeatureFlag should have been denied for MEMBER actor"
  return 1
}

test_seed_vibecontrols_feature_flags_removed() {
  # The deprecated mutation must no longer be in the schema. Expect a parsing error.
  local q='mutation{ seedVibeControlsFeatureFlags }'
  local r; r=$(gql "$q")
  if has_errors "$r"; then
    local msg; msg=$(extract "$r" '.errors[0].message')
    if echo "$msg" | grep -qi "Cannot query field \"seedVibeControlsFeatureFlags\"\\|undefined field"; then
      return 0
    fi
    log_error "Got error but not the expected schema rejection: $msg"
    return 1
  fi
  log_error "seedVibeControlsFeatureFlags is still resolvable — deprecation removal failed"
  return 1
}

# --- Suites ----------------------------------------------------------------

run_products()      { run_test "platformProducts paginated" test_list_platform_products_paginated;
                      run_test "publicProducts read"        test_public_products; }
run_shortcuts()     { run_test "keyboardShortcuts paginated" test_keyboard_shortcuts_paginated;
                      run_test "productShortcuts bounded args" test_product_shortcuts_bounded_args; }
run_content_pages() { run_test "contentPages paginated" test_content_pages_paginated; }
run_feature_flags() { run_test "workspaceFeatureFlagOverrides paginated" test_workspace_overrides_paginated;
                      run_test "userFeatureFlagPreferences paginated"   test_user_preferences_paginated;
                      run_test "availableFeaturePreviews paginated"     test_available_feature_previews_paginated;
                      run_test "evaluateFeatureFlags workspace-scoped"  test_evaluate_feature_flags_workspace_scoped;
                      run_test "createFeatureFlag denied for MEMBER"    test_feature_flag_create_denied_for_member; }
run_deprecation()   { run_test "seedVibeControlsFeatureFlags removed"   test_seed_vibecontrols_feature_flags_removed; }
run_pagination()    { run_test "platformProducts paginated" test_list_platform_products_paginated;
                      run_test "keyboardShortcuts paginated" test_keyboard_shortcuts_paginated;
                      run_test "contentPages paginated" test_content_pages_paginated; }

run_all() {
  run_products
  run_shortcuts
  run_content_pages
  run_feature_flags
  run_deprecation
}

main() {
  log_info "Product-Management E2E Tests"
  log_info "============================"
  load_env
  local suite="${1:-all}"
  case "$suite" in
    products)       run_products ;;
    shortcuts)      run_shortcuts ;;
    content-pages)  run_content_pages ;;
    feature-flags)  run_feature_flags ;;
    deprecation)    run_deprecation ;;
    pagination)     run_pagination ;;
    all)            run_all ;;
    *) log_error "Unknown suite: $suite"; exit 1 ;;
  esac

  echo ""
  log_info "Summary"
  log_info "Total:  $TESTS_RUN"
  log_success "Passed: $TESTS_PASSED"
  if (( TESTS_FAILED > 0 )); then
    log_error "Failed: $TESTS_FAILED"
    exit 1
  fi
}

main "$@"
