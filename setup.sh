#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f .env ]]; then
  set -a; source .env; set +a
else
  echo "ERROR: .env file not found in $SCRIPT_DIR" >&2
  echo "Copy .env.example to .env and fill in your credentials first." >&2
  exit 1
fi

for var in ES_ENDPOINT ES_API_KEY_ENCODED KB_ENDPOINT; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Check your .env file." >&2
    exit 1
  fi
done

TOTAL=11
STEP=0
BASE="${ES_ENDPOINT%/}"
KB_BASE="${KB_ENDPOINT%/}"

run_curl() {
  local label="$1"; shift
  STEP=$((STEP + 1))
  echo "[$STEP/$TOTAL] $label ..."

  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  http_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" "$@")

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $http_code):" >&2
    cat "$tmpfile" >&2
    rm -f "$tmpfile"
    exit 1
  fi

  echo "  OK (HTTP $http_code)"
  rm -f "$tmpfile"
}

run_curl "Creating geo shapes source index" \
  -X PUT "$BASE/geo.shapes-world.countries-50m" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/geo-shapes-world-countries-50m-mapping.json

run_curl "Bulk-loading geo shapes data" \
  -X POST "$BASE/geo.shapes-world.countries-50m/_bulk" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @elasticsearch/geo-shapes-world-countries-50m-data.json

run_curl "Creating enrich policy" \
  -X PUT "$BASE/_enrich/policy/opensky-geo-enrich-50m" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/enrich-policy.json

run_curl "Executing enrich policy" \
  -X POST "$BASE/_enrich/policy/opensky-geo-enrich-50m/_execute"

run_curl "Creating airports source index" \
  -X PUT "$BASE/adsb-airports-geo" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/adsb-airports-geo-mapping.json

run_curl "Bulk-loading airports data" \
  -X POST "$BASE/adsb-airports-geo/_bulk" \
  -H "Content-Type: application/x-ndjson" \
  --data-binary @elasticsearch/adsb-airports-geo-data.json

run_curl "Creating airport proximity enrich policy" \
  -X PUT "$BASE/_enrich/policy/adsb-airport-proximity" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/adsb-airport-enrich-policy.json

run_curl "Executing airport proximity enrich policy" \
  -X POST "$BASE/_enrich/policy/adsb-airport-proximity/_execute"

run_curl "Creating ingest pipeline" \
  -X PUT "$BASE/_ingest/pipeline/demo-aircraft-adsb.opensky" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/ingest-pipeline.json

run_curl "Creating index template" \
  -X PUT "$BASE/_index_template/demos-aircraft-adsb" \
  -H "Content-Type: application/json" \
  -d @elasticsearch/index-template.json

run_curl "Importing Kibana saved objects (dashboards, data views)" \
  -X POST "$KB_BASE/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  -F "file=@elasticsearch/adsb-saved-objects.ndjson"

echo ""
echo "Elasticsearch setup complete."
