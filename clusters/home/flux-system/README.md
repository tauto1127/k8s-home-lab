# home Flux bootstrap boundary

このdirectoryは、Flux `v2.9.3`を後日installするためのGit入力である。このPRでは`gotk-components.yaml`、public GitRepository、root Kustomizationを追加するが、clusterには適用しない。mergeだけでFluxが動くことはない。

root Kustomization `flux-system/flux-system`は`./clusters/home`を`prune: false`でreconcileする。`clusters/home/kustomization.yaml`が参照するのは`flux-system/`だけであり、`packages/`を直接renderしない。rootが作成する4つのpackage Kustomizationはすべて`suspend: true`、`prune: false`である。3つのHelmReleaseはGit上で`suspend: true`を維持するが、package停止中のbootstrap段階ではclusterに作成されない。Nextcloudは外側Kustomizationと内側HelmReleaseの両方で`flux.takutk.com/activation-blocked: "true"`を維持する。

## 固定した生成物

- Flux release: `v2.9.3`
- Release: <https://github.com/fluxcd/flux2/releases/tag/v2.9.3>
- Upstream `install.yaml`: <https://github.com/fluxcd/flux2/releases/download/v2.9.3/install.yaml>
- Upstream `install.yaml` SHA256: `aa0bd71dbc4bed916b9cafa850c4618f341c74c580832c613dca04a067ee7281`
- Generated `gotk-components.yaml` SHA256: `c6e84495c3b611978d053adc40aca1e2a12af38f6e239c44a6b6c1224e01cab7`
- CRD schema archive: <https://github.com/fluxcd/flux2/releases/download/v2.9.3/crd-schemas.tar.gz>
- CRD schema archive SHA256: `91a555810a37a61b021d0a7334d5623783d267a7ecbbff7d5a00e8c7df9c0d33`

`gotk-components.yaml`は、repository-pinned CLIを使う次のコマンドの出力である。

```bash
aqua exec -- flux install \
  --version=v2.9.3 \
  --components=source-controller,kustomize-controller,helm-controller,notification-controller \
  --namespace=flux-system \
  --export > clusters/home/flux-system/gotk-components.yaml
```

`gotk-sync.yaml`は次の2コマンドの`--export`出力を順番に連結したもので、credentialを含まない。

```bash
aqua exec -- flux create source git flux-system \
  --namespace=flux-system \
  --url=https://github.com/tauto1127/k8s-home-lab \
  --branch=main \
  --interval=1m \
  --export

aqua exec -- flux create kustomization flux-system \
  --namespace=flux-system \
  --source=GitRepository/flux-system \
  --path=./clusters/home \
  --prune=false \
  --interval=10m \
  --export
```

version、artifact URL/checksum、controller image、bootstrap source/root、offline schema inventoryは`.github/manifest-policy.yaml`と`scripts/validate-flux-ownership.rb`がfail-closedで検証する。validatorは固定HTTPS URLからupstream artifactを取得して記録したSHA256と照合し、repository-pinned Flux CLIで上記コマンドを再実行して`gotk-components.yaml`をbyte比較する。適用手順と停止条件は`docs/flux-bootstrap-runbook.md`を参照する。

## Activation boundary

bootstrap適用後もworkload activationは別PRと別承認で行う。公式bundleの`cluster-admin`付与はbootstrap承認時に明示確認し、workload activation前にはmulti-tenancy lockdown採用かsingle-tenant前提での継続を別レビューする。順序はESO controller → ESO config → CSIで、Nextcloudは完全なHelm values/render/adoption parityとSecret適用phaseの安全な設計が独立に証明されるまで対象外である。`activation-blocked` annotation自体をFluxは解釈しないため、CLI resumeや手動unsuspendは禁止する。activationの詳細は`docs/flux-pr2-activation-runbook.md`を参照する。
