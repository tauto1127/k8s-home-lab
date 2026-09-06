# PR2 activation runbook template（準備PR）

このtemplateは別PRのGit commitでのみ実行する。CLI `flux resume`は禁止。root reconciliationはGitの`suspend: true`へ戻す。PR2はFlux bootstrapではなく停止状態の準備であり、このPRのmerge/applyだけではFluxもworkloadも動かない。

## Preflight

- [ ] Flux bootstrap、gotk-components、CRD/controller、GitRepositoryは別管理で導入済み
- [ ] `flux-system/flux-system` GitRepository identityがpolicy allowlistと一致
- [ ] read-only diffで既存Helm release、child resource、ownership collisionを確認
- [ ] `suspend: true` / `prune: false`の現状と、今回のexpected diffを保存
- [ ] Secret値・Helm Secret・raw manifestを取得していない
- [ ] credential rotationの記録は独立運用証跡で、自動安全証明ではないと承認者が確認

## One activation commit

対象は外側Flux Kustomizationと内側HelmReleaseを同じcommitで変更する。順序は以下のみ。

1. ESO controller: outer Kustomization + HelmReleaseをfalse。timeout 5m。Deployment/CRDがReadyでなければ即停止しcommit revert。
2. ESO config: ClusterSecretStore/ExternalSecretをfalse。Secret値ではなくstatus/metadataでReady/SecretSyncedを確認。timeout/provider failureで停止・revert。
3. CSI: DaemonSet rolloutとownershipをread-only確認。failureで停止・revert。
4. Nextcloud: 常に除外。Ingress/PVC/NFS/Service/cron/probes/TLS、render child、existing Helm release adoption/parity、外部Secret参照の安全な証明が揃う別PRまでblocked。

各段階でReady条件、開始/終了時刻、timeout、停止理由、revert commitをPRに記録する。pruneは有効化しない。

## Failure policy

- timeout、Ready false、unknown dependency/source、ownership collision、予期しないdiffはfail-closed。
- CLI resumeで一時的に動かしてもGitの`suspend: true`が正であり、root reconciliationで再停止される。
- rollbackはactivation commitのrevert PRで行い、cluster writeをこの準備PRから実施しない。
