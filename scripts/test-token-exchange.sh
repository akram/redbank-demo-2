#!/bin/bash
set -e

# Decode a JWT payload (handles base64url padding)
decode_jwt() {
  local payload
  payload=$(echo "$1" | cut -d'.' -f2 | tr '_-' '/+')
  local pad=$(( 4 - ${#payload} % 4 ))
  [ "$pad" -lt 4 ] && payload="${payload}$(printf '%0.s=' $(seq 1 $pad))"
  echo "$payload" | base64 -d 2>/dev/null | jq '.'
}

# Get a user token via password grant.
get_user_token() {
  local username="$1" password="$2" client_id="${3:-$KEYCLOAK_CLIENT_ID}"
  local secret_arg=""
  if [ -n "$PLAYGROUND_CLIENT_SECRET" ] && [ "$client_id" = "$KEYCLOAK_CLIENT_ID" ]; then
    secret_arg="-d client_secret=$PLAYGROUND_CLIENT_SECRET"
  fi
  curl -sk -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=$client_id" \
    $secret_arg \
    -d "username=$username" \
    -d "password=$password" \
    -d "scope=openid" | jq -r '.access_token // empty'
}

# Token exchange using client_secret auth (non-SPIFFE).
do_token_exchange() {
  local label="$1" subject_token="$2" client_id="$3" client_secret="$4" audience="${5:-account}"

  echo ""
  echo "=== Token Exchange: $label ==="

  local response
  response=$(curl -sk -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "client_id=$client_id" \
    -d "client_secret=$client_secret" \
    -d "subject_token=$subject_token" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "audience=$audience")

  if echo "$response" | jq -e '.access_token' > /dev/null 2>&1; then
    echo "TOKEN EXCHANGE SUCCEEDED"
    echo "Exchanged token claims:"
    decode_jwt "$(echo "$response" | jq -r '.access_token')" || echo "Could not decode"
    return 0
  else
    echo "TOKEN EXCHANGE FAILED"
    echo "Error: $(echo "$response" | jq -r '.error // "unknown"')"
    echo "Description: $(echo "$response" | jq -r '.error_description // "no description"')"
    return 1
  fi
}

# Run a Keycloak token request from inside a pod using JWT-SVID auth.
# Reads JWT-SVID and client-id from envoy-proxy, executes curl from the app container.
do_spiffe_request() {
  local pod="$1" app_container="$2"
  shift 2
  # Extra curl args passed as remaining parameters

  # Read JWT-SVID and client ID from the envoy-proxy container
  local jwt_svid client_id
  jwt_svid=$(kubectl exec "$pod" -n "$NAMESPACE" -c envoy-proxy -- cat /opt/jwt_svid.token 2>/dev/null)
  client_id=$(kubectl exec "$pod" -n "$NAMESPACE" -c envoy-proxy -- cat /shared/client-id.txt 2>/dev/null)

  if [ -z "$jwt_svid" ] || [ -z "$client_id" ]; then
    echo '{"error":"missing jwt_svid or client_id in pod"}'
    return
  fi

  # Run curl from the app container (which has curl installed)
  kubectl exec "$pod" -n "$NAMESPACE" -c "$app_container" -- \
    curl -sk -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
      --data-urlencode "client_id=${client_id}" \
      -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
      --data-urlencode "client_assertion=${jwt_svid}" \
      "$@" 2>/dev/null
}

# Token exchange using JWT-SVID auth (SPIFFE mode).
do_spiffe_token_exchange() {
  local label="$1" deploy="$2" app_container="$3" audience="$4" subject_token="$5"

  echo ""
  echo "=== Token Exchange (SPIFFE): $label ==="

  local pod
  pod=$(kubectl get pod -n "$NAMESPACE" -l "app=$deploy" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    echo "No pod found for deployment $deploy"
    return 1
  fi

  local result
  result=$(do_spiffe_request "$pod" "$app_container" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    --data-urlencode "subject_token=${subject_token}" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
    --data-urlencode "audience=${audience}")

  if echo "$result" | jq -e '.access_token' > /dev/null 2>&1; then
    echo "TOKEN EXCHANGE SUCCEEDED"
    echo "Exchanged token claims:"
    decode_jwt "$(echo "$result" | jq -r '.access_token')" || echo "Could not decode"
    return 0
  else
    echo "TOKEN EXCHANGE FAILED"
    echo "Error: $(echo "$result" | jq -r '.error // "unknown"')"
    echo "Description: $(echo "$result" | jq -r '.error_description // "no description"')"
    return 1
  fi
}

# Test client_credentials grant from inside a pod (SPIFFE mode).
do_spiffe_client_credentials() {
  local label="$1" deploy="$2" app_container="$3"

  echo ""
  echo "=== Client Credentials (SPIFFE): $label ==="

  local pod
  pod=$(kubectl get pod -n "$NAMESPACE" -l "app=$deploy" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    echo "No pod found for deployment $deploy"
    return 1
  fi

  local result
  result=$(do_spiffe_request "$pod" "$app_container" \
    -d "grant_type=client_credentials")

  if echo "$result" | jq -e '.access_token' > /dev/null 2>&1; then
    echo "TOKEN EXCHANGE SUCCEEDED"
    echo "Token claims:"
    decode_jwt "$(echo "$result" | jq -r '.access_token')" || echo "Could not decode"
    return 0
  else
    echo "TOKEN EXCHANGE FAILED"
    echo "Error: $(echo "$result" | jq -r '.error // "unknown"')"
    echo "Description: $(echo "$result" | jq -r '.error_description // "no description"')"
    return 1
  fi
}

# --- Load configuration from .env -------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

NAMESPACE="${NAMESPACE:-redbank-demo}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
FAILURES=0

# Use external Keycloak URL
if [ -n "${KEYCLOAK_URL:-}" ]; then
  KC_URL="$KEYCLOAK_URL"
else
  KC_URL="https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
fi
KEYCLOAK_URL="$KC_URL"

# Detect SPIFFE mode — only when using federated-jwt auth (not client-secret with SPIFFE IDs)
CLIENT_AUTH_TYPE=$(kubectl get configmap authbridge-config -n "$NAMESPACE" -o jsonpath='{.data.CLIENT_AUTH_TYPE}' 2>/dev/null)
if [ "$CLIENT_AUTH_TYPE" = "federated-jwt" ]; then
  SPIFFE_MODE=true
else
  SPIFFE_MODE=false
fi

echo "Testing token exchange in namespace: ${NAMESPACE}, realm: ${REALM}"
echo "Keycloak URL: ${KEYCLOAK_URL}"
echo "SPIFFE mode: ${SPIFFE_MODE}"

# --- Get admin token ---------------------------------------------------------

echo ""
echo "=== Getting Keycloak admin token ==="
KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
ADMIN_TOKEN=$(curl -sk "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=admin-cli" \
  -d "username=${KC_ADMIN_USER:-admin}" -d "password=${KC_ADMIN_PASS:-admin}" | jq -r '.access_token // empty')
if [ -z "$ADMIN_TOKEN" ]; then
  echo "WARNING: Could not get admin token"
fi

# --- Get playground client secret ---------------------------------------------

KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-$NAMESPACE}"
PLAYGROUND_CLIENT_SECRET=""
if [ -n "$ADMIN_TOKEN" ]; then
  PLAYGROUND_UUID=$(curl -sk "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=$KEYCLOAK_CLIENT_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id // empty')
  if [ -n "$PLAYGROUND_UUID" ]; then
    PLAYGROUND_CLIENT_SECRET=$(curl -sk "$KEYCLOAK_URL/admin/realms/$REALM/clients/$PLAYGROUND_UUID/client-secret" \
      -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.value // empty')
  fi
fi

# --- Discover agent credentials ----------------------------------------------

echo "=== Discovering agent credentials in ${NAMESPACE} ==="

KNOWLEDGE_SECRET=""
KNOWLEDGE_AGENT_CLIENT_ID=""
KNOWLEDGE_AGENT_CLIENT_SECRET=""
for secret in $(kubectl get secrets -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep kagenti-keycloak-client-credentials); do
  CID=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.client-id\.txt}' | base64 -d)
  if echo "$CID" | grep -q "knowledge-agent"; then
    KNOWLEDGE_SECRET="$secret"
    KNOWLEDGE_AGENT_CLIENT_ID="$CID"
    KNOWLEDGE_AGENT_CLIENT_SECRET=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.client-secret\.txt}' | base64 -d)
    break
  fi
done

if [ -z "$KNOWLEDGE_SECRET" ]; then
  echo "ERROR: Could not find knowledge-agent credentials in namespace ${NAMESPACE}"
  exit 1
fi
echo "Knowledge agent: $KNOWLEDGE_AGENT_CLIENT_ID (secret: $KNOWLEDGE_SECRET)"

MCP_SECRET_NAME=""
MCP_CLIENT_ID=""
MCP_CLIENT_SECRET=""
for secret in $(kubectl get secrets -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep kagenti-keycloak-client-credentials); do
  CID=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.client-id\.txt}' | base64 -d)
  if echo "$CID" | grep -q "mcp-server"; then
    MCP_SECRET_NAME="$secret"
    MCP_CLIENT_ID="$CID"
    MCP_CLIENT_SECRET=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data.client-secret\.txt}' | base64 -d)
    break
  fi
done

# ============================================================================
# Test 1: MCP server client_credentials + token exchange
# ============================================================================
echo ""
echo "=========================================="
echo "Test 1: MCP server (client_credentials)"
echo "=========================================="

if [ -z "$MCP_SECRET_NAME" ]; then
  echo "Skipping — MCP server credentials not found"
  FAILURES=$((FAILURES + 1))
elif [ "$SPIFFE_MODE" = "true" ]; then
  echo "SPIFFE mode — running from inside MCP server pod"
  do_spiffe_client_credentials "MCP server client_credentials" "redbank-mcp-server" "mcp-server" || FAILURES=$((FAILURES + 1))
else
  MCP_TOKEN=$(curl -sk -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=$MCP_CLIENT_ID" \
    -d "client_secret=$MCP_CLIENT_SECRET" | jq -r '.access_token // empty')

  if [ -z "$MCP_TOKEN" ]; then
    echo "Failed to get MCP server token"
    FAILURES=$((FAILURES + 1))
  else
    echo "Got MCP server token"
    echo "Token claims:"
    decode_jwt "$MCP_TOKEN" || echo "Could not decode"
    do_token_exchange "MCP server -> knowledge-agent" "$MCP_TOKEN" "$KNOWLEDGE_AGENT_CLIENT_ID" "$KNOWLEDGE_AGENT_CLIENT_SECRET" "$KNOWLEDGE_AGENT_CLIENT_ID" || FAILURES=$((FAILURES + 1))
  fi
fi

# ============================================================================
# Test 2: john (user role) password grant + token exchange
# ============================================================================
echo ""
echo "=========================================="
echo "Test 2: john (user role, password grant)"
echo "=========================================="

JOHN_TOKEN=$(get_user_token "john" "john123")
if [ -z "$JOHN_TOKEN" ]; then
  echo "Failed to get token for john"
  FAILURES=$((FAILURES + 1))
else
  echo "Got token for john"
  echo "Token claims:"
  decode_jwt "$JOHN_TOKEN" || echo "Could not decode"

  if [ "$SPIFFE_MODE" = "true" ]; then
    echo "SPIFFE mode — running exchange from inside knowledge-agent pod"
    do_spiffe_token_exchange "john -> knowledge-agent (target: mcp-server)" "redbank-knowledge-agent" "knowledge-agent" "$MCP_CLIENT_ID" "$JOHN_TOKEN" || FAILURES=$((FAILURES + 1))
  else
    do_token_exchange "john -> knowledge-agent (target: mcp-server)" "$JOHN_TOKEN" "$KNOWLEDGE_AGENT_CLIENT_ID" "$KNOWLEDGE_AGENT_CLIENT_SECRET" "$MCP_CLIENT_ID" || FAILURES=$((FAILURES + 1))
  fi
fi

# ============================================================================
# Test 3: jane (admin role) password grant + token exchange
# ============================================================================
echo ""
echo "=========================================="
echo "Test 3: jane (admin role, password grant)"
echo "=========================================="

JANE_TOKEN=$(get_user_token "jane" "jane123")
if [ -z "$JANE_TOKEN" ]; then
  echo "Failed to get token for jane"
  FAILURES=$((FAILURES + 1))
else
  echo "Got token for jane"
  echo "Token claims:"
  decode_jwt "$JANE_TOKEN" || echo "Could not decode"

  if [ "$SPIFFE_MODE" = "true" ]; then
    echo "SPIFFE mode — running exchange from inside knowledge-agent pod"
    do_spiffe_token_exchange "jane -> knowledge-agent (target: mcp-server)" "redbank-knowledge-agent" "knowledge-agent" "$MCP_CLIENT_ID" "$JANE_TOKEN" || FAILURES=$((FAILURES + 1))
  else
    do_token_exchange "jane -> knowledge-agent (target: mcp-server)" "$JANE_TOKEN" "$KNOWLEDGE_AGENT_CLIENT_ID" "$KNOWLEDGE_AGENT_CLIENT_SECRET" "$MCP_CLIENT_ID" || FAILURES=$((FAILURES + 1))
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "$FAILURES test(s) failed"
  exit 1
fi
