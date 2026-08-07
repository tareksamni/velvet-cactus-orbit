#!/usr/bin/env bash
# Tear down the local cluster.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd minikube "make bootstrap" || exit 1

if minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  log "Deleting minikube profile '$MINIKUBE_PROFILE'"
  minikube delete -p "$MINIKUBE_PROFILE"
  success "Cluster deleted"
else
  success "Nothing to do — profile '$MINIKUBE_PROFILE' is not running"
fi
