# Token Exchange Configuration Guide

This document explains how to configure OAuth 2.0 Token Exchange (RFC 8693) in Red Hat Build of Keycloak (RHBK) for the RedBank demo agents.

## Problem Overview

The RedBank demo uses token exchange to allow agents to call other services with properly scoped tokens:

- **Playground** → issues token with `audience=redbank-mcp`, `clientId=redbank-mcp`
- **Orchestrator** → validates token and passes it to downstream agents
- **Knowledge Agent** → needs to exchange the playground token for a token with `audience=account` to call the MCP server
- **MCP Server** → expects JWT with `JWT_AUDIENCE=account`

## Critical Bug: Token Exchange V2

**DO NOT enable "Standard Token Exchange V2"** in RHBK. This version has an unimplemented method:

```
ERROR: java.lang.UnsupportedOperationException: Not supported in V2
at org.keycloak.services.resources.admin.fgap.ClientPermissionsV2.canExchangeTo
```

## Solution: Enable FGAP v1

### Step 1: Enable FGAP v1 in Keycloak CR

Edit the Keycloak custom resource:

```bash
oc edit keycloak keycloak -n keycloak
```

Add to the `spec.features` section:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  features:
    enabled:
      - token-exchange
      - admin-fine-grained-authz:v1  # FGAP v1
```

Wait for Keycloak to restart and apply the feature.

### Step 2: Configure Token Exchange on Source Client (redbank-mcp)

In Keycloak Admin UI:

1. Go to: **Realm: redbank** → **Clients** → **redbank-mcp**
2. **Settings** tab:
  - Ensure **Client authentication**: ON
  - Ensure **Service accounts roles**: ON
3. **Advanced** tab → **Fine Grained OpenID Connect Configuration**:
  - Enable **Token Exchange Enabled** (v1 - simple checkbox)
  - Save

### Step 3: Configure Token Exchange on Requesting Client (knowledge-agent)

1. Go to: **Clients** → **spiffe://apps.rosa.akram.dxp0.p3.openshiftapps.com/ns/redbank-demo/sa/redbank-knowledge-agent**
2. **Settings** tab:
  - Enable **Authorization Enabled**: ON
  - Save (this enables the Authorization tab)
3. Go to **Authorization** tab → **Policies** → **Create policy** → **Client**:
  - Name: `clients-allowed-to-knowledge-agent-exchange`
  - Description: "Clients allowed to exchange tokens with knowledge-agent"
  - **Clients**: Add the MCP server SPIFFE client:
    - `spiffe://apps.rosa.akram.dxp0.p3.openshiftapps.com/ns/redbank-demo/sa/redbank-mcp-server`
  - Logic: **Positive**
  - Save
4. Go to **Permissions** tab → Click **token-exchange**:
  - **Policies**: Select `clients-allowed-to-knowledge-agent-exchange`
  - Decision strategy: **Unanimous**
  - Save

### Step 4: Configure Token Exchange on Target Client (account)

1. Go to: **Clients** → **account**
2. **Settings** tab:
  - Enable **Authorization Enabled**: ON
  - Save
3. Go to **Authorization** tab → **Policies** → **Create policy** → **Client**:
  - Name: `clients-allowed-to-exchange-to-account`
  - Description: "Clients allowed to exchange tokens to account audience"
  - **Clients**: Add all agent SPIFFE clients that need to call the MCP server:
    - `spiffe://apps.rosa.akram.dxp0.p3.openshiftapps.com/ns/redbank-demo/sa/redbank-knowledge-agent`
    - `spiffe://apps.rosa.akram.dxp0.p3.openshiftapps.com/ns/redbank-demo/sa/redbank-banking-agent`
  - Logic: **Positive**
  - Save
4. Go to **Permissions** tab → Click **token-exchange**:
  - **Policies**: Select `clients-allowed-to-exchange-to-account`
  - Decision strategy: **Unanimous**
  - Save

## Testing Token Exchange

Use the test script to verify token exchange works:

```bash
./scripts/test-token-exchange.sh
```

Expected output:

```
✅ ✅ ✅ TOKEN EXCHANGE SUCCEEDED! ✅ ✅ ✅
```

If you see errors:

- `UnsupportedOperationException: Not supported in V2` → Disable V2, enable FGAP v1
- `access_denied: Client not allowed to exchange` → Check policies are configured and saved
- `client not allowed to exchange to audience` → Check target client (account) has proper permissions

## End-to-End Verification

After configuration, test in the playground:

1. Make a request that requires the knowledge agent (e.g., "What are the top 10 customers?")
2. Check logs:

```bash
# Should show successful token exchange
kubectl logs -n redbank-demo deploy/redbank-knowledge-agent -c envoy-proxy | grep 'redbank-mcp-server' | tail -5

# Should show 200 OK instead of 401
kubectl logs -n redbank-demo deploy/redbank-mcp-server -c mcp-server --tail=20 | grep -E 'POST|401|200'
```

## Architecture

```
┌─────────────┐ token (aud=redbank-mcp)  ┌──────────────────┐
│ Playground  │─────────────────────────>│ Orchestrator     │
└─────────────┘                          └──────────────────┘
                                                   │
                  token (aud=redbank-mcp)          │
                  (passthrough - no exchange)      │
                                                   ▼
                                         ┌──────────────────┐
                                         │ Knowledge Agent  │
                                         └──────────────────┘
                                                   │
                  TOKEN EXCHANGE                   │
                  aud=redbank-mcp → aud=account    │
                  (authbridge outbound)            │
                                                   ▼
                                         ┌──────────────────┐
                                         │ MCP Server       │
                                         │ (expects account)│
                                         └──────────────────┘
```

## Common Errors and Solutions


| Error                                                | Cause                                  | Solution                                              |
| ---------------------------------------------------- | -------------------------------------- | ----------------------------------------------------- |
| `UnsupportedOperationException: Not supported in V2` | Token Exchange V2 enabled              | Disable V2, enable FGAP v1                            |
| `access_denied: Client not allowed to exchange`      | Missing or empty policy on permission  | Create client policy and attach to permission         |
| `client not allowed to exchange to audience`         | Target client (account) not configured | Configure token-exchange permission on account client |
| `invalid_token: subject_token validation failure`    | Source token signature/issuer mismatch | Check JWKS URL and issuer configuration               |
| `unauthorized_client: Invalid client credentials`    | Wrong client secret                    | Verify credentials from Kubernetes secret             |


## References

- [RFC 8693 - OAuth 2.0 Token Exchange](https://www.rfc-editor.org/rfc/rfc8693.html)
- [Keycloak Token Exchange Documentation](https://www.keycloak.org/docs/latest/securing_apps/#_token-exchange)
- [RHBK Fine-Grained Authorization](https://access.redhat.com/documentation/en-us/red_hat_build_of_keycloak)

