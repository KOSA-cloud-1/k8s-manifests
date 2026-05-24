#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SECRET_PREFIX="${SECRET_PREFIX:-prod}"
DRY_RUN="${DRY_RUN:-false}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 is required" >&2
    exit 1
  }
}

need python3
if [[ "$DRY_RUN" != "true" ]]; then
  need aws
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

python3 - "$tmpdir" <<'PY'
import json
import os
from pathlib import Path
import sys

out = Path(sys.argv[1])

def required(name):
    value = os.environ.get(name)
    if value is None or value == "":
        raise SystemExit(f"missing required environment variable: {name}")
    return value

def optional(name, default):
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value

mysql_database = optional("MYSQL_DATABASE", optional("DATABASE_DB_NAME", "employees"))
database_db_name = optional("DATABASE_DB_NAME", mysql_database)
mysql_root_password = required("MYSQL_ROOT_PASSWORD")
database_user = optional("DATABASE_USER", "root")
database_password = optional("DATABASE_PASSWORD", mysql_root_password)

alertmanager_config_file = os.environ.get("ALERTMANAGER_CONFIG_FILE")
alertmanager_config = os.environ.get("ALERTMANAGER_CONFIG")
if alertmanager_config_file:
    alertmanager_config = Path(alertmanager_config_file).read_text()
if not alertmanager_config:
    raise SystemExit(
        "missing required environment variable: ALERTMANAGER_CONFIG_FILE or ALERTMANAGER_CONFIG"
    )

payloads = {
    "mariadb": {
        "MYSQL_ROOT_PASSWORD": mysql_root_password,
        "MYSQL_DATABASE": mysql_database,
        "DATABASE_USER": database_user,
        "DATABASE_PASSWORD": database_password,
        "DATABASE_DB_NAME": database_db_name,
        "JWT_SECRET_KEY": required("JWT_SECRET_KEY"),
        "ADMIN_PASSWORD": required("ADMIN_PASSWORD"),
    },
    "ceph": {
        "S3_ENDPOINT": required("S3_ENDPOINT"),
        "S3_ACCESS_KEY": required("S3_ACCESS_KEY"),
        "S3_SECRET_KEY": required("S3_SECRET_KEY"),
        "S3_BUCKET": required("S3_BUCKET"),
    },
    "ceph-rbd": {
        "userKey": required("CEPH_RBD_USER_KEY"),
    },
    "aws": {
        "AWS_ACCESS_KEY_ID": required("BACKUP_AWS_ACCESS_KEY_ID"),
        "AWS_SECRET_ACCESS_KEY": required("BACKUP_AWS_SECRET_ACCESS_KEY"),
        "AWS_S3_BUCKET": required("BACKUP_AWS_S3_BUCKET"),
        "AWS_REGION": optional("BACKUP_AWS_REGION", "ap-northeast-2"),
    },
    "monitoring-grafana": {
        "admin-user": optional("GRAFANA_ADMIN_USER", "admin"),
        "admin-password": required("GRAFANA_ADMIN_PASSWORD"),
    },
    "monitoring-alertmanager": {
        "alertmanager.yaml": alertmanager_config,
    },
}

for name, payload in payloads.items():
    (out / f"{name}.json").write_text(json.dumps(payload, ensure_ascii=True))
PY

upsert_secret() {
  local secret_name="$1"
  local file_name="$2"
  local description="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] would upsert ${secret_name}"
    return
  fi

  if aws secretsmanager describe-secret \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" >/dev/null 2>&1; then
    echo "[INFO] Updating ${secret_name}"
    aws secretsmanager put-secret-value \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --secret-string "file://${file_name}" >/dev/null
  else
    echo "[INFO] Creating ${secret_name}"
    aws secretsmanager create-secret \
      --region "$AWS_REGION" \
      --name "$secret_name" \
      --description "$description" \
      --secret-string "file://${file_name}" >/dev/null
  fi
}

upsert_secret "${SECRET_PREFIX}/mariadb" \
  "$tmpdir/mariadb.json" \
  "KOSA MariaDB, app auth, and JWT settings"
upsert_secret "${SECRET_PREFIX}/ceph" \
  "$tmpdir/ceph.json" \
  "KOSA Ceph RGW S3 settings"
upsert_secret "${SECRET_PREFIX}/ceph-rbd" \
  "$tmpdir/ceph-rbd.json" \
  "KOSA Ceph CSI RBD client key"
upsert_secret "${SECRET_PREFIX}/aws" \
  "$tmpdir/aws.json" \
  "KOSA backup destination AWS S3 settings"
upsert_secret "${SECRET_PREFIX}/monitoring/grafana" \
  "$tmpdir/monitoring-grafana.json" \
  "KOSA Grafana admin credentials"
upsert_secret "${SECRET_PREFIX}/monitoring/alertmanager" \
  "$tmpdir/monitoring-alertmanager.json" \
  "KOSA Alertmanager configuration"

echo "[INFO] Done"
echo "[INFO] Trigger ExternalSecret refresh with:"
echo "kubectl get externalsecret -A"
echo "kubectl -n ceph-csi-rbd annotate externalsecret ceph-csi-rbd-secret force-sync=\$(date +%s) --overwrite"
