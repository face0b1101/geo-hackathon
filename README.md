# ADS-B Flight Tracking with the Elastic Stack

Live aircraft position tracking powered by [OpenSky Network](https://opensky-network.org) and the Elastic Stack. Logstash pipelines poll the OpenSky REST API for real-time ADS-B transponder data, enrich each position with country/region geo-shapes, and index everything into an Elasticsearch data stream for visualisation in Kibana.

> **Data source** - All flight data is provided by [The OpenSky Network](https://opensky-network.org), a community-based receiver network that collects air traffic surveillance data and makes it freely available for research and non-commercial purposes. No data is bundled in this repository; it is fetched live from the OpenSky API at runtime.
>
> If you use this project, please review the [OpenSky Network terms of use](https://opensky-network.org/about/terms-of-use).

## Architecture

```mermaid
flowchart LR
    OSN["OpenSky Network API"]
    LS["Logstash"]
    ES["Elasticsearch"]
    KB["Kibana"]

    OSN -->|"HTTP poll every 6 min"| LS
    LS -->|"enrich + index"| ES
    ES -->|"visualise"| KB
```

Each pipeline covers one quadrant of the globe. Splitting the world into four smaller queries is intentional - a single global request requires significantly more memory and CPU than four parallel quadrant requests.

| Pipeline  | Coverage                    | Bounding box                |
| --------- | --------------------------- | --------------------------- |
| `adsb-q1` | North-West (Americas/North) | lat 0 to 90, lon -180 to 0  |
| `adsb-q2` | North-East (Europe/Asia)    | lat 0 to 90, lon 0 to 180   |
| `adsb-q3` | South-West (Americas/South) | lat -90 to 0, lon -180 to 0 |
| `adsb-q4` | South-East (Africa/Oceania) | lat -90 to 0, lon 0 to 180  |

All four pipelines write to the same `demos-aircraft-adsb` data stream. An ingest pipeline enriches each document with country/region metadata and nearest airport proximity via geo-shape enrich policies.

## Getting Started with Elasticsearch

You need a running Elasticsearch and Kibana instance to receive the data. Two options:

- **Elastic Cloud** ([elastic.co/cloud](https://elastic.co/cloud)) - managed Elasticsearch and Kibana (Hosted or Serverless). Your Elasticsearch and Kibana endpoint URLs are shown on the deployment overview page.
- **Start Local** ([elastic/start-local](https://github.com/elastic/start-local)) - run `curl -fsSL https://elastic.co/start-local | sh` to spin up Elasticsearch and Kibana locally via Docker. Your endpoints are shown at the end of the install and saved in `elastic-start-local/.env`.

Both approaches give you an **Elasticsearch endpoint URL** and a **Kibana endpoint URL**. You will also need an API key - see below.

## Generate an API Key

Open Kibana **Dev Tools** (or use curl) and run:

```dev-tools
POST /_security/api_key
{
  "name": "adsb-demo"
}
```

From the response, copy the `id` and `api_key` values and join them with a colon:

```secret
ES_API_KEY=<id>:<api_key>
```

This is the format that the [Logstash elasticsearch output plugin](https://www.elastic.co/docs/reference/logstash/plugins/plugins-outputs-elasticsearch#plugins-outputs-elasticsearch-api_key) expects.

> **Warning** - When created by the `elastic` superuser, this key inherits full cluster privileges. This is fine for a demo but **not a production best practice**. In production, use [scoped role descriptors](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-security-create-api-key) to follow the principle of least privilege.

## Quick Start

### 1. Prerequisites

- Docker and Docker Compose
- An [OpenSky Network](https://opensky-network.org/register) account (free)
- An Elasticsearch cluster (see above)

### 2. Configure

```bash
cp .env.example .env
```

Edit `.env` and fill in your credentials:

```sh
ES_ENDPOINT=https://my-deployment.es.us-central1.gcp.cloud.es.io
ES_API_KEY=VuaCfGcBCdbkQm-e5aOx:ui2lp2axTNmsyakw9tvNnw
KB_ENDPOINT=https://my-deployment.kb.us-central1.gcp.cloud.es.io

OPENSKY_API_USER=your_opensky_username
OPENSKY_API_PW=your_opensky_password
```

### 3. Set up Elasticsearch

Run the setup script to create the geo-shapes and airports indices, enrich policies, ingest pipeline, index template, and import Kibana saved objects (dashboards, data views). The script reads `ES_ENDPOINT`, `ES_API_KEY`, and `KB_ENDPOINT` from your `.env` file.

```bash
./setup.sh
```

### 4. Run

```bash
docker compose up -d
```

All four quadrant pipelines start automatically. Each polls OpenSky every 6 minutes and writes to the `demos-aircraft-adsb` data stream.

### 5. Verify

Check logs:

```bash
docker compose logs -f logstash
```

Confirm all pipelines are running:

```bash
docker compose exec logstash curl -s localhost:9600/_node/pipelines?pretty
```

You should see `adsb-q1` through `adsb-q4` in the response.

## Stopping

```bash
docker compose down
```

## Project Structure

```sh
.
├── docker-compose.yml
├── .env.example
├── setup.sh                                          # One-command Elasticsearch setup
├── elasticsearch/
│   ├── index-template.json                           # Index template for the data stream
│   ├── ingest-pipeline.json                          # Ingest pipeline (enrich + trim)
│   ├── enrich-policy.json                            # Country geo-shape enrich policy
│   ├── geo-shapes-world-countries-50m-mapping.json   # Source index mapping for country boundaries
│   ├── geo-shapes-world-countries-50m-data.json      # Country boundary geo-shapes (bulk data)
│   ├── adsb-airport-enrich-policy.json               # Airport proximity enrich policy
│   ├── adsb-airports-geo-mapping.json                # Source index mapping for airports (Natural Earth + coverage)
│   ├── adsb-airports-geo-data.json                   # 893 airports with multilingual names, ICAO codes, and coverage polygons
│   └── adsb-saved-objects.ndjson                     # Kibana saved objects (dashboards, data views)
└── logstash/
    ├── config/
    │   ├── logstash.yml                              # Logstash node settings
    │   └── pipelines.yml                             # Registers all 4 quadrant pipelines
    └── pipeline/
        ├── adsb_q1.conf                              # Q1 - North-West
        ├── adsb_q2.conf                              # Q2 - North-East
        ├── adsb_q3.conf                              # Q3 - South-West
        └── adsb_q4.conf                              # Q4 - South-East
```

## Optional: Centralised Pipeline Management

Instead of managing pipeline `.conf` files on disk, you can use Kibana's [Centralised Pipeline Management](https://www.elastic.co/docs/reference/logstash/configuring-centralized-pipelines) (CPM) to create, edit, and delete pipelines from the UI. Pipelines are stored in Elasticsearch and pulled by Logstash at the configured polling interval.

### 1. Add management settings to `logstash.yml`

```yaml
xpack.management.enabled: true
xpack.management.elasticsearch.hosts: ["${ES_ENDPOINT}"]
xpack.management.elasticsearch.api_key: "${ES_API_KEY}"
xpack.management.pipeline.id: ["adsb-q1", "adsb-q2", "adsb-q3", "adsb-q4"]
xpack.management.elasticsearch.pipeline.poll_interval: 5s
```

### 2. Create pipelines in Kibana

1. Go to **Management > Ingest > Logstash Pipelines**.
2. Create a pipeline for each ID (`adsb-q1` through `adsb-q4`) and paste the corresponding config from the pipeline files in `logstash/pipeline/`.

Once CPM is enabled, Logstash ignores local `.conf` files for managed pipeline IDs. You can run some pipelines locally and others centrally as long as their IDs don't overlap.

### 3. Restart Logstash

```bash
docker compose restart logstash
```

## Changing Log Level at Runtime

The Logstash node API (port 9600) is protected by the `LS_API_USER` / `LS_API_PW` credentials you set in `.env` (defaults: `logstash` / `changeme`).

```bash
curl -XPUT -u "${LS_API_USER}:${LS_API_PW}" \
  'localhost:9600/_node/logging?pretty' \
  -H 'Content-Type: application/json' \
  -d '{"logger.logstash.outputs.elasticsearch":"DEBUG"}'
```

Reset to defaults:

```bash
curl -XPUT -u "${LS_API_USER}:${LS_API_PW}" \
  'localhost:9600/_node/logging/reset?pretty'
```

## Data Source and Attribution

Flight tracking data is provided by [The OpenSky Network](https://opensky-network.org).

> Matthias Schäfer, Martin Strohmeier, Vincent Lenders, Ivan Martinovic and Matthias Wilhelm.
> "Bringing Up OpenSky: A Large-scale ADS-B Sensor Network for Research".
> In *Proceedings of the 13th IEEE/ACM International Symposium on Information Processing in Sensor Networks (IPSN)*, pages 83-94, April 2014.

This project is not affiliated with or endorsed by the OpenSky Network. Please review the [OpenSky Network terms of use](https://opensky-network.org/about/terms-of-use) before operating this demo.
