# n8n の Flux 移行 runbook

## このPRの範囲

n8n の **config activation**。外側 `Kustomization/n8n` だけ `suspend: false`。
merge すると Namespace / HelmRepository / PVC / 停止中 HelmRelease が reconcile される。
内側 HelmRelease は `suspend: true` のままなので、Helm upgrade は始まらない。
クラスタへの手動 apply、`flux resume`、手動 reconcile はしない。

## 構成（ライブ照合 2026-09-11）

- Namespace/release: `n8n`（Helm revision 7, deployed, chart `n8n-1.0.7`, app `1.85.1`）
- Chart: OCI `oci://8gears.container-registry.com/library` / `n8n` `1.0.7`
- Image: `n8nio/n8n:1.85.1@sha256:73c40a7fc6106e22d80ba48f753d991a7a9752b15a1b215a8a301b131badebf3`（ライブ imageID。Helm values の tag は空だったので digest をピンした）
- Service: LoadBalancer `192.168.11.207`、annotation `metallb.universe.tf/loadBalancerIPs`
- Ingress: `n8n.takutk.com`（class なし）
- PVC: `n8n-pvc` / `n8n-webhook-pvc` / `n8n-worker-pvc`、`nfs-client`、5Gi、RWO、Bound
- ExternalSecret: `n8n-key` → GSM `n8n-key`（Helm `extraManifests`。Secret 値は未比較）
- Redis: `redis-master.redis.svc.cluster.local:6379`（queue mode）
- Deployments: `n8n` / `n8n-webhook` / `n8n-worker` Ready 1/1

未モデル / 未比較:

- chart 全 defaults と live computed values の完全一致
- Ingress TLS の chart 既定 `workflow.example.com`（live Helm values にあるが、Git helmfile には無い）
- helmfile にあって live extraEnv に無い `N8N_PORT` / `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS`

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（完了）
2. Config activation（このPR）: 外側だけ `suspend: false`、外側 marker と Namespace marker を外す。内側は `suspend: true` と marker 付き。`n8nActivation.stage` は `config-active`。
3. App activation（別PR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 Helm release を adopt する。helmfile は Ready 後の別PRで archive する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
