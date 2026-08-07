#!/usr/bin/env bash
# Run the unit and API test suites with coverage.
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"

cd "$REPO_ROOT" || exit 1
log "Running tests"
"$PYTHON" -m pytest --cov --cov-report=term-missing "$@"
success "Tests passed"
