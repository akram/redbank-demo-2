# RedBank Demo — Kagenti Edition

PostgreSQL database, MCP server, and A2A agents for the RedBank multi-agent banking demo, adapted for Kagenti deployment with Row-Level Security (RLS).

Part of RHAISTRAT-1459 / RHAIENG-4555 (Epic) / RHAIENG-4556 (MCP Server) / RHAIENG-4559 (Banking Agent).

## Directory Layout

```
redbank-demo-2/
├── postgres-db/              PostgreSQL schema, seed data, RLS policies
│   ├── init.sql              Schema + RLS + seed data
│   ├── init-db.sh            Startup init script
│   ├── postgres.yaml         Secret + Deployment + Service
│   └── kustomization.yaml
├── langchain-pgvector/        LangChain + PGVector RAG pipeline
│   ├── tests/                 Schema + RLS tests (testcontainers)
│   ├── pipeline/              KFP ingestion pipeline
│   ├── notebook/              Query notebook (admin vs user RLS demo)
│   └── requirements.txt
├── mcp-server/               FastMCP server with auth-aware tools
│   ├── redbank-mcp/
│   │   ├── mcp_server.py     Tool definitions + JWT auth
│   │   ├── database_manager.py  Connection pool + RLS context
│   │   └── logger.py
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── mcp-server.yaml       Deployment + Service
│   ├── agentruntime.yaml     AgentRuntime CR (type: tool)
│   └── deploy.sh             OpenShift build + deploy
├── banking-agent/            A2A Banking Operations Agent (Agent C — admin CRUD)
│   ├── banking_agent/
│   │   ├── __main__.py       A2A server startup, agent card, MLflow init
│   │   ├── agent.py          LangGraph ReAct agent + MCP client setup
│   │   └── agent_executor.py A2A <-> LangGraph bridge with token propagation
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── banking-agent.yaml    Deployment + Service
│   ├── agentruntime.yaml     AgentRuntime CR (type: agent)
│   └── deploy.sh             OpenShift build + deploy
├── scripts/
│   ├── setup-keycloak.sh     Provision Keycloak realm, client, users, audience mapper
│   └── cleanup.sh            Tear down deployed workloads
├── tests/
│   └── test_mcp_rls.py       MCP-level integration tests (pytest)
├── Makefile
└── README.md
```

## How It Works

### Overview

The MCP server is a [FastMCP](https://github.com/jlowin/fastmcp) application that exposes banking data tools over the MCP Streamable HTTP transport. It sits between Kagenti agents and a PostgreSQL database, enforcing access control at two levels:

1. **Application-level gating** — Write tools (`update_account`, `create_transaction`) are decorated with `@admin_only` and reject non-admin callers before any SQL runs.
2. **Database-level Row-Level Security (RLS)** — PostgreSQL policies filter query results based on session variables, so even if application logic has a bug, users can only see their own data.

### Request Flow

```
Agent (A2A/MCP client)
  │
  │  Authorization: Bearer <JWT>
  ▼
┌──────────────────────────────────────────────┐
│  AuthBridge Sidecar (Envoy + go-processor)   │
│                                              │
│  1. Validate JWT (signature, exp, issuer)    │
│  2. Token exchange (RFC 8693) for tool aud   │
│  3. Forward with exchanged Bearer token      │
└──────────────────┬───────────────────────────┘
                   │
                   │  Authorization: Bearer <exchanged-JWT>
                   ▼
┌──────────────────────────────────────────────┐
│  FastMCP HTTP Server (:8000/mcp)             │
│                                              │
│  1. Verify JWT (JWKS) or decode (trusted)    │
│  2. Extract email + role from claims         │
│  3. Check @admin_only (write tools)          │
│  4. Open pooled DB connection                │
│  5. SET app.current_role, app.current_email  │
│  6. Execute query (RLS filters rows)         │
│  7. Return structured result                 │
└──────────────────┬───────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│  PostgreSQL 16                               │
│                                              │
│  RLS policies on: customers, statements,     │
│  transactions                                │
│                                              │
│  Admin: sees all rows, can INSERT/UPDATE     │
│  User:  sees only own customer_id (SELECT)   │
└──────────────────────────────────────────────┘
```

### AuthBridge Integration

In a Kagenti deployment, the AuthBridge sidecar (Envoy + go-processor) handles JWT validation and RFC 8693 token exchange automatically. The flow is:

1. Caller authenticates with Keycloak and receives a JWT
2. Caller sends the request with `Authorization: Bearer <JWT>` to the MCP server
3. The AuthBridge Envoy sidecar intercepts the request, validates the JWT (signature, expiration, issuer) via JWKS, and exchanges the token for an audience-scoped token targeting this tool
4. The exchanged token reaches the MCP server container on the `Authorization` header

The MCP server operates in two modes:

**AuthBridge trusted mode** (`JWT_VERIFY=false`, default) — The sidecar has already validated the token. The server decodes the JWT without signature verification to extract identity claims. This is the standard Kagenti deployment model.

**Standalone mode** (`JWT_VERIFY=true`) — No sidecar present. The server fetches signing keys from `JWKS_URL` (Keycloak JWKS endpoint) and verifies the JWT itself. Use for dev clusters without Kagenti or as defense-in-depth.

Identity is extracted from Keycloak JWT claims:
- **email**: `claims.email` → `claims.preferred_username` → `claims.sub` (fallback chain)
- **role**: `"admin"` if the `ADMIN_ROLE_CLAIM` value (default `"admin"`) appears in `realm_access.roles`, `resource_access.account.roles`, or `scope`

When no Bearer token is present, the server falls back to `DEFAULT_ROLE` and `DEFAULT_EMAIL` environment variables. In production with AuthBridge, unauthenticated requests are rejected by the sidecar before they reach the MCP server.

### Row-Level Security

RLS is enabled and forced (`FORCE ROW LEVEL SECURITY`) on `customers`, `statements`, and `transactions`. The table owner (`$POSTGRESQL_USER`) is the same role the MCP server connects as, so `FORCE` ensures policies apply even to the owner.

> **Note:** The `embeddings` table (used by the RAG pipeline) uses a **different RLS approach** — database roles (`redbank_admin`/`redbank_user`) instead of session variables (`app.current_role`). This is because the pipeline and notebook connect as distinct database roles rather than through the MCP server. No `FORCE ROW LEVEL SECURITY` is needed since these roles are not the table owner.

Before each query, the `@authenticated` decorator opens a connection from the pool and sets two session variables inside a transaction:

```sql
SELECT set_config('app.current_role', 'admin', true);
SELECT set_config('app.current_user_email', 'jane@redbank.demo', true);
```

The `true` parameter scopes these to the current transaction, so they're automatically cleared when the connection returns to the pool.

RLS policies then filter based on these variables:
- **Admin policies** (`FOR ALL`): allow full read/write when `app.current_role = 'admin'`
- **User policies** (`FOR SELECT`): restrict to rows matching the `customer_id` mapped in the `user_accounts` table for the current email

### MCP Tools

**Read tools** (all roles):
| Tool | Description |
|------|-------------|
| `get_customer` | Look up a customer by email or phone |
| `get_customer_transactions` | List transactions with optional date range filter |
| `get_account_summary` | Customer info + statement count + latest balance |

**Write tools** (admin only):
| Tool | Description |
|------|-------------|
| `update_account` | Update customer phone, address, or account type |
| `create_transaction` | Insert a new transaction on the latest statement |

### Security Model

| Role | Read access | Write access |
|------|-------------|--------------|
| `user` | Own customer record, statements, transactions only (RLS) | None (rejected by `@admin_only`) |
| `admin` | All records | `update_account`, `create_transaction` |

### Demo Users

| Keycloak identity | Role | Customer record |
|-------------------|------|-----------------|
| `john@redbank.demo` | user | John Doe (customer_id 5) |
| `jane@redbank.demo` | admin | All customers (no customer_id binding) |

Seed data includes 5 customers (Alice, Bob, Carol, David, John), 13 statements, and 27 transactions.

### Kagenti Integration

Each workload is enrolled into the Kagenti platform via an `AgentRuntime` custom resource (`agent.kagenti.dev/v1alpha1`). The `AgentRuntime` references the Deployment via `targetRef` — the operator then manages `kagenti.io/type` labels, sets a `kagenti.io/config-hash` annotation for rollout coordination, and enables AuthBridge sidecar injection at Pod admission.

| Workload | AgentRuntime | `spec.type` | Protocol label (Service) |
|----------|-------------|-------------|--------------------------|
| `redbank-mcp-server` | `redbank-mcp-server-runtime` | `tool` | `protocol.kagenti.io/mcp: "true"` |
| `redbank-banking-agent` | `redbank-banking-agent-runtime` | `agent` | `protocol.kagenti.io/a2a: ""` |

The `kagenti.io/type` label on Deployments is managed by the operator — do not set it manually. Protocol labels on Services (`protocol.kagenti.io/a2a`, `protocol.kagenti.io/mcp`) remain in the Service manifests since they drive AgentCard sync and tool discovery independently.

Verify enrollment:

```bash
oc get agentruntime
# NAME                              TYPE    TARGET                   PHASE   AGE
# redbank-banking-agent-runtime     agent   redbank-banking-agent    Active  ...
# redbank-mcp-server-runtime        tool    redbank-mcp-server       Active  ...
```

### Banking Operations Agent (Agent C)

The Banking Operations Agent is an A2A service built with LangGraph that provides admin-level CRUD access to the RedBank customer database. It connects to the MCP server via `MultiServerMCPClient` from `langchain-mcp-adapters`.

**Architecture:**
- **Protocol**: A2A (Agent-to-Agent) — exposes `/.well-known/agent-card.json` for Kagenti discovery
- **Agent framework**: LangGraph `create_react_agent` with a system prompt for banking operations
- **MCP client**: `MultiServerMCPClient` connected to the PostgreSQL MCP server over HTTP
- **LLM**: Configurable — vLLM (default) or OpenAI via `ChatOpenAI` with `base_url` override
- **Observability**: MLflow LangChain autolog (`mlflow.langchain.autolog()`)
- **Auth**: Trusts AuthBridge sidecar for Tier 1 admin gating. Propagates the incoming Bearer JWT to the MCP server so RLS policies apply.

**Error handling:**
- MCP tool errors (auth denials, validation failures, DB errors) are intercepted and returned to the LLM as text rather than crashing the agent. The system prompt instructs the LLM to relay permission errors and empty results to the user without hallucinating data.
- LLM rate limit errors (`429 Too Many Requests`) are caught separately and return a user-friendly "service temporarily overloaded" message.
- All other agent execution errors are caught and returned as a generic error message.

**Kagenti enrollment:**
- **AgentRuntime**: `redbank-banking-agent-runtime` (type: `agent`) — operator manages `kagenti.io/type` label and AuthBridge injection
- **Service**: `protocol.kagenti.io/a2a: ""` — enables AgentCard sync and A2A discovery

**Token flow:**
1. Caller sends A2A request with `Authorization: Bearer <JWT>`
2. AuthBridge sidecar validates the token and rejects non-admin users (Tier 1)
3. Agent extracts the Bearer token from the incoming request
4. Agent passes the token as a header to `MultiServerMCPClient`
5. MCP server applies RLS based on the JWT claims (Tier 2)

### Orchestrator Integration (RHAIENG-4560)

Agent C is designed to be called by the Orchestrator Agent (Agent A) via A2A. The orchestrator classifies user intent and routes write operations (update account, create transaction) to this agent while sending read-only queries to the Knowledge Agent (Agent B).

**Integration points:**
- **Discovery**: The orchestrator discovers Agent C via `protocol.kagenti.io/a2a` service labels
- **A2A protocol**: Agent C accepts `message/send` JSON-RPC requests at its service URL
- **Token propagation**: The orchestrator forwards the user's Bearer JWT in the `Authorization` header. Agent C passes it through to the MCP server, preserving the full identity chain.
- **Access gating**: With AuthBridge deployed, non-admin users are rejected at the network level (Tier 1) before reaching Agent C. Without AuthBridge, the MCP server's `@admin_only` decorator enforces this at the tool level (Tier 2).

## RAG Pipeline (LangChain + PGVector)

### Overview

A document ingestion pipeline using LangChain + PGVector for retrieval-augmented generation (RAG) with role-scoped access. Admin documents and user documents are ingested into separate collections in the same `embeddings` table, and PostgreSQL RLS ensures each role sees only its authorized documents.

This reuses the **existing PostgreSQL instance** deployed via `postgres-db/`. The pgvector extension, `embeddings` table, and role-based RLS policies are all defined in `postgres-db/init.sql`.

### Embedding Model

Uses `nomic-ai/nomic-embed-text-v1.5` via **sentence-transformers** (`langchain-huggingface`). Produces 768-dimensional vectors and runs locally — no external embedding API endpoint needed.

### Document Source

6 RedBank PDF documents hosted on GitHub, fetched by the pipeline at runtime:

- **Admin** (`admin/`): `redbank_compliance_procedures.pdf`, `redbank_transaction_operations.pdf`, `redbank_user_management.pdf`
- **User** (`user/`): `redbank_account_selfservice.pdf`, `redbank_password_and_security.pdf`, `redbank_payments_and_transfers.pdf`

### Embeddings Table Schema

Each row represents a single chunk of a source PDF document. PDFs are split into chunks by `RecursiveCharacterTextSplitter`, and each chunk is embedded and stored as one row.

| Column | Type | Description |
|--------|------|-------------|
| `langchain_id` | `UUID` (PK) | Unique identifier for each chunk |
| `collection` | `VARCHAR(64)` | `admin` or `user` — determines RLS visibility |
| `content` | `TEXT` | The text content of the chunk |
| `embedding` | `vector(768)` | 768-dim embedding from nomic-embed-text-v1.5 |
| `langchain_metadata` | `JSONB` | Source metadata (page number, source PDF, creator) |

### RLS for Embeddings

Role-based access control on the `embeddings` table:

| Role | Read | Write | Collections visible |
|------|------|-------|---------------------|
| `redbank_admin` | All rows | INSERT/UPDATE/DELETE | `admin`, `user` |
| `redbank_user` | `user` collection only | None | `user` |

The table owner (`$POSTGRESQL_USER`) bypasses RLS and is used by the ingestion pipeline.

### Pipeline

`langchain-pgvector/pipeline/pgvector_rag_pipeline.py` is a KFP pipeline that:

1. Downloads PDFs from GitHub via `base_url` + `filenames`
2. Loads and chunks documents with `RecursiveCharacterTextSplitter`
3. Embeds with `HuggingFaceEmbeddings` (nomic-embed-text)
4. Stores in PGVector via `PGVectorStore` with collection-scoped access

Admin and user document sets are ingested in parallel as separate pipeline tasks.

Compile the pipeline: `make compile-pipeline`

### Query Notebook

`langchain-pgvector/notebook/pgvector_query_notebook.ipynb` demonstrates:

1. Admin similarity search — results from both `admin` and `user` collections
2. User similarity search — results from `user` collection only
3. Direct SQL verification that RLS blocks user access to admin rows
4. Document count per collection

### PostgreSQL Infrastructure

`postgres-db/init.sql` includes the pgvector extension (`CREATE EXTENSION IF NOT EXISTS vector`), `embeddings` table, and role-based RLS policies alongside the existing MCP schema. `postgres-db/postgres.yaml` uses the `quay.io/mcampbel/pgvector:pg16` image (community PostgreSQL with pgvector pre-installed) and includes:

- A **PersistentVolumeClaim** (`postgres-pvc`, 10Gi) mounted at `/var/lib/postgresql/data` for data persistence
- **`PGDATA`** set to a subdirectory (`/var/lib/postgresql/data/pgdata`) to avoid the `lost+found` conflict on PVC mount points

### Tests

Schema and RLS tests use **testcontainers** with the `pgvector/pgvector:pg16` container image (via Podman):

```bash
make test-pgvector   # requires Podman
```

## Deployment

All operations are driven through the Makefile. The default namespace is `redbank-demo` — override with `NAMESPACE=my-namespace`.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `deploy-all` | Deploy everything (Postgres + MCP server + Banking Agent) |
| `deploy-db` | Create namespace and apply Kustomize (Secret + ConfigMap + Deployment + Service) |
| `deploy-mcp` | Build MCP server image via `oc new-build` and deploy |
| `deploy-agent-c` | Build Banking Operations Agent image and deploy |
| `setup-keycloak` | Provision Keycloak realm, client, audience mapper, roles, and demo users |
| `test-pgvector` | Run pgvector schema + RLS tests (requires Podman) |
| `compile-pipeline` | Compile the KFP pipeline to YAML |
| `clean` | Tear down deployed workloads (deployments, services, secrets, configmaps, PVC) |

> **Note:** Tier 1 access gating (non-admin rejection at the network level) requires the Kagenti AuthBridge sidecar, which is injected by the Kagenti operator. Without it, the MCP server's `@admin_only` decorator still enforces write restrictions at the tool level (Tier 2), and RLS enforces read scoping at the database level.

### Quick Start

```bash
# 1. Deploy the database and MCP server
make deploy-db deploy-mcp

# 2. Configure Keycloak (creates realm, client, users, audience mapper)
KEYCLOAK_ADMIN=<admin-user> KEYCLOAK_PASSWORD=<admin-password> make setup-keycloak

# 3. Deploy the Banking Operations Agent (requires LLM config)
LLM_BASE_URL=<vllm-endpoint>/v1 LLM_MODEL=<model-name> make deploy-agent-c

# 4. Verify
oc get pods
```

### Keycloak Setup Details

`make setup-keycloak` runs `scripts/setup-keycloak.sh`, which creates:

- Realm `redbank` with client `redbank-mcp` (public, direct access grants enabled)
- An audience mapper that adds `redbank-mcp` to the access token `aud` claim
- Realm role `admin`
- Users `john` (user) and `jane` (admin, with `admin` realm role)

Required environment variables:

| Variable | Description |
|----------|-------------|
| `KEYCLOAK_ADMIN` | Keycloak admin username |
| `KEYCLOAK_PASSWORD` | Keycloak admin password |

Optional — auto-detected from `oc get route keycloak -n keycloak` if not set:

| Variable | Description |
|----------|-------------|
| `KEYCLOAK_URL` | Keycloak base URL (e.g. `https://keycloak.example.com`) |

### Cleanup

```bash
make clean                         # uses default namespace
NAMESPACE=my-namespace make clean  # override namespace
```

This removes AgentRuntime CRs, deployments, services, secrets, and configmaps. It does not remove the namespace or Keycloak resources.

## Manual Testing

### Prerequisites

- OpenShift cluster with `oc` CLI authenticated
- The demo is deployed (`make deploy-all`)
- Keycloak realm configured (`make setup-keycloak`)
- Port-forward is active in a separate terminal:

```bash
oc port-forward svc/redbank-mcp-server 8000:8000
```

### Step 1 — Verify database seed data

Run from your local terminal (not inside the pod):

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'admin', false);
  SELECT set_config('app.current_user_email', 'jane@redbank.demo', false);
  SELECT count(*) FROM customers;
  SELECT count(*) FROM statements;
  SELECT count(*) FROM transactions;
  SELECT count(*) FROM user_accounts;
"
```

Expected: 5 customers, 13 statements, 27 transactions, 2 user_accounts.

Verify RLS is enabled and forced:

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'admin', false);
  SELECT relname, relrowsecurity, relforcerowsecurity
  FROM pg_class
  WHERE relname IN ('customers', 'statements', 'transactions');
"
```

Expected: all rows show `t` / `t`.

### Step 2 — Verify RLS scoping

Switch to John's user context and confirm he can only see his own data:

```bash
oc rsh deployment/postgresql psql -U user -d db -c "
  SELECT set_config('app.current_role', 'user', false);
  SELECT set_config('app.current_user_email', 'john@redbank.demo', false);
  SELECT customer_id, name FROM customers;
  SELECT count(*) FROM transactions;
"
```

Expected: only customer_id=5 (John Doe), and only John's transactions (8 from seed data).

### Step 3 — Initialize an MCP session

The MCP server uses FastMCP's Streamable HTTP transport, which requires a session. All curl commands need these headers:

```
Content-Type: application/json
Accept: application/json, text/event-stream
```

Initialize a session and capture the session ID:

```bash
SESSION_ID=$(curl -si http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl-test","version":"1.0"}}}' \
  2>&1 | grep -i 'mcp-session-id' | tr -d '\r' | awk '{print $2}')

echo "Session: $SESSION_ID"
```

### Step 4 — List tools

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Expected: 5 tools (`get_customer`, `get_customer_transactions`, `get_account_summary`, `update_account`, `create_transaction`).

### Step 5 — Get Keycloak tokens

Fetch real tokens from Keycloak for the demo users. Requires `make setup-keycloak` to have been run first.

```bash
# Get the Keycloak route from your cluster
KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"

# John (regular user)
JOHN_JWT=$(curl -sf "${KEYCLOAK_URL}/realms/redbank/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=redbank-mcp" \
  -d "username=john" \
  -d "password=john123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Jane (admin)
JANE_JWT=$(curl -sf "${KEYCLOAK_URL}/realms/redbank/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=redbank-mcp" \
  -d "username=jane" \
  -d "password=jane123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

### Step 6 — Admin read

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JANE_JWT" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"alice.johnson@email.com"}}}'
```

Expected: Alice Johnson's full customer record.

### Step 7 — User read (RLS scoped)

John can see his own data:

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"john@redbank.demo"}}}'
```

Expected: John Doe's customer record (customer_id 5).

John cannot see other customers:

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_customer","arguments":{"email":"bob.smith@email.com"}}}'
```

Expected: empty `{}` — RLS blocks access to Bob's record.

### Step 8 — User write (blocked)

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JOHN_JWT" \
  -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"update_account","arguments":{"customer_id":5,"phone":"555-0000"}}}'
```

Expected: `"isError": true` with `"This operation requires admin privileges"`.

### Step 9 — Admin write (allowed)

```bash
curl -s http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "Authorization: Bearer $JANE_JWT" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"update_account","arguments":{"customer_id":5,"phone":"555-9999"}}}'
```

Expected: updated customer record with `phone: "555-9999"`.

### Step 10 — Verify Kagenti enrollment

```bash
oc get agentruntime
# expect: redbank-banking-agent-runtime (agent, Active) and redbank-mcp-server-runtime (tool, Active)

oc get deployment redbank-mcp-server -o jsonpath='{.metadata.labels.kagenti\.io/type}'
# expect: tool (set by operator)

oc get svc redbank-mcp-server -o jsonpath='{.metadata.labels.protocol\.kagenti\.io/mcp}'
# expect: true
```

## Automated Tests

Integration tests cover tool discovery, admin reads, user RLS scoping, write enforcement, and Keycloak token acquisition.

### Prerequisites

- MCP server deployed and running
- Port-forward active: `oc port-forward svc/redbank-mcp-server 8000:8000`
- Keycloak realm configured: `make setup-keycloak`

### Run

```bash
pip install requests pytest
pytest tests/test_mcp_rls.py -v
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MCP_URL` | `http://localhost:8000/mcp` | MCP server endpoint |
| `KEYCLOAK_URL` | cluster route | Keycloak base URL |
| `KEYCLOAK_REALM` | `redbank` | Keycloak realm |
| `KEYCLOAK_CLIENT` | `redbank-mcp` | Keycloak client ID |
| `JOHN_PASSWORD` | `john123` | Password for john |
| `JANE_PASSWORD` | `jane123` | Password for jane |
| `USE_FAKE_JWT` | `false` | Set `true` to use unsigned JWTs (for `JWT_VERIFY=false` mode) |

By default, tests fetch real access tokens from Keycloak. Set `USE_FAKE_JWT=true` for local dev without Keycloak.

## Environment Variables

### MCP Server

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8000` | Bind port |
| `POSTGRES_HOST` | `localhost` | PostgreSQL host |
| `POSTGRES_DATABASE` | `db` | Database name |
| `POSTGRES_USER` | `user` | Database user |
| `POSTGRES_PASSWORD` | `pass` | Database password |
| `POSTGRES_PORT` | `5432` | Database port |
| `JWT_VERIFY` | `false` | `false` = trust AuthBridge sidecar; `true` = verify JWT via JWKS |
| `JWT_ALGORITHMS` | `RS256` | Comma-separated JWT algorithms |
| `JWKS_URL` | (empty) | Keycloak JWKS endpoint (required when `JWT_VERIFY=true`) |
| `JWT_AUDIENCE` | (empty) | Expected JWT `aud` claim. Use `account` for default Keycloak tokens, or `redbank-mcp` after adding an audience mapper. Tokens are rejected if the claim doesn't match. |
| `ADMIN_ROLE_CLAIM` | `admin` | Role name that grants admin access |
| `DEFAULT_ROLE` | `admin` | Fallback role when no Bearer token present |
| `DEFAULT_EMAIL` | `jane@redbank.demo` | Fallback email when no Bearer token present |

### Banking Agent

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `8001` | Bind port |
| `MCP_SERVER_URL` | `http://redbank-mcp-server:8000/mcp` | MCP server endpoint (in-cluster service) |
| `LLM_BASE_URL` | (required) | vLLM or OpenAI API base URL (e.g. `http://vllm:8000/v1`) |
| `LLM_MODEL` | (required) | Model name (e.g. `meta-llama/Llama-3.1-8B-Instruct`) |
| `OPENAI_API_KEY` | (required) | API key for the LLM endpoint (vLLM or OpenAI). Stored in `llm-credentials` secret. |
| `MLFLOW_TRACKING_URI` | (optional) | MLflow tracking endpoint from OpenShift AI |
| `AGENT_URL` | `http://redbank-banking-agent:8001` | Agent's own URL (used in agent card) |

### Production Configuration

**With AuthBridge sidecar** (standard Kagenti deployment) — the sidecar validates and exchanges tokens upstream. The MCP server decodes the trusted token without re-verifying the signature:

```yaml
- name: JWT_VERIFY
  value: "false"
- name: JWT_AUDIENCE
  value: "redbank-mcp"   # AuthBridge token exchange sets this audience
- name: DEFAULT_ROLE
  value: "user"           # fail-safe: no token = restricted access
```

**Standalone deployment** (no AuthBridge, e.g. dev cluster) — the MCP server verifies JWT signatures directly via JWKS:

```yaml
- name: JWT_VERIFY
  value: "true"
- name: JWKS_URL
  value: "https://keycloak.example.com/realms/redbank/protocol/openid-connect/certs"
- name: JWT_AUDIENCE
  value: "account"        # or "redbank-mcp" if audience mapper is configured
- name: DEFAULT_ROLE
  value: "user"           # fail-safe: no token = restricted access
```
