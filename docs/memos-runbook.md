# Memos の Flux 移行 runbook

## このPRの範囲

Memos の **preparation** だけ。クラスタ apply、`flux resume`、手動 reconcile はしない。
merge しても起動しない。

## 構成（ライブ照合 2026-09-10）

- Namespace/release: `memos`
- Chart: リポジトリ内 `apps/memos/chart`（chart 0.2.1、app 0.29.0）
- Image tag: `0.29.0`（digest はライブに無かったので未ピン）
- Service: LoadBalancer、port 5230、MetalLB `192.168.11.209`
- PVC: `memos`、`nfs-client`、10Gi、RWO、Bound
- Ingress: disabled
- Secret / ExternalSecret: なし

HelmRelease の chart source は bootstrap `GitRepository/flux-system`。HelmRepository は作らない。

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（完了）
2. Config activation（完了）
3. App activation（このPR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 Helm release を adopt する。`safety.activationStage` は `app-active`。helmfile は Ready 後の別PRで archive する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
