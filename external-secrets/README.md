# External Secrets

This repository keeps only External Secrets Operator resources in Git.
The secret values stay in AWS Secrets Manager and are synced into Kubernetes
Secrets per namespace.

Install the operator first:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --version 2.5.0 \
  --set installCRDs=true
```

Bootstrap the AWS credential Secret with `deploy.sh` or create it out of band.
Use an IAM principal scoped to the exact Secrets Manager ARNs used by this
project.

```bash
cp external-secrets/secrets.env.example external-secrets/secrets.env
vi external-secrets/secrets.env
bash deploy.sh
```

`deploy.sh` loads the ignored `external-secrets/secrets.env` file. The local
file should contain real values; keep the tracked `.example` as a template
unless you are intentionally editing defaults.

Manual creation:

```bash
kubectl -n external-secrets create secret generic aws-secretsmanager-credentials \
  --from-literal=access-key='<AWS_ACCESS_KEY_ID>' \
  --from-literal=secret-access-key='<AWS_SECRET_ACCESS_KEY>'
```

Expected AWS Secrets Manager JSON secrets:

- `prod/mariadb`
- `prod/ceph`
- `prod/ceph-rbd`
- `prod/aws`
- `prod/monitoring/grafana`
- `prod/monitoring/alertmanager`

If the cluster can use an EC2 instance profile, IRSA, EKS Pod Identity, or
kube2iam, prefer that over static access keys and update
`00-cluster-secret-store.yaml` accordingly.

## Required AWS Secrets

All AWS Secrets Manager entries are JSON objects. Keep the AWS secret names
exactly as listed because the ExternalSecret manifests reference these names.

| AWS secret name | JSON properties | Used by |
| --- | --- | --- |
| `prod/mariadb` | `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_DB_NAME`, `JWT_SECRET_KEY`, `ADMIN_PASSWORD` | Galera, auth-server, employee-server, backup |
| `prod/ceph` | `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET` | photo-service, backup |
| `prod/ceph-rbd` | `userKey` | Ceph CSI RBD `ceph-csi-rbd-secret`; `userID` is templated as `TEAM1` |
| `prod/aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_REGION` | backup CronJob AWS S3 destination |
| `prod/monitoring/grafana` | `admin-user`, `admin-password` | kube-prometheus-stack Grafana admin credentials |
| `prod/monitoring/alertmanager` | `alertmanager.yaml` | kube-prometheus-stack Alertmanager config secret |

Notes:

- `MYSQL_DATABASE` and `DATABASE_DB_NAME` should normally be the same value
  (`employees` in this project).
- The current Galera init SQL creates the database/table but does not create a
  separate app DB user. Either set `DATABASE_USER=root` and
  `DATABASE_PASSWORD` equal to `MYSQL_ROOT_PASSWORD`, or add user creation SQL
  before using a separate app user.
- `JWT_SECRET_KEY` must be identical for auth-server and employee-server.
  Restart those pods after rotating it because the value is injected as an env
  var.
- `ADMIN_PASSWORD` is the web login password for username `admin` unless
  `ADMIN_USERNAME` is added to the auth-server deployment.
- `prod/ceph-rbd.userKey` is the key string from `ceph auth get-key
  client.TEAM1`, not a whole keyring file.
- `prod/aws` is for the backup job's destination AWS S3 bucket. It is separate
  from the AWS credentials used by External Secrets Operator itself.

## Create Or Update AWS Secrets

Use `secrets.env.example` as a template and keep the real env file out of Git.
The repo `.gitignore` ignores `external-secrets/secrets.env`.

```bash
cp external-secrets/secrets.env.example external-secrets/secrets.env
vi external-secrets/secrets.env
set -a
. external-secrets/secrets.env
set +a

external-secrets/bootstrap-aws-secrets.sh
```

The script uses the normal AWS CLI credential chain to write to Secrets
Manager. It creates missing secrets and writes a new version for existing
secrets.

To run against a different prefix or region:

```bash
SECRET_PREFIX=prod AWS_REGION=ap-northeast-2 \
  external-secrets/bootstrap-aws-secrets.sh
```

Manual AWS CLI examples for the same JSON shape:

```bash
aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/mariadb \
  --secret-string '{
    "MYSQL_ROOT_PASSWORD":"<mysql-root-password>",
    "MYSQL_DATABASE":"employees",
    "DATABASE_USER":"root",
    "DATABASE_PASSWORD":"<mysql-root-password>",
    "DATABASE_DB_NAME":"employees",
    "JWT_SECRET_KEY":"<long-random-jwt-secret>",
    "ADMIN_PASSWORD":"<web-admin-password>"
  }'

aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/ceph \
  --secret-string '{
    "S3_ENDPOINT":"http://<ceph-rgw-host>:<port>",
    "S3_ACCESS_KEY":"<ceph-rgw-access-key>",
    "S3_SECRET_KEY":"<ceph-rgw-secret-key>",
    "S3_BUCKET":"<photo-bucket>"
  }'

aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/ceph-rbd \
  --secret-string '{"userKey":"<ceph-auth-key-from-client.TEAM1>"}'

aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/aws \
  --secret-string '{
    "AWS_ACCESS_KEY_ID":"<backup-destination-access-key>",
    "AWS_SECRET_ACCESS_KEY":"<backup-destination-secret-key>",
    "AWS_S3_BUCKET":"<backup-destination-bucket>",
    "AWS_REGION":"ap-northeast-2"
  }'

aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/monitoring/grafana \
  --secret-string '{
    "admin-user":"admin",
    "admin-password":"<grafana-admin-password>"
  }'

aws secretsmanager create-secret \
  --region ap-northeast-2 \
  --name prod/monitoring/alertmanager \
  --secret-string '{"alertmanager.yaml":"global:\n  resolve_timeout: 5m\nroute:\n  receiver: default\nreceivers:\n  - name: default\n"}'
```

Use `aws secretsmanager put-secret-value --secret-id <name> --secret-string ...`
instead of `create-secret` when the secret already exists.

## Validate

Check AWS Secrets Manager JSON shape and, when `kubectl` is configured, the
ExternalSecret/Kubernetes Secret sync status:

```bash
external-secrets/check-external-secrets.sh
```

Useful direct cluster checks:

```bash
kubectl get externalsecret -A
kubectl -n apps get secret mariadb-secret ceph-secret
kubectl -n data get secret mariadb-secret
kubectl -n ceph-csi-rbd get secret ceph-csi-rbd-secret
kubectl -n backup get secret mariadb-secret ceph-secret aws-secret
kubectl -n monitoring get secret grafana-admin-secret alertmanager-config-secret
```
