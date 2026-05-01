#!/bin/bash
#
# Enable SPIFFE identity for all kagenti workloads in the namespace.
#
# This script:
#   1. Updates authbridge-config with SPIRE_ENABLED=true and CLIENT_AUTH_TYPE=federated-jwt
#   2. Ensures each workload deployment has a dedicated ServiceAccount
#   3. Deletes existing keycloak credential secrets so the operator re-registers with SPIFFE IDs
#   4. Deletes per-agent authbridge configmaps so they regenerate with SPIFFE identity
#   5. Restarts all workloads
#
# Environment: NAMESPACE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

NAMESPACE="${NAMESPACE:?NAMESPACE is required}"

function _out() { echo "$(date +'%F %H:%M:%S') $*"; }

_out "Enabling SPIFFE identity in namespace ${NAMESPACE}"

# --- 1. Detect SPIFFE IDP and choose auth type ------------------------------

REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
KC_HOST="${KEYCLOAK_HOST:-$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' 2>/dev/null)}"
KC_URL="https://${KC_HOST}"
KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null || true)
KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null || true)

AUTH_TYPE="client-secret"
if [ -n "$KC_ADMIN_USER" ] && [ -n "$KC_ADMIN_PASS" ]; then
  TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  if [ -n "$TOKEN" ]; then
    HAS_SPIFFE_IDP=$(curl -sk "$KC_URL/admin/realms/$REALM/identity-provider/instances" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[] | select(.providerId == "spiffe") | .alias' 2>/dev/null || true)
    if [ -n "$HAS_SPIFFE_IDP" ]; then
      AUTH_TYPE="federated-jwt"
      _out "  SPIFFE IDP '${HAS_SPIFFE_IDP}' found — using federated-jwt"
    else
      _out "  No SPIFFE IDP found — falling back to client-secret"
    fi
  fi
fi

# --- 1b. Update authbridge-config -------------------------------------------

_out "Updating authbridge-config (SPIRE_ENABLED=true, CLIENT_AUTH_TYPE=${AUTH_TYPE})"
oc patch configmap authbridge-config -n "${NAMESPACE}" --type=merge \
  -p "{\"data\":{\"SPIRE_ENABLED\":\"true\",\"CLIENT_AUTH_TYPE\":\"${AUTH_TYPE}\"}}"

# --- 2. Update authbridge-runtime-config -------------------------------------

_out "Updating authbridge-runtime-config (identity type + jwt_svid_path)"
RUNTIME_YAML=$(oc get configmap authbridge-runtime-config -n "${NAMESPACE}" -o jsonpath='{.data.config\.yaml}')
UPDATED_YAML=$(echo "$RUNTIME_YAML" | python3 -c "
import sys
lines = []
has_svid = False
for line in sys.stdin:
    stripped = line.rstrip()
    if 'jwt_svid_path' in stripped:
        has_svid = True
    lines.append(stripped)
# Rewrite with correct identity type and jwt_svid_path
result = []
for line in lines:
    if 'type: \"client-secret\"' in line:
        result.append(line.replace('client-secret', 'spiffe'))
    else:
        result.append(line)
    if 'client_secret_file' in line and not has_svid:
        indent = len(line) - len(line.lstrip())
        result.append(' ' * indent + 'jwt_svid_path: \"/opt/jwt_svid.token\"')
print('\n'.join(result))
")
oc patch configmap authbridge-runtime-config -n "${NAMESPACE}" --type=merge \
  -p "{\"data\":{\"config.yaml\":$(echo "$UPDATED_YAML" | jq -Rs .)}}"

# --- 2b. Fix spiffe-helper JWT audience to match Keycloak issuer ------------
# Community Keycloak uses http:// when TLS terminates at the route

_out "Checking Keycloak issuer for JWT audience"
KC_HOST="${KEYCLOAK_HOST:-$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}')}"
REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
KC_ISSUER=$(curl -sk "https://${KC_HOST}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty')
if [ -n "$KC_ISSUER" ]; then
  CURRENT_AUD=$(oc get configmap spiffe-helper-config -n "${NAMESPACE}" -o jsonpath='{.data.helper\.conf}' | grep -o 'jwt_audience="[^"]*"' | sed 's/jwt_audience="//' | sed 's/"//')
  if [ "$KC_ISSUER" != "$CURRENT_AUD" ]; then
    _out "  Updating JWT audience: $CURRENT_AUD -> $KC_ISSUER"
    HELPER_CONF=$(oc get configmap spiffe-helper-config -n "${NAMESPACE}" -o jsonpath='{.data.helper\.conf}')
    UPDATED_CONF=$(echo "$HELPER_CONF" | sed "s|jwt_audience=\"${CURRENT_AUD}\"|jwt_audience=\"${KC_ISSUER}\"|")
    oc patch configmap spiffe-helper-config -n "${NAMESPACE}" --type=merge \
      -p "{\"data\":{\"helper.conf\":$(echo "$UPDATED_CONF" | jq -Rs .)}}"
  else
    _out "  JWT audience already matches Keycloak issuer"
  fi
fi

# --- 3. Ensure dedicated ServiceAccounts ------------------------------------

_out "Ensuring dedicated ServiceAccounts for all workloads"

WORKLOADS=$(oc get deploy -n "${NAMESPACE}" -l 'kagenti.io/type in (agent,tool)' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
# Fallback: find workloads by name pattern if labels aren't set
if [ -z "$WORKLOADS" ]; then
  WORKLOADS=$(oc get deploy -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "redbank-(banking|knowledge|mcp|orchestrator)")
fi

for DEPLOY in $WORKLOADS; do
  CURRENT_SA=$(oc get deploy "$DEPLOY" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)
  if [ -z "$CURRENT_SA" ] || [ "$CURRENT_SA" = "default" ]; then
    SA_NAME="$DEPLOY"
    _out "  ${DEPLOY}: creating SA ${SA_NAME} and updating deployment"
    oc create sa "$SA_NAME" -n "${NAMESPACE}" 2>/dev/null || true
    oc patch deploy "$DEPLOY" -n "${NAMESPACE}" --type=json \
      -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/serviceAccountName\",\"value\":\"${SA_NAME}\"}]"
  else
    _out "  ${DEPLOY}: already uses SA ${CURRENT_SA}"
  fi
done

# --- 4. Delete old credential secrets and per-agent configmaps ---------------

_out "Deleting old Keycloak clients (operator will re-register with SPIFFE IDs)"
if [ -n "$TOKEN" ]; then
  # Re-fetch token (may have expired)
  TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  if [ -n "$TOKEN" ]; then
    CLIENT_UUIDS=$(curl -sk "$KC_URL/admin/realms/$REALM/clients?max=100" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null | \
      jq -r ".[] | select(.clientId | contains(\"/ns/${NAMESPACE}/sa/\") or startswith(\"${NAMESPACE}/\")) | .id" 2>/dev/null || true)
    for UUID in $CLIENT_UUIDS; do
      TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" -d "client_id=admin-cli" \
        -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
      curl -sk -X DELETE "$KC_URL/admin/realms/$REALM/clients/$UUID" \
        -H "Authorization: Bearer $TOKEN" -o /dev/null 2>/dev/null || true
    done
    _out "  Deleted $(echo "$CLIENT_UUIDS" | grep -c . || echo 0) Keycloak clients"
  fi
fi

_out "Deleting old keycloak credential secrets"
for SECRET in $(oc get secrets -n "${NAMESPACE}" -o name | grep kagenti-keycloak-client-credentials); do
  oc delete "$SECRET" -n "${NAMESPACE}"
done

_out "Deleting per-agent authbridge configmaps (will regenerate with SPIFFE identity)"
for CM in $(oc get configmap -n "${NAMESPACE}" -o name | grep authbridge-config-redbank); do
  oc delete "$CM" -n "${NAMESPACE}"
done

# --- 5. Restart workloads ----------------------------------------------------

_out "Restarting all workloads to pick up SPIFFE identity"
for DEPLOY in $WORKLOADS; do
  oc rollout restart "deploy/$DEPLOY" -n "${NAMESPACE}"
done

_out ""
_out "SPIFFE identity enabled in namespace ${NAMESPACE}"
_out ""
_out "Next steps:"
_out "  1. Wait for pods to be 3/3 Running:"
_out "       oc get pods -n ${NAMESPACE} -w"
_out "  2. Re-run token exchange setup (FGAP policies need new SPIFFE client IDs):"
_out "       make configure-token-exchange"
