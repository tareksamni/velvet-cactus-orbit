#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Create the cluster from the manifests in this directory.
#
# THIS HAS NEVER BEEN RUN. There is no AWS account in play and the case study
# says a running cluster is not expected. The script exists so the manifests
# are not left context-free — it shows the order of operations, the
# prerequisites, and the commands a real deployment would use.
#
# It refuses to do anything without --confirm, precisely because it creates
# real, billable AWS infrastructure.
# ---------------------------------------------------------------------------
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-csv-app.k8s.local}"
STATE_BUCKET="${STATE_BUCKET:-kops-state-REPLACE-ME}"
OIDC_BUCKET="${OIDC_BUCKET:-csv-app-oidc-store-REPLACE-ME}"
REGION="${REGION:-eu-west-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KOPS_STATE_STORE="s3://${STATE_BUCKET}"

if [[ "${1:-}" != "--confirm" ]]; then
  cat <<EOF
This script creates real AWS infrastructure and costs real money:
  3 x m6i.large control-plane instances (on-demand)
  3 x m6i.large workers               (on-demand, nodes-ondemand)
  2+ x mixed spot instances           (nodes-spot, up to 20)
  NAT gateways in 3 AZs, an internal NLB, EBS volumes

Before running, you must:
  1. Have AWS credentials with permission to create VPC/EC2/IAM/S3/Route53.
  2. Create and version the state store and OIDC discovery buckets:
       aws s3 mb s3://${STATE_BUCKET} --region ${REGION}
       aws s3api put-bucket-versioning --bucket ${STATE_BUCKET} \\
         --versioning-configuration Status=Enabled
       aws s3 mb s3://${OIDC_BUCKET} --region ${REGION}
  3. Replace every REPLACE-ME placeholder in cluster.yaml.
  4. Pin a real AMI id for ${REGION} in the ig-*.yaml files:
       kops get assets --name ${CLUSTER_NAME}
  5. Narrow kubernetesApiAccess/sshAccess in cluster.yaml from 0.0.0.0/0.

Re-run with --confirm to proceed.
EOF
  exit 1
fi

command -v kops >/dev/null || { echo "kops not installed: https://kops.sigs.k8s.io/getting_started/install/" >&2; exit 1; }
command -v aws  >/dev/null || { echo "aws cli not installed" >&2; exit 1; }

echo "==> Registering the cluster and instance groups from manifests"
# `kops create -f` writes the spec into the state store. It does NOT create any
# AWS resources — that is what `kops update cluster --yes` does below.
kops create -f "${HERE}/cluster.yaml"
kops create -f "${HERE}/ig-control-plane.yaml"
kops create -f "${HERE}/ig-nodes-ondemand.yaml"
kops create -f "${HERE}/ig-nodes-spot.yaml"

echo "==> Creating an SSH key for the nodes"
kops create secret --name "${CLUSTER_NAME}" sshpublickey admin -i ~/.ssh/id_rsa.pub

echo "==> Previewing the changes (nothing is created yet)"
kops update cluster --name "${CLUSTER_NAME}"

echo "==> Applying — this creates the AWS resources"
kops update cluster --name "${CLUSTER_NAME}" --yes --admin

echo "==> Waiting for the cluster to become healthy (10-15 minutes is normal)"
kops validate cluster --name "${CLUSTER_NAME}" --wait 15m

echo "==> Confirming the instance groups and their lifecycles"
kops get instancegroups --name "${CLUSTER_NAME}"
kubectl get nodes -L lifecycle,kops.k8s.io/instancegroup

echo "==> Confirming the Cluster Autoscaler is running and has found the ASGs"
kubectl -n kube-system get deploy cluster-autoscaler
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=30 | grep -i "node group" || true

cat <<EOF

Cluster is up. Next:
  helm upgrade --install csv-app charts/csv-app -f charts/csv-app/values-prod.yaml
  # or: ansible-playbook ansible/site.yml -e env=prod

Useful:
  kops rolling-update cluster --name ${CLUSTER_NAME} --yes   # apply spec changes to nodes
  kops delete cluster --name ${CLUSTER_NAME} --yes           # tear everything down
EOF
