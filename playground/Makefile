SHELL          := bash
AGENT_NAME     := $(shell python3 -c "import re; print(re.search(r'^name:\s*(.+)', open('agent.yaml').read(), re.M).group(1).strip())")
CHART_DIR      := ./charts/agent
VALUES_FILE    := values.yaml
CONTAINER_CLI  := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: init re-init env run-app run-app-fresh build push build-openshift deploy undeploy dry-run help setup-auth

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

re-init: ## Activate venv and reload .env variables
	@source .venv/bin/activate && set -a && source .env && set +a && \
	  echo "Venv activated and .env variables loaded."

init: ## Copy .env.example to .env for configuration
	@if [ ! -f .env ]; then cp .env.example .env && echo "Created .env from .env.example — edit it with your configuration"; else echo ".env already exists — skipping"; fi

env: ## Create venv, load .env, and install dependencies
	@echo "==> Creating virtual environment and installing dependencies..." && \
	  rm -rf .venv && \
	  uv sync --python 3.12 && \
	  echo "==> Load .env variables..." && \
	  source .venv/bin/activate && set -a && source .env && set +a && \
	  echo "" && \
	  echo "Done. Next steps:" && \
	  echo "  make run-app  # start the playground UI"

run-app: ## Run playground locally with hot-reload
	@source .venv/bin/activate && set -a && source .env && set +a && \
	  if lsof -ti:$${PORT:-8080} >/dev/null 2>&1; then \
	    echo "ERROR: Port $${PORT:-8080} is already in use." && \
	    echo "  Change PORT in .env or run: make run-app-fresh" && \
	    exit 1; \
	  fi && \
	  uv run uvicorn main:app --host 0.0.0.0 --port $${PORT:-8080} --reload --reload-exclude .venv

run-app-fresh: ## Kill existing process on port and run playground with hot-reload
	@source .venv/bin/activate && set -a && source .env && set +a && \
	  echo "==> Killing existing process on port $${PORT:-8080}..." && \
	  lsof -ti:$${PORT:-8080} | xargs kill -9 2>/dev/null; true && \
	  uv run uvicorn main:app --host 0.0.0.0 --port $${PORT:-8080} --reload --reload-exclude .venv

build: ## Build container image locally (podman/docker)
	@[ -n "$(CONTAINER_CLI)" ] || { echo "ERROR: neither podman nor docker found in PATH"; exit 1; } && \
	  source .env && \
	  [ -n "$${CONTAINER_IMAGE}" ] || { echo "ERROR: CONTAINER_IMAGE is not set in .env"; exit 1; } && \
	  $(CONTAINER_CLI) build --platform linux/amd64 -t "$${CONTAINER_IMAGE}" -f Dockerfile .

push: ## Push container image to registry
	@[ -n "$(CONTAINER_CLI)" ] || { echo "ERROR: neither podman nor docker found in PATH"; exit 1; } && \
	  source .env && \
	  [ -n "$${CONTAINER_IMAGE}" ] || { echo "ERROR: CONTAINER_IMAGE is not set in .env"; exit 1; } && \
	  $(CONTAINER_CLI) push "$${CONTAINER_IMAGE}"

build-openshift: ## Build image in-cluster via OpenShift BuildConfig (no podman/docker needed)
	@[ -f .env ] || { echo "ERROR: .env not found — run 'make init' and configure it first"; exit 1; } && \
	  source .env && \
	  NS_FLAG=""; [ -z "$${NAMESPACE}" ] || NS_FLAG="--namespace $${NAMESPACE}"; \
	  oc new-build --strategy=docker --binary --name=$(AGENT_NAME) --to=$(AGENT_NAME):latest $$NS_FLAG 2>/dev/null || true && \
	  oc start-build $(AGENT_NAME) --from-dir=. --follow $$NS_FLAG && \
	  NS=$${NAMESPACE:-$$(oc project -q)} && \
	  IMG="image-registry.openshift-image-registry.svc:5000/$$NS/$(AGENT_NAME):latest" && \
	  sed -i '' 's|^CONTAINER_IMAGE=.*|CONTAINER_IMAGE='"$$IMG"'|' .env && \
	  echo "" && \
	  echo "Image built and CONTAINER_IMAGE updated in .env:" && \
	  echo "  $$IMG" && \
	  echo "" && \
	  echo "Next: make deploy"

_check-env:
	@set -a && source .env 2>/dev/null && set +a; \
	  missing=""; \
	  for var in $$(sed -n '/^ *required:/,/^ *[a-z]/{ /^ *- /s/^ *- *//p; }' agent.yaml); do \
	    eval val="\$$$$var"; \
	    [ -n "$$val" ] || missing="$$missing $$var"; \
	  done; \
	  [ -z "$$missing" ] || { echo "ERROR: Missing required env vars:$$missing"; exit 1; }

deploy: _check-env ## Deploy to OpenShift/K8s via Helm
	@source .env && \
	  [ -n "$${CONTAINER_IMAGE}" ] || { echo "ERROR: CONTAINER_IMAGE is not set in .env"; exit 1; } && \
	  NS_FLAG="" && [ -z "$${NAMESPACE}" ] || NS_FLAG="--namespace $${NAMESPACE}" && \
	  LAST_SEG="$${CONTAINER_IMAGE##*/}" && if [[ "$$LAST_SEG" == *:* ]]; then IMAGE_REPO="$${CONTAINER_IMAGE%:*}"; IMAGE_TAG="$${LAST_SEG##*:}"; else IMAGE_REPO="$${CONTAINER_IMAGE}"; IMAGE_TAG="latest"; fi && \
	  helm upgrade --install $(AGENT_NAME) $(CHART_DIR) \
	    $$NS_FLAG \
	    -f $(VALUES_FILE) \
	    --set image.repository="$${IMAGE_REPO}" \
	    --set image.tag="$${IMAGE_TAG}" \
	    --set env.ORCHESTRATOR_URL="$${ORCHESTRATOR_URL}" && \
	  echo "" && echo "Waiting for rollout to complete..." && \
	  if oc rollout status deployment/$(AGENT_NAME) $$NS_FLAG --timeout=120s; then \
	    ROUTE=$$(oc get route $(AGENT_NAME) $$NS_FLAG -o jsonpath='{.spec.host}' 2>/dev/null || true); \
	    if [ -n "$$ROUTE" ]; then echo "" && echo "Playground is available at: https://$$ROUTE"; fi; \
	    if [[ -n "$${KEYCLOAK_URL:-}$${KEYCLOAK_REALM:-}$${KEYCLOAK_CLIENT_ID:-}" ]]; then \
	      echo "" && echo "==> Registering Keycloak redirect URI..." && \
	      NAMESPACE="$${NAMESPACE}" bash scripts/register-keycloak-redirect.sh || \
	        echo "WARNING: Keycloak redirect registration failed. Run 'make setup-auth' manually."; \
	    fi; \
	  else \
	    echo "" && echo "WARNING: Rollout did not complete successfully. Check pod status with:" && \
	    echo "  oc get pods $$NS_FLAG -l app.kubernetes.io/name=$(AGENT_NAME)" && \
	    echo "  oc logs $$NS_FLAG deployment/$(AGENT_NAME)"; \
	  fi

dry-run: _check-env ## Render Helm templates without deploying
	@source .env && \
	  [ -n "$${CONTAINER_IMAGE}" ] || { echo "ERROR: CONTAINER_IMAGE is not set in .env"; exit 1; } && \
	  NS_FLAG="" && [ -z "$${NAMESPACE}" ] || NS_FLAG="--namespace $${NAMESPACE}" && \
	  LAST_SEG="$${CONTAINER_IMAGE##*/}" && if [[ "$$LAST_SEG" == *:* ]]; then IMAGE_REPO="$${CONTAINER_IMAGE%:*}"; IMAGE_TAG="$${LAST_SEG##*:}"; else IMAGE_REPO="$${CONTAINER_IMAGE}"; IMAGE_TAG="latest"; fi && \
	  helm template $(AGENT_NAME) $(CHART_DIR) \
	    $$NS_FLAG \
	    -f $(VALUES_FILE) \
	    --set image.repository="$${IMAGE_REPO}" \
	    --set image.tag="$${IMAGE_TAG}" \
	    --set env.ORCHESTRATOR_URL="$${ORCHESTRATOR_URL}"

setup-auth: ## Register playground redirect URI in Keycloak (run after deploy)
	@source .env 2>/dev/null; \
	  bash scripts/register-keycloak-redirect.sh

undeploy: ## Remove deployment from cluster
	@source .env 2>/dev/null; \
	  NS_FLAG=""; [ -z "$${NAMESPACE}" ] || NS_FLAG="--namespace $${NAMESPACE}"; \
	  helm uninstall $(AGENT_NAME) $$NS_FLAG
