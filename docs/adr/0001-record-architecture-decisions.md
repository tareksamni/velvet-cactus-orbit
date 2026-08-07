# ADR-0001: Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

This repository is a response to a DevOps case study. A reviewer reading it
needs to distinguish three things that look identical in a diff: a deliberate
trade-off, an arbitrary default, and a mistake.

Comments explain *how* code works. They are a poor place to record *why* one
option was chosen over another, because the alternatives are not in the file.

## Decision

Record every non-obvious decision as a numbered ADR in `docs/adr/`, using a
lightweight MADR-style structure: **Context → Decision → Consequences →
Alternatives considered**.

ADRs are immutable. A decision that changes gets a new ADR that supersedes the
old one; the original stays as a record of what was believed at the time.

## Consequences

- A reviewer can read `docs/decisions.md` for the narrative and drill into an
  ADR for the reasoning behind any specific choice.
- Choices that would otherwise look arbitrary — `emptyDir` over a PVC, Glacier
  IR over Glacier Flexible, `PreferNoSchedule` over `NoSchedule` — carry their
  justification.
- It costs a few minutes per decision to write.

## Alternatives considered

- **A single DESIGN.md.** Easier to write, but it accumulates edits until the
  history of *why* is lost. ADRs keep superseded reasoning visible.
- **Comments only.** Cannot express "we considered X and rejected it because Y",
  because X does not appear anywhere in the file.
