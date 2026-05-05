#!/bin/bash
#
# Configure Keycloak FGAP token exchange for all agent/tool clients in a realm.
#
# For each client with kagenti-style naming (namespace/workload), this script:
#   1. Enables management permissions (FGAP)
#   2. Creates a token-exchange scope permission on the client's authz server
#   3. Creates a token-exchange policy on realm-management allowing all agents
#
# Also restores the authproxy-routes so authbridge triggers token exchange.
#
# Environment: NAMESPACE, KEYCLOAK_REALM, KEYCLOAK_URL (or auto-detected)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"

KC_URL="${KEYCLOAK_URL:-}"
if [ -z "$KC_URL" ]; then
  KC_URL="https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}')"
fi

# Get admin credentials from keycloak-initial-admin
KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
if [ -z "$KC_ADMIN_USER" ] || [ -z "$KC_ADMIN_PASS" ]; then
  echo "ERROR: Could not read keycloak-initial-admin secret" >&2
  exit 1
fi

function _out() { echo "$(date +'%F %H:%M:%S') $*"; }

function get_token() {
  curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" | jq -r '.access_token'
}

function kc() {
  local method="$1" path="$2"; shift 2
  curl -sk -X "$method" "$KC_URL/admin/realms${path}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" "$@"
}

# --- Get admin token ---------------------------------------------------------

_out "Authenticating to Keycloak"
TOKEN=$(get_token)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to get admin token" >&2; exit 1
fi

# --- Discover clients --------------------------------------------------------

_out "Discovering clients in realm $REALM"

# Get all kagenti-registered clients (namespace/workload pattern) + playground client
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-$NAMESPACE}"
ALL_CLIENTS=$(kc GET "/$REALM/clients?max=100" | jq "[.[] | select(.clientId | startswith(\"${NAMESPACE}/\") or contains(\"/ns/${NAMESPACE}/sa/\") or . == \"${KEYCLOAK_CLIENT_ID}\")]")
CLIENT_COUNT=$(echo "$ALL_CLIENTS" | jq length)
_out "  Found $CLIENT_COUNT clients"

if [ "$CLIENT_COUNT" -eq 0 ]; then
  echo "ERROR: No kagenti clients found. Has the operator registered them?" >&2
  exit 1
fi

# Collect all client UUIDs
ALL_UUIDS_JSON=$(echo "$ALL_CLIENTS" | jq '[.[].id]')

# Get realm-management client UUID (holds FGAP policies)
REALM_MGMT_UUID=$(kc GET "/$REALM/clients?clientId=realm-management" | jq -r '.[0].id')

# --- Ensure ${KEYCLOAK_CLIENT_ID} is confidential (required for FGAP) --------

REDBANK_MCP_UUID=$(echo "$ALL_CLIENTS" | jq -r ".[] | select(.clientId == \"${KEYCLOAK_CLIENT_ID}\") | .id")
if [ -n "$REDBANK_MCP_UUID" ]; then
  TOKEN=$(get_token)
  IS_PUBLIC=$(kc GET "/$REALM/clients/$REDBANK_MCP_UUID" | jq -r '.publicClient')
  if [ "$IS_PUBLIC" = "true" ]; then
    _out "Making ${KEYCLOAK_CLIENT_ID} confidential (required for token exchange)"
    CLIENT_JSON=$(kc GET "/$REALM/clients/$REDBANK_MCP_UUID")
    UPDATED=$(echo "$CLIENT_JSON" | jq '.publicClient = false | .serviceAccountsEnabled = true')
    TOKEN=$(get_token)
    kc PUT "/$REALM/clients/$REDBANK_MCP_UUID" -d "$UPDATED" > /dev/null
  fi
fi

# --- Configure each client ---------------------------------------------------

# First pass: enable FGAP on all clients (this initializes realm-management authz)
for ROW in $(echo "$ALL_CLIENTS" | jq -r '.[] | @base64'); do
  CLIENT_UUID=$(echo "$ROW" | base64 -d | jq -r '.id')
  SHORT_NAME=$(echo "$ROW" | base64 -d | jq -r '.clientId' | sed "s|${NAMESPACE}/||" | sed 's|.*/sa/||')

  TOKEN=$(get_token)
  _out "Enabling FGAP on $SHORT_NAME"

  # Enable authorizationServicesEnabled
  kc PUT "/$REALM/clients/$CLIENT_UUID" -d '{"authorizationServicesEnabled": true}' > /dev/null 2>&1 || true

  # Create token-exchange scope permission on client's own authz server
  EXISTING=$(kc GET "/$REALM/clients/$CLIENT_UUID/authz/resource-server/permission?name=token-exchange-permission" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)
  if [ -z "$EXISTING" ]; then
    kc POST "/$REALM/clients/$CLIENT_UUID/authz/resource-server/permission/scope" \
      -d '{"name":"token-exchange-permission","type":"scope","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","resourceType":"token-exchange"}' > /dev/null 2>&1 || true
    _out "  Created token-exchange scope permission"
  fi

  # Enable management permissions
  kc PUT "/$REALM/clients/$CLIENT_UUID/management/permissions" -d '{"enabled": true}' > /dev/null 2>&1 || true

  # Set standard.token.exchange.enabled=false (use FGAP path)
  kc PUT "/$REALM/clients/$CLIENT_UUID" \
    -d '{"attributes":{"standard.token.exchange.enabled":"false"}}' > /dev/null 2>&1 || true
done

# Now get the token-exchange scope (should exist after enabling FGAP above)
TOKEN=$(get_token)
TX_SCOPE_ID=$(kc GET "/$REALM/clients/$REALM_MGMT_UUID/authz/resource-server/scope?name=token-exchange" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)
if [ -z "$TX_SCOPE_ID" ]; then
  _out "WARNING: token-exchange scope not found on realm-management. Token exchange may not work."
  _out "  Ensure Keycloak has admin-fine-grained-authz:v1 feature enabled."
fi

# Second pass: create FGAP policies linking all clients
for ROW in $(echo "$ALL_CLIENTS" | jq -r '.[] | @base64'); do
  CLIENT_UUID=$(echo "$ROW" | base64 -d | jq -r '.id')
  SHORT_NAME=$(echo "$ROW" | base64 -d | jq -r '.clientId' | sed "s|${NAMESPACE}/||" | sed 's|.*/sa/||')

  TOKEN=$(get_token)
  _out "Creating FGAP policy for $SHORT_NAME"

  # Look up management permission IDs
  MGMT_INFO=$(kc GET "/$REALM/clients/$CLIENT_UUID/management/permissions")
  TX_PERM_ID=$(echo "$MGMT_INFO" | jq -r '.scopePermissions["token-exchange"] // empty')
  RESOURCE_ID=$(echo "$MGMT_INFO" | jq -r '.resource // empty')

  if [ -z "$TX_PERM_ID" ] || [ -z "$TX_SCOPE_ID" ]; then
    _out "  Skipping — missing permission or scope ID"
    continue
  fi

  # Create client policy allowing all agents
  POLICY_NAME="all-agents-exchange-${SHORT_NAME}"
  EXISTING_POLICY=$(kc GET "/$REALM/clients/$REALM_MGMT_UUID/authz/resource-server/policy?name=$POLICY_NAME" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)

  if [ -z "$EXISTING_POLICY" ]; then
    POLICY_ID=$(kc POST "/$REALM/clients/$REALM_MGMT_UUID/authz/resource-server/policy/client" \
      -d "{\"name\":\"$POLICY_NAME\",\"type\":\"client\",\"logic\":\"POSITIVE\",\"decisionStrategy\":\"UNANIMOUS\",\"clients\":$ALL_UUIDS_JSON}" | jq -r '.id // empty')
    _out "  Created policy: $POLICY_NAME"
  else
    POLICY_ID="$EXISTING_POLICY"
    # Update existing policy with current client list
    kc PUT "/$REALM/clients/$REALM_MGMT_UUID/authz/resource-server/policy/client/$POLICY_ID" \
      -d "{\"id\":\"$POLICY_ID\",\"name\":\"$POLICY_NAME\",\"type\":\"client\",\"logic\":\"POSITIVE\",\"decisionStrategy\":\"UNANIMOUS\",\"clients\":$ALL_UUIDS_JSON}" > /dev/null 2>&1 || true
    _out "  Updated policy: $POLICY_NAME"
  fi

  # Link policy to the token-exchange permission
  if [ -n "$POLICY_ID" ]; then
    kc PUT "/$REALM/clients/$REALM_MGMT_UUID/authz/resource-server/permission/scope/$TX_PERM_ID" \
      -d "{\"id\":\"$TX_PERM_ID\",\"name\":\"token-exchange.permission.client.$CLIENT_UUID\",\"type\":\"scope\",\"logic\":\"POSITIVE\",\"decisionStrategy\":\"UNANIMOUS\",\"resources\":[\"$RESOURCE_ID\"],\"scopes\":[\"$TX_SCOPE_ID\"],\"policies\":[\"$POLICY_ID\"]}" > /dev/null 2>&1 || true
    _out "  Linked to permission"
  fi
done

# --- Assign audience scopes to all clients ------------------------------------
# Realm default scopes don't retroactively apply to existing clients.
# Explicitly assign all agent-*-aud scopes to every kagenti client.

TOKEN=$(get_token)
_out "Assigning audience scopes to all clients"
AGENT_SCOPES=$(kc GET "/$REALM/client-scopes" | jq -r '.[] | select(.name | test("^agent-")) | "\(.id) \(.name)"')
if [ -n "$AGENT_SCOPES" ]; then
  for ROW in $(echo "$ALL_CLIENTS" | jq -r '.[].id'); do
    echo "$AGENT_SCOPES" | while read SID SNAME; do
      TOKEN=$(get_token)
      kc PUT "/$REALM/clients/$ROW/default-client-scopes/$SID" > /dev/null 2>&1 || true
    done
  done
  _out "  Audience scopes assigned"
else
  _out "  No agent-*-aud scopes found (operator may not have created them yet)"
fi

# --- Fix audience scope mappers for SPIFFE clients ----------------------------
# The operator creates audience scopes with short-form client IDs (namespace/name),
# but SPIFFE clients are registered with full SPIFFE URIs. Fix the mismatch so that
# tokens include the actual client ID in the aud claim.

TOKEN=$(get_token)
HAS_SPIFFE_CLIENTS=$(echo "$ALL_CLIENTS" | jq '[.[] | select(.clientId | startswith("spiffe://"))] | length')
if [ "$HAS_SPIFFE_CLIENTS" -gt 0 ] && [ -n "$AGENT_SCOPES" ]; then
  _out "Fixing audience scope mappers for SPIFFE clients"
  echo "$AGENT_SCOPES" | while read SID SNAME; do
    TOKEN=$(get_token)
    MAPPER=$(kc GET "/$REALM/client-scopes/$SID/protocol-mappers/models" | jq '.[0]')
    MAPPER_ID=$(echo "$MAPPER" | jq -r '.id // empty')
    CURRENT_AUD=$(echo "$MAPPER" | jq -r '.config["included.custom.audience"] // empty')

    # Skip if already a SPIFFE URI or no mapper
    if [ -z "$MAPPER_ID" ] || [ -z "$CURRENT_AUD" ] || echo "$CURRENT_AUD" | grep -q "^spiffe://"; then
      continue
    fi

    # Extract workload name from short-form (namespace/workload -> workload)
    WORKLOAD="${CURRENT_AUD##*/}"
    SPIFFE_ID=$(echo "$ALL_CLIENTS" | jq -r ".[] | select(.clientId | endswith(\"/sa/$WORKLOAD\")) | .clientId")

    if [ -n "$SPIFFE_ID" ]; then
      UPDATED=$(echo "$MAPPER" | jq --arg aud "$SPIFFE_ID" '.config["included.custom.audience"] = $aud')
      TOKEN=$(get_token)
      kc PUT "/$REALM/client-scopes/$SID/protocol-mappers/models/$MAPPER_ID" \
        -d "$UPDATED" > /dev/null 2>&1
      _out "  Fixed $SNAME: $CURRENT_AUD -> $SPIFFE_ID"
    fi
  done
fi

# --- Update playground with client secret (confidential client) ---------------

if [ -n "$REDBANK_MCP_UUID" ]; then
  TOKEN=$(get_token)
  MCP_SECRET=$(kc GET "/$REALM/clients/$REDBANK_MCP_UUID/client-secret" | jq -r '.value // empty')
  if [ -n "$MCP_SECRET" ]; then
    _out "Storing ${KEYCLOAK_CLIENT_ID} client secret for playground"
    oc create secret generic keycloak-client-credentials \
      --from-literal=client-secret="$MCP_SECRET" \
      -n "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

    # Patch playground deployment if it exists
    if oc get deployment redbank-playground -n "${NAMESPACE}" &>/dev/null; then
      HAS_SECRET=$(oc get deployment redbank-playground -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KEYCLOAK_CLIENT_SECRET")].name}' 2>/dev/null)
      if [ -z "$HAS_SECRET" ]; then
        oc patch deployment redbank-playground -n "${NAMESPACE}" --type=json \
          -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"KEYCLOAK_CLIENT_SECRET","valueFrom":{"secretKeyRef":{"name":"keycloak-client-credentials","key":"client-secret"}}}}]'
        _out "  Patched playground with client secret"
      else
        _out "  Playground already has client secret"
      fi
    fi
  fi
fi

# --- Update authproxy-routes -------------------------------------------------

_out ""
_out "Updating authproxy-routes to enable token exchange for redbank-mcp-server"

# Look up the MCP server's actual Keycloak client ID (may be a SPIFFE URI)
TOKEN=$(get_token)
MCP_TARGET_AUD=$(echo "$ALL_CLIENTS" | jq -r '[.[] | select(.clientId | contains("mcp-server"))][0].clientId // empty')
if [ -z "$MCP_TARGET_AUD" ]; then
  MCP_TARGET_AUD="${KEYCLOAK_CLIENT_ID}"
  _out "  WARNING: MCP server client not found, falling back to ${KEYCLOAK_CLIENT_ID}"
fi

cat <<EOF | oc apply -n "${NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: authproxy-routes
data:
  routes.yaml: |
    - host: "redbank-mcp-server"
      target_audience: "${MCP_TARGET_AUD}"
      token_scopes: "openid"
EOF

# --- Restart agents ----------------------------------------------------------

_out "Restarting agents to pick up new routes..."
oc rollout restart deployment/redbank-orchestrator deployment/redbank-banking-agent deployment/redbank-knowledge-agent -n "${NAMESPACE}" 2>/dev/null || true

_out ""
_out "Token exchange configured!"
_out "  Realm:   $REALM"
_out "  Clients: $CLIENT_COUNT"
_out "  Route:   redbank-mcp-server -> audience ${MCP_TARGET_AUD}"
