#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive enough load to make the HPA scale, and watch it happen.
#
# This demonstrates POD autoscaling. Node autoscaling (the Cluster Autoscaler
# configured in infra/kops) cannot be demonstrated on minikube: it works by
# calling the AWS ASG API, and a single-node local cluster has no ASG.
# See docs/kops-explained.md.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/" || exit 1

DURATION="${LOAD_DURATION:-120}"
CONCURRENCY="${LOAD_CONCURRENCY:-20}"
PORT="${LOAD_PORT:-18081}"
BASE="http://127.0.0.1:${PORT}"
pf_pid=""
workers=()

cleanup() {
  for pid in "${workers[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ -n "$pf_pid" ]]; then
    kill "$pf_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" >/dev/null 2>&1; then
  die "No HPA found. Deploy with autoscaling enabled first (make deploy)."
fi

targets="$(kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" -o jsonpath='{.status.currentMetrics}' 2>/dev/null || true)"
if [[ -z "$targets" || "$targets" == "null" ]]; then
  warn "HPA is not reporting metrics yet."
  warn "If it stays <unknown>, metrics-server is missing or the containers have no resource requests:"
  warn "  minikube addons enable metrics-server -p $MINIKUBE_PROFILE"
fi

log "Port-forwarding svc/$RELEASE_NAME -> localhost:$PORT"
kubectl -n "$NAMESPACE" port-forward "svc/$RELEASE_NAME" "${PORT}:80" >/dev/null 2>&1 &
pf_pid=$!
sleep 3

SAMPLE="$REPO_ROOT/app/tests/fixtures/sample.csv"

log "Generating load: ${CONCURRENCY} workers for ${DURATION}s"
deadline=$(( SECONDS + DURATION ))
for _ in $(seq 1 "$CONCURRENCY"); do
  (
    while [[ $SECONDS -lt $deadline ]]; do
      curl -s -o /dev/null -m 10 -X POST "$BASE/api/v1/files" -F "file=@${SAMPLE};type=text/csv" || true
      curl -s -o /dev/null -m 10 "$BASE/" || true
    done
  ) &
  workers+=($!)
done

log "Watching the HPA (Ctrl-C to stop early)"
echo >&2
# Read the fields by name rather than by position: the TARGETS column contains
# spaces ("cpu: 11%/70%, memory: 48%/80%"), so splitting on whitespace shifts
# every column after it.
while [[ $SECONDS -lt $deadline ]]; do
  replicas="$(kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  desired="$(kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  cpu="$(kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" \
    -o jsonpath='{.status.currentMetrics[?(@.resource.name=="cpu")].resource.current.averageUtilization}' 2>/dev/null)"
  mem="$(kubectl -n "$NAMESPACE" get hpa "$RELEASE_NAME" \
    -o jsonpath='{.status.currentMetrics[?(@.resource.name=="memory")].resource.current.averageUtilization}' 2>/dev/null)"
  printf '  cpu=%-6s memory=%-6s replicas=%s -> %s\n' \
    "${cpu:-?}%" "${mem:-?}%" "${replicas:-?}" "${desired:-?}" >&2
  sleep 10
done

echo >&2
log "Scaling decisions the HPA actually made:"
kubectl -n "$NAMESPACE" describe hpa "$RELEASE_NAME" 2>/dev/null \
  | grep -E "SuccessfulRescale|New size" | sed 's/^/  /' >&2 || true

for pid in "${workers[@]}"; do wait "$pid" 2>/dev/null || true; done
workers=()

echo >&2
log "Load stopped. The HPA scales back down after its stabilisation window (300s by default)."
log "Keep watching with:  kubectl -n $NAMESPACE get hpa $RELEASE_NAME -w"
