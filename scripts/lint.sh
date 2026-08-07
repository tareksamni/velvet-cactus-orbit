#!/usr/bin/env bash
# Lint and type-check the application code.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

cd "$REPO_ROOT"

log "ruff check"
"$PYTHON" -m ruff check app

log "ruff format --check"
"$PYTHON" -m ruff format --check app

log "mypy"
"$PYTHON" -m mypy

success "Application lint clean"
