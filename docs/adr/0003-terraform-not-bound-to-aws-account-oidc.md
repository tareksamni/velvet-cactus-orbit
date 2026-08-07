# ADR-0003: Terraform is not bound to an AWS account; OIDC is the real path

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study asks for an S3 bucket with a Glacier lifecycle transition. No AWS
account was provided, and the brief says a running cluster is not expected.

There are two honest ways to handle this and one dishonest one. The dishonest
one is to write Terraform that looks applied and say nothing.

## Decision

**Write real, complete Terraform, bind it to no AWS account, and say so
loudly.**

Concretely:

- `providers.tf` declares the provider and version constraints but configures
  **no credentials, no profile, no assumed role**.
- The `backend "s3"` block is present but **commented out** — there is no state
  bucket to point at.
- The commented `assume_role_with_web_identity` block shows the shape of the
  real authentication path.
- `infra/terraform/README.md` opens with a statement that the configuration has
  never been applied, and lists the apply-time errors to expect.

**The real authentication path is AWS OIDC federation.** Terraform Cloud (or
GitHub Actions) presents a short-lived OIDC identity token; AWS exchanges it for
temporary credentials against a scoped IAM deployment role whose trust policy
restricts which repository and branch may assume it. No long-lived access keys
exist anywhere — not in CI secrets, not in a developer's `~/.aws`, not in the
cluster.

## Consequences

- **What is verified:** `terraform fmt`, `init -backend=false`, `validate`,
  `tflint` and `checkov` all pass in CI. The configuration is syntactically
  valid, type-correct and policy-clean.
- **What is not verified:** everything AWS would tell you at apply time.
  **Runtime errors on a first real apply are still possible** — a bucket name
  that is not globally unique, a missing permission on the deploy role, a
  region-specific feature gap, a provider-version behaviour change, or an
  organisation SCP. Each is a well-signposted error with a small local fix, and
  the "first real apply" checklist in `infra/terraform/README.md` walks through
  them. Budget a little time for that rather than assuming a clean first apply.
- CI runs no `plan` and no `apply`, so there is no path from this repository to
  any cloud account. That is a feature.
- A reviewer can assess the *design* — lifecycle rules, least-privilege IAM,
  encryption, TLS enforcement — without needing to trust an environment they
  cannot see.

## Alternatives considered

- **Apply it against a personal AWS account.** Would prove it works, but bills a
  real account for an interview exercise, and the reviewer still could not
  inspect the result.
- **Use LocalStack.** Would exercise the API calls, but LocalStack's S3
  lifecycle and Glacier support is a simulation. A green LocalStack run would
  imply a verification that had not actually happened — worse than saying
  plainly that it was never applied.
- **Static access keys in CI secrets.** Works, and is what a lot of pipelines
  still do. Rejected because long-lived keys are the credential most commonly
  leaked, and OIDC federation removes the class of problem entirely.
