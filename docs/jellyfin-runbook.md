# Jellyfin の Flux 移行 runbook

## このPRの範囲

Jellyfin の **config activation**。外側 `Kustomization/jellyfin` だけ `suspend: false`。
merge すると Namespace / HelmRepository / media PV・PVC / 停止中 HelmRelease が reconcile される。
内側 HelmRelease は `suspend: true` のままなので、Helm upgrade は始まらない。
クラスタへの手動 apply、`flux resume`、手動 reconcile はしない。

## 構成（ライブ照合 2026-09-11）

- Namespace/release: `jellyfin`（Helm revision 7, deployed, chart `jellyfin-3.2.0`）
- Chart: `https://jellyfin.github.io/jellyfin-helm` / `jellyfin` `3.2.0`
- Image: `docker.io/jellyfin/jellyfin:10.11.11@sha256:0b901391a662862eddb5dc55d244d7883cbb6236ef5b9a6ea82abc78a89819f0`（ライブ imageID。chart appVersion は `10.11.8` だが稼働 tag は `10.11.11`）
- Service: LoadBalancer `192.168.11.208`、annotation `metallb.universe.tf/loadBalancerIPs`
- Ingress: disabled
- PVC: `jellyfin-claim` → static PV `jellyfin-pv`（NFS `192.168.11.9:/mnt/md0`、6Gi、RWX）
- PVC: `jellyfin-config` は Helm が作る（nfs-client、5Gi、RWO）。Git には置かない
- Secret / ExternalSecret: なし
- Deployment: `jellyfin` Ready 1/1

未モデル / 未比較:

- chart 全 defaults と live computed values の完全一致
- Helm 所有の `jellyfin-config` PVC を Flux YAML として二重所有しない

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（完了）
2. Config activation（このPR）: 外側だけ `suspend: false`、外側 marker と Namespace marker を外す。内側は `suspend: true` と marker 付き。`jellyfinActivation.stage` は `config-active`。
3. App activation（別PR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 Helm release を adopt する。helmfile は Ready 後の別PRで archive する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
