# ADR-0006: Split capacity into on-demand and diversified-spot instance groups

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study requires:

> Kubernetes cluster creation config for kops which has multiple ig, mixed
> instance group and lifecycle (spot and ondemand)
> Have cluster autoscaler for all instance groups

Spot instances are 60–90% cheaper than on-demand and can be reclaimed by AWS
with two minutes' notice.

## Decision

Two worker instance groups with different lifecycles, plus three on-demand
control-plane groups:

| Group | Lifecycle | Size | Taint |
|---|---|---|---|
| `control-plane-eu-west-1{a,b,c}` | on-demand | 1–1 each | (control plane) |
| `nodes-ondemand` | on-demand | 3–6 | none |
| `nodes-spot` | 100% spot, 4 instance types | 2–20 | `spot=true:PreferNoSchedule` |

The spot group uses a `mixedInstancesPolicy` with `onDemandBase: 0`,
`onDemandAboveBase: 0` and `spotAllocationStrategy: capacity-optimized`.

## Consequences

- **The control plane is never on spot.** An interruption would take an etcd
  member with it. The saving is not worth the risk.
- **The on-demand group is the floor.** Ingress controllers, cert-manager, the
  Cluster Autoscaler itself and the application's minimum replicas all have
  somewhere safe to land, even if spot capacity vanishes entirely.
- **Growth is cheap.** Scale-up beyond the baseline lands on spot at a fraction
  of the price.
- Workloads must be interruption-tolerant to benefit. This application is —
  it is stateless with no local state (ADR-0005), so a killed pod is replaced
  with no data loss.

### Why four instance types, all the same size

Spot capacity is allocated per *(instance type, availability zone)* pool. An ASG
restricted to `m6i.large` in one AZ competes for a single pool and is
interrupted whenever that pool tightens. Four comparable types across three AZs
is **twelve pools**; a shortage in one is absorbed by the others.

All four (`m6i.large`, `m5.large`, `m5a.large`, `m5n.large`) are 2 vCPU / 8 GiB
deliberately. Mixing sizes would make the Cluster Autoscaler's capacity
arithmetic unreliable — it could not predict how much room a new node provides.

### Why `capacity-optimized` and not `lowest-price`

`lowest-price` chases the cheapest pool, which is usually the one closest to
exhaustion — you save a little and get interrupted a lot. `capacity-optimized`
picks pools with the deepest spare capacity: marginally more expensive,
materially more stable. For anything serving traffic that is the right trade.

### Why `PreferNoSchedule` and not `NoSchedule`

`NoSchedule` keeps every workload off spot unless it explicitly tolerates the
taint. Safe, but it strands the capacity you are paying for whenever someone
forgets the toleration.

`PreferNoSchedule` makes the scheduler treat spot as a last resort for
workloads that have not opted in, while still allowing them there under
pressure. Workloads that *have* opted in — this application, via a toleration
plus a `preferredDuringScheduling` node affinity for `lifecycle: Spot` — land
there preferentially.

Toleration alone would only make spot *permitted*. The affinity is what makes it
*preferred*. Both are needed, or the split exists on paper only.

## Alternatives considered

- **All on-demand.** Simplest and most stable; roughly 3× the compute bill.
- **All spot.** Cheapest, but a correlated interruption across pools could take
  the whole service down with nothing to fall back to.
- **One ASG with `onDemandBase: 3`.** AWS supports mixing both lifecycles in a
  single ASG. Rejected because separate groups let the two kinds of capacity be
  reasoned about, labelled, tainted, scaled and costed independently — and let
  the scheduler distinguish them, which a single ASG cannot.
- **Karpenter instead of the Cluster Autoscaler.** Genuinely better at
  bin-packing and diversification. Rejected because the case study explicitly
  asks for kops with cluster-autoscaler.
