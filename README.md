# KOSA Kubernetes Manifests

이 저장소는 애플리케이션, Galera, 백업, 스토리지, 모니터링의 Kubernetes 선언 상태를 관리합니다.
운영 배포의 기준은 ArgoCD이며, `deploy.sh`는 최초 bootstrap 보조 용도로만 사용합니다.

## Namespace

- `apps`: gateway, auth-server, employee-server, photo-service, frontend, Ingress
- `data`: Galera StatefulSet, DB Service
- `backup`: photo backup CronJob
- `monitoring`: kube-prometheus-stack, Grafana, Alertmanager, local PV
- `ceph-csi-rbd`: Ceph CSI RBD driver and CSI credentials
- `external-secrets`: External Secrets Operator

## Secret Management

Secret 값은 Git에 저장하지 않습니다. AWS Secrets Manager를 원본으로 유지하고,
External Secrets Operator가 네임스페이스별 Kubernetes Secret을 생성합니다.

이 방식이 `secret.yml`보다 나은 이유:

- Git 유출 사고의 blast radius를 줄일 수 있습니다.
- AWS IAM으로 읽기 권한을 좁게 줄 수 있습니다.
- 값 회전 후 ExternalSecret refresh로 클러스터 반영이 가능합니다.
- ArgoCD는 Secret 값이 아니라 Secret 동기화 규칙만 관리합니다.

필요한 AWS Secrets Manager JSON secret:

- `prod/mariadb`
- `prod/ceph`
- `prod/aws`
- `prod/ceph-rbd`
- `prod/monitoring/grafana`
- `prod/monitoring/alertmanager`

`external-secrets/aws-secretsmanager-credentials` Secret은 Git 밖에서 bootstrap합니다.
`deploy.sh`는 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` 환경변수가 있으면 이 Secret을
자동으로 생성/갱신합니다.
가능하면 static key보다 EC2 instance profile, IRSA, EKS Pod Identity, kube2iam 같은
short-lived credential 방식을 우선 검토합니다.

## Ceph Storage

사진 객체 데이터는 Ceph RGW를 S3 API로 사용합니다. `photo-service`와 `backup`은
`ceph-secret`에서 RGW endpoint/access key/bucket 정보를 읽습니다.

DB 데이터는 Ceph RBD PVC를 사용합니다.

- StorageClass: `ceph-rbd`
- Ceph cluster ID: `861f6095-c334-413a-95a0-04e197f430c2`
- RBD pool: `rbd-team1`
- Ceph auth entity: `client.TEAM1`
- CSI Secret `userID`: `TEAM1`
- reclaimPolicy: `Retain`
- encryption: disabled

Ceph CSI RBD driver는 현재 알려진 Ceph monitor 주소 `10.10.10.11:6789`를 사용합니다.
추가 monitor 주소를 알게 되면 `argocd/applications/08-ceph-csi-rbd.yaml`의 `monitors`에
항목을 더 추가합니다.


`galera/01-galera-pv.yaml`의 hostPath 정적 PV는 제거했습니다. Galera는 처음부터
`volumeClaimTemplates`로 `ceph-rbd` PVC를 생성합니다.

## Galera

Galera는 `data` 네임스페이스에서 3 replica StatefulSet으로 동작합니다.
각 Pod는 독립적인 RWO RBD 볼륨을 사용합니다. 앱은 아래 주소로 DB에 접속합니다.

```text
mysql.data.svc.cluster.local
```

운영 전 확인할 것:

- `client.TEAM1`이 `rbd-team1` pool에 필요한 최소 권한을 가지고 있는지
- Ceph CSI driver가 모든 worker node에서 Running 상태인지
- `ceph-rbd-smoke-test` PVC가 Bound 되는지
- Galera readiness가 `wsrep_ready=ON`으로 전환되는지

## Monitoring

요청대로 모니터링은 Ceph가 아니라 전용 monitoring node의 local PV에 저장합니다.
현재 권장 기본값은 다음과 같습니다.

- Prometheus: 15일 보존, `retentionSize: 24GB`, PV 30Gi
- Grafana: PV 5Gi
- Alertmanager: PV 2Gi
- dedicated monitoring node: 100Gi 이상 권장

아직 미정인 정책에 대한 제안:

- 단기 운영: 현재 local PV 유지, Prometheus 15일 보존, Grafana dashboard/config는 Git으로 관리
- 장애 허용: monitoring node 장애 시 메트릭 유실을 허용하되, 앱 운영에는 영향 없게 분리
- 장기 보관 필요 시점: 30일 이상 보존, 감사/용량 추세 분석, 장애 회고 지표가 필요해지면 Thanos 또는 remote_write 도입
- 백업: Grafana PVC와 Alertmanager 설정은 정기 백업, Prometheus TSDB는 장기 보관 도입 전까지 best-effort

## Ingress And Load Balancer

외부 흐름:

```text
NLB(TLS termination) -> EC2 HAProxy -> EC2 strongSwan VPN -> k8s ingress -> service -> pod
```

MetalLB pool:

```text
172.17.128.240-172.17.128.250
```

권장 IP 배정:

- ingress-nginx: `172.17.128.240`
- argocd-server: `172.17.128.241`
- grafana: `172.17.128.242`

주의: MetalLB pool이 `172.17.128.0/24`이므로 `172.16.128.241/242`는 오타로 보고
`172.17.128.241/242`를 기준으로 문서화했습니다.

## ArgoCD

권장 구조는 ArgoCD가 전체 steady-state를 소유하고, GitHub Actions는 이미지 빌드와
`k8s-manifests`의 image tag 업데이트만 수행하는 방식입니다.

Bootstrap:

```bash
AWS_ACCESS_KEY_ID='<AWS_ACCESS_KEY_ID>' \
AWS_SECRET_ACCESS_KEY='<AWS_SECRET_ACCESS_KEY>' \
bash deploy.sh
```

`argocd/argo-app.yaml`은 app-of-apps root Application입니다. 하위 Application은
`argocd/applications/`에서 관리합니다.

동기화 순서:

1. namespaces
2. MetalLB
3. External Secrets Operator
4. ingress-nginx
5. ExternalSecret/ClusterSecretStore
6. Ceph CSI RBD
7. StorageClass
8. Galera
9. apps
10. infra
11. backup
12. monitoring local storage

## Bootstrap Script

`deploy.sh`는 운영 배포 스크립트가 아닙니다. 다음만 수행합니다.

- namespace 생성
- ArgoCD 설치
- External Secrets Operator 설치
- AWS Secrets Manager 접근용 bootstrap Secret 생성/갱신
- ExternalSecret 리소스 적용
- Ceph CSI RBD 설치
- ArgoCD root Application 적용

ArgoCD CRD는 크기가 커서 `deploy.sh`가 server-side apply로 설치합니다. 수동 설치가 필요할 때도
아래처럼 실행합니다.

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

운영 변경은 Git commit/push와 ArgoCD sync를 통해 진행합니다.
