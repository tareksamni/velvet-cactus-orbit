# CSV Processor — DevOps case study

A CSV-processing web application, packaged as nginx + app in a single
Kubernetes pod sharing static assets through pod-scoped storage, deployed by
Helm and Ansible, autoscaled by an HPA, archiving uploads to S3 with a Glacier
lifecycle policy — plus the kops cluster configuration to run it on.

```bash
make help     # every command, self-documented
make demo     # start a cluster, build, deploy, and assert it works
```

---

## Read this first — three scope boundaries

This is an **interview assignment**, and three things are deliberately bounded.
They are stated here so nothing looks like an oversight. The full list of
judgement calls is in **[`ASSUMPTIONS.md`](ASSUMPTIONS.md)**.

1. **The Terraform was never applied.** No AWS account was in play. It passes
   `fmt`, `init -backend=false`, `validate`, `tflint` and `checkov` — which
   proves it is valid, and proves nothing about how AWS responds to it. **A
   first real apply can still hit runtime errors** (bucket-name uniqueness,
   deploy-role permissions, region or provider differences, org guardrails).
   Each is well-signposted with a small local fix;
   [`infra/terraform/README.md`](infra/terraform/README.md) lists them with a
   first-apply checklist. The real auth path would be **AWS OIDC federation**
   into a scoped IAM role — no long-lived keys
   ([ADR-0003](docs/adr/0003-terraform-not-bound-to-aws-account-oidc.md)).

2. **The kops cluster was never created.** The brief says a running cluster is
   not expected. The manifests are a reviewable deliverable with heavy inline
   commentary and a dedicated explainer:
   [`docs/kops-explained.md`](docs/kops-explained.md).

3. **Everything is in one repository** for delivery convenience. In a real
   environment that is a judgement call — driven by how many workloads share the
   platform, who owns the blast radius of an `apply`, review gates, release
   cadence, team boundaries and scale.
   [ADR-0002](docs/adr/0002-monorepo-vs-separate-infra-repo.md) argues it both
   ways rather than claiming one answer is correct.

**Also worth knowing up front:** there is **no authentication**. None was
requested, and none was built. It is the largest production gap here and is
called out rather than left to be found.

---

## Requirements → where they are satisfied

Each row is marked **verified** (actually run and asserted on a live cluster) or
**config only** (written and statically validated, never applied).

### K8s cluster

| Requirement | Where | Status |
|---|---|---|
| kops cluster creation config | [`infra/kops/cluster.yaml`](infra/kops/cluster.yaml) | config only |
| Multiple instance groups | [`ig-control-plane.yaml`](infra/kops/ig-control-plane.yaml), [`ig-nodes-ondemand.yaml`](infra/kops/ig-nodes-ondemand.yaml), [`ig-nodes-spot.yaml`](infra/kops/ig-nodes-spot.yaml) | config only |
| Mixed instance group + lifecycle (spot & on-demand) | [`ig-nodes-spot.yaml`](infra/kops/ig-nodes-spot.yaml) — `mixedInstancesPolicy`, 4 types, `capacity-optimized`, 100% spot | config only |
| Cluster autoscaler for all instance groups | [`cluster-autoscaler-values.yaml`](infra/kops/cluster-autoscaler-values.yaml) + discovery tags on every IG | config only — needs an AWS ASG, impossible on minikube |

### Infra

| Requirement | Where | Status |
|---|---|---|
| Nginx + web app in the **same pod** | [`deployment.yaml`](charts/csv-app/templates/deployment.yaml) | **verified** — `2/2` containers, asserted by `make smoke` |
| Sharing public files via shared storage (**not NFS**) | `emptyDir` + `static-init` init container ([ADR-0004](docs/adr/0004-emptydir-for-shared-static-assets.md)) | **verified** — `X-Served-By: nginx-shared-volume` asserted |
| Expose with a Service | [`service.yaml`](charts/csv-app/templates/service.yaml) | **verified** |
| Auto scaling for deployment | [`hpa.yaml`](charts/csv-app/templates/hpa.yaml) | **verified** — scaled **2 → 4** at 281% CPU under `make load` |
| Configuration management with Ansible | [`ansible/`](ansible/) — `group_vars/` + `app_config` role | **verified** — playbook performs the deploy |
| Helm to render K8s objects for new environments | [`charts/csv-app/`](charts/csv-app/) + `values-dev.yaml` / `values-prod.yaml` | **verified** — both render and pass `kubeconform` |

### Development

| Requirement | Where | Status |
|---|---|---|
| Web app parsing CSVs in the attached format (Python) | [`app/csv_parser.py`](app/csv_parser.py) | **verified** — 751 rows parsed from `soh-1-.csv` |
| Interface to upload CSV and show previously processed files | [`app/templates/`](app/templates/) | **verified** |
| Print the file's lines to the browser | `GET /files/{key}`, `POST /upload` | **verified** |
| Upload processed file to S3 | [`app/storage.py`](app/storage.py) — boto3 | **verified** against MinIO, identical code path to AWS |
| S3 Glacier transition | [`infra/terraform/s3.tf`](infra/terraform/s3.tf) | **config only** — never applied |

### Solutioning

| Requirement | Where |
|---|---|
| Documentation | [`docs/`](docs/) — architecture, kops explainer, decisions, 9 ADRs, runbook |
| Architecture diagram | [`docs/architecture.md`](docs/architecture.md) — 7 Mermaid diagrams |

### Beyond the brief

OpenAPI contract ([`docs/openapi.yaml`](docs/openapi.yaml), served at `/docs`),
GitHub Actions for tests/lint/image build+scan+push
([`.github/workflows/`](.github/workflows/)), a DevSpace inner loop
([`devspace.yaml`](devspace.yaml)), and a runbook
([`docs/runbook.md`](docs/runbook.md)).

---

## Layout

```
app/                     FastAPI application, tests, Dockerfile
charts/csv-app/          Helm chart — the only thing that renders K8s objects
ansible/                 application configuration + the deploy playbook
infra/kops/              cluster + instance groups (never applied)
infra/terraform/         S3 bucket + Glacier lifecycle + IRSA (never applied)
scripts/                 all real logic; the Makefile only calls into here
docs/                    architecture, ADRs, kops explainer, runbook, openapi
.github/workflows/       ci (app) · docker (image) · iac (infrastructure)
devspace.yaml            dev inner loop, driving the same Helm chart
ASSUMPTIONS.md           every judgement call, written to the reviewer
```

---

## Running it

**Primary target: Linux.** Everything is developed and tested on a Linux
development machine, and that is what CI runs. macOS is supported on a
best-effort basis — the scripts avoid GNU-only behaviour where it is cheap to,
and `make preflight` names the Homebrew package for anything missing.

```bash
make preflight    # what's installed, what isn't, how to install it
make bootstrap    # install the missing tooling (minikube, devspace, ansible, ...)
make demo         # up -> build -> deploy -> smoke
```

`make up` sizes the cluster from the machine's available memory and CPU rather
than hardcoding values that fail on a smaller box.

### Developing

```bash
make dev          # DevSpace: edit app/, uvicorn reloads in-cluster, no rebuild
make test         # pytest
make check        # everything CI runs
```

The dev loop deploys the **same Helm chart** as the release path, so the
development environment cannot drift from the deployment
([ADR-0009](docs/adr/0009-devspace-inner-loop-over-docker-compose.md)).

### Deploying

```bash
make deploy ENV=dev      # ansible-playbook site.yml -e env=dev
```

Values layer: chart defaults → `values-<env>.yaml` → Ansible's generated
overlay, which wins. Ansible owns configuration; Helm owns objects
([ADR-0008](docs/adr/0008-helm-renders-k8s-ansible-owns-config.md)).

---

## What `make smoke` actually asserts

It exits non-zero on failure — this is a test, not a demo script:

```
ok  upload parsed 751 rows (got 751)
ok  archived to object storage under uploads/ (key: uploads/2026/08/07/03e57333-soh-1-.csv)
ok  file appears in the previously-processed list
ok  re-read from storage returns 751 rows
ok  browser output contains the parsed lines ('Purple Safi Kaftan')
ok  nginx serves /static from the shared emptyDir volume
ok  static asset has the correct content type
ok  OpenAPI document is served
ok  one pod runs both containers (got: app nginx)
```

The static-asset check reads the `X-Served-By` header, which only nginx's
`/static/` location block sets — so it proves the file came off the shared
volume rather than falling through to the application.

---

## The two autoscalers

The brief asks for autoscaling twice, and they are different components. This
catches most people out, so it has its own explainer:
[`docs/kops-explained.md`](docs/kops-explained.md).

| | HPA | Cluster Autoscaler |
|---|---|---|
| Scales | **Pods** | **Nodes** |
| Triggered by | CPU/memory utilisation | **Pending** pods (not CPU) |
| Needs | metrics-server + resource **requests** | An AWS Auto Scaling Group |
| On minikube | **works** — `make load` proves it | **impossible** — one node, no ASG |

They chain: load rises → HPA adds pods → pods go Pending → Cluster Autoscaler
adds a node → pods schedule.

The gotcha worth internalising: without resource **requests** the HPA has no
denominator for utilisation, reports `<unknown>`, and silently never scales.

---

## Notes

- `soh-1-.csv` is git-ignored and not redistributed. A 12-line slice is
  committed at `app/tests/fixtures/sample.csv` so the tests are self-contained.
- The file holds **751** records; `wc -l` says 750 because the last line has no
  trailing newline.
- The application is stateless by design — no database. "Previously processed
  files" is a bucket listing, which is what makes horizontal scaling safe
  ([ADR-0005](docs/adr/0005-stateless-s3-listing-no-database.md)).
