# kube-prometheus-stack

Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter를 `monitoring` 네임스페이스에 설치합니다.
Helm chart는 `prometheus-community/kube-prometheus-stack`을 사용합니다.

## 사전 준비

- Kubernetes cluster
- `kubectl`
- Helm 3
- Grafana를 `LoadBalancer` Service로 열기 때문에 bare-metal cluster라면 MetalLB가 먼저 동작해야 합니다.
- 기본 설정은 PVC 없이 설치됩니다. 영구 저장이 필요하면 StorageClass를 준비한 뒤 persistence overlay를 같이 적용합니다.

## 저장소 전략

현재 구성은 전용 monitoring worker node의 로컬 디스크에 Prometheus, Alertmanager, Grafana 데이터를 저장합니다.
나중에 장기 보관이나 백업이 필요하면 이 로컬 데이터를 백업하거나 Thanos 같은 구성을 추가해 object storage로 보낼 수 있습니다.

이 방식은 Ceph/Rook/CSI 없이 단순하고 빠르지만, monitoring node가 장애 나면 Prometheus/Grafana도 함께 내려갑니다.
PV `reclaimPolicy`는 `Retain`이라 Helm release를 삭제해도 로컬 데이터는 자동 삭제되지 않습니다.
전용 monitoring node 디스크는 100Gi 이상을 권장하며, 현재 PV 크기는 Prometheus 30Gi, Grafana 5Gi, Alertmanager 2Gi입니다.

## 설치

아래 명령은 `k8s-manifests/` 디렉터리에서 실행합니다.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 85.2.0 \
  -f monitoring/kube-prometheus-stack-values.yaml
```

## 상태 확인

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
kubectl get prometheus,alertmanager -n monitoring
```

Grafana admin 비밀번호는 ExternalSecret이 AWS Secrets Manager에서 동기화한 `grafana-admin-secret`에 있습니다.

```bash
kubectl get secret -n monitoring grafana-admin-secret \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

Grafana 접속 주소는 LoadBalancer IP를 확인합니다.

```bash
kubectl get svc -n monitoring kube-prometheus-stack-grafana
```

LoadBalancer IP가 없거나 임시로만 접속하려면 port-forward를 사용합니다.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

브라우저에서 `http://localhost:3000`으로 접속하고, 계정은 `admin`과 위 Secret 비밀번호를 사용합니다.

## PVC 사용

Prometheus, Alertmanager, Grafana 데이터를 전용 monitoring node 로컬 디스크에 보존하려면 먼저 node를 준비합니다.

```bash
kubectl label node <node-name> dedicated=monitoring
kubectl taint node <node-name> dedicated=monitoring:NoSchedule
```

그 node에 접속해서 local PV 경로를 만듭니다.

```bash
sudo mkdir -p /mnt/monitoring/prometheus /mnt/monitoring/alertmanager /mnt/monitoring/grafana
sudo chmod 0777 /mnt/monitoring/prometheus /mnt/monitoring/alertmanager /mnt/monitoring/grafana
```

디렉터리를 같은 디스크에 만들면 Kubernetes의 local PV `capacity`는 스케줄링 기준일 뿐 실제 디렉터리별 quota는 아닙니다.
Prometheus는 `retentionSize: 24GB`로 TSDB 사용량을 제한합니다.

그 다음 local StorageClass, PV, Grafana PVC를 만들고 Helm overlay를 적용합니다.

```bash
kubectl create namespace monitoring
kubectl apply -f monitoring/local-storage.yaml
kubectl get storageclass
kubectl get pv

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 85.2.0 \
  -f monitoring/kube-prometheus-stack-values.yaml \
  -f monitoring/kube-prometheus-stack-persistence-values.yaml
```

## 애플리케이션 메트릭 수집

이 values 파일은 Prometheus가 모든 네임스페이스의 `ServiceMonitor`, `PodMonitor`, `Probe`, `PrometheusRule`, `ScrapeConfig`를 감지하도록 설정되어 있습니다. 앱에서 `/metrics`를 노출한다면 Service port에 이름을 붙이고 ServiceMonitor를 추가하면 됩니다.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: example-app
  namespace: apps
spec:
  selector:
    matchLabels:
      app: example-app
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

## 업그레이드

```bash
helm repo update

helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 85.2.0 \
  -f monitoring/kube-prometheus-stack-values.yaml
```

chart version을 올릴 때는 CRD 변경이 포함될 수 있으니 release note를 먼저 확인합니다.

## 삭제

```bash
helm uninstall kube-prometheus-stack -n monitoring
```

PVC와 CRD는 데이터 보호를 위해 남을 수 있습니다. 완전 삭제가 필요할 때만 PVC/CRD를 별도로 확인한 뒤 지웁니다.

## 초기화 (완전 재설치)

```bash
# 1. Helm 릴리즈 삭제
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
helm uninstall loki               -n monitoring 2>/dev/null || true
helm uninstall promtail           -n monitoring 2>/dev/null || true

# 2. PVC 삭제 (helm uninstall 후에도 남음)
kubectl delete pvc -n monitoring --all

# 3. PV 삭제 (reclaimPolicy: Retain 이라 PVC 삭제 후에도 남음)
kubectl delete pv monitoring-prometheus-pv \
                   monitoring-alertmanager-pv \
                   monitoring-grafana-pv \
                   monitoring-loki-pv 2>/dev/null || true

# 4. monitoring 노드에서 데이터 디렉터리 초기화 (노드에 ssh 접속 후)
sudo rm -rf /mnt/monitoring/prometheus/* \
            /mnt/monitoring/alertmanager/* \
            /mnt/monitoring/grafana/* \
            /mnt/monitoring/loki/*

# 5. ConfigMap (Loki 데이터소스) 삭제
kubectl delete configmap loki-grafana-datasource -n monitoring 2>/dev/null || true

# 6. ExternalSecret 이 생성한 Secret 삭제
kubectl delete secret grafana-admin-secret alertmanager-config-secret -n monitoring 2>/dev/null || true

# 7. StorageClass/PV 재생성 (local-storage.yaml 재적용)
kubectl apply -f monitoring/local-storage.yaml
```

재설치는 [설치](#설치) 섹션부터 다시 진행합니다.

---

# Loki + Promtail

Grafana Loki로 클러스터 전체 컨테이너 로그를 수집하고 Grafana에서 조회합니다.
Promtail이 DaemonSet으로 모든 노드의 로그를 수집해 Loki로 전송합니다.

## 설치

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana/loki \
  --namespace monitoring --create-namespace \
  --version 6.29.0 \
  -f monitoring/loki-values.yaml

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring --create-namespace \
  --version 6.16.6 \
  -f monitoring/promtail-values.yaml
```

## PVC 사용 (monitoring 노드 로컬 디스크)

모니터링 노드에 Loki 디렉터리를 추가로 만듭니다.

```bash
sudo mkdir -p /mnt/monitoring/loki
sudo chmod 0777 /mnt/monitoring/loki
```

`local-storage.yaml`에 이미 `monitoring-loki-pv` PV가 선언되어 있습니다.
ArgoCD `kosa-monitoring-local-storage` 앱이 자동으로 적용합니다.

PVC를 사용하는 Loki 설치:

```bash
helm upgrade --install loki grafana/loki \
  --namespace monitoring --create-namespace \
  --version 6.29.0 \
  -f monitoring/loki-values.yaml \
  -f monitoring/loki-persistence-values.yaml
```

## Grafana 데이터소스 등록

```bash
kubectl apply -f monitoring/loki-grafana-datasource.yaml
```

Grafana sidecar가 ConfigMap을 감지해 Loki 데이터소스를 자동으로 추가합니다.
Grafana → Explore → 데이터소스를 Loki로 전환하면 로그를 조회할 수 있습니다.

## 상태 확인

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail
kubectl logs -n monitoring -l app.kubernetes.io/name=promtail --tail=20
```

## 삭제

```bash
helm uninstall loki -n monitoring
helm uninstall promtail -n monitoring
```

---

# Alertmanager 설정

`alertmanagerSpec.configSecret: alertmanager-config-secret`으로 지정된 Kubernetes Secret에서
설정을 읽습니다. 이 Secret은 ExternalSecret `alertmanager-config-secret`이 AWS Secrets Manager
`prod/monitoring/alertmanager`의 `alertmanager.yaml` 키에서 동기화합니다.

## ALERTMANAGER_CONFIG_FILE 설정 방법

1. 템플릿을 git 외부로 복사하고 수정합니다.

   ```bash
   cp monitoring/alertmanager-config.yaml.example /tmp/alertmanager-config.yaml
   # 파일을 열어 Slack webhook URL 또는 SMTP 설정을 채웁니다.
   ```

2. `secrets.env`에 경로를 지정합니다.

   ```bash
   ALERTMANAGER_CONFIG_FILE=/tmp/alertmanager-config.yaml
   ```

3. 부트스트랩 스크립트로 AWS Secrets Manager에 업로드합니다.

   ```bash
   set -a; . /tmp/kosa-secrets.env; set +a
   external-secrets/bootstrap-aws-secrets.sh
   ```

4. ExternalSecret을 강제 동기화합니다.

   ```bash
   kubectl annotate externalsecret alertmanager-config-secret \
     -n monitoring \
     force-sync=$(date +%s) --overwrite
   ```

5. Alertmanager Pod를 재시작해 새 설정을 반영합니다.

   ```bash
   kubectl rollout restart statefulset -n monitoring \
     -l app.kubernetes.io/name=alertmanager
   ```
