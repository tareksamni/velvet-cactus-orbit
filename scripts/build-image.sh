#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the application image directly into minikube's Docker daemon.
#
# Building inside the cluster's daemon means there is nothing to push and no
# registry to configure, which is why the dev values use pullPolicy: Never.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd docker "https://docs.docker.com/engine/install/" || exit 1

if [[ "${USE_MINIKUBE_DOCKER:-true}" == "true" ]] && have_cmd minikube \
   && minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  log "Pointing docker at minikube's daemon (profile: $MINIKUBE_PROFILE)"
  # shellcheck disable=SC2046  # word splitting is the documented usage
  eval $(minikube -p "$MINIKUBE_PROFILE" docker-env)
else
  warn "minikube not running — building into the local docker daemon instead"
fi

log "Building ${IMAGE_NAME}:${IMAGE_TAG}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$REPO_ROOT/app"

success "Built ${IMAGE_NAME}:${IMAGE_TAG}"
