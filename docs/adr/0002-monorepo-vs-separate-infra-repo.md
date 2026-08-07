# ADR-0002: One repository for application and infrastructure

- **Status:** Accepted **for this assignment**
- **Date:** 2026-08-07

## Context

This repository contains the application (`app/`), the Helm chart (`charts/`),
Ansible (`ansible/`), Terraform (`infra/terraform/`) and kops manifests
(`infra/kops/`).

Whether these belong together is a genuine architectural question, not a
formality. It is also **not** a question with a universal answer.

## Decision

**Keep everything in one repository, because this is an interview assignment
and the deliverable is a single reviewable artifact.**

A reviewer should be able to clone one thing, run `make help`, and see how every
requirement is satisfied. Splitting the submission across repositories would add
coordination cost that serves nobody here.

This decision is scoped to the assignment. It is explicitly **not** a
recommendation that production systems be laid out this way.

## Consequences

- One clone, one CI configuration, one place to look. Atomic changes across the
  app and its deployment are possible.
- CI must use path filters so a docs change does not rebuild an image
  (see `.github/workflows/`).
- Everyone with commit access to the application also has commit access to the
  Terraform. In a real environment that is often exactly what you do not want.

## Alternatives considered — and when each is right

In a real environment this is a judgement call driven by the wider picture, not
a default. The factors that actually decide it:

**How many workloads share the platform.** One service owning its own bucket is
very different from a platform team running shared VPCs, clusters and DNS for
forty services. Shared infrastructure wants its own repository; service-specific
infrastructure is often happiest next to the service that owns it.

**Who owns the blast radius of an `apply`.** A `terraform apply` that can delete
a production database should not be reachable from the same review process as a
CSS change. Separate repositories let you put genuinely different review gates,
required approvers and branch protections on genuinely different risks.

**State isolation and release cadence.** Application code ships many times a
day; network topology changes quarterly. Coupling them means every infra change
drags along the application's CI, and every app deploy re-plans the
infrastructure.

**Team boundaries.** If a platform team owns the cluster and a product team owns
the service, the repository boundary usually wants to follow the ownership
boundary, so that CODEOWNERS and on-call responsibility line up.

**Scale.** At three services, a monorepo is simpler and the coordination cost of
splitting is real. At three hundred, a shared platform repository plus
per-service application repositories is usually the only thing that stays
manageable.

Reasonable production layouts include:

| Layout | Fits when |
|---|---|
| One repo (this one) | Small team, service owns its own infra, few workloads |
| App repo + infra repo | Infra needs separate review gates and cadence |
| App repos + shared platform repo + per-service infra modules | Many services on a shared platform |

None of these is correct in the abstract. This ADR records that the monorepo
here was chosen for **delivery convenience**, and that a real decision would be
made against the criteria above.
