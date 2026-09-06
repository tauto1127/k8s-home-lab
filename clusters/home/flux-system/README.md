# home Flux sync boundary

このPRはFlux bootstrapではなく、停止状態のmigration preparationである。gotk-components、Flux CRD/controller、GitRepository bootstrap定義はこのrepoにない。したがって、このPRをmerge/applyしただけでFluxがinstall/startしたりworkloadをreconcileしたりすることはない。

すべてのFlux Kustomizationは`suspend: true`、`prune: false`、すべてのHelmReleaseは`suspend: true`を維持する。activationはCLIの`flux resume`ではなく、別PRのGit commitで、外側Flux Kustomizationと内側HelmReleaseのsuspendを同じactivation changeでfalseにする。root reconciliationはCLIで一時resumeしても、Git上の`suspend: true`へ戻す。

依存順はESO controller → ESO config（ClusterSecretStore/ExternalSecret）→ CSIである。NextcloudはIngress/PVC/NFS/Service/cron/probes/TLS、既存Helm release adoption、rendered child resource、Secretを読まないmetadata parityを含む完全parityが独立証明されるまでactivation対象外で、`flux.takut.dev/activation-blocked: "true"`を機械検証するfail-closed gateがある。`createNamespace: true`はHelmRelease CR自身のnamespaceを作成しないため、external-secretsとnextcloudのNamespace desired manifestをcontroller/nextcloud packageが所有する。

## Activation boundary

1. 別途Flux bootstrap（このPRでは実施しない）後、GitRepository identity `flux-system/flux-system`がbootstrap管理allowlistにあることを確認する。
2. activation用の別PRで、外側Kustomizationと内側HelmReleaseを同じcommitで変更する。ESO controllerだけを先に有効化し、timeout 5mでReadyを確認する。
3. ESO controllerのDeployment/CRDがReadyでなければ停止し、変更commitをrevertしてrollbackする。
4. 次にESO configを有効化し、ClusterSecretStoreとExternalSecretのReady/SecretSyncedを、Secret値を取得せずmetadata/statusだけで確認する。timeoutまたはprovider不備なら停止・revertする。
5. CSIを個別に有効化し、DaemonSetのrolloutと既存ownership collisionをread-only確認する。失敗時は停止・revertする。
6. Nextcloudはこのrunbookでは有効化しない。完全parity証明と専用承認を満たした別PRでのみ、blocked annotationを解除する。
7. prune有効化、既存release adoption、TLS/credential rotationの運用証跡は別レビューとする。

expected diffは、activation PRの対象Kustomizationと同じpackage内HelmReleaseの`suspend: true`→`false`、Nextcloudを除く範囲でblocked annotationの変更、その他のmanifest差分なしである。Ready条件、timeout、stop、revertをPR本文に記録する。rotation記録はrepo/CIから独立検証できない運用証跡であり、activation safetyの自動証明ではない。

CIのkubeconformはFlux CRD schemaを`allowedMissingSchemas`でskipしている。これはCRD compatibilityを証明せず、operator/server gateも存在しない。固定offline schema導入までは未証明ゲートとして扱う。
