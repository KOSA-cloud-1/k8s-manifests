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
AWS_ACCESS_KEY_ID='<AWS_ACCESS_KEY_ID>' \
AWS_SECRET_ACCESS_KEY='<AWS_SECRET_ACCESS_KEY>' \
bash deploy.sh
```

Manual creation:

```bash
kubectl -n external-secrets create secret generic aws-secretsmanager-credentials \
  --from-literal=access-key='<AWS_ACCESS_KEY_ID>' \
  --from-literal=secret-access-key='<AWS_SECRET_ACCESS_KEY>'
```

Expected AWS Secrets Manager JSON secrets:

- `prod/mariadb`
- `prod/ceph`
- `prod/aws`
- `prod/ceph-rbd`
- `prod/monitoring/grafana`
- `prod/monitoring/alertmanager`

If the cluster can use an EC2 instance profile, IRSA, EKS Pod Identity, or
kube2iam, prefer that over static access keys and update
`00-cluster-secret-store.yaml` accordingly.
