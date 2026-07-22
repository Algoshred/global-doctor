#!/usr/bin/env bash
#
# Scale audit: tenant-svc services are module-scope singletons
# (not allocated per-request).
#
# Asserts via a debug GraphQL endpoint `_debug { serviceInstanceIds }`
# that the set of instance IDs is stable across N=10 sequential requests.
# If services were per-request, the set would grow by 1 each call.
#
# Alternative path (if debug endpoint is disabled in prod-like builds):
# inspect process RSS growth across 1000 noop queries — growth must be
# bounded (< 5MB) since no per-request allocation occurs.
#
# requires: live global-tenant-svc with DEBUG_INSPECT_DI=true (or RSS
#           sampling via /proc/<pid>/status); gateway routable.
# env: GATEWAY_URL (default http://localhost:4002/global/graphql),
#      E2E_ADMIN_TOKEN, E2E_ADMIN_ID, TENANT_CONTAINER (default
#      global-tenant-svc), N_REQUESTS (default 10), RSS_GROWTH_KB
#      (default 5120)
#
# Usage:
#   ./scripts/test-scale-module-singletons.sh
#   make test-scale-module-singletons

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_FILE="$DOCTOR_ROOT/core/env/e2e-env.sh"
LOG_FILE="${E2E_LOG_FILE:-$DOCTOR_ROOT/logs/e2e-tenant-scale-singletons.log}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:4002/global/graphql}"
CONTAINER="${TENANT_CONTAINER:-global-tenant-svc}"
N="${N_REQUESTS:-10}"
RSS_MAX_KB="${RSS_GROWTH_KB:-5120}"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

: "${E2E_ADMIN_TOKEN:?missing E2E_ADMIN_TOKEN}"
: "${E2E_ADMIN_ID:?missing E2E_ADMIN_ID}"

log() { printf '%s %s\n' "[scale-singletons]" "$*" | tee -a "$LOG_FILE"; }

graphql() {
  curl -sS -X POST "$GATEWAY_URL" \
    -H "Authorization: Bearer $E2E_ADMIN_TOKEN" \
    -H "x-actor-id: $E2E_ADMIN_ID" \
    -H "x-actor-type: super_admin" \
    -H "x-internal-service-token: ${INTERNAL_SERVICE_TOKEN:-gw-trust-121b8faa2b538d4c1ec9435d3c08bc69}" \
    -H "Content-Type: application/json" \
    -d "$1"
}

# Path A — debug DI inspect endpoint
DEBUG_RESP=$(graphql '{"query":"{ _debug { serviceInstanceIds } }"}')
if echo "$DEBUG_RESP" | jq -e '.data._debug.serviceInstanceIds' >/dev/null 2>&1; then
  log "Using DI introspection path"
  FIRST=$(echo "$DEBUG_RESP" | jq -c '.data._debug.serviceInstanceIds | sort')
  log "Initial instance IDs: $FIRST"
  for i in $(seq 1 "$N"); do
    NEXT=$(graphql '{"query":"{ _debug { serviceInstanceIds } }"}' | jq -c '.data._debug.serviceInstanceIds | sort')
    if [ "$NEXT" != "$FIRST" ]; then
      log "FAIL — instance IDs drifted on request #$i. Services are NOT module-scope singletons."
      log "  before: $FIRST"
      log "  after:  $NEXT"
      exit 1
    fi
  done
  log "PASS — instance IDs stable across $N requests"
  exit 0
fi

# Path B — RSS growth fallback
log "Debug endpoint unavailable; falling back to RSS sampling on $CONTAINER"
PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")
[ -n "$PID" ] || { log "FAIL — could not read PID of $CONTAINER"; exit 1; }
read_rss() { awk '/VmRSS/ {print $2}' "/proc/$PID/status"; }

BEFORE=$(read_rss)
log "Initial RSS=${BEFORE}KB; firing 1000 noop queries"
for i in $(seq 1 1000); do
  graphql '{"query":"{ __typename }"}' >/dev/null
done
sleep 2
AFTER=$(read_rss)
DELTA=$((AFTER - BEFORE))
log "Final RSS=${AFTER}KB delta=${DELTA}KB (cap=${RSS_MAX_KB}KB)"

if [ "$DELTA" -gt "$RSS_MAX_KB" ]; then
  log "FAIL — RSS grew by ${DELTA}KB > ${RSS_MAX_KB}KB across 1000 requests → per-request allocation suspected"
  exit 1
fi

log "PASS — RSS stable; services behave as module-scope singletons"
