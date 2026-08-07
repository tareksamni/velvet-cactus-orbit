# Assumptions

**To the reviewer:** the brief left a number of things open. Rather than pick
silently, every gap I filled is listed here with the reasoning and what changes
if my reading was wrong. Nothing was invented without being written down.

Where an assumption would be a genuine defect in production, this document says
so plainly rather than hiding it.

---

## 1. Scope of the exercise

**This is an interview assignment, not a production deployment.** Three
boundaries follow from that, and they are deliberate rather than oversights:

| | |
|---|---|
| **Terraform was never applied** | No AWS account was provided. The configuration is statically validated only; no bucket, key, role or policy has ever been created. See §6 and [ADR-0003](docs/adr/0003-terraform-not-bound-to-aws-account-oidc.md). |
| **The kops cluster was never created** | The brief says a running cluster is not expected. The manifests are a reviewable deliverable. |
| **Everything is in one repository** | For delivery convenience. In a real environment this is a judgement call, not a default — see §7 and [ADR-0002](docs/adr/0002-monorepo-vs-separate-infra-repo.md). |

The README carries a per-requirement table marking each item **verified
locally** or **config only**. Nothing is claimed as working that was not run.

---

## 2. The data and the parser

**The attached file has no header and three columns.** No schema came with it,
so the column meanings are inferred from the values:

```
"211627629","Purple Safi Kaftan","4900.0000"
 sku         product_name        price
```

I read `soh` as *stock on hand*. If those columns mean something else, only the
display labels are wrong — `DEFAULT_COLUMNS` in `app/csv_parser.py` is a
one-line change.

**The file contains 751 records, not 750.** `wc -l` reports 750 because the
final line has no trailing newline. The parser counts 751 and `make smoke`
asserts that number.

Other assumptions in the parser:

- **A header row may or may not be present.** The parser sniffs it: if the last
  field of the first row does not parse as a number, it is treated as a header.
  The trade-off is visible in the tests — a genuine data row whose price is
  `N/A` would be mistaken for a header.
- **Ragged rows should not abort the file.** A malformed line is recorded as an
  error and skipped; the other 750 still process. Aborting seemed clearly wrong
  for a bulk import.
- **UTF-8, falling back to latin-1.** Exports of this kind are often vague about
  encoding, and failing an upload over one accented product name would be poor.
- **Files are megabytes, not gigabytes.** Hence a 25 MB cap and an in-memory
  parse rather than a streaming pipeline. If real files are much larger this is
  the first thing to change.
- **"Just print content of the lines to browser" is meant literally.** Rows are
  rendered in a table, capped at 1000 for browser sanity — while the
  **complete** file is always archived to S3.

---

## 3. The application

- **No authentication was requested, so none was built.** This is the single
  largest production gap in the repository: an unauthenticated endpoint that
  writes to object storage. It is called out here, in the README, and in
  `docs/decisions.md` rather than left to be discovered.
- **No rate limiting or upload quotas.** Nothing stops one client filling the
  bucket.
- **No database.** "Previously processed files" is answered by listing the
  bucket. I assumed object storage is an acceptable source of truth; the payoff
  is a stateless app that the HPA can scale freely, and the cost is no search
  or filtering ([ADR-0005](docs/adr/0005-stateless-s3-listing-no-database.md)).
- **"Upload it to the s3 storage" means the CSV file itself**, not per-row
  records into a datastore.
- **No data transformation was asked for** — parse, display, archive.
- **A JSON API was added alongside the HTML UI** (`/api/v1/*`) so the generated
  OpenAPI document is a usable contract rather than a description of form posts.
  The brief only asked for a "basic interface".

---

## 4. Infrastructure

- **"Shared storage (not nfs)" means pod-scoped shared storage.** I used an
  `emptyDir` populated by an init container. The assets are immutable and
  versioned with the image, and there is no cross-pod state, so a ReadWriteMany
  PVC would satisfy the wording while adding a CSI dependency for no benefit
  ([ADR-0004](docs/adr/0004-emptydir-for-shared-static-assets.md)).
- **Nginx and the app in one pod is a requirement**, so it is implemented as
  specified. Worth stating the consequence rather than pretending it is free:
  the two scale and deploy as a unit, so nginx replica count is dictated by
  application load rather than by static-serving load. That is a trade-off
  inherited from the brief, not a recommendation.
- **"Expose application with creating service object" was taken at face value.**
  The chart carries a complete Ingress template, but it is disabled by default
  and **no ingress controller is installed** — locally the app is reached over a
  NodePort or a port-forward. `values-prod.yaml` shows what the Ingress would
  look like on AWS. TLS termination, host routing and certificate issuance are
  therefore unverified
  ([ADR-0010](docs/adr/0010-no-ingress-controller-or-platform-addons.md)).
  Note also that ingress-nginx was retired in 2026, so a real deployment should
  start from Gateway API or the AWS Load Balancer Controller rather than the
  historically obvious choice.
- **The cluster-wide platform layer is absent by design**, not by oversight:
  cert-manager, external-dns, external-secrets and the AWS Load Balancer
  Controller. These are installed once per cluster by whoever owns the platform,
  not bundled into an application chart — so shipping them here would be wrong
  even in production.
- **"Implement auto scaling for deployment" means an HPA on CPU and memory.** I
  assumed no custom or external metrics backend exists.
- **metrics-server is available** on the target cluster.
- **Kubernetes version, instance types, region, cluster name, AMI ids, CIDR
  ranges and the kops state-store bucket are placeholders** chosen as sane
  defaults. Every one is a value a real engagement would dictate. They are
  marked `REPLACE-ME` where a first apply would fail without changing them.
- **API and SSH access are left at `0.0.0.0/0`** in `cluster.yaml` with a
  comment saying they must be narrowed. I had no office or VPN CIDR to use.

---

## 5. Ansible

- **"Application configs in Ansible" means Ansible owns configuration values,
  not Kubernetes manifests.** Helm renders the objects; Ansible renders the
  values and the nginx config. Both tools template YAML, and this is the seam
  that stops them duplicating each other
  ([ADR-0008](docs/adr/0008-helm-renders-k8s-ansible-owns-config.md)).
- **There is no server fleet to configure.** kops owns node lifecycle, and
  anything applied over SSH would be lost at the next `rolling-update`. The
  playbook therefore runs `connection: local` against a kubeconfig. This is
  cluster configuration management, not fleet configuration management.

---

## 6. S3, Glacier and Terraform

- **No AWS account was provided**, so the provider is deliberately unbound: no
  credentials, no assumed role, no configured backend.
- **The Terraform has never been applied and the infrastructure has never been
  created.** `fmt`, `init -backend=false`, `validate`, `tflint` and `checkov`
  all pass, which proves the configuration is syntactically valid, type-correct
  and policy-clean — and proves nothing about how AWS responds to it.
  **Runtime errors on a first real setup are still possible:** a bucket name
  that is not globally unique, a permission missing from the deploy role, a
  region or provider-version difference, an organisation SCP. Each is a
  well-signposted error with a small local fix;
  [`infra/terraform/README.md`](infra/terraform/README.md) lists the likely ones
  and gives a first-apply checklist. Budget a little time rather than assuming a
  clean first apply.
- **The real authentication path would be AWS OIDC federation** — Terraform
  Cloud or GitHub Actions exchanging a short-lived OIDC token for a scoped IAM
  deployment role, with no long-lived access keys anywhere. The shape is in
  `providers.tf`, commented.
- **The lifecycle day counts are invented.** 30 days → Glacier IR, 90 → Deep
  Archive, 365 → expire. **No retention policy was given.** This is the number
  in the repository most likely to be wrong, and it is a one-line change in
  `infra/terraform/variables.tf`.
- **Glacier Instant Retrieval was chosen over Glacier Flexible Retrieval**
  because the app re-reads archived files on demand and a minutes-to-hours
  restore would break that. Note the honest caveat: Glacier IR bills a 128 KB
  minimum per object and the sample file is 45 KB, so for objects this small
  these transitions can cost *more* than leaving them in Standard. The mechanism
  is correct; the economics depend on real object sizes
  ([ADR-0007](docs/adr/0007-glacier-ir-before-deep-archive.md)).
- **A file older than 90 days would not open** in the UI, because Deep Archive
  needs a restore the app does not implement. Flagged rather than papered over.
- **Private, versioned, SSE-KMS encrypted, TLS-only** by default, because
  nothing indicated otherwise.

---

## 7. Delivery and tooling

- **A Linux development machine is the target.** Scripts are written and tested
  on Linux; macOS is best-effort and the portability limits are named in
  `scripts/lib/common.sh` rather than assumed away.
- **One repository, for reviewability.** Splitting infrastructure into its own
  repository is a real-world judgement call driven by how many workloads share
  the platform, who owns the blast radius of an `apply`, review gates, release
  cadence, team boundaries and scale.
  [ADR-0002](docs/adr/0002-monorepo-vs-separate-infra-repo.md) argues it both
  ways rather than claiming one is correct.
- **GHCR as the image registry**, because it authenticates with the built-in
  `GITHUB_TOKEN` and therefore works in a fresh clone with no secrets to
  configure. The brief suggests Docker Hub; that path is supported and
  commented in `.github/workflows/docker.yml`.
- **GitHub Actions**, since the brief suggests GitHub for code hosting. No CI
  platform was mandated.
- **The reviewer may read rather than run.** Every runnable path is documented
  with copy-pasteable commands, and the local-vs-config-only split is stated per
  requirement.

---

## 8. Questions I would have asked

In a real engagement these would be answered rather than assumed. They are
listed in the order I would ask them:

1. **What is the retention policy for uploaded files?** Directly sets the
   Glacier transition days, which are currently invented.
2. **Who uses this, and does it need authentication?** Determines whether the
   largest gap in the repository is acceptable.
3. **What is the expected file size and upload volume?** Decides whether the
   in-memory parse and 25 MB cap hold, and whether small objects should be
   aggregated before archiving.
4. **What do the three CSV columns actually mean, and will the format change?**
   Decides how defensive the parser needs to be.
5. **Which AWS account and region, and is there an existing platform?** Most of
   the kops placeholders would be dictated by existing conventions.
6. **Are there existing conventions for logging, metrics and secrets?** Better
   to adopt the platform's than to invent a parallel stack.
7. **What is the availability target?** Decides replica counts, PDB values, and
   how aggressive the spot/on-demand split should be.

---

## 9. Deliberately not built

Not oversights — scope decisions, listed so their absence is not mistaken for
one:

| Not built | What I would add |
|---|---|
| Authentication / authorisation | OIDC at the ingress, or app-level sessions |
| **Ingress controller** | Gateway API, or the AWS Load Balancer Controller on AWS — not ingress-nginx, which was retired in 2026 (ADR-0010) |
| TLS inside the cluster | ALB termination + cert-manager (both configured in `values-prod.yaml`, never applied) |
| **DNS records** | external-dns, driven from the Ingress annotation rather than the console |
| **Secret sync** | external-secrets from Secrets Manager/SSM — though with IRSA there is no secret to sync (ADR-0003) |
| **GitOps deployment** | ArgoCD App-of-Apps, pulling from git and reconciling drift, instead of `helm upgrade` pushed from a pipeline (ADR-0010) |
| Rate limiting | nginx `limit_req`, or WAF rules at the ALB |
| Multi-tenancy | A tenant prefix in the S3 key and an authorisation check |
| Metrics, tracing, alerting | Prometheus + OpenTelemetry; alert on upload failure and S3 error rates |
| Backup / DR | S3 versioning is on; cross-region replication is not |
| Restore workflow for Deep Archive | Async restore + "check back later" UI, or drop that transition |
| Secret management | External Secrets or SSM; today prod relies on IRSA and holds no secrets, which is the better answer where it applies |
