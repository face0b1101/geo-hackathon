# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.10.0] - 2026-03-25

### Added

- **Demo user deployment** (`make deploy-demouser`) — creates two pre-configured demo users (`goose` and `maverick`) with least-privilege roles scoped to the demo space; `goose` is audience-facing (dashboards, agents, cases) while `maverick` adds Dev Tools and management access for presenters; passwords are randomly generated and printed to the console; also runs as part of `make setup`
- **`warn_on_fail` helper** in `setup.sh` — logs a WARNING for non-2xx HTTP responses instead of silently discarding them; applied to workflow name PUT calls that previously had no error handling

### Fixed

- **Saved objects import false positive** — `jq -r` outputs lowercase `"false"` for JSON booleans but the comparison used title-case `"False"`, causing partial import failures with `--force` to be silently ignored
- **`create_kibana_role` abort on Serverless** — the function returned non-zero for expected skip cases (HTTP 400/404/403), causing `set -e` to abort the script on Serverless deployments; now returns 0 and uses a flag variable for caller detection

### Changed

- **AGENTS.md** — added Elastic Skills & MCP Servers guidance section with skill categories, MCP server usage, and precedence rules; added `deploy-demouser` to Make targets table
- **README** — added AI coding agent skills section; added Demo Users documentation with user table and deployment instructions; added `deploy-demouser` to Make targets table

## [1.9.3] - 2026-03-23

### Fixed

- **Enrich policy existence check false positive** — `GET /_enrich/policy/<name>` returns HTTP 200 with an empty `policies: []` array when the policy does not exist; the existence check in `setup_enrich_policy()` compared only the HTTP status code, causing it to skip policy creation on every fresh cluster and then fail at `_execute` with `policy does not exist`; now parses the response body and checks `.policies | length > 0` before treating the policy as existing ([#15](https://github.com/face0b1101/adsb-demo/issues/15))
- **Incorrect step counter for indices group** — `group_step_count("indices")` declared 6 steps but `setup_index()` always emits 3 `step_label` calls per index (create + load + refresh); corrected to 9
- **Incorrect step counter for workflows group** — `group_step_count("workflows")` declared 13 steps but `setup_workflows()` emits 19 `step_label` calls (12 deploy/config steps + 7 `register_wf_tool` steps); corrected to 19

## [1.9.1] - 2026-03-23

### Fixed

- **`setup.sh` Bash 3.2 compatibility** — replaced `declare -A` associative array with a POSIX-friendly `case` helper function; the unquoted keys triggered `set -u` (`space: unbound variable`) on stock macOS Bash ([#14](https://github.com/face0b1101/adsb-demo/issues/14))

## [1.9.0] - 2026-03-23

### Added

- **Defunct callsign detector** — new ES|QL workflow (`adsb-defunct-callsign-detector.yaml`) that cross-references live ADS-B callsign prefixes against a lookup index of 781 known defunct airlines using `LOOKUP JOIN`; configurable lookback (default 24 hours, max 30 days); scheduled daily at 07:30 Europe/London and available on-demand as an agent tool
- **Defunct airlines lookup index** (`adsb-airlines-defunct`) — Elasticsearch lookup-mode index containing 781 defunct airlines with ICAO designator codes, sourced from Wikipedia (CC BY-SA 4.0); fields include callsign prefix, airline name, country, region, ICAO/IATA codes, telephony callsign, operational dates, and notes; data file at `data/adsb-airlines-defunct-data.ndjson`, last scraped 23 March 2026
- **Defunct airlines scraper** (`data/scrape-defunct-airlines/`) — optional Python tool (uv, Python 3.13, ruff) to regenerate the dataset from Wikipedia via the Jina Reader API; scrapes 11 pages (5 regional + India, US ×4, UK), parses markdown tables, and outputs bulk NDJSON with date parsing via `python-dateutil`
- **CC BY-SA 4.0 licence file** (`data/adsb-airlines-defunct-LICENCE.md`) — attribution, source links, changes statement, and ShareAlike declaration for the Wikipedia-derived dataset
- **Daily briefing integration** — added `defunct_callsign_scan` ES|QL step to the Daily Flight Briefing workflow; results are passed to the briefing agent as section 11 (defunct callsign detections)
- **Agent tool** — registered `adsb-defunct-callsign-detector` as a workflow tool for the ADS-B Tracking Specialist agent with structured markdown report format, cache fallback instructions, and interpretation guidance for code reuse vs genuine anomalies

### Changed

- **API key privileges** — simplified index names in the role descriptor from explicit list (`adsb-airports-geo`, `adsb-enrichment-cache`, etc.) to `adsb*` glob, covering all current and future `adsb-` prefixed indices; updated in both `setup.sh` service user role and `README.md` API key example
- **ADS-B agent** (`adsb-agent.json`) — added `adsb-defunct-callsign-detector` to tool_ids and appended "Defunct Callsign Detection" instructions section with report format, cache fallback, and interpretation context
- **Daily briefing agent** (`adsb-daily-briefing-agent.json`) — added briefing section 11 (defunct callsign detections) to the instructions
- **`setup.sh`** — added `adsb-airlines-defunct` index to `setup_indices()`, added defunct callsign detector workflow deployment with `register_wf_tool`, updated service user privileges to `adsb*`

## [1.8.0] - 2026-03-22

### Added

- **Airport activity report workflow** (`adsb-airport-activity.yaml`) — new ES|QL workflow that generates a comprehensive activity report for an airport over a configurable time range; accepts free-text airport names (e.g. "Heathrow"), IATA codes ("LHR"), or ICAO/GPS codes ("EGLL") and resolves them via case-insensitive matching; eight `elasticsearch.esql.query` steps produce airport resolution, traffic summary, activity breakdown, hourly traffic profile, top flights, origin countries, emergency squawks, and recent positions
- **Airport activity agent tool** — registered `adsb-airport-activity` as a workflow tool for the Aircraft ADS-B Tracking Specialist agent; added report format instructions covering 9-section structured markdown output, ES|QL columnar output parsing guidance, and enrichment cache fallback for Stack 9.3.x
- **Enrichment cache for airport activity** — all 8 ES|QL query steps write their output to the `adsb-enrichment-cache` index (keyed `airport-activity:{step}:{airport}`), following the same WORKAROUND(#9) pattern used by `adsb-aircraft-history`; agents query the cache as a fallback when workflow `outputs` are null on Stack 9.3.x (quirk #4)

### Changed

- **ADS-B agent** (`adsb-agent.json`) — added `adsb-airport-activity` tool and full Airport Activity Report instructions section; `lookback` input uses ES|QL time intervals (`24 hours`, `7 days`) instead of ES date math
- **`setup_agents()` in `setup.sh`** — now extracts and substitutes `__DASHBOARD_WORLD_OVERVIEW_ID__` alongside the existing `__DASHBOARD_AIRCRAFT_DETAIL_ID__` placeholder, fixing unresolved dashboard links in agent instructions
- **`setup_workflows()` in `setup.sh`** — new deployment block for the airport activity workflow with `register_wf_tool` registration
- **Workflows README** (`elasticsearch/workflows/README.md`) — added inventory entry, system overview mermaid diagram updates (tracking agent, aircraft history, airport activity), new documentation sections for Aircraft History (section 6), Airport Activity (section 7), and Hijack Cases Summary (section 8), and ADS-B Tracking Specialist to the agents section
- **Agents README** (`elasticsearch/agents/README.md`) — updated Tracking Specialist tools table, capabilities list, and mermaid diagrams to reflect both workflow tools

## [1.7.0] - 2026-03-21

### Added

- **Aircraft history report workflow** (`adsb-aircraft-history.yaml`) — new workflow that generates a comprehensive history report for an individual aircraft over a configurable time range, including flight summary aggregations (callsigns with time windows and airports, countries, altitude/velocity stats), up to 1,000 time-ordered position samples, related Kibana cases, airframe details from adsbdb, and live position from adsb.lol
- **ADS-B agent tool** — registered `adsb-aircraft-history` as a workflow tool for the Aircraft ADS-B Tracking Specialist agent; added report format instructions, 30-day lookback guardrail, and ES-authoritative data source priority guidance to the agent prompt
- **Enrichment cache workaround** (`adsb-enrichment-cache` index) — agent-called workflows with HTTP steps now write external API responses to an ES cache index via `elasticsearch.request` PUT with `| json` serialisation, so agents can query cached data when workflow `outputs` are null on Stack 9.3.x (quirk #4); applied to both `adsb-aircraft-history` and `squawk-7500-enrich` workflows; tracked by [#12](https://github.com/face0b1101/adsb-demo/issues/12)
- **Known Quirks #7–#9** in AGENTS.md — documented `elasticsearch.index` template limitations, null step names in `get_workflow_execution_status`, and `if` condition behaviour with failed step outputs
- **Workflow authoring tips** in `elasticsearch/workflows/README.md` — indexing from step outputs, handling missing indices in conditionals, and two patterns for passing step data to agents

### Changed

- **ADS-B agent** (`adsb-agent.json`) — added `adsb-aircraft-history` tool, enrichment cache fallback instructions, 30-day lookback guardrail, and data source priority note; `setup_agents()` in `setup.sh` now substitutes `__KB_ENDPOINT__` and `__DASHBOARD_AIRCRAFT_DETAIL_ID__` placeholders in agent instructions at deploy time
- **Hijack assessment agent** (`adsb-hijack-assessment-agent.json`) — added enrichment cache fallback instructions for interactive chat path
- **Service user role** — added `adsb-enrichment-cache` to the index privileges
- **API key role descriptor** (README.md) — added `adsb-enrichment-cache` to the index list

## [1.6.2] - 2026-03-19

### Changed

- **Kibana saved objects re-exported** — picked up dashboard and data view changes from Kibana
- **ICAO24 field URL changed** — data view link target updated from `opensky-network.org/aircraft-profile` to `planespotters.net/search` for better aircraft lookup
- **Callsign field format simplified** — removed internal Kibana `parsedUrl` metadata; FlightAware URL template unchanged
- **Aircraft Detail navigation upgraded** — replaced `DASHBOARD_MARKDOWN` panel ("Return to World Overview" link) with a native Kibana `links` panel for proper dashboard cross-linking
- **Dashboard access control updated** — Aircraft World Overview set to `write_restricted`; Aircraft Detail `accessControl` removed
- **Dashboard pinned panels removed** — both dashboards had `pinned_panels` cleared
- **Control group reference naming** — options list references updated with `controlGroup_` prefix (Kibana version migration)

## [1.6.1] - 2026-03-19

### Fixed

- **Confidence custom field not populated on alert-triggered cases** — the `squawk-7500-hijack-investigation.yaml` workflow hardcoded `confidence: null` in both the `tag_genuine` and `tag_false_positive` PATCH steps, leaving the Confidence case custom field empty even though the value appeared in the AI assessment comment; replaced each single PATCH step with a nested `if`/`contains` chain that extracts the confidence level (`high`, `medium`, or `low`) from the agent's `**Confidence:**` output line, defaulting to `low` if no match is found; the chat-mode workflow (`squawk-7500-create-case.yaml`) was already correct as it receives confidence as a structured input

## [1.6.0] - 2026-03-19

### Added

- **Case custom fields and template** — new `elasticsearch/cases/observability-config.json` defines four custom fields (ICAO24 Address, Callsign, AI Triage Assessment, Confidence) and a "Squawk 7500 — Hijack Investigation" case template; `setup.sh` gains a `cases` group that creates or updates the case configuration via the Kibana Cases configure API; `make deploy-cases` target added
- **Custom fields populated by workflows** — both `squawk-7500-hijack-investigation.yaml` and `squawk-7500-create-case.yaml` now set `customFields` when creating or tagging cases, providing structured metadata alongside the existing tag-based deduplication
- **Case category** — cases created by both `squawk-7500-hijack-investigation.yaml` and `squawk-7500-create-case.yaml` now carry `category: "Hijack Triage"`
- **Cases link in daily briefing** — Slack message now includes an "Open Cases" link alongside the existing "Open Dashboard" link
- **Known Quirk #5** in `AGENTS.md` — documents that Case custom field `type: "number"` is integer-only and unsupported in `kibana.createCase`; recommends `type: "text"` with categorical values as a workaround

### Changed

- **"Verdict" renamed to "AI Triage Assessment"** across all user-facing surfaces — case tags use `triage:genuine` / `triage:false_positive` (previously `verdict:`), workflow inputs and parse conditions use the new label, agent instructions output `**AI Triage Assessment:**` instead of `**Verdict:**`, and all documentation updated to match; existing cases retain their old `verdict:` tags
- **`squawk-7500-create-case` workflow input renamed** — `verdict` input is now `triage_assessment`; agent tool description in `setup.sh` updated accordingly
- **Confidence changed from numeric to categorical** — agent instructions and `squawk-7500-create-case` workflow now use `low` / `medium` / `high` instead of a 0–1 float, avoiding the Cases API integer-only limitation for number fields
- **Case deduplication switched to composite tag** — `squawk-7500-hijack-investigation.yaml` and `squawk-7500-create-case.yaml` now deduplicate using a single `icao24:{icao24}:callsign:{callsign}` tag instead of separate `icao24:` + `squawk-7500` tags, sidestepping the Kibana Cases `_find` OR-logic quirk
- **False positives no longer auto-closed** — `close_case` step replaced by `tag_false_positive`; false-positive cases are tagged `triage:false_positive` and left open for human review instead of being automatically closed
- **Slack case link corrected** — hijack investigation Slack notification now links to `/app/observability/cases/` (matching `owner: observability`) instead of `/app/security/cases/`
- **ES|QL alert rule LIMIT increased** — from 10 to 100, allowing the alert rule to surface more aircraft per evaluation window
- **Service user step refactored** — removed `serviceuser` from `ALL_GROUPS`; the service user step now always runs first (unless `--no-service-user` is passed), even when `--only` selects a subset of groups
- **Documentation updated** — README, `elasticsearch/agents/README.md`, and `elasticsearch/workflows/README.md` updated to reflect renamed fields, new deduplication strategy, and revised routing behaviour

## [1.5.1] - 2026-03-18

### Added

- **`LS_CENTRALIZED_MGMT` env var** — toggle for Logstash centralised pipeline management; when `true`, Logstash fetches pipeline configs from Elasticsearch instead of local files; defaults to `false` (local file mode)
- **`silence_errors_in_log`** on all four pipeline Elasticsearch outputs — suppresses `version_conflict_engine_exception` (409) log noise from duplicate documents
- **Pipeline design documentation** — all four quadrant pipeline configs now include a block comment explaining the `heartbeat` → OAuth2 token → API call polling pattern and why `http_poller` cannot be used; README gains a new "Pipeline Design — Polling with OAuth2" section with an ASCII flow diagram

### Changed

- **README** — "Centralised Pipeline Management" section rewritten to use `LS_CENTRALIZED_MGMT` env var toggle instead of manual `logstash.yml` edits; Quick Start `.env` example updated for OAuth2 credentials (`OPENSKY_API_CLIENT_ID` / `OPENSKY_API_CLIENT_SECRET`)

## [1.5.0] - 2026-03-18

### Changed

- **OpenSky API auth migrated from Basic Auth to OAuth2** — OpenSky Network deprecated username/password authentication on 18 March 2026; all four quadrant pipelines (`adsb_q1`–`adsb_q4`) now use the OAuth2 client credentials flow via two inline `http` filter steps (token fetch + Bearer-authenticated API call)
- **Pipeline input replaced** — `http_poller` input swapped for `heartbeat` input (360s interval) with HTTP calls moved to the filter stage, enabling the two-step OAuth2 flow
- **Error resilience added** — drop guard (`_httprequestfailure` tag or missing `[message][states]`) prevents failed polls (429s, token errors, empty responses) from reaching the Elasticsearch output and triggering TSDS dimension errors
- **Stale references cleaned up** — removed `http_poller_metadata` and `time` from split filter `remove_field`; removed commented-out `generator` input blocks from Q2–Q4

### Added

- **`logstash/Dockerfile`** — extends the stock Logstash image to install `logstash-filter-http` (not bundled by default)
- **`OPENSKY_API_CLIENT_ID`** and **`OPENSKY_API_CLIENT_SECRET`** environment variables in `.env.example` and `docker-compose.yml`
- **Docker Compose `build` context** — `docker-compose.yml` switched from `image:` to `build:` referencing the new Dockerfile with `ELASTIC_STACK_VERSION` as a build arg

## [1.4.5] - 2026-03-13

### Removed

- **Bug report working docs** (`.github/bug-reports/`) — moved to upstream Kibana issues; local copies no longer needed

### Changed

- **Known Quirks** in `AGENTS.md` — linked items 1 and 2 to upstream issues ([elastic/kibana#257744](https://github.com/elastic/kibana/issues/257744), [elastic/kibana#257743](https://github.com/elastic/kibana/issues/257743))
- **README** — added Known Issues section linking upstream Kibana bug reports

## [1.4.4] - 2026-03-13

### Added

- **Workflow `outputs` sections** for four agent-tool workflows (`squawk-7500-enrich`, `adsb-aggregate-stats`, `hijack-cases-summary`, `squawk-7500-create-case`) — maps step outputs to execution-level output fields using `${{ }}` syntax; forward-compatible with future Stack releases (currently non-functional on Stack 9.3.x, works on Elastic Cloud Serverless)
- **Bug report templates** (`.github/bug-reports/`) — documented two Kibana API quirks for upstream reporting: `lastExecution` always `null` on Workflows API, and Cases `_find` `tags` parameter using OR logic

### Changed

- **Known Quirks** expanded in `AGENTS.md` — added item #4 documenting workflow `outputs` limitation on Stack 9.3.x
- **README** — added known limitation note for workflow `outputs` on Stack 9.3.x referencing tracking issue [#9](https://github.com/face0b1101/adsb-demo/issues/9), noting Elastic Workflows is a Preview feature
- **Kibana saved objects** re-exported to pick up latest changes

## [1.4.3] - 2026-03-13

### Fixed

- **adsbdb enrichment failing silently** — when the alert callsign was empty or null, the combined `/v0/aircraft/{icao24}?callsign=` URL returned HTTP 200 with `{"response": "invalid callsign: "}`, bypassing the `on-failure` fallback and producing "unavailable — unknown" in case comments; split into two separate steps: `adsbdb_aircraft` (unconditional `/v0/aircraft/{icao24}`) and `adsbdb_route` (conditional `/v0/callsign/{callsign}`, guarded by a non-empty callsign check); applied to both `squawk-7500-hijack-investigation.yaml` and `squawk-7500-enrich.yaml`
- **Case comment output paths corrected** — template references updated from `steps.adsbdb_lookup.output.data.response.*` to the new split step names (`steps.adsbdb_aircraft` / `steps.adsbdb_route`)
- **AI prompt updated** — agent prompt now receives aircraft metadata and expected route as separate labelled sections instead of a single combined dump

## [1.4.2] - 2026-03-13

### Changed

- **Hijack assessment output format improved** — agent instructions now specify a structured markdown template with a title heading (`## Squawk 7500 Assessment — {icao24} ({callsign})`), explicit Verdict/Confidence fields, a Reasoning section with 4–6 key-evidence bullets; workflow prompt, case comment, and routing condition updated to match
- **Case comment simplified** — removed redundant `### AI Hijack Assessment` wrapper heading from the investigation workflow; the agent's own structured heading now serves as the case comment title
- **Create-case workflow aligned** — `squawk-7500-create-case.yaml` comment and description templates updated to use the same structured format for consistency across automated and interactive paths

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
- **`.gitignore`** expanded with IDE (`.idea/`, `.vscode/`), temp (`*.tmp`, `*.bak`), and project-specific entries
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
[1.4.2]: https://github.com/face0b1101/adsb-demo/compare/v1.4.1...v1.4.2
[1.4.3]: https://github.com/face0b1101/adsb-demo/compare/v1.4.2...v1.4.3
[1.4.4]: https://github.com/face0b1101/adsb-demo/compare/v1.4.3...v1.4.4
[1.4.5]: https://github.com/face0b1101/adsb-demo/compare/v1.4.4...v1.4.5
[1.5.0]: https://github.com/face0b1101/adsb-demo/compare/v1.4.5...v1.5.0
[1.5.1]: https://github.com/face0b1101/adsb-demo/compare/v1.5.0...v1.5.1
[1.6.0]: https://github.com/face0b1101/adsb-demo/compare/v1.5.1...v1.6.0
[1.6.1]: https://github.com/face0b1101/adsb-demo/compare/v1.6.0...v1.6.1
[1.6.2]: https://github.com/face0b1101/adsb-demo/compare/v1.6.1...v1.6.2
[1.7.0]: https://github.com/face0b1101/adsb-demo/compare/v1.6.2...v1.7.0
[1.8.0]: https://github.com/face0b1101/adsb-demo/compare/v1.7.0...v1.8.0
[1.9.0]: https://github.com/face0b1101/adsb-demo/compare/v1.8.0...v1.9.0
[1.9.1]: https://github.com/face0b1101/adsb-demo/compare/v1.9.0...v1.9.1
[1.9.3]: https://github.com/face0b1101/adsb-demo/compare/v1.9.2...v1.9.3
[1.10.0]: https://github.com/face0b1101/adsb-demo/compare/v1.9.3...v1.10.0
[unreleased]: https://github.com/face0b1101/adsb-demo/compare/v1.10.0...HEAD
