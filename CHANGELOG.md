# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.1] - 2026-03-12

### Changed

- **Dashboard IDs parameterised in workflows** — `daily-flight-briefing.yaml` and `squawk-7500-hijack-investigation.yaml` now use `__DASHBOARD_WORLD_OVERVIEW_ID__` and `__DASHBOARD_AIRCRAFT_DETAIL_ID__` placeholders instead of hardcoded UUIDs; `setup.sh` extracts the real IDs from the ndjson export at deploy time using jq, matching the existing pattern for `__SLACK_CONNECTOR_ID__`
- **Alert rule dashboard artifact dynamised** — the squawk 7500 alerting rule in `setup.sh` now uses the extracted `DASHBOARD_AIRCRAFT_DETAIL_ID` variable instead of a hardcoded UUID

### Fixed

- **Hardcoded Elastic Cloud URL in saved objects** — the Aircraft Detail dashboard's "Return to World Overview" markdown panel used a full `https://adsb-demo-fe9ed3.kb.eu-west-1.aws.elastic.cloud/...` URL; replaced with a relative `/app/dashboards#/view/...` path so the link works on any deployment

## [1.4.0] - 2026-03-12

### Changed

- **Alert rule switched from DSL to ES|QL** — the squawk 7500 hijack detection rule now uses `searchType: "esqlQuery"` with per-row grouping (`groupBy: "row"`), providing individual alerts per aircraft with full field context in `event.alerts[0].kibana.alert.grouping`
- **Alert rule consumer switched to `observability`** — alerts now land in `.alerts-observability` indices, consistent with `owner: observability` on Kibana Cases
- **Hijack investigation workflow refactored** — consumes alert context directly (`event.alerts[0].kibana.alert.grouping.*`) instead of re-querying Elasticsearch; removed redundant `search_squawk_7500` step and `foreach` wrapper; added `fetch_enriched_doc` step for geo and airport fields not in the ES|QL `KEEP` clause
- **`.workflows` system connector wired at rule creation** — `setup.sh` now pre-resolves the workflow ID and includes the `.workflows` action in the alert rule payload, with fallback manual-linking instructions if the workflow isn't deployed yet

### Fixed

- **Case deduplication logic** — Kibana Cases `_find` API treats multiple `tags` query parameters as an OR condition; switched from `tags=icao24:...&tags=squawk-7500` to a single `tags=icao24:...` filter so only the aircraft-specific tag is used for dedup

## [1.3.0] - 2026-03-10

### Added

- **Service user automation** — `setup.sh` creates a dedicated `adsb-automation` user, role, and session API key so all deployed resources (alert rules, workflows, agents) are attributed to a service identity rather than the human operator; gracefully skips when the API key lacks `manage_security` or the deployment does not support native roles
- **`--no-service-user` flag** for `setup.sh` — opt out of service user creation and run everything under the original `.env` API key
- **`make setup-no-service-user` target** — convenience Make target for running full setup without the service user
- **adsbdb callsign fallback** — `squawk-7500-enrich.yaml` and `squawk-7500-hijack-investigation.yaml` now fall back to an ICAO24-only adsbdb lookup when the combined callsign+ICAO24 request fails (e.g. unrecognised callsign)

### Changed

- **API key role descriptor** updated in README and `.env.example` — now includes `manage_security` cluster privilege for service user creation; existing keys without this privilege continue to work (service user step is skipped)
- **Dashboard link corrected** in `daily-flight-briefing.yaml` — Slack message "Open Dashboard" button now points to the correct saved-object ID
- **Kibana saved objects** re-exported to pick up latest dashboard changes
- **AGENTS.md** — added `make setup-no-service-user` to Make targets table, reformatted table column widths

## [1.2.1] - 2026-03-10

### Changed

- **News API replaced** — switched from defunct Reuters/RapidAPI endpoint (returning 404) to [GNews](https://gnews.io) across hijack investigation and enrichment workflows, `setup.sh`, agent instructions, and all documentation
- **`GNEWS_API_KEY`** replaces `RAPIDAPI_KEY` in `.env.example` — free tier provides 100 req/day with 12-hour article delay; news correlation step skips gracefully when unset
- **Workflow step renamed** — `reuters_search` → `news_search` in both `squawk-7500-hijack-investigation.yaml` and `squawk-7500-enrich.yaml`; HTTP headers block removed (GNews uses query-string auth)

## [1.2.0] - 2026-03-10

### Added

- **Kibana Spaces support** — new `KB_SPACE` environment variable deploys all Kibana resources (dashboards, agents, workflows) into a dedicated space; `setup.sh` creates the space automatically with the Observability solution view and custom icon (`data/adsb-space-icon-64.png`)
- **ILM policy** (`elasticsearch/indices/adsb-ilm-policy.json`) — `adsb-lifecycle` policy with hot (rollover at 40 GB / 14 d), frozen (searchable snapshot at 14 d), and delete (730 d) phases; index template references it; `setup.sh` deploys it and gracefully skips on Serverless
- **`deploy-ilm` Make target** — deploys the ILM policy independently (`make deploy-ilm`)
- **Migration import pipeline** (`logstash/pipeline/migrate-import.conf`) — Logstash pipeline for importing NDJSON files exported by logstash-es-export into the `demos-aircraft-adsb` data stream
- **`SLACK_CONNECTOR_ID`** environment variable — configurable Slack connector UUID substituted into workflow YAML at deploy time
- **Deployment comparison table** in README — Cloud Hosted, Observability Serverless, start-local, and Elasticsearch Serverless with Cases and alerting support matrix
- **jq dependency check** — `setup.sh` now validates that `jq` is installed before running

### Changed

- **Case owner migrated from `securitySolution` to `observability`** — all workflows (create-case, hijack-investigation, daily-briefing, hijack-cases-summary) now use `owner: observability` for Kibana case management, enabling Cases on Observability Serverless deployments
- **Hijack investigation workflow restructured** — iterates over `event.context.hits` from the alert payload (foreach loop) instead of re-querying Elasticsearch; creates individual cases per matched aircraft with deduplication; removed manual trigger (alert-only); uses `${{ }}` expression syntax for conditions
- **Slack connector ID parameterised** — workflows use `__SLACK_CONNECTOR_ID__` placeholder substituted at deploy time instead of a hardcoded UUID
- **Space-aware Kibana API paths** — all workflow `kibana.request` steps and `setup.sh` API calls use `__SPACE_PREFIX__` placeholder (workflows) or `KB_BASE` variable (scripts) for correct space routing
- **Python3 replaced with jq** — all `python3 -c` inline scripts in `setup.sh` replaced with `jq` equivalents, removing the Python runtime dependency
- **API key scope simplified** — role descriptor now uses `cluster: ["manage"]` (single privilege) and `"privileges": ["all"]` for Kibana application access instead of listing individual feature privileges
- **Enrich policy force-delete improved** — when `--force` cannot delete a policy (referenced by a running pipeline), `setup.sh` re-executes it instead of failing
- **adsbdb lookup** — ICAO24 hex code uppercased with `| upcase` filter for correct API matching
- **Daily briefing Slack step** — corrected agent output reference from `steps.generate_briefing.output.message` to `steps.generate_briefing.output`
- **`deploy-es` target** now includes ILM (`ilm,indices,enrich,pipelines`)
- **AGENTS.md** — added `deploy-ilm` to Make targets table, space-aware `KB_BASE` variable in testing recipes, all API examples updated to use `KB_BASE` instead of `KB_ENDPOINT`
- **README** — expanded prerequisites for workflows and agents (Agent Builder, Workflows UI toggles, Cases), added Kibana Spaces documentation, added `KB_SPACE` to example `.env` config

## [1.1.0] - 2026-03-09

### Added

- **Squawk 7500 hijack detection pipeline** — end-to-end automated response when a transponder broadcasts squawk 7500 (hijack):
  - **Alerting rule** — ES query rule checks `demos-aircraft-adsb` every 5 minutes for `squawk: "7500"` events; created idempotently by `setup.sh`
  - **Enrichment workflow** (`squawk-7500-enrich.yaml`) — fetches aircraft metadata from adsbdb, live position from adsb.lol, and correlated news from GNews
  - **Investigation workflow** (`squawk-7500-hijack-investigation.yaml`) — orchestrates enrichment, AI assessment, case creation, and optional Slack notification
  - **Case creation workflow** (`squawk-7500-create-case.yaml`) — creates or updates a Kibana Security case tagged `squawk-7500` with verdict tags (`verdict:genuine` / `verdict:false_positive`)
  - **Cases summary workflow** (`hijack-cases-summary.yaml`) — retrieves squawk 7500 investigation cases from Kibana case management for briefing integration
- **Hijack assessment agent** (`adsb-hijack-assessment-agent.json`) — AI agent that evaluates squawk 7500 events using enriched context (aircraft history, live position, news correlation) and renders a structured verdict
- **Agent documentation** (`elasticsearch/agents/README.md`) — architecture, deployment, and testing guide for all AI agents
- **Workflow documentation** (`elasticsearch/workflows/README.md`) — reference for all workflows including triggers, inputs, side effects, and deployment
- **`GNEWS_API_KEY`** environment variable in `.env.example` for GNews news search in the hijack investigation workflow
- **Makefile deploy targets** — granular `deploy-indices`, `deploy-enrich`, `deploy-pipelines`, `deploy-kibana`, `deploy-workflows`, `deploy-agents`, `deploy-es`, `deploy-ai`, `redeploy` targets with `FORCE=1` support
- **Makefile diagnostics** — `validate`, `health`, `ps`, `shell` targets
- **Make Targets** reference section in README with tables for all target groups
- **Testing via API** section in `AGENTS.md` — recipes for testing workflows, agents, and ES queries via curl

### Changed

- **Aggregation deduplication** — all bucket aggregations in `adsb-aggregate-stats.yaml` and `daily-flight-briefing.yaml` now include cardinality sub-aggregations (`unique_flights` / `unique_aircraft`) so counts reflect distinct aircraft or flights rather than raw observation `doc_count`
- **Daily briefing agent instructions** — rewritten to use deduplicated counts, add OpenSky Network coverage caveats, correct ground-vs-airborne framing (overlapping buckets, not a ratio), and integrate hijack investigation cases (section 10)
- **Daily briefing workflow** — fetches hijack cases from Kibana case management (`fetch_hijack_cases` step), expanded agent prompt with deduplication guidance and executive-summary framing rules
- **API key role descriptor** — added `feature_workflowsManagement.all`, `feature_stackAlerts.all`, and `feature_siem.all` Kibana privileges (replaced `feature_workflows.all`)
- **`setup.sh` expanded** — deploys hijack assessment agent, squawk 7500 alerting rule, and four new workflows; workflow deploy logic refactored with rename-after-create and improved error handling
- **Makefile restructured** — grouped targets under `##@` section headers with improved `help` output using `awk`
- **AGENTS.md Make targets table** — expanded to include all deploy, diagnostics, and help targets
- **README getting started** — commands updated to use `make` shortcuts (`make setup`, `make up`, `make logs`, `make status`, `make down`)

## [1.0.0] - 2026-03-09

First stable release. Complete ADS-B flight tracking pipeline with real-time
data ingestion, geo-enrichment, AI agents, automated daily briefings, and
Kibana dashboards.

### Changed

- **Kibana saved objects** — re-exported to pick up latest dashboard tweaks

## [0.3.0] - 2026-03-09

### Added

- **Daily briefing workflow** — `daily-flight-briefing.yaml` runs at 08:00 Europe/London each day; aggregates 24h ADS-B statistics (unique aircraft, busiest airports, regional traffic, emergency squawks), invokes the briefing agent to generate a natural-language summary, and posts it to Slack
- **Aggregate stats workflow** — `adsb-aggregate-stats.yaml` (manual trigger) returns raw 24h aggregation results; registered as an agent tool so AI agents can fetch live statistics on demand
- **Daily briefing agent** — "ADS-B Daily Briefing Analyst" (`adsb-daily-briefing-agent.json`) deployed via Kibana Agent Builder; generates and discusses flight briefings, highlights emergency squawk events, and can trigger the aggregation workflow
- **Slack connector** — `setup.sh` auto-creates a Kibana Slack connector when `SLACK_WEBHOOK_URL` is set in `.env`
- **`SLACK_WEBHOOK_URL`** environment variable in `.env.example`
- **`--only` and `--force` flags** for `setup.sh` — run specific groups (`indices`, `enrich`, `pipelines`, `kibana`, `agents`, `workflows`) and optionally overwrite existing resources
- **Screenshot** of Aircraft World Overview dashboard in README
- **Kibana saved objects** — four new objects: `ES|QL` tag, _Latest Events_ ES|QL saved search, _World Countries_ map, and `geo.shapes-world.countries-50m` data view
- **Airports & Airspace layer group** added to Aircraft Demo map (Airspace + Airports layers matching World Overview)
- **Airport proximity enrichment** — 893 airports from Natural Earth dataset merged with geo-shape coverage polygons (`adsb-airports-geo` index), `adsb-airport-proximity` enrich policy, and ingest pipeline integration; each ADS-B document is now enriched with airport name, IATA/ICAO codes, type, geo-point location, and Wikipedia link when within coverage range
- **Airport activity classification** — ingest pipeline script processor tags each airport-enriched document with `airport.activity`: `at_airport` (stationary), `taxiing` (moving on ground), `arriving` (descending), `departing` (climbing), or `overflight` (level flight through airspace)
- **AI agent** — "Aircraft ADS-B Tracking Specialist" (`adsb-agent.json`) deployed via Kibana Agent Builder; answers natural-language questions about flight data using platform search tools against the `demos-aircraft-adsb` data stream
- **Ingest pipeline type conversions** — `convert` processors cast `on_ground` to boolean, `velocity` and `vertical_rate` to float before the activity-classification script runs
- **Index refresh steps** — `setup.sh` now explicitly refreshes the geo-shapes and airports indices after bulk loading, before creating enrich policies
- **Kibana import error handling** — saved-objects import in `setup.sh` now checks HTTP status and parses the response for partial failures, reporting individual object errors
- **Log4j2 configuration** — `logstash/config/log4j2.properties` with console and rolling-file appenders (25 MB rotation, 3 archives)
- **Makefile** with targets for common operations (`setup`, `up`, `down`, `logs`, `restart`, `status`, `clean`, `help`)
- **Apache 2.0 licence** (`LICENSE`)
- **API key generation instructions** in README with scoped role descriptor for least-privilege access
- **Getting Started with Elasticsearch** section covering Elastic Cloud (Hosted/Serverless) and start-local
- **Architecture diagram** (Mermaid) with AI Agent, Workflow, and Slack nodes plus pipeline architecture explanation in README
- **OpenSky Network attribution** — data source section with citation and terms-of-use link

### Fixed

- **Agent Builder deployment** — removed `id` from `adsb-agent.json` request body (rejected by the PUT endpoint) and made `setup.sh` idempotent with a PUT-then-POST fallback so the agent is created on first run and updated on re-runs

### Changed

- **Repository restructured** — Elasticsearch resources reorganised into `agents/`, `enrich/`, `indices/`, `kibana/`, `pipelines/`, `workflows/` subdirectories; bulk data files moved to top-level `data/`
- **`setup.sh` rewritten** — modular group-based architecture; idempotent by default (skips existing resources); supports `--only` to run specific groups and `--force` to overwrite
- **API key scope expanded** — added `feature_workflows.all`, `feature_actions.all`, and `feature_advancedSettings.all` Kibana privileges for workflow and connector deployment
- **README updated** — Workflows section with prerequisites, `--only`/`--force` usage examples, expanded architecture diagram, and updated directory tree
- **Saved objects tagged "Demo"** — all content objects (data views, maps, searches, dashboards) now carry the _Demo_ tag for consistent filtering in Kibana
- **Fixed missing data view references** — country boundary layers in both maps rewired from stale ID (`8ce4c5f0`) to the bundled `geo.shapes-world.countries-50m` data view (`29d4323f`); export metadata now reports zero missing references
- **Aircraft Demo map aligned with World Overview** — default basemap set to Dark Blue only (ESA Copernicus off), old flat Airports layer replaced with Airports & Airspace group
- **Airport geo data restructured** — flat `geometry`/`coverage_area`/`location` fields reorganised into a nested `geo` object (`geo.location`, `geo.airspace`, `geo.description`) across the airport mapping, enrich policy, ingest pipeline, index template, and bulk data; data file renamed from `.json` to `.ndjson`
- **API key role descriptor** — added `monitor` cluster privilege and `feature_agentBuilder.all` Kibana application privilege for agent deployment
- **Docker Compose** — mounts `log4j2.properties` into the Logstash container
- **API key split** — replaced single `ES_API_KEY` with three variables (`ES_API_KEY_ID`, `ES_API_KEY`, `ES_API_KEY_ENCODED`) copied directly from the Create API Key response; eliminates user-side base64 encoding and improves setup UX
- **Scoped API key** — README now documents a least-privilege role descriptor (`adsb_setup`) instead of a superuser key; consolidated index privileges into a single block covering all required indices
- **Auth migration** — replaced Cloud ID / basic auth with `ES_ENDPOINT` + API key across all configs (Logstash pipelines, docker-compose, setup.sh, .env.example)
- **`.env.example` simplified** — Elasticsearch/Kibana variables consolidated to `ES_ENDPOINT`, `ES_API_KEY_ID`, `ES_API_KEY`, `ES_API_KEY_ENCODED`, `KB_ENDPOINT`; added `SLACK_WEBHOOK_URL`
- **`setup.sh`** migrated from basic auth (`-u user:pass`) to API key auth (`Authorization: ApiKey` header)
- **Logstash pipeline outputs** switched from `cloud_id`/`cloud_auth` to `hosts`/`api_key`
- **Centralised Pipeline Management** section updated with API key config and link to official docs
- **Docker volume** changed from `external: true` to managed (auto-created by `docker compose up`)
- **AGENTS.md** rewritten for actual tech stack (Docker, Logstash, Elasticsearch, Kibana, Bash) — removed Python/UV/Ruff boilerplate
- **README** rewritten as top-level repo README — removed stale `cd adsb` instruction and `adsb/` path references
- **`.gitignore`** expanded with IDE (`.idea/`, `.vscode/`), temp (`*.tmp`, `*.bak`), and project-specific (`hive-mind/`, `docker-compose.override.yml`) entries
- **Repository renamed** from `geo-hackathon` to `adsb-demo`

### Removed

- **Country-highlight layers** (Europe, Russia, Belarus, Ukraine) removed from Aircraft Demo map
- `ES_CLOUD_ID`, `ES_CLOUD_AUTH`, `ES_URL`, `ES_HOSTS`, `ES_USER`, `ES_PW`, `ES_SSL_VERIFICATION`, `LS_HTTP_USER`, `LS_HTTP_PW` environment variables
- Commented-out test `generator` block from `adsb_q1.conf`
- `CHANGELOG.md` template content from unrelated project
- `.pre-commit-config.yaml` with Python/Ruff hooks (not applicable)
- Flat `geometry`, `coverage_area`, and `location` fields from airport source index (replaced by nested `geo` object)

## [0.2.0] - 2026-03-03

### Added

- **AGENTS.md** with AI assistant operating rules and project conventions
- **Kibana saved objects import** in `setup.sh` — dashboards and data views loaded automatically

### Changed

- Files moved from `adsb/` subdirectory to repository root

## [0.1.0] - 2026-03-02

### Added

- **ADS-B flight tracker** — four Logstash pipelines polling the OpenSky Network API, one per geographic quadrant (NW, NE, SW, SE)
- **Elasticsearch resources** — index template (time-series data stream), ingest pipeline (geo-shape enrichment), enrich policy, country boundary geo-shapes (bulk data)
- **`setup.sh`** — one-command Elasticsearch setup (indices, enrich policy, ingest pipeline, index template)
- **Docker Compose** configuration for Logstash 9.x
- **`.env.example`** with all required configuration variables

[0.1.0]: https://github.com/face0b1101/adsb-demo/releases/tag/v0.1.0
[0.2.0]: https://github.com/face0b1101/adsb-demo/compare/v0.1.0...v0.2.0
[0.3.0]: https://github.com/face0b1101/adsb-demo/compare/v0.2.0...v0.3.0
[1.0.0]: https://github.com/face0b1101/adsb-demo/compare/v0.3.0...v1.0.0
[1.1.0]: https://github.com/face0b1101/adsb-demo/compare/v1.0.0...v1.1.0
[1.2.0]: https://github.com/face0b1101/adsb-demo/compare/v1.1.0...v1.2.0
[1.2.1]: https://github.com/face0b1101/adsb-demo/compare/v1.2.0...v1.2.1
[1.3.0]: https://github.com/face0b1101/adsb-demo/compare/v1.2.1...v1.3.0
[1.4.0]: https://github.com/face0b1101/adsb-demo/compare/v1.3.0...v1.4.0
[1.4.1]: https://github.com/face0b1101/adsb-demo/compare/v1.4.0...v1.4.1
[unreleased]: https://github.com/face0b1101/adsb-demo/compare/v1.4.1...HEAD
