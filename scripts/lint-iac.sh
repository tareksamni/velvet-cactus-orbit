#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Lint every non-application artifact: Helm, Terraform, Ansible, YAML, shell.
#
# Mirrors .github/workflows/iac.yml. Tools that are not installed are SKIPPED
# with a warning rather than failing the run, so a developer without the full
# toolchain still gets useful feedback — CI installs everything and is the
# authority.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

cd "$REPO_ROOT" || exit 1

PYTHON="${PYTHON:-$REPO_ROOT/.venv/bin/python}"
[[ -x "$PYTHON" ]] || PYTHON="$(command -v python3)"
VENV_BIN="$REPO_ROOT/.venv/bin"

failures=0
skipped=()

run() {
  local label="$1"; shift
  log "$label"
  if "$@"; then
    success "$label"
  else
    err "$label failed"
    failures=$((failures + 1))
  fi
}

skip() { warn "skipped: $1 (not installed — $2)"; skipped+=("$1"); }

# --- Helm ------------------------------------------------------------------
if have_cmd helm; then
  for env in dev prod; do
    run "helm lint ($env)" helm lint charts/csv-app -f "charts/csv-app/values-$env.yaml"
  done

  if have_cmd kubeconform; then
    for env in dev prod; do
      log "helm template + kubeconform ($env)"
      if helm template csv-app charts/csv-app -f "charts/csv-app/values-$env.yaml" \
           | kubeconform -strict -summary -kubernetes-version 1.31.0 -; then
        success "kubeconform ($env)"
      else
        err "kubeconform ($env) failed"
        failures=$((failures + 1))
      fi
    done
  else
    skip "kubeconform" "make bootstrap"
  fi
else
  skip "helm" "https://helm.sh/docs/intro/install/"
fi

# --- Terraform -------------------------------------------------------------
# No credentials and no backend: -backend=false is what lets validate run
# without an AWS account. See infra/terraform/README.md.
if have_cmd terraform; then
  run "terraform fmt" terraform -chdir=infra/terraform fmt -check -recursive -diff
  run "terraform init" terraform -chdir=infra/terraform init -backend=false -input=false -no-color
  run "terraform validate" terraform -chdir=infra/terraform validate -no-color
else
  skip "terraform" "https://developer.hashicorp.com/terraform/install"
fi

if have_cmd tflint; then
  run "tflint" tflint --chdir=infra/terraform --format compact
else
  skip "tflint" "https://github.com/terraform-linters/tflint"
fi

CHECKOV="$VENV_BIN/checkov"
[[ -x "$CHECKOV" ]] || CHECKOV="$(command -v checkov || true)"
if [[ -n "$CHECKOV" ]]; then
  run "checkov" "$CHECKOV" -d infra/terraform --framework terraform --quiet --compact
else
  skip "checkov" "pip install checkov"
fi

# --- Ansible ---------------------------------------------------------------
ANSIBLE_PLAYBOOK="$VENV_BIN/ansible-playbook"
[[ -x "$ANSIBLE_PLAYBOOK" ]] || ANSIBLE_PLAYBOOK="$(command -v ansible-playbook || true)"

if [[ -n "$ANSIBLE_PLAYBOOK" ]]; then
  for env in dev prod; do
    run "ansible syntax-check ($env)" bash -c \
      "cd '$REPO_ROOT/ansible' && '$ANSIBLE_PLAYBOOK' site.yml --syntax-check -e env=$env >/dev/null"
  done
else
  skip "ansible-playbook" "make bootstrap"
fi

ANSIBLE_LINT="$VENV_BIN/ansible-lint"
[[ -x "$ANSIBLE_LINT" ]] || ANSIBLE_LINT="$(command -v ansible-lint || true)"
if [[ -n "$ANSIBLE_LINT" ]]; then
  run "ansible-lint" bash -c "cd '$REPO_ROOT/ansible' && '$ANSIBLE_LINT'"
else
  skip "ansible-lint" "make bootstrap"
fi

# --- YAML ------------------------------------------------------------------
YAMLLINT="$VENV_BIN/yamllint"
[[ -x "$YAMLLINT" ]] || YAMLLINT="$(command -v yamllint || true)"
if [[ -n "$YAMLLINT" ]]; then
  run "yamllint" "$YAMLLINT" -c .yamllint.yml ansible/ infra/kops/ .github/
else
  skip "yamllint" "make bootstrap"
fi

# --- shell -----------------------------------------------------------------
if have_cmd shellcheck; then
  # -x follows the `# shellcheck source=` directives so the sourced helpers in
  # lib/common.sh are analysed too, rather than reported as unresolvable.
  run "shellcheck" shellcheck -x scripts/*.sh scripts/lib/*.sh infra/kops/*.sh
else
  skip "shellcheck" "apt-get install shellcheck"
fi

echo >&2
if [[ ${#skipped[@]} -gt 0 ]]; then
  warn "Skipped (not installed): ${skipped[*]}"
fi
if [[ "$failures" -gt 0 ]]; then
  die "$failures infrastructure check(s) failed"
fi
success "Infrastructure lint clean"
