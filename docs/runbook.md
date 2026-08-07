# Runbook

Operational reference. The failure modes listed here are the ones actually hit
while building this, not hypotheticals.

---

## Everyday commands

```bash
make help              # every target, self-documented
make preflight         # what's installed, what's missing, how to install it
make bootstrap         # install the missing dev tooling
make up                # start the local cluster (sizes itself to the machine)
make build             # build the image into minikube's docker daemon
make deploy            # Ansible + Helm (ENV=dev|prod)
make smoke             # end-to-end assertions
make load              # drive the HPA and watch it scale
make check             # everything CI runs
make down              # delete the cluster
```

## Deploying

```bash
make deploy ENV=dev
# equivalently:
cd ansible && ansible-playbook site.yml -e env=dev
```

Values are layered chart defaults → `values-<env>.yaml` → Ansible's generated
overlay (which wins). Ansible runs Helm with `--atomic`, so a release that never
becomes healthy is rolled back rather than left half-applied.

## Rolling back

```bash
helm -n csv-app history csv-app
helm -n csv-app rollback csv-app <revision>
kubectl -n csv-app rollout status deploy/csv-app
```

## Changing configuration

Application settings live in `ansible/group_vars/`. Edit, then redeploy — do
not `kubectl edit` the ConfigMap, or the next deploy reverts it.

The Deployment carries a `checksum/config` annotation derived from the
ConfigMap's contents, so a config change rolls the pods automatically. If it
does not, that annotation is the first thing to check.

---

## Failure modes

### HPA shows `<unknown>` and never scales

```console
$ kubectl -n csv-app get hpa
NAME      TARGETS                                     REPLICAS
csv-app   cpu: <unknown>/70%, memory: <unknown>/80%   1
```

Two causes, in order of likelihood:

1. **metrics-server is not running.**
   ```bash
   kubectl -n kube-system get pods -l k8s-app=metrics-server
   minikube addons enable metrics-server -p csv-app
   kubectl top pods -n csv-app     # must return numbers
   ```
2. **A container has no resource requests.** The HPA computes utilisation as
   *usage ÷ request*. With no request there is no denominator, and it gives up
   silently — for **all** containers in the pod, not just the one missing them.
   ```bash
   kubectl -n csv-app get deploy csv-app \
     -o jsonpath='{range .spec.template.spec.containers[*]}{.name}: {.resources.requests}{"\n"}{end}'
   ```

Also normal: CPU shows `<unknown>` for the **first 30–60 seconds** after a pod
starts, because CPU is a rate and needs two samples. Memory appears first. Wait
before diagnosing.

### Pod stuck at 0/2 or CrashLoopBackOff

Check each container separately — the sidecar's logs are usually noise
describing the app's failure:

```bash
kubectl -n csv-app logs <pod> -c app --tail=30
kubectl -n csv-app logs <pod> -c nginx --tail=30
kubectl -n csv-app describe pod <pod> | tail -30
```

Nginx logging `connect() failed (111: Connection refused) ... upstream
127.0.0.1:8000` means **the app container is down**. Read the app's logs; nginx
is a symptom.

### App exits with a pydantic ValidationError at startup

```
max_upload_bytes: Input should be a valid integer,
  unable to parse string as an integer [input_value='2.62144e+07']
```

Helm parses YAML numbers as float64, so a large integer renders in scientific
notation. Any numeric value passed into the ConfigMap must go through `int64`:

```yaml
APP_MAX_UPLOAD_BYTES: {{ .Values.app.maxUploadBytes | int64 | quote }}
```

### Readiness failing, liveness fine

By design. Liveness (`/healthz`) never touches object storage, so an S3 outage
does not restart healthy pods. Readiness (`/readyz`) does, so unusable pods
leave the Service endpoints.

```bash
kubectl -n csv-app exec deploy/csv-app -c app -- \
  python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/readyz').read())"
kubectl -n csv-app get pods -l app.kubernetes.io/component=minio
```

Locally, MinIO stores data on an `emptyDir` — a MinIO restart loses every
uploaded object and the bucket. The app recreates the bucket at startup; restart
the app pods if listing then fails.

### `port-forward` fails: "does not have a named port 'http'"

The Service selector is matching a pod it should not. This happened here: MinIO
originally shared `app.kubernetes.io/name` with the application, so the app's
Service matched the MinIO pod too.

```bash
kubectl -n csv-app get endpoints csv-app -o wide   # should list ONLY app pods
```

A selector matches on a *subset* of labels, so adding a distinguishing label to
the extra workload does not help — the **name itself** has to differ.
`make smoke` now prints endpoints and pods on failure so this is obvious.

### The image scan fails the build

`docker.yml` fails on HIGH/CRITICAL vulnerabilities that have a fix available.
`ignore-unfixed: true` means a vulnerability with no patch will not block you —
there would be no action to take — but it still appears in the SARIF report.

Reproduce locally before guessing:

```bash
docker build -t csv-app:scan app/
trivy image --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln csv-app:scan
```

In order of preference:

1. **Upgrade the dependency.** Trivy prints the fixed version. Bump it in
   `app/requirements.txt`, run `make test`, rescan. Watch for transitive pins —
   Starlette could not be patched without also moving FastAPI, because FastAPI
   capped it.
2. **Upgrade the base image** if the finding is an OS package. Dependabot opens
   these weekly.
3. **Accept it, with an expiry.** Only when there is genuinely no fix and the
   code path is unreachable. Add a `.trivyignore` entry with the CVE, a reason,
   and an `exp:` date so it comes back rather than becoming permanent:
   ```
   # unreachable: we never parse untrusted XML
   CVE-2026-12345 exp:2026-12-01
   ```

Do **not** widen `severity` or set `exit-code: 0` to get a green build. That
turns the gate off for everything, not just the finding in front of you.

### `devspace dev`: a CSS or JS edit does not show up

Expected if you only sync `./app`. nginx serves `/shared/static`, not
`/app/static` — the `static-init` init container populates the shared volume
once at pod start and never runs again, so a file synced into `/app` is
invisible to nginx.

`devspace.yaml` handles this with a second sync target
(`./app/static:/shared/static`) plus a patch making that mount writable in the
dev pod. If it stops working, check both are still present:

```bash
devspace print | grep -A3 'shared-static'
kubectl -n csv-app exec deploy/csv-app-devspace -c app -- head -1 /shared/static/css/app.css
```

### `devspace dev`: container stuck on "Waiting for initial sync to complete"

The app container runs as uid 10001 and `/.devspace` is root-owned, so
DevSpace's restart helper cannot write its `/.devspace/start` marker and the
container waits forever — nginx then crash-loops, because its probe proxies to
an app that never started. Do not set `startContainer: true` on the sync; the
image already contains the code and `uvicorn --reload` picks up the sync.

### Ansible deploys the wrong environment

If `-e env=dev` produces prod values, check the inventory: a host listed in
**both** groups inherits **both** `group_vars` files. Each environment needs a
distinct host name (`dev-cluster`, `prod-cluster`).

```bash
cd ansible && ansible-inventory --graph
```

### Helm `context deadline exceeded`, release uninstalled

`--atomic` rolled back, which hides the cause. Reproduce without it:

```bash
helm upgrade -i csv-app charts/csv-app -n csv-app \
  -f charts/csv-app/values-dev.yaml -f ansible/build/values.generated.yaml
kubectl -n csv-app get pods -w
```

Most often an image that cannot be pulled — `values-prod.yaml` points at
`ghcr.io/OWNER/csv-app`, which does not exist until CI has pushed it.

### minikube: apiserver stops, kubectl "connection refused"

Usually memory pressure. `make up` sizes the cluster from `MemAvailable`, but a
busy machine can still squeeze it.

```bash
minikube status -p csv-app
free -m
minikube stop -p csv-app && minikube start -p csv-app
MINIKUBE_MEMORY=3000 make up        # override if needed
```

If `~/.kube/config` loses its context: `minikube update-context -p csv-app`.

---

## Production-only concerns

### Spot interruption

AWS gives two minutes. Pods are rescheduled onto the on-demand group; the app
is stateless so nothing is lost.

```bash
kubectl get nodes -L lifecycle,kops.k8s.io/instancegroup
kubectl get events -A --field-selector reason=NodeNotReady
```

Persistent interruptions mean the diversified pools are exhausted — widen
`mixedInstancesPolicy.instances` in `infra/kops/ig-nodes-spot.yaml`.

### Cluster Autoscaler is not adding nodes

```bash
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=100
kubectl get pods -A --field-selector status.phase=Pending
```

- **No node groups discovered** → the ASG is missing the
  `k8s.io/cluster-autoscaler/enabled` and cluster-name tags.
- **Adds nodes but pods stay Pending** → the `node-template/taint/*` tag is
  missing, so it does not know new nodes carry the spot taint. This loops until
  `maxSize`.
- **Never scales down** → `skip-nodes-with-local-storage` left at `true`. Every
  app pod uses an `emptyDir` (ADR-0004), so every node looks unremovable.

### S3 access denied in production

Production uses IRSA — no static credentials.

```bash
kubectl -n csv-app get sa csv-app -o yaml    # needs the role-arn annotation
kubectl -n csv-app exec deploy/csv-app -c app -- env | grep AWS_ROLE_ARN
```

Objects are SSE-KMS encrypted, so the role needs `kms:Decrypt` and
`kms:GenerateDataKey` as well as the S3 actions — without them writes succeed
and reads fail.

### A file older than 90 days will not open

Expected. The lifecycle policy moved it to Deep Archive, which needs a
12–48 hour restore the application does not implement. See
[ADR-0007](adr/0007-glacier-ir-before-deep-archive.md) — either drop that
transition or add a restore workflow.
