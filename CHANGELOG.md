# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Airport proximity enrichment** — 893 airports from Natural Earth dataset merged with geo-shape coverage polygons (`adsb-airports-geo` index), `adsb-airport-proximity` enrich policy, and ingest pipeline integration; each ADS-B document is now enriched with airport name, IATA/ICAO codes, type, geometry, and Wikipedia link when within coverage range
- **Airport activity classification** — ingest pipeline script processor tags each airport-enriched document with `airport.activity`: `at_airport` (stationary), `taxiing` (moving on ground), `arriving` (descending), `departing` (climbing), or `overflight` (level flight through airspace)
- **Makefile** with targets for common operations (`setup`, `up`, `down`, `logs`, `restart`, `status`, `clean`, `help`)
- **Apache 2.0 licence** (`LICENSE`)
- **API key generation instructions** in README with scoped role descriptor for least-privilege access
- **Getting Started with Elasticsearch** section covering Elastic Cloud (Hosted/Serverless) and start-local
- **Architecture diagram** (Mermaid) and pipeline architecture explanation in README
- **OpenSky Network attribution** — data source section with citation and terms-of-use link

### Changed

- **API key split** — replaced single `ES_API_KEY` with three variables (`ES_API_KEY_ID`, `ES_API_KEY`, `ES_API_KEY_ENCODED`) copied directly from the Create API Key response; eliminates user-side base64 encoding and improves setup UX
- **Scoped API key** — README now documents a least-privilege role descriptor instead of a superuser key
- **Auth migration** — replaced Cloud ID / basic auth with `ES_ENDPOINT` + API key across all configs (Logstash pipelines, docker-compose, setup.sh, .env.example)
- **`.env.example` simplified** — Elasticsearch/Kibana variables consolidated to `ES_ENDPOINT`, `ES_API_KEY_ID`, `ES_API_KEY`, `ES_API_KEY_ENCODED`, `KB_ENDPOINT`
- **`setup.sh`** migrated from basic auth (`-u user:pass`) to API key auth (`Authorization: ApiKey` header)
- **Logstash pipeline outputs** switched from `cloud_id`/`cloud_auth` to `hosts`/`api_key`
- **Centralised Pipeline Management** section updated with API key config and link to official docs
- **Docker volume** changed from `external: true` to managed (auto-created by `docker compose up`)
- **AGENTS.md** rewritten for actual tech stack (Docker, Logstash, Elasticsearch, Kibana, Bash) — removed Python/UV/Ruff boilerplate
- **README** rewritten as top-level repo README — removed stale `cd adsb` instruction and `adsb/` path references
- **`.gitignore`** expanded with `.DS_Store`, `*.log`, `.cursor/`, `logstash/files/*`
- **Repository renamed** from `geo-hackathon` to `adsb-demo`

### Removed

- `ES_CLOUD_ID`, `ES_CLOUD_AUTH`, `ES_URL`, `ES_HOSTS`, `ES_USER`, `ES_PW`, `ES_SSL_VERIFICATION`, `LS_HTTP_USER`, `LS_HTTP_PW` environment variables
- Commented-out test `generator` block from `adsb_q1.conf`
- `CHANGELOG.md` template content from unrelated project
- `.pre-commit-config.yaml` with Python/Ruff hooks (not applicable)

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
[unreleased]: https://github.com/face0b1101/adsb-demo/compare/v0.2.0...HEAD
