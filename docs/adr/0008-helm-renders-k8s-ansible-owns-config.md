# ADR-0008: Helm renders Kubernetes objects; Ansible owns application config

- **Status:** Accepted
- **Date:** 2026-08-07

## Context

The case study asks for two things that overlap:

> Implementing/using basic configuration management with Ansible (to have
> application configs in Ansible)
>
> Use helm to render Kubernetes objects for re-using while creating new
> environments

Both tools can template YAML. Used carelessly they fight: Ansible templating
Kubernetes manifests makes Helm pointless; Helm holding all configuration makes
Ansible pointless.

There is also a conceptual mismatch worth naming. Ansible's classic job is
configuring a fleet of servers over SSH. There is no such fleet here — **kops
owns the node lifecycle**. Nodes are cattle created from an AMI by an ASG; SSHing
in to configure them would be fighting the platform.

## Decision

Draw a clean seam:

- **Ansible owns application configuration VALUES.** `ansible/group_vars/all.yml`
  holds the defaults; `dev.yml` and `prod.yml` hold the per-environment
  overrides. The `app_config` role renders these — plus `nginx.conf.j2` — into
  `ansible/build/values.generated.yaml`.
- **Helm owns the Kubernetes OBJECTS.** The chart templates the Deployment,
  Service, HPA, ConfigMap, Secret, Ingress and PDB. It never decides *what* the
  log level should be, only *where* it goes.
- **The `k8s_deploy` role joins them**, running `helm upgrade --install` with
  values layered in precedence order:

```
charts/csv-app/values.yaml            chart defaults
charts/csv-app/values-<env>.yaml      environment shape (replicas, resources, ingress)
ansible/build/values.generated.yaml   Ansible's application config — wins
```

Ansible runs with `connection: local` against the current kubeconfig. This is
**cluster** configuration management, not **server-fleet** configuration
management, and the inventory says so.

## Consequences

- Neither tool duplicates the other. Reading `group_vars/prod.yml` tells you
  the application's production settings without reading a single Go template.
- One `nginx.conf.j2` in Ansible is the single source of truth for the nginx
  configuration. `client_max_body_size` is *derived* from `app_max_upload_bytes`,
  so nginx's limit and the application's limit cannot silently disagree.
- Changing config rolls the pods: the ConfigMap's content feeds a
  `checksum/config` annotation on the Deployment's pod template.
- `atomic: true` means a release that does not become healthy is rolled back
  rather than left half-applied.
- **Cost:** two tools where one would do. Helm alone with per-environment values
  files would cover this application. Ansible earns its place when there is also
  non-Kubernetes configuration to manage — and the case study asks for it
  explicitly.

## Alternatives considered

- **Ansible templates the Kubernetes manifests directly** (`k8s` module with
  Jinja). Satisfies "configs in Ansible" but abandons Helm, losing releases,
  rollback, and `helm diff`.
- **Helm alone, no Ansible.** Simplest. Rejected because the case study
  explicitly requires Ansible.
- **Kustomize overlays instead of Helm values.** A reasonable alternative — but
  the case study names Helm.
- **A separate inventory of real hosts for Ansible.** There are no long-lived
  hosts to configure; kops replaces nodes wholesale on `rolling-update`. Any
  configuration applied by SSH would be lost at the next node cycle.
