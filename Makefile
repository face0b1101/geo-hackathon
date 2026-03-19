FORCE_FLAG := $(if $(FORCE),--force,)

.PHONY: setup setup-no-service-user deploy-ilm deploy-indices deploy-enrich deploy-pipelines deploy-kibana \
        deploy-cases deploy-workflows deploy-agents deploy-es deploy-ai redeploy \
        up down logs restart status clean \
        validate health ps shell help

# ---------------------------------------------------------------------------
##@ Setup / Deploy
# ---------------------------------------------------------------------------

setup:              ## Run full Elasticsearch setup (skip existing)
	./setup.sh $(FORCE_FLAG)

setup-no-service-user: ## Run full setup without service user (actions attributed to .env API key owner)
	./setup.sh --no-service-user $(FORCE_FLAG)

deploy-ilm:         ## Deploy ES ILM policy (skipped on Serverless)
	./setup.sh --only ilm $(FORCE_FLAG)

deploy-indices:     ## Deploy ES index templates and data streams
	./setup.sh --only indices $(FORCE_FLAG)

deploy-enrich:      ## Deploy ES enrich policies
	./setup.sh --only enrich $(FORCE_FLAG)

deploy-pipelines:   ## Deploy ES ingest pipelines
	./setup.sh --only pipelines $(FORCE_FLAG)

deploy-kibana:      ## Deploy Kibana saved objects (dashboards, data views)
	./setup.sh --only kibana $(FORCE_FLAG)

deploy-cases:       ## Deploy case configuration (custom fields, templates)
	./setup.sh --only cases $(FORCE_FLAG)

deploy-workflows:   ## Deploy Kibana workflows
	./setup.sh --only workflows $(FORCE_FLAG)

deploy-agents:      ## Deploy Kibana AI agents
	./setup.sh --only agents $(FORCE_FLAG)

deploy-es:          ## Deploy all ES resources (ilm + indices + enrich + pipelines)
	./setup.sh --only ilm,indices,enrich,pipelines $(FORCE_FLAG)

deploy-ai:          ## Deploy AI layer (workflows + agents)
	./setup.sh --only workflows,agents $(FORCE_FLAG)

redeploy:           ## Re-deploy all resources (force overwrite)
	./setup.sh --force

# ---------------------------------------------------------------------------
##@ Logstash
# ---------------------------------------------------------------------------

up:                 ## Start Logstash
	docker compose up -d

down:               ## Stop Logstash
	docker compose down

logs:               ## Tail Logstash logs
	docker compose logs -f logstash

restart:            ## Restart Logstash after config changes
	docker compose restart logstash

status:             ## Show Logstash pipeline status
	docker compose exec logstash curl -s localhost:9600/_node/pipelines?pretty

clean:              ## Stop Logstash and remove volumes
	docker compose down -v

# ---------------------------------------------------------------------------
##@ Diagnostics
# ---------------------------------------------------------------------------

validate:           ## Validate Docker Compose config
	docker compose config --quiet && echo "Docker Compose config is valid."

health:             ## Check Elasticsearch cluster health
	@if [ -f .env ]; then set -a; . ./.env; set +a; fi; \
	curl -s "$${ES_ENDPOINT%/}/_cluster/health?pretty" \
	  -H "Authorization: ApiKey $${ES_API_KEY_ENCODED}"

ps:                 ## Show running containers
	docker compose ps

shell:              ## Open a shell inside the Logstash container
	docker compose exec logstash bash

# ---------------------------------------------------------------------------
##@ Help
# ---------------------------------------------------------------------------

help:               ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
