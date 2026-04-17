#!/bin/bash
#
# Tear down RedBank demo workloads. Keeps the namespace and build configs.

set -euo pipefail

NAMESPACE="${NAMESPACE:-redbank-demo}"

function _out() {
  echo "$(date +'%F %H:%M:%S') $@"
}

_out "Cleaning up RedBank workloads in namespace: ${NAMESPACE}"
oc project "${NAMESPACE}"

_out "Deleting AgentRuntime CRs"
oc delete agentruntime redbank-banking-agent-runtime --ignore-not-found
oc delete agentruntime redbank-mcp-server-runtime --ignore-not-found

_out "Deleting Banking Agent deployment and service"
oc delete deployment redbank-banking-agent --ignore-not-found
oc delete service redbank-banking-agent --ignore-not-found

_out "Deleting MCP server deployment and service"
oc delete deployment redbank-mcp-server --ignore-not-found
oc delete service redbank-mcp-server --ignore-not-found

_out "Deleting PostgreSQL deployment and service"
oc delete deployment postgresql --ignore-not-found
oc delete service postgresql --ignore-not-found

_out "Deleting PersistentVolumeClaim"
oc delete pvc postgres-pvc --ignore-not-found

_out "Deleting secrets and configmaps"
oc delete secret postgresql-credentials --ignore-not-found
oc delete configmap postgres-init --ignore-not-found

_out "Cleanup complete — namespace '${NAMESPACE}' and build configs retained"
