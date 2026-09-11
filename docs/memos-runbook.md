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

1. Preparation（完了）: 外側 `Kustomization/memos` と内側 `HelmRelease/memos` を両方 `suspend: true`、両方に `flux.takutk.com/activation-blocked: "true"`。
2. Config activation（このPR）: 外側だけ `suspend: false`、外側 marker と Namespace marker を外す。内側は `suspend: true` と marker 付き。`memosActivation.stage` は `config-active`。
3. App activation（別PR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 Helm release を adopt する。PVC は既存 `memos` を使う。同じPRで `safety.activationStage` を `app-active` にする。helmfile は Ready 後の別PRで archive する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
