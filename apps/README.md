# apps — dev / prod 환경 분리 (Kustomize overlay)

AI 프로필 이미지 변환 서비스 워크로드를 **개발(dev) / 운영(prod)** 으로 분리해 GitOps 로
배포한다. 한 클러스터 안에서 **네임스페이스 + Kustomize overlay** 로 환경을 가른다.

## 디렉터리 구조

```text
apps/
├── base/                     # 공통 워크로드 (Deployment/Service/NetworkPolicy)
│   ├── auth-server/
│   ├── employee-server/
│   ├── gateway/
│   ├── photo-service/
│   ├── frontend/
│   ├── networkpolicy.yaml
│   └── kustomization.yaml    # namespace·이미지태그·HPA·PDB·Ingress 미포함 (overlay가 결정)
└── overlays/
    ├── prod/                 # → namespace: apps      (운영)
    │   ├── kustomization.yaml # base + HPA/PDB, images(main 태그)
    │   ├── hpa.yaml
    │   └── pdb.yaml
    └── dev/                  # → namespace: apps-dev  (개발)
        ├── kustomization.yaml # base + Ingress/ExternalSecret, images(dev 태그), replica/리소스 축소
        ├── ingress.yaml      # host: dev.kosa.local
        └── external-secrets.yaml
```

## 환경 분리 매핑

| 축 | dev | prod |
|---|---|---|
| 네임스페이스 | `apps-dev` | `apps` |
| ArgoCD Application | `kosa-apps-dev` (`41-apps-dev.yaml`) | `kosa-apps` (`40-apps.yaml`) |
| overlay 경로 | `apps/overlays/dev` | `apps/overlays/prod` |
| 트리거 브랜치(app repo) | `dev` push | `main` push (= 릴리즈/운영 승격) |
| 이미지 태그 출처 | `overlays/dev/kustomization.yaml` `images[].newTag` | `overlays/prod/...` |
| replica / 리소스 | **평소 0 (on-demand)**, 켤 땐 1 replica, photo 축소(2Gi/500m, affinity 해제) | 2~4 (HPA), photo-service 4Gi/2CPU |
| HPA / PDB | 없음 | 있음 |
| 노드 배치 | photo affinity 해제 → 여유 노드(worker3~6) | photo는 worker1/worker2 고정 |
| Ingress | dev 전용, `host: dev.kosa.local` | `infra/ingress.yaml` (host 없는 catch-all) |

> k8s-manifests 는 단일 브랜치(`dev`)를 유지한다. 환경 구분은 **브랜치가 아니라 overlay 경로/네임스페이스**로 한다.
> app repo 의 `dev`/`main` push 가 각각 dev/prod overlay 의 이미지 태그를 갱신하고, 두 갱신 모두 k8s-manifests `dev` 브랜치로 커밋된다.

## 배포 흐름 (GitOps)

```text
[app repo] dev push  ──CI──▶ overlays/dev/kustomization.yaml  newTag 갱신 ─┐
[app repo] main push ──CI──▶ overlays/prod/kustomization.yaml newTag 갱신 ─┤
                                                                          ▼
                                          k8s-manifests (dev 브랜치) 커밋
                                                                          ▼
   ArgoCD kosa-apps-dev (apps/overlays/dev)  → apps-dev 네임스페이스 sync
   ArgoCD kosa-apps     (apps/overlays/prod) → apps     네임스페이스 sync
```

운영 승격 = **app repo 에서 dev → main 으로 머지/릴리즈 PR**. main push 가 prod overlay 태그를 올린다.

## dev on-demand 운용 (리소스 절약)

dev 는 "항상 떠 있는 환경"이 아니라 **검증/시연할 때만 켜는 환경**이다. overlay 의 desired
replicas 는 0 이라 평소엔 Pod 가 없고 추가 리소스 점유가 거의 없다. `kosa-apps-dev` 의
`ignoreDifferences(.spec.replicas)` 덕분에 아래 수동 scale 을 ArgoCD 가 0 으로 되돌리지 않는다.

```bash
# dev 켜기 (테스트/시연 직전)
kubectl -n apps-dev scale deploy --all --replicas=1
kubectl -n apps-dev rollout status deploy/photo-service   # 기동 확인

# dev 끄기 (테스트 끝나면)
kubectl -n apps-dev scale deploy --all --replicas=0
```

- dev photo-service 는 base 의 nodeAffinity(worker1/worker2 고정)를 제거해, 켜질 때 여유 노드
  (worker3~6)로 스케줄된다 → prod 와 노드 경합 없음.
- **새 dev 이미지를 push 하면** overlay 가 갱신·sync 되며 desired replicas=0 이 다시 적용된다.
  즉 dev 가 자동으로 0 으로 내려가니, 새 이미지를 테스트하려면 위 scale 명령으로 다시 켠다.

## 적용 / 확인

```bash
# 로컬에서 overlay 렌더링 확인 (kustomize 또는 kubectl)
kubectl kustomize apps/overlays/dev
kubectl kustomize apps/overlays/prod

# 클러스터 적용은 ArgoCD 가 자동(자동 sync). 수동이면:
kubectl apply -k apps/overlays/prod
kubectl apply -k apps/overlays/dev

# 확인
kubectl get deploy,svc,ingress -n apps
kubectl get deploy,svc,ingress -n apps-dev
kubectl get externalsecret,secret -n apps-dev

# dev 접속 (도메인 없으므로 Host 헤더로):
curl -H "Host: dev.kosa.local" http://172.17.128.240/
# 또는 hosts 파일에 "172.17.128.240 dev.kosa.local" 추가 후 브라우저 접속
```

## ⚠ 적용 전 반드시 확인할 것

1. **app repo `main` 브랜치에도 갱신된 워크플로우가 있어야 한다.**
   GitHub Actions 는 트리거된 브랜치의 워크플로우 파일을 사용한다. `main` push 로 prod 배포가
   돌게 하려면 이 `deploy.yml` 변경을 `dev` 뿐 아니라 `main` 에도 머지해야 한다.
   (안 하면 `main` push 시 기존 "dev 트리거 전용" 워크플로우가 실행되어 prod 갱신이 안 됨)

2. **이미지 레지스트리 이름 일치.** overlay `images[].name` 은 `kosa1team/<service>` 로 하드코딩돼 있다.
   CI 의 `DOCKERHUB_USERNAME` 이 `kosa1team` 이 아니면 태그 갱신 매칭이 안 되니, 둘을 일치시킨다.

3. **dev 는 운영 DB·Ceph 를 공유한다 (격리 수준: "공유형").**
   `overlays/dev/external-secrets.yaml` 이 운영과 동일한 AWS 키(`prod/mariadb`, `prod/ceph`)를 재사용하고,
   `employee-server` 는 `mysql.data.svc.cluster.local`(운영 Galera) 에 그대로 붙는다.
   → **dev 테스트가 운영 데이터에 영향을 줄 수 있다.** 데이터까지 분리하려면:
   - AWS Secrets Manager 에 `dev/mariadb`, `dev/ceph` 생성 후 `overlays/dev/external-secrets.yaml` 의 `remoteRef.key` 교체
   - 별도 DB 스키마(`employees_dev`) 생성(Galera init SQL) 또는 dev 전용 DB 인스턴스 분리

4. **prod 무중단 전환.** `kosa-apps` 앱 이름은 그대로 두고 `path` 만 `apps` → `apps/overlays/prod` 로 바꿨다.
   렌더링 결과(Deployment/Service/HPA/PDB/NetworkPolicy, 이미지 태그)는 기존과 동일하므로
   ArgoCD 가 운영 워크로드를 재생성하지 않고 그대로 채택한다.
