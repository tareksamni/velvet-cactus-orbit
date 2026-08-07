# Design decisions

The narrative version. Each section links to the ADR with the full reasoning,
alternatives, and consequences.

---

## Index

| ADR | Decision |
|---|---|
| [0001](adr/0001-record-architecture-decisions.md) | Record architecture decisions |
| [0002](adr/0002-monorepo-vs-separate-infra-repo.md) | One repository for app and infrastructure (**for this assignment**) |
| [0003](adr/0003-terraform-not-bound-to-aws-account-oidc.md) | Terraform bound to no AWS account; OIDC is the real path |
| [0004](adr/0004-emptydir-for-shared-static-assets.md) | Share static assets through a pod-scoped `emptyDir` |
| [0005](adr/0005-stateless-s3-listing-no-database.md) | List processed files from S3; no database |
| [0006](adr/0006-spot-ondemand-instance-group-split.md) | Split capacity into on-demand and diversified-spot groups |
| [0007](adr/0007-glacier-ir-before-deep-archive.md) | Glacier Instant Retrieval before Deep Archive |
| [0008](adr/0008-helm-renders-k8s-ansible-owns-config.md) | Helm renders objects; Ansible owns application config |
| [0009](adr/0009-devspace-inner-loop-over-docker-compose.md) | DevSpace against the real chart, not docker-compose |
| [0010](adr/0010-no-ingress-controller-or-platform-addons.md) | No ingress controller or platform add-ons in the demo; ArgoCD for real GitOps |

---

## The shape of the thing

The case study asks for four deliverables that pull in different directions: a
cluster definition that will never run, a workload that must actually work, an
application, and documentation. The organising principle here is that **every
artifact is either verified or explicitly labelled as unverified** — never
quietly in between.

That split runs through the whole repository:

- The **Helm chart, application, Ansible and DevSpace** are exercised on a real
  minikube cluster. `make smoke` asserts them.
- The **kops manifests, Cluster Autoscaler and Terraform** are reviewable
  configuration, statically validated, never applied.

`ASSUMPTIONS.md` and the README state which is which, per requirement.

## Storage: three different problems, three different answers

The word "storage" appears three times in this project and means something
different each time.

**Sharing CSS between two containers in one pod** is not a storage problem at
all — it is a packaging problem. The assets already exist in the application
image; nginx just cannot see them. An `emptyDir` and a two-line init container
solve it with no infrastructure ([ADR-0004](adr/0004-emptydir-for-shared-static-assets.md)).
A ReadWriteMany PVC would satisfy the requirement's letter while adding a CSI
driver, a cost line and a minikube incompatibility for no benefit.

**Archiving uploaded CSVs** is a real storage problem, and S3 is the right
answer — with a lifecycle policy that moves cold data to Glacier
([ADR-0007](adr/0007-glacier-ir-before-deep-archive.md)).

**Remembering which files were processed** looks like a database problem and
is not. The bucket already knows. Listing it keeps the application stateless,
which is precisely what makes horizontal autoscaling safe
([ADR-0005](adr/0005-stateless-s3-listing-no-database.md)).

## Two autoscalers, one of which cannot be demonstrated

The case study asks for autoscaling twice — "cluster autoscaler for all
instance groups" and "implement auto scaling for deployment" — and they are
different components.

The **HPA** scales pods on CPU/memory. It runs on minikube and `make load`
proves it: CPU hit 281% of its 70% target and the deployment scaled 2 → 4.

The **Cluster Autoscaler** scales nodes by calling the AWS ASG API when pods go
Pending. It cannot run on minikube — one node, no ASG. It ships as configuration
with heavy commentary and a dedicated explainer
([docs/kops-explained.md](kops-explained.md)).

The subtlety worth knowing: the HPA needs resource **requests** or it reports
`<unknown>` and silently never scales; the Cluster Autoscaler needs
`skip-nodes-with-local-storage: false` or it refuses to drain any node running
an `emptyDir` pod — which, thanks to ADR-0004, is every application node.

## Spot capacity is a pool problem

The naive spot configuration picks one instance type and gets interrupted
constantly. Capacity is allocated per *(instance type, AZ)* pool, so the fix is
diversification: four comparable types across three AZs is twelve pools rather
than one ([ADR-0006](adr/0006-spot-ondemand-instance-group-split.md)).

The taint choice matters as much. `NoSchedule` strands the capacity whenever
somebody forgets a toleration; `PreferNoSchedule` lets the scheduler use spot as
a last resort while letting opted-in workloads prefer it. Toleration makes spot
*permitted*; node affinity makes it *preferred*. Both are needed, or the split
exists on paper only.

## Two tools, one seam

Helm and Ansible both template YAML, and used carelessly they duplicate each
other. The seam here: Ansible owns application configuration **values**, Helm
owns Kubernetes **objects**, and the generated values file is the handoff
([ADR-0008](adr/0008-helm-renders-k8s-ansible-owns-config.md)).

The concrete payoff is that nginx's `client_max_body_size` is *derived* from the
application's upload limit, so the two cannot silently disagree.

## What is deliberately absent from the cluster

The application is exposed with a Service, which is what the brief asks for.
There is **no ingress controller installed** — the chart carries a complete
Ingress template, disabled by default and enabled in `values-prod.yaml`, but
nothing has ever been served through one
([ADR-0010](adr/0010-no-ingress-controller-or-platform-addons.md)).

The same goes for the rest of the cluster-wide layer: cert-manager,
external-dns, external-secrets, the AWS Load Balancer Controller. These are
**platform components, not application components** — you install cert-manager
once per cluster, not once per service — so bundling them into this chart would
be wrong even in production. That boundary is also the strongest argument for
the separate platform repository discussed in
[ADR-0002](adr/0002-monorepo-vs-separate-infra-repo.md).

Worth noting for anyone reaching for the obvious controller: **ingress-nginx was
retired in 2026**. A new deployment should be starting from Gateway API, or —
on AWS — from the AWS Load Balancer Controller, which `values-prod.yaml` already
assumes.

And for actually deploying all of it, I would use **ArgoCD** rather than the
`helm upgrade` from a pipeline that `ansible/site.yml` does here. Pull beats
push: the controller runs in the cluster, reconciles continuously against git,
detects drift instead of silently reverting it at the next deploy, and needs no
cluster credentials sitting in CI. ADR-0010 sketches the App-of-Apps shape.

## What I would change for a real production system

Honestly, in rough priority order:

1. **Authentication.** There is none. An unauthenticated upload endpoint writing
   to object storage is the single largest gap. OIDC via the ingress, or an
   application-level session.
2. **Rate limiting and upload quotas.** Nothing stops one client filling the
   bucket.
3. **An ingress controller and TLS**, plus the platform add-ons that go with it
   — cert-manager for certificates, external-dns for the Route53 record,
   external-secrets where workload identity is not an option. Gateway API or
   the AWS Load Balancer Controller, not ingress-nginx
   ([ADR-0010](adr/0010-no-ingress-controller-or-platform-addons.md)).
4. **ArgoCD** for deployment, so git is the declared state and drift is
   reconciled rather than discovered.
5. **Observability.** Structured logs go to stdout, which is a start.
   A real system needs metrics (Prometheus), traces, and alerts on upload
   failure rate and S3 error rate — not just probes.
6. **Reconsider the Deep Archive transition**, or implement a restore workflow.
   Today, viewing a file older than 90 days would fail.
7. **Aggregate small objects before archiving.** Glacier's 128 KB minimum
   billable size means the current policy may cost more than it saves for 45 KB
   files ([ADR-0007](adr/0007-glacier-ir-before-deep-archive.md)).
8. **Split the infrastructure out**, if this grew past one service
   ([ADR-0002](adr/0002-monorepo-vs-separate-infra-repo.md)).
9. **Actually apply the Terraform**, in a sandbox account, behind OIDC
   ([ADR-0003](adr/0003-terraform-not-bound-to-aws-account-oidc.md)).
