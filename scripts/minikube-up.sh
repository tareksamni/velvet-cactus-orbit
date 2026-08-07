#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Start the local cluster. Idempotent: safe to run when it is already up.
#
# metrics-server is not optional here — without it the HPA reports <unknown>
# for its targets and never scales, which is one of the things this project
# needs to demonstrate.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd minikube "make bootstrap" || exit 1
require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/" || exit 1

CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6g}"
DRIVER="${MINIKUBE_DRIVER:-docker}"

if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  success "minikube profile '$MINIKUBE_PROFILE' is already running"
else
  log "Starting minikube profile '$MINIKUBE_PROFILE' ($CPUS cpus, $MEMORY memory, $DRIVER driver)"
  # Running as root with the docker driver requires an explicit opt-in.
  extra=()
  [[ "$(id -u)" -eq 0 && "$DRIVER" == "docker" ]] && extra+=(--force)
  minikube start \
    -p "$MINIKUBE_PROFILE" \
    --driver="$DRIVER" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    "${extra[@]}"
fi

log "Enabling addons"
minikube addons enable metrics-server -p "$MINIKUBE_PROFILE"

kubectl config use-context "$MINIKUBE_PROFILE" >/dev/null
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

success "Cluster ready. Context: $MINIKUBE_PROFILE, namespace: $NAMESPACE"
