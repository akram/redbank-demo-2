#!/bin/bash
#
# Install Keycloak on OpenShift.
#
# Usage:
#   bash install-keycloak.sh              # RHBK operator (default)
#   bash install-keycloak.sh community    # Community Keycloak 26.5.2
#
# Both modes create:
#   - keycloak namespace
#   - PostgreSQL database
#   - Keycloak instance with required features
#   - keycloak-initial-admin secret

set -uo pipefail

MODE="${1:-rhbk}"
FORCE="${FORCE:-false}"
KC_NS="keycloak"

function _out() { echo "$(date +'%F %H:%M:%S') $*"; }

# --- Check for existing installation ----------------------------------------

EXISTING=""
if oc get keycloak keycloak -n "$KC_NS" &>/dev/null; then
  # Detect which type is installed
  if oc get subscription -n "$KC_NS" -o name 2>/dev/null | grep -q rhbk; then
    EXISTING="rhbk"
  elif oc get deploy keycloak-operator -n "$KC_NS" &>/dev/null; then
    EXISTING="community"
  else
    EXISTING="unknown"
  fi

  if [ "$FORCE" != "true" ]; then
    _out "ERROR: Keycloak is already installed (type: ${EXISTING})"
    _out "  Run 'make uninstall-keycloak' first, or use FORCE=true to reinstall:"
    _out "  FORCE=true make install-keycloak"
    exit 1
  else
    _out "WARNING: Keycloak already installed (type: ${EXISTING}) — FORCE=true, uninstalling first"
    bash "$(dirname "$0")/uninstall-keycloak.sh"
    sleep 5
  fi
fi

_out "Installing Keycloak (mode: ${MODE})"

# --- Create namespace --------------------------------------------------------

oc new-project "$KC_NS" 2>/dev/null || oc project "$KC_NS" || true

if [ "$MODE" = "community" ]; then
  # ============================================================================
  # Community Keycloak 26.5.2
  # ============================================================================

  KC_VERSION="${KC_VERSION:-26.6.0}"
  _out "Installing community Keycloak ${KC_VERSION}"

  # Install operator CRDs and deployment
  _out "Installing Keycloak operator..."
  oc apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/refs/tags/${KC_VERSION}/kubernetes/keycloaks.k8s.keycloak.org-v1.yml" -n "$KC_NS" 2>/dev/null || true
  oc apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/refs/tags/${KC_VERSION}/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml" -n "$KC_NS" 2>/dev/null || true
  oc apply -f "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/refs/tags/${KC_VERSION}/kubernetes/kubernetes.yml" -n "$KC_NS"

  # Deploy PostgreSQL
  _out "Deploying PostgreSQL..."
  oc create secret generic keycloak-db-secret -n "$KC_NS" \
    --from-literal=username=keycloak --from-literal=password=keycloak123 \
    --dry-run=client -o yaml | oc apply -f -

  cat <<EOF | oc apply -n "$KC_NS" -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres-kc
spec:
  serviceName: postgres-kc
  replicas: 1
  selector:
    matchLabels:
      app: postgres-kc
  template:
    metadata:
      labels:
        app: postgres-kc
    spec:
      containers:
      - name: postgres
        image: mirror.gcr.io/postgres:17
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: keycloak
        - name: POSTGRES_USER
          value: keycloak
        - name: POSTGRES_PASSWORD
          value: keycloak123
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-kc
spec:
  selector:
    app: postgres-kc
  ports:
  - port: 5432
    targetPort: 5432
EOF

  _out "Waiting for PostgreSQL..."
  oc rollout status statefulset/postgres-kc -n "$KC_NS" --timeout=2m 2>/dev/null || true

  # Get cluster hostname for Keycloak
  KC_HOST="${KEYCLOAK_HOST:-keycloak-keycloak.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"

  # Deploy Keycloak CR
  _out "Deploying Keycloak CR..."
  cat <<EOF | oc apply -n "$KC_NS" -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
spec:
  instances: 1
  hostname:
    hostname: ${KC_HOST}
    strict: false
    strictBackchannel: false
  proxy:
    headers: xforwarded
  features:
    enabled:
      - preview
      - token-exchange
      - admin-fine-grained-authz:v1
      - client-auth-federated:v1
      - spiffe:v1
  http:
    httpEnabled: true
  db:
    vendor: postgres
    host: postgres-kc
    port: 5432
    database: keycloak
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
EOF

else
  # ============================================================================
  # RHBK Operator (Red Hat Build of Keycloak)
  # ============================================================================

  _out "Installing RHBK operator via OperatorHub"

  # Create subscription
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${KC_NS}
spec:
  channel: stable-v26.4
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  _out "Waiting for operator to install..."
  for i in $(seq 1 30); do
    CSV=$(oc get csv -n "$KC_NS" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$CSV" = "Succeeded" ]; then break; fi
    sleep 10
  done

  # Get cluster hostname
  KC_HOST="${KEYCLOAK_HOST:-keycloak-keycloak.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)}"

  # Deploy Keycloak CR (RHBK manages its own PostgreSQL)
  _out "Deploying Keycloak CR..."
  cat <<EOF | oc apply -n "$KC_NS" -f -
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
spec:
  instances: 1
  hostname:
    hostname: ${KC_HOST}
    strict: false
    strictBackchannel: false
  features:
    enabled:
      - preview
      - token-exchange
      - admin-fine-grained-authz:v1
      - client-auth-federated:v1
      - spiffe:v1
  unsupported:
    podTemplate:
      spec:
        containers:
          - name: keycloak
            env:
              - name: KC_HOSTNAME_URL
                value: "https://${KC_HOST}"
EOF
fi

# --- Wait for Keycloak to be ready ------------------------------------------

_out "Waiting for Keycloak to be ready..."
oc rollout status statefulset/keycloak -n "$KC_NS" --timeout=5m 2>/dev/null || true

# Verify
KC_READY=$(oc get pod keycloak-0 -n "$KC_NS" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
if [ "$KC_READY" = "true" ]; then
  KC_VERSION=$(oc exec keycloak-0 -n "$KC_NS" -- /opt/keycloak/bin/kc.sh --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
  KC_ROUTE=$(oc get route -n "$KC_NS" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
  _out ""
  _out "Keycloak installed successfully!"
  _out "  Version: ${KC_VERSION}"
  _out "  URL:     https://${KC_ROUTE}"
  _out "  Admin:   kubectl get secret keycloak-initial-admin -n ${KC_NS} -o go-template='{{.data.username | base64decode}} / {{.data.password | base64decode}}'"
else
  _out "WARNING: Keycloak not ready yet. Check: oc get pods -n ${KC_NS}"
fi
