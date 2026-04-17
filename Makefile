.PHONY: deploy-db deploy-mcp deploy-agent-c deploy-all clean setup-keycloak

NAMESPACE ?= redbank-demo
export NAMESPACE

deploy-db:
	oc new-project $(NAMESPACE) 2>/dev/null || oc project $(NAMESPACE)
	cd postgres-db && oc apply -k .

deploy-mcp:
	cd mcp-server && bash deploy.sh

deploy-agent-c:
	cd banking-agent && bash deploy.sh

deploy-all: deploy-db deploy-mcp deploy-agent-c
	@echo "RedBank Kagenti demo deployed to namespace $(NAMESPACE)"

clean:
	bash scripts/cleanup.sh

setup-keycloak:
	bash scripts/setup-keycloak.sh
