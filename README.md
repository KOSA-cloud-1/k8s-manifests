# KOSA Kubernetes Manifests

이 저장소는 애플리케이션, Galera, 백업, 스토리지, 모니터링의 Kubernetes 선언 상태를 관리합니다.
운영 배포의 기준은 ArgoCD이며, `deploy.sh`는 최초 bootstrap 보조 용도로만 사용합니다.

## 저장소 구조

| 디렉터리 | 내용 |
|---|---|
| `argocd/` | app-of-apps root(`argo-app.yaml`) + child Application(`applications/`) |
| `namespaces/` | 네임스페이스 정의 |
| `apps/` | 앱 워크로드 — **Kustomize `base` + `overlays/{prod,dev}`** (dev/운영 네임스페이스 분리). 상세는 `apps/README.md` |
| `galera/` | MariaDB Galera StatefulSet (`data` ns) |
| `storage/ceph-csi-rbd/` | Ceph CSI RBD StorageClass/리소스 |
| `external-secrets/` | External Secrets Operator + ExternalSecret(AWS Secrets Manager) |
| `monitoring/` | kube-prometheus-stack/Loki/Promtail **Helm values** + local-storage PV + datasource |
| `infra/monitoring/` | 선언형 관측성: ServiceMonitor / PrometheusRule / Grafana dashboard ConfigMap |
| `infra/` | metallb-config, argocd-server-service 등 인프라 매니페스트 |
| `backup/` | 사진 백업 CronJob |
| `deploy.sh` | 최초 bootstrap 스크립트(운영 배포용 아님) |

## 문서 색인

| 문서 | 내용 |
|---|---|
| 이 문서(최상위) | 전체 구조 / 배포 순서 / Secret / Storage / Galera / Ingress |
| `apps/README.md` | **dev/prod 환경 분리(Kustomize overlay), on-demand dev, 이미지 태그/registry 주입** |
| `infra/monitoring/README.md` | 모니터링·알림·대시보드·HPA 상세 |
| `external-secrets/README.md` | ExternalSecret / AWS Secrets Manager 매핑 |
| `storage/ceph-csi-rbd/README.md` | Ceph CSI RBD |
| `backup/README.md` | 백업 CronJob |
| `monitoring/README.md` | Helm values 관련 |

## Namespace

- `apps`: gateway, auth-server, employee-server, photo-service, frontend, Ingress (PROD overlay)
- `apps-dev`: 동일 워크로드의 dev overlay (on-demand, 평소 0 replica)
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

모니터링은 Ceph가 아니라 전용 monitoring node(label `dedicated=monitoring`)의 local PV에 저장합니다.
관측성 리소스(ServiceMonitor/PrometheusRule/dashboard)와 HPA 상세는 `infra/monitoring/README.md` 참고.

저장/보존 (현재값):

- Prometheus: 30일 보존, `retentionSize: 80GB`, PV 100Gi
- Loki: 30일 보존(compactor retention), PV 60Gi
- Grafana: PV 10Gi, Alertmanager: PV 5Gi
- dedicated monitoring node 디스크: 200Gi 이상 권장(local PV capacity는 advisory)

스택 구성:

- `kube-prometheus-stack`(Prometheus/Grafana/Alertmanager/node-exporter/kube-state-metrics) +
  `loki`/`promtail`(로그) + `metrics-server`(HPA용 resource metrics)
- Grafana(LoadBalancer `172.17.128.242`)에 8개 대시보드 자동 로드:
  AI Profile / Cluster Overview / Workload / Ingress NGINX / Loki / Memory / Network / Gateway
- 앱 메트릭: photo-service `profile_image_*` + `http_request_duration_seconds`,
  gateway `http_request_duration_seconds`
- HPA: photo-service(memory 60% + cpu 60% 보조, min2/max4), gateway(cpu 70%, min2/max4)

장기 보관(30일+ 감사/추세/장애 회고)이 필요해지면 Thanos 또는 remote_write 도입을 검토합니다.
Grafana PVC/Alertmanager 설정은 정기 백업, Prometheus TSDB는 장기 보관 도입 전까지 best-effort.

## Ingress And Load Balancer

초기 bootstrap은 MetalLB가 아직 완전히 준비되지 않았을 수 있으므로 `NodePort`를 기본값으로 둡니다.
현재 NodePort 기본값:

- ArgoCD: `infra/argocd-server-service.yaml`
- ingress-nginx: `argocd/applications/06-ingress-nginx.yaml`
- Grafana: `monitoring/kube-prometheus-stack-values.yaml`

MetalLB chart와 `infra/metallb-config.yaml`이 정상 동기화된 뒤, 위 파일들의 `type`을
`LoadBalancer`로 바꾸고 주석 처리된 `metallb.io/loadBalancerIPs` annotation을 되살리면 됩니다.

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
cp external-secrets/secrets.env.example external-secrets/secrets.env
vi external-secrets/secrets.env
bash deploy.sh
```

`deploy.sh` loads `external-secrets/secrets.env`. To use another file, run
`SECRETS_ENV_FILE=/path/to/secrets.env bash deploy.sh`.

`argocd/argo-app.yaml`은 app-of-apps root Application(최초 부트스트랩용)입니다. 하위 Application은
`argocd/applications/`에서 관리하며, root 자신도 `argocd/applications/00-kosa-platform.yaml`로
**self-managed**되어 `targetRevision: dev`가 self-heal됩니다(수동 revision 드리프트 방지).

child Application 인벤토리 (sync-wave 오름차순 = 배포 순서):

| wave | Application | source | namespace |
|---|---|---|---|
| -40 | kosa-platform (self-managed root) | `argocd/applications/` | argocd |
| -30 | kosa-namespaces | `namespaces/` | default |
| -25 | metallb | chart metallb 0.15.3 | metallb-system |
| -24 | metallb-config | `infra/` | metallb-system |
| -20 | external-secrets-operator | chart external-secrets 2.5.0 | external-secrets |
| -15 | ingress-nginx | chart ingress-nginx 4.15.1 | ingress-nginx |
| -10 | metrics-server | chart metrics-server 3.12.2 | kube-system |
| -10 | kosa-external-secrets | `external-secrets/` | external-secrets |
| -8 | ceph-csi-rbd | chart ceph-csi-rbd 3.16.2 | ceph-csi-rbd |
| -5 | kosa-storage | `storage/ceph-csi-rbd/` | ceph-csi-rbd |
| 0 | kosa-data | `galera/` | data |
| 10 | kosa-apps | `apps/overlays/prod` | apps |
| 10 | kosa-apps-dev | `apps/overlays/dev` | apps-dev |
| 20 | kosa-infra | `infra/` | apps |
| 30 | kosa-backup | `backup/` | backup |
| 40 | kosa-monitoring-local-storage | `monitoring/local-storage.yaml` | monitoring |
| 45 | kosa-monitoring-config | `monitoring/loki-grafana-datasource.yaml` | monitoring |
| 50 | kube-prometheus-stack | chart 85.2.0 + `monitoring/*-values.yaml` | monitoring |
| 55 | loki | chart 6.29.0 + `monitoring/loki-*values.yaml` | monitoring |
| 60 | promtail | chart 6.16.6 + `monitoring/promtail-values.yaml` | monitoring |
| 60 | monitoring-observability | `infra/monitoring/` | monitoring |

## Bootstrap Script

`deploy.sh`는 운영 배포 스크립트가 아닙니다. 다음만 수행합니다.

- namespace 생성
- ArgoCD 설치
- External Secrets Operator 설치
- AWS Secrets Manager 접근용 bootstrap Secret 생성/갱신
- ignored `external-secrets/secrets.env` 로드
- AWS Secrets Manager 애플리케이션 Secret 생성/갱신
- ExternalSecret 리소스 적용
- ExternalSecret Ready 상태 대기
- Ceph CSI RBD 설치
- ArgoCD 서버 Service를 초기 NodePort 상태로 유지
- ArgoCD root Application 적용

이미 AWS Secrets Manager 값이 준비되어 있어 업로드 단계를 건너뛰려면
`BOOTSTRAP_AWS_SECRETS=false bash deploy.sh`로 실행합니다. 이 경우에도
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`가 있으면 ESO bootstrap Secret을 갱신하고,
없으면 기존 `external-secrets/aws-secretsmanager-credentials` Secret을 사용합니다.
ExternalSecret Ready 대기를 건너뛰려면 `WAIT_FOR_EXTERNAL_SECRETS=false`를 사용할 수 있습니다.

ArgoCD CRD는 크기가 커서 `deploy.sh`가 server-side apply로 설치합니다. 수동 설치가 필요할 때도
아래처럼 실행합니다.

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

운영 변경은 Git commit/push와 ArgoCD sync를 통해 진행합니다.
