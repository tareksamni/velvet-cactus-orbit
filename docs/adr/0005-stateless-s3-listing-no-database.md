# ADR-0005: List processed files from S3; no database

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study requires the UI to "show previously processed files". That
implies some record of what has been processed.

The obvious instinct is a database table: filename, row count, timestamp, key.

## Decision

**Answer the question with `s3:ListObjectsV2` against the upload prefix. Add no
database.**

Per-file metadata (row count, upload time) is stamped into the S3 object's own
metadata at write time and read back with `HeadObject`.

## Consequences

- **The application is completely stateless.** Any replica can serve any
  request. This is what makes the HPA safe: scaling from 1 to 20 pods needs no
  connection pool sizing, no migration, no leader.
- **One fewer component** to deploy, back up, secure, patch and pay for. The
  Helm chart has no database dependency; the Terraform provisions no RDS.
- **The bucket is the single source of truth.** The list cannot drift from
  reality, because it *is* reality. A file that exists is listed; a file the
  lifecycle policy expired disappears from the list automatically, with no
  cleanup job.
- **Trade-off — no rich queries.** There is no search by filename, no filter by
  row count, no join. `ListObjectsV2` returns keys in lexicographic order; the
  application sorts by `LastModified` in memory.
- **Trade-off — listing cost grows with object count.** At case-study scale
  (hundreds of objects) this is instant and free. At a million objects per
  prefix it would need pagination discipline and would still be slow. The date
  partitioning in the key (`uploads/YYYY/MM/DD/...`) means a real
  implementation could scope listings to a date range rather than the whole
  prefix.
- **Trade-off — no row count in the list view.** Getting it would mean a
  `HeadObject` per object, which turns one API call into N. The list shows size
  and timestamp from the listing itself; the row count appears when a file is
  opened.

## When this would need revisiting

If any of these became true, a database (or DynamoDB, or S3 Inventory) would
earn its place:

- Objects per prefix in the hundreds of thousands
- Search, filtering or sorting by attributes not in the key
- Needing processing status (queued/running/failed), not just "it exists"
- Retaining a record of files after the lifecycle policy deletes the object

## Alternatives considered

- **PostgreSQL/RDS.** Correct for a real product with users and search.
  Rejected here as disproportionate: it would be the most expensive and most
  operationally demanding component in a system whose actual job is parsing
  three-column CSVs.
- **SQLite on a PersistentVolume.** Would make the application stateful, pin it
  to one node with a ReadWriteOnce volume, and cap it at one replica —
  defeating the autoscaling requirement.
- **In-memory list.** Lost on restart, and different per replica, so the UI
  would show different results depending on which pod served the request.
