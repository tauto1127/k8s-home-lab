# Grafana k8s-monitoring の Flux 移行 runbook

## このPRの範囲

Grafana の **app activation**。内側 `HelmRelease/grafana-k8s-monitoring` も `suspend: false` にし、marker を外す。
merge すると helm-controller が既存の parent release（revision 2）を adopt し、修正済みの values で upgrade する。

- upgrade で chart が作っていた username だけの Secret 7個（`*-grafana-k8s-monitoring`、`alloy-*-remote-cfg-*`）が消える。
  代わりに Alloy は `grafana-external-secrets` を `remote.kubernetes.secret` で読む。
- Alloy CR が更新され、alloy-operator が子 release（alloy-logs / metrics / receiver / singleton）を upgrade する。
- クラスタへの手動 apply、`flux resume` はしない。

## 認証情報の参照（2026-11-21 修正）

revision 2（2026-09-11）で values を `passwordFrom: grafana-external-secrets` に変えたため、監視が止まっていた。

- k8s-monitoring v3 の `passwordFrom` は Secret 名ではなく、Alloy の式をそのまま書くフィールド。
  `password = grafana-external-secrets` という不正な Alloy 設定になる。
- chart が作る `*-grafana-k8s-monitoring` / `alloy-*-remote-cfg-*` の Secret から `password` キーが消えた。
  `extraEnv` の `GCLOUD_RW_API_KEY` が `key: password` を参照していたため、
  Alloy の4 Pod が `CreateContainerConfigError` で起動できなくなった。

正しい書き方は、chart の external secret モードを使うこと。

- 各 destination と `alloy-*.remoteConfig` に `secret: {create: false, name: grafana-external-secrets, namespace: grafana}`
  と `auth.passwordKey: grafana` を指定する。
- external モードでは username も Secret から読もうとするので、`auth.usernameFrom: '"<id>"'`（Alloy の文字列リテラル）で渡す。
- `GCLOUD_RW_API_KEY` は `grafana-external-secrets` の `grafana` キーから取る。
- 1Password `grafana/password` の token が4つの endpoint（metrics / logs / OTLP / Fleet）すべてで認証に通ることを確認済み（2026-11-21）。
  不正な token はすべて 401 になることも確かめた。

live の ExternalSecret は、ローカルで手動 apply された secretKey `grafana-external-secrets` の定義になっていた。
config activation で Git の定義（secretKey `grafana`）に戻る。

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

1. Preparation（完了、#65）: 両方 `suspend: true`
2. Config activation（完了、#100）: 外側だけ `suspend: false`、外側 marker と Namespace marker を外す。`grafanaActivation.stage` は `config-active`。
   merge 後、`Secret/grafana-external-secrets` のキーが `grafana` になったことをキー名だけで確認する。
3. App activation（このPR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 parent Helm を adopt する。
   alloy 4本は Alloy CR 経由で alloy-operator が更新する。Flux には載せない

## merge 後の確認

```sh
kubectl wait helmrelease/grafana-k8s-monitoring -n grafana --for=condition=Ready --timeout=10m
kubectl get pods -n grafana   # alloy-* が 2/2 Running
kubectl logs -n grafana statefulset/grafana-k8s-monitoring-alloy-metrics -c alloy | grep -iE "error|401|remotecfg"
```

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
