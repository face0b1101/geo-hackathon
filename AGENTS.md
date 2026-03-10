# Project Rules

> **Single Source of Truth** for AI coding assistants (Claude Code, Cursor, etc.)

______________________________________________________________________

## Tech Stack & Commands

- **Runtime**: Docker & Docker Compose
- **Data pipeline**: Logstash 9.x (four quadrant pipelines polling the OpenSky Network API)
- **Search & storage**: Elasticsearch (time-series data stream with geo-shape enrichment)
- **Visualisation**: Kibana (dashboards, data views)
- **Setup automation**: Bash (`setup.sh`)

| Command                    | Purpose                                                                  |
| -------------------------- | ------------------------------------------------------------------------ |
| `cp .env.example .env`     | Create local environment config                                          |
| `make setup`               | Create ES indices, enrich policy, ingest pipeline, import Kibana objects |
| `make deploy-ilm`          | Deploy ES ILM policy only (skipped on Serverless)                        |
| `make deploy-indices`      | Deploy ES index templates and data streams only                          |
| `make deploy-enrich`       | Deploy ES enrich policies only                                           |
| `make deploy-pipelines`    | Deploy ES ingest pipelines only                                          |
| `make deploy-kibana`       | Deploy Kibana saved objects (dashboards, data views) only                |
| `make deploy-workflows`    | Deploy Kibana workflows only                                             |
| `make deploy-agents`       | Deploy Kibana AI agents only                                             |
| `make deploy-es`           | Deploy all ES resources (ilm + indices + enrich + pipelines)             |
| `make deploy-ai`           | Deploy AI layer (workflows + agents)                                     |
| `make redeploy`            | Re-deploy all resources (force overwrite)                                |
| `make up`                  | Start Logstash (all 4 pipelines)                                         |
| `make down`                | Stop Logstash                                                            |
| `make logs`                | Tail Logstash logs                                                       |
| `make restart`             | Restart Logstash after config changes                                    |
| `make status`              | Show Logstash pipeline status                                            |
| `make clean`               | Stop Logstash and remove volumes                                         |
| `make validate`            | Validate Docker Compose config                                           |
| `make health`              | Check Elasticsearch cluster health                                       |
| `make ps`                  | Show running containers                                                  |
| `make shell`               | Open a shell inside the Logstash container                               |
| `make help`                | List all available targets (grouped)                                     |

Any deploy target accepts `FORCE=1` to overwrite existing resources, e.g. `make deploy-agents FORCE=1`.

**Key conventions**:

- Never edit `.env` directly in commits; only reference `.env.example`.
- Logstash pipeline configs live in `logstash/pipeline/`; Elasticsearch resources in `elasticsearch/`.
- The four pipelines (`adsb_q1`–`adsb_q4`) are intentionally separate to spread load across quadrants.

______________________________________________________________________

## Docker Access

This project relies on Docker for its Logstash service. AI assistants
running in sandboxed environments (e.g. Cursor) often cannot reach the Docker
daemon under default sandbox restrictions.

**Always request elevated permissions for Docker commands.** Use
`required_permissions: ["all"]` for any `docker` or `docker compose` command
(including `docker ps`, `docker logs`, `docker stats`, `docker volume`,
`docker inspect`, etc.). Read-only Docker queries still require the Docker
socket, which the sandbox blocks.

```sh
# Correct — works reliably
Shell(command="docker ps", required_permissions=["all"])

# Wrong — will silently fail with empty output or exit code 1
Shell(command="docker ps")
Shell(command="docker ps", required_permissions=["full_network"])
```

______________________________________________________________________

## Testing via API

After editing workflows (`elasticsearch/workflows/`), agents (`elasticsearch/agents/`),
or aggregation queries, validate changes via the Elasticsearch and Kibana REST APIs.
All commands require `required_permissions: ["all"]` in sandboxed environments.

### Prerequisites

```sh
source .env   # provides ES_ENDPOINT, KB_ENDPOINT, ES_API_KEY_ENCODED

# Space-aware Kibana base URL (all Kibana API calls must use KB_BASE)
KB_BASE="${KB_ENDPOINT%/}"
[[ -n "${KB_SPACE:-}" ]] && KB_BASE="${KB_BASE}/s/${KB_SPACE}"
```

### Redeploy changed resources

```sh
./setup.sh --only agents,workflows --force
```

### Test an Elasticsearch query

Run the query body directly against ES to validate aggregations, painless scripts, and
mappings before deploying a workflow.

```sh
curl -s "${ES_ENDPOINT}/demos-aircraft-adsb/_search" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "Content-Type: application/json" \
  -d '{"size":0,"query":{...},"aggs":{...}}' | jq '.aggregations'
```

### Test a workflow

The Kibana Workflows API (Technical Preview) requires the extra header
`x-elastic-internal-origin: kibana` on every request.

```sh
# 1. Find workflow ID by name
WF_ID=$(curl -s -X POST "${KB_BASE}/api/workflows/search" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  -H "Content-Type: application/json" \
  -d '{"query":"My Workflow Name"}' \
  | jq -r '.results[] | select(.name=="My Workflow Name") | .id')

# 2. Run (pass inputs:{} even if the workflow has none)
EXEC_ID=$(curl -s -X POST "${KB_BASE}/api/workflows/${WF_ID}/run" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{}}' | jq -r '.workflowExecutionId')

# 3. Poll until status is "completed" or "failed"
curl -s "${KB_BASE}/api/workflowExecutions/${EXEC_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  | jq '{status, duration, steps: [.stepExecutions[]? | {type: .stepType, status: .status}]}'

# 4. Inspect individual step output
STEP_ID=$(curl -s "${KB_BASE}/api/workflowExecutions/${EXEC_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" \
  | jq -r '.stepExecutions[0].id')

curl -s "${KB_BASE}/api/workflowExecutions/${EXEC_ID}/steps/${STEP_ID}" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "x-elastic-internal-origin: kibana" | jq '.output'
```

For workflows with inputs, pass them in the run body:
`-d '{"inputs":{"icao24":"a1b2c3","callsign":"DAL123"}}'`

### Test an agent

Use the Agent Builder converse API to send a message and inspect the response.

```sh
curl -s -X POST "${KB_BASE}/api/agent_builder/converse" \
  -H "Authorization: ApiKey ${ES_API_KEY_ENCODED}" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"${AGENT_ID}","input":"Your test prompt here"}' \
  | jq '{status, model: .model_usage.model, response: .response.message}'
```

### Side-effect awareness

Some workflows trigger real external actions when run:

| Workflow | Side effects |
| --- | --- |
| `adsb-aggregate-stats` | None (read-only ES query) |
| `daily-flight-briefing` | Sends Slack message, invokes AI agent |
| `squawk-7500-enrich` | External HTTP calls (adsbdb, adsb.lol, Reuters) |
| `squawk-7500-hijack-investigation` | Creates Kibana case, may send Slack |
| `squawk-7500-create-case` | Creates or updates a Kibana case |

Agent converse calls may invoke workflow tools and incur LLM costs.

______________________________________________________________________

## AI Assistant Operating Rules

Concise policy reference for all coding agents touching this repository. Keep responses factual and avoid speculative language.

### 1. Communication & Planning

- Always mention assumptions; ask the user to confirm anything ambiguous before editing.
- Follow the required plan/approval workflow when prompted and wait for explicit approval to execute.
- Use UK-English spelling in comments, documentation, and commit messages.

### 2. File Safety

- Do **not** edit `.env` or other environment files; only reference `.env.example`.
- Delete files only when you created them or the user explicitly instructs you to remove older assets.
- Never run destructive git commands (`git reset --hard`, `git checkout --`, `git restore`, `rm -rf .git`) unless the user provides written approval in this thread.

### 3. Collaboration Etiquette

- If another agent has edited a file, read their changes and build on them — do not revert or overwrite.
- Coordinate before touching large refactors that might conflict with ongoing work.
- Keep diffs minimal and reviewable; use targeted edits rather than rewriting whole files.

### 4. Git & Commits

- Check `git status` before staging and before committing.
- Keep commits atomic and list paths explicitly, e.g. `git commit -m "feat: add CI" -- path/to/file`.
- For new files: `git restore --staged :/ && git add <paths> && git commit -m "<msg>" -- <paths>`.
- Quote any paths containing brackets/parentheses when staging to avoid globbing.
- Never amend existing commits unless the user instructs you to.
- Don't plaster all commits and git issues with "Made with Cursor", "Cursor helped me with this", "AI did everything" or anything similar.

### 5. Pre-flight Checklist

1. Read the task, confirm assumptions, and outline the approach.
2. Inspect the relevant files (include imports/configs for context).
3. After changes, verify Docker Compose config parses: `docker compose config --quiet`.
4. Summarise edits, mention tests, and flag follow-up work in the final response.
