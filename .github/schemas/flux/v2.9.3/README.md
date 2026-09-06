# Flux v2.9.3 offline schemas

`v1.36.0-standalone-strict/`のJSONはFlux `v2.9.3` release asset `crd-schemas.tar.gz`から、現在Gitで使用する`GitRepository`、`Kustomization`、`HelmRepository`、`HelmRelease`と共通definitionsだけを抽出したもの。

- Source: <https://github.com/fluxcd/flux2/releases/download/v2.9.3/crd-schemas.tar.gz>
- Archive SHA256: `91a555810a37a61b021d0a7334d5623783d267a7ecbbff7d5a00e8c7df9c0d33`
- Kubeconform Kubernetes schema directory: `v1.36.0-standalone-strict`

各JSONのSHA256と完全なfile inventoryは`.github/manifest-policy.yaml`で固定する。`scripts/validate-flux-ownership.rb`は固定URLのarchiveを実取得してarchive SHA256を確認し、選択した各JSONをメモリ上で展開したupstream bytesとbyte比較する。これはFlux CRのoffline schema検証を提供するが、admission webhook、controller runtime、live API server compatibilityを証明するものではない。
