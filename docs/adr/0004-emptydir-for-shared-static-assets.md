# ADR-0004: Share static assets through a pod-scoped emptyDir

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study requires:

> Create deployment which contains Nginx and below web application running
> (within same pod) and sharing public files (css, js etc) through shared
> storage (**not nfs**).

So: two containers, one pod, nginx must serve files the application owns, and
NFS is explicitly excluded.

The static assets (`app/static/css/app.css`, `app/static/js/app.js`) are built
into the application image. Nginx's image does not contain them.

## Decision

Use an **`emptyDir` volume with an init container**:

```
initContainer static-init  (app image)  cp -R /app/static/. /shared/static/
container     app          (app image)  mounts /shared/static read-only
container     nginx        (nginx)      mounts /shared/static read-only,
                                        serves it at /static/
```

The volume is created with the pod, shared by every container in it, and
destroyed with it.

## Consequences

- **Satisfies the requirement literally**: real shared storage, not NFS.
- **No CSI driver, no StorageClass, no PersistentVolumeClaim.** Behaves
  identically on minikube and on the kops cluster, which is what lets the same
  chart deploy to both.
- **Assets are versioned with the image.** Roll back the Deployment and the CSS
  rolls back with it. There is no separate artifact to keep in sync.
- **Nothing to garbage-collect.** The volume dies with the pod.
- The copy runs on every pod start. It is a few kilobytes; the cost is
  immeasurable.
- The Cluster Autoscaler must be configured with
  `skip-nodes-with-local-storage: false`, or it will refuse to drain any node
  running a pod with an `emptyDir` and scale-down will silently never happen.
  This is noted in `infra/kops/cluster-autoscaler-values.yaml`.
- **Verified**: `make smoke` asserts the `X-Served-By: nginx-shared-volume`
  header, which is set only by nginx's `/static/` location block — proving the
  file came off the shared volume and did not fall through to the application.

## Alternatives considered

- **ReadWriteMany PVC (EFS on AWS).** Satisfies the letter of the requirement
  and allows cross-pod sharing. Rejected: there is no cross-pod state to share.
  The assets are immutable and already replicated with the image. It would add a
  CSI driver dependency, a cost line, a failure mode, and a StorageClass that
  minikube does not have — buying nothing.
- **Bake the assets into a custom nginx image.** Works, but creates two images
  that must be version-locked together. Forget once and nginx serves stale CSS
  against new HTML.
- **`hostPath`.** Node-scoped, not pod-scoped; breaks on multi-node clusters and
  requires elevated permissions. No.
- **Serve static files from the application itself.** Simplest of all, and FastAPI
  does mount `/static` for standalone development — but the case study
  specifically asks for nginx to serve them from shared storage.
