#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$ROOT_DIR/external-secrets/secrets.env}"
ESO_VERSION="${ESO_VERSION:-2.5.0}"
CEPH_CSI_RBD_VERSION="${CEPH_CSI_RBD_VERSION:-3.16.2}"
CEPH_CLUSTER_ID="${CEPH_CLUSTER_ID:-861f6095-c334-413a-95a0-04e197f430c2}"
CEPH_MONITORS="${CEPH_MONITORS:-10.10.10.11:6789}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
BOOTSTRAP_AWS_SECRETS="${BOOTSTRAP_AWS_SECRETS:-true}"
WAIT_FOR_EXTERNAL_SECRETS="${WAIT_FOR_EXTERNAL_SECRETS:-true}"

info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
die() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

env_keys_from_file() {
  local file="$1"
  sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$file"
}

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  info "Loading environment from $file"

  local key
  local keys=()
  while IFS= read -r key; do
    keys+=("$key")
  done < <(env_keys_from_file "$file")

  declare -A before_set=()
  declare -A before_value=()
  for key in "${keys[@]}"; do
    if [[ -n "${!key+x}" ]]; then
      before_set["$key"]=1
      before_value["$key"]="${!key}"
    fi
  done

  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a

  for key in "${keys[@]}"; do
    if [[ -n "${before_set[$key]:-}" && -n "${before_value[$key]}" && -z "${!key:-}" ]]; then
      export "$key=${before_value[$key]}"
    fi
  done
}

require_env() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing required environment variables: ${missing[*]}"
  fi
}

validate_secret_env() {
  if [[ "$BOOTSTRAP_AWS_SECRETS" != "true" ]]; then
    return 0
  fi

  require_env \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    MYSQL_ROOT_PASSWORD \
    JWT_SECRET_KEY \
    ADMIN_PASSWORD \
    S3_ENDPOINT \
    S3_ACCESS_KEY \
    S3_SECRET_KEY \
    S3_BUCKET \
    CEPH_RBD_USER_KEY \
    BACKUP_AWS_ACCESS_KEY_ID \
    BACKUP_AWS_SECRET_ACCESS_KEY \
    BACKUP_AWS_S3_BUCKET \
    GRAFANA_ADMIN_PASSWORD

  if [[ -z "${ALERTMANAGER_CONFIG_FILE:-}" && -z "${ALERTMANAGER_CONFIG:-}" ]]; then
    die "Missing required environment variable: ALERTMANAGER_CONFIG_FILE or ALERTMANAGER_CONFIG"
  fi

  if [[ -n "${ALERTMANAGER_CONFIG_FILE:-}" && ! -f "$ALERTMANAGER_CONFIG_FILE" ]]; then
    die "ALERTMANAGER_CONFIG_FILE does not exist: $ALERTMANAGER_CONFIG_FILE"
  fi
}

need kubectl
need helm

[[ -f "$LOCAL_SECRETS_ENV_FILE" ]] || die "Secrets env file not found: $LOCAL_SECRETS_ENV_FILE"
load_env_file "$LOCAL_SECRETS_ENV_FILE"
validate_secret_env

if [[ "$BOOTSTRAP_AWS_SECRETS" == "true" ]]; then
  need aws
  need python3
fi

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

kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=120s
kubectl wait --for=condition=Established crd/externalsecrets.external-secrets.io --timeout=120s

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

if [[ "$BOOTSTRAP_AWS_SECRETS" == "true" ]]; then
  info "Creating or updating AWS Secrets Manager application secrets"
  "$ROOT_DIR/external-secrets/bootstrap-aws-secrets.sh"
fi

info "Applying ExternalSecret and ClusterSecretStore resources"
kubectl apply -f "$ROOT_DIR/external-secrets"

if [[ "$WAIT_FOR_EXTERNAL_SECRETS" == "true" ]]; then
  info "Waiting for ExternalSecret resources"
  kubectl -n apps wait externalsecret/mariadb-secret --for=condition=Ready --timeout=180s
  kubectl -n apps wait externalsecret/ceph-secret --for=condition=Ready --timeout=180s
  kubectl -n data wait externalsecret/mariadb-secret --for=condition=Ready --timeout=180s
  kubectl -n ceph-csi-rbd wait externalsecret/ceph-csi-rbd-secret --for=condition=Ready --timeout=180s
  kubectl -n backup wait externalsecret/mariadb-secret --for=condition=Ready --timeout=180s
  kubectl -n backup wait externalsecret/ceph-secret --for=condition=Ready --timeout=180s
  kubectl -n backup wait externalsecret/aws-secret --for=condition=Ready --timeout=180s
  kubectl -n monitoring wait externalsecret/grafana-admin-secret --for=condition=Ready --timeout=180s
  kubectl -n monitoring wait externalsecret/alertmanager-config-secret --for=condition=Ready --timeout=180s
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
