# ADR-0009: DevSpace against the real chart, not a parallel docker-compose stack

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

Developing an application that runs as two containers in one pod, behind nginx,
against object storage, needs a fast inner loop. Rebuilding an image and running
`helm upgrade` for every one-line change is intolerable.

The usual answer is a `docker-compose.yml` that approximates the deployment.

## Decision

Use **DevSpace**, configured to deploy **the same Helm chart** the release path
deploys, with file sync and hot reload into the running pod.

```
devspace dev
  -> builds the image into minikube's docker daemon
  -> helm-installs charts/csv-app with values-dev.yaml
  -> syncs ./app into the app container
  -> runs uvicorn --reload there
  -> forwards :8080 (nginx) and :8000 (app)
```

Dev-only overrides (`replicaCount: 1`, HPA off, `--reload`) live in
`devspace.yaml`, **not** in `values-dev.yaml` — so `values-dev.yaml` stays an
honest deployable environment rather than becoming a development special case.

## Consequences

- **The dev environment cannot drift from the deployment.** There is no second
  description of how the application runs. A change to the chart is immediately
  felt by every developer.
- **The real serving path is exercised during development**: nginx in front,
  static assets off the shared `emptyDir`, the same probes, the same ConfigMap.
  A misconfigured nginx location block fails on a developer's machine rather
  than in the first deployment.
- Edits land in the running container in under a second; no rebuild, no
  redeploy.
- **Static assets need a second sync target, which is not obvious.** nginx does
  not serve `/app/static`; it serves `/shared/static`, which the `static-init`
  init container copied there once at pod start. An init container runs exactly
  once, so syncing a CSS change into `/app` leaves nginx serving the stale copy
  for the life of the pod. `devspace.yaml` therefore syncs `./app/static`
  straight into `/shared/static` as well, and patches that volumeMount writable
  for the dev pod only. Verified by editing `app.css` and re-requesting it
  through nginx.
- The dev pod also needs `readOnlyRootFilesystem: false`, patched dev-only:
  DevSpace cannot sync into a read-only filesystem, and production keeps the
  read-only root.
- **Cost:** a developer needs a running Kubernetes cluster. `make up` handles it,
  but it is heavier than `docker compose up` and needs more RAM.
- DevSpace is an extra tool to install (`make bootstrap`).
- It is **additive**. `ansible-playbook site.yml` remains the deployment path;
  DevSpace does not replace it, and nothing depends on DevSpace being installed.

## Alternatives considered

- **docker-compose.** Fast, familiar, and needs no cluster. Rejected because it
  is a *second, divergent description* of the runtime: a compose file cannot
  express an init container populating a shared volume, or pod-scoped
  networking between nginx and the app over loopback. Every chart change would
  need a matching compose change, and the two would drift — usually discovered
  when something works locally and fails in Kubernetes.
- **Skaffold.** Very similar and equally defensible. DevSpace was chosen for its
  simpler file-sync-plus-hot-reload story; Skaffold leans more on rebuild loops.
- **Run uvicorn directly on the laptop.** Fastest of all, and still supported for
  pure parser work (`pytest`). But it bypasses nginx entirely, so the
  shared-volume mechanism — one of the case study's actual requirements — is
  never exercised.
- **`kubectl cp` plus a manual restart.** What DevSpace automates. Doing it by
  hand is error-prone and slow.
