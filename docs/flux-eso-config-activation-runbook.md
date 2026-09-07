# ESO config の Flux 管理移行

対象は既存の `ClusterSecretStore/secret-store-provider` 1件だけ。
Git上の接続設定は変更せず、`Kustomization/flux-system/eso-config` を有効にする。
先行するESO controllerはPR #46で移行済み。CSIとNextcloudのFlux packageは停止を維持する。
このPRのマージを稼働中のFluxが検知すると、既存storeがFlux管理に入る。

## 2026-09-07 の読み取り確認

- Flux controller 4件がReady、rootとeso-controllerは `b6a453ce6f3ca4473614c7b6a525478aaa89e52e` を適用済みでReady。
- ESO HelmReleaseはReady。既存storeは `Ready=True / Valid`。
- storeのspecはGitと一致。providerはgcpsmだけ、projectIDは `269357193809`。
  認証参照はnamespace/nameともに `gcpsm-secret`、keyは `secret-access-credentials`。
  spec各階層のキー名も確認し、追加provider/auth/conditions等がないことを確認した。
- storeを参照する既存ExternalSecret 10件はすべて `Ready=True / SecretSynced`。
  別storeを使うcronus-mongodbも正常。Secret値は取得していない。
- storeのmanagedFieldsに2025-05-27のargocd-controller履歴が残るが、現在のApplication APIは存在せず、
  Argo tracking-id/instanceラベルはない。Deployment/StatefulSet一覧にもArgo controllerはない。
  過去のmanager記録だけを現在の二重管理とはみなさない。

## Git と検証の境界

- `eso-config.suspend: false`、`prune: false`、`wait: true`、`dependsOn: eso-controller`。
- validatorはphaseの正確なinventory/pathと、storeのspec全体を固定する。
  接続先、認証参照、追加spec、依存関係の変更をこの移行に混ぜない。
- Credential SecretやアプリのExternalSecretはこのpackageに含めない。
  既存のESOによるSecret同期は継続する。Nextcloud packageが停止中でも、既存の
  Nextcloud ExternalSecretは引き続きESOが同期している。
- KubeconformのClusterSecretStore schemaは既存のallowedMissingSchemas対象であり、
  CI通過だけではCRD互換性や外部サービスへの認証成功を証明しない。

## マージ前・マージ後の確認

マージ前に上記preflightのReady、参照先、他packageの停止を再確認する。
期待される変更はstoreへのFlux管理metadataと所有フィールドの追加であり、provider設定の変更はない。
マージ後5分以内にroot/eso-configの`status.lastAppliedRevision`が
`main@sha1:<マージSHA>`と一致し、storeがReadyになることを確認する。
以下は読み取り専用。成功を記録するまでは実施予定の手順として扱う。

```bash
ssh kube 'kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system -o custom-columns=NAME:.metadata.name,PATH:.spec.path,SUSPEND:.spec.suspend,PRUNE:.spec.prune,READY:.status.conditions[?(@.type=="Ready")].status,LAST_APPLIED:.status.lastAppliedRevision'
ssh kube 'kubectl get clustersecretstore secret-store-provider'
ssh kube 'kubectl get externalsecret -A -o "custom-columns=NS:.metadata.namespace,NAME:.metadata.name,STORE:.spec.secretStoreRef.name,READY:.status.conditions[?(@.type==\"Ready\")].status,REASON:.status.conditions[?(@.type==\"Ready\")].reason"'
ssh kube 'kubectl get helmrelease -n external-secrets'
```

root/eso-config Ready、store Valid、参照する10件のExternalSecret SecretSynced、ESO HelmRelease Readyを確認する。
CSI/Nextcloudのsuspend=trueとNextcloudのactivation-blocked=trueも確認する。
Secret値・raw Secret・helm get values/manifestは取得しない。

## 異常時

5分timeout、Ready=False、参照の変化、想定外の所有者、他packageの有効化で後続移行を停止する。
このactivationだけをrevertするPRを作り、policyをeso-controller phaseへ戻し、eso-configを停止する。
rootがrevertを適用し、eso-configのsuspend=trueを確認する。
このpackageには自律的にHelm処理を続けるHelmReleaseはないため、PR #46のinner停止操作は不要。
prune=falseなのでstoreや生成Secretは削除されず、既存ESOの同期も停止しない。
revertはstore設定の破損を修復する操作ではない。設定修復や直接のcluster writeが必要なら別途承認を得る。

一次資料:

- [ESO v0.14.4 ClusterSecretStore](https://external-secrets.io/v0.14.4/api/clustersecretstore/)
- [Flux Kustomization dependencies and health checks](https://fluxcd.io/flux/components/kustomize/kustomizations/)
