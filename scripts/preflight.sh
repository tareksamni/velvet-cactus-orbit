#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verify the tooling this project needs is installed, and say exactly how to
# install anything that is missing on this platform.
#
# Exits non-zero if any REQUIRED tool is missing. Optional tools only warn.
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_supported_platform

missing=0

# name | required? | linux install hint | macos install hint
check() {
  local cmd="$1" required="$2" linux_hint="$3" mac_hint="$4" hint
  if [[ "$OS" == "darwin" ]]; then hint="$mac_hint"; else hint="$linux_hint"; fi

  if have_cmd "$cmd"; then
    success "$(printf '%-12s %s' "$cmd" "$(tool_version "$cmd")")"
    return 0
  fi

  if [[ "$required" == "required" ]]; then
    err "$(printf '%-12s MISSING  -> %s' "$cmd" "$hint")"
    missing=$((missing + 1))
  else
    warn "$(printf '%-12s missing (optional) -> %s' "$cmd" "$hint")"
  fi
}

tool_version() {
  case "$1" in
    kubectl)  kubectl version --client 2>/dev/null | head -1 ;;
    helm)     helm version --short 2>/dev/null ;;
    docker)   docker --version 2>/dev/null ;;
    *)        "$1" --version 2>/dev/null | head -1 ;;
  esac
}

log "Checking required tooling (primary target: Linux; macOS best-effort)"

check docker      required "https://docs.docker.com/engine/install/"        "brew install --cask docker"
check kubectl     required "https://kubernetes.io/docs/tasks/tools/"        "brew install kubectl"
check helm        required "https://helm.sh/docs/intro/install/"            "brew install helm"
check python3     required "apt-get install python3 python3-venv"          "brew install python@3.12"
check minikube    required "make bootstrap  (or https://minikube.sigs.k8s.io/docs/start/)" "brew install minikube"

log "Checking optional tooling (needed for specific targets)"

check ansible-playbook optional "make bootstrap  (pipx install ansible)"    "brew install ansible"
check devspace    optional "make bootstrap  (https://devspace.sh/docs)"     "brew install devspace"
check terraform   optional "https://developer.hashicorp.com/terraform/install" "brew install terraform"
check kubeconform optional "make bootstrap"                                 "brew install kubeconform"
check tflint      optional "make bootstrap"                                 "brew install tflint"
check trivy       optional "make bootstrap"                                 "brew install trivy"
check shellcheck  optional "apt-get install shellcheck"                     "brew install shellcheck"
check yamllint    optional "pipx install yamllint"                          "brew install yamllint"

if [[ "$missing" -gt 0 ]]; then
  echo >&2
  die "$missing required tool(s) missing. Run 'make bootstrap' to install what it can."
fi

echo >&2
success "All required tooling present."
