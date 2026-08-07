#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deploy via Ansible (application config) + Helm (Kubernetes objects).
#
# Usage: scripts/deploy.sh [dev|prod]
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ENV_NAME="${1:-dev}"
[[ "$ENV_NAME" == "dev" || "$ENV_NAME" == "prod" ]] || die "environment must be 'dev' or 'prod' (got '$ENV_NAME')"

# Prefer the venv's ansible so a bootstrap-installed toolchain is used without
# the developer having to activate anything.
ANSIBLE="$REPO_ROOT/.venv/bin/ansible-playbook"
[[ -x "$ANSIBLE" ]] || ANSIBLE="$(command -v ansible-playbook || true)"
[[ -n "$ANSIBLE" ]] || die "ansible-playbook not found. Run 'make bootstrap'."

require_cmd helm "https://helm.sh/docs/intro/install/" || exit 1

if [[ "$ENV_NAME" == "prod" ]]; then
  warn "Deploying with the 'prod' values. This targets whatever cluster your"
  warn "current kubeconfig context points at: $(kubectl config current-context 2>/dev/null || echo unknown)"
fi

log "Deploying environment '$ENV_NAME'"
cd "$REPO_ROOT/ansible" || exit 1
"$ANSIBLE" site.yml -e "env=$ENV_NAME"

success "Deployed '$ENV_NAME'"
