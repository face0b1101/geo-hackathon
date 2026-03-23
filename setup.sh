#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------

FORCE=false
SKIP_SERVICE_USER=false
SELECTED_GROUPS=""
ALL_GROUPS="space ilm indices enrich pipelines kibana cases workflows agents"

usage() {
  cat <<EOF
Usage: ./setup.sh [OPTIONS]

Set up Elasticsearch indices, enrich policies, pipelines, Kibana objects,
AI agents, and workflows for the ADS-B demo.

By default, the script creates a dedicated 'adsb-automation' service user
and mints an API key owned by that user, so all deployed resources (alert
rules, workflows, agents) are attributed to the service identity rather
than the human operator. Use --no-service-user to skip this.

If KB_SPACE is set in .env, the Kibana space is created automatically with
the Observability solution view, and all Kibana resources are deployed
into that space.

The service-user step always runs first (unless --no-service-user is passed),
even when --only is used to select a subset of groups.

Options:
  --only GROUP[,GROUP]  Run only the specified groups (comma-separated).
                        Available groups: ${ALL_GROUPS}
  --force               Overwrite existing resources instead of skipping them.
  --no-service-user     Skip service user creation; run everything under the
                        original API key from .env.
  --help                Show this help message.

Examples:
  ./setup.sh                         Run all groups (skip existing by default)
  ./setup.sh --only agents,workflows Re-deploy agents and workflows only
  ./setup.sh --only kibana --force   Reset dashboards to source-controlled versions
  ./setup.sh --force                 Overwrite everything
  ./setup.sh --no-service-user       Run all groups without service user
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --only)  SELECTED_GROUPS="$2"; shift 2 ;;
    --no-service-user) SKIP_SERVICE_USER=true; shift ;;
    --help)  usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$SELECTED_GROUPS" ]]; then
  SELECTED_GROUPS="$ALL_GROUPS"
else
  SELECTED_GROUPS="${SELECTED_GROUPS//,/ }"
  for g in $SELECTED_GROUPS; do
    if ! echo "$ALL_GROUPS" | grep -qw "$g"; then
      echo "ERROR: Unknown group '$g'. Available: $ALL_GROUPS" >&2
      exit 1
    fi
  done
fi

group_enabled() { echo "$SELECTED_GROUPS" | grep -qw "$1"; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

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

BASE="${ES_ENDPOINT%/}"
KB_BASE="${KB_ENDPOINT%/}"
KB_BASE_NO_SPACE="$KB_BASE"
[[ -n "${KB_SPACE:-}" ]] && KB_BASE="${KB_BASE}/s/${KB_SPACE}"

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  echo "Install it: https://jqlang.github.io/jq/download/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step counting
# ---------------------------------------------------------------------------

group_step_count() {
  case "$1" in
    space) echo 1 ;;  ilm)       echo 1 ;;
    indices) echo 9 ;; enrich)   echo 4 ;;
    pipelines) echo 2 ;; kibana) echo 1 ;;
    cases) echo 1 ;;  agents)    echo 3 ;;
    workflows) echo 19 ;;
    *) echo 0 ;;
  esac
}

TOTAL=0
for g in $SELECTED_GROUPS; do
  TOTAL=$((TOTAL + $(group_step_count "$g")))
done
[[ "$SKIP_SERVICE_USER" == "false" ]] && TOTAL=$((TOTAL + 1))

STEP=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

step_label() {
  STEP=$((STEP + 1))
  echo "[$STEP/$TOTAL] $1 ..."
}

curl_es() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" "$@"
}

curl_kb() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" "$@"
}

curl_kb_wf() {
  curl -s -w '\n%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" "$@"
}

parse_response() {
  local body http_code
  body=$(sed '$d' <<< "$1")
  http_code=$(tail -1 <<< "$1")
  echo "$body"
  return 0
}

http_code_of() {
  tail -1 <<< "$1"
}

run_curl() {
  local label="$1"; shift
  step_label "$label"

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

ndjson_doc_count() {
  local lines
  lines=$(wc -l < "$1" | tr -d ' ')
  echo $((lines / 2))
}

index_doc_count() {
  local resp
  resp=$(curl_es -X GET "$BASE/$1/_count" 2>/dev/null || echo '{"count":-1}')
  local body
  body=$(parse_response "$resp")
  echo "$body" | jq -r '.count // -1' 2>/dev/null || echo "-1"
}

# ---------------------------------------------------------------------------
# Group: serviceuser
# ---------------------------------------------------------------------------

setup_serviceuser() {
  step_label "Creating service user 'adsb-automation'"

  local svc_user="adsb-automation"
  local svc_role="adsb-automation"
  local svc_pass
  svc_pass="$(openssl rand -base64 32)"

  local role_payload='{
    "cluster": ["manage", "manage_security"],
    "indices": [
      {
        "names": ["geo.shapes-world.countries-50m", "adsb*", "demos-aircraft-adsb*"],
        "privileges": ["create_index", "write", "read", "view_index_metadata", "manage"]
      }
    ],
    "applications": [
      {
        "application": "kibana-.kibana",
        "privileges": ["all"],
        "resources": ["*"]
      }
    ]
  }'

  # Create role
  local role_tmp role_http
  role_tmp=$(mktemp)
  role_http=$(curl -s -w '%{http_code}' -o "$role_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_security/role/$svc_role" \
    -H "Content-Type: application/json" \
    -d "$role_payload")

  if [[ "$role_http" == "400" || "$role_http" == "404" ]]; then
    echo "  Skipped — native roles not supported on this deployment (HTTP $role_http)"
    echo "  Workflow actions will be attributed to the .env API key owner"
    rm -f "$role_tmp"
    return 0
  elif [[ "$role_http" == "403" ]]; then
    echo "  Skipped — API key lacks manage_security privilege (HTTP 403)"
    echo "  Regenerate the API key with manage_security to enable service user creation."
    echo "  See README.md 'Generate an API Key' for the updated role descriptor."
    echo "  Continuing with the original API key."
    rm -f "$role_tmp"
    return 0
  elif [[ "$role_http" -lt 200 || "$role_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $role_http): Could not create service role." >&2
    cat "$role_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$role_tmp"
    return 0
  fi
  rm -f "$role_tmp"

  # Create user with the role
  local user_tmp user_http
  user_tmp=$(mktemp)
  user_http=$(curl -s -w '%{http_code}' -o "$user_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_security/user/$svc_user" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg pw "$svc_pass" --arg role "$svc_role" '{
      password: $pw,
      full_name: "ADS-B Automation",
      email: "adsb-automation@noreply.local",
      roles: [$role]
    }')")

  if [[ "$user_http" -lt 200 || "$user_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $user_http): Could not create service user." >&2
    cat "$user_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$user_tmp"
    return 0
  fi
  rm -f "$user_tmp"

  # Mint API key as the service user (inherits role privileges)
  local key_tmp key_http
  key_tmp=$(mktemp)
  key_http=$(curl -s -w '%{http_code}' -o "$key_tmp" \
    -u "${svc_user}:${svc_pass}" \
    -X POST "$BASE/_security/api_key" \
    -H "Content-Type: application/json" \
    -d '{"name": "adsb-automation-session", "expiration": "7d"}')

  if [[ "$key_http" -lt 200 || "$key_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $key_http): Could not mint API key for service user." >&2
    cat "$key_tmp" >&2
    echo "  Continuing with the original API key." >&2
    rm -f "$key_tmp"
    return 0
  fi

  local new_encoded
  new_encoded=$(jq -r '.encoded // empty' < "$key_tmp" 2>/dev/null)
  rm -f "$key_tmp"

  if [[ -z "$new_encoded" ]]; then
    echo "  WARNING: API key response missing 'encoded' field." >&2
    echo "  Continuing with the original API key." >&2
    return 0
  fi

  ES_API_KEY_ENCODED="$new_encoded"
  echo "  Using service user 'adsb-automation' for all subsequent operations"
}

# ---------------------------------------------------------------------------
# Group: space
# ---------------------------------------------------------------------------

setup_space() {
  if [[ -z "${KB_SPACE:-}" ]]; then
    step_label "Skipping space creation (KB_SPACE not set)"
    echo "  Using default space"
    return 0
  fi

  step_label "Creating Kibana space '${KB_SPACE}'"

  local space_check_code
  space_check_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    "$KB_BASE_NO_SPACE/api/spaces/space/$KB_SPACE")

  if [[ "$space_check_code" == "200" ]]; then
    echo "  Already exists — skipping"
  else
    local icon_b64=""
    local icon_file="$SCRIPT_DIR/data/adsb-space-icon-64.png"
    if [[ -f "$icon_file" ]]; then
      icon_b64=$(base64 < "$icon_file" | tr -d '\n')
    fi

    local space_payload
    space_payload=$(jq -n \
      --arg id "$KB_SPACE" \
      --arg name "ADS-B" \
      --arg desc "ADS-B flight tracking demo" \
      --arg icon "$icon_b64" \
      '{id: $id, name: $name, description: $desc, solution: "oblt", color: "#0077CC", initials: "AB"} +
       (if $icon != "" then {imageUrl: ("data:image/png;base64," + $icon)} else {} end)')

    local space_tmp space_http
    space_tmp=$(mktemp)
    space_http=$(curl -s -w '%{http_code}' -o "$space_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE_NO_SPACE/api/spaces/space" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "$space_payload")

    if [[ "$space_http" -lt 200 || "$space_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $space_http): Could not create space." >&2
      cat "$space_tmp" >&2
      echo "  Create it manually: Kibana > Stack Management > Spaces" >&2
    else
      echo "  Created (HTTP $space_http)"
    fi
    rm -f "$space_tmp"
  fi

}

# ---------------------------------------------------------------------------
# Group: ilm
# ---------------------------------------------------------------------------

setup_ilm() {
  step_label "Creating ILM policy 'adsb-lifecycle'"

  local tmp_file http_code
  tmp_file=$(mktemp)
  http_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X PUT "$BASE/_ilm/policy/adsb-lifecycle" \
    -H "Content-Type: application/json" \
    -d @elasticsearch/indices/adsb-ilm-policy.json)

  if [[ "$http_code" == "400" || "$http_code" == "404" ]]; then
    echo "  Skipped — ILM not available on this deployment (HTTP $http_code)"
    echo "  Data stream lifecycle (data_retention: 730d) will manage retention instead"
  elif [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $http_code):" >&2
    cat "$tmp_file" >&2
    rm -f "$tmp_file"
    exit 1
  else
    echo "  OK (HTTP $http_code)"
  fi
  rm -f "$tmp_file"
}

# ---------------------------------------------------------------------------
# Group: indices
# ---------------------------------------------------------------------------

setup_index() {
  local index_name="$1" mapping_file="$2" data_file="$3" label="$4"

  step_label "Creating $label index"

  local head_code
  head_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -I "$BASE/$index_name")

  if [[ "$head_code" == "200" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Index exists — deleting (--force)"
      curl_es -X DELETE "$BASE/$index_name" > /dev/null 2>&1
      local tmpfile
      tmpfile=$(mktemp)
      local create_code
      create_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$BASE/$index_name" \
        -H "Content-Type: application/json" \
        -d "@$mapping_file")
      if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
        echo "  FAILED (HTTP $create_code):" >&2
        cat "$tmpfile" >&2
        rm -f "$tmpfile"
        exit 1
      fi
      echo "  Recreated (HTTP $create_code)"
      rm -f "$tmpfile"
    else
      echo "  Already exists — skipping creation"
    fi
  else
    local tmpfile
    tmpfile=$(mktemp)
    local create_code
    create_code=$(curl -s -w '%{http_code}' -o "$tmpfile" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$BASE/$index_name" \
      -H "Content-Type: application/json" \
      -d "@$mapping_file")
    if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
      echo "  FAILED (HTTP $create_code):" >&2
      cat "$tmpfile" >&2
      rm -f "$tmpfile"
      exit 1
    fi
    echo "  Created (HTTP $create_code)"
    rm -f "$tmpfile"
  fi

  step_label "Loading $label reference data"

  if [[ "$FORCE" == "true" ]]; then
    echo "  Loading unconditionally (--force)"
  else
    local expected actual
    expected=$(ndjson_doc_count "$data_file")
    actual=$(index_doc_count "$index_name")
    if [[ "$actual" == "$expected" ]]; then
      echo "  Reference data already loaded ($actual documents) — skipping"
      step_label "Refreshing $label index"
      echo "  Skipped (data unchanged)"
      return 0
    fi
    echo "  Document count differs (index: $actual, file: $expected) — reloading"
  fi

  local bulk_tmp bulk_code
  bulk_tmp=$(mktemp)
  bulk_code=$(curl -s -w '%{http_code}' -o "$bulk_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/$index_name/_bulk" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary "@$data_file")

  if [[ "$bulk_code" -lt 200 || "$bulk_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $bulk_code):" >&2
    cat "$bulk_tmp" >&2
    rm -f "$bulk_tmp"
    exit 1
  fi
  echo "  OK (HTTP $bulk_code)"
  rm -f "$bulk_tmp"

  step_label "Refreshing $label index"
  local ref_tmp ref_code
  ref_tmp=$(mktemp)
  ref_code=$(curl -s -w '%{http_code}' -o "$ref_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/$index_name/_refresh")
  if [[ "$ref_code" -lt 200 || "$ref_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $ref_code):" >&2
    cat "$ref_tmp" >&2
    rm -f "$ref_tmp"
    exit 1
  fi
  echo "  OK (HTTP $ref_code)"
  rm -f "$ref_tmp"
}

setup_indices() {
  setup_index \
    "geo.shapes-world.countries-50m" \
    "elasticsearch/indices/geo-shapes-world-countries-50m-mapping.json" \
    "data/geo-shapes-world-countries-50m-data.json" \
    "geo shapes"

  setup_index \
    "adsb-airports-geo" \
    "elasticsearch/indices/adsb-airports-geo-mapping.json" \
    "data/adsb-airports-geo-data.ndjson" \
    "airports"

  setup_index \
    "adsb-airlines-defunct" \
    "elasticsearch/indices/adsb-airlines-defunct-mapping.json" \
    "data/adsb-airlines-defunct-data.ndjson" \
    "defunct airlines"
}

# ---------------------------------------------------------------------------
# Group: enrich
# ---------------------------------------------------------------------------

exec_enrich_policy() {
  local policy_name="$1"
  local exec_tmp exec_code
  exec_tmp=$(mktemp)
  exec_code=$(curl -s -w '%{http_code}' -o "$exec_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$BASE/_enrich/policy/$policy_name/_execute")
  if [[ "$exec_code" -lt 200 || "$exec_code" -ge 300 ]]; then
    echo "  FAILED (HTTP $exec_code):" >&2
    cat "$exec_tmp" >&2
    rm -f "$exec_tmp"
    exit 1
  fi
  echo "  OK (HTTP $exec_code)"
  rm -f "$exec_tmp"
}

setup_enrich_policy() {
  local policy_name="$1" policy_file="$2" label="$3"

  step_label "Creating $label enrich policy"

  local check_resp check_code check_body policy_exists=false
  check_resp=$(curl_es -X GET "$BASE/_enrich/policy/$policy_name" 2>/dev/null)
  check_code=$(http_code_of "$check_resp")
  check_body=$(parse_response "$check_resp")
  if [[ "$check_code" == "200" ]]; then
    local policy_count
    policy_count=$(echo "$check_body" | jq -r '.policies | length' 2>/dev/null || echo "0")
    [[ "$policy_count" -gt 0 ]] && policy_exists=true
  fi

  if [[ "$policy_exists" == "true" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Policy exists — attempting delete (--force)"
      local del_tmp del_code
      del_tmp=$(mktemp)
      del_code=$(curl -s -w '%{http_code}' -o "$del_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X DELETE "$BASE/_enrich/policy/$policy_name")
      if [[ "$del_code" -ge 200 && "$del_code" -lt 300 ]]; then
        echo "  Deleted — recreating"
        rm -f "$del_tmp"
      else
        echo "  Could not delete (HTTP $del_code, likely referenced by a pipeline) — re-executing instead"
        rm -f "$del_tmp"
        step_label "Executing $label enrich policy"
        exec_enrich_policy "$policy_name"
        return 0
      fi
    else
      echo "  Already exists — skipping creation"
    fi
  fi

  if [[ "$policy_exists" != "true" ]] || [[ "$FORCE" == "true" ]]; then
    local tmp_file create_code
    tmp_file=$(mktemp)
    create_code=$(curl -s -w '%{http_code}' -o "$tmp_file" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$BASE/_enrich/policy/$policy_name" \
      -H "Content-Type: application/json" \
      -d "@$policy_file")

    if [[ "$create_code" -lt 200 || "$create_code" -ge 300 ]]; then
      echo "  FAILED (HTTP $create_code):" >&2
      cat "$tmp_file" >&2
      rm -f "$tmp_file"
      exit 1
    fi
    echo "  OK (HTTP $create_code)"
    rm -f "$tmp_file"
  fi

  step_label "Executing $label enrich policy"
  exec_enrich_policy "$policy_name"
}

setup_enrich() {
  setup_enrich_policy \
    "opensky-geo-enrich-50m" \
    "elasticsearch/enrich/adsb-geo-enrich-policy.json" \
    "geo-shape"

  setup_enrich_policy \
    "adsb-airport-proximity" \
    "elasticsearch/enrich/adsb-airport-enrich-policy.json" \
    "airport proximity"
}

# ---------------------------------------------------------------------------
# Group: pipelines
# ---------------------------------------------------------------------------

setup_pipelines() {
  run_curl "Creating ingest pipeline" \
    -X PUT "$BASE/_ingest/pipeline/demo-aircraft-adsb.opensky" \
    -H "Content-Type: application/json" \
    -d @elasticsearch/pipelines/adsb-ingest-pipeline.json

  run_curl "Creating index template" \
    -X PUT "$BASE/_index_template/demos-aircraft-adsb" \
    -H "Content-Type: application/json" \
    -d @elasticsearch/indices/adsb-index-template.json
}

# ---------------------------------------------------------------------------
# Group: kibana
# ---------------------------------------------------------------------------

setup_kibana() {
  STEP=$((STEP + 1))

  local overwrite_param=""
  if [[ "$FORCE" == "true" ]]; then
    overwrite_param="?overwrite=true"
    echo "[$STEP/$TOTAL] Importing Kibana saved objects (--force: overwriting existing) ..."
  else
    echo "[$STEP/$TOTAL] Importing Kibana saved objects ..."
  fi

  local import_tmp import_http
  import_tmp=$(mktemp)
  import_http=$(curl -s -w '%{http_code}' -o "$import_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/saved_objects/_import${overwrite_param}" \
    -H "kbn-xsrf: true" \
    -F "file=@elasticsearch/kibana/adsb-saved-objects.ndjson")

  if [[ "$import_http" -lt 200 || "$import_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $import_http):" >&2
    cat "$import_tmp" >&2
    rm -f "$import_tmp"
    exit 1
  fi

  local import_success
  import_success=$(jq -r '.success // true' < "$import_tmp" || echo "True")

  if [[ "$import_success" == "False" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  PARTIAL FAILURE (HTTP $import_http):" >&2
      jq -r '
        "  \(.successCount // 0) objects imported, \(.errors // [] | length) failed:",
        (.errors // [] | .[] |
          "    - \(.type) \"\(.meta.title // "?")\": \(.error.type // "?") (refs: \(.error.references // [] | [.[].id // "?"] | join(", ")))")
      ' < "$import_tmp" >&2
      rm -f "$import_tmp"
      exit 1
    else
      local ok_count skipped_count
      ok_count=$(jq -r '.successCount // 0' < "$import_tmp" 2>/dev/null || echo "0")
      skipped_count=$(jq -r '.errors // [] | length' < "$import_tmp" 2>/dev/null || echo "0")
      echo "  OK (HTTP $import_http) — $ok_count imported, $skipped_count skipped (already exist)"
      rm -f "$import_tmp"
      return 0
    fi
  fi

  echo "  OK (HTTP $import_http) — $(jq -r '.successCount // "?"' < "$import_tmp" || echo "?") objects imported"
  rm -f "$import_tmp"
}

# ---------------------------------------------------------------------------
# Group: cases
# ---------------------------------------------------------------------------

setup_cases() {
  step_label "Configuring case custom fields and templates"

  local config_file="elasticsearch/cases/observability-config.json"

  # Check for existing case configuration for the observability owner
  local cfg_tmp cfg_http
  cfg_tmp=$(mktemp)
  cfg_http=$(curl -s -w '%{http_code}' -o "$cfg_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -X GET "$KB_BASE/api/cases/configure?owner=observability")

  if [[ "$cfg_http" -lt 200 || "$cfg_http" -ge 300 ]]; then
    echo "  WARNING (HTTP $cfg_http): Could not query case configuration." >&2
    cat "$cfg_tmp" >&2
    rm -f "$cfg_tmp"
    return 0
  fi

  local existing_id existing_version
  existing_id=$(jq -r '.[0].id // empty' < "$cfg_tmp" 2>/dev/null || true)
  existing_version=$(jq -r '.[0].version // empty' < "$cfg_tmp" 2>/dev/null || true)

  if [[ -n "$existing_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Configuration exists — updating (--force)"
      local patch_payload
      patch_payload=$(jq --arg ver "$existing_version" '{
        version: $ver,
        customFields: .customFields,
        templates: .templates
      }' "$config_file")

      local patch_tmp patch_http
      patch_tmp=$(mktemp)
      patch_http=$(curl -s -w '%{http_code}' -o "$patch_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -X PATCH "$KB_BASE/api/cases/configure/$existing_id" \
        -d "$patch_payload")

      if [[ "$patch_http" -lt 200 || "$patch_http" -ge 300 ]]; then
        echo "  WARNING (HTTP $patch_http): Could not update case configuration." >&2
        cat "$patch_tmp" >&2
      else
        echo "  Updated (HTTP $patch_http)"
      fi
      rm -f "$patch_tmp"
    else
      echo "  Already exists — skipping"
    fi
  else
    echo "  Creating case configuration ..."
    local create_tmp create_http
    create_tmp=$(mktemp)
    create_http=$(curl -s -w '%{http_code}' -o "$create_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/cases/configure" \
      -d "@$config_file")

    if [[ "$create_http" -lt 200 || "$create_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $create_http): Could not create case configuration." >&2
      cat "$create_tmp" >&2
      echo "  Configure it manually in Kibana > Cases > Settings." >&2
    else
      echo "  Created (HTTP $create_http)"
    fi
    rm -f "$create_tmp"
  fi

  rm -f "$cfg_tmp"
}

# ---------------------------------------------------------------------------
# Group: agents
# ---------------------------------------------------------------------------

deploy_agent() {
  local agent_id="$1" agent_file="$2" label="$3"

  step_label "Deploying $label"

  if [[ "$FORCE" == "true" ]]; then
    local agent_tmp agent_http
    agent_tmp=$(mktemp)
    agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/agent_builder/agents/$agent_id" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "@$agent_file")

    if [[ "$agent_http" == "404" ]]; then
      agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X POST "$KB_BASE/api/agent_builder/agents" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "$(jq --arg id "$agent_id" '. + {id: $id}' "$agent_file")")
    fi

    if [[ "$agent_http" -lt 200 || "$agent_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $agent_http):" >&2
      cat "$agent_tmp" >&2
      rm -f "$agent_tmp"
      exit 1
    fi
    echo "  OK (HTTP $agent_http)"
    rm -f "$agent_tmp"
  else
    local agent_tmp agent_http
    agent_tmp=$(mktemp)
    agent_http=$(curl -s -w '%{http_code}' -o "$agent_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/agent_builder/agents" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -d "$(jq --arg id "$agent_id" '. + {id: $id}' "$agent_file")")

    if [[ "$agent_http" -ge 200 && "$agent_http" -lt 300 ]]; then
      echo "  Created (HTTP $agent_http)"
    elif [[ "$agent_http" == "409" ]] || { [[ "$agent_http" == "400" ]] && grep -q "already exists" "$agent_tmp"; }; then
      echo "  Already exists — skipping"
    else
      echo "  FAILED (HTTP $agent_http):" >&2
      cat "$agent_tmp" >&2
      rm -f "$agent_tmp"
      exit 1
    fi
    rm -f "$agent_tmp"
  fi
}

setup_agents() {
  # Extract dashboard IDs for agent instruction placeholders
  local DASHBOARD_AIRCRAFT_DETAIL_ID DASHBOARD_WORLD_OVERVIEW_ID
  DASHBOARD_AIRCRAFT_DETAIL_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft Detail") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)
  DASHBOARD_WORLD_OVERVIEW_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft World Overview") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)

  # ADS-B agent needs KB_ENDPOINT and dashboard IDs substituted into instructions
  local adsb_agent_tmp
  adsb_agent_tmp=$(mktemp)
  sed -e "s|__KB_ENDPOINT__|${KB_BASE}|g" \
      -e "s|__DASHBOARD_AIRCRAFT_DETAIL_ID__|${DASHBOARD_AIRCRAFT_DETAIL_ID}|g" \
      -e "s|__DASHBOARD_WORLD_OVERVIEW_ID__|${DASHBOARD_WORLD_OVERVIEW_ID}|g" \
      "elasticsearch/agents/adsb-agent.json" > "$adsb_agent_tmp"

  deploy_agent \
    "adsb_agent" \
    "$adsb_agent_tmp" \
    "ADS-B tracking agent"
  rm -f "$adsb_agent_tmp"

  deploy_agent \
    "adsb_daily_briefing_agent" \
    "elasticsearch/agents/adsb-daily-briefing-agent.json" \
    "daily briefing agent"

  deploy_agent \
    "adsb_hijack_assessment_agent" \
    "elasticsearch/agents/adsb-hijack-assessment-agent.json" \
    "hijack assessment agent"
}

# ---------------------------------------------------------------------------
# Group: workflows
# ---------------------------------------------------------------------------

setup_workflows() {
  # --- Extract dashboard IDs from ndjson (used in workflow placeholders + alert rule) ---
  local DASHBOARD_WORLD_OVERVIEW_ID DASHBOARD_AIRCRAFT_DETAIL_ID
  DASHBOARD_WORLD_OVERVIEW_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft World Overview") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)
  DASHBOARD_AIRCRAFT_DETAIL_ID=$(jq -r \
    'select(.type == "dashboard" and .attributes.title == "Aircraft Detail") | .id' \
    elasticsearch/kibana/adsb-saved-objects.ndjson | head -1)

  # --- Create Slack connector (conditional) ---
  step_label "Configuring Slack connector"

  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    local slack_check slack_check_code
    local slack_connector_id="d85ca362-fb82-56f6-867c-4ef2c356d912"
    slack_check=$(curl_kb -X GET "$KB_BASE/api/actions/connector/$slack_connector_id" 2>/dev/null)
    slack_check_code=$(http_code_of "$slack_check")

    if [[ "$slack_check_code" == "200" ]]; then
      if [[ "$FORCE" == "true" ]]; then
        echo "  Connector exists — updating (--force)"
        local slack_tmp slack_http
        slack_tmp=$(mktemp)
        slack_http=$(curl -s -w '%{http_code}' -o "$slack_tmp" \
          -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
          -X PUT "$KB_BASE/api/actions/connector/$slack_connector_id" \
          -H "kbn-xsrf: true" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg url "$SLACK_WEBHOOK_URL" '{name: "ADS-B Daily Briefing", secrets: {webhookUrl: $url}}')")
        if [[ "$slack_http" -lt 200 || "$slack_http" -ge 300 ]]; then
          echo "  WARNING (HTTP $slack_http): Could not update Slack connector." >&2
          cat "$slack_tmp" >&2
        else
          echo "  Updated (HTTP $slack_http)"
        fi
        rm -f "$slack_tmp"
      else
        echo "  Already exists — skipping"
      fi
    else
      echo "  Creating Slack connector ..."
      local slack_tmp slack_http
      slack_tmp=$(mktemp)
      slack_http=$(curl -s -w '%{http_code}' -o "$slack_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X POST "$KB_BASE/api/actions/connector/$slack_connector_id" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg url "$SLACK_WEBHOOK_URL" '{connector_type_id: ".slack", name: "ADS-B Daily Briefing", secrets: {webhookUrl: $url}}')")
      if [[ "$slack_http" -lt 200 || "$slack_http" -ge 300 ]]; then
        echo "  WARNING (HTTP $slack_http): Could not create Slack connector." >&2
        echo "  Configure it manually in Kibana > Stack Management > Connectors." >&2
        cat "$slack_tmp" >&2
      else
        echo "  Created (HTTP $slack_http)"
      fi
      rm -f "$slack_tmp"
    fi
  else
    echo "  Skipped (SLACK_WEBHOOK_URL not set)"
    echo "  To enable Slack notifications, add SLACK_WEBHOOK_URL to .env"
    echo "  or create the connector manually in Kibana > Stack Management > Connectors."
  fi

  # --- Create squawk 7500 alerting rule ---
  step_label "Creating squawk 7500 alerting rule"

  # Pre-resolve the hijack workflow ID so we can wire the action at create time
  local hijack_wf_id_for_rule=""
  local _pre_wf_tmp
  _pre_wf_tmp=$(mktemp)
  if curl -s -w '%{http_code}' -o "$_pre_wf_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -X POST "$KB_BASE/api/workflows/search" \
    -d '{"query":"Squawk 7500 Hijack Investigation"}' 2>/dev/null | grep -q '^2'; then
    hijack_wf_id_for_rule=$(jq -r '(.workflows // .results // [])[] | select(.name == "Squawk 7500 Hijack Investigation") | .id' < "$_pre_wf_tmp" 2>/dev/null | head -1 || true)
  fi
  rm -f "$_pre_wf_tmp"
  if [[ -n "$hijack_wf_id_for_rule" ]]; then
    echo "  Resolved workflow ID for action: $hijack_wf_id_for_rule"
  else
    echo "  Workflow not yet deployed — rule will be created without workflow action"
  fi

  local rule_id="7500a1e7-cafe-4bee-b500-deadbeef7500"
  local rule_needs_create=true

  local rule_check rule_check_code
  rule_check=$(curl_kb -X GET "$KB_BASE/api/alerting/rule/$rule_id" 2>/dev/null)
  rule_check_code=$(http_code_of "$rule_check")

  if [[ "$rule_check_code" == "200" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Rule exists — recreating (--force)"
      curl_kb -X DELETE "$KB_BASE/api/alerting/rule/$rule_id" > /dev/null 2>&1
    else
      echo "  Already exists — skipping"
      rule_needs_create=false
    fi
  fi

  if [[ "$rule_needs_create" == "true" ]]; then
    local rule_payload
    local esql_query='FROM demos-aircraft-adsb | WHERE squawk == "7500" | KEEP @timestamp, icao24, callsign, squawk, origin_country, latitude, longitude, baro_altitude, velocity, true_track, vertical_rate, on_ground, geo_altitude | LIMIT 100'
    rule_payload=$(jq -n --arg esql "$esql_query" --arg wf_id "$hijack_wf_id_for_rule" --arg dash_id "$DASHBOARD_AIRCRAFT_DETAIL_ID" '{
      name: "Squawk 7500 \u2014 Hijack Detection",
      rule_type_id: ".es-query",
      consumer: "observability",
      enabled: true,
      schedule: {interval: "5m"},
      tags: ["adsb","squawk-7500","hijack"],
      params: {
        searchType: "esqlQuery",
        esqlQuery: {esql: $esql},
        timeField: "@timestamp",
        threshold: [0],
        thresholdComparator: ">",
        timeWindowSize: 5,
        timeWindowUnit: "m",
        size: 100,
        groupBy: "row"
      },
      artifacts: {
        dashboards: [
          {id: $dash_id}
        ]
      },
      actions: (if $wf_id != "" then [
        {
          id: "system-connector-.workflows",
          params: {
            subActionParams: {
              workflowId: $wf_id,
              summaryMode: false
            },
            subAction: "run"
          }
        }
      ] else [] end)
    }')

    local rule_tmp rule_http
    rule_tmp=$(mktemp)
    rule_http=$(curl -s -w '%{http_code}' -o "$rule_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X POST "$KB_BASE/api/alerting/rule/$rule_id" \
      -d "$rule_payload")

    if [[ "$rule_http" -lt 200 || "$rule_http" -ge 300 ]]; then
      echo "  WARNING (HTTP $rule_http): Could not create alerting rule." >&2
      cat "$rule_tmp" >&2
      echo "  Create it manually in Kibana > Stack Management > Rules." >&2
    else
      echo "  OK (HTTP $rule_http)"
    fi
    rm -f "$rule_tmp"
  fi

  # --- Deploy daily flight briefing workflow ---
  step_label "Deploying daily flight briefing workflow"

  local workflow_yaml
  local _wf_yaml_content _wf_name
  local _space_prefix=""
  [[ -n "${KB_SPACE:-}" ]] && _space_prefix="/s/${KB_SPACE}"
  _wf_yaml_content=$(sed \
    -e "s|__KB_ENDPOINT__|${KB_BASE}|g" \
    -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    -e "s|__SLACK_CONNECTOR_ID__|${SLACK_CONNECTOR_ID:-}|g" \
    -e "s|__DASHBOARD_WORLD_OVERVIEW_ID__|${DASHBOARD_WORLD_OVERVIEW_ID}|g" \
    -e "s|__DASHBOARD_AIRCRAFT_DETAIL_ID__|${DASHBOARD_AIRCRAFT_DETAIL_ID}|g" \
    "elasticsearch/workflows/daily-flight-briefing.yaml")
  _wf_name=$(echo "$_wf_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  workflow_yaml=$(echo "$_wf_yaml_content" | jq -Rs '{yaml: .}')
  workflow_name_json=$(jq -n --arg name "$_wf_name" '{name: $name}')

  local wf_tmp
  wf_tmp=$(mktemp)

  local wf_search_http existing_wf_id=""
  wf_search_http=$(curl -s -w '%{http_code}' -o "$wf_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Daily Flight Briefing", "limit": 1}')

  if [[ "$wf_search_http" -ge 200 && "$wf_search_http" -lt 300 ]]; then
    existing_wf_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Daily Flight Briefing") | .id' < "$wf_tmp" 2>/dev/null | head -1 || true)
  fi

  local wf_http=""
  if [[ -n "$existing_wf_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      wf_http=$(curl -s -w '%{http_code}' -o "$wf_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$workflow_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$workflow_name_json"
    else
      echo "  Already exists — skipping"
      rm -f "$wf_tmp"
    fi
  else
    wf_http=$(curl -s -w '%{http_code}' -o "$wf_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$workflow_yaml")
  fi

  if [[ -n "$wf_http" ]]; then
    if [[ "$wf_http" -lt 200 || "$wf_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $wf_http):" >&2
      cat "$wf_tmp" >&2
      rm -f "$wf_tmp"
      exit 1
    fi

    local wf_id
    wf_id=$(jq -r '.id // empty' < "$wf_tmp" 2>/dev/null || true)

    if [[ -z "$existing_wf_id" && -n "$wf_id" ]]; then
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$workflow_name_json"
    fi

    echo "  OK (HTTP $wf_http) — workflow ID: ${wf_id:-unknown}"
    rm -f "$wf_tmp"
  fi

  # --- Deploy squawk 7500 hijack investigation workflow ---
  step_label "Deploying squawk 7500 hijack investigation workflow"

  local hijack_yaml
  local _hijack_yaml_content _hijack_name
  _hijack_yaml_content=$(sed \
    -e "s|__KB_ENDPOINT__|${KB_BASE}|g" \
    -e "s|__GNEWS_API_KEY__|${GNEWS_API_KEY:-}|g" \
    -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    -e "s|__SLACK_CONNECTOR_ID__|${SLACK_CONNECTOR_ID:-}|g" \
    -e "s|__DASHBOARD_WORLD_OVERVIEW_ID__|${DASHBOARD_WORLD_OVERVIEW_ID}|g" \
    -e "s|__DASHBOARD_AIRCRAFT_DETAIL_ID__|${DASHBOARD_AIRCRAFT_DETAIL_ID}|g" \
    "elasticsearch/workflows/squawk-7500-hijack-investigation.yaml")
  _hijack_name=$(echo "$_hijack_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  hijack_yaml=$(echo "$_hijack_yaml_content" | jq -Rs '{yaml: .}')
  hijack_name_json=$(jq -n --arg name "$_hijack_name" '{name: $name}')

  local hijack_tmp
  hijack_tmp=$(mktemp)

  local hijack_search_http existing_hijack_id=""
  hijack_search_http=$(curl -s -w '%{http_code}' -o "$hijack_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Squawk 7500 Hijack Investigation", "limit": 1}')

  if [[ "$hijack_search_http" -ge 200 && "$hijack_search_http" -lt 300 ]]; then
    existing_hijack_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Squawk 7500 Hijack Investigation") | .id' < "$hijack_tmp" 2>/dev/null | head -1 || true)
  fi

  local hijack_http=""
  if [[ -n "$existing_hijack_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      hijack_http=$(curl -s -w '%{http_code}' -o "$hijack_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hijack_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hijack_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hijack_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hijack_name_json"
    else
      echo "  Already exists — skipping"
      rm -f "$hijack_tmp"
    fi
  else
    hijack_http=$(curl -s -w '%{http_code}' -o "$hijack_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$hijack_yaml")
  fi

  if [[ -n "$hijack_http" ]]; then
    if [[ "$hijack_http" -lt 200 || "$hijack_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $hijack_http):" >&2
      cat "$hijack_tmp" >&2
      rm -f "$hijack_tmp"
      exit 1
    fi

    local hijack_wf_id
    hijack_wf_id=$(jq -r '.id // empty' < "$hijack_tmp" 2>/dev/null || true)

    if [[ -z "$existing_hijack_id" && -n "$hijack_wf_id" ]]; then
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$hijack_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hijack_name_json"
    fi

    echo "  OK (HTTP $hijack_http) — workflow ID: ${hijack_wf_id:-unknown}"
    rm -f "$hijack_tmp"
  fi

  # --- Link squawk 7500 alert rule → hijack investigation workflow ---
  step_label "Linking alert rule to hijack investigation workflow"

  local _resolved_hijack_wf_id="${hijack_wf_id:-$existing_hijack_id}"
  if [[ -z "$_resolved_hijack_wf_id" ]]; then
    echo "  Skipped — workflow ID not available (workflow deployment may have been skipped)"
  elif [[ -n "$hijack_wf_id_for_rule" ]]; then
    echo "  Already wired at rule creation time — no manual step needed"
  else
    # Workflow was deployed after rule creation; add action via API update
    local _link_payload
    _link_payload=$(jq -n --arg wf_id "$_resolved_hijack_wf_id" '{
      actions: [
        {
          id: "system-connector-.workflows",
          params: {
            subActionParams: { workflowId: $wf_id, summaryMode: false },
            subAction: "run"
          }
        }
      ]
    }')
    local _link_http
    _link_http=$(curl -s -w '%{http_code}' -o /dev/null \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -H "kbn-xsrf: true" \
      -H "Content-Type: application/json" \
      -X PUT "$KB_BASE/api/alerting/rule/$rule_id" \
      -d "$_link_payload")
    if [[ "$_link_http" -ge 200 && "$_link_http" -lt 300 ]]; then
      echo "  OK — workflow action added to rule via API"
    else
      local _rule_url="${KB_BASE}/app/management/insightsAndAlerting/triggersActions/rules/edit/${rule_id}"
      echo "  WARNING (HTTP $_link_http): Could not add action via API." >&2
      echo ""
      echo "  ┌──────────────────────────────────────────────────────────────┐"
      echo "  │  MANUAL STEP REQUIRED                                       │"
      echo "  │                                                              │"
      echo "  │  Connect the alert rule to the workflow in the Kibana UI:    │"
      echo "  │                                                              │"
      echo "  │  1. Open the rule:                                           │"
      echo "  │     ${_rule_url}"
      echo "  │  2. Under Actions, click 'Add action'                        │"
      echo "  │  3. Select 'Workflows'                                       │"
      echo "  │  4. Choose 'Squawk 7500 Hijack Investigation'                │"
      echo "  │  5. Set frequency to 'Run per alert'                         │"
      echo "  │  6. Save                                                     │"
      echo "  └──────────────────────────────────────────────────────────────┘"
      echo ""
    fi
  fi

  # --- Deploy squawk 7500 enrich workflow ---
  step_label "Deploying squawk 7500 enrich workflow"

  local enrich_yaml
  local _enrich_yaml_content _enrich_name
  _enrich_yaml_content=$(sed -e "s|__GNEWS_API_KEY__|${GNEWS_API_KEY:-}|g" \
    "elasticsearch/workflows/squawk-7500-enrich.yaml")
  _enrich_name=$(echo "$_enrich_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  enrich_yaml=$(echo "$_enrich_yaml_content" | jq -Rs '{yaml: .}')
  enrich_name_json=$(jq -n --arg name "$_enrich_name" '{name: $name}')

  local enrich_tmp
  enrich_tmp=$(mktemp)

  local enrich_search_http existing_enrich_id=""
  enrich_search_http=$(curl -s -w '%{http_code}' -o "$enrich_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Squawk 7500 Enrich", "limit": 1}')

  if [[ "$enrich_search_http" -ge 200 && "$enrich_search_http" -lt 300 ]]; then
    existing_enrich_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Squawk 7500 Enrich") | .id' < "$enrich_tmp" 2>/dev/null | head -1 || true)
  fi

  local enrich_http=""
  if [[ -n "$existing_enrich_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      enrich_http=$(curl -s -w '%{http_code}' -o "$enrich_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_enrich_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$enrich_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_enrich_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$enrich_name_json"
    else
      echo "  Already exists — skipping"
    fi
  else
    enrich_http=$(curl -s -w '%{http_code}' -o "$enrich_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$enrich_yaml")
  fi

  local enrich_wf_id="${existing_enrich_id:-}"
  if [[ -n "$enrich_http" ]]; then
    if [[ "$enrich_http" -lt 200 || "$enrich_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $enrich_http):" >&2
      cat "$enrich_tmp" >&2
      rm -f "$enrich_tmp"
      exit 1
    fi
    enrich_wf_id=$(jq -r '.id // empty' < "$enrich_tmp" 2>/dev/null || true)

    if [[ -z "$existing_enrich_id" && -n "$enrich_wf_id" ]]; then
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$enrich_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$enrich_name_json"
    fi

    echo "  OK (HTTP $enrich_http) — workflow ID: ${enrich_wf_id:-unknown}"
  fi
  rm -f "$enrich_tmp"

  register_wf_tool "squawk-7500-enrich" "${enrich_wf_id:-}" \
    $'Gathers enrichment data for a squawk 7500 investigation \u2014 flight history from Elasticsearch, aircraft metadata and route from adsbdb, live position from adsb.lol, and GNews news search.\n\nInputs:\n- icao24 (required string): ICAO 24-bit aircraft address\n- callsign (optional string): flight callsign\n\nReturns step outputs: flight_history (ES search), latest_position (ES search), adsbdb_lookup (HTTP), adsblol_lookup (HTTP), news_search (HTTP).\n\nStack 9.3.x workaround: HTTP step outputs may be null. The workflow caches enrichment responses in the adsb-enrichment-cache index. Query by _id: adsbdb:{icao24}, adsbdb_route:{callsign}, adsblol:{icao24}, gnews:{callsign}.\n\nThis is an async workflow \u2014 poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "squawk-7500", "enrichment"]'

  # --- Deploy squawk 7500 create-case workflow ---
  step_label "Deploying squawk 7500 create-case workflow"

  local case_yaml
  local _case_yaml_content _case_name
  _case_yaml_content=$(sed -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    "elasticsearch/workflows/squawk-7500-create-case.yaml")
  _case_name=$(echo "$_case_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  case_yaml=$(echo "$_case_yaml_content" | jq -Rs '{yaml: .}')
  case_name_json=$(jq -n --arg name "$_case_name" '{name: $name}')

  local case_tmp
  case_tmp=$(mktemp)

  local case_search_http existing_case_id=""
  case_search_http=$(curl -s -w '%{http_code}' -o "$case_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Squawk 7500 Create Case", "limit": 1}')

  if [[ "$case_search_http" -ge 200 && "$case_search_http" -lt 300 ]]; then
    existing_case_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Squawk 7500 Create Case") | .id' < "$case_tmp" 2>/dev/null | head -1 || true)
  fi

  local case_http=""
  if [[ -n "$existing_case_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      case_http=$(curl -s -w '%{http_code}' -o "$case_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_case_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$case_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_case_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$case_name_json"
    else
      echo "  Already exists — skipping"
    fi
  else
    case_http=$(curl -s -w '%{http_code}' -o "$case_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$case_yaml")
  fi

  local case_wf_id="${existing_case_id:-}"
  if [[ -n "$case_http" ]]; then
    if [[ "$case_http" -lt 200 || "$case_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $case_http):" >&2
      cat "$case_tmp" >&2
      rm -f "$case_tmp"
      exit 1
    fi
    case_wf_id=$(jq -r '.id // empty' < "$case_tmp" 2>/dev/null || true)

    if [[ -z "$existing_case_id" && -n "$case_wf_id" ]]; then
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$case_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$case_name_json"
    fi

    echo "  OK (HTTP $case_http) — workflow ID: ${case_wf_id:-unknown}"
  fi
  rm -f "$case_tmp"

  register_wf_tool "squawk-7500-create-case" "${case_wf_id:-}" \
    $'Creates or updates a Kibana case for a squawk 7500 investigation with deduplication. If an open case already exists for the aircraft, adds a comment; otherwise creates a new case.\n\nInputs:\n- icao24 (required string): ICAO 24-bit aircraft address\n- callsign (optional string): flight callsign\n- triage_assessment (required string): genuine or false_positive\n- confidence (required string): confidence level \u2014 low, medium, or high\n- reasoning (required string): full assessment reasoning\n\nThis is an async workflow \u2014 poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "squawk-7500", "cases"]'

  # --- Deploy ADS-B aggregate stats workflow ---
  step_label "Deploying ADS-B aggregate stats workflow"

  local agg_yaml
  local _agg_yaml_content _agg_name
  _agg_yaml_content=$(cat "elasticsearch/workflows/adsb-aggregate-stats.yaml")
  _agg_name=$(echo "$_agg_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  agg_yaml=$(echo "$_agg_yaml_content" | jq -Rs '{yaml: .}')
  agg_name_json=$(jq -n --arg name "$_agg_name" '{name: $name}')

  local agg_tmp
  agg_tmp=$(mktemp)

  local agg_search_http existing_agg_id=""
  agg_search_http=$(curl -s -w '%{http_code}' -o "$agg_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "ADS-B Aggregate Stats", "limit": 1}')

  if [[ "$agg_search_http" -ge 200 && "$agg_search_http" -lt 300 ]]; then
    existing_agg_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "ADS-B Aggregate Stats") | .id' < "$agg_tmp" 2>/dev/null | head -1 || true)
  fi

  local agg_http
  if [[ -n "$existing_agg_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      agg_http=$(curl -s -w '%{http_code}' -o "$agg_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_agg_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$agg_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_agg_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$agg_name_json"
    else
      echo "  Already exists — skipping"
      local agg_wf_id="$existing_agg_id"
      register_wf_tool "adsb-aggregate-stats" "$agg_wf_id" \
        $'Aggregates the last 24 hours of ADS-B data from demos-aircraft-adsb. Takes no parameters (fixed now-24h window).\n\nReturned aggregation keys:\n- unique_aircraft: cardinality of icao24\n- busiest_airports: top 10 by airport.iata_code\n- origin_countries: top 10 by origin_country\n- activity_breakdown: terms on airport.activity (arriving, departing, taxiing, overflight, at_airport — airport airspace zone only)\n- traffic_by_subregion: top 15 by geo.SUBREGION\n- traffic_by_continent: top 7 by geo.CONTINENT\n- ground_vs_airborne: terms on on_ground\n- emergency_squawks: named filters for 7500 (hijack), 7600 (radio failure), 7700 (general emergency)\n\nResults are at output.aggregations. Total document count is at hits.total.value. This is an async workflow \u2014 poll with platform.core.get_workflow_execution_status until complete.' \
        '["adsb", "aggregation"]'
      rm -f "$agg_tmp"
      return 0
    fi
  else
    agg_http=$(curl -s -w '%{http_code}' -o "$agg_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$agg_yaml")
  fi

  if [[ "$agg_http" -lt 200 || "$agg_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $agg_http):" >&2
    cat "$agg_tmp" >&2
    rm -f "$agg_tmp"
    exit 1
  fi

  local agg_wf_id
  agg_wf_id=$(jq -r '.id // empty' < "$agg_tmp" 2>/dev/null || true)

  if [[ -z "$existing_agg_id" && -n "$agg_wf_id" ]]; then
    curl -s -o /dev/null \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/workflows/$agg_wf_id" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$agg_name_json"
  fi

  echo "  OK (HTTP $agg_http) — workflow ID: ${agg_wf_id:-unknown}"

  register_wf_tool "adsb-aggregate-stats" "$agg_wf_id" \
    $'Aggregates the last 24 hours of ADS-B data from demos-aircraft-adsb. Takes no parameters (fixed now-24h window).\n\nReturned aggregation keys:\n- unique_aircraft: cardinality of icao24\n- busiest_airports: top 10 by airport.iata_code\n- origin_countries: top 10 by origin_country\n- activity_breakdown: terms on airport.activity (arriving, departing, taxiing, overflight, at_airport — airport airspace zone only)\n- traffic_by_subregion: top 15 by geo.SUBREGION\n- traffic_by_continent: top 7 by geo.CONTINENT\n- ground_vs_airborne: terms on on_ground\n- emergency_squawks: named filters for 7500 (hijack), 7600 (radio failure), 7700 (general emergency)\n\nResults are at output.aggregations. Total document count is at hits.total.value. This is an async workflow \u2014 poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "aggregation"]'
  rm -f "$agg_tmp"

  # --- Deploy aircraft history report workflow ---
  step_label "Deploying aircraft history report workflow"

  local hist_yaml
  local _hist_yaml_content _hist_name
  _hist_yaml_content=$(sed -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    "elasticsearch/workflows/adsb-aircraft-history.yaml")
  _hist_name=$(echo "$_hist_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  hist_yaml=$(echo "$_hist_yaml_content" | jq -Rs '{yaml: .}')
  hist_name_json=$(jq -n --arg name "$_hist_name" '{name: $name}')

  local hist_tmp
  hist_tmp=$(mktemp)

  local hist_search_http existing_hist_id=""
  hist_search_http=$(curl -s -w '%{http_code}' -o "$hist_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "ADS-B Aircraft History Report", "limit": 1}')

  if [[ "$hist_search_http" -ge 200 && "$hist_search_http" -lt 300 ]]; then
    existing_hist_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "ADS-B Aircraft History Report") | .id' < "$hist_tmp" 2>/dev/null | head -1 || true)
  fi

  local hist_http
  if [[ -n "$existing_hist_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      hist_http=$(curl -s -w '%{http_code}' -o "$hist_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hist_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hist_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hist_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hist_name_json"
    else
      echo "  Already exists — skipping"
      local hist_wf_id="$existing_hist_id"
      register_wf_tool "adsb-aircraft-history" "$hist_wf_id" \
        $'Generates a comprehensive history report for an individual aircraft over a configurable time range.\n\nInputs:\n- icao24 (required string): ICAO 24-bit aircraft address (hex, e.g. 406bbb)\n- lookback (optional string, default now-24h): lookback period in ES date math (e.g. now-24h, now-7d, now-48h)\n\nReturned step outputs:\n- flight_summary: aggregations — callsigns (ordered by first_seen, with time windows and airports), airports_visited, countries_overflown, regions, origin_country, altitude_stats, velocity_stats, ground_vs_airborne, squawk_codes, time_range, hourly_activity\n- positions: up to 1000 time-ordered position documents\n- find_cases: Kibana investigation cases tagged with the aircraft icao24\n- adsbdb_aircraft: airframe details (type, registration, operator) from adsbdb\n- adsblol_position: current live position from adsb.lol\n\nStack 9.3.x workaround: HTTP step outputs may be null. The workflow caches enrichment responses in the adsb-enrichment-cache index. Query by _id: adsbdb:{icao24} and adsblol:{icao24}.\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
        '["adsb", "aircraft", "history"]'
      rm -f "$hist_tmp"
      return 0
    fi
  else
    hist_http=$(curl -s -w '%{http_code}' -o "$hist_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$hist_yaml")
  fi

  if [[ "$hist_http" -lt 200 || "$hist_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $hist_http):" >&2
    cat "$hist_tmp" >&2
    rm -f "$hist_tmp"
    exit 1
  fi

  local hist_wf_id
  hist_wf_id=$(jq -r '.id // empty' < "$hist_tmp" 2>/dev/null || true)

  if [[ -z "$existing_hist_id" && -n "$hist_wf_id" ]]; then
    curl -s -o /dev/null \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/workflows/$hist_wf_id" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$hist_name_json"
  fi

  echo "  OK (HTTP $hist_http) — workflow ID: ${hist_wf_id:-unknown}"

  register_wf_tool "adsb-aircraft-history" "$hist_wf_id" \
    $'Generates a comprehensive history report for an individual aircraft over a configurable time range.\n\nInputs:\n- icao24 (required string): ICAO 24-bit aircraft address (hex, e.g. 406bbb)\n- lookback (optional string, default now-24h): lookback period in ES date math (e.g. now-24h, now-7d, now-48h)\n\nReturned step outputs:\n- flight_summary: aggregations — callsigns (ordered by first_seen, with time windows and airports), airports_visited, countries_overflown, regions, origin_country, altitude_stats, velocity_stats, ground_vs_airborne, squawk_codes, time_range, hourly_activity\n- positions: up to 1000 time-ordered position documents\n- find_cases: Kibana investigation cases tagged with the aircraft icao24\n- adsbdb_aircraft: airframe details (type, registration, operator) from adsbdb\n- adsblol_position: current live position from adsb.lol\n\nStack 9.3.x workaround: HTTP step outputs may be null. The workflow caches enrichment responses in the adsb-enrichment-cache index. Query by _id: adsbdb:{icao24} and adsblol:{icao24}.\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "aircraft", "history"]'
  rm -f "$hist_tmp"

  # --- Deploy airport activity report workflow ---
  step_label "Deploying airport activity report workflow"

  local arpt_yaml
  local _arpt_yaml_content _arpt_name
  _arpt_yaml_content=$(sed -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    "elasticsearch/workflows/adsb-airport-activity.yaml")
  _arpt_name=$(echo "$_arpt_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  arpt_yaml=$(echo "$_arpt_yaml_content" | jq -Rs '{yaml: .}')
  arpt_name_json=$(jq -n --arg name "$_arpt_name" '{name: $name}')

  local arpt_tmp
  arpt_tmp=$(mktemp)

  local arpt_search_http existing_arpt_id=""
  arpt_search_http=$(curl -s -w '%{http_code}' -o "$arpt_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "ADS-B Airport Activity Report", "limit": 1}')

  if [[ "$arpt_search_http" -ge 200 && "$arpt_search_http" -lt 300 ]]; then
    existing_arpt_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "ADS-B Airport Activity Report") | .id' < "$arpt_tmp" 2>/dev/null | head -1 || true)
  fi

  local arpt_http
  if [[ -n "$existing_arpt_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      arpt_http=$(curl -s -w '%{http_code}' -o "$arpt_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_arpt_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$arpt_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_arpt_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$arpt_name_json"
    else
      echo "  Already exists — skipping"
      local arpt_wf_id="$existing_arpt_id"
      register_wf_tool "adsb-airport-activity" "$arpt_wf_id" \
        $'Generates a comprehensive airport activity report over a configurable time range using ES|QL.\n\nInputs:\n- airport (required string): airport name, IATA code, or ICAO/GPS code (e.g. LHR, Heathrow, EGLL). The workflow resolves free-text input automatically via case-insensitive matching.\n- lookback (optional string, default 24 hours): lookback period as an ES|QL time interval (e.g. 24 hours, 7 days, 48 hours)\n\nReturned step outputs (ES|QL columnar format — columns + values arrays):\n- resolve_airport: up to 5 matching airports (doc_count, airport.iata_code, airport.name, airport.type, airport.wikipedia)\n- traffic_summary: unique_aircraft, unique_flights, total_obs, first_seen, last_seen\n- activity_breakdown: unique_flights, unique_aircraft by airport.activity\n- hourly_traffic: unique_aircraft by hour\n- top_flights: first_seen, last_seen, origins, activities by callsign (up to 25)\n- origin_countries: unique_aircraft by origin_country (up to 15)\n- emergency_squawks: unique_aircraft by squawk (7500/7600/7700 only)\n- recent_positions: up to 500 recent position observations\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
        '["adsb", "airport", "activity"]'
      rm -f "$arpt_tmp"
    fi
  else
    arpt_http=$(curl -s -w '%{http_code}' -o "$arpt_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$arpt_yaml")
  fi

  if [[ -n "$existing_arpt_id" && "$FORCE" != "true" ]]; then
    : # already handled above (skip branch)
  else
    if [[ "$arpt_http" -lt 200 || "$arpt_http" -ge 300 ]]; then
      echo "  FAILED (HTTP $arpt_http):" >&2
      cat "$arpt_tmp" >&2
      rm -f "$arpt_tmp"
      exit 1
    fi

    local arpt_wf_id
    arpt_wf_id=$(jq -r '.id // empty' < "$arpt_tmp" 2>/dev/null || true)

    if [[ -z "$existing_arpt_id" && -n "$arpt_wf_id" ]]; then
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$arpt_wf_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$arpt_name_json"
    fi

    echo "  OK (HTTP $arpt_http) — workflow ID: ${arpt_wf_id:-unknown}"

    register_wf_tool "adsb-airport-activity" "$arpt_wf_id" \
      $'Generates a comprehensive airport activity report over a configurable time range using ES|QL.\n\nInputs:\n- airport (required string): airport name, IATA code, or ICAO/GPS code (e.g. LHR, Heathrow, EGLL). The workflow resolves free-text input automatically via case-insensitive matching.\n- lookback (optional string, default 24 hours): lookback period as an ES|QL time interval (e.g. 24 hours, 7 days, 48 hours)\n\nReturned step outputs (ES|QL columnar format — columns + values arrays):\n- resolve_airport: up to 5 matching airports (doc_count, airport.iata_code, airport.name, airport.type, airport.wikipedia)\n- traffic_summary: unique_aircraft, unique_flights, total_obs, first_seen, last_seen\n- activity_breakdown: unique_flights, unique_aircraft by airport.activity\n- hourly_traffic: unique_aircraft by hour\n- top_flights: first_seen, last_seen, origins, activities by callsign (up to 25)\n- origin_countries: unique_aircraft by origin_country (up to 15)\n- emergency_squawks: unique_aircraft by squawk (7500/7600/7700 only)\n- recent_positions: up to 500 recent position observations\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
      '["adsb", "airport", "activity"]'
  fi
  rm -f "$arpt_tmp"

  # --- Deploy hijack cases summary workflow ---
  step_label "Deploying hijack cases summary workflow"

  local hcs_yaml
  local _hcs_yaml_content _hcs_name
  _hcs_yaml_content=$(sed -e "s|__SPACE_PREFIX__|${_space_prefix}|g" \
    "elasticsearch/workflows/hijack-cases-summary.yaml")
  _hcs_name=$(echo "$_hcs_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  hcs_yaml=$(echo "$_hcs_yaml_content" | jq -Rs '{yaml: .}')
  hcs_name_json=$(jq -n --arg name "$_hcs_name" '{name: $name}')

  local hcs_tmp
  hcs_tmp=$(mktemp)

  local hcs_search_http existing_hcs_id=""
  hcs_search_http=$(curl -s -w '%{http_code}' -o "$hcs_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Hijack Cases Summary", "limit": 1}')

  if [[ "$hcs_search_http" -ge 200 && "$hcs_search_http" -lt 300 ]]; then
    existing_hcs_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Hijack Cases Summary") | .id' < "$hcs_tmp" 2>/dev/null | head -1 || true)
  fi

  local hcs_http
  if [[ -n "$existing_hcs_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      hcs_http=$(curl -s -w '%{http_code}' -o "$hcs_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hcs_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hcs_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_hcs_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$hcs_name_json"
    else
      echo "  Already exists — skipping"
      local hcs_wf_id="$existing_hcs_id"
      register_wf_tool "hijack-cases-summary" "$hcs_wf_id" \
        $'Fetches squawk 7500 (hijack) investigation cases from Kibana case management. Returns case titles, tags (including triage:genuine or triage:false_positive), status, and creation dates.\n\nUse this to review hijack investigation outcomes — how many were genuine vs false positive. Cases are tagged with triage:genuine or triage:false_positive after AI triage assessment.\n\nResults are at output.cases (array) and output.total (count). This is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
        '["adsb", "squawk-7500", "cases"]'
      rm -f "$hcs_tmp"
      return 0
    fi
  else
    hcs_http=$(curl -s -w '%{http_code}' -o "$hcs_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$hcs_yaml")
  fi

  if [[ "$hcs_http" -lt 200 || "$hcs_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $hcs_http):" >&2
    cat "$hcs_tmp" >&2
    rm -f "$hcs_tmp"
    exit 1
  fi

  local hcs_wf_id
  hcs_wf_id=$(jq -r '.id // empty' < "$hcs_tmp" 2>/dev/null || true)

  if [[ -z "$existing_hcs_id" && -n "$hcs_wf_id" ]]; then
    curl -s -o /dev/null \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/workflows/$hcs_wf_id" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$hcs_name_json"
  fi

  echo "  OK (HTTP $hcs_http) — workflow ID: ${hcs_wf_id:-unknown}"

  register_wf_tool "hijack-cases-summary" "$hcs_wf_id" \
    $'Fetches squawk 7500 (hijack) investigation cases from Kibana case management. Returns case titles, tags (including triage:genuine or triage:false_positive), status, and creation dates.\n\nUse this to review hijack investigation outcomes — how many were genuine vs false positive. Cases are tagged with triage:genuine or triage:false_positive after AI triage assessment.\n\nResults are at output.cases (array) and output.total (count). This is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "squawk-7500", "cases"]'
  rm -f "$hcs_tmp"

  # --- Deploy defunct callsign detector workflow ---
  step_label "Deploying defunct callsign detector workflow"

  local dcd_yaml
  local _dcd_yaml_content _dcd_name
  _dcd_yaml_content=$(cat "elasticsearch/workflows/adsb-defunct-callsign-detector.yaml")
  _dcd_name=$(echo "$_dcd_yaml_content" | grep -m1 '^name:' | sed 's/^name:[[:space:]]*//')
  dcd_yaml=$(echo "$_dcd_yaml_content" | jq -Rs '{yaml: .}')
  dcd_name_json=$(jq -n --arg name "$_dcd_name" '{name: $name}')

  local dcd_tmp
  dcd_tmp=$(mktemp)

  local dcd_search_http existing_dcd_id=""
  dcd_search_http=$(curl -s -w '%{http_code}' -o "$dcd_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/workflows/search" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: kibana" \
    -H "Content-Type: application/json" \
    -d '{"query": "Defunct Callsign Detector", "limit": 1}')

  if [[ "$dcd_search_http" -ge 200 && "$dcd_search_http" -lt 300 ]]; then
    existing_dcd_id=$(jq -r '(.workflows // .results // [])[] | select(.name == "Defunct Callsign Detector") | .id' < "$dcd_tmp" 2>/dev/null | head -1 || true)
  fi

  local dcd_http
  if [[ -n "$existing_dcd_id" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      echo "  Workflow exists — updating (--force)"
      dcd_http=$(curl -s -w '%{http_code}' -o "$dcd_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_dcd_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$dcd_yaml")
      curl -s -o /dev/null \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/workflows/$existing_dcd_id" \
        -H "kbn-xsrf: true" \
        -H "x-elastic-internal-origin: kibana" \
        -H "Content-Type: application/json" \
        -d "$dcd_name_json"
    else
      echo "  Already exists — skipping"
      local dcd_wf_id="$existing_dcd_id"
      register_wf_tool "adsb-defunct-callsign-detector" "$dcd_wf_id" \
        $'Detects aircraft using callsign prefixes matching known defunct airlines. Cross-references ADS-B data against the adsb-airlines-defunct lookup index using ES|QL LOOKUP JOIN.\n\nInputs:\n- lookback (optional string, default 24 hours): lookback period as an ES|QL time interval (e.g. 24 hours, 7 days, 30 days). Max 30 days.\n\nReturns ES|QL columnar output (columns + values) with: callsign_prefix, defunct_airline_name, defunct_country, defunct_icao, operations.ceased.text, aircraft_count, last_seen, callsigns (array), countries (array).\n\nStack 9.3.x workaround: workflow output may be null. The workflow caches results in the adsb-enrichment-cache index with _id: defunct-callsign-detections. Query that document and parse the raw field (JSON string) as a fallback.\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
        '["adsb", "callsign", "defunct"]'
      rm -f "$dcd_tmp"
      return 0
    fi
  else
    dcd_http=$(curl -s -w '%{http_code}' -o "$dcd_tmp" \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X POST "$KB_BASE/api/workflows" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$dcd_yaml")
  fi

  if [[ "$dcd_http" -lt 200 || "$dcd_http" -ge 300 ]]; then
    echo "  FAILED (HTTP $dcd_http):" >&2
    cat "$dcd_tmp" >&2
    rm -f "$dcd_tmp"
    exit 1
  fi

  local dcd_wf_id
  dcd_wf_id=$(jq -r '.id // empty' < "$dcd_tmp" 2>/dev/null || true)

  if [[ -z "$existing_dcd_id" && -n "$dcd_wf_id" ]]; then
    curl -s -o /dev/null \
      -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
      -X PUT "$KB_BASE/api/workflows/$dcd_wf_id" \
      -H "kbn-xsrf: true" \
      -H "x-elastic-internal-origin: kibana" \
      -H "Content-Type: application/json" \
      -d "$dcd_name_json"
  fi

  echo "  OK (HTTP $dcd_http) — workflow ID: ${dcd_wf_id:-unknown}"

  register_wf_tool "adsb-defunct-callsign-detector" "${dcd_wf_id:-}" \
    $'Detects aircraft using callsign prefixes matching known defunct airlines. Cross-references ADS-B data against the adsb-airlines-defunct lookup index using ES|QL LOOKUP JOIN.\n\nInputs:\n- lookback (optional string, default 24 hours): lookback period as an ES|QL time interval (e.g. 24 hours, 7 days, 30 days). Max 30 days.\n\nReturns ES|QL columnar output (columns + values) with: callsign_prefix, defunct_airline_name, defunct_country, defunct_icao, operations.ceased.text, aircraft_count, last_seen, callsigns (array), countries (array).\n\nStack 9.3.x workaround: workflow output may be null. The workflow caches results in the adsb-enrichment-cache index with _id: defunct-callsign-detections. Query that document and parse the raw field (JSON string) as a fallback.\n\nThis is an async workflow — poll with platform.core.get_workflow_execution_status until complete.' \
    '["adsb", "callsign", "defunct"]'
  rm -f "$dcd_tmp"
}

register_wf_tool() {
  local tool_id="$1" wf_id="$2" tool_desc="$3" tags_json="$4"
  [[ -z "$wf_id" ]] && return 0

  step_label "Registering $tool_id workflow tool"

  local tool_payload
  tool_payload=$(jq -n --arg id "$tool_id" --arg desc "$tool_desc" \
    --argjson tags "$tags_json" --arg wf_id "$wf_id" \
    '{id: $id, description: $desc, type: "workflow", tags: $tags, configuration: {workflow_id: $wf_id}}')

  local tool_tmp tool_http
  tool_tmp=$(mktemp)
  tool_http=$(curl -s -w '%{http_code}' -o "$tool_tmp" \
    -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
    -X POST "$KB_BASE/api/agent_builder/tools" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "$tool_payload")

  if [[ "$tool_http" -ge 200 && "$tool_http" -lt 300 ]]; then
    echo "  Workflow tool registered (HTTP $tool_http)"
  elif [[ "$tool_http" == "409" ]] || { [[ "$tool_http" == "400" ]] && grep -q "already exists" "$tool_tmp"; }; then
    if [[ "$FORCE" == "true" ]]; then
      local tool_update_payload
      tool_update_payload=$(echo "$tool_payload" | jq 'del(.id, .type)')
      tool_http=$(curl -s -w '%{http_code}' -o "$tool_tmp" \
        -H "Authorization: ApiKey $ES_API_KEY_ENCODED" \
        -X PUT "$KB_BASE/api/agent_builder/tools/$tool_id" \
        -H "kbn-xsrf: true" \
        -H "Content-Type: application/json" \
        -d "$tool_update_payload")
      if [[ "$tool_http" -ge 200 && "$tool_http" -lt 300 ]]; then
        echo "  Workflow tool updated (HTTP $tool_http)"
      else
        echo "  WARNING: Could not update workflow tool (HTTP $tool_http)" >&2
        cat "$tool_tmp" >&2
      fi
    else
      echo "  Workflow tool already registered — skipping"
    fi
  else
    echo "  WARNING: Could not register workflow tool (HTTP $tool_http)" >&2
    cat "$tool_tmp" >&2
  fi
  rm -f "$tool_tmp"
}

# ---------------------------------------------------------------------------
# Run selected groups
# ---------------------------------------------------------------------------

echo "ADS-B Demo Setup"
echo "Groups: $SELECTED_GROUPS"
[[ "$FORCE" == "true" ]] && echo "Mode: --force (overwriting existing resources)"
[[ -n "${KB_SPACE:-}" ]] && echo "Space: $KB_SPACE"
echo ""

[[ "$SKIP_SERVICE_USER" == "false" ]] && setup_serviceuser
group_enabled "space"     && setup_space
group_enabled "ilm"       && setup_ilm
group_enabled "indices"   && setup_indices
group_enabled "enrich"    && setup_enrich
group_enabled "pipelines" && setup_pipelines
group_enabled "kibana"    && setup_kibana
group_enabled "cases"     && setup_cases
group_enabled "workflows" && setup_workflows
group_enabled "agents"    && setup_agents

echo ""
echo "Setup complete."
