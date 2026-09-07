# Flux ESO controller activation runbook

このPRは、既存のExternal Secrets Operator（ESO）Helm releaseだけをFlux管理へ移す。
マージするとactiveなroot KustomizationがGit変更を検出し、外側
`flux-system/eso-controller`と内側`external-secrets/external-secrets`をreconcileする。
ESO config、CSI、Nextcloudは対象外であり、`prune: false`を維持する。

## 2026-09-07 read-only preflight

- Flux GitRepository/root Kustomizationは`main@sha1:ff7996f84b7d13b9606bdf9b6c4b072858803e88`でReadyだった。
- Flux controller 4件はAvailable、Pod 4件はReadyだった。
- 既存Helm release `external-secrets`はnamespace `external-secrets`、chart
  `external-secrets-0.14.4`、app `v0.14.4`、status `deployed`、revision 1だった。
- ESO Deployment 3件はすべて1/1 Availableで、imageは
  `oci.external-secrets.io/external-secrets/external-secrets:v0.14.4`だった。
- chartがrenderする38 resourceすべてについて、Helm ownership annotationのrelease名と
  namespaceが`external-secrets`、managed-by labelが`Helm`と一致した。Secret 1件は
  metadataの選択フィールドだけを確認し、dataは取得していない。同じ対象を管理する
  Argo Applicationまたは別のFlux HelmReleaseは表示されなかった。
- repository-pinned Helm v3.18.1でchart 0.14.4を`releaseName=external-secrets`、
  namespace `external-secrets`、`installCRDs=true`としてrenderした。renderに含まれる
  Secret 1件を比較対象から完全に除外し、残る37リソースをserver-side dry-run diffした結果は差分0だった。
- chart archiveのSHA256は
  `cfda856bdfab922a92c1e0ca199811edae21ad529484f3669b8233e813168779`で、公式chart
  repository indexのdigestと一致した。取得元は
  `https://github.com/external-secrets/external-secrets/releases/download/helm-chart-0.14.4/external-secrets-0.14.4.tgz`
  に固定した。
- ESO 0.14.4はCRDをchartの`crds/`ではなく`templates/crds/`配下の通常template 19件として
  renderする。この19ファイルをpath昇順に並べ、各`path + NUL + bytes + NUL`を連結して求めた
  SHA256は`5fa17b33c731ab29d089f2bfd350342b002c6758db9ad7f7667c71c809f23ab5`だった。
- clusterはKubernetes v1.36.4である。一方、ESO v0.14.xのversioned support資料が
  保証対象としているKubernetesはv1.32であり、0.14.4は現在のsupport対象ではない。
  このPRは既に稼働中のversionをFluxへ移すだけでupgradeしないため、既存の互換性負債を
  新規導入はしないが、解消もしない。この残存Warningを承認してからマージする。
- Secret value、raw Secret、`helm get values`、`helm get manifest`は取得していない。

Flux helm-controllerは、同じstorage namespace/release nameに既存releaseがあり、
そのreleaseがHelmReleaseの履歴で未観測ならinstallではなくupgradeを実行する。このため、
chart/versionが同じでも初回reconcileはno-opとは仮定しない。

## Expected Git diff

- `clusters/home/flux-system/sync.yaml`: `eso-controller`だけを`suspend: false`
- `clusters/home/packages/eso-controller/helmrelease.yaml`: `external-secrets`だけを`suspend: false`。
  release/target/storage namespaceを明示し、install/upgradeとも`disableTakeOwnership: true`と
  `crds: Skip`にする。`crds: Skip`はchartの`crds/`ディレクトリだけに作用し、ESOの
  `templates/crds/`を除外しない。既存Helm releaseからtemplate-managed CRDを削除する変更を
  避けるため`installCRDs: true`を維持する
- `.github/manifest-policy.yaml`: activeなKustomization/HelmReleaseのidentityに加え、package path、
  render inventory、owner、chart名/version、HelmRepository URL、公式chart artifact SHA256、
  CRD template 19件の集合SHA256を固定する。ESO identityを別phase名へ移す変更を含め、
  `eso-controller`の完全な境界はvalidator側の独立した定数とも一致しなければならない
- ESO config、CSI、Nextcloudの外側Kustomizationは`suspend: true`、`prune: false`
- Nextcloudの内側HelmReleaseは`suspend: true`、両方の
  `flux.takutk.com/activation-blocked: "true"`を維持

validatorは、許可されていない`suspend: false`、片側だけの有効化、path/inventory/ownerの差替え、
chart/repository/artifact/CRD template集合のdrift、明示的なrelease/target/storage namespace・
`disableTakeOwnership`・`installCRDs`の欠落、Nextcloudの有効化をfail-closedで拒否する。
これはGit/CIの固定であり、Fluxがruntimeに取得したHelmChart artifactはマージ後のstatus digestでも
照合する。

## Merge後の確認（5分timeout）

次のコマンドはPR内では実行していない。マージ承認後に実行し、Secret値は表示しない。

```bash
ssh kube 'kubectl wait -n flux-system kustomization/eso-controller --for=condition=ready --timeout=5m'
ssh kube 'kubectl wait -n external-secrets helmrelease/external-secrets --for=condition=ready --timeout=5m'
ssh kube 'kubectl get -n flux-system kustomization eso-controller eso-config csi-secrets-store nextcloud'
ssh kube 'kubectl get -n flux-system helmchart external-secrets-external-secrets -o custom-columns=NAME:.metadata.name,REVISION:.status.artifact.revision,DIGEST:.status.artifact.digest'
ssh kube 'kubectl get -n external-secrets helmrelease external-secrets'
ssh kube 'kubectl get -n external-secrets deployment,pod'
ssh kube 'helm list -n external-secrets'
```

成功条件は、ESO outer KustomizationとHelmReleaseがReady、Helm releaseがdeployed、
Deployment 3件がAvailable、Pod 3件がReadyであること。さらにESO config、CSI、Nextcloudが
suspendedのままで、Nextcloudのactivation-blocked annotationが維持され、HelmChart artifact
digestが`sha256:cfda856bdfab922a92c1e0ca199811edae21ad529484f3669b8233e813168779`
と一致することを確認する。

## Stop / rollback

- HelmRepository/HelmChart取得失敗、chart digest不一致、upgrade失敗、5分timeout、
  Deployment非Ready、予期しないchart/revision/resource変更、他packageのreconcile、
  Secret値が出力されそうな操作で即停止する。
- `flux resume`、`helm upgrade/rollback/uninstall`は行わない。手動patchは以下の別途承認された緊急停止だけを例外とする。
- まず、outer Kustomizationとinner HelmReleaseを同じ変更で`suspend: true`へ戻す、検証済みのactivation commit revert PRを作成・マージする。片側だけを有効化するGit変更はvalidatorが拒否するため、innerだけを先に戻すGit PRは作らない。
- revertのマージ後、read-onlyでrootがrevertのGit SHAを適用済みであることと、outer `flux-system/eso-controller` が`suspend: true`になったことを確認する。rootの適用またはouter停止を確認できない場合は停止し、別の明示承認なしに次へ進まない。
- outerが停止したことを確認した後、inner `external-secrets/external-secrets` が存在する場合に限り、緊急封じ込めとして、別途明示承認を得た直接のcluster writeでinnerも`suspend: true`にする。これはGitの代替ではなく、Git revertだけではouter停止後にinnerへ届かないための必須手順である。read-only確認に失敗した状態でのinner patchや、outer停止前のpatchは行わない。この直接patchはこのrunbookでは実行していない。

  ```bash
  # read-only: rootのrevert SHAとouter停止を確認する
  ssh kube 'kubectl get -n flux-system kustomization flux-system eso-controller -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend,LAST_APPLIED:.status.lastAppliedRevision,OBSERVED_GEN:.status.observedGeneration'
  # 別途明示承認後のみ実行するcluster write（このrunbookでは未実行）
  ssh kube 'kubectl patch -n external-secrets helmrelease external-secrets --type=merge -p '\''{"spec":{"suspend":true}}'\'''
  # read-only: innerの停止を確認する
  ssh kube 'kubectl get -n external-secrets helmrelease external-secrets -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend'
  ```

- 直接停止後、上記の選択フィールドをread-onlyで再確認し、outer/innerの`suspend: true`とrevert後のGit desiredの一致を記録する。停止前に開始したouter reconciliationが遅れてinnerを書き戻す可能性があるため、outerの`Reconciling=True`が解消した後にも再確認する。innerがfalseへ戻る、または進行中処理の終了を確認できない場合は停止完了と扱わず、追加の対処を判断する。
- `suspend`は将来のreconcileを止めるだけで、既に進行中または完了したHelm upgradeを自動rollbackしない。Helm rollbackやresource修復が必要なら、read-only evidenceを保存した後、別の明示承認を得る。
- ESO controllerが安定するまでESO config、CSIのactivation PRを作成・マージしない。

一次資料:

- [Flux HelmRelease reconciliation](https://fluxcd.io/flux/components/helm/helmreleases/)
- [Flux HelmChart artifacts](https://fluxcd.io/flux/components/source/helmcharts/)
- [Flux Kustomization suspend and health checks](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [ESO v0.14.4 stability and support](https://external-secrets.io/v0.14.4/introduction/stability-support/)
