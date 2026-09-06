# home Flux sync boundary

このディレクトリは、Flux bootstrap後に別途レビューして有効化する同期定義だけを置く。
このPRではFluxをインストールせず、すべてのFlux `Kustomization` と `HelmRelease` を
`suspend: true`、`prune: false`で初期停止する。

`sync.yaml` のpackage境界はESO controller、ESO設定、CSI Driver、Nextcloudだけである。
ESO controllerを先に置き、ClusterSecretStore/ExternalSecretを含むESO設定とNextcloudが
依存する。`gcpsm-secret`のSecretデータはGitに取り込まず、外部プロビジョニングを前提にする。

有効化ゲートは、Flux bootstrap、read-only diff、明示承認、controller、health、設定、
applicationsの順とする。pruneを有効にする判断はこのPRの範囲外である。
