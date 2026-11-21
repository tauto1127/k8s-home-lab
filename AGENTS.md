# AGENTS.md

このリポジトリとhome-labクラスタを保守するエージェント（と人間）向けのルール。
詳細な移行記録は `docs/manifest-ownership.md` と `docs/*-runbook.md` を参照する。

## 正本はGitの `origin/main`

- Fluxは `GitRepository/flux-system`（このリポジトリの `main`）の `./clusters/home` をreconcileする。
  Flux管理リソースのdesired stateの正本は `origin/main` であり、ローカルのcheckoutではない。
- ローカルのcheckoutは `main` から大きく分岐していたり、未コミットの変更を含んでいたりする。
  作業は `git fetch` 後に `origin/main` からworktreeを切って始め、ローカルのブランチや差分を前提にしない。
- 何がFlux管理かは次で確認する。推測で判断しない。
  - Git: `clusters/home/flux-system/sync.yaml` と `clusters/home/packages/*`
  - live: `kubectl get kustomizations -n flux-system` と `kubectl get helmreleases -A`
  - 分類: `docs/manifest-ownership.md`
- `apps/` と `middlewares/` の大半はFlux管理外（helmfile / kubectl で手動適用）か、移行前の定義である。

## Flux管理リソースの変更手順

1. `origin/main` からworktreeとブランチを作る。
2. `clusters/home/packages/<package>/` を変更する。
3. 検証する（ツールは `aqua install` で揃う）。
   - `ruby scripts/test-validation.rb`
   - `bash scripts/validate-manifests.sh`
   - inventory、apiVersion、chart versionを変えた場合は、`scripts/validate-flux-ownership.rb` と
     `.github/manifest-policy.yaml` の契約を**両方**更新する。chart artifactのsha256とCRDの
     fingerprintは推測せず、実際のartifactから計算する。
4. PRを作る。タイトルはConventional Commits（英語）で、squash mergeする。CIの `validate-manifests` が通ることを確認する。
5. **マージはユーザーの明示的な承認を得てから行う。**
6. マージ後にreconcileを確認する（後述のコマンド）。

### やってはいけないこと

- Flux管理リソースのdesired stateを、`helm upgrade` / `helm rollback` / `kubectl apply|edit|patch|scale`
  で直接変更すること。Fluxに上書きされるか、Gitとの乖離が次回のupgradeを壊す。
  - 実例: Jellyfinのstartup probeの修正を手動の `helm upgrade` だけで入れ、Gitに戻さなかった。
    そのため2026-09から2026-11までFluxのupgradeが失敗し続けた（#97で修正）。
- suspend中のpackage、または `flux.takutk.com/activation-blocked: "true"` の付いたpackage
  （現時点ではgrafanaとnextcloud）を、承認なしに有効化すること。
- 全Kustomizationが `prune: false` であることを忘れること。Gitからファイルを消しても、クラスタからは消えない。
  削除は別作業として明示的に行う。

### 例外: desired stateを変えない修復

次のような操作はクラスタを直接操作してよい。ただし事前に対象を確認してバックアップを取り、
何をしたかをPRまたはdocsに残す。

- CrashLoopやEvictedのPodの削除・再作成
- Helm release storageの修復（削除されたAPI versionが残ったrelease manifestの書き換えなど）
- reconcileの要求（後述のannotation）

## Flux管理外のリソース

- immich、kong、kubernetes-dashboard、kubero、CloudNativePG（`pg`）、redis、postgresなどは手動で管理している。
  Gitの定義とliveがずれている可能性があるので、変更前にliveを確認し、変更後はGitの定義も更新する。
- Fluxへの移行は `docs/manifest-ownership.md` の分類と手順に従う。

## シークレット

- このリポジトリは**public**である。secretの値をGitに書かない（過去のcommit履歴も公開されている）。
- secretはExternal Secrets Operatorで取得する。
  - 標準は `ClusterSecretStore/onepassword`（1Password vault `home-lab`）で、`remoteRef.key` は `<item>/<field>` の形式。
  - ESO 0.20以降は `external-secrets.io/v1beta1` がservedされない。新規作成も既存の更新も `v1` を使う。
- secretの値を出力しない。値の一致確認が必要なときはハッシュで比較する。

## reconcileの確認（`flux` CLIがない環境向け）

```sh
kubectl annotate gitrepository flux-system -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl annotate kustomization <package> -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
kubectl wait helmrelease/<name> -n <namespace> --for=condition=Ready --timeout=10m
kubectl get kustomizations -n flux-system
kubectl get helmreleases -A
```

## クラスタ構成上の注意

- `k8scontroller` は、コントロールプレーンと開発マシンを兼ねる小さなVM（2 vCPU / 8 GiB / disk 30 GiB）。
  ディスクが逼迫すると、DiskPressure、etcdの遅延、controllerの一斉再起動が起きる。大きなファイルやキャッシュをここに溜めない。
- ワークロードは実質 `k8s-worker-node-2` の1台で動いており、PVの大半はNFS（`192.168.11.9`）上にある。
- StorageClass `nfs-client` は `reclaimPolicy: Delete` かつ `archiveOnDelete: "false"` である。
  **PVCやnamespaceを削除すると、データも即座に消える。**
