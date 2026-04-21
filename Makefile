.PHONY: deploy-db deploy-mcp deploy-agent-c deploy-knowledge-agent deploy-all clean setup-keycloak test-pgvector compile-pipeline test-knowledge-agent

NAMESPACE ?= redbank-demo
export NAMESPACE

deploy-db:
	oc new-project $(NAMESPACE) 2>/dev/null || oc project $(NAMESPACE)
	cd postgres-db && oc apply -k .

deploy-mcp:
	cd mcp-server && bash deploy.sh

deploy-agent-c:
	cd banking-agent && bash deploy.sh

deploy-knowledge-agent:
	cd knowledge-agent && bash deploy.sh

deploy-all: deploy-db deploy-mcp deploy-agent-c deploy-knowledge-agent
	@echo "RedBank Kagenti demo deployed to namespace $(NAMESPACE)"

clean:
	bash scripts/cleanup.sh

setup-keycloak:
	bash scripts/setup-keycloak.sh

test-pgvector:
	cd langchain-pgvector && python3 -m pytest tests/ -v

compile-pipeline:
	cd langchain-pgvector/pipeline && python3 pgvector_rag_pipeline.py

test-knowledge-agent:
	@echo "Port-forwarding knowledge agent (background)..."
	@oc port-forward svc/redbank-knowledge-agent 8002:8002 &
	@sleep 2
	@bash scripts/test-knowledge-agent.sh; RC=$$?; kill %1 2>/dev/null; exit $$RC
