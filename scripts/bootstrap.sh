#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the dev tooling this project needs.
#
# Linux is the primary target and gets direct binary installs. macOS is
# best-effort and delegates to Homebrew. Anything already present is skipped.
#
# Nothing here is required to *review* the repo — only to run the local demo.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_supported_platform

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.34.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"
DEVSPACE_VERSION="${DEVSPACE_VERSION:-v6.3.12}"

brew_install() {
  have_cmd brew || die "Homebrew is required to bootstrap on macOS: https://brew.sh"
  brew install "$1"
}

install_binary() {
  # install_binary <name> <url> [tar-member]
  local name="$1" url="$2" member="${3:-}" tmp
  tmp="$(mktemp -d)"
  log "Installing $name -> $BIN_DIR/$name"
  if [[ -n "$member" ]]; then
    curl -sSfL "$url" -o "$tmp/archive.tar.gz"
    tar -xzf "$tmp/archive.tar.gz" -C "$tmp" "$member"
    install -m 0755 "$tmp/$member" "$BIN_DIR/$name"
  else
    curl -sSfL "$url" -o "$tmp/$name"
    install -m 0755 "$tmp/$name" "$BIN_DIR/$name"
  fi
  rm -rf "$tmp"
}

install_minikube() {
  have_cmd minikube && { success "minikube already installed"; return; }
  if [[ "$OS" == "darwin" ]]; then brew_install minikube; return; fi
  install_binary minikube \
    "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${ARCH}"
}

install_kubeconform() {
  have_cmd kubeconform && { success "kubeconform already installed"; return; }
  if [[ "$OS" == "darwin" ]]; then brew_install kubeconform; return; fi
  install_binary kubeconform \
    "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${ARCH}.tar.gz" \
    kubeconform
}

install_devspace() {
  have_cmd devspace && { success "devspace already installed"; return; }
  if [[ "$OS" == "darwin" ]]; then brew_install devspace; return; fi
  install_binary devspace \
    "https://github.com/devspace-sh/devspace/releases/download/${DEVSPACE_VERSION}/devspace-linux-${ARCH}"
}

install_python_tools() {
  local python="$REPO_ROOT/.venv/bin/python"
  if [[ ! -x "$python" ]]; then
    log "Creating .venv"
    python3 -m venv "$REPO_ROOT/.venv"
    python="$REPO_ROOT/.venv/bin/python"
  fi
  log "Installing Python dependencies into .venv"
  "$python" -m pip install --quiet --upgrade pip
  "$python" -m pip install --quiet -r "$REPO_ROOT/app/requirements-dev.txt"
  # Ansible and yamllint are tooling, not application dependencies, so they are
  # installed into the same venv rather than added to requirements-dev.txt.
  "$python" -m pip install --quiet ansible-core ansible-lint yamllint kubernetes
  log "Installing Ansible collections"
  "$REPO_ROOT/.venv/bin/ansible-galaxy" collection install -r "$REPO_ROOT/ansible/requirements.yml" >/dev/null
  success "Python tooling ready in .venv"
}

log "Bootstrapping tooling for $OS/$ARCH (primary target: Linux)"

install_minikube
install_kubeconform
install_devspace
install_python_tools

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "Add $BIN_DIR to your PATH:  export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

echo >&2
log "Optional extras not installed automatically (they are only needed for lint-iac):"
log "  trivy      https://aquasecurity.github.io/trivy/"
log "  tflint     https://github.com/terraform-linters/tflint"
log "  shellcheck apt-get install shellcheck / brew install shellcheck"

echo >&2
success "Bootstrap complete. Run 'make preflight' to confirm."
