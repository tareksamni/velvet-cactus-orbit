# ADR-0010: No ingress controller or platform add-ons in the demo

- **Status:** Accepted **for this assignment**
- **Date:** 2026-08-07

## Context

The case study asks for the application to be exposed with a Service object.
It does not ask for an Ingress, a TLS certificate, or a DNS record.

A production deployment of this application would sit behind an ingress
controller with TLS termination, a real hostname, and a certificate — and that
controller would be one of a small family of cluster-wide platform components
(cert-manager, external-dns, external-secrets) that are typically installed
*once per cluster* by whoever owns the platform, not per application.

The question is how much of that to build for a demo that runs on a
single-node minikube cluster.

## Decision

**Ship the Ingress as a chart template, disabled by default, and install no
ingress controller.** Expose the application with a Service — `NodePort`
locally, `ClusterIP` in prod — and reach it with `minikube service` or
`kubectl port-forward`.

Concretely, what is in the repository:

| | |
|---|---|
| `charts/csv-app/templates/ingress.yaml` | A complete, conditional Ingress template |
| `values.yaml` | `ingress.enabled: false` — the default |
| `values-dev.yaml` | Leaves it off; uses `service.type: NodePort` |
| `values-prod.yaml` | `ingress.enabled: true`, `className: alb`, with ALB annotations for TLS and HTTP→HTTPS redirect |
| The cluster | **No ingress controller is installed.** `scripts/minikube-up.sh` enables `metrics-server` only |

So the *shape* of the ingress is expressed and reviewable, and the prod values
show what it would look like — but nothing has ever been served through one.
The `NOTES.txt` output branches on `ingress.enabled` and prints the right
access instructions either way.

## Consequences

- **The local demo stays small.** An ingress controller is a second Deployment,
  a LoadBalancer or hostPort, an admission webhook, and — on minikube — a
  `minikube tunnel` running in another terminal. On a box where the cluster
  already had to be sized down to fit available memory, that is real cost for
  no additional proof: `make smoke` exercises nginx, the shared volume, the
  app and object storage identically through a port-forward.
- **Enabling it is a values change, not a code change.** `--set
  ingress.enabled=true` and a `className` is the whole diff.
- **What is therefore unverified:** TLS termination, host-based routing,
  redirect behaviour, and certificate issuance. That is listed as *config only*
  in the README table and in `ASSUMPTIONS.md`, not glossed over.
- The application is unauthenticated (see `ASSUMPTIONS.md`), so **not** exposing
  it on a routable hostname is arguably the correct default anyway.

## What it would look like with an ingress controller

### The caveat first: ingress-nginx is retired

The obvious choice historically was **ingress-nginx**, the community controller.
It was retired in 2026 — the project stopped taking new features, and
maintenance and security fixes wound down. Anything standing up a new cluster
today should not be starting there.

The successors:

- **Gateway API** is the direction of travel. `Ingress` is effectively frozen;
  `Gateway`/`HTTPRoute` is the API that is actually being developed. It splits
  the resource by role — infrastructure owners manage `GatewayClass` and
  `Gateway`, application teams own `HTTPRoute` — which is a much better fit for
  the platform-team/product-team split than a single annotation-laden `Ingress`.
- **InGate** is the announced successor project for ingress-nginx users.
- On AWS specifically, the **AWS Load Balancer Controller** (already assumed in
  `values-prod.yaml`) is usually the better answer regardless: it provisions a
  real ALB instead of running a reverse proxy on your own nodes, and terminates
  TLS with an ACM certificate.

So for a new deployment I would go straight to Gateway API, or to the ALB
controller on AWS — not to ingress-nginx.

### For reference, the ingress-nginx shape

If it were still the choice, the values would be:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: 25m   # must match the app's upload limit
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: csv-app.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: csv-app-tls
      hosts: [csv-app.example.com]
```

Note `proxy-body-size`. There would then be **three** places an upload limit is
enforced — the ingress controller, the nginx sidecar, and the application — and
all three have to agree or a large upload fails with a confusing 413 from
whichever is strictest. The sidecar's limit is already derived from the
application's (ADR-0008); a real ingress deployment would need to derive this
one the same way rather than hardcode it.

Locally that would mean `minikube addons enable ingress`, a `/etc/hosts` entry,
and `minikube tunnel` — which is exactly the setup cost this ADR is avoiding.

## The platform add-ons that are also absent

The same reasoning applies to the rest of the cluster-wide layer. None of these
are installed, and all of them would earn their place in a real deployment:

| Component | What it would do here |
|---|---|
| **cert-manager** | Issue and renew the TLS certificate. Already enabled in `infra/kops/cluster.yaml`, but never applied |
| **external-dns** | Create the Route53 record for `csv-app.example.com` from the Ingress annotation, instead of someone clicking in the console |
| **external-secrets** | Sync the S3 credentials from AWS Secrets Manager or SSM into the cluster. The chart already supports `s3.existingSecret` for exactly this — though in production IRSA means there is no secret to sync at all (ADR-0003), so this matters more for anything that *cannot* use workload identity |
| **AWS Load Balancer Controller** | Provision the ALB for the Ingress. Enabled in the kops cluster spec, never applied |
| **Prometheus / OpenTelemetry** | Metrics and traces. Today there are structured logs and probes, nothing more |

They share a property worth stating: they are **cluster-scoped platform
components, not application components**. Bundling them into this chart would
be wrong even in production — install cert-manager once per cluster, not once
per service. That boundary is also the strongest argument for the separate
platform repository discussed in ADR-0002.

## How I would actually deploy all of this: ArgoCD

For real environments I prefer **ArgoCD** over running `helm upgrade` from a
pipeline, which is what `ansible/site.yml` does here.

The difference that matters is **push versus pull**. A pipeline that runs
`helm upgrade` needs cluster credentials in CI, and it only knows the state it
last pushed — if someone `kubectl edit`s a Deployment, the pipeline is unaware
until the next deploy silently reverts it. ArgoCD runs *inside* the cluster,
pulls from git, and continuously reconciles: git is the declared state, drift is
detected and shown, and no external system holds cluster credentials.

Shape it would take:

- An **App-of-Apps** or ApplicationSet: one Application per platform add-on
  (cert-manager, external-dns, external-secrets, the ingress/gateway
  controller, the AWS Load Balancer Controller) plus one per workload.
- Sync waves so the platform layer is healthy before workloads that depend on
  it — cert-manager and its CRDs before anything requesting a Certificate.
- This chart referenced as a source with the per-environment values file, so
  `values-dev.yaml` / `values-prod.yaml` keep exactly the role they have now.
- Auto-sync with prune and self-heal in dev; manual sync (or a PR gate) in prod,
  so a production change is a reviewed commit rather than a pipeline run.
- Image updates by commit — CI pushes the image and opens a PR bumping the tag,
  so what is running is always exactly what is in git.

This does **not** displace Helm or the chart. ArgoCD renders the same chart;
it changes *who* applies it and *how drift is handled*. Ansible's role would
shrink to what it does well — rendering configuration into the values ArgoCD
consumes — or disappear, with those values living in git per environment.

Not done here because a GitOps controller needs a git remote to pull from and a
cluster that outlives a `make demo`, neither of which a case study has.

## Alternatives considered

- **Install ingress-nginx on minikube and demo through it.** The most complete
  demonstration, and what I would do if the brief had asked for TLS or
  host-based routing. Rejected: it is setup cost and memory for something the
  brief explicitly scopes to a Service object, on a controller that is retired.
- **Ship no Ingress template at all.** Simpler, but then `values-prod.yaml`
  could not express how the application is actually exposed in production, and
  the reviewer would have to take it on trust.
- **Gateway API resources instead of an Ingress.** Where I would start for a
  real deployment. Rejected here only because it needs a controller installed to
  mean anything, and an unexercised `HTTPRoute` demonstrates no more than an
  unexercised `Ingress` while being less familiar to skim.
- **LoadBalancer Service type.** Would work on a cloud provider and skip the
  ingress layer entirely, but gives one load balancer per service, no
  host-based routing, and no shared TLS termination.
