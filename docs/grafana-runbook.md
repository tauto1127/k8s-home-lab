# Grafana k8s-monitoring の Flux 移行 runbook

## このPRの範囲

Grafana の **preparation**。外側 Kustomization と内側 HelmRelease は両方 `suspend: true`。
merge しても Flux は起動しない。クラスタへの手動 apply、`flux resume`、手動 reconcile はしない。

## 構成（ライブ照合 2026-09-11）

- Namespace: `grafana`
- Parent Helm release: `grafana-k8s-monitoring` revision 2, chart `k8s-monitoring-3.5.3`
- Chart repo: `https://grafana.github.io/helm-charts`
- Alloy 4本（`alloy-logs` / `alloy-metrics` / `alloy-receiver` / `alloy-singleton`）は Alloy CR が作る子 Helm release。Flux には載せない
- ExternalSecret `grafana-external-secrets` → Secret key `grafana`（GSM id `grafana`）。live `SecretSynced`
- Helm values の Grafana Cloud token は literals ではなく `passwordFrom` / `passwordKey: grafana`
- OTLP destination 名は live `gc-otlp-endpoint`（helmfile の `grafana-cloud-otlp-endpoint` ではない）
- `remoteConfig` は collector 直下（helmfile の `alloy.remoteConfig` ではない）
- `ns/monitoring` は空。取り込まない

未モデル / 未比較:

- chart 全 defaults と live computed values の完全一致
- Alloy 子 release の Helm values（親が所有）

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（このPR）: 両方 `suspend: true`
2. Config activation（次PR）: 外側だけ `suspend: false`。Namespace / HelmRepository / ExternalSecret / 停止中 HelmRelease
3. App activation: 内側 `suspend: false`。`disableTakeOwnership: true` で既存 parent Helm を adopt する。alloy 4本は作らない

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
