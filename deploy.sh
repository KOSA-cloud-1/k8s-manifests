#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESO_VERSION="${ESO_VERSION:-2.5.0}"
CEPH_CSI_RBD_VERSION="${CEPH_CSI_RBD_VERSION:-3.16.2}"
CEPH_CLUSTER_ID="${CEPH_CLUSTER_ID:-861f6095-c334-413a-95a0-04e197f430c2}"
CEPH_MONITORS="${CEPH_MONITORS:-10.10.10.11:6789}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

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
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1 || \
   ! kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  info "Installing ArgoCD"
  kubectl apply --server-side --force-conflicts -n argocd -f "$ARGOCD_INSTALL_URL"
  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
  kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
else
  info "ArgoCD CRD already exists"
fi

info "Installing or upgrading External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version "$ESO_VERSION" \
  --set installCRDs=true

if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  info "Creating or updating AWS Secrets Manager bootstrap credentials"
  kubectl -n external-secrets create secret generic aws-secretsmanager-credentials \
    --from-literal=access-key="$AWS_ACCESS_KEY_ID" \
    --from-literal=secret-access-key="$AWS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
elif kubectl -n external-secrets get secret aws-secretsmanager-credentials >/dev/null 2>&1; then
  info "Using existing external-secrets/aws-secretsmanager-credentials"
else
  die "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or create external-secrets/aws-secretsmanager-credentials first"
fi

info "Applying ExternalSecret and ClusterSecretStore resources"
kubectl apply -f "$ROOT_DIR/external-secrets"

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

info "Patching argocd-server service to NodePort"
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort"}}'

info "ArgoCD NodePort service"
kubectl get svc argocd-server -n argocd

if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  info "Applying ArgoCD root Application"
  kubectl apply -f "$ROOT_DIR/argocd/argo-app.yaml"
else
  die "ArgoCD CRD applications.argoproj.io not found after installation"
fi

info "Bootstrap complete"

