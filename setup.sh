#!/usr/bin/env bash
# Provisions the SIS scheduler in a running Windmill (idempotent: safe to
# re-run; it updates what already exists):
#   workspace  $WM_WORKSPACE (default sis)
#   folder     f/sis
#   variables  f/sis/claim_service_base_url, f/sis/claim_internal_api_key (secret)
#   script     f/sis/claim_outstanding_job   <- windmill/f/sis/claim_outstanding_job.ts
#   schedule   f/sis/claim_outstanding_hourly (0 5 * * * *, Asia/Jakarta)
#
# Usage: ./windmill/setup.sh   (reads windmill/.env; needs curl + jq)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
set -a; source "$DIR/.env"; set +a

: "${WM_URL:?}" "${WM_EMAIL:?}" "${WM_PASSWORD:?}" "${WM_WORKSPACE:?}"
: "${CLAIM_SERVICE_BASE_URL:?}" "${CLAIM_INTERNAL_API_KEY:?set CLAIM_INTERNAL_API_KEY in windmill/.env}"
SCHEDULE_ENABLED="${SCHEDULE_ENABLED:-false}"

API="$WM_URL/api"
W="$API/w/$WM_WORKSPACE"

echo "› login $WM_EMAIL @ $WM_URL"
TOKEN=$(curl -fsS -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$WM_EMAIL" --arg p "$WM_PASSWORD" '{email:$e,password:$p}')")
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')

get()  { curl -fsS "${AUTH[@]}" "$1"; }
post() { curl -fsS "${AUTH[@]}" -X POST "$1" -d "$2" >/dev/null; }

# --- workspace -------------------------------------------------------------
if [ "$(curl -fsS "${AUTH[@]}" -X POST "$API/workspaces/exists" -d "{\"id\":\"$WM_WORKSPACE\"}")" = "true" ]; then
  echo "✓ workspace $WM_WORKSPACE exists"
else
  post "$API/workspaces/create" "{\"id\":\"$WM_WORKSPACE\",\"name\":\"SERA SIS\"}"
  echo "✓ workspace $WM_WORKSPACE created"
fi

# --- folder ----------------------------------------------------------------
if [ "$(get "$W/folders/exists/sis")" = "true" ]; then
  echo "✓ folder f/sis exists"
else
  post "$W/folders/create" '{"name":"sis"}'
  echo "✓ folder f/sis created"
fi

# --- variables -------------------------------------------------------------
upsert_variable() { # path value is_secret description
  local path=$1 value=$2 secret=$3 desc=$4
  if [ "$(get "$W/variables/exists/$path")" = "true" ]; then
    post "$W/variables/update/$path" "$(jq -n --arg v "$value" '{value:$v}')"
    echo "✓ variable $path updated"
  else
    post "$W/variables/create" "$(jq -n --arg p "$path" --arg v "$value" \
      --argjson s "$secret" --arg d "$desc" \
      '{path:$p,value:$v,is_secret:$s,description:$d}')"
    echo "✓ variable $path created"
  fi
}
upsert_variable f/sis/claim_service_base_url "$CLAIM_SERVICE_BASE_URL" false \
  "Base URL claim-service dari worker Windmill"
upsert_variable f/sis/claim_internal_api_key "$CLAIM_INTERNAL_API_KEY" true \
  "x-api-key endpoint /internal claim-service (= INTERNAL_API_KEY)"

# --- script ----------------------------------------------------------------
SCRIPT_PATH=f/sis/claim_outstanding_job
CONTENT=$(cat "$DIR/f/sis/claim_outstanding_job.ts")
PARENT=$(curl -fsS "${AUTH[@]}" "$W/scripts/get/p/$SCRIPT_PATH" 2>/dev/null | jq -r '.hash // empty' || true)
post "$W/scripts/create" "$(jq -n --arg p "$SCRIPT_PATH" --arg c "$CONTENT" --arg h "$PARENT" '{
  path: $p,
  summary: "API-CL-34 Job Outstanding",
  description: "Registrasi > 24 jam & dokumen wajib belum lengkap -> Outstanding (IA Claim 11 §5). Loop hasMore maks 10, retry 5xx 2x/30 detik, 409 dilewati.",
  content: $c,
  language: "bun"
} + (if $h == "" then {} else {parent_hash: $h} end)')"
if [ -n "$PARENT" ]; then echo "✓ script $SCRIPT_PATH updated"; else echo "✓ script $SCRIPT_PATH created"; fi

# --- schedule --------------------------------------------------------------
SCHEDULE_PATH=f/sis/claim_outstanding_hourly
SCHEDULE_BODY=$(jq -n --arg s "$SCRIPT_PATH" '{
  schedule: "0 5 * * * *",
  timezone: "Asia/Jakarta",
  args: {},
  summary: "Job Outstanding klaim, tiap jam menit ke-5",
  no_flow_overlap: true
}')
if [ "$(get "$W/schedules/exists/$SCHEDULE_PATH")" = "true" ]; then
  post "$W/schedules/update/$SCHEDULE_PATH" "$SCHEDULE_BODY"
  echo "✓ schedule $SCHEDULE_PATH updated"
else
  post "$W/schedules/create" "$(echo "$SCHEDULE_BODY" | jq --arg p "$SCHEDULE_PATH" --arg s "$SCRIPT_PATH" \
    '. + {path:$p, script_path:$s, is_flow:false, enabled:false}')"
  echo "✓ schedule $SCHEDULE_PATH created"
fi
post "$W/schedules/setenabled/$SCHEDULE_PATH" "{\"enabled\":$SCHEDULE_ENABLED}"
echo "✓ schedule enabled=$SCHEDULE_ENABLED"

echo
echo "Done. UI: $WM_URL/scripts/get/$SCRIPT_PATH?workspace=$WM_WORKSPACE"
