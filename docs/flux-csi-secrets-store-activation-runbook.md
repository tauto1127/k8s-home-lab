# Secrets Store CSI Driver の Flux 管理移行

このrunbookは、既存の `kube-system/csi-secrets-store` Helm release を
Flux 管理へ移す cumulative phase `csi-secrets-store` のGit変更と、read-only preflightの
確認済み事項・残る停止条件を記録する。
ESO controller と `ClusterSecretStore/secret-store-provider` は先行 phase の
管理境界を維持し、Nextcloud は引き続き停止する。今回の作業ではclusterへの操作を行わない。

## Preflight（確認済み証跡と残る停止条件）

チェック済み項目は2026-09-08時点のread-only preflightまたはGit固定値で確認済みであり、
未チェックの必須項目はactivationを停止する。Warning表記の観測差分は、下記の成功条件で
不変または説明済みであることを確認する。Secret 値、Helm Secret、`helm get values`、raw manifestは取得しない。

- [x] Flux controller、root、`eso-controller`、`eso-config` が Ready（read-only preflight確認済み）
- [x] live release identity: `kube-system/csi-secrets-store`
- [x] live chart/revision: `secrets-store-csi-driver-1.4.8`; live DaemonSet is Ready 2/2
- [x] chart repository URL: `https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts`
- [x] chart archive URL: `https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.4.8.tgz`
- [x] chart archive SHA256: `894ee5351f615184af4ad0f4ea03be35485e65bc1797c10e315fcd1bcc3aef13`
- [x] stable no-hooks inventory: 10 exact resources; default render has 18 resources including 8 transient CRD hook objects
- [x] existing CRDs `secretproviderclasses.secrets-store.csi.x-k8s.io` and
      `secretproviderclasspodstatuses.secrets-store.csi.x-k8s.io` have matching selected schema,
      owner, and version fields: SPC schema SHA256 `5fd3ce634633e0ddc084147ff344af5e1a73c7f2115c218bd1a9cb28635b4cb4`,
      SPCPS schema SHA256 `6e2bbc518f71707be11348fdbb067a2b7385416ce6c56d7614869b9fdbd086a4`,
      both `v1` served/storage and `v1alpha1` served/non-storage; ownership is empty except the
      `controller-gen.kubebuilder.io/version` annotation
- [x] rendered child inventory is the exact stable 10-resource set, server diff is empty, and
      Helm ownership metadata has no competing owner for the selected resources
- [ ] image ID parity and restart-history parity remain unresolved
- [x] `eso-config` が Ready であり、CSI package の dependency が解決可能
- [x] Git desired: CSI packageは有効、Nextcloudは停止、全 package の `prune: false` を固定（live post-merge状態は未確認）
- [ ] merge後の `csi-secrets-store`/Nextcloudのlive suspend・Ready状態を保存

> Warning (not an activation stop by itself): the live DaemonSet is Ready 2/2, but node image
> IDs differ and worker restart history is higher than the controller. The merge gate is an
> unchanged or explained image-ID/restart baseline and no unexpected rollout; the image-ID
> difference alone is not a blocker because the stable server diff is empty.

policy は公式 archive SHA256、`crds/` 2件の集合SHA256、stable no-hooks inventory 10件を固定する。
CRD集合SHA256は、archive pathを昇順に並べ、各 `path + NUL + file bytes + NUL` を連結して
SHA256化する既存validatorのアルゴリズムで再計算する。
chartのstable inventory gateはCRDをapiVersion/kind/namespace/nameのidentityだけで比較する。
CRDはHelm childのrelease ownership annotationを期待する対象ではなく、live側のschema・version・
owner metadataは別のread-only preflightで確認する。
live CRD の名前・schema・owner がこの archive と一致しない、またはどちらか一方が欠落する場合は
fail-closed とし、既存 CRD の修復・upgrade は別承認に分ける。

## Git activation boundary

外側と内側を同一 commit で変更する。

- `clusters/home/flux-system/sync.yaml` の `flux-system/csi-secrets-store`:
  `suspend: false`、`prune: false`、`wait: true`、`dependsOn: [{name: eso-config}]`
- `clusters/home/packages/csi-secrets-store/helmrelease.yaml` の
  `kube-system/csi-secrets-store`: `suspend: false`、`releaseName`、
  `targetNamespace`、`storageNamespace` はすべて `kube-system`
- install/upgrade とも `crds: Skip`、`disableTakeOwnership: true`
- install/upgrade とも `disableHooks: true`。chart values は `linux.crds.enabled: false` とし、
  既存 CRD を Helm hook で書き換えない
- chart は `secrets-store-csi-driver` 1.4.8、repository は既存 HelmRepository の
  `https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts`
- すべての package Kustomization は `prune: false`。Secret 値や生成 child resource は
  Git に追加しない

依存は既存の移行順序 ESO controller → ESO config → CSI の直前段だけを表すため、
`eso-config` の一件に限定する。controller を直接併記して別の順序を作らない。

## Merge 後の read-only confirmation

5 分を timeout とし、次を選択フィールドだけで確認する。以下は承認後に実行する手順であり、
このPRではマージ後まで実行しない。

```bash
ssh kube 'kubectl get -n flux-system kustomization eso-controller eso-config csi-secrets-store nextcloud -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend,PRUNE:.spec.prune,READY:.status.conditions[?(@.type=="Ready")].status,LAST_APPLIED:.status.lastAppliedRevision'
ssh kube 'kubectl wait -n flux-system kustomization/csi-secrets-store --for=condition=ready --timeout=5m'
ssh kube 'kubectl wait -n kube-system helmrelease/csi-secrets-store --for=condition=ready --timeout=5m'
ssh kube 'kubectl get -n kube-system helmrelease csi-secrets-store -o custom-columns=NAME:.metadata.name,CHART:.spec.chart.spec.chart,VERSION:.spec.chart.spec.version,RELEASE:.spec.releaseName,TARGET:.spec.targetNamespace,STORAGE:.spec.storageNamespace,SUSPEND:.spec.suspend'
ssh kube 'kubectl get -n kube-system daemonset csi-secrets-store-secrets-store-csi-driver -o custom-columns=NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady,UPDATED:.status.updatedNumberScheduled'
```

成功条件は outer/inner とも Ready、DaemonSet が desired 数で Ready、Helm ownership collision
なし、ESO controller/config Ready、Nextcloud outer/inner が停止中であることに加え、preflight
baselineから予期しないrolloutがなく、image ID/restart差分が不変または説明済みであること。
image ID差分だけでは停止しない。HelmChart のruntime artifact digestは、preflightで記録された
値と別途照合する。

## Failure / rollback

取得失敗、artifact fingerprint 不一致、ownership collision、DaemonSet 非 Ready、依存不明、
予期しない diff、Secret 値が出力されそうな操作では停止する。`flux resume`、`helm upgrade`、
手動 patch は行わない。

rollback は PR #46 で確立した quiesce/recheck 順序を使う。

1. outer Kustomization と inner HelmRelease をともに `suspend: true`へ戻す同一 Git revert
   commitのPRを作成・マージする。片側だけのGit変更は作らない。
2. read-onlyでrootのrevert SHA適用と `flux-system/csi-secrets-store` の停止を確認する。
   root適用またはouter停止を確認できなければ、別の操作へ進まない。
3. outer停止後、`kube-system/csi-secrets-store` が存在する場合だけ、別途明示承認を得た
   緊急停止としてinnerへ `suspend: true`をpatchする。これはGit revertの代替ではない。
4. outer/innerの停止、revert後のdesired、進行中の `Reconciling=True` 解消をread-onlyで再確認
   する。innerがfalseへ戻る、または処理が継続中なら停止完了と扱わない。
5. `suspend`は進行中のHelm処理をrollbackしないため、Helm rollbackやresource修復は証跡保存後の
   別承認とする。

CSI が安定するまで Nextcloud は有効化しない。

一次資料:

- [Secrets Store CSI Driver Helm chart](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Flux HelmRelease reconciliation](https://fluxcd.io/flux/components/helm/helmreleases/)
- [Flux Kustomization dependencies](https://fluxcd.io/flux/components/kustomize/kustomizations/)
