# Flux移行時のマニフェスト所有権

最終確認日: 2026-09-05

この一覧は、どの定義をFluxの入力にできるかを示す。ここに記載したことは、
Fluxが現在そのリソースを所有していることを意味しない。最初の移行PRで
変更するのはリポジトリの検証だけであり、クラスターには何も適用しない。

## 分類

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
| `apps/memos/chart/**`, `apps/memos/helmfile.yaml` | migration-pending | local chartはCIでlintとrenderを行っている。Flux HelmReleaseへ変換する。 |
| `apps/metube/*.yaml`, `apps/mortis/*.yaml` | flux-candidate | raw workload package。 |
| `apps/n8n/test-pvc.yaml`, `kustomization.yaml` | flux-candidate | ファイル名に反して、Helm releaseが参照するliveのn8n PVC 3個を定義している。 |
| `apps/n8n/helmfile.yaml` | migration-pending | releaseとExternalSecretのextra objectを一緒に変換する。 |
| `apps/nextcloud/helmfile.yaml` | migration-pending | chart 9.1.3、liveのNextcloud image digest、ExternalSecret生成の既存Secret参照は固定済みだが、PR #36により完全なdesired configurationが示されている。変換前にownershipと残りのvaluesを整理する。 |
| `apps/portainer/portainer-pvc.yaml`, `kustomization.yaml` | flux-candidate | PVCの削除保護が必要。 |
| `apps/portainer/helmfile.yaml` | migration-pending | render結果と比較してから変換する。 |
| `apps/wordpress/external-secret.yaml`, `wordpress-deployment.yaml`, `wordpress-pvc.yaml`, `kustomization.yaml` | flux-candidate | WordPress workloadの入力。現時点ではpackageからMySQLを意図的に除外している。 |
| `apps/wordpress/mysql-deployment.yaml` | migration-pending | Gitで追跡していたroot passwordは削除済み。credentialをrotateして検証するまで、暫定的なExternalSecret参照をreconciliationしてはならない。 |
| `middlewares/cert-manager/helmfile.yaml` | migration-pending | 依存するresourceより先にcontroller releaseを変換する。 |
| `middlewares/couchdb/*.yaml` | flux-candidate | workload、PVC、ConfigMap、ExternalSecret、package Kustomization。 |
| `middlewares/external-secrets-operator/gcp-provider.yaml`, `kustomization.yaml` | migration-pending | liveのExternal Secrets Operator releaseには、このrepository内のGit ownerが記録されていない。controller ownerとdependencyを明示するまでproviderをreconciliation対象外にする。 |
| `middlewares/external-secrets-operator/helmfile.yaml` | migration-pending | desiredのSecrets Store CSI Driver chartは1.5.1、liveは1.4.8。このfileはExternal Secrets Operator本体をinstallしないため、変換時にownership boundaryをrenameまたは分割する。 |
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

すべてのraw `flux-candidate` packageには`kustomization.yaml`がある。Helm chartの
templateは`helm template`後にのみ検証し、raw Kubernetes YAMLとしてはparseしない。

これらのKustomizationはCI用のrender packageであり、最終的なFlux reconciliation
boundaryではない。後続の移行PRでは、controllerとCRDを依存するcustom resource
から分離し、`dependsOn`とhealth checkで順序を表現する。Dashboardのcluster-admin
bindingは意図的にpackageから除外している。

## 移行前のライブ差分とPR2のゲート

以下は2026-09-05に読み取り専用で確認した事項であり、PR1ではクラスターへ
適用していない。

- External Secrets Operatorのlive Helm release（chart `external-secrets-0.14.4`）は、このリポジトリ内にGit所有元がない。`middlewares/external-secrets-operator/helmfile.yaml`が管理しているのはESO本体ではなく、Secrets Store CSI Driverである。
- Secrets Store CSI Driverは、Gitのdesired chart versionが`1.5.1`、liveが`1.4.8`である。差分を確認してから、どちらを正本にするか決める。
- Nextcloudはlive Helm chart `9.1.3`で、Podが使用中の`33.0.5-apache` image digestに固定した。liveはExternalSecretが生成する`nextcloud-db-secret`を参照しているため、Helmfileも同じSecret名とキーを参照し、chartの既定資格情報Secretをrenderしない。ExternalSecret自体のGit ownerとHelm chartの全valuesが一致したことまでは確認していないため、HelmRelease化は引き続き`migration-pending`とする。
- PR2では、各Flux Kustomizationの所有境界を先に決め、同じ`apiVersion/kind/namespace/name`を複数のKustomizationから管理しない。特に、親Kustomizationが子Kustomizationを取り込む構造を自動検出で二重登録しない。controllers、CRDs、PVC/PV、Secret生成物、依存するカスタムリソースは境界と`dependsOn`を分け、初回は`prune: false`とする。

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
