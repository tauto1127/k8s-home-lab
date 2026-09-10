# TREK 運用ランブック

## このPRの範囲

このPRはTREK 4.2.1のFlux移行準備だけを行う。`main`へマージしても、TREKはインストールされず、起動せず、Helm chartもreconcileされない。

rootのFlux Kustomizationが作成するのは、停止状態の外側 `Kustomization/trek` だけである。外側は `suspend: true` と `prune: false`、内側の `HelmRelease/trek` も `suspend: true` で、両方に `flux.takutk.com/activation-blocked: "true"` を付けている。GSM、クラスター、Cloudflare DNS/TunnelはこのPRでは変更しない。

## 構成

- Namespace/release: `trek`
- Chart: `trek` 4.2.1, `https://chart.liketrek.com`
- Image: `mauriceboe/trek:4.2.1`
- Ingress: Kong、`trek.takutk.com/`、strip-path false
- Data PVC: `nfs-client`, 5Gi
- Uploads PVC: `nfs-client`, 20Gi
- Secret: ESOが `trek-secrets` を生成する。Gitには値を置かない
- SecretのGSM remote refs: `trek-encryption-key`, `trek-admin-email`, `trek-admin-password`

## 有効化の手順

`flux resume`、imperative patch、手動reconcileは使用しない。各段階を別のGit PRとして行う。

1. Config activation PR: `flux-system` namespaceの外側 `Kustomization/trek` を `suspend: false` にする。内側 `HelmRelease/trek` は `suspend: true` のままにする。この段階でpackage resources（Namespace、HelmRepository、ExternalSecret、停止中HelmRelease）がreconcileされる。GSM secret registrationはこの段階の前提として別途実施する。
2. App activation PR: `HelmRelease/trek` の `suspend: false` にする。activation markerも同じGit変更で更新し、Helm chartをreconcileする。

両方とも、`prune: false` を維持する。アンインストールを使うrollbackは行わない。

## ロールバック

Gitで直前の安全なdesired stateへ戻す。設定は停止状態へ戻し、削除を伴うuninstallや `prune: true` への変更はしない。稼働後のデータPVCは `helm.sh/resource-policy: keep` で保護される。

## 有効化前チェック

- GSMに3つのremote secretが登録済みであること
- `trek-secrets` のキーが `ENCRYPTION_KEY`、`ADMIN_EMAIL`、`ADMIN_PASSWORD` であること
- Cloudflare DNS/Tunnelが `trek.takutk.com` をKong Ingressへ向けていること
- Config activation PRのCIでrendered Helm desired stateと依存関係を確認すること
- App activation PRでは、HelmReleaseをfalseにする変更以外を混在させないこと
