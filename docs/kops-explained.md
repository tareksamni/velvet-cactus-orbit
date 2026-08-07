# kops, explained

Written for someone who has not used kops before. It covers what kops actually
does, how it differs from minikube, and — the part that trips most people up —
the difference between the **two autoscalers** this project configures.

---

## 1. What kops is

**kops** ("Kubernetes Operations") provisions a real, production-grade
Kubernetes cluster on cloud infrastructure. AWS is its GA target; GCE,
DigitalOcean, Hetzner and OpenStack support exists but is beta or worse. In
practice: **kops means AWS**.

When you run `kops update cluster --yes`, it creates actual AWS resources:

| kops concept | AWS resource it produces |
|---|---|
| `Cluster` | VPC, subnets, route tables, NAT gateways, security groups, IAM roles |
| `Cluster.api.loadBalancer` | NLB/ELB in front of the API server |
| `Cluster.etcdClusters` | EBS volumes, one per etcd member |
| **`InstanceGroup`** | **One Auto Scaling Group** |
| `Cluster.metadata.name` | Route53 records, or gossip DNS for `.k8s.local` |
| `KOPS_STATE_STORE` | An S3 bucket holding the cluster's desired state |

Cluster state lives in that S3 bucket, not on your laptop. `kops` reads and
writes it on every command, which is why `KOPS_STATE_STORE` must be exported
before anything works.

### The two-phase model

This catches people out:

```console
$ kops create -f cluster.yaml        # writes the SPEC to the state store. Creates NOTHING in AWS.
$ kops update cluster --name ...     # shows what WOULD change (a dry run)
$ kops update cluster --name ... --yes   # actually creates/changes AWS resources
$ kops rolling-update cluster --yes  # replaces existing NODES to pick up spec changes
```

`kops update` reconciles infrastructure. It does **not** replace running nodes —
if you change `machineType`, the ASG's launch template updates but existing
instances keep running until `kops rolling-update` cycles them.

---

## 2. kops vs minikube

They are **not** two backends for the same thing.

| | kops | minikube |
|---|---|---|
| Where it runs | AWS | your laptop |
| Nodes | EC2 instances in ASGs | one container/VM |
| Networking | real VPC, subnets, NAT | a single bridge |
| Spot instances | yes | no such concept |
| Node autoscaling | yes, via ASG API | impossible |
| Cost | real money | free |
| Purpose | production | development |

You cannot deploy a kops config to minikube. There is no translation layer,
because `InstanceGroup` describes an AWS ASG and an ASG has no local analogue.

**What IS portable** is everything above the node layer — the Helm chart. The
same `Deployment`, `Service`, `HPA` and `ConfigMap` templates render for both;
only the values differ (`values-dev.yaml` vs `values-prod.yaml`). That is the
whole reason this project uses Helm.

This is why the case study asks for both: kops proves you can design the node
layer, minikube proves the workload layer actually works.

---

## 3. InstanceGroup → ASG

One `InstanceGroup` becomes exactly one Auto Scaling Group.

```yaml
# infra/kops/ig-nodes-ondemand.yaml
spec:
  role: Node
  machineType: m6i.large
  minSize: 3          # -> ASG MinSize
  maxSize: 6          # -> ASG MaxSize (and the autoscaler's ceiling)
  subnets:            # -> ASG VPCZoneIdentifier: balanced across 3 AZs
    - private-eu-west-1a
    - private-eu-west-1b
    - private-eu-west-1c
  nodeLabels:         # -> kubelet --node-labels, visible to the scheduler
    lifecycle: OnDemand
  cloudLabels:        # -> AWS tags on the ASG and its instances
    Project: csv-app
```

Note the distinction that matters:

- **`nodeLabels`** become **Kubernetes** node labels. The scheduler sees them;
  `nodeSelector` and `nodeAffinity` match on them.
- **`cloudLabels`** become **AWS tags**. Kubernetes cannot see them. The Cluster
  Autoscaler *can*, and uses them for discovery (§5).

This project defines four instance groups:

| Group | Lifecycle | Size | Purpose |
|---|---|---|---|
| `control-plane-eu-west-1{a,b,c}` | on-demand | 1–1 each | control plane + etcd, one per AZ |
| `nodes-ondemand` | on-demand | 3–6 | uninterruptible baseline capacity |
| `nodes-spot` | **spot, mixed types** | 2–20 | cheap elastic capacity |

---

## 4. Spot, and the mixed instances policy

```yaml
# infra/kops/ig-nodes-spot.yaml
mixedInstancesPolicy:
  instances: [m6i.large, m5.large, m5a.large, m5n.large]
  onDemandBase: 0             # no on-demand floor in THIS group
  onDemandAboveBase: 0        # 0% of growth is on-demand => 100% spot
  spotAllocationStrategy: capacity-optimized
```

**Why four instance types instead of one.** Spot capacity is allocated per
*(instance type, availability zone)* pool. An ASG restricted to `m6i.large` in
one AZ competes for a single pool, and gets interrupted the moment that pool
tightens. Four comparable types across three AZs is **twelve pools** — a
shortage in one is absorbed by the others.

All four are 2 vCPU / 8 GiB deliberately. Mixing sizes would make the Cluster
Autoscaler's capacity arithmetic unreliable, because it could not predict how
much room a new node would actually provide.

**`capacity-optimized` vs `lowest-price`.** `lowest-price` chases the cheapest
pool, which is usually the one closest to exhaustion. `capacity-optimized`
picks the pools with the deepest spare capacity: marginally more expensive,
materially fewer interruptions. For anything serving traffic, that is the right
trade.

**The taint.**

```yaml
taints:
  - spot=true:PreferNoSchedule
```

`PreferNoSchedule`, not `NoSchedule`. `NoSchedule` would keep every workload off
spot unless it explicitly tolerated the taint — safe, but it wastes the
capacity you are paying for. `PreferNoSchedule` makes the scheduler treat spot
as a last resort for workloads that have not opted in, while still allowing
them there under pressure.

The application opts in, in `charts/csv-app/values.yaml`:

```yaml
tolerations:
  - key: spot, operator: Equal, value: "true", effect: PreferNoSchedule
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 50
        preference: { matchExpressions: [{ key: lifecycle, operator: In, values: [Spot] }] }
```

Toleration says *"I am allowed on spot"*; affinity says *"I would rather be
there"*. Both are needed — this is what makes the spot/on-demand split actually
get used rather than merely declared.

---

## 5. The two autoscalers

**This is the part that trips everyone up.** The case study asks for both, and
they are entirely different components.

### HPA — scales PODS

Built into Kubernetes. Defined in `charts/csv-app/templates/hpa.yaml`.

- Reads CPU/memory from **metrics-server**
- Compares against a target utilisation
- Changes the Deployment's **replica count**

```
CPU at 90%, target 70%  ->  replicas 3 -> 4
```

**The gotcha:** the HPA computes utilisation as *usage ÷ request*. With no
resource **requests** set on the containers, there is no denominator, so it
reports `<unknown>` and never scales. This is the single most common reason an
HPA silently does nothing. Both containers in this chart set requests for
exactly that reason.

Works on minikube (`minikube addons enable metrics-server`). Verifiable with
`make load`.

### Cluster Autoscaler — scales NODES

A separate Deployment in `kube-system`. Configured by
`infra/kops/cluster-autoscaler-values.yaml` and the `clusterAutoscaler:` block
in `cluster.yaml`.

- Does **not** look at CPU
- Watches for **Pending** pods — pods the scheduler could not place
- Calls the **AWS ASG API** to raise desired capacity
- For scale-down: finds nodes under ~50% utilisation for ~10 minutes, drains
  them, and terminates

```
pod Pending: "0/6 nodes available: insufficient cpu"
  -> ASG nodes-spot desired 4 -> 5
  -> new EC2 instance joins
  -> pod schedules
```

**Cannot work on minikube.** One node, no ASG to call. This is why it ships as
reviewable configuration only.

### How they chain

```
traffic ↑
   HPA sees CPU > 70%          -> replicas 3 -> 8
   3 new pods cannot fit       -> Pending
   Cluster Autoscaler sees Pending -> ASG desired +1
   EC2 instance boots, joins   -> pods schedule
traffic ↓
   HPA scales pods back down   -> nodes go idle
   CA waits 10 min, drains, terminates them
```

Two independent control loops. Neither knows about the other; they interact
only through the scheduler.

---

## 6. Autoscaler discovery: the tags

The autoscaler is not told which ASGs it may touch. It **discovers** them by
tag:

```yaml
cloudLabels:
  k8s.io/cluster-autoscaler/enabled: "true"
  k8s.io/cluster-autoscaler/csv-app.k8s.local: "owned"
```

It enumerates ASGs carrying **both** the `enabled` tag and a tag naming this
cluster. An ASG missing either is invisible to it and will never be scaled —
which is exactly why the control-plane instance groups deliberately do *not*
carry them.

### Scale-from-zero hints

```yaml
k8s.io/cluster-autoscaler/node-template/label/lifecycle: "Spot"
k8s.io/cluster-autoscaler/node-template/taint/spot: "true:PreferNoSchedule"
k8s.io/cluster-autoscaler/node-template/resources/ephemeral-storage: "100G"
```

When an ASG has **zero** instances, the autoscaler has no running node to
inspect. It cannot know what labels or taints a new node would carry, so it
cannot tell whether a Pending pod would actually fit there. These
`node-template` tags tell it in advance.

The **taint** tag matters as much as the label. Without it, the autoscaler
would believe a new node could host any Pending pod, add one, and then watch
the pod stay Pending because of a taint it did not know about — repeating until
it hit `maxSize`. A tag omission becomes a runaway scale-up.

---

## 7. Operating it

```console
$ export KOPS_STATE_STORE=s3://kops-state-<unique>

$ kops get cluster                                 # list clusters
$ kops get instancegroups --name csv-app.k8s.local # list IGs and their sizes
$ kops edit ig nodes-spot --name ...               # change an IG
$ kops update cluster --name ... --yes             # reconcile AWS
$ kops rolling-update cluster --name ... --yes     # replace nodes to pick it up
$ kops validate cluster --wait 10m                 # is it healthy?
$ kops delete cluster --name ... --yes             # tear it all down
```

Two habits worth having:

- **Always `kops update cluster` without `--yes` first.** It prints the diff.
- **`kops rolling-update` respects PodDisruptionBudgets.** The chart ships one,
  so a node drain cannot take the service to zero.

---

## 8. Where to look in this repo

| File | What it shows |
|---|---|
| `infra/kops/cluster.yaml` | cluster spec: networking, etcd, IRSA, addons |
| `infra/kops/ig-control-plane.yaml` | 3 control-plane IGs, on-demand, one per AZ |
| `infra/kops/ig-nodes-ondemand.yaml` | uninterruptible baseline, discovery tags |
| `infra/kops/ig-nodes-spot.yaml` | **mixed instances policy, spot, taint** |
| `infra/kops/cluster-autoscaler-values.yaml` | **node autoscaling, heavily commented** |
| `infra/kops/create-cluster.sh` | the command sequence and its prerequisites |
| `charts/csv-app/templates/hpa.yaml` | **pod autoscaling** |

None of the kops configuration has ever been applied — there is no AWS account
in play, and the case study says a running cluster is not expected. See
[`ASSUMPTIONS.md`](../ASSUMPTIONS.md).
