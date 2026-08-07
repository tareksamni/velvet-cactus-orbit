#!/usr/bin/env bash
# Start the DevSpace inner loop against the local cluster.
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd devspace "make bootstrap" || exit 1
require_cmd kubectl "https://kubernetes.io/docs/tasks/tools/" || exit 1

if have_cmd minikube && ! minikube status -p "$MINIKUBE_PROFILE" >/dev/null 2>&1; then
  die "minikube profile '$MINIKUBE_PROFILE' is not running. Run 'make up' first."
fi

cd "$REPO_ROOT" || exit 1
log "Starting DevSpace (namespace: $NAMESPACE)"
log "Edit files under app/ and uvicorn reloads in-cluster — no rebuild, no redeploy."
exec devspace dev --namespace "$NAMESPACE" "$@"
