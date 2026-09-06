# Flux PR2 read-only Git/live比較

確認日: 2026-09-06
対象: `chore/flux-pr2-ownership-boundaries`

この比較は、Gitのdesired定義をrender/静的検査し、`ssh takuto1127@192.168.11.28`
から選択した非機密フィールドだけを読み取った結果である。Secret value、raw Secret
manifest、Helm values/manifestは取得・保存していない。Flux bootstrap/reconcile/applyは
行っていない。

## PR2で比較できたフィールド

次の項目だけが、PR2のGit定義に明示され、選択したliveフィールドと比較できる範囲である。Helm chartのrender結果全体や、HelmReleaseが宣言していないchild resourceのparityは意味しない。

| 項目 | Git desired | live selected field | 判定 |
| --- | --- | --- | --- |
| ESO chart | `external-secrets` 0.14.4 | release `external-secrets`, chart `external-secrets-0.14.4`, app `v0.14.4` | Git/liveの選択フィールド一致 |
| ESO controller image | chart既定のv0.14.4を明示的に上書きしない | controller系Deploymentはv0.14.4 image tag | 部分一致（digest未確認） |
| CSI chart | `secrets-store-csi-driver` 1.4.8 | release/chart/app `1.4.8` | Git/liveの選択フィールド一致 |
| Nextcloud chart | chart `nextcloud` 9.1.3 | release/chart `nextcloud-9.1.3`, app `33.0.5` | Git/liveの選択フィールド一致 |
| Nextcloud image | repository、`33.0.5-apache`、digestをHelmReleaseに明示 | live tag/digestと一致 | Git/liveの選択フィールド一致 |
| Nextcloud existingSecret | `nextcloud-db-secret`、username/password keyを明示 | live Deployment/Secret参照と一致 | Git/liveの選択フィールド一致 |
| ExternalSecret target/store | target `nextcloud-db-secret`, `ClusterSecretStore/secret-store-provider` | liveと一致 | Git/liveの選択フィールド一致 |
| ExternalSecret refresh/retention | `24h`, `Owner`, `Retain` | live `24h`, `Owner`, `Retain` | Git/liveの選択フィールド一致 |
| ExternalSecret remote refs | 4 keys、各 `latest`、decoding `None` | live selected refsと一致 | Git/liveの選択フィールド一致 |
| ESO provider reference | `gcpsm-secret/secret-access-credentials`, project `269357193809` | live selected reference/projectと一致 | Git/liveの選択フィールド一致（Secret dataは外部前提） |

## PR2で証明していないlive-only/reference項目

PR2のNextcloud HelmReleaseはimageとexistingSecretだけを宣言する。ingress class/host、PVC `nextcloud-data-pvc`/`200Gi`、Service、NFS、cron、probes、TLS等はPR2のdesiredにはないため、Git desiredとの「一致」には分類しない。

| 項目 | live/reference情報 | 判定 |
| --- | --- | --- |
| Nextcloud ingress | live class `kong`、host `nc.takutk.com` | live-only/reference; PR2 parity unknown |
| Nextcloud storage | live PVC `nextcloud-data-pvc`、`200Gi` Bound | live-only/reference; PR2 parity unknown |
| Nextcloud Service/NFS/cron/probes/TLS | PR #36の候補定義またはlive情報 | parity unknown; PR2の所有対象外 |

PR #36にはこれらの候補定義があるが、PR2では取り込まず、所有者・render結果・live差分の確認なしにparityを主張しない。

## ownership / drift

- ESO live child resourcesはHelm labels `app.kubernetes.io/managed-by=Helm`、chart
  `external-secrets-0.14.4`を持つ。GitではFlux HelmReleaseをcontroller ownerとして
  定義するが、生成Deployment/Service/Webhook/CRD等をGitの個別manifestとして所有しない。
  Helm ownership labelの移行結果は未実施であり、read-only比較では未知のまま残す。
- CSI live DaemonSetはchart `secrets-store-csi-driver-1.4.8`で、旧Helmfileの所有境界を
  `middlewares/secrets-store-csi-driver/`へ分離した。Git mainにある1.5.1からではなく、
  live 1.4.8をこの移行baselineに固定し、Renovate PR #28 (1.6.0)は対象外とした。
  `middlewares/secrets-store-csi-driver/helmfile.yaml`とNextcloudの旧Helmfileは、比較・移行検討用の
  legacy reference-only定義であり、PR2のFlux Kustomizationからは参照されず、active Flux ownerではない。
- Nextcloud live DeploymentはHelm labels/chart labelと1 replica。GitにはHelmReleaseを
  定義するが、PR #36の全values、init container、NFS、service annotations、TLS Secret、
  liveness/readiness、cron等の完全parityはこの比較だけでは証明できない。そのため
  HelmReleaseは`suspend: true`のままにし、PV/PVCやHelm生成childは重複所有しない。
- live Secretの生成owner labels/annotationsは外部Secret controller由来であり、Gitへ
  取り込まない。ExternalSecretのGit desiredにlive Secretの生成metadataをコピーしない。

## unknown / activation blockers

- Flux CRD、source-controller、kustomize-controller、helm-controllerはliveに存在せず、
  Flux namespace/CRD/releaseも不在。bootstrapが別途必要。
- ESO/CSI/Nextcloudの全chart values、renderされた全child、image digest（ESO/CSIの
  全コンテナ）、Helm release ownership collisionは未証明。
- `gcpsm-secret`は手動/外部プロビジョニングの前提で、dataをimportしない。
- HelmReleaseのunsuspend、Flux Kustomizationのunsuspend、read-only diff、明示承認が
  完了するまでreconcileしない。初期定義は全て`prune: false`、Kustomization/HelmRelease
  とも`suspend: true`である。

## activation order

1. Flux bootstrap（このPRでは実施しない）
2. read-only diffとownership collision確認
3. 明示承認
4. ESO controllerのhealth確認後にcontroller packageだけunsuspend
5. CRD/ClusterSecretStore/ExternalSecret設定のhealth確認
6. CSI、Nextcloudの順に個別unsuspend
7. prune有効化は別レビュー
