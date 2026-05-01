# RedBank Demo Deployment Issues and Solutions

This document summarizes critical issues encountered during the RedBank demo deployment and their solutions.

## Issue Summary

The RedBank demo encountered three major blocking issues:

1. **Playground OAuth Login Failure** - Users could not authenticate
2. **Token Exchange Configuration** - OAuth 2.0 Token Exchange failed between agents
3. **MCP Server Database Connection (CRITICAL BLOCKER)** - Envoy proxy blocked PostgreSQL access

All issues have been resolved. This document provides detailed troubleshooting steps and permanent fixes.

### Critical Blocker: Envoy Cannot Proxy Database Protocols

⚠️ **IMPORTANT**: Issue #3 represents a **fundamental architectural incompatibility** between Layer 7 proxies (Envoy) and Layer 4 database protocols (PostgreSQL, MySQL, etc.).

**The Problem:**
- Envoy is an HTTP/gRPC proxy that does not understand database wire protocols
- The `proxy-init` sidecar transparently intercepts ALL TCP traffic using iptables
- When Envoy receives PostgreSQL protocol bytes, it responds with HTTP error messages
- Database clients fail with "invalid response to SSL negotiation: H" errors

**Why This Matters:**
- **MCP servers** and other tools that require database access cannot use Envoy sidecars without additional configuration
- This affects any Kagenti workload that needs to connect to:
  - PostgreSQL, MySQL, MongoDB (database servers)
  - Redis, Memcached (cache servers)
  - Custom TCP services using non-HTTP protocols

**Solutions Available:**
Multiple architectural approaches are documented in section 3, ranging from simple (disable sidecars for tools) to complex (HTTP-to-PostgreSQL proxy sidecars). The chosen solution depends on production requirements for mTLS, observability, and architecture constraints.

See **Section 3: Solution Approaches** for detailed comparison of 7 different solutions.

---

## 1. Playground OAuth Login Failure

### Symptom

After successful Keycloak authentication, users saw: "Invalid client or Invalid client credentials"

Keycloak logs showed:
```
type="CODE_TO_TOKEN_ERROR", clientId="redbank-mcp", error="invalid_client_credentials"
```

### Root Cause

The playground's `_auth_token` function in `server.py` was not sending the `client_secret` when exchanging the OAuth authorization code for an access token. Red Hat Build of Keycloak requires `client_secret` for confidential clients using the Authorization Code flow.

### Solution

Modified `playground/server.py` to:

1. Read `KEYCLOAK_CLIENT_SECRET` from environment:
   ```python
   kc_secret = getenv("KEYCLOAK_CLIENT_SECRET", "")
   ```

2. Include `client_secret` in token exchange request:
   ```python
   # Add client_secret if configured (required for confidential clients)
   if kc_secret:
       form_data["client_secret"] = kc_secret
   ```

3. Updated playground deployment to include the secret:
   ```bash
   kubectl create secret generic playground-keycloak-secret \
     --from-literal=client-secret=<SECRET> \
     -n redbank-demo
   ```

### Files Modified

- `playground/server.py` - Lines 125, 145-147
- Playground Helm chart values (added `KEYCLOAK_CLIENT_SECRET` env var)

---

## 2. OAuth 2.0 Token Exchange Configuration

### Symptom

Agents could not call the MCP server. Logs showed:
```
TOKEN_EXCHANGE_ERROR: Client not allowed to exchange
UnsupportedOperationException: Not supported in V2
```

### Root Causes

1. **Token Exchange V2 Bug**: RHBK's Token Exchange V2 implementation has an incomplete method (`canExchangeTo()`)
2. **Missing FGAP v1**: Fine-Grained Authorization Permissions v1 not enabled
3. **Incorrect Token Issuer**: Keycloak issuing tokens with internal URL instead of public HTTPS URL
4. **Misconfigured Permissions**: Token exchange permissions not properly configured for SPIFFE clients
5. **Wrong SPIFFE JWT Audience**: JWT-SVIDs had `audience: realms/kagenti` instead of `audience: realms/redbank`

### Solutions

#### 2.1 Enable FGAP v1 in Keycloak

Edit Keycloak CR to enable Fine-Grained Authorization Permissions v1:

```bash
oc edit keycloak keycloak -n keycloak
```

Add to `spec.features.enabled`:
```yaml
spec:
  features:
    enabled:
      - token-exchange
      - admin-fine-grained-authz  # FGAP v1 (required for token exchange)
```

**File**: `docs/keycloak-cr-fgap-v1.yaml`

#### 2.2 Configure Keycloak Hostname

Set the public hostname so tokens have the correct issuer:

```bash
kubectl patch keycloak keycloak -n keycloak --type=merge -p '{
  "spec": {
    "hostname": {
      "hostname": "keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com",
      "strict": false,
      "strictBackchannel": false
    },
    "unsupported": {
      "podTemplate": {
        "spec": {
          "containers": [{
            "name": "keycloak",
            "env": [{
              "name": "KC_HOSTNAME_URL",
              "value": "https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com"
            }]
          }]
        }
      }
    }
  }
}'
```

This ensures tokens have `iss: https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com/realms/redbank` instead of `http://localhost:8080/realms/redbank`.

#### 2.3 Fix SPIFFE JWT Audience

Update the SPIFFE helper config to use the correct realm:

```bash
kubectl get configmap spiffe-helper-config -n redbank-demo -o yaml | \
  sed 's|realms/kagenti|realms/redbank|g' | \
  kubectl apply -f -
```

Then restart agents to pick up new JWT-SVIDs:
```bash
kubectl rollout restart deployment/redbank-knowledge-agent \
  deployment/redbank-banking-agent -n redbank-demo
```

#### 2.4 Configure Token Exchange Permissions

In Keycloak Admin UI:

1. **On requesting client** (e.g., `redbank-knowledge-agent`):
   - Settings → **Authorization Enabled**: ON
   - Authorization → Policies → Create **Client Policy**
   - Add MCP server SPIFFE client
   - Authorization → Permissions → **token-exchange** → Attach policy

2. **On target client** (`account`):
   - Settings → **Authorization Enabled**: ON
   - Authorization → Policies → Create **Client Policy**
   - Add all agent SPIFFE clients that need MCP access
   - Authorization → Permissions → **token-exchange** → Attach policy

#### 2.5 Configure AuthBridge Routes

Create token exchange route for knowledge agents:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authproxy-routes
  namespace: redbank-demo
data:
  routes.yaml: |
    - host: "redbank-mcp-server"
      target_audience: "redbank-mcp"
      token_scopes: "openid"
```

**Note**: Do NOT include port in `host` field. AuthBridge strips ports before pattern matching.

### Verification

Test token exchange with:
```bash
./scripts/test-token-exchange.sh
```

Expected output:
```
✅ ✅ ✅ TOKEN EXCHANGE SUCCEEDED! ✅ ✅ ✅
```

### Files Created/Modified

- `docs/TOKEN_EXCHANGE_SETUP.md` - Step-by-step configuration guide
- `docs/TOKEN_EXCHANGE_DEBUG.md` - Debugging and troubleshooting guide
- `docs/keycloak-cr-fgap-v1.yaml` - Keycloak CR configuration snippet
- `scripts/test-token-exchange.sh` - Automated token exchange test script

---

## 3. MCP Server Database Connection Blocked by Envoy

### Symptom

MCP server could not connect to PostgreSQL. Logs showed:
```
connection failed: connection to server at "172.30.106.36", port 5432 failed: 
received invalid response to SSL negotiation: H
```

Knowledge agent queries failed with:
```
Database error: couldn't get a connection after 30.00 sec
```

### Root Cause

**Envoy sidecar was intercepting PostgreSQL connections and returning HTTP responses.**

The Kagenti operator injects Envoy sidecars into all workloads by default, including tools. Envoy's `proxy-init` container uses iptables to redirect all outbound traffic through the Envoy proxy at port 15123.

When the MCP server tried to connect to PostgreSQL on port 5432:
1. iptables redirected the connection to Envoy (port 15123)
2. Envoy received PostgreSQL protocol bytes
3. Envoy returned HTTP error response (starting with "H")
4. PostgreSQL driver received "H" instead of PostgreSQL protocol
5. Connection failed with "received invalid response to SSL negotiation: H"

### Why This Happened

The `OUTBOUND_PORTS_EXCLUDE` environment variable in the `proxy-init` container controls which ports bypass Envoy. By default, only port 8080 was excluded. Port 5432 (PostgreSQL) was being intercepted.

### Solution

**Disable sidecar injection for tools** in Kagenti feature gates:

```bash
kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | \
  sed 's/injectTools: true/injectTools: false/g' | \
  kubectl apply -f -
```

Then restart the Kagenti controller and MCP server:

```bash
kubectl rollout restart deployment/kagenti-controller-manager -n kagenti-system
kubectl delete pod -n redbank-demo -l app=redbank-mcp-server
```

### Verification

After the fix:

1. **Check pod containers** (should only have `mcp-server`):
   ```bash
   kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
     -o jsonpath='{.items[0].spec.containers[*].name}'
   ```
   
   Expected: `mcp-server`  
   Before fix: `mcp-server envoy-proxy spiffe-helper`

2. **Check MCP server logs**:
   ```bash
   kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep PGVector
   ```
   
   Expected:
   ```
   PGVector knowledge base initialized (model=nomic-ai/nomic-embed-text-v1.5)
   ```

3. **Run E2E test**:
   ```bash
   ./scripts/test-playground-e2e.sh
   ```
   
   Expected:
   ```
   ✅ ✅ ✅ E2E TEST PASSED! ✅ ✅ ✅
   ```

### Why This Is a Critical Blocker

**MCP servers that require database access cannot use authbridge/Envoy sidecars** because:

1. **Protocol Mismatch**: Envoy is an HTTP/gRPC proxy. It does not understand database protocols (PostgreSQL wire protocol, MySQL protocol, etc.)

2. **Transparent Interception**: The `proxy-init` container uses iptables rules to transparently redirect ALL outbound TCP connections to Envoy

3. **No Protocol Detection**: Envoy cannot detect that a connection is PostgreSQL vs HTTP. When it receives PostgreSQL protocol bytes, it responds with HTTP error messages

4. **Connection Failure**: The database client receives "H" (start of "HTTP/1.1 400 Bad Request") instead of PostgreSQL's expected response, causing "invalid response to SSL negotiation" errors

This is a **fundamental architectural incompatibility** between:
- **Layer 7 proxies** (Envoy) designed for HTTP/gRPC
- **Layer 4 protocols** (PostgreSQL, MySQL, Redis, etc.)

### Solution Approaches

Multiple solutions exist depending on production requirements:

#### Solution 1: Disable Sidecar Injection for Tools ✅ (Chosen)

**What:** Set `injectTools: false` in Kagenti feature gates

**Pros:**
- ✅ Simple, works immediately
- ✅ No performance overhead from sidecars
- ✅ Lower resource usage
- ✅ No configuration complexity

**Cons:**
- ❌ Tools lose automatic mTLS for outbound connections
- ❌ Tools lose SPIFFE identity injection
- ❌ Tools must handle authentication themselves
- ❌ No centralized observability/tracing for tool traffic

**When to use:**
- Tools are internal services only
- Tools don't need mTLS to other services
- Development/demo environments
- Cost-sensitive deployments

**Implementation:**
```bash
kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | \
  sed 's/injectTools: true/injectTools: false/g' | \
  kubectl apply -f -

kubectl rollout restart deployment/kagenti-controller-manager -n kagenti-system
kubectl delete pod -n redbank-demo -l app=redbank-mcp-server
```

---

#### Solution 2: Bypass Database Ports in Envoy

**What:** Configure `proxy-init` to exclude database ports from Envoy interception

**Pros:**
- ✅ Keep sidecars for HTTP/gRPC traffic
- ✅ Database traffic bypasses Envoy
- ✅ Can still use mTLS for non-database outbound calls
- ✅ Minimal configuration change

**Cons:**
- ❌ Requires operator support for port exclusion annotations
- ❌ Database connections bypass observability/tracing
- ❌ Need to know all database ports in advance
- ❌ Configuration is pod-specific, not database-specific

**When to use:**
- Production environments needing mTLS for HTTP traffic
- When you know all database ports upfront
- Tools that make both database and HTTP calls

**Implementation (requires operator support):**

Option A: Via deployment annotation (if supported by operator):
```yaml
metadata:
  annotations:
    kagenti.io/authbridge-bypass-outbound-ports: "5432,3306,6379"  # PostgreSQL, MySQL, Redis
```

Option B: Manually patch init container (fragile, overwritten by operator):
```bash
kubectl patch deployment redbank-mcp-server -n redbank-demo --type=json -p='[{
  "op": "add",
  "path": "/spec/template/spec/initContainers/0/env/-",
  "value": {
    "name": "OUTBOUND_PORTS_EXCLUDE",
    "value": "8080,5432,3306,6379"
  }
}]'
```

---

#### Solution 3: Collocate Database with MCP Server

**What:** Run PostgreSQL as a sidecar in the same pod as the MCP server

**Pros:**
- ✅ Database connections stay local (localhost)
- ✅ Envoy doesn't intercept localhost traffic
- ✅ Fast database access (no network hop)
- ✅ Can keep authbridge sidecars
- ✅ Simplified networking (no service mesh for DB)

**Cons:**
- ❌ Stateful pod (requires persistent volumes)
- ❌ Scaling is complex (each pod has its own DB)
- ❌ Data consistency issues if multiple pods
- ❌ Backup/restore is per-pod
- ❌ Higher resource usage per pod
- ❌ Not suitable for shared databases

**When to use:**
- Tool needs a **local cache database**
- SQLite-style use case (single process DB)
- Ephemeral data only
- Tool never scales beyond 1 replica

**Implementation:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redbank-mcp-server
spec:
  replicas: 1  # Must be 1 if using local DB
  template:
    spec:
      containers:
      - name: mcp-server
        env:
        - name: POSTGRES_HOST
          value: "localhost"  # Connect to sidecar
        - name: POSTGRES_PORT
          value: "5432"
      
      - name: postgresql
        image: postgres:16-alpine
        env:
        - name: POSTGRES_DB
          value: "mcp_db"
        - name: POSTGRES_USER
          value: "mcp_user"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mcp-db-secret
              key: password
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
      
      volumes:
      - name: pgdata
        persistentVolumeClaim:
          claimName: mcp-server-db-pvc
```

---

#### Solution 4: Database Proxy Sidecar (HTTP-to-PostgreSQL)

**What:** Add a sidecar that translates HTTP requests to PostgreSQL protocol

**Pros:**
- ✅ Envoy handles HTTP traffic
- ✅ Proxy handles PostgreSQL translation
- ✅ Can keep all authbridge features
- ✅ Centralized database connection management

**Cons:**
- ❌ Complex architecture (extra translation layer)
- ❌ Performance overhead (HTTP → PostgreSQL translation)
- ❌ Need to develop/maintain custom proxy
- ❌ Another component to secure and monitor
- ❌ Limited database feature support in proxy

**When to use:**
- Need strict service mesh enforcement
- Can tolerate performance overhead
- Have resources to build/maintain proxy
- Limited database feature requirements

**Example architecture:**
```
MCP Server → HTTP → Envoy → pgproxy service → PostgreSQL
                      ↓
                  mTLS/SPIFFE
```

**Implementation:** Requires custom development (e.g., using PostgREST or similar)

---

#### Solution 5: External Database with Bypass Annotation

**What:** Keep database external, configure Envoy to bypass specific IPs/CIDRs

**Pros:**
- ✅ Centralized database (standard architecture)
- ✅ Database can be managed separately
- ✅ Proper scaling, backup, HA
- ✅ Can keep sidecars for other traffic

**Cons:**
- ❌ Requires operator support for IP/CIDR bypass
- ❌ Complex configuration for dynamic IPs
- ❌ Database traffic bypasses service mesh
- ❌ Need to maintain IP allow-lists

**When to use:**
- Production with managed databases
- Database has stable IP/CIDR
- Operator supports IP bypass configuration

**Implementation (if operator supports):**
```yaml
metadata:
  annotations:
    kagenti.io/authbridge-bypass-destination-ips: "172.30.106.36/32"
```

---

#### Solution 6: Use HTTP-Native Database (Database Change)

**What:** Replace PostgreSQL with an HTTP-native database that Envoy can proxy

**Pros:**
- ✅ Works seamlessly with Envoy
- ✅ Keep all service mesh features
- ✅ No proxy bypass needed
- ✅ REST API is standard and portable

**Cons:**
- ❌ **Major architecture change** (different database)
- ❌ May lack PostgreSQL features (transactions, triggers, etc.)
- ❌ Migration effort for existing data
- ❌ Different query language/API
- ❌ May impact performance for complex queries

**Options:**
- **CouchDB** - HTTP/REST API, JSON documents
- **Elasticsearch** - HTTP/REST API, full-text search
- **FaunaDB** - HTTP GraphQL API, distributed
- **PostgREST** - HTTP wrapper around PostgreSQL

**When to use:**
- Greenfield project (no existing data)
- Simple data model (key-value or documents)
- HTTP API is acceptable
- Can tolerate database change

**Example:**
```python
# Instead of psycopg2
import requests

response = requests.post(
    "http://postgrest-service:3000/rpc/search_knowledge",
    json={"query": "password reset"},
    headers={"Authorization": f"Bearer {token}"}
)
```

---

#### Solution 7: Dual-Network Architecture

**What:** Run MCP server on a separate network namespace without Envoy, database on same network

**Pros:**
- ✅ Complete network isolation for databases
- ✅ No Envoy interference
- ✅ Can still use Envoy for HTTP services on main network
- ✅ Security boundary between HTTP and DB traffic

**Cons:**
- ❌ **Very complex** networking setup
- ❌ Requires CNI plugin support (Multus, etc.)
- ❌ Hard to troubleshoot
- ❌ Platform-specific configuration
- ❌ Difficult to get right in production

**When to use:**
- Extremely high security requirements
- Platform supports multi-network pods
- Have experienced network engineers
- Need strict network segmentation

**Not recommended** for most use cases due to complexity.

---

### Comparison Matrix

| Solution | Complexity | Production Ready | Keeps mTLS | Keeps SPIFFE | DB Change | Performance |
|----------|------------|------------------|------------|--------------|-----------|-------------|
| 1. Disable sidecars | ⭐ Low | ✅ Yes | ❌ No | ❌ No | ❌ No | ⭐⭐⭐ Excellent |
| 2. Bypass ports | ⭐⭐ Medium | ✅ Yes (if operator supports) | ✅ Partial | ✅ Yes | ❌ No | ⭐⭐⭐ Excellent |
| 3. Collocate DB | ⭐⭐ Medium | ⚠️ Limited (1 replica only) | ✅ Yes | ✅ Yes | ❌ No | ⭐⭐⭐ Excellent |
| 4. DB proxy sidecar | ⭐⭐⭐ High | ⚠️ Requires custom code | ✅ Yes | ✅ Yes | ❌ No | ⭐⭐ Good |
| 5. IP bypass | ⭐⭐ Medium | ✅ Yes (if operator supports) | ✅ Partial | ✅ Yes | ❌ No | ⭐⭐⭐ Excellent |
| 6. HTTP database | ⭐⭐⭐ High | ✅ Yes | ✅ Yes | ✅ Yes | ✅ **Yes** | ⭐⭐ Good |
| 7. Dual network | ⭐⭐⭐⭐ Very High | ⚠️ Complex | ✅ Partial | ✅ Partial | ❌ No | ⭐⭐⭐ Excellent |

---

### Recommended Approach by Environment

#### Development / Demo
→ **Solution 1: Disable sidecar injection** (`injectTools: false`)
- Simplest, fastest to implement
- No production requirements

#### Production (Internal Services)
→ **Solution 2: Bypass database ports** with operator annotation support
- Keeps mTLS for HTTP traffic
- Clean separation of HTTP and DB traffic
- Requires operator enhancement

#### Production (High Security)
→ **Solution 2 + 5: Bypass ports + IP restrictions**
- Port bypass for PostgreSQL protocol
- IP allowlist for database servers
- Full mTLS for application traffic

#### Production (New Projects)
→ **Solution 6: HTTP-native database** (if architecture allows)
- Future-proof with service mesh
- No special configuration needed
- Consider CouchDB, PostgREST, or similar

---

### Implementation Notes

**For Kagenti Operator Developers:**

To properly support database access, the operator should:

1. **Support port bypass annotations**:
   ```yaml
   kagenti.io/authbridge-bypass-outbound-ports: "5432,3306,6379"
   ```

2. **Support destination IP/CIDR bypass**:
   ```yaml
   kagenti.io/authbridge-bypass-destination-cidrs: "172.30.0.0/16,10.0.0.0/8"
   ```

3. **Provide per-workload configuration** instead of global `injectTools` flag

4. **Document protocol limitations** clearly (HTTP/gRPC only)

5. **Auto-detect database connections** and warn users if Envoy will intercept them

**For MCP Server Developers:**

When designing tools that need databases:

1. **Document database requirements** clearly
2. **Provide configuration** for both sidecar and non-sidecar modes
3. **Use localhost** when collocating databases
4. **Consider HTTP APIs** instead of native database drivers where possible
5. **Test with and without sidecars** in CI/CD

### Files Modified

- Kagenti `feature-gates.yaml` - Set `injectTools: false`
- None in redbank-demo-2 repo (configuration change only)

---

## Additional Fixes

### Database SSL Mode

PostgreSQL in the demo cluster doesn't support SSL. Fixed by setting:

```bash
kubectl set env deployment/redbank-mcp-server -n redbank-demo \
  POSTGRES_SSLMODE=disable \
  PGVECTOR_SSLMODE=disable
```

### LLM Endpoint Configuration

Knowledge agent had placeholder LLM endpoint. Fixed by copying from orchestrator:

```bash
kubectl set env deployment/redbank-knowledge-agent -n redbank-demo \
  LLM_BASE_URL=https://litellm-litemaas.apps.prod.rhoai.rh-aiservices-bu.com/v1 \
  LLM_MODEL=Qwen3.6-35B-A3B
```

### PGVector Database Connection

MCP server needed explicit host/port configuration:

```bash
kubectl set env deployment/redbank-mcp-server -n redbank-demo \
  PGVECTOR_HOST=postgresql \
  PGVECTOR_PORT=5432
```

---

## Testing

### End-to-End Test Script

Created `scripts/test-playground-e2e.sh` to validate the full flow:

1. ✅ OAuth authentication with Keycloak
2. ✅ Token exchange (knowledge-agent → MCP)
3. ✅ MCP server database access
4. ✅ LLM query with RAG
5. ✅ Successful response to user

Run with:
```bash
./scripts/test-playground-e2e.sh
```

### Manual Testing

1. **Login**: https://redbank-playground-redbank-demo.apps.rosa.akram.dxp0.p3.openshiftapps.com
2. **Credentials**: jane / jane123
3. **Test query**: "How to reset my password?"
4. **Expected**: Coherent answer from knowledge base

---

## Lessons Learned

### 1. OAuth Confidential Clients

**Always send client_secret** when exchanging authorization codes for confidential clients. Even if the Keycloak UI shows "Client authentication: ON", the code must explicitly include the secret in the token request.

### 2. Token Exchange V2 in RHBK

**Do not enable "Standard Token Exchange V2"** in Red Hat Build of Keycloak. Use FGAP v1 instead by enabling the `admin-fine-grained-authz` feature flag.

### 3. Keycloak Token Issuer

**Set the public hostname** on Keycloak CR using `spec.hostname.hostname` and the `KC_HOSTNAME_URL` environment variable. Otherwise, tokens will have internal URLs like `http://localhost:8080/realms/redbank` which fail validation.

### 4. Envoy Sidecar Proxy

**Envoy intercepts ALL outbound TCP connections** unless explicitly excluded via:
- `OUTBOUND_PORTS_EXCLUDE` in proxy-init
- `bypass.outbound_ports` in authbridge config
- Disabling sidecar injection entirely

For database connections (PostgreSQL, MySQL, etc.), either:
- Exclude the database port from Envoy interception
- Disable sidecar injection for the workload
- Use a database proxy that speaks HTTP (not recommended)

### 5. SPIFFE JWT Audience

**JWT-SVID audience MUST match the Keycloak realm issuer**. If your realm is `redbank`, the JWT audience must be `https://<keycloak-host>/realms/redbank`, not `realms/kagenti` or any other value.

### 6. AuthBridge Route Patterns

**Do NOT include ports in authbridge route host patterns**. AuthBridge strips the port before matching. Use:
```yaml
host: "redbank-mcp-server"  # ✅ Correct
```

Not:
```yaml
host: "redbank-mcp-server:8000"  # ❌ Won't match
```

---

## Quick Troubleshooting Guide

### How to Identify the Envoy-Database Issue

**Symptoms:**
```bash
# 1. Check application logs for database connection errors
kubectl logs -n <namespace> <pod-name> | grep -E "connection failed|invalid response"

# Common error patterns:
# ❌ "received invalid response to SSL negotiation: H"
# ❌ "server closed the connection unexpectedly"
# ❌ "connection refused"
# ❌ "couldn't get a connection after 30.00 sec"
```

**Diagnostic Steps:**

```bash
# Step 1: Check if pod has Envoy sidecar
kubectl get pod -n redbank-demo <pod-name> -o jsonpath='{.spec.containers[*].name}'
# If you see: mcp-server envoy-proxy spiffe-helper
# → Envoy sidecar is present

# Step 2: Check if application connects to database
kubectl logs -n redbank-demo <pod-name> -c <app-container> | grep -i postgres
# Look for connection attempts to port 5432

# Step 3: Check Envoy proxy-init configuration
kubectl get pod -n redbank-demo <pod-name> -o yaml | grep -A5 "proxy-init"
# Look for OUTBOUND_PORTS_EXCLUDE env var
# Default: "8080" (PostgreSQL port 5432 NOT excluded)

# Step 4: Test direct database connection (bypass Envoy)
kubectl exec -n redbank-demo <pod-name> -c <app-container> -- \
  nc -zv <database-host> 5432
# If this succeeds but app still fails → Envoy is intercepting

# Step 5: Check iptables rules (shows what Envoy intercepts)
kubectl exec -n redbank-demo <pod-name> -c <app-container> -- \
  iptables -t nat -L OUTPUT -n -v
# Look for rules redirecting to port 15123 (Envoy)
```

**Confirmation:**

If you see ALL of these:
1. ✅ Pod has `envoy-proxy` container
2. ✅ App tries to connect to database on port 5432
3. ✅ Logs show "received invalid response to SSL negotiation: H"
4. ✅ Port 5432 is NOT in `OUTBOUND_PORTS_EXCLUDE`

Then **Envoy is definitely blocking the database connection**.

### Quick Fix Decision Tree

```
Is this a development/demo environment?
├─ YES → Use Solution 1: Disable sidecar injection for tools
│         (Set injectTools: false in Kagenti feature gates)
│
└─ NO (Production)
   │
   ├─ Do you need mTLS for HTTP traffic?
   │  ├─ NO → Use Solution 1: Disable sidecars
   │  └─ YES
   │     │
   │     ├─ Can you modify Kagenti operator?
   │     │  ├─ YES → Use Solution 2: Add port bypass annotation support
   │     │  └─ NO
   │     │     │
   │     │     ├─ Is database used only by this one tool?
   │     │     │  ├─ YES → Consider Solution 3: Collocate database
   │     │     │  └─ NO
   │     │     │     │
   │     │     │     ├─ Can you change database technology?
   │     │     │     │  ├─ YES → Use Solution 6: HTTP-native database
   │     │     │     │  └─ NO → Use Solution 4: DB proxy sidecar
   │     │     │     │           (Most complex, requires development)
```

### Validation After Fix

```bash
# 1. Verify sidecar status
kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# Expected after Solution 1: mcp-server
# Expected after Solution 2/3/4: mcp-server envoy-proxy spiffe-helper

# 2. Check database connection in logs
kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep -E "PGVector|initialized|Starting"

# Expected success:
# ✅ "PGVector knowledge base initialized"
# ✅ "Starting RedBank PostgreSQL MCP server"

# Expected failure:
# ❌ "connection failed: received invalid response to SSL negotiation: H"
# ❌ "couldn't get a connection after 30.00 sec"

# 3. Test end-to-end flow
./scripts/test-playground-e2e.sh

# Expected: ✅ ✅ ✅ E2E TEST PASSED! ✅ ✅ ✅
```

### Common Mistakes

1. **Modifying ConfigMap directly** → Kagenti operator overwrites it
   - ❌ `kubectl edit configmap authbridge-config-*`
   - ✅ Add annotation to deployment or disable injection

2. **Only excluding port 8080** → Database ports still intercepted
   - ❌ `OUTBOUND_PORTS_EXCLUDE=8080`
   - ✅ `OUTBOUND_PORTS_EXCLUDE=8080,5432,3306,6379`

3. **Using localhost for external DB** → Won't work
   - ❌ `POSTGRES_HOST=localhost` (unless collocated)
   - ✅ `POSTGRES_HOST=postgresql.namespace.svc`

4. **Forgetting to restart pods** → Old config still active
   - ❌ Changing ConfigMap without pod restart
   - ✅ `kubectl delete pod -n redbank-demo <pod-name>`

5. **Mixing HTTP and TCP in same bypass** → Different configs needed
   - ❌ Expecting Envoy to handle both PostgreSQL and HTTP
   - ✅ Bypass database, proxy HTTP

---

## Files Created

- `docs/TOKEN_EXCHANGE_SETUP.md` - Configuration guide
- `docs/TOKEN_EXCHANGE_DEBUG.md` - Debugging guide
- `docs/keycloak-cr-fgap-v1.yaml` - Keycloak configuration
- `scripts/test-token-exchange.sh` - Token exchange test
- `scripts/test-playground-e2e.sh` - End-to-end test
- `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` - This file

## Files Modified

- `playground/server.py` - Added client_secret handling for OAuth
- `playground/deployment` - Added KEYCLOAK_CLIENT_SECRET environment variable

## Configuration Changes (Not in Git)

- Keycloak CR: Enabled FGAP v1, set hostname
- Keycloak realm: Configured token-exchange permissions
- ConfigMap `spiffe-helper-config`: Fixed JWT audience
- ConfigMap `authproxy-routes`: Added MCP server route
- Kagenti feature gates: Set `injectTools: false`
- Deployments: Added env vars for database SSL, LLM endpoint, PGVector connection

---

## Quick Reference

### Check Token Exchange
```bash
./scripts/test-token-exchange.sh
```

### Check E2E Flow
```bash
./scripts/test-playground-e2e.sh
```

### Check MCP Database Connection
```bash
kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep PGVector
```

### Check Token Issuer
```bash
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 &
curl -s http://localhost:8080/realms/redbank/.well-known/openid-configuration | jq .issuer
```

Expected: `https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com/realms/redbank`

### Check Envoy Sidecar Injection
```bash
kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'
```

Expected (after fix): `mcp-server`

---

## Support

For issues:
- Token Exchange: See `docs/TOKEN_EXCHANGE_DEBUG.md`
- Playground Login: Check Keycloak logs for `CODE_TO_TOKEN_ERROR`
- Database Connection: Check for "received invalid response to SSL negotiation: H"
- Envoy Issues: Check if port is in `OUTBOUND_PORTS_EXCLUDE`

All test scripts are in `scripts/`:
- `test-token-exchange.sh` - Validate OAuth token exchange
- `test-playground-e2e.sh` - Validate end-to-end flow
