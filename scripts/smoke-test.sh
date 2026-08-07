#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# End-to-end proof against the deployed application.
#
# This ASSERTS rather than prints: every check exits non-zero on failure, so
# `make demo` genuinely verifies the case-study requirements instead of just
# producing output that looks plausible.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/" || exit 1
require_cmd curl "apt-get install curl" || exit 1

SAMPLE="${SAMPLE_CSV:-$REPO_ROOT/soh-1-.csv}"
if [[ ! -f "$SAMPLE" ]]; then
  warn "$SAMPLE not found; falling back to the committed test fixture"
  SAMPLE="$REPO_ROOT/app/tests/fixtures/sample.csv"
fi
EXPECTED_ROWS="$(grep -c . "$SAMPLE")"

PORT="${SMOKE_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
pf_pid=""

cleanup() { [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true; }
trap cleanup EXIT

failures=0
check() {
  local name="$1"; shift
  if "$@"; then
    success "$name"
  else
    err "$name"
    failures=$((failures + 1))
  fi
}

# --- connect ---------------------------------------------------------------
log "Port-forwarding svc/$RELEASE_NAME -> localhost:$PORT"
kubectl -n "$NAMESPACE" port-forward "svc/$RELEASE_NAME" "${PORT}:80" >/dev/null 2>&1 &
pf_pid=$!

for _ in $(seq 1 30); do
  curl -sf -m 2 "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -m 5 "$BASE/healthz" >/dev/null || die "application did not become reachable on $BASE"

log "Running smoke checks against $BASE (sample: $(basename "$SAMPLE"), $EXPECTED_ROWS rows)"

# --- 1. upload, parse, archive --------------------------------------------
response="$(curl -sf -m 60 -X POST "$BASE/api/v1/files" -F "file=@${SAMPLE};type=text/csv")" \
  || die "upload failed"

parsed_rows="$(printf '%s' "$response" | tr ',' '\n' | grep -o '"row_count":[0-9]*' | head -1 | cut -d: -f2)"
key="$(printf '%s' "$response" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)"

check "upload parsed $EXPECTED_ROWS rows (got ${parsed_rows:-none})" test "$parsed_rows" = "$EXPECTED_ROWS"
check "archived to object storage under uploads/ (key: ${key:-none})" \
  bash -c "[[ '${key}' == uploads/* ]]"

# --- 2. the file is listed as previously processed -------------------------
listing="$(curl -sf -m 15 "$BASE/api/v1/files")" || die "listing failed"
check "file appears in the previously-processed list" \
  bash -c "printf '%s' \"\$1\" | grep -q \"${key}\"" _ "$listing"

# --- 3. it can be re-read and re-parsed from storage ------------------------
reread="$(curl -sf -m 30 "$BASE/api/v1/files/${key}")" || die "re-read failed"
reread_rows="$(printf '%s' "$reread" | tr ',' '\n' | grep -o '"row_count":[0-9]*' | head -1 | cut -d: -f2)"
check "re-read from storage returns $EXPECTED_ROWS rows" test "$reread_rows" = "$EXPECTED_ROWS"

# --- 4. the HTML UI prints the lines to the browser -------------------------
html="$(curl -sf -m 60 -X POST "$BASE/upload" -F "file=@${SAMPLE};type=text/csv")" || die "HTML upload failed"
first_value="$(head -1 "$SAMPLE" | cut -d, -f2 | tr -d '"')"
check "browser output contains the parsed lines ('${first_value}')" \
  bash -c "printf '%s' \"\$1\" | grep -qF \"\$2\"" _ "$html" "$first_value"

# --- 5. nginx serves static assets off the SHARED volume --------------------
# The X-Served-By header is set only by the /static/ location block, so its
# presence proves nginx served the file from the shared emptyDir rather than
# the request falling through to the application.
headers="$(curl -sf -m 10 -D - -o /dev/null "$BASE/static/css/app.css")" || die "static asset request failed"
check "nginx serves /static from the shared emptyDir volume" \
  bash -c "printf '%s' \"\$1\" | grep -qi 'X-Served-By: nginx-shared-volume'" _ "$headers"
check "static asset has the correct content type" \
  bash -c "printf '%s' \"\$1\" | grep -qi 'content-type: text/css'" _ "$headers"

# --- 6. the OpenAPI contract is served --------------------------------------
check "OpenAPI document is served" \
  bash -c "curl -sf -m 10 '$BASE/openapi.json' | grep -q 'CSV Processor'"

# --- 7. the pod really is nginx + app in ONE pod ---------------------------
containers="$(kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=csv-app,app.kubernetes.io/instance=$RELEASE_NAME" \
  -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true)"
check "one pod runs both containers (got: ${containers:-none})" \
  bash -c "[[ '$containers' == *app* && '$containers' == *nginx* ]]"

echo >&2
if [[ "$failures" -gt 0 ]]; then
  die "$failures smoke check(s) failed"
fi
success "All smoke checks passed"
