# RedBank Demo — Keycloak SSO & AuthBridge Integration
**Work Log - April 25, 2026**

---

## Summary

Fixed three blocking issues preventing the RedBank demo playground from functioning end-to-end. All issues resolved and validated with passing E2E tests.

---

## Issues Resolved

### 1. Playground OAuth Login Failure ✅

**Symptom:** "Invalid client or Invalid client credentials" after Keycloak authentication

**Root Cause:** Playground's `_auth_token()` function was not sending `client_secret` when exchanging OAuth authorization code for access token. RHBK requires `client_secret` for confidential clients.

**Fix:**
- Modified `playground/server.py` to read `KEYCLOAK_CLIENT_SECRET` from environment
- Added `client_secret` to token exchange request (lines 125, 145-147)
- Updated `scripts/setup-keycloak.sh` to enable standard flow

**Files Changed:**
- `playground/server.py`
- `scripts/setup-keycloak.sh`

---

### 2. OAuth 2.0 Token Exchange Configuration ✅

**Symptom:** 
- `TOKEN_EXCHANGE_ERROR: Client not allowed to exchange`
- `UnsupportedOperationException: Not supported in V2`

**Root Causes:**
1. Token Exchange V2 bug in RHBK
2. FGAP v1 not enabled
3. Token issuer using internal URL instead of public HTTPS
4. Missing token-exchange permissions
5. Wrong SPIFFE JWT audience (kagenti instead of redbank)

**Fixes Applied:**
1. Enabled FGAP v1 in Keycloak CR (`admin-fine-grained-authz` feature)
2. Configured public hostname and `KC_HOSTNAME_URL` environment variable
3. Fixed SPIFFE JWT audience from `realms/kagenti` to `realms/redbank`
4. Configured token-exchange permissions in Keycloak UI (knowledge-agent → account client policy)
5. Updated authbridge routes ConfigMap with `target_audience: redbank-mcp`

**Documentation Created:**
- `docs/TOKEN_EXCHANGE_SETUP.md` (7.0 KB) - Step-by-step configuration guide
- `docs/TOKEN_EXCHANGE_DEBUG.md` (9.6 KB) - Debugging and troubleshooting
- `docs/keycloak-cr-fgap-v1.yaml` - Keycloak CR snippet
- `scripts/test-token-exchange.sh` - Automated test script

---

### 3. MCP Server Database Connection (CRITICAL BLOCKER) ✅

**Symptom:**
```
connection failed: received invalid response to SSL negotiation: H
Database error: couldn't get a connection after 30.00 sec
```

**Root Cause: Fundamental Architectural Incompatibility**

Envoy sidecar was intercepting PostgreSQL connections:
1. `proxy-init` uses iptables to redirect ALL TCP to Envoy (port 15123)
2. Envoy receives PostgreSQL wire protocol bytes
3. Envoy returns HTTP error response (starts with "H")
4. PostgreSQL driver fails: "invalid response to SSL negotiation: H"

**Why Critical:** Envoy is a Layer 7 proxy (HTTP/gRPC) and does NOT understand Layer 4 database protocols (PostgreSQL, MySQL, MongoDB, Redis). This affects ANY tool/service connecting to databases.

#### Solution Implemented: Port Bypass Annotation (Solution #2) ✅

Added `kagenti.io/outbound-ports-exclude: "5432"` annotation to MCP server deployment.

**Benefits:**
- ✅ Keeps AuthBridge sidecars (Envoy, SPIFFE, client-registration) for security
- ✅ Bypasses PostgreSQL port 5432 from Envoy interception via iptables exclusion
- ✅ Allows MCP server to connect directly to PostgreSQL
- ✅ Maintains mTLS and token exchange for all HTTP traffic

**Configuration:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redbank-mcp-server
spec:
  template:
    metadata:
      annotations:
        kagenti.io/outbound-ports-exclude: "5432"
```

**Verification:**
- Pod containers: `mcp-server`, `envoy-proxy`, `spiffe-helper`
- Proxy-init environment: `OUTBOUND_PORTS_EXCLUDE="8080,5432"`
- Database connection: `PGVector knowledge base initialized`
- MCP requests: `POST /mcp HTTP/1.1 200 OK`

#### Alternative Solutions Documented

7 architectural approaches documented in `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md`:

1. **Disable sidecar injection** - Development/testing only
2. **Port bypass annotation** - ✅ **RECOMMENDED for production**
3. **Collocate PostgreSQL as sidecar** - Run PostgreSQL in same pod
4. **HTTP-to-PostgreSQL proxy sidecar** - Translation layer
5. **IP/CIDR bypass** - For external databases
6. **HTTP-native database alternatives** - CouchDB, PostgREST
7. **Dual-network architecture** - Complex, separate network namespace

**Files Created/Modified:**
- Modified: `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` (expanded to 30+ KB with 7 solutions, comparison matrix, troubleshooting guide)
- Created: `scripts/test-playground-e2e.sh` - End-to-end test script

---

## Additional Configuration Changes

### Database Configuration
```bash
kubectl set env deployment/redbank-mcp-server -n redbank-demo \
  POSTGRES_SSLMODE=disable \
  PGVECTOR_SSLMODE=disable \
  PGVECTOR_HOST=postgresql \
  PGVECTOR_PORT=5432
```

### LLM Endpoint Configuration
```bash
kubectl set env deployment/redbank-knowledge-agent -n redbank-demo \
  LLM_BASE_URL=https://litellm-litemaas.apps.prod.rhoai.rh-aiservices-bu.com/v1 \
  LLM_MODEL=Qwen3.6-35B-A3B
```

### Kagenti Operator
- Re-enabled `injectTools: true` in feature gates after validating port bypass solution
- Restarted controller to apply changes

---

## Testing & Validation

### Automated Test Scripts

1. **Token Exchange Test**
   ```bash
   ./scripts/test-token-exchange.sh
   ```
   Validates OAuth token exchange between agents
   - ✅ Expected output: `TOKEN EXCHANGE SUCCEEDED!`

2. **End-to-End Test**
   ```bash
   ./scripts/test-playground-e2e.sh
   ```
   Validates complete flow:
   - OAuth authentication with Keycloak
   - Playground → Orchestrator → Knowledge Agent
   - Token exchange (knowledge-agent → MCP)
   - MCP server database access
   - RAG query with PGVector
   - LLM response generation
   - ✅ Expected output: `E2E TEST PASSED!`

### Manual Testing

**Playground URL:**
```
https://redbank-playground-redbank-demo.apps.rosa.akram.dxp0.p3.openshiftapps.com
```

**Test Credentials:**
- Username: `jane`
- Password: `jane123`

**Test Queries:**
- "How do I reset my password?"
- "What are the top 10 customers?"
- "Tell me about RedBank services"

**Result:** ✅ All tests passing with coherent RAG-based answers

---

## Git Commits

**Repository:** `redbank-demo-2`

| Commit | Description |
|--------|-------------|
| `eeb3137` | Added TOKEN_EXCHANGE_SETUP.md and TOKEN_EXCHANGE_DEBUG.md |
| `65be907` | Added keycloak-cr-fgap-v1.yaml |
| `bea056b` | fix: OAuth login and token exchange for RedBank demo |
| `393aa8a` | docs: Expand Envoy-database blocker documentation with 7 solutions |

---

## Key Learnings

### 1. OAuth Confidential Clients
Always send `client_secret` when exchanging authorization codes. Even if "Client authentication: ON" is set in Keycloak UI, the code must explicitly include it.

### 2. Token Exchange V2 in RHBK
**Never enable "Standard Token Exchange V2"** - it has incomplete implementation. Use FGAP v1 instead.

### 3. Keycloak Public Hostname
Set `KC_HOSTNAME_URL` to the public HTTPS URL. Otherwise tokens have internal URLs that fail validation.

### 4. Envoy Layer 7 Limitation
**Envoy cannot proxy database protocols.** It's designed for HTTP/gRPC (Layer 7), not PostgreSQL/MySQL (Layer 4). This is a fundamental architectural constraint, not a configuration issue.

### 5. SPIFFE JWT Audience
JWT-SVID audience MUST match the Keycloak realm. Verify it's `realms/redbank` not `realms/kagenti` or other values.

### 6. Port 8080 Mandatory Exclusion
Port 8080 (Keycloak) is always excluded from Envoy interception to prevent circular dependency. Envoy needs to call Keycloak for token exchange, so it cannot intercept its own Keycloak requests.

### 7. Configuration Persistence
Manual ConfigMap edits get overwritten by Kagenti operator. Use deployment annotations or operator configuration instead.

---

## Production Recommendations

### For Database-Connected Workloads

Use the port bypass annotation pattern for any Kagenti workload requiring database access:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-tool
spec:
  template:
    metadata:
      annotations:
        kagenti.io/outbound-ports-exclude: "5432,6379,3306"  # PostgreSQL, Redis, MySQL
    spec:
      containers:
      - name: my-tool
        # ...
```

This maintains full AuthBridge security (mTLS, SPIFFE identity, token exchange) while enabling direct database connectivity.

### For Security Hardening

1. **Create dedicated playground client** instead of reusing redbank-mcp
2. **Implement PKCE** for playground OAuth flow
3. **Add token refresh** before expiry
4. **Implement proper SSO logout** flow
5. **Use short-lived tokens** (5 min instead of 300 sec)

---

## Documentation Created

### In redbank-demo-2 Repository

1. **docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md** (30 KB)
   - Comprehensive troubleshooting guide for all three issues
   - 7 detailed solution approaches for Envoy-database issue
   - Comparison matrix for solutions
   - Environment-specific recommendations
   - Quick troubleshooting guide with diagnostic commands
   - Decision tree for choosing solutions
   - Validation steps and common mistakes

2. **docs/TOKEN_EXCHANGE_SETUP.md** (7.0 KB)
   - Step-by-step configuration guide
   - Keycloak permission setup
   - Client configuration
   - Testing procedures

3. **docs/TOKEN_EXCHANGE_DEBUG.md** (9.6 KB)
   - Diagnostic commands
   - Log patterns and their meanings
   - Debugging workflows
   - Manual token exchange testing

4. **docs/keycloak-cr-fgap-v1.yaml** (833 B)
   - Keycloak CR configuration snippet
   - Feature flags for FGAP v1

5. **scripts/test-token-exchange.sh** (4.4 KB)
   - Automated token exchange test
   - Port-forward to Keycloak
   - Exchange token and verify

6. **scripts/test-playground-e2e.sh** (6.2 KB)
   - End-to-end flow validation
   - OAuth login simulation
   - RAG query test
   - Log verification

### External Documentation

7. **/tmp/kagenti-changes-summary.md**
   - Kagenti configuration changes
   - Feature gate modification rationale
   - Impact analysis
   - Rollback procedures

8. **/tmp/redbank-demo-fix-summary.md**
   - Complete summary of all fixes
   - Commit history
   - Testing procedures
   - Links to all documentation

---

## Quick Diagnostic Commands

```bash
# Check Keycloak issuer
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 &
curl -s http://localhost:8080/realms/redbank/.well-known/openid-configuration | jq .issuer

# Check MCP sidecars
kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'

# Check database connection
kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep PGVector

# Check token exchange
kubectl logs -n redbank-demo -l app=redbank-knowledge-agent -c envoy-proxy | \
  grep "outbound token exchanged"

# Run E2E test
./scripts/test-playground-e2e.sh
```

---

## Status

✅ **All issues resolved**  
✅ **E2E test passing**  
✅ **Comprehensive documentation created**  
✅ **Production solution validated (port bypass annotation)**  
✅ **Playground fully functional**

**Total commits:** 4  
**Total files created:** 6  
**Total files modified:** 4  
**Documentation added:** ~30 KB  

**Time to resolution:** Issues identified, fixed, documented, and tested in a single session.

---

## Labels

`authentication` `oauth` `envoy` `database-connectivity` `documentation` `keycloak` `authbridge` `postgres` `mcp` `spiffe`

---

**Prepared by:** Claude (Anthropic AI)  
**Date:** April 25, 2026  
**Repository:** redbank-demo-2  
**Related Jira:** RedBank Demo — Keycloak SSO & AuthBridge Integration
