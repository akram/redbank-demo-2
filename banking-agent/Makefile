SHELL          := bash
PORT           ?= 8001
CONTAINER_CLI  := $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: init env run run-fresh build push deploy help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

init: ## Create .env from template.env if missing
	@if [ ! -f .env ]; then cp template.env .env && echo "Created .env from template.env — edit it with your configuration"; else echo ".env already exists — skipping"; fi

env: ## Create venv and install dependencies (uv sync)
	@echo "==> Creating/syncing virtual environment (Python 3.12)..." && \
	uv sync --python 3.12 && \
	echo "" && \
	echo "Done. Next: configure .env (make init), then make run"

run: ## Run the banking agent locally (PORT, default 8001)
	@[ -d .venv ] || { echo "ERROR: No .venv — run: make env  (or: uv venv --python 3.12 && uv sync)"; exit 1; }
	@source .venv/bin/activate && set -a && source .env && set +a && \
	AGENT_PORT=$${PORT:-8001}; \
	if command -v lsof >/dev/null 2>&1 && lsof -ti:$$AGENT_PORT >/dev/null 2>&1; then \
	  echo "ERROR: Port $$AGENT_PORT is already in use."; \
	  exit 1; \
	fi && \
	uv run python -m banking_agent

run-fresh: ## Free the agent port and restart
	@[ -d .venv ] || { echo "ERROR: No .venv — run: make env"; exit 1; }
	@source .venv/bin/activate && set -a && source .env && set +a && \
	AGENT_PORT=$${PORT:-8001}; \
	echo "==> Killing process on port $$AGENT_PORT (if any)..." && \
	(command -v lsof >/dev/null 2>&1 && lsof -ti:$$AGENT_PORT | xargs kill -9 2>/dev/null); true && \
	sleep 0.5 && \
	$(MAKE) run

build: ## Build container image locally
	@[ -n "$(CONTAINER_CLI)" ] || { echo "ERROR: neither podman nor docker found in PATH"; exit 1; }
	$(CONTAINER_CLI) build -t redbank-banking-agent:latest .

push: ## Push container image to registry (set CONTAINER_IMAGE in .env)
	@[ -n "$(CONTAINER_CLI)" ] || { echo "ERROR: neither podman nor docker found in PATH"; exit 1; }
	@set -a && source .env && set +a && \
	[ -n "$${CONTAINER_IMAGE:-}" ] || { echo "ERROR: Set CONTAINER_IMAGE in .env"; exit 1; } && \
	$(CONTAINER_CLI) tag redbank-banking-agent:latest "$${CONTAINER_IMAGE}" && \
	$(CONTAINER_CLI) push "$${CONTAINER_IMAGE}" && \
	echo "Pushed $${CONTAINER_IMAGE}"

deploy: ## Deploy to OpenShift (requires oc login + LLM_BASE_URL, LLM_MODEL)
	@bash deploy.sh
