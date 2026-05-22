# Monitoring Observability

AI 프로필 이미지 변환 서비스의 metrics / alert / dashboard를 GUI가 아니라 Kubernetes
manifest(GitOps)로 관리하기 위한 디렉터리이다.

기존 `k8s-manifests/monitoring/` 은 Helm values(kube-prometheus-stack, Loki, Promtail)를
보관한다. 이 디렉터리(`infra/monitoring/`)는 그 위에 얹는 **ServiceMonitor / PrometheusRule /
Grafana dashboard ConfigMap** 같은 선언형 관측성 리소스만 담는다.

## 구성 요소

| 종류 | 파일 | 대상 |
|---|---|---|
| ServiceMonitor | `servicemonitor/photo-service-servicemonitor.yaml` | apps/photo-service `http /metrics` (profile_image_*) |
| ServiceMonitor | `servicemonitor/gateway-servicemonitor.yaml` | apps/gateway `http /metrics` (http_request_duration_seconds) |
| ServiceMonitor | `servicemonitor/ingress-nginx-servicemonitor.yaml` | ingress-nginx controller `metrics` port |
| PrometheusRule | `prometheusrule/ai-profile-service-rules.yaml` | profile_image_* 기반 에러율/지연/부재 alert |
| PrometheusRule | `prometheusrule/kubernetes-workload-rules.yaml` | apps namespace Pod/Deployment alert |
| PrometheusRule | `prometheusrule/memory-rules.yaml` | 메모리 중점 alert(limit 근접/OOMKill/photo-service request 초과/노드 가용 부족) |
| Grafana Dashboard | `grafana-dashboards/ai-profile-service-dashboard.yaml` | AI Profile Service Monitoring |
| Grafana Dashboard | `grafana-dashboards/kubernetes-cluster-overview-dashboard.yaml` | Kubernetes Cluster Overview |
| Grafana Dashboard | `grafana-dashboards/kubernetes-workload-dashboard.yaml` | Kubernetes Workload Monitoring |
| Grafana Dashboard | `grafana-dashboards/ingress-nginx-dashboard.yaml` | Ingress NGINX Monitoring |
| Grafana Dashboard | `grafana-dashboards/loki-log-dashboard.yaml` | Loki Log Monitoring |
| Grafana Dashboard | `grafana-dashboards/memory-dashboard.yaml` | Memory Monitoring (클러스터/노드/파드 메모리, OOM) |
| Grafana Dashboard | `grafana-dashboards/gateway-dashboard.yaml` | Gateway Monitoring (RPS/P95/상태코드/5xx/Pod CPU) |

## 이 repository 실제 환경에 맞춘 값

`.claude/CLAUDE.md`의 기본 가정과 다른 부분을 실제 클러스터 매니페스트에서 확인해 반영했다.

| 항목 | CLAUDE.md 기본값 | 이 repo 실제값 | 근거 |
|---|---|---|---|
| app namespace | `app` | **`apps`** | `namespaces/00-namespaces.yaml`, `apps/*/*.yaml` |
| photo-service `/metrics` | 있다고 가정 | **있음** → photo-service ServiceMonitor 사용 | `app/photo-service/app.py`, `infra/monitoring/servicemonitor/photo-service-servicemonitor.yaml` |
| Grafana sidecar label | `grafana_dashboard: "1"` | `grafana_dashboard: "1"` (동일), `searchNamespace: ALL` | `monitoring/kube-prometheus-stack-values.yaml` |
| PrometheusRule selector | `release: prometheus` | label 무관(`ruleSelector: {}`)이지만 관례상 `release: kube-prometheus-stack` 부여 | `monitoring/kube-prometheus-stack-values.yaml` |
| Loki datasource 이름 | - | `Loki` (`http://loki:3100`) | `monitoring/loki-grafana-datasource.yaml` |
| ArgoCD repo / branch | 예시값 | `https://github.com/KOSA-cloud-1/k8s-manifests`, `dev` | `argocd/argo-app.yaml` |

> 참고: Prometheus는 `serviceMonitorSelector: {}` / `ruleSelector: {}` + `*NilUsesHelmValues: false`
> 로 설정되어 **모든 namespace의 ServiceMonitor / PrometheusRule을 label과 무관하게 선택**한다.
> 따라서 `release` label은 필수가 아니며 일관성/문서화 목적으로만 붙였다.

## 적용 방법

```bash
# 로컬 적용 (kustomize)
kubectl apply -k infra/monitoring
```

ArgoCD로는 별도 조작이 필요 없다. `argocd/applications/75-monitoring-observability.yaml`
Application이 app-of-apps(`kosa-platform`)에 의해 자동 등록되어 `infra/monitoring` 경로를
동기화한다. (sync-wave 60 — kube-prometheus-stack이 Operator CRD/Grafana를 먼저 설치한 뒤 동작)

## 확인 방법

```bash
kubectl get servicemonitor -n monitoring
kubectl get prometheusrule -n monitoring
kubectl get configmap -n monitoring -l grafana_dashboard=1

# Prometheus target 확인 (kube-prometheus-stack의 service 이름 사용)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
#  -> Status > Targets 에서 photo-service / ingress-nginx target 확인

# Grafana 접속
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
#  -> Dashboards 에서 아래 7개 자동 로드 확인:
#     AI Profile Service Monitoring / Kubernetes Cluster Overview /
#     Kubernetes Workload Monitoring / Ingress NGINX Monitoring / Loki Log Monitoring /
#     Memory Monitoring / Gateway Monitoring
#  -> 로그는 Explore 에서 Loki 데이터소스로 조회
```

## 데이터 출처: 실제 데이터

이 구성의 패널/alert는 실제 클러스터와 실제 photo-service metric을 쓴다.

| 영역 | 데이터 출처 |
|---|---|
| Kubernetes 기본 metrics (Node/Pod phase, Deployment replica 등) | **실제** — kube-state-metrics |
| Pod CPU / Memory / Restart | **실제** — cAdvisor + kube-state-metrics |
| Ingress NGINX (요청률/상태코드/지연) | **실제** — ingress-nginx controller metrics |
| Loki 로그 (app / ingress / argocd) | **실제** — Promtail이 수집한 클러스터 로그 |
| `profile_image_*` (Request/Success/Failure/Latency/Queue/Active) | **실제** — apps/photo-service `/metrics` |
| `http_request_duration_seconds` (gateway RPS/지연/상태코드) | **실제** — apps/gateway `/metrics` (prometheus-fastapi-instrumentator) |

### profile_image_* metric

`photo-service` 앱(`app/photo-service/app.py`)이 `/metrics` endpoint를 직접 제공한다.
Prometheus는 `servicemonitor/photo-service-servicemonitor.yaml`을 통해 `apps` namespace의
`photo-service` Service `http` port를 scrape한다.

- 노출 metric (이름은 기존 dashboard/alert와 동일):
  `profile_image_requests_total`, `profile_image_success_total`,
  `profile_image_failed_total`, `profile_image_processing_seconds`(histogram),
  `profile_image_queue_depth`, `profile_image_active_jobs`
- `profile_image_queue_depth`는 앱 내부 큐가 없으므로 0으로 노출한다.
- `fake-exporter/` 파일은 이전 시연용으로 남아 있지만 `kustomization.yaml`에서 참조하지 않는다.

### gateway metric (http_request_duration_seconds)

`gateway` 앱(`app/gateway/app.py`)은 FastAPI 프록시이며 `prometheus-fastapi-instrumentator`로
모든 라우트의 요청수/지연/상태코드를 자동 계측해 `/metrics`로 노출한다. catch-all 라우트가 없어
`/metrics`가 프록시에 가려지지 않는다. `servicemonitor/gateway-servicemonitor.yaml`이 `apps`
namespace의 `gateway` Service `http` port를 scrape한다.

- 주요 metric: `http_request_duration_seconds{handler,method,status}` (histogram)
  → `_count`(RPS), `_bucket`(P95 latency). status는 instrumentator 기본값상 `2xx`/`5xx`로 그룹화된다.
- Gateway Monitoring 대시보드가 RPS / handler별 P95 / status 분포 / 5xx rate / Pod CPU를 보여준다.

## HPA / Autoscaling

오토스케일링은 `metrics-server`(resource metrics) 기반이며 `apps` namespace 워크로드를 확장한다.
관측성과 별개 파이프라인이지만 함께 운영한다.

| 대상 | 파일 | 기준 | 비고 |
|---|---|---|---|
| metrics-server | `argocd/applications/04-metrics-server.yaml` | - | HPA `kubectl top`용 resource metrics 제공(`--kubelet-insecure-tls`) |
| photo-service HPA | `apps/photo-service/hpa.yaml` | **memory 60%** + cpu 60%(보조), min2/max4 | 메모리(이미지 바이트)가 주 신호. request 4Gi 기준 |
| gateway HPA | `apps/gateway/hpa.yaml` | **cpu 70%**, min2/max4 | 프록시라 메모리 거의 안 늘어 CPU가 주 신호 |

- HPA가 `.spec.replicas`를 관리하므로 `argocd/applications/40-apps.yaml`에 photo-service/gateway
  Deployment의 `.spec.replicas` `ignoreDifferences` + `RespectIgnoreDifferences=true`를 두어
  ArgoCD가 HPA와 충돌(replicas 되돌림)하지 않도록 했다.
- 메모리 알림 임계(80%)는 HPA 목표(60%)보다 **위**로 두어 "HPA로도 메모리를 못 잡는" 상황만 알린다.

## ⚠️ 동작 전제 / 후속 작업

### ingress-nginx metrics (활성화 완료, ArgoCD sync 필요)

`argocd/applications/06-ingress-nginx.yaml`의 Helm values에 아래를 추가해 controller metrics를
**활성화해 두었다.** (`controller.metrics.serviceMonitor.enabled: false` — ServiceMonitor는
이 디렉터리에서 직접 관리하므로 chart 내장본은 끔)

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false
```

- 활성화하면 controller Service에 name `metrics`(10254) port가 생기고
  `nginx_ingress_controller_*` metric이 노출되어 이 ServiceMonitor가 바로 scrape한다.
- 단, **ArgoCD가 `ingress-nginx` Application을 sync해 controller를 재배포**해야 실제로 port가
  생긴다. sync 전에는 Ingress NGINX Dashboard가 빈 상태일 수 있다.

## Loki label 원칙

Promtail(`monitoring/promtail-values.yaml`)은 CRI 파이프라인 + `labeldrop: [filename]`으로
`namespace`, `app`, `pod`, `container`, `node_name` 같은 안정적 label만 유지한다.
`user_id`, `request_id`, `filename`, `image_id` 처럼 자주 바뀌는 값은 label cardinality를
높이므로 label로 쓰지 않는다(로그 본문에만 남기고 LogQL `|=` / `| json` 으로 필터).
