# Architecture

Diagrams are Mermaid, which GitHub renders natively — no image assets to fall
out of sync with the code.

---

## 1. Request and data flow

What happens when someone uploads a CSV.

```mermaid
flowchart LR
    browser([Browser])

    subgraph pod["Pod — one pod, two containers"]
        direction TB
        nginx["nginx :8080<br/>serves /static<br/>proxies the rest"]
        vol[("emptyDir<br/>shared static")]
        app["app :8000<br/>FastAPI + uvicorn"]
        nginx -. "reads css/js" .-> vol
        vol -. "populated by<br/>init container" .-> app
        nginx -- "loopback<br/>127.0.0.1:8000" --> app
    end

    svc["Service :80"]
    s3[("S3 / MinIO<br/>bucket: csv-uploads")]
    glacier[("Glacier IR<br/>→ Deep Archive")]

    browser -->|"POST /upload"| svc --> nginx
    app -->|"1 . parse rows"| app
    app -->|"2 . PutObject<br/>uploads/YYYY/MM/DD/key.csv"| s3
    app -->|"3 . ListObjectsV2<br/>(previously processed)"| s3
    s3 -.->|"lifecycle policy<br/>day 30 / day 90"| glacier
    app -->|"4 . render parsed lines"| browser
```

The application keeps **no database**. "Previously processed files" is answered
by listing the bucket, which is what makes the app stateless and safe to scale
([ADR-0005](adr/0005-stateless-s3-listing-no-database.md)).

---

## 2. Inside the pod — the shared-storage mechanism

The case study requires nginx and the app in the **same pod**, sharing public
files through shared storage that is **not NFS**.

```mermaid
flowchart TB
    subgraph pod["Pod"]
        direction TB

        subgraph init["initContainer: static-init"]
            initc["image: csv-app<br/><br/>cp -R /app/static/. /shared/static/"]
        end

        vol[("Volume: shared-static<br/><b>emptyDir</b>, 64Mi<br/>pod-scoped, dies with the pod")]

        subgraph containers["containers (run concurrently)"]
            direction LR
            appc["<b>app</b><br/>image: csv-app<br/>uvicorn :8000<br/><br/>mounts /shared/static ro"]
            nginxc["<b>nginx</b><br/>image: nginx:alpine<br/>listens :8080<br/><br/>mounts /shared/static ro<br/>serves it at /static/"]
        end

        initc -->|"writes, then exits"| vol
        vol --> appc
        vol --> nginxc
        nginxc -->|"proxy_pass<br/>everything else"| appc
    end

    cm["ConfigMap<br/>nginx.conf + APP_* env"]
    cm -.->|"mounted /etc/nginx/nginx.conf"| nginxc
    cm -.->|"envFrom"| appc

    style vol fill:#e8f0fe,stroke:#2563eb,stroke-width:2px
```

The static assets ship **inside the application image**. Nginx's image does not
contain them, so the init container copies them into a volume both containers
mount. No CSI driver, no StorageClass, no PVC, no NFS — and it behaves
identically on minikube and on a real cluster
([ADR-0004](adr/0004-emptydir-for-shared-static-assets.md)).

`make smoke` asserts the `X-Served-By: nginx-shared-volume` response header,
which only nginx's `/static/` block sets — proving the file came off the shared
volume rather than falling through to the app.

---

## 3. The kops cluster (never applied)

```mermaid
flowchart TB
    subgraph vpc["VPC 10.20.0.0/16 — 3 AZs, private topology"]

        subgraph cp["Control plane — ON-DEMAND, 3 ASGs of 1"]
            cp1["control-plane-1a<br/>m6i.large + etcd"]
            cp2["control-plane-1b<br/>m6i.large + etcd"]
            cp3["control-plane-1c<br/>m6i.large + etcd"]
        end

        subgraph od["nodes-ondemand — 1 ASG, 3-6"]
            odn["m6i.large<br/>lifecycle=OnDemand<br/><b>no taint</b><br/><br/>ingress, cert-manager,<br/>cluster-autoscaler,<br/>app minReplicas"]
        end

        subgraph sp["nodes-spot — 1 ASG, 2-20"]
            spn["<b>mixedInstancesPolicy</b><br/>m6i / m5 / m5a / m5n .large<br/>100% spot, capacity-optimized<br/>lifecycle=Spot<br/><b>taint spot=true:PreferNoSchedule</b>"]
        end
    end

    ca["Cluster Autoscaler<br/>(kube-system)"]
    asg{{"AWS Auto Scaling API"}}

    ca -->|"discovers ASGs by tag<br/>k8s.io/cluster-autoscaler/enabled"| asg
    asg -->|"SetDesiredCapacity"| od
    asg -->|"SetDesiredCapacity"| sp
    ca -.->|"never scaled"| cp

    style sp fill:#fff7ed,stroke:#b45309,stroke-width:2px
    style od fill:#f0fdf4,stroke:#16a34a,stroke-width:2px
```

One `InstanceGroup` = one AWS Auto Scaling Group. The control-plane groups
deliberately carry **no** autoscaler discovery tags, so the autoscaler cannot
touch them. See [kops-explained.md](kops-explained.md).

---

## 4. The two autoscalers

They are different components and only one can be demonstrated locally.

```mermaid
sequenceDiagram
    participant L as Load
    participant H as HPA<br/>(scales PODS)
    participant S as Scheduler
    participant C as Cluster Autoscaler<br/>(scales NODES)
    participant A as AWS ASG

    L->>H: CPU rises to 281% of the 70% target
    Note over H: reads metrics-server<br/>needs resource REQUESTS<br/>or reports <unknown>
    H->>S: replicas 2 → 4
    S-->>S: places 2 pods, 2 stay Pending<br/>"Insufficient cpu"

    Note over C: does NOT watch CPU —<br/>watches for Pending pods
    C->>A: SetDesiredCapacity +1
    A-->>S: new EC2 node joins
    S-->>S: remaining pods schedule

    L->>H: load drops
    H->>S: replicas 4 → 2
    Note over C: node under 50% used for 10 min<br/>→ cordon, drain, terminate
    C->>A: terminate instance
```

| | HPA | Cluster Autoscaler |
|---|---|---|
| Scales | Pods | Nodes |
| Triggered by | CPU/memory utilisation | **Pending** pods |
| Needs | metrics-server + resource requests | An AWS ASG |
| Where | `charts/csv-app/templates/hpa.yaml` | `infra/kops/cluster-autoscaler-values.yaml` |
| On minikube | **works** — verified by `make load` | **impossible** — one node, no ASG |

---

## 5. Object lifecycle

```mermaid
timeline
    title An uploaded CSV over its lifetime
    day 0    : S3 Standard : instant access : full storage cost
    day 30   : GLACIER_IR : still instant access : ~25% of Standard cost
    day 90   : DEEP_ARCHIVE : 12-48 hour restore : ~4% of Standard cost
    day 365  : deleted : disappears from the UI automatically
```

Glacier **Instant** Retrieval for the first hop, because the application
re-reads archived files on demand and a minutes-to-hours restore would break
that. The day counts are **invented** — no retention policy was supplied
([ADR-0007](adr/0007-glacier-ir-before-deep-archive.md), `ASSUMPTIONS.md`).

---

## 6. Configuration and deployment flow

Who owns what, and how a change reaches a running pod.

```mermaid
flowchart LR
    subgraph ansible["Ansible — owns application CONFIG"]
        gv["group_vars/<br/>all.yml + dev.yml + prod.yml"]
        njt["nginx.conf.j2"]
        gen["build/values.generated.yaml"]
        gv --> gen
        njt --> gen
    end

    subgraph helm["Helm — owns Kubernetes OBJECTS"]
        base["values.yaml<br/>(defaults)"]
        envv["values-dev.yaml<br/>values-prod.yaml"]
        tpl["templates/<br/>Deployment, Service, HPA,<br/>ConfigMap, Secret, Ingress, PDB"]
    end

    k8s[("Kubernetes")]

    base --> tpl
    envv --> tpl
    gen -->|"last -f wins"| tpl
    tpl -->|"helm upgrade --install --atomic"| k8s

    ds["devspace.yaml"] -.->|"dev inner loop,<br/>same chart"| tpl
```

Precedence: chart defaults → environment values → **Ansible's generated values
win**. `client_max_body_size` in nginx is *derived* from the application's
upload limit, so the two limits cannot disagree
([ADR-0008](adr/0008-helm-renders-k8s-ansible-owns-config.md)).

---

## 7. CI/CD

```mermaid
flowchart LR
    commit([push / PR])

    subgraph ci["ci.yml — application"]
        r["ruff + mypy"] --> t["pytest --cov"] --> o["OpenAPI<br/>staleness check"]
    end

    subgraph dk["docker.yml — image"]
        b["buildx build"] --> sc["trivy scan<br/>HIGH/CRITICAL"] --> sb["SBOM"] --> p["push to GHCR<br/>(not on PRs)"]
    end

    subgraph iac["iac.yml — infrastructure"]
        h["helm lint +<br/>template + kubeconform"]
        tf["terraform fmt / validate<br/>tflint / checkov<br/><i>no plan, no apply</i>"]
        an["ansible-lint +<br/>syntax-check"]
        y["yamllint + shellcheck"]
    end

    deploy["ansible-playbook site.yml<br/><i>manual — no cluster wired to CI</i>"]

    commit --> ci
    commit --> dk
    commit --> iac
    p -.-> deploy

    style deploy stroke-dasharray: 5 5
```

The image is **scanned before it is pushed**, not after — scanning afterwards
means shipping the vulnerability first. Terraform runs no `plan` and no `apply`:
there is no AWS account wired to this repository, deliberately
([ADR-0003](adr/0003-terraform-not-bound-to-aws-account-oidc.md)).
