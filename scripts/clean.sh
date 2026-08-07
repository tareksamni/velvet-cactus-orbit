#!/usr/bin/env bash
# Remove build artifacts and caches. Does not touch the cluster.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

cd "$REPO_ROOT"

log "Removing build artifacts and caches"
rm -rf \
  .pytest_cache .mypy_cache .ruff_cache .coverage htmlcov coverage.xml \
  ansible/build build .devspace

find . -type d -name __pycache__ -not -path "./.venv/*" -prune -exec rm -rf {} + 2>/dev/null || true

success "Clean"
