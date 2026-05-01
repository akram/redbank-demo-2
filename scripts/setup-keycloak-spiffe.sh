#!/bin/bash
#
# Configure the SPIFFE Identity Provider in Keycloak for JWT-SVID authentication.
#
# Creates a "spiffe" type Identity Provider in the target realm so that
# Keycloak clients with clientAuthenticatorType=federated-jwt can authenticate
# using SPIFFE JWT-SVIDs.
#
# Prerequisites:
#   - SPIRE installed and OIDC discovery provider accessible
#   - Keycloak with SPIFFE provider support (RHBK 26+)
#
# Environment: KEYCLOAK_REALM (from .env)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; source "$SCRIPT_DIR/../.env"; set +a
fi

REALM="${KEYCLOAK_REALM:-$NAMESPACE}"
IDP_ALIAS="${SPIFFE_IDP_ALIAS:-spire-spiffe}"

# Keycloak URL
KC_URL="${KEYCLOAK_URL:-}"
if [ -z "$KC_URL" ]; then
  KC_URL="https://$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}')"
fi

# Admin credentials from keycloak-initial-admin secret
KC_ADMIN_USER=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.username | base64decode}}' 2>/dev/null)
KC_ADMIN_PASS=$(kubectl get secret keycloak-initial-admin -n keycloak -o go-template='{{.data.password | base64decode}}' 2>/dev/null)
if [ -z "$KC_ADMIN_USER" ] || [ -z "$KC_ADMIN_PASS" ]; then
  echo "ERROR: Could not read keycloak-initial-admin secret" >&2
  exit 1
fi

# SPIRE trust domain from the operator
TRUST_DOMAIN=$(oc get deploy kagenti-controller-manager -n kagenti-system -o json 2>/dev/null | \
  jq -r '.spec.template.spec.containers[0].args[]? | select(startswith("--spire-trust-domain=")) | split("=")[1]' 2>/dev/null)
if [ -z "$TRUST_DOMAIN" ]; then
  TRUST_DOMAIN=$(oc get route -n keycloak -o jsonpath='{.items[0].spec.host}' | sed 's/^keycloak-keycloak\.//')
  echo "WARNING: Could not read --spire-trust-domain from operator, using cluster domain: $TRUST_DOMAIN"
fi

# SPIRE OIDC discovery provider URL
SPIRE_NS=$(oc get ns zero-trust-workload-identity-manager -o name 2>/dev/null | sed 's|namespace/||' || echo "spire-server")
BUNDLE_ENDPOINT="https://spire-spiffe-oidc-discovery-provider.${SPIRE_NS}.svc.cluster.local/keys"

function _out() { echo "$(date +'%F %H:%M:%S') $*"; }

function get_token() {
  curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true
}

# --- Ensure Keycloak proxy headers are configured ----------------------------
# Community Keycloak behind an OpenShift route needs proxy.headers=xforwarded
# so it uses https:// in its issuer URL (TLS terminates at the route).

_out "Ensuring Keycloak features, proxy headers, and SPIRE CA truststore"

# Create SPIRE CA secret for Keycloak truststore (service-serving CA)
if oc get configmap openshift-service-ca.crt -n keycloak -o jsonpath='{.data.service-ca\.crt}' > /tmp/service-ca.crt 2>/dev/null && [ -s /tmp/service-ca.crt ]; then
  oc create secret generic spire-oidc-ca -n keycloak --from-file=ca.crt=/tmp/service-ca.crt --dry-run=client -o yaml | oc apply -f - > /dev/null 2>&1
  _out "  SPIRE CA secret created/updated"
fi

oc patch keycloak keycloak -n keycloak --type=merge \
  -p '{"spec":{"proxy":{"headers":"xforwarded"},"features":{"enabled":["preview","token-exchange","admin-fine-grained-authz:v1","client-auth-federated:v1","spiffe:v1"]},"truststores":{"spire-oidc":{"secret":{"name":"spire-oidc-ca"}}}}}' 2>/dev/null && \
  _out "  Features, proxy headers, and truststore configured" || \
  _out "  WARNING: Could not patch Keycloak CR"

# Wait for Keycloak to restart if features changed
KC_READY=$(oc get pod keycloak-0 -n keycloak -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
if [ "$KC_READY" != "true" ]; then
  _out "  Waiting for Keycloak restart..."
  oc rollout status statefulset/keycloak -n keycloak --timeout=5m 2>/dev/null || true
fi

# --- Set up SPIFFE Identity Provider ----------------------------------------

_out "Setting up SPIFFE Identity Provider in Keycloak"
_out "  Realm:           $REALM"
_out "  IDP Alias:       $IDP_ALIAS"
_out "  Trust Domain:    $TRUST_DOMAIN"
_out "  Bundle Endpoint: $BUNDLE_ENDPOINT"
_out ""

# --- Verify SPIRE OIDC endpoint is accessible from cluster -------------------

# --- Enable CREATE_ONLY_MODE on ZTWIM operator --------------------------------
# This prevents the operator from reverting configmap changes (like set_key_use).

_out "Enabling CREATE_ONLY_MODE on ZTWIM operator subscription"
ZTWIM_SUB=$(oc get subscription -n "${SPIRE_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$ZTWIM_SUB" ]; then
  HAS_COM=$(oc get subscription "$ZTWIM_SUB" -n "${SPIRE_NS}" -o json | jq -r '.spec.config.env[]? | select(.name=="CREATE_ONLY_MODE") | .value' 2>/dev/null)
  if [ "$HAS_COM" != "true" ]; then
    oc patch subscription "$ZTWIM_SUB" -n "${SPIRE_NS}" --type=merge \
      -p '{"spec":{"config":{"env":[{"name":"CREATE_ONLY_MODE","value":"true"}]}}}'
    _out "  CREATE_ONLY_MODE enabled — waiting for operator restart"
    sleep 15
  else
    _out "  CREATE_ONLY_MODE already enabled"
  fi
else
  _out "  WARNING: No ZTWIM subscription found in ${SPIRE_NS}"
fi

# --- Ensure SPIRE OIDC set_key_use is enabled --------------------------------

_out "Enabling set_key_use on SPIRE OIDC discovery provider"
OIDC_CONF=$(oc get configmap spire-spiffe-oidc-discovery-provider -n "${SPIRE_NS}" -o jsonpath='{.data.oidc-discovery-provider\.conf}' 2>/dev/null)
if [ -n "$OIDC_CONF" ]; then
  HAS_KEY_USE=$(echo "$OIDC_CONF" | jq '.set_key_use // false')
  if [ "$HAS_KEY_USE" != "true" ]; then
    PATCHED=$(echo "$OIDC_CONF" | jq '. + {"set_key_use": true}')
    oc patch configmap spire-spiffe-oidc-discovery-provider -n "${SPIRE_NS}" \
      --type=merge -p "{\"data\":{\"oidc-discovery-provider.conf\":$(echo "$PATCHED" | jq -Rs .)}}"
    OIDC_POD=$(oc get pods -n "${SPIRE_NS}" -o name | grep oidc | head -1 | sed 's|pod/||')
    oc delete pod "$OIDC_POD" -n "${SPIRE_NS}" 2>/dev/null || true
    _out "  set_key_use enabled, OIDC pod restarting"
    sleep 15
  else
    _out "  set_key_use already enabled"
  fi
fi

# --- Verify SPIRE OIDC endpoint is accessible from cluster -------------------

_out "Verifying SPIRE OIDC discovery provider..."
# Use a pod to test the in-cluster endpoint
VERIFY_POD=$(kubectl get pod -n "${NAMESPACE:-redbank-demo}" -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null)
if [ -n "$VERIFY_POD" ]; then
  VERIFY_NS="${NAMESPACE:-redbank-demo}"
  VERIFY_CONTAINER=$(kubectl get pod "$VERIFY_POD" -n "$VERIFY_NS" -o jsonpath='{.spec.containers[0].name}')
  KEYS=$(kubectl exec "$VERIFY_POD" -n "$VERIFY_NS" -c "$VERIFY_CONTAINER" -- \
    curl -s "$BUNDLE_ENDPOINT" 2>/dev/null | jq '.keys | length' 2>/dev/null || echo "0")
  if [ "$KEYS" -gt 0 ] 2>/dev/null; then
    _out "  SPIRE OIDC endpoint accessible ($KEYS keys)"
  else
    _out "  WARNING: Could not verify SPIRE OIDC endpoint (will try IDP creation anyway)"
  fi
else
  _out "  No pod available to verify SPIRE endpoint"
fi

# --- Create/update SPIFFE Identity Provider ----------------------------------

_out ""
_out "Creating SPIFFE Identity Provider..."
TOKEN=$(get_token)
if [ -z "$TOKEN" ]; then
  _out "  WARNING: Could not get admin token — skipping IDP creation"
  _out "  Check KEYCLOAK_URL and admin credentials"
fi

# Check if IDP already exists
EXISTING=$(curl -sk "$KC_URL/admin/realms/$REALM/identity-provider/instances" \
  -H "Authorization: Bearer ${TOKEN:-none}" 2>/dev/null | jq -r ".[] | select(.alias == \"$IDP_ALIAS\") | .alias" 2>/dev/null || true)

IDP_PAYLOAD=$(cat <<EOF
{
  "alias": "$IDP_ALIAS",
  "providerId": "spiffe",
  "enabled": true,
  "hideOnLogin": true,
  "config": {
    "syncMode": "LEGACY",
    "allowCreate": "true",
    "bundleEndpoint": "$BUNDLE_ENDPOINT",
    "issuer": "spiffe://$TRUST_DOMAIN",
    "trustDomain": "spiffe://$TRUST_DOMAIN",
    "showInAccountConsole": "NEVER"
  }
}
EOF
)

TOKEN=$(get_token)
if [ "$EXISTING" = "$IDP_ALIAS" ]; then
  RESP=$(curl -sk -X PUT "$KC_URL/admin/realms/$REALM/identity-provider/instances/$IDP_ALIAS" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$IDP_PAYLOAD" -w "\n%{http_code}")
else
  RESP=$(curl -sk -X POST "$KC_URL/admin/realms/$REALM/identity-provider/instances" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$IDP_PAYLOAD" -w "\n%{http_code}")
fi
HTTP_CODE=$(echo "$RESP" | tail -1 | tr -d '[:space:]')
BODY=$(echo "$RESP" | sed '$d')

case "${HTTP_CODE:-000}" in
  201) _out "  Created SPIFFE Identity Provider '$IDP_ALIAS'" ;;
  204) _out "  Updated SPIFFE Identity Provider '$IDP_ALIAS'" ;;
  409) _out "  SPIFFE Identity Provider '$IDP_ALIAS' already exists" ;;
  *)   _out "  Result: HTTP ${HTTP_CODE:-unknown} — ${BODY:-no response}"
       _out "  NOTE: RHBK 26.4 may not support SPIFFE IDP. Community Keycloak 26.5.2+ is required." ;;
esac

# --- Enable management permissions on the SPIFFE IDP -------------------------
# Required for federated-jwt client authentication to work via this IDP.

_out "Enabling management permissions on SPIFFE IDP"
TOKEN=$(get_token)
if [ -n "$TOKEN" ]; then
  PERMS=$(curl -sk "$KC_URL/admin/realms/$REALM/identity-provider/instances/$IDP_ALIAS/management/permissions" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.enabled // "false"' 2>/dev/null || echo "false")
  if [ "$PERMS" != "true" ]; then
    TOKEN=$(get_token)
    curl -sk -X PUT "$KC_URL/admin/realms/$REALM/identity-provider/instances/$IDP_ALIAS/management/permissions" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"enabled":true}' > /dev/null 2>&1
    _out "  Permissions enabled on '$IDP_ALIAS'"
  else
    _out "  Permissions already enabled"
  fi
fi

# --- Update authbridge-config with SPIFFE_IDP_ALIAS --------------------------

_out ""
_out "Updating authbridge-config with SPIFFE_IDP_ALIAS=$IDP_ALIAS"
NAMESPACE="${NAMESPACE:-redbank-demo}"
oc patch configmap authbridge-config -n "$NAMESPACE" --type=merge \
  -p "{\"data\":{\"SPIFFE_IDP_ALIAS\":\"$IDP_ALIAS\"}}" 2>/dev/null || \
  _out "  WARNING: authbridge-config not found in $NAMESPACE"

# --- Verify ------------------------------------------------------------------

_out ""
TOKEN=$(get_token)
VERIFY=$(curl -sk "$KC_URL/admin/realms/$REALM/identity-provider/instances" \
  -H "Authorization: Bearer $TOKEN" | jq ".[] | select(.alias == \"$IDP_ALIAS\") | {alias, providerId, enabled, trustDomain: .config.trustDomain}" 2>/dev/null)

_out "Verification:"
echo "$VERIFY" | jq '.' 2>/dev/null || _out "  Could not verify IDP"

_out ""
_out "SPIFFE Identity Provider setup complete!"
_out ""
_out "Next steps:"
_out "  1. Run 'make enable-spiffe' to switch agents to SPIFFE identity"
_out "  2. Run 'make configure-token-exchange' to update FGAP policies"
_out "  3. Run 'make test-token-exchange' to verify"
