# Kagenti Configuration Changes - RedBank Demo Fix

## Summary

To fix the MCP server database connection issue in the RedBank demo, the following configuration change was made to the Kagenti operator:

**Disabled sidecar injection for tools** by setting `injectTools: false` in the Kagenti feature gates ConfigMap.

## Change Made

### File: `charts/kagenti/values.yaml` or Kagenti ConfigMap

Changed the `injectTools` feature gate from `true` to `false`:

```yaml
# Before
feature-gates.yaml:
  injectTools: true

# After
feature-gates.yaml:
  injectTools: false
```

### Command Applied

```bash
kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | \
  sed 's/injectTools: true/injectTools: false/g' | \
  kubectl apply -f -

kubectl rollout restart deployment/kagenti-controller-manager -n kagenti-system
```

## Why This Change Was Needed

### Problem

The MCP server (a Tool workload) could not connect to PostgreSQL. Connection attempts failed with:

```
connection failed: connection to server at "172.30.106.36", port 5432 failed: 
received invalid response to SSL negotiation: H
```

### Root Cause

1. Kagenti operator was injecting Envoy sidecar containers into Tool workloads (when `injectTools: true`)
2. The `proxy-init` init container used iptables to redirect all outbound traffic through Envoy
3. Envoy intercepted PostgreSQL connections on port 5432
4. Envoy returned HTTP responses (starting with "H") instead of PostgreSQL protocol
5. PostgreSQL driver failed with "invalid response to SSL negotiation"

### Solution

Disabling `injectTools` prevents the operator from injecting Envoy sidecars into Tool workloads, allowing the MCP server to connect directly to PostgreSQL.

## Impact

### Affected Workloads

Only workloads with label `kagenti.io/type: tool` are affected.

In the RedBank demo:
- `redbank-mcp-server` - MCP server (Tool) ✅ Sidecars removed
- `redbank-knowledge-agent` - Agent ❌ Not affected (still has sidecars)
- `redbank-banking-agent` - Agent ❌ Not affected (still has sidecars)
- `redbank-orchestrator` - Agent ❌ Not affected (still has sidecars)

### Pod Changes

Before:
```bash
$ kubectl get pod redbank-mcp-server-xxx -o jsonpath='{.spec.containers[*].name}'
mcp-server envoy-proxy spiffe-helper
```

After:
```bash
$ kubectl get pod redbank-mcp-server-xxx -o jsonpath='{.spec.containers[*].name}'
mcp-server
```

### Trade-offs

**Benefits:**
- ✅ Tools can now connect to databases (PostgreSQL, MySQL, etc.) without issues
- ✅ Simpler pod configuration for tools
- ✅ Lower resource usage for tool pods

**Drawbacks:**
- ❌ Tools no longer have automatic mTLS for outbound connections
- ❌ Tools no longer have SPIFFE identity injection
- ❌ Tools must handle authentication themselves (not via authbridge)

## Alternative Solutions

If sidecar injection must remain enabled for tools, these alternatives can be used:

### Option 1: Exclude Database Ports

Add database ports to `OUTBOUND_PORTS_EXCLUDE` in the `proxy-init` container:

```bash
kubectl patch deployment redbank-mcp-server -n redbank-demo --type=json -p='[{
  "op": "add",
  "path": "/spec/template/spec/initContainers/0/env/-",
  "value": {
    "name": "OUTBOUND_PORTS_EXCLUDE",
    "value": "8080,5432"
  }
}]'
```

### Option 2: Authbridge Bypass Configuration

Add outbound port bypass to the authbridge config:

```yaml
bypass:
  outbound_ports:
  - 5432
```

However, this requires the Kagenti operator to support the annotation:
```yaml
metadata:
  annotations:
    kagenti.io/authbridge-bypass-outbound-ports: "5432"
```

## Verification

After the change:

1. **Check feature gate:**
   ```bash
   kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | grep injectTools
   ```
   
   Expected: `injectTools: false`

2. **Restart MCP server:**
   ```bash
   kubectl delete pod -n redbank-demo -l app=redbank-mcp-server
   ```

3. **Verify no sidecars:**
   ```bash
   kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
     -o jsonpath='{.items[0].spec.containers[*].name}'
   ```
   
   Expected: `mcp-server`

4. **Check database connection:**
   ```bash
   kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep PGVector
   ```
   
   Expected:
   ```
   PGVector knowledge base initialized (model=nomic-ai/nomic-embed-text-v1.5)
   ```

## Recommendations

### For Production

Consider these approaches for production deployments:

1. **Service Mesh Native Database Clients**: Use database clients that understand Envoy's protocol (e.g., pgbouncer as an HTTP proxy)

2. **Per-Workload Configuration**: Allow workloads to specify which ports should bypass Envoy via annotations

3. **Separate Tool Types**: Distinguish between tools that need sidecars (HTTP APIs) and tools that don't (database clients)

4. **Database Sidecar Pattern**: Use a database proxy sidecar that converts HTTP to PostgreSQL protocol

### For Development

The current solution (`injectTools: false`) is acceptable for development and demo environments where:
- Tools are internal services (not exposed externally)
- mTLS is not required for tool-to-database connections
- SPIFFE identity is not needed for tools

## Related Documentation

See RedBank demo repository:
- `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` - Full troubleshooting guide
- `docs/TOKEN_EXCHANGE_DEBUG.md` - Token exchange debugging
- `scripts/test-playground-e2e.sh` - End-to-end test script

## Rollback

To revert this change:

```bash
kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | \
  sed 's/injectTools: false/injectTools: true/g' | \
  kubectl apply -f -

kubectl rollout restart deployment/kagenti-controller-manager -n kagenti-system
kubectl delete pod -n redbank-demo -l kagenti.io/type=tool
```

Note: This will bring back the database connection issue.
