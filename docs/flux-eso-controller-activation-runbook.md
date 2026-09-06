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
  repository indexのdigestと一致した。
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
  `crds: Skip`にして、ownership不一致とCRD変更をfail-closedにする
- `.github/manifest-policy.yaml`: 現在activeであることを許可する上記2 identityを明示
- ESO config、CSI、Nextcloudの外側Kustomizationは`suspend: true`、`prune: false`
- Nextcloudの内側HelmReleaseは`suspend: true`、両方の
  `flux.takutk.com/activation-blocked: "true"`を維持

validatorは、許可されていない`suspend: false`、片側だけの有効化、存在しないidentity、
active HelmReleaseをsuspended owner配下へ置く構成、明示的なrelease/target/storage namespace・
ownership/CRD safety設定の欠落、Nextcloudの有効化をfail-closedで拒否する。

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
suspendedのままで、Nextcloudのactivation-blocked annotationが維持されていることを確認する。

## Stop / rollback

- HelmRepository/HelmChart取得失敗、chart digest不一致、upgrade失敗、5分timeout、
  Deployment非Ready、予期しないchart/revision/resource変更、他packageのreconcile、
  Secret値が出力されそうな操作で即停止する。
- `flux resume`、手動`kubectl patch`、`helm upgrade/rollback/uninstall`は行わない。
- まずactivation commitをrevertする別PRを作り、outer/innerを同じcommitで`suspend: true`へ戻す。
  suspendは将来のreconcileを止めるだけで、既に行われたHelm upgradeをrollbackしない。
- Helm rollbackやresource修復が必要なら、read-only evidenceを保存した後、別の明示承認を得る。
- ESO controllerが安定するまでESO config、CSIのactivation PRを作成・マージしない。

一次資料:

- [Flux HelmRelease reconciliation](https://fluxcd.io/flux/components/helm/helmreleases/)
- [Flux Kustomization suspend and health checks](https://fluxcd.io/flux/components/kustomize/kustomizations/)
- [ESO v0.14.4 stability and support](https://external-secrets.io/v0.14.4/introduction/stability-support/)
