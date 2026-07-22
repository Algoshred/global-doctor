#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$DOCTOR_ROOT/core/scripts/common.sh"

ENV_FILE="$DOCTOR_ROOT/core/env/e2e-env.sh"
if [ ! -f "$ENV_FILE" ]; then
  log_error "Environment file not found: $ENV_FILE"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

AUTH_URL="${E2E_AUTH_URL:-http://localhost:4000/global/graphql}"
CHANNEL_URL="${E2E_CHANNEL_URL:-http://localhost:4021/graphql}"
ROUTING_ORG_ID="dev-org"

graphql_post() {
  local url="$1"
  local org_id="$2"
  local query="$3"
  local variables_json="$4"
  curl -s -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H "x-actor-id: $E2E_USER_ID" \
    -H 'x-actor-type: user' \
    -H "x-tenant-id: $E2E_TENANT_ID" \
    -H "x-organization-id: $org_id" \
    -H "x-workspace-id: $E2E_WORKSPACE_ID" \
    -d "$(jq -nc --arg q "$query" --argjson v "$variables_json" '{query:$q,variables:$v}')"
}

TIMESTAMP="$(date +%s)"

log_info "Creating EMAIL notification channel for org $ROUTING_ORG_ID"
CHANNEL_ID=$(graphql_post "$CHANNEL_URL" "$ROUTING_ORG_ID" \
  'mutation CreateChannel($input: CreateChannelInput!) { createChannel(input: $input) { id } }' \
  "$(jq -n --arg name "Auth Routing $TIMESTAMP" --arg org "$ROUTING_ORG_ID" '{input:{name:$name,platform:"EMAIL",channelType:"NOTIFICATION",adapterType:"AWS_SES",organizationId:$org,description:"doctor auth routing",priority:1}}')" | jq -r '.data.createChannel.id // empty')

if [ -z "$CHANNEL_ID" ]; then
  log_error 'Failed to create EMAIL channel for auth routing test'
  exit 1
fi

CONNECTION_ID=$(graphql_post "$CHANNEL_URL" "$ROUTING_ORG_ID" \
  'mutation CreateConnection($input: CreateConnectionInput!) { createConnection(input: $input) { id } }' \
  "$(jq -n --arg channelId "$CHANNEL_ID" '{input:{channelId:$channelId,authType:"API_KEY",credentials:{accessKeyId:"doctor-access",secretAccessKey:"doctor-secret",region:"ap-south-1",fromEmail:"contact@burdenoff.com"}}}')" | jq -r '.data.createConnection.id // empty')

if [ -z "$CONNECTION_ID" ]; then
  log_error 'Failed to create EMAIL connection for auth routing test'
  exit 1
fi

log_info "Triggering auth magic link email for $E2E_USER_EMAIL"

RESPONSE=$(curl -s -X POST "$AUTH_URL" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $E2E_AUTH_TOKEN" \
  -d "$(jq -nc --arg q 'mutation SendMagicLink($email: String!) { sendMagicLink(email: $email) { success message expiresIn } }' --argjson v "$(jq -n --arg email "$E2E_USER_EMAIL" '{email:$email}')" '{query:$q,variables:$v}')")

if ! echo "$RESPONSE" | jq -e '.data.sendMagicLink.success == true' >/dev/null 2>&1; then
  log_error 'Failed to trigger auth magic link email'
  log_error "Response: $RESPONSE"
  exit 1
fi

sleep 3

ATTEMPT=$(docker exec "${GLOBAL_POSTGRES_CONTAINER}" psql -U "${GLOBAL_POSTGRES_USER}" -d global_channel -t -A -F '|' \
  -c "select id,status from message_delivery_attempts where message->>'recipient'='${E2E_USER_EMAIL}' and message->>'platform'='EMAIL' order by \"createdAt\" desc limit 1;" 2>/dev/null || true)

if [ -z "$ATTEMPT" ]; then
  log_error 'No channel delivery attempt found for auth email routing'
  exit 1
fi

log_success "Auth email routed through global-channel-svc (attempt=$(echo "$ATTEMPT" | cut -d '|' -f1), status=$(echo "$ATTEMPT" | cut -d '|' -f2))"
