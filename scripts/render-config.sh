#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Render application configuration to ansible/build/values.generated.yaml,
# without deploying anything.
#
# This is the config half of `ansible-playbook site.yml` — the app_config role
# on its own. It exists so DevSpace can drive Helm itself while still deploying
# the SAME configuration every other environment gets.
#
# Without it the dev loop falls back to the chart's built-in nginx config,
# which differs from Ansible's in ways that matter: it caches static assets for
# an hour, so an edited stylesheet syncs into the container and the browser
# keeps serving the old one.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ENV_NAME="${1:-${ENV:-dev}}"

ANSIBLE="${ANSIBLE_PLAYBOOK:-$REPO_ROOT/.venv/bin/ansible-playbook}"
[[ -x "$ANSIBLE" ]] || ANSIBLE="$(command -v ansible-playbook || true)"
[[ -n "$ANSIBLE" ]] || die "ansible-playbook not found. Run 'make bootstrap'."

log "Rendering '$ENV_NAME' configuration -> ansible/build/values.generated.yaml"
cd "$REPO_ROOT/ansible" || exit 1
"$ANSIBLE" site.yml -e "env=$ENV_NAME" --tags config

success "Configuration rendered"
