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

Grafana admin 비밀번호는 Helm chart가 Secret으로 생성합니다.

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
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
  namespace: default
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
