#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared helpers for every script in scripts/.
#
# PLATFORM SUPPORT
#   Primary target: Linux. All scripts here are developed and tested on a Linux
#   development machine, and that is what CI runs.
#   macOS is supported on a best-effort basis: we avoid GNU-only behaviour where
#   it is cheap to do so (no `sed -i` without an argument, no `readlink -f`, no
#   `base64 -w0`, no `grep -P`, no `date -d`). Where a GNU tool is genuinely
#   required, preflight.sh names the brew package rather than failing cryptically.
#
# Usage:  source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# ---------------------------------------------------------------------------

set -euo pipefail

# --- colours (disabled when not a TTY or when NO_COLOR is set) --------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
fi

log()     { printf '%s==>%s %s\n' "$C_BLUE" "$C_OFF" "$*" >&2; }
success() { printf '%s ok %s %s\n' "$C_GREEN" "$C_OFF" "$*" >&2; }
warn()    { printf '%swarn%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
err()     { printf '%sfail%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()     { err "$*"; exit 1; }

# --- repo root -------------------------------------------------------------
# `readlink -f` is GNU-only; cd+pwd works identically everywhere.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# --- platform detection ----------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Linux)  printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *)      printf 'unsupported' ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *)             printf 'unsupported' ;;
  esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"
export OS ARCH

require_supported_platform() {
  [[ "$OS" == "unsupported" ]] && die "Unsupported OS '$(uname -s)'. This project targets Linux (macOS best-effort)."
  [[ "$ARCH" == "unsupported" ]] && die "Unsupported architecture '$(uname -m)'."
  if [[ "$OS" == "darwin" ]]; then
    warn "macOS detected. Linux is this project's primary target; macOS is best-effort."
  fi
  return 0
}

# --- tool checks -----------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  local cmd="$1" hint="${2:-}"
  have_cmd "$cmd" && return 0
  err "Required command not found: ${C_BOLD}${cmd}${C_OFF}"
  [[ -n "$hint" ]] && err "  install: $hint"
  return 1
}

# --- config shared across scripts -----------------------------------------
: "${APP_NAME:=csv-app}"
: "${IMAGE_NAME:=csv-app}"
: "${IMAGE_TAG:=dev}"
: "${NAMESPACE:=csv-app}"
: "${RELEASE_NAME:=csv-app}"
: "${MINIKUBE_PROFILE:=csv-app}"
export APP_NAME IMAGE_NAME IMAGE_TAG NAMESPACE RELEASE_NAME MINIKUBE_PROFILE
