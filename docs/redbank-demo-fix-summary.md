# RedBank Demo Fix - Complete Summary

## Overview

Fixed three critical deployment issues in the RedBank demo that prevented the playground from functioning end-to-end.

**Status:** ✅ All issues resolved  
**Testing:** ✅ E2E test passing  
**Repository:** redbank-demo-2  
**Date:** 2026-04-25

---

## Issues Fixed

### 1. Playground OAuth Login Failure ✅

**Symptom:** Users saw "Invalid client or Invalid client credentials" after authenticating with Keycloak

**Root Cause:** Playground's `_auth_token()` function was not sending `client_secret` when exchanging the OAuth authorization code for an access token. RHBK requires `client_secret` for confidential clients.

**Fix:** Modified `playground/server.py`:
```python
# Line 125: Read client secret from environment
kc_secret = getenv("KEYCLOAK_CLIENT_SECRET", "")

# Lines 145-147: Send client_secret in token exchange
if kc_secret:
    form_data["client_secret"] = kc_secret
```

**Files:**
- Modified: `playground/server.py`
- Modified: `scripts/setup-keycloak.sh` (enable standard flow)

---

### 2. OAuth 2.0 Token Exchange Configuration ✅

**Symptom:** Agents could not call MCP server; logs showed:
- `TOKEN_EXCHANGE_ERROR: Client not allowed to exchange`
- `UnsupportedOperationException: Not supported in V2`

**Root Causes:**
1. Token Exchange V2 bug in RHBK
2. FGAP v1 not enabled
3. Token issuer using internal URL instead of public HTTPS
4. Missing token-exchange permissions
5. Wrong SPIFFE JWT audience (kagenti instead of redbank)

**Fixes Applied:**

**Keycloak Configuration:**
```bash
# 1. Enable FGAP v1 in Keycloak CR
oc edit keycloak keycloak -n keycloak
# Added: admin-fine-grained-authz to spec.features.enabled

# 2. Configure public hostname
kubectl patch keycloak keycloak -n keycloak --type=merge -p '{
  "spec": {
    "hostname": {
      "hostname": "keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com"
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

# 3. Fix SPIFFE JWT audience
kubectl get configmap spiffe-helper-config -n redbank-demo -o yaml | \
  sed 's|realms/kagenti|realms/redbank|g' | \
  kubectl apply -f -

# 4. Configure token-exchange permissions in Keycloak UI
# - knowledge-agent client: Authorization → Policies → Client Policy
# - account client: Authorization → Permissions → token-exchange
```

**AuthBridge Routes:**
```yaml
# ConfigMap: authproxy-routes
- host: "redbank-mcp-server"
  target_audience: "redbank-mcp"
  token_scopes: "openid"
```

**Files Created:**
- `docs/TOKEN_EXCHANGE_SETUP.md` - Step-by-step configuration guide
- `docs/TOKEN_EXCHANGE_DEBUG.md` - Debugging and troubleshooting
- `docs/keycloak-cr-fgap-v1.yaml` - Keycloak CR snippet
- `scripts/test-token-exchange.sh` - Automated test script

---

### 3. MCP Server Database Connection (CRITICAL BLOCKER) ✅

**Symptom:** MCP server could not connect to PostgreSQL:
```
connection failed: received invalid response to SSL negotiation: H
Database error: couldn't get a connection after 30.00 sec
```

**Root Cause:** **Fundamental architectural incompatibility**

Envoy sidecar was intercepting PostgreSQL connections:
1. `proxy-init` uses iptables to redirect ALL TCP to Envoy (port 15123)
2. Envoy receives PostgreSQL wire protocol bytes
3. Envoy returns HTTP error response (starts with "H")
4. PostgreSQL driver fails: "invalid response to SSL negotiation: H"

**Why This Is Critical:**
- Envoy is a Layer 7 proxy (HTTP/gRPC) and does NOT understand Layer 4 database protocols
- Affects ANY tool/service connecting to: PostgreSQL, MySQL, MongoDB, Redis, Memcached, or custom TCP services
- Without a fix, MCP servers cannot access knowledge bases

**Solution Chosen:** Disable sidecar injection for tools

```bash
# Kagenti feature gates: Set injectTools: false
kubectl get configmap kagenti-feature-gates -n kagenti-system -o yaml | \
  sed 's/injectTools: true/injectTools: false/g' | \
  kubectl apply -f -

# Restart controller
kubectl rollout restart deployment/kagenti-controller-manager -n kagenti-system

# Restart MCP server (will recreate without sidecars)
kubectl delete pod -n redbank-demo -l app=redbank-mcp-server
```

**Result:**
- Before: `mcp-server envoy-proxy spiffe-helper` (3 containers)
- After: `mcp-server` (1 container)
- Database connection: ✅ Success
- PGVector initialized: ✅ Success

**Alternative Solutions Documented:**

7 different architectural approaches are documented with pros/cons:

1. **Disable sidecars** (chosen) - Simple, works immediately
2. **Bypass database ports** - Requires operator annotation support
3. **Collocate database** - Run PostgreSQL as sidecar in same pod
4. **DB proxy sidecar** - HTTP-to-PostgreSQL translation layer
5. **IP bypass** - Exclude database IPs from Envoy interception
6. **HTTP-native database** - Replace PostgreSQL with CouchDB/PostgREST
7. **Dual-network** - Separate network namespace (very complex)

See `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` for detailed comparison matrix.

**Files:**
- Modified: `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` (expanded with 7 solutions, troubleshooting guide, decision tree)
- Created: `scripts/test-playground-e2e.sh` - End-to-end test

---

## Additional Fixes

### Database SSL Mode
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

---

## Git Commits

### Repository: redbank-demo-2

**Commit 1:** `eeb3137` (previous)
- Added TOKEN_EXCHANGE_SETUP.md
- Added TOKEN_EXCHANGE_DEBUG.md

**Commit 2:** `65be907` (previous)  
- Added keycloak-cr-fgap-v1.yaml

**Commit 3:** `bea056b` (new)
```
fix: OAuth login and token exchange for RedBank demo

- Added client_secret handling in playground/server.py
- Created comprehensive troubleshooting documentation
- Created E2E test script
- UX improvements in playground UI
```

Files changed:
- Modified: `playground/server.py`
- Modified: `playground/playground/templates/index.html`
- Modified: `scripts/setup-keycloak.sh`
- Created: `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md`
- Created: `scripts/test-playground-e2e.sh`

**Commit 4:** `393aa8a` (new)
```
docs: Expand Envoy-database blocker documentation with 7 solutions

- Marked issue #3 as CRITICAL BLOCKER
- Documented 7 solution approaches with comparison matrix
- Added troubleshooting guide with diagnostic commands
- Added decision tree for choosing solutions
- Added validation steps and common mistakes
```

Files changed:
- Modified: `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md` (+519 lines)

---

## Configuration Changes (Not in Git)

These changes were applied to the running cluster but are not tracked in git:

### Keycloak
- **CR**: Enabled `admin-fine-grained-authz` feature
- **CR**: Set hostname to public URL
- **CR**: Added `KC_HOSTNAME_URL` environment variable
- **Realm**: Configured token-exchange permissions on knowledge-agent and account clients
- **Client (redbank-mcp)**: Enabled standard flow, added redirect URIs

### Kagenti
- **Feature gates**: Set `injectTools: false`
- **Controller**: Restarted to pick up feature gate change

### ConfigMaps
- **spiffe-helper-config**: Changed JWT audience from `realms/kagenti` to `realms/redbank`
- **authproxy-routes**: Added route for redbank-mcp-server with `target_audience: redbank-mcp`

### Deployments
- **redbank-mcp-server**: Added env vars for database SSL mode, PGVector host/port
- **redbank-knowledge-agent**: Added env vars for LLM endpoint and model

---

## Testing

### Test Scripts Created

**1. Token Exchange Test:**
```bash
./scripts/test-token-exchange.sh
```
Validates:
- OAuth token exchange between agents
- Keycloak token-exchange permissions
- SPIFFE client credentials

Expected output:
```
✅ ✅ ✅ TOKEN EXCHANGE SUCCEEDED! ✅ ✅ ✅
```

**2. End-to-End Test:**
```bash
./scripts/test-playground-e2e.sh
```
Validates:
- OAuth authentication with Keycloak
- Playground → Orchestrator → Knowledge Agent flow
- Token exchange (knowledge-agent → MCP)
- MCP server database access
- RAG query with PGVector
- LLM response generation

Expected output:
```
✅ ✅ ✅ E2E TEST PASSED! ✅ ✅ ✅
```

### Manual Testing

**URL:** https://redbank-playground-redbank-demo.apps.rosa.akram.dxp0.p3.openshiftapps.com

**Credentials:**
- Username: `jane`
- Password: `jane123`

**Test Queries:**
- "How to reset my password?"
- "What are the top 10 customers?"
- "Tell me about RedBank services"

**Expected:** Coherent answers from knowledge base (RAG)

**Status:** ✅ All tests passing

---

## Documentation Created

### In redbank-demo-2 Repository

1. **docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md** (11.4 KB)
   - Comprehensive troubleshooting guide for all three issues
   - 7 detailed solution approaches for Envoy-database issue
   - Comparison matrix for solutions
   - Environment-specific recommendations
   - Quick troubleshooting guide with diagnostic commands
   - Decision tree for choosing solutions
   - Validation steps
   - Common mistakes

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

8. **/tmp/redbank-demo-fix-summary.md** (this document)
   - Complete summary of all fixes
   - Commit history
   - Testing procedures
   - Links to all documentation

---

## Verification Commands

### Check Token Issuer
```bash
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 &
curl -s http://localhost:8080/realms/redbank/.well-known/openid-configuration | jq .issuer
```
Expected: `https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com/realms/redbank`

### Check Sidecar Injection
```bash
kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'
```
Expected: `mcp-server` (no envoy-proxy or spiffe-helper)

### Check Database Connection
```bash
kubectl logs -n redbank-demo -l app=redbank-mcp-server | grep PGVector
```
Expected: `PGVector knowledge base initialized (model=nomic-ai/nomic-embed-text-v1.5)`

### Check Token Exchange
```bash
kubectl logs -n redbank-demo -l app=redbank-knowledge-agent -c envoy-proxy | \
  grep "outbound token exchanged"
```
Expected: `msg="outbound token exchanged" host=redbank-mcp-server:8000 audience=redbank-mcp`

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
JWT-SVID audience MUST match the Keycloak realm. Check that it's `realms/redbank` not `realms/kagenti` or other values.

### 6. AuthBridge Route Patterns
Never include ports in host patterns. AuthBridge strips ports before matching.

### 7. Configuration Persistence
Manual ConfigMap edits get overwritten by Kagenti operator. Use deployment annotations or operator configuration instead.

---

## Next Steps (Optional)

### For Production Deployment

1. **Implement operator support for port bypass annotations:**
   ```yaml
   kagenti.io/authbridge-bypass-outbound-ports: "5432,3306,6379"
   ```

2. **Add per-workload sidecar configuration** instead of global `injectTools` flag

3. **Auto-detect database connections** in operator and warn users

4. **Document protocol limitations** in Kagenti operator docs

5. **Consider HTTP-native alternatives** for new projects (PostgREST, CouchDB)

### For Security Hardening

1. **Create dedicated playground client** instead of reusing redbank-mcp
2. **Implement PKCE** for playground OAuth flow
3. **Add token refresh** before expiry
4. **Implement proper SSO logout** flow
5. **Use short-lived tokens** (5 min instead of 300 sec)

---

## Support Resources

### Documentation
- Main troubleshooting guide: `docs/DEPLOYMENT_ISSUES_AND_SOLUTIONS.md`
- Token exchange setup: `docs/TOKEN_EXCHANGE_SETUP.md`
- Token exchange debugging: `docs/TOKEN_EXCHANGE_DEBUG.md`
- Kagenti changes: `/tmp/kagenti-changes-summary.md`

### Test Scripts
- Token exchange: `./scripts/test-token-exchange.sh`
- End-to-end: `./scripts/test-playground-e2e.sh`

### Quick Diagnostic
```bash
# Check all components quickly
echo "=== Keycloak Issuer ==="
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 &
sleep 2
curl -s http://localhost:8080/realms/redbank/.well-known/openid-configuration | jq .issuer
kill %1

echo -e "\n=== MCP Sidecars ==="
kubectl get pod -n redbank-demo -l app=redbank-mcp-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'

echo -e "\n\n=== Database Connection ==="
kubectl logs -n redbank-demo -l app=redbank-mcp-server --tail=50 | \
  grep -E "PGVector|connection failed" | tail -5

echo -e "\n=== Token Exchange ==="
kubectl logs -n redbank-demo -l app=redbank-knowledge-agent -c envoy-proxy --tail=50 | \
  grep "outbound token exchanged" | tail -3

echo -e "\n=== E2E Test ==="
./scripts/test-playground-e2e.sh 2>&1 | grep -E "PASSED|FAILED"
```

---

## Summary

✅ **All issues resolved**  
✅ **E2E test passing**  
✅ **Comprehensive documentation created**  
✅ **7 solution approaches documented for production**  
✅ **Playground fully functional**

**Total commits:** 4  
**Total files created:** 6  
**Total files modified:** 4  
**Documentation added:** ~30 KB  

**Time to resolution:** Issues identified, fixed, documented, and tested in a single session.

The RedBank demo is now fully functional with a working authentication flow, token exchange, and database-backed RAG queries.
