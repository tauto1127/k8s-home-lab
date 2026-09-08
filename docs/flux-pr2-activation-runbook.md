# PR2 activation runbook（cumulative CSI phase）

このrunbookはbootstrap完了後の別PRのGit commitでのみ実行する。CLI `flux resume`は禁止。root Kustomizationは継続してreconcileし、NextcloudのGit上の`suspend: true`を維持する。現在のcumulative phaseはESO controller → ESO config → CSIであり、bootstrapのGit定義と実際のcluster適用は`docs/flux-bootstrap-runbook.md`で別管理する。

## Preflight

- [ ] `docs/flux-bootstrap-runbook.md`の別承認でFlux bootstrapを適用し、CRD/controller、GitRepository、root KustomizationがReady
- [ ] `flux-system/flux-system` GitRepository identityがpolicy allowlistと一致
- [ ] read-only diffで既存Helm release、child resource、ownership collisionを確認
- [ ] ESO controller/configはactive、CSI/Nextcloudの現状と今回のexpected diffを保存
- [ ] 全packageで`prune: false`、CSI outer/innerの同一commit境界を確認
- [ ] Secret値・Helm Secret・raw manifestを取得していない
- [ ] credential rotationの記録は独立運用証跡で、自動安全証明ではないと承認者が確認
- [ ] 公式bootstrapの`cluster-reconciler-flux-system`が付与する`cluster-admin`について、Flux multi-tenancy lockdownを採用するかsingle-tenant前提で継続するかを別レビューで明示承認

## One activation commit

対象は外側Flux Kustomizationと内側HelmReleaseを同じcommitで変更する。現在activeな
identityは`.github/manifest-policy.yaml`の`fluxActivation`へ全件列挙し、片側だけの有効化を
validatorで拒否する。順序は以下のみ。

1. ESO controller: outer Kustomization + HelmReleaseをfalse。timeout 5m。Deployment/CRDがReadyでなければ即停止しcommit revert。revert後のouter停止確認と、存在するinner HelmReleaseの明示承認済み直接suspendを含む個別の証跡・手順は`docs/flux-eso-controller-activation-runbook.md`。
2. ESO config: `eso-config` Kustomizationだけをfalseにし、既存ClusterSecretStore 1件を管理する。ExternalSecret自体にsuspendを設定しない。Secret値ではなくstatusでstore Readyと既存ExternalSecretのSecretSyncedを確認。timeout/provider failureで停止・revert。詳細は`docs/flux-eso-config-activation-runbook.md`。
3. CSI: `flux-system/csi-secrets-store` と `kube-system/csi-secrets-store` を同一commitでfalseにする。outerは`wait: true`、`prune: false`、`dependsOn: eso-config`。`secrets-store-csi-driver` 1.4.8の公式artifact SHA256、CRD集合、stable no-hooks 10 resource inventoryをpolicyで固定し、Helm install/upgradeは`crds: Skip`、`disableHooks: true`、`disableTakeOwnership: true`、`linux.crds.enabled: false`とする。DaemonSet rollout、release identity、ownership、live CRD schema/owner、runtime artifact digestをread-only確認する。image ID差とworker restart履歴は残存リスクとして記録する。failureで停止・revert。詳細は`docs/flux-csi-secrets-store-activation-runbook.md`。
4. Nextcloud: 常に除外。`activation-blocked` annotationはFlux nativeの強制機構ではなく、外側だけを手動resumeするとExternalSecretが先に適用され得る。Ingress/PVC/NFS/Service/cron/probes/TLS、render child、existing Helm release adoption/parity、外部Secret参照の安全な証明に加え、Secret適用を独立phase/packageへ分けるかadmission policyを用意した別PRまでblocked。

各段階でReady条件、開始/終了時刻、timeout、停止理由、revert commitをPRに記録する。pruneは有効化しない。

## Failure policy

- timeout、Ready false、unknown dependency/source、ownership collision、予期しないdiffはfail-closed。
- CLI resumeは使わない。Git上のpackage `suspend: true`が正であり、activeなroot reconciliationが停止状態を維持する。
- Nextcloud outer Kustomizationを手動patch/unsuspendしない。annotationだけではFluxのreconcileを止められない。
- rollbackはactivation commitのrevert PRで行う。revert後にouter停止をread-only確認したうえで、存在するinner HelmReleaseを直接`suspend: true`にする緊急cluster writeは、別途明示承認を得た運用手順としてのみ実施し、この準備PRからは実施しない。詳細は`docs/flux-eso-controller-activation-runbook.md`。
