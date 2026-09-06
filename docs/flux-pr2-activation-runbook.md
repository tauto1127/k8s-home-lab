# PR2 activation runbook template（準備PR）

このtemplateはbootstrap完了後の別PRのGit commitでのみ実行する。CLI `flux resume`は禁止。root Kustomizationは継続してreconcileし、停止対象packageのGit上の`suspend: true`を維持する。PR2は停止状態の準備であり、bootstrapのGit定義と実際のcluster適用は`docs/flux-bootstrap-runbook.md`で別管理する。

## Preflight

- [ ] `docs/flux-bootstrap-runbook.md`の別承認でFlux bootstrapを適用し、CRD/controller、GitRepository、root KustomizationがReady
- [ ] `flux-system/flux-system` GitRepository identityがpolicy allowlistと一致
- [ ] read-only diffで既存Helm release、child resource、ownership collisionを確認
- [ ] `suspend: true` / `prune: false`の現状と、今回のexpected diffを保存
- [ ] Secret値・Helm Secret・raw manifestを取得していない
- [ ] credential rotationの記録は独立運用証跡で、自動安全証明ではないと承認者が確認
- [ ] 公式bootstrapの`cluster-reconciler-flux-system`が付与する`cluster-admin`について、Flux multi-tenancy lockdownを採用するかsingle-tenant前提で継続するかを別レビューで明示承認

## One activation commit

対象は外側Flux Kustomizationと内側HelmReleaseを同じcommitで変更する。順序は以下のみ。

1. ESO controller: outer Kustomization + HelmReleaseをfalse。timeout 5m。Deployment/CRDがReadyでなければ即停止しcommit revert。
2. ESO config: ClusterSecretStore/ExternalSecretをfalse。Secret値ではなくstatus/metadataでReady/SecretSyncedを確認。timeout/provider failureで停止・revert。
3. CSI: DaemonSet rolloutとownershipをread-only確認。failureで停止・revert。
4. Nextcloud: 常に除外。`activation-blocked` annotationはFlux nativeの強制機構ではなく、外側だけを手動resumeするとExternalSecretが先に適用され得る。Ingress/PVC/NFS/Service/cron/probes/TLS、render child、existing Helm release adoption/parity、外部Secret参照の安全な証明に加え、Secret適用を独立phase/packageへ分けるかadmission policyを用意した別PRまでblocked。

各段階でReady条件、開始/終了時刻、timeout、停止理由、revert commitをPRに記録する。pruneは有効化しない。

## Failure policy

- timeout、Ready false、unknown dependency/source、ownership collision、予期しないdiffはfail-closed。
- CLI resumeは使わない。Git上のpackage `suspend: true`が正であり、activeなroot reconciliationが停止状態を維持する。
- Nextcloud outer Kustomizationを手動patch/unsuspendしない。annotationだけではFluxのreconcileを止められない。
- rollbackはactivation commitのrevert PRで行い、cluster writeをこの準備PRから実施しない。
