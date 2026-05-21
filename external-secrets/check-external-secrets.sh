#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SECRET_PREFIX="${SECRET_PREFIX:-prod}"
SKIP_KUBECTL="${SKIP_KUBECTL:-false}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 is required" >&2
    exit 1
  }
}

need aws
need python3

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

check_aws_secret() {
  local secret_name="$1"
  shift
  local output_file="$tmpdir/$(echo "$secret_name" | tr '/' '_').json"

  if ! aws secretsmanager get-secret-value \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --query SecretString \
      --output json >"$output_file"; then
    echo "[FAIL] AWS ${secret_name}: missing or not readable"
    return 1
  fi

  if python3 - "$output_file" "$@" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
required_keys = sys.argv[2:]
try:
    secret_string = json.loads(path.read_text())
    data = json.loads(secret_string)
except Exception as exc:
    raise SystemExit(f"invalid JSON: {exc}")

missing = []
empty = []
for key in required_keys:
    if key not in data:
        missing.append(key)
    elif data[key] in (None, ""):
        empty.append(key)

if missing or empty:
    details = []
    if missing:
        details.append("missing=" + ",".join(missing))
    if empty:
        details.append("empty=" + ",".join(empty))
    raise SystemExit("; ".join(details))
PY
  then
    echo "[OK]   AWS ${secret_name}: required properties present"
  else
    echo "[FAIL] AWS ${secret_name}: required property check failed"
    return 1
  fi
}

check_k8s_secret() {
  local namespace="$1"
  local secret_name="$2"
  shift 2

  if ! kubectl -n "$namespace" get secret "$secret_name" -o json >"$tmpdir/k8s-${namespace}-${secret_name}.json" 2>/dev/null; then
    echo "[FAIL] K8s ${namespace}/${secret_name}: missing"
    return 1
  fi

  if python3 - "$tmpdir/k8s-${namespace}-${secret_name}.json" "$@" <<'PY'
import json
from pathlib import Path
import sys

obj = json.loads(Path(sys.argv[1]).read_text())
data = obj.get("data") or {}
missing = [key for key in sys.argv[2:] if key not in data or not data[key]]
if missing:
    raise SystemExit("missing=" + ",".join(missing))
PY
  then
    echo "[OK]   K8s ${namespace}/${secret_name}: required keys present"
  else
    echo "[FAIL] K8s ${namespace}/${secret_name}: required key check failed"
    return 1
  fi
}

check_externalsecret() {
  local namespace="$1"
  local name="$2"
  local condition

  if ! condition="$(kubectl -n "$namespace" get externalsecret "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"; then
    echo "[FAIL] ExternalSecret ${namespace}/${name}: missing"
    return 1
  fi

  if [[ "$condition" == "True" ]]; then
    echo "[OK]   ExternalSecret ${namespace}/${name}: Ready=True"
  else
    echo "[FAIL] ExternalSecret ${namespace}/${name}: Ready=${condition:-<unset>}"
    return 1
  fi
}

failures=0

check_aws_secret "${SECRET_PREFIX}/mariadb" \
  MYSQL_ROOT_PASSWORD MYSQL_DATABASE DATABASE_USER DATABASE_PASSWORD \
  DATABASE_DB_NAME JWT_SECRET_KEY ADMIN_PASSWORD || failures=$((failures + 1))
check_aws_secret "${SECRET_PREFIX}/ceph" \
  S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET || failures=$((failures + 1))
check_aws_secret "${SECRET_PREFIX}/ceph-rbd" \
  userKey || failures=$((failures + 1))
check_aws_secret "${SECRET_PREFIX}/aws" \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_S3_BUCKET AWS_REGION || failures=$((failures + 1))
check_aws_secret "${SECRET_PREFIX}/monitoring/grafana" \
  admin-user admin-password || failures=$((failures + 1))
check_aws_secret "${SECRET_PREFIX}/monitoring/alertmanager" \
  alertmanager.yaml || failures=$((failures + 1))

if [[ "$SKIP_KUBECTL" != "true" ]] && command -v kubectl >/dev/null 2>&1; then
  check_externalsecret apps mariadb-secret || failures=$((failures + 1))
  check_externalsecret apps ceph-secret || failures=$((failures + 1))
  check_externalsecret data mariadb-secret || failures=$((failures + 1))
  check_externalsecret ceph-csi-rbd ceph-csi-rbd-secret || failures=$((failures + 1))
  check_externalsecret backup mariadb-secret || failures=$((failures + 1))
  check_externalsecret backup ceph-secret || failures=$((failures + 1))
  check_externalsecret backup aws-secret || failures=$((failures + 1))
  check_externalsecret monitoring grafana-admin-secret || failures=$((failures + 1))
  check_externalsecret monitoring alertmanager-config-secret || failures=$((failures + 1))

  check_k8s_secret apps mariadb-secret \
    DATABASE_USER DATABASE_PASSWORD DATABASE_DB_NAME JWT_SECRET_KEY ADMIN_PASSWORD || failures=$((failures + 1))
  check_k8s_secret apps ceph-secret \
    S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET || failures=$((failures + 1))
  check_k8s_secret data mariadb-secret \
    MYSQL_ROOT_PASSWORD MYSQL_DATABASE || failures=$((failures + 1))
  check_k8s_secret ceph-csi-rbd ceph-csi-rbd-secret \
    userID userKey || failures=$((failures + 1))
  check_k8s_secret backup mariadb-secret \
    MYSQL_ROOT_PASSWORD DATABASE_USER DATABASE_PASSWORD DATABASE_DB_NAME || failures=$((failures + 1))
  check_k8s_secret backup ceph-secret \
    S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET || failures=$((failures + 1))
  check_k8s_secret backup aws-secret \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_S3_BUCKET AWS_REGION || failures=$((failures + 1))
  check_k8s_secret monitoring grafana-admin-secret \
    admin-user admin-password || failures=$((failures + 1))
  check_k8s_secret monitoring alertmanager-config-secret \
    alertmanager.yaml || failures=$((failures + 1))
else
  echo "[INFO] kubectl checks skipped"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "[FAIL] ${failures} check group(s) failed"
  exit 1
fi

echo "[OK] all configured external secret checks passed"
