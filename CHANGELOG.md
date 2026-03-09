# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
[unreleased]: https://github.com/face0b1101/adsb-demo/compare/v1.0.0...HEAD
