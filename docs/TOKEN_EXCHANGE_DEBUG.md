# Token Exchange Debugging Guide

This document provides debugging techniques and common issues encountered when configuring OAuth 2.0 Token Exchange in the RedBank demo.

## Quick Diagnostic Commands

### 1. Check Keycloak Logs for Token Exchange Errors

```bash
kubectl logs -n keycloak keycloak-0 --tail=50 | grep TOKEN_EXCHANGE
```

Common log patterns:

| Log Message | Meaning | Fix |
|-------------|---------|-----|
| `type="TOKEN_EXCHANGE_ERROR", error="not_allowed", reason="client not allowed to exchange to audience"` | Permission missing on target audience | Configure policy on target client (e.g., "account") |
| `type="TOKEN_EXCHANGE_ERROR", error="invalid_token", reason="subject_token validation failure"` | Source token cannot be validated | Check issuer, JWKS URL, and client configuration |
| `UnsupportedOperationException: Not supported in V2` | Token Exchange V2 bug | Disable V2, enable FGAP v1 |

### 2. Test Token Exchange Directly

```bash
./scripts/test-token-exchange.sh
```

This script:
- Gets a token from the MCP server SPIFFE client (subject_token)
- Attempts to exchange it for an "account" audience token
- Shows detailed error messages from Keycloak

### 3. Check Authbridge Logs

```bash
# Knowledge agent authbridge
kubectl logs -n redbank-demo deploy/redbank-knowledge-agent -c envoy-proxy | grep -E "token exchange|redbank-mcp-server" | tail -20

# Banking agent authbridge
kubectl logs -n redbank-demo deploy/redbank-banking-agent -c envoy-proxy | grep -E "token exchange|redbank-mcp-server" | tail -20
```

Log patterns:

| Log Message | Meaning |
|-------------|---------|
| `msg="outbound passthrough" host=redbank-mcp-server:8000 reason="no matching route"` | Route not configured in authproxy-routes ConfigMap |
| `msg="token exchange failed" host=redbank-mcp-server:8000 error="token exchange failed (HTTP 400): invalid_request: Invalid token"` | Keycloak rejected the subject_token |
| `msg="outbound exchange" host=redbank-mcp-server:8000 audience=account` | Token exchange succeeded (no error) |

### 4. Check MCP Server Logs

```bash
kubectl logs -n redbank-demo deploy/redbank-mcp-server -c mcp-server --tail=50 | grep -E "POST|401|200"
```

Expected after fix:
```
INFO: POST http://redbank-mcp-server:8000/mcp "HTTP/1.1 200 OK"
```

Before fix:
```
INFO: POST http://redbank-mcp-server:8000/mcp "HTTP/1.1 401 Unauthorized"
```

## Debugging Workflow

### Issue: Token Exchange Fails with "UnsupportedOperationException"

**Symptom:**
```
ERROR [org.keycloak.services.error.KeycloakErrorHandler] Uncaught server error: 
java.lang.UnsupportedOperationException: Not supported in V2
at org.keycloak.services.resources.admin.fgap.ClientPermissionsV2.canExchangeTo
```

**Root Cause:** Token Exchange V2 has an incomplete implementation in this RHBK version.

**Fix:**
1. Edit Keycloak CR: `oc edit keycloak keycloak -n keycloak`
2. Add `admin-fine-grained-authz` to `spec.features.enabled`
3. In Keycloak UI, disable "Standard Token Exchange V2" on clients
4. Enable simple "Token Exchange Enabled" checkbox instead

### Issue: "Client not allowed to exchange"

**Symptom:**
```
error="access_denied"
error_description="Client not allowed to exchange"
```

**Root Cause:** Fine-grained permissions not configured.

**Debugging Steps:**

1. **Check which client is trying to exchange:**
   ```bash
   kubectl logs -n keycloak keycloak-0 --tail=20 | grep TOKEN_EXCHANGE_ERROR
   ```
   Look for `clientId` in the log line.

2. **Verify the client has Authorization enabled:**
   - Keycloak UI → Clients → [requesting client] → Settings
   - Check **Authorization Enabled** is ON

3. **Check if policies exist:**
   - Authorization tab → Policies
   - Should have a Client policy listing allowed clients

4. **Check if permission has the policy attached:**
   - Permissions tab → token-exchange
   - **Policies** field should not be empty

5. **Check target client (account) configuration:**
   - Clients → account → Authorization → Permissions → token-exchange
   - Should have a policy allowing the requesting SPIFFE clients

### Issue: "Subject token validation failure"

**Symptom:**
```
error="invalid_token"
reason="subject_token validation failure"
```

**Root Cause:** Keycloak cannot validate the incoming token's signature or claims.

**Debugging Steps:**

1. **Decode the subject token to check claims:**
   ```bash
   # Get token from authbridge logs or intercept
   echo "TOKEN_HERE" | cut -d'.' -f2 | base64 -d | jq '.'
   ```
   
   Check:
   - `iss` (issuer) - should match Keycloak's expected issuer
   - `aud` (audience) - should be a valid audience
   - `azp` (authorized party / client ID) - the client that issued the token

2. **Verify issuer configuration:**
   ```bash
   kubectl get configmap -n redbank-demo authbridge-config-redbank-orchestrator -o yaml | grep issuer
   ```
   
   Should be the **external HTTPS URL** not the internal service URL:
   - ✅ `https://keycloak-keycloak.apps.rosa.akram.dxp0.p3.openshiftapps.com/realms/redbank`
   - ❌ `http://keycloak-service.keycloak.svc:8080/realms/redbank`

3. **Check JWKS URL is accessible:**
   ```bash
   curl -s http://keycloak-service.keycloak.svc:8080/realms/redbank/protocol/openid-connect/certs | jq '.keys[0].kid'
   ```

### Issue: Route Not Matching (Passthrough Instead of Exchange)

**Symptom:**
```
msg="outbound passthrough" host=redbank-mcp-server:8000 reason="no matching route"
```

**Root Cause:** authproxy-routes ConfigMap not configured or route pattern doesn't match.

**Debugging:**

1. **Check if routes ConfigMap exists:**
   ```bash
   kubectl get configmap authproxy-routes -n redbank-demo -o yaml
   ```

2. **Verify route pattern:**
   - Host patterns **must NOT include port** (authbridge strips it before matching)
   - ✅ `host: "redbank-mcp-server"`
   - ❌ `host: "redbank-mcp-server:8000"`

3. **Verify ConfigMap is mounted:**
   ```bash
   kubectl exec -n redbank-demo deploy/redbank-knowledge-agent -c envoy-proxy -- cat /etc/authproxy/routes.yaml
   ```

4. **Check authbridge config references the routes file:**
   ```bash
   kubectl get configmap authbridge-runtime-config -n redbank-demo -o yaml | grep -A1 routes
   ```
   
   Should have:
   ```yaml
   routes:
     file: "/etc/authproxy/routes.yaml"
   ```

## Manual Token Exchange Test (Advanced)

If the automated test script fails, test manually with curl:

```bash
# 1. Port-forward Keycloak
kubectl port-forward -n keycloak svc/keycloak-service 8080:8080 &

# 2. Get subject token (from any valid client)
SUBJECT_TOKEN=$(curl -s -X POST "http://localhost:8080/realms/redbank/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" | jq -r '.access_token')

# 3. Get requesting client credentials
REQUESTING_CLIENT_ID="spiffe://apps.rosa.akram.dxp0.p3.openshiftapps.com/ns/redbank-demo/sa/redbank-knowledge-agent"
REQUESTING_CLIENT_SECRET=$(kubectl get secret -n redbank-demo kagenti-keycloak-client-credentials-db59e7e064540d40 -o jsonpath='{.data.client-secret\.txt}' | base64 -d)

# 4. Attempt token exchange
curl -v -X POST "http://localhost:8080/realms/redbank/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=$REQUESTING_CLIENT_ID" \
  -d "client_secret=$REQUESTING_CLIENT_SECRET" \
  -d "subject_token=$SUBJECT_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=account" | jq '.'
```

Success response:
```json
{
  "access_token": "eyJhbGc...",
  "expires_in": 300,
  "token_type": "Bearer",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token"
}
```

Error response:
```json
{
  "error": "access_denied",
  "error_description": "Client not allowed to exchange"
}
```

## Verification Checklist

After configuration, verify:

- [ ] Keycloak CR has `admin-fine-grained-authz` in features
- [ ] Keycloak pod restarted after feature change
- [ ] Source client (redbank-mcp) has "Token Exchange Enabled"
- [ ] Requesting client (knowledge-agent) has "Authorization Enabled"
- [ ] Requesting client has token-exchange permission with policy
- [ ] Target client (account) has "Authorization Enabled"
- [ ] Target client has token-exchange permission with policy allowing requesting clients
- [ ] Test script succeeds: `./scripts/test-token-exchange.sh`
- [ ] authproxy-routes ConfigMap exists with correct route
- [ ] authbridge-runtime-config references routes file
- [ ] Agents can successfully call MCP server (200 OK in logs)

## Performance Considerations

Token exchange adds latency to each outbound request:
- **First request:** ~200-500ms (token exchange + JWKS fetch)
- **Cached requests:** ~5-10ms (cache lookup only)

Cache settings in authbridge:
- Default TTL: Based on token `expires_in` (typically 300s = 5 minutes)
- Cache key: SHA-256 of (subject_token + target_audience)

## Security Notes

1. **Token Exchange preserves user context:** The exchanged token maintains the original user's identity in claims
2. **Least privilege:** Only grant token-exchange permissions to clients that need them
3. **Audience scoping:** Each service should validate its expected audience to prevent confused deputy attacks
4. **No privilege escalation:** Token exchange cannot grant more permissions than the subject token had

## References

- [TOKEN_EXCHANGE_SETUP.md](./TOKEN_EXCHANGE_SETUP.md) - Configuration guide
- [AuthBridge documentation](https://github.com/kagenti/kagenti-extensions/blob/main/authbridge/CLAUDE.md)
- [RFC 8693 - OAuth 2.0 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693.html)
