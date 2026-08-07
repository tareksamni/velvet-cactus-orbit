#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Start the local cluster. Idempotent: safe to run when it is already up.
#
# metrics-server is not optional here — without it the HPA reports <unknown>
# for its targets and never scales, which is one of the things this project
# needs to demonstrate.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd minikube "make bootstrap" || exit 1
require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/" || exit 1

# Size the cluster to the machine rather than hardcoding values that fail on a
# smaller box. Overridable with MINIKUBE_CPUS / MINIKUBE_MEMORY / MINIKUBE_DISK.
detect_cpus() {
  local total
  total="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  # Leave one core for everything else; never go below 2.
  local want=$(( total - 1 ))
  [[ "$want" -lt 2 ]] && want=2
  [[ "$want" -gt 4 ]] && want=4
  printf '%s' "$want"
}

detect_memory_mb() {
  local available_mb
  if [[ "$OS" == "darwin" ]]; then
    available_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 2 ))
  else
    # MemAvailable is what can actually be handed out without swapping.
    available_mb=$(( $(awk '/MemAvailable/ {print $2}' /proc/meminfo) / 1024 ))
    available_mb=$(( available_mb * 80 / 100 ))
  fi
  [[ "$available_mb" -gt 6144 ]] && available_mb=6144
  printf '%s' "$available_mb"
}

CPUS="${MINIKUBE_CPUS:-$(detect_cpus)}"
MEMORY="${MINIKUBE_MEMORY:-$(detect_memory_mb)}"
DISK="${MINIKUBE_DISK:-10g}"
DRIVER="${MINIKUBE_DRIVER:-docker}"

# metrics-server plus a two-container pod needs roughly this much to be stable.
if [[ "$MEMORY" -lt 2400 ]]; then
  die "Only ${MEMORY}MB of memory is available for the cluster; at least 2400MB is needed.
     Free some memory, or override with MINIKUBE_MEMORY=<mb> if you know better."
fi

if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  success "minikube profile '$MINIKUBE_PROFILE' is already running"
else
  log "Starting minikube profile '$MINIKUBE_PROFILE' (${CPUS} cpus, ${MEMORY}MB memory, ${DISK} disk, ${DRIVER} driver)"
  # Running as root with the docker driver requires an explicit opt-in.
  extra=()
  [[ "$(id -u)" -eq 0 && "$DRIVER" == "docker" ]] && extra+=(--force)
  minikube start \
    -p "$MINIKUBE_PROFILE" \
    --driver="$DRIVER" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --disk-size="$DISK" \
    "${extra[@]}"
fi

log "Enabling addons"
minikube addons enable metrics-server -p "$MINIKUBE_PROFILE"

kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

success "Cluster ready. Context: $MINIKUBE_PROFILE, namespace: $NAMESPACE"
