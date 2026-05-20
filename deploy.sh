#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESO_VERSION="${ESO_VERSION:-2.5.0}"
CEPH_CSI_RBD_VERSION="${CEPH_CSI_RBD_VERSION:-3.16.2}"
CEPH_CLUSTER_ID="${CEPH_CLUSTER_ID:-861f6095-c334-413a-95a0-04e197f430c2}"
CEPH_MONITORS="${CEPH_MONITORS:-10.10.10.11:6789}"

info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need kubectl
need helm

info "Applying namespaces"
kubectl apply -f "$ROOT_DIR/namespaces/00-namespaces.yaml"

info "Installing or upgrading External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version "$ESO_VERSION" \
  --set installCRDs=true

if ! kubectl -n external-secrets get secret aws-secretsmanager-credentials >/dev/null 2>&1; then
  warn "Missing bootstrap Secret external-secrets/aws-secretsmanager-credentials"
  warn "Create it out of band with restricted AWS Secrets Manager credentials before syncing ExternalSecrets."
else
  info "Applying ExternalSecret and ClusterSecretStore resources"
  kubectl apply -f "$ROOT_DIR/external-secrets"
fi

info "Installing or upgrading Ceph CSI RBD"
values_file="$(mktemp /tmp/ceph-csi-rbd-values.XXXXXX.yaml)"
{
  printf 'csiConfig:\n'
  printf '  - clusterID: %s\n' "$CEPH_CLUSTER_ID"
  printf '    monitors:\n'
  IFS=',' read -ra monitors <<< "$CEPH_MONITORS"
  for monitor in "${monitors[@]}"; do
    printf '      - %s\n' "$monitor"
  done
} > "$values_file"

helm repo add ceph-csi https://ceph.github.io/csi-charts >/dev/null
helm repo update ceph-csi >/dev/null
helm upgrade --install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
  --namespace ceph-csi-rbd \
  --create-namespace \
  --version "$CEPH_CSI_RBD_VERSION" \
  -f "$values_file"
rm -f "$values_file"

info "Applying Ceph RBD StorageClass"
kubectl apply -f "$ROOT_DIR/storage/ceph-csi-rbd/00-storageclass.yaml"

if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  info "Applying ArgoCD root Application"
  kubectl apply -f "$ROOT_DIR/argocd/argo-app.yaml"
else
  warn "ArgoCD CRD applications.argoproj.io not found; install ArgoCD first, then apply argocd/argo-app.yaml."
fi

info "Bootstrap complete"
