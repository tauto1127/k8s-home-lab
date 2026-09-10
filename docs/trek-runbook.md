# TREK 運用ランブック

## このPRの範囲

このPRはTREK 4.2.1のFlux移行準備だけを行う。`main`へマージしても、TREKはインストールされず、起動せず、Helm chartもreconcileされない。

rootのFlux Kustomizationが作成するのは、停止状態の外側 `Kustomization/trek` だけである。外側は `suspend: true` と `prune: false`、内側の `HelmRelease/trek` も `suspend: true` で、両方に `flux.takutk.com/activation-blocked: "true"` を付けている。GSM、クラスター、Cloudflare DNS/TunnelはこのPRでは変更しない。

## 構成

- Namespace/release: `trek`
- Chart: `trek` 4.2.1, `https://chart.liketrek.com`
- Image: `mauriceboe/trek:4.2.1@sha256:777f4d647e973fe7d87fecd957e854b86d57e8d977fd041763e0ca19b3c2e2c0`
- Ingress: Kong、`trek.takutk.com/`、strip-path false。connect/read/write timeoutはHelm post-rendererでServiceに付与する
- Data PVC: `nfs-client`, 5Gi
- Uploads PVC: `nfs-client`, 20Gi
- Secret: ESOが `trek-secrets` を生成する。Gitには値を置かない
- SecretのGSM remote refs: `trek-encryption-key`, `trek-admin-email`, `trek-admin-password`

## 有効化の手順

`flux resume`、imperative patch、手動reconcileは使用しない。次の3状態だけを許可し、各遷移を別のGit PRとして行う。すべての状態で外側Kustomizationの `prune: false` を維持する。

1. Preparation（このPR）: 外側 `Kustomization/trek` は `suspend: true` かつactivation marker付き、内側 `HelmRelease/trek` も `suspend: true` かつmarker付き。packageはreconcileされない。
2. Config activation PR: 次の変更を同じPRで行う。外側 `clusters/home/flux-system/sync.yaml` の `Kustomization/trek` を `suspend: false` にし、外側の `flux.takutk.com/activation-blocked: "true"` を削除する。`clusters/home/packages/trek/namespace.yaml` のNamespace `trek` から、同じactivation-blockedのlabelとannotationを両方削除する。`.github/manifest-policy.yaml` の `trekActivation.stage` を `config-active` にし、TREK Kustomizationをactive inventoryへ追加し、TREK HelmReleaseを `safety.trekStage: config-active` 付きのapproved active HelmRelease policyへ追加する。内側 `HelmRelease/trek` は `suspend: true` とmarker付きのままにする。これによりNamespace、HelmRepository、ExternalSecret、停止中HelmReleaseだけがreconcileされる。PRには、このstage transitionに必要なFlux ownership/policy/docs/testsの更新を含める。
3. App activation PR: `clusters/home/packages/trek/helmrelease.yaml` の内側 `HelmRelease/trek` を `suspend: false` にし、内側の `flux.takutk.com/activation-blocked: "true"` を削除する。`.github/manifest-policy.yaml` の `trekActivation.stage` とTREK HelmRelease policyの `safety.trekStage` を `app-active` に更新し、必要なownership/policy/docs/testsも同じPRに含める。外側は `suspend: false`、markerなし、Namespaceもmarkerなしのままにする。

外側が停止中のまま内側だけをactiveにする状態、markerとsuspendの混在、`prune: true` はCIで拒否する。GSM secret registrationはConfig activationの前提として別途実施する。LAN/KongのHost-header smoke testはCloudflareなしで実行できる。Cloudflare DNS/Tunnelは、後段のpublic HTTPS/WebSocket validationでのみ必要になる。

## ロールバック

Gitで直前の安全なdesired stateへ戻す。設定は停止状態へ戻し、削除を伴うuninstallや `prune: true` への変更はしない。稼働後のデータPVCは `helm.sh/resource-policy: keep` で保護される。

## 有効化前チェック

- GSMに3つのremote secretが登録済みであること
- `trek-secrets` のキーが `ENCRYPTION_KEY`、`ADMIN_EMAIL`、`ADMIN_PASSWORD` であること
- Cloudflare DNS/Tunnelが `trek.takutk.com` をKong Ingressへ向けていること（public HTTPS/WebSocket validation時のみ）
- Config activation PRのCIでrendered Helm desired stateと依存関係を確認すること
- App activation PRでは、HelmReleaseをfalseにする変更と、そのstage transitionに必要なownership/policy/docs/testsだけを含めること
