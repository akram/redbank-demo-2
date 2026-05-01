#!/bin/bash
#
# Uninstall Keycloak from OpenShift.
#
# Removes both RHBK operator and community Keycloak installations.

set -uo pipefail

KC_NS="keycloak"

function _out() { echo "$(date +'%F %H:%M:%S') $*"; }

_out "Uninstalling Keycloak from namespace ${KC_NS}"

# Delete Keycloak CR
_out "Deleting Keycloak CR..."
oc delete keycloak keycloak -n "$KC_NS" --ignore-not-found 2>/dev/null

# Delete PostgreSQL
_out "Deleting PostgreSQL..."
oc delete statefulset postgres-kc -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete svc postgres-kc -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete pvc -l app=postgres-kc -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete pvc data-postgres-kc-0 -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete secret keycloak-db-secret -n "$KC_NS" --ignore-not-found 2>/dev/null

# Delete RHBK operator (if installed via OLM)
_out "Removing RHBK operator subscription..."
oc delete subscription rhbk-operator -n "$KC_NS" --ignore-not-found 2>/dev/null
for CSV in $(oc get csv -n "$KC_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep rhbk); do
  oc delete csv "$CSV" -n "$KC_NS" --ignore-not-found 2>/dev/null
done

# Delete community operator (if installed)
_out "Removing community Keycloak operator..."
oc delete deploy keycloak-operator -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete sa keycloak-operator -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete svc keycloak-operator -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete role keycloak-operator-role -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete rolebinding keycloak-operator-role-binding -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete rolebinding keycloakrealmimportcontroller-role-binding -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete rolebinding keycloakcontroller-role-binding -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete rolebinding keycloak-operator-view -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete clusterrole keycloak-operator-clusterrole --ignore-not-found 2>/dev/null
oc delete clusterrole keycloakrealmimportcontroller-cluster-role --ignore-not-found 2>/dev/null
oc delete clusterrole keycloakcontroller-cluster-role --ignore-not-found 2>/dev/null
oc delete clusterrolebinding keycloak-operator-clusterrole-binding --ignore-not-found 2>/dev/null

# Delete remaining operator pods
_out "Cleaning up pods..."
oc delete pods -n "$KC_NS" --all --ignore-not-found 2>/dev/null

# Delete secrets
oc delete secret keycloak-initial-admin -n "$KC_NS" --ignore-not-found 2>/dev/null
oc delete secret spire-oidc-ca -n "$KC_NS" --ignore-not-found 2>/dev/null

# Delete routes
for ROUTE in $(oc get route -n "$KC_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  oc delete route "$ROUTE" -n "$KC_NS" --ignore-not-found 2>/dev/null
done

_out ""
_out "Keycloak uninstalled from namespace ${KC_NS}"
_out "Note: CRDs (keycloaks.k8s.keycloak.org) are retained. Delete manually if needed."
