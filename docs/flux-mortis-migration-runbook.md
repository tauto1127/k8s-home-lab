# Mortis の Flux 移行 runbook

## 対象範囲

Mortis の Preparation と、後続の Activation を別々のPRで実施する。
Cronus、Portainer、Nextcloud、Argo CD のリソース、テスト用リソース、operatorが生成する子リソースは対象外とする。

## Preparation PR

Preparation package は次のとおり。

- `clusters/home/packages/mortis/`
- Flux `Kustomization` `flux-system/mortis`
- `spec.path: ./clusters/home/packages/mortis`
- `spec.suspend: true`
- `spec.prune: false`
- `spec.wait: true`

package が宣言するのは、既存の Mortis Namespace、Service、Deployment だけである。
Memos、Secret、PVC、PV、operator の子リソース、生成リソースは宣言しない。
Deployment は既存の `memos.memos.svc.cluster.local` Service を参照するが、所有しない。

Preparation の検証では、`kubectl kustomize` のレンダー結果について次を確認する。

- resource identity が `v1/Namespace//mortis`、`v1/Service/mortis/mortis`、
  `apps/v1/Deployment/mortis/mortis` の3個と完全一致すること
- image が `ghcr.io/mudkipme/mortis:0.29.0` であること
- Service が `LoadBalancer`、port `5231`、MetalLB address `192.168.11.212` であること
- Deployment のprobe、argument、requests、limits、selector が live と一致すること
- PVC/PV、Secret、Ingress、Cronus、Portainer のresourceがレンダーされないこと
- クラスタへの直接writeを行わないこと

## Activation PR

Preparation PRではActivationしない。Preparation PRのmerge後、Fluxが suspended な
Kustomization を作成したことを確認してから、別のActivation PRを作成する。

Activation PRで必要な変更は `sync.yaml` の `suspend: false` だけではない。次を同じPRで更新・検証する。

1. `.github/manifest-policy.yaml` の `fluxActivation.activeKustomizations` に
   `flux-system/mortis` を追加し、path と上記3 resourceのinventoryを記載する。
2. `fluxActivation` の既存phase契約と衝突しないよう、Mortis Activation用のphase契約を
   validatorへ追加または既存の契約を拡張する。既存のESO/CSIのactive resource、inventory、
   Nextcloudのblocked契約は維持する。
3. `scripts/test-validation.rb` のPreparation用 `suspend: true` assertionをActivation用の
   `suspend: false` assertionとpolicy/inventory assertionへ更新する。
4. `scripts/validate-flux-ownership.rb` と全manifest validationを実行し、Mortis以外の
   ownershipやinventoryに差分がないことを確認する。

Activation後も `prune: false` は維持する。`flux resume`、`flux reconcile`、
`kubectl apply`、手動rolloutコマンドは使用しない。

Activation前にliveの Mortis resource がpackageと一致し、他のKustomizationが同じidentityを
所有していないことを確認する。merge後はFluxとMortisのreadinessだけを確認し、他のworkloadを変更しない。

## Rollback

review済みのGit PRで `flux-system/mortis` を再びsuspendする。RollbackでNamespace、Service、
Deploymentを削除しない。PVC/PVと外部データはこのpackageに含まれない。
