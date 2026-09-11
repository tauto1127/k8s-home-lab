# Flux移行時のマニフェスト所有権

最終確認日: 2026-09-07

この一覧は、どの定義をFluxの入力にできるかを示す。ここに記載したことは、
Fluxが現在そのリソースを所有していることを意味しない。PR #43は停止状態の
移行準備だった。bootstrapは別途適用済みで、2026-09-07の読み取り確認ではFluxの
4 controllerとrootが稼働している。PR #46のESO controller移行はReady確認まで完了済み。
今回のGit desiredではESO controller、ESO config、CSIが有効で、Nextcloudは停止中。
CSIの実機移行成功とchart artifact fingerprintは、専用preflightとマージ後に個別に確認する。

## 分類

- `flux-managed`: Fluxでのreconciliationと実機Readyを確認済みの入力。
- `flux-candidate`: render結果とlive stateを比較したうえで、Fluxの
  `Kustomization`の管理下へ移せる宣言的な入力。
- `migration-pending`: 所有者、権限、またはHelmReleaseへの変換について、
  明示的なレビューがまだ必要なdesired configuration。
- `excluded`: 本番のreconciliation pathに入れてはならない診断用または
  テスト用のリソース。
- `generated`: controllerが生成する子リソース。Gitが所有するのはcontrollerの
  設定またはcustom resourceであり、生成された子リソースではない。

PVC、PV、namespace、CRD、privileged bindingは、初回移行時に
`prune: false`とし、削除の安全性を明示的にレビューする必要がある。

## リポジトリ内の定義

| パス | 分類 | 備考 |
| --- | --- | --- |
| `apps/dashboard/dashboard-ingress.yaml`, `dashboard-user-root.yaml`, `kustomization.yaml` | flux-candidate | DashboardのroutingとServiceAccount。 |
| `apps/dashboard/crb-user-root.yaml` | migration-pending | `cluster-admin`を付与する。reconciliationの前にleast privilegeへ置き換える。 |
| `apps/dashboard/helmfile.yaml` | migration-pending | アーカイブ済みのDashboardを、retired repositoryの7.13.0に固定している。HelmReleaseへ変換する前に、Headlampを評価する。 |
| `apps/immich/*.yaml` | flux-candidate | 削除した`.env`とinspector Podは対象外。machine-learningの`release` tagは、image parityを確認するまでpolicy exceptionとして残す。 |
| `apps/jellyfin/jellyfin-pvc.yaml`, `kustomization.yaml` | flux-candidate | PVCの削除保護が必要。 |
| `apps/jellyfin/helmfile.yaml` | migration-pending | render結果とlive resourceを比較してから変換する。 |
| `apps/memos/chart/**`, `apps/memos/helmfile.yaml` | migration-pending | local chartはCIでlintとrenderを行っている。正本はFlux HelmRelease。helmfileはReady後の別PRでarchiveする。 |
| `clusters/home/packages/memos/*`, `clusters/home/flux-system/sync.yaml` | migration-pending | Memos app-active package。外側Kustomizationと内側HelmReleaseは両方`suspend: false`、`prune: false`。chartは`GitRepository/flux-system`の`./apps/memos/chart`。既存Helm releaseを`disableTakeOwnership: true`でadoptする。helmfile archiveはReady後の別PR。 |
| `apps/metube/*.yaml`, `apps/mortis/*.yaml` | flux-candidate | raw workload package。 |
| `clusters/home/packages/mortis/*`, `clusters/home/flux-system/sync.yaml` | migration-pending | Mortis preparation package。live parity確認済み、初回は`suspend: true`・`prune: false`。Activationは別PR。MemosのServiceを参照するが所有しない。 |
| `apps/n8n/test-pvc.yaml`, `kustomization.yaml` | flux-candidate | ファイル名に反して、Helm releaseが参照するliveのn8n PVC 3個を定義している。正本は `clusters/home/packages/n8n/pvc.yaml`。 |
| `apps/n8n/helmfile.yaml` | migration-pending | 正本は Flux HelmRelease。helmfile は Ready 後の別PRで archive する。 |
| `clusters/home/packages/n8n/*`, `clusters/home/flux-system/sync.yaml` | migration-pending | n8n config-active package。外側Kustomizationは`suspend: false`、内側HelmReleaseは`suspend: true`、`prune: false`。chart は OCI `8gears` `n8n` 1.0.7。merge しても Helm adopt は始まらない。 |
| `apps/nextcloud/helmfile.yaml` | migration-pending | chart 9.1.3、liveのNextcloud image digest、liveのExternalSecret target/store/remote keyを安全なフィールドだけで一致確認した。PR #36の全valuesは未証明のため、Flux HelmReleaseは停止状態で残す。 |
| `apps/portainer/portainer-pvc.yaml`, `kustomization.yaml` | flux-candidate | PVCの削除保護が必要。 |
| `apps/portainer/helmfile.yaml` | migration-pending | render結果と比較してから変換する。 |
| `apps/wordpress/external-secret.yaml`, `wordpress-deployment.yaml`, `wordpress-pvc.yaml`, `kustomization.yaml` | flux-candidate | WordPress workloadの入力。現時点ではpackageからMySQLを意図的に除外している。 |
| `apps/wordpress/mysql-deployment.yaml` | migration-pending | Gitで追跡していたroot passwordは削除済み。credentialをrotateして検証するまで、暫定的なExternalSecret参照をreconciliationしてはならない。 |
| `middlewares/cert-manager/helmfile.yaml` | migration-pending | 依存するresourceより先にcontroller releaseを変換する。 |
| `middlewares/couchdb/*.yaml` | flux-candidate | workload、PVC、ConfigMap、ExternalSecret、package Kustomization。 |
| `clusters/home/packages/eso-config/clustersecretstore.yaml` | migration-pending | 既存`ClusterSecretStore`のGit owner。今回のdesiredではESO controllerのReadyを依存条件として有効化。specはliveと一致、移行成功はマージ後に確認する。`gcpsm-secret`のdataは取り込まない。 |
| `clusters/home/packages/csi-secrets-store/*.yaml` | migration-pending | live 1.4.8の既存Helm releaseを`kube-system`へ移すFlux package。外側は`eso-config`に依存し、外側Kustomizationと内側HelmReleaseを同一commitで有効化する。公式archive SHA256、CRD集合、stable no-hooks inventoryをpolicyに固定するが、live CRD/schema/ownershipの不一致は停止条件とする。 |
| `middlewares/secrets-store-csi-driver/helmfile.yaml` | migration-pending | CSIの旧所有境界を参照専用として保持する。live 1.4.8をFlux移行baselineに固定し、Renovate PR #28の1.6.0は別管理。 |
| `middlewares/grafana/grafana-external-secrets.yaml`, `kustomization.yaml` | flux-candidate | secret materialは外部に保持する。 |
| `middlewares/grafana/helmfile.yaml` | migration-pending | render結果と比較してから変換する。 |
| `middlewares/metallb-native/*.yaml` | flux-candidate | vendored controller bundleとaddress configuration。 |
| `middlewares/metrics-server/*.yaml` | flux-candidate | vendored controller bundleとpackage Kustomization。 |
| `middlewares/nfs-subdir-external-provisioner/helmfile.yaml` | migration-pending | storage controllerの移行にはPVC/PVの安全性レビューが必要。 |
| `middlewares/pg-operator/**` | flux-candidate | operatorとBarman pluginの入力。生成されるresourceはGitの直接の入力ではない。 |
| `middlewares/pg/*.yaml` | flux-candidate | CloudNativePG custom resourceとExternalSecrets。以前inlineで定義していたapp-user Secretは、liveと一致するExternalSecret spec（2026-09-05時点で`Ready=True`、`SecretSynced`）に置き換えた。 |
| `middlewares/redis/helmfile.yaml` | migration-pending | render結果と比較してから変換する。以前あった空のYAML placeholderは削除済み。 |
| `pv/pv-md0.yaml`, `pv/kustomization.yaml` | flux-candidate | static PV。最初は削除保護と`prune: false`が必要。 |
| `pv/storageTest.yaml` | excluded | test Pod。liveには存在しない。 |
| `pv/test-pvc.yaml` | excluded | test PVCは現在もBoundのため、cleanupは別途storageの判断が必要。 |
| `clusters/home/flux-system/gotk-components.yaml` | bootstrap | Flux `v2.9.3`のCRD/controller/RBAC。生成物とupstream bytesのSHA256をpolicyで検証し、公式bundleの`cluster-admin`付与を含むcluster適用は別承認とする。 |
| `clusters/home/flux-system/gotk-sync.yaml` | bootstrap | public GitRepositoryとactive root Kustomization。rootは`flux-system/`だけをcomposeし、`packages/`を直接所有しない。 |
| `clusters/home/flux-system/sync.yaml` | migration-pending | 8つのpackage Kustomization定義。今回のdesiredではESO controller/config/CSIとTREKとMemosとn8nの外側Kustomizationが`suspend: false`、NextcloudとMortisは`suspend: true`、全て`prune: false`。CSIは`eso-config`に、TREKとn8nはESO controller/configに依存する。n8n の内側 HelmRelease は停止のまま。 |
| `clusters/home/packages/trek/*`, `clusters/home/flux-system/sync.yaml` | migration-pending | TREK 4.2.1 app-active package。Namespace、HelmRepository、ExternalSecretと稼働中HelmReleaseを外側Kustomizationが所有する。外側Kustomizationは`suspend: false`、`prune: false`で、内側HelmReleaseも`suspend: false`とする。 |
| `clusters/home/packages/eso-controller/helmrelease.yaml` | flux-managed | PR #46で移行済み。初回upgrade成功、Ready、chart artifact digest一致を確認済み。 |

すべてのraw `flux-candidate` packageには`kustomization.yaml`がある。Helm chartの
templateは`helm template`後にのみ検証し、raw Kubernetes YAMLとしてはparseしない。

これらのKustomizationはCI用のrender packageであり、最終的なFlux reconciliation
boundaryではない。後続の移行PRでは、controllerとCRDを依存するcustom resource
から分離し、`dependsOn`とhealth checkで順序を表現する。Dashboardのcluster-admin
bindingは意図的にpackageから除外している。

## 移行前のライブ差分とPR2のゲート

以下は2026-09-05に読み取り専用で確認した事項であり、PR1ではクラスターへ
適用していない。

- ESOのGit定義はPR #43から`clusters/home/packages/eso-controller/helmrelease.yaml`に存在し、PR #46で既存Helm release（chart `external-secrets-0.14.4`）のFlux管理への移行を完了した。2026-09-07の読み取り確認でもHelmReleaseはReadyだった。このPRはcontrollerを再度有効化するものではなく、既存の`ClusterSecretStore`だけをESO config packageでFlux管理へ移す。旧`middlewares/external-secrets-operator/helmfile.yaml`が管理していたのはESO本体ではなくSecrets Store CSI Driverである。
- Secrets Store CSI Driverは、Git desiredとliveを`secrets-store-csi-driver` 1.4.8へ固定する。公式archive URL/SHA256とstable no-hooks 10 resource inventoryは専用preflightで確認済みだが、live CRD schema/ownership、rendered child、image digestの完全一致は未証明であり、1.6.0へのupgrade（Renovate PR #28）は対象外とする。
- Nextcloudはlive Helm chart `9.1.3`で、Podが使用中の`33.0.5-apache` image digestに固定した。liveはExternalSecretが生成する`nextcloud-db-secret`を参照しているため、Helmfileも同じSecret名とキーを参照し、chartの既定資格情報Secretをrenderしない。ExternalSecret自体のGit ownerとHelm chartの全valuesが一致したことまでは確認していないため、HelmRelease化は引き続き`migration-pending`とする。
- Nextcloud valuesは不完全で、既存releaseをupgradeするとchart defaultsへ戻る危険がある。Ingress/PVC/NFS/Service/cron/probes/TLS、既存release adoptionと完全parityが証明されるまで`activation-blocked`で停止し、runbook対象外とする。Secret値を取得せず証明できない場合はvaluesを補完しない。
- `activation-blocked` annotationはCI markerでありFlux nativeの強制機構ではない。Nextcloudの外側Kustomizationだけを手動resumeするとExternalSecretが先に適用され得るため、CLI resume/手動unsuspendは禁止する。将来activationにはSecret適用phaseの分離またはadmission policyを必須とする。
- activationはCLI resumeではなく、外側Kustomizationと内側HelmReleaseを同一Git commitでfalseにする別PRで行う。activation PRマージ前のliveは既存Helm ownerのままで、成功後のdesired/runtime境界だけがFlux HelmReleaseになる。root reconciliationはGitのsuspend:trueを戻り先とする。特に、親Kustomizationが子Kustomizationを取り込む構造を自動検出で二重登録しない。controllers、CRDs、PVC/PV、Secret生成物、依存するカスタムリソースは境界と`dependsOn`を分け、初回は`prune: false`とする。

## liveにのみ存在するdesired workload

2026-09-05のlive inventoryには、このrepositoryに定義がないresourceも含まれている。
対象はAudiobookshelf、Cronus、Glance、Honcho、Kubero、Percona MongoDBのworkloadである。
まず所有するrepositoryを特定する。存在しない場合も、Secret value、status、generated
field、controller-owned childを除き、desired configurationだけを再構成する。

## generated resource

次のlive objectをGitへ戻してはならない。

- Helm-generated Deployment、Service、release Secretなどの子resource
- External Secretsまたはcert-managerが生成するSecret
- CloudNativePGが生成するPod、Service、certificate
- MetalLB、Kubero、Percona、その他のoperatorが生成するchild resource

## 現在のtreeから削除したもの

移行baselineでは、未使用のArgo CD bundleと、Gitで追跡していたlocal credential
artifactを削除した。Git historyには以前のvalueが残っているため、credentialのrotate
とhistory rewriteは別のsecurity operationとして扱う。
