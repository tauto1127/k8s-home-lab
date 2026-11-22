# Jellyfin の Flux 移行 runbook

## このPRの範囲

Jellyfin の **app activation**。内側 `HelmRelease/jellyfin` を `suspend: false` にする。
merge すると Flux が既存 Helm release を adopt し、Helm reconcile が始まる。
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

## /config をワーカーのローカルディスクへ移す（2026-11-22〜）

`/config`（SQLite `jellyfin.db`、WAL）が NFS 上にあり、`/health` が30秒以上止まることが1日に何度も起きていた。

- Pod 内の probe で、timeout 30s を20時間に56回超えた。
- Grafana の外形監視では、少なくとも 2026-11-09 から毎日失敗していた。
- NAS への NFS COMMIT は平均241ms かかっていた。

SQLite の WAL はネットワークファイルシステム上では動作保証の対象外なので、`/config` を `k8s-worker-node-2` のローカルディスク
（hostPath `/var/lib/jellyfin/config`、PV `jellyfin-config-local-pv`、PVC `jellyfin-config-local`）へ移す。

1. 準備（PR-A #103、停止なし）:
   - 静的 PV/PVC を Flux package に追加する。
   - Helm 所有の `jellyfin-config` PVC に `helm.sh/resource-policy: keep` を付ける。
     Helm は削除の直前に live の PVC の annotation を見るので、切り替えより前のリリースで付けておく必要がある。
2. 切り替え（PR-B、数分停止。merge 後に init container のログ、`/config/.migrated-from-nfs` の有無、ライブラリとユーザーが見えることを確認する）:
   - `deploymentStrategy: Recreate` にし、`persistence.config.existingClaim: jellyfin-config-local` にする。
   - init container が、旧 PVC（read-only）からローカルへ1回だけ `cp -a` する（marker `/config/.migrated-from-nfs`）。
   - Recreate なので、旧 Pod が止まってからコピーする。
3. 後片付け（PR-C）:
   - 動作を確認したら、init container と旧 PVC の volume を外す。
   - 旧 PVC `jellyfin-config` の削除は、別途承認を得てから行う。

ロールバックは PR-B を revert する。旧 PVC は keep で残っているので、NFS 上の `/config` に戻る（切り替え後の変更は失われる）。

DB がNASのバックアップ対象から外れるため、ローカルの `/config` をNFSへ定期コピーする仕組みは別途検討する。

## 有効化

`prune: false` を維持する。CLI resume は使わない。

1. Preparation（完了）
2. Config activation（完了）
3. App activation（このPR）: 内側 `suspend: false`、内側 marker を外す。`disableTakeOwnership: true` で既存 Helm release を adopt する。`safety.activationStage` は `app-active`。helmfile は Ready 後の別PRで archive する。

## ロールバック

Git で preparation の停止状態へ戻す。uninstall と `prune: true` はしない。
