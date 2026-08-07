# ADR-0007: Glacier Instant Retrieval before Deep Archive

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study requires:

> Waiting you to implement s3 glacier transition on s3 config.

S3 offers several archive classes with very different retrieval characteristics:

| Class | Retrieval | Min duration | Relative storage cost |
|---|---|---|---|
| Standard | instant | none | 1× |
| Standard-IA | instant | 30 days | ~0.55× |
| **Glacier Instant Retrieval** | **instant** | 90 days | ~0.25× |
| Glacier Flexible Retrieval | 1–5 min to 5–12 h | 90 days | ~0.18× |
| Glacier Deep Archive | 12–48 h | 180 days | ~0.04× |

The application can re-read and re-parse any archived file on demand:
`GET /api/v1/files/{key}` fetches the object and parses it live.

## Decision

```
day 0    Standard
day 30   GLACIER_IR      (Glacier Instant Retrieval)
day 90   DEEP_ARCHIVE
day 365  deleted

noncurrent versions:  day 30 -> GLACIER, day 90 -> deleted
incomplete multipart uploads aborted after 7 days
```

**Glacier Instant Retrieval, not Glacier Flexible Retrieval**, for the first
transition — because a minutes-to-hours restore would break the "view a
previously processed file" feature the case study asks for. The application
would have to grow an asynchronous restore workflow to serve a page that
currently renders in milliseconds.

Deep Archive at 90 days accepts that trade deliberately: by then the file is
genuinely cold, and a 12–48 hour restore for a year-old CSV is reasonable.

## Consequences

- Files stay instantly viewable in the UI for their first 90 days at a quarter
  of Standard's storage cost.
- After 90 days, viewing requires an explicit restore. The application does not
  implement one — it would return an error. A production system would either
  keep the Deep Archive transition out, or add a restore workflow and tell the
  user "this file is being retrieved, check back tomorrow".
- Objects deleted at 365 days vanish from the UI automatically, because the
  listing is the source of truth (ADR-0005). No cleanup job.

### The cost caveat, stated plainly

**These transitions may cost more than they save for files this small.**

Glacier IR bills a **128 KB minimum** per object and a **90-day minimum storage
duration**. Deep Archive bills 180 days. The sample file is 45 KB — under a
third of the minimum billable size. Add per-object transition request charges
and a bucket of small CSVs can end up *more* expensive archived than left in
Standard.

The mechanism implemented here is correct. Whether it saves money depends
entirely on real object sizes and access patterns, which were not provided. At
scale the right answer for many small objects is to **aggregate them** — daily
tarballs or Parquet — before archiving, so each archived object comfortably
exceeds the minimum billable size.

### The day counts are invented

No retention policy came with the case study. 30/90/365 is a plausible archive
policy, not a requirement. It is the number in this repository most likely to be
wrong, it is flagged in `ASSUMPTIONS.md`, and it is a one-line change in
`infra/terraform/variables.tf`.

## Alternatives considered

- **Straight to Deep Archive at day 30.** Cheapest storage; breaks the view
  feature almost immediately.
- **Glacier Flexible Retrieval.** ~30% cheaper than Glacier IR, but the
  expedited retrieval tier is still 1–5 minutes and is not guaranteed to be
  available. Not compatible with a synchronous page render.
- **Standard-IA as an intermediate step.** Adds a fourth transition and another
  set of minimum-duration charges for a modest saving. Not worth the complexity
  at this scale.
- **S3 Intelligent-Tiering.** Genuinely the best default when access patterns
  are unknown — it moves objects automatically and includes an archive tier.
  Rejected here only because the case study explicitly asks for a *Glacier
  transition*, and Intelligent-Tiering would hide the very mechanism being
  assessed. In a real system with unpredictable access, it would be a strong
  choice.
