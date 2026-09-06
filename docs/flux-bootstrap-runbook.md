# Flux bootstrap runbook（未実行）

対象はFlux `v2.9.3`、cluster `home`、public repository `https://github.com/tauto1127/k8s-home-lab`の`main` branchである。この文書のcluster writeコマンドは、このPRでは一度も実行していない。PRのmergeとclusterへのbootstrap適用は別の操作であり、適用には改めて人間の明示承認が必要である。

## Phase boundary

このrunbookが扱うのはFlux CRD/controllerのinstallと、GitRepository/root Kustomizationの作成までである。rootは`clusters/home/flux-system/`だけを構成し、4つのworkload package Kustomizationを停止状態で作成する。停止中のpackageは中身をrender/applyしないため、この段階では3つのHelmReleaseやNextcloudのExternalSecretはclusterに作成されない。ESO、CSI、Nextcloudのactivation、prune有効化、既存Helm release adoptionは扱わない。

`flux.takutk.com/activation-blocked`はrepository validatorが確認するCI markerであり、Flux nativeの強制機構ではない。権限を持つ人がNextcloudの外側Kustomizationを手動でresume/patchすると、内側HelmReleaseが停止中でもExternalSecretが適用され得る。そのためCLI `flux resume`と手動unsuspendは禁止し、Nextcloudの将来activation前にはSecret適用を独立phase/packageへ分離するか、admission policyで同時承認を強制する別設計を必須とする。

## Preflight（read-only）

1. 承認対象のcommitをcheckoutし、worktreeがcleanであることを確認する。

   ```bash
   git fetch origin
   git status --short --branch
   git rev-parse HEAD
   git rev-parse origin/main
   ```

2. repository-pinned toolと生成物を検証する。

   ```bash
   aqua install
   aqua exec -- flux version --client
   shasum -a 256 clusters/home/flux-system/gotk-components.yaml
   ruby scripts/test-validation.rb
   bash scripts/validate-manifests.sh
   ```

   `gotk-components.yaml`の期待値は`c6e84495c3b611978d053adc40aca1e2a12af38f6e239c44a6b6c1224e01cab7`である。

3. `ssh kube`で、Kubernetes versionとzero-Flux状態を値を限定して確認する。

   ```bash
   ssh kube 'kubectl version -o yaml | sed -n "/serverVersion:/,/^$/p"'
   ssh kube 'kubectl get namespace flux-system --ignore-not-found -o name'
   ssh kube 'kubectl api-resources --api-group=source.toolkit.fluxcd.io -o name 2>/dev/null'
   ssh kube 'kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io -o name 2>/dev/null'
   ssh kube 'helm list -A -o json | jq -r ".[] | select((.name | ascii_downcase | contains(\"flux\")) or (.chart | ascii_downcase | contains(\"flux\"))) | [.namespace,.name,.chart] | @tsv"'
   ```

4. 適用前diffを確認する。`kubectl diff`もAPI serverへrequestするため、実行時点の承認範囲に含める。

   ```bash
   ssh kube 'kubectl diff --server-side -f -' < clusters/home/flux-system/gotk-components.yaml
   ssh kube 'kubectl diff -f -' < clusters/home/flux-system/gotk-sync.yaml
   ```

5. `cluster-reconciler-flux-system` ClusterRoleBindingが、公式生成物どおり`cluster-admin`を`kustomize-controller`と`helm-controller`へ付与することを承認者が明示確認する。このbootstrap PRはleast privilegeを証明しない。workload activation前に、Flux multi-tenancy lockdownを採用するか、single-tenant clusterとしてこの権限を継続する判断を別レビューで明示承認する。また、生成bundleの固定と再生成一致はcontroller image tag自体をimmutableにしないため、tag trustを受け入れるか、別途digest/signatureを検証する判断も適用承認に含める。GitRepositoryはmutableな`main`を追従するため、repository write権限とbranch protectionも同じ承認で確認する。

期待diffは次だけである。

- `flux-system` Namespace、Flux `v2.9.3`のCRD/controller/RBAC/network policy
- credentialを持たない`flux-system/flux-system` GitRepository
- `./clusters/home`、`prune: false`の`flux-system/flux-system` root Kustomization
- root reconciliation後に、4つのpackage Kustomizationが`suspend: true`、`prune: false`で存在する
- packageが停止中なので、3つのHelmReleaseを含むpackage内resourceはまだ作成されない
- Nextcloudは外側Kustomizationのactivation gateが`"true"`で、内側HelmReleaseはまだ作成されない（Git上では内側gateも`"true"`のまま）

## Future install/bootstrap（明示承認後のみ）

最初にcomponentsだけを適用し、4 controllerが5分以内にAvailableになるまで待つ。

```bash
ssh kube 'kubectl apply --server-side --field-manager=flux-bootstrap -f -' < clusters/home/flux-system/gotk-components.yaml
ssh kube 'kubectl wait -n flux-system --for=condition=Available deployment/source-controller deployment/kustomize-controller deployment/helm-controller deployment/notification-controller --timeout=5m'
```

成功した場合だけsource/rootを適用し、5分以内にReadyを確認する。

```bash
ssh kube 'kubectl apply --server-side --field-manager=flux-bootstrap -f -' < clusters/home/flux-system/gotk-sync.yaml
ssh kube 'kubectl wait -n flux-system --for=condition=Ready gitrepository/flux-system --timeout=5m'
ssh kube 'kubectl wait -n flux-system --for=condition=Ready kustomization/flux-system --timeout=5m'
```

## Stop conditions

次のいずれかなら、その段階で後続コマンドを実行しない。

- preflight時点で既存Flux namespace、Flux CRD/controller/releaseが見つかる
- Kubernetes version、Git HEAD、artifact checksum、repository URL/branch/pathが期待値と異なる
- diffに既存workloadの更新・削除、Secret data、`prune: true`、packageの`suspend: false`が含まれる
- controller、GitRepository、root Kustomizationが各timeout内にReadyにならない
- rootのinventoryに`clusters/home/packages/*`のworkload objectが直接現れる
- 4つのpackage Kustomizationの停止状態が崩れる、またはpackage由来のHelmReleaseが1つでも作成される
- Nextcloudの外側activation gateがcluster上で欠ける、またはGit上の外側・内側gateのどちらかが欠ける
- 公式生成物の`cluster-admin`付与範囲、controller image tagの可変性、public repositoryの`main`追従リスクを承認者が確認していない
- 認証、source取得、RBAC、admission、ownership collisionのerrorが出る

緊急停止が必要な場合、最初に次のread-only確認でroot、4 package、存在するHelmReleaseの状態を限定表示する。rootだけを停止しても、既に有効なchild reconciliationは停止しない。

```bash
ssh kube 'kubectl get kustomization -n flux-system -o custom-columns=NAME:.metadata.name,SUSPEND:.spec.suspend,READY:.status.conditions[0].status'
ssh kube 'kubectl get helmrelease -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend'
```

次のpatchはすべてcluster writeであり、その時点の別の明示承認後にだけ使う。rootを先に停止し、4 packageを個別に停止した後、存在する既知のHelmReleaseも停止する。途中失敗は後続を止め、状態を再確認する。Git上の`suspend: true`を正とし、緊急patchを恒久設定にしない。

```bash
ssh kube 'kubectl patch -n flux-system kustomization flux-system --type=merge -p '\''{"spec":{"suspend":true}}'\'''
ssh kube 'for name in eso-controller eso-config csi-secrets-store nextcloud; do kubectl patch -n flux-system kustomization "$name" --type=merge -p '\''{"spec":{"suspend":true}}'\'' || exit 1; done'
ssh kube 'for target in external-secrets/external-secrets kube-system/csi-secrets-store nextcloud/nextcloud; do namespace=${target%/*}; name=${target#*/}; if kubectl get -n "$namespace" helmrelease "$name" -o name >/dev/null 2>&1; then kubectl patch -n "$namespace" helmrelease "$name" --type=merge -p '\''{"spec":{"suspend":true}}'\'' || exit 1; fi; done'
```

## Post-install verification（値を限定したread-only確認）

```bash
ssh kube 'kubectl get deployment -n flux-system -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[0].image'
ssh kube 'kubectl get gitrepository -n flux-system flux-system -o custom-columns=NAME:.metadata.name,URL:.spec.url,BRANCH:.spec.ref.branch,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason'
ssh kube 'kubectl get kustomization -n flux-system -o custom-columns=NAME:.metadata.name,PATH:.spec.path,SUSPEND:.spec.suspend,PRUNE:.spec.prune,BLOCKED:.metadata.annotations.flux\.takutk\.com/activation-blocked,READY:.status.conditions[0].status'
ssh kube 'kubectl get helmrelease -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend,BLOCKED:.metadata.annotations.flux\.takutk\.com/activation-blocked'
```

期待状態は、rootだけがreconcile可能、package Kustomizationはすべて`suspend: true`/`prune: false`、Nextcloudの外側gateは`true`である。HelmRelease queryは対象0件が正しく、package activation後に初めて各HelmReleaseの停止状態を検証する。「controllerがAvailable」と「bootstrap/rootがReady」は、workload activation成功を意味しない。

## Rollback / uninstall considerations

- source/root適用後に問題が出た場合、まずrootを停止し、status/eventsを値を限定して保存する。自動でCRDを削除しない。
- `gotk-sync.yaml`の削除はGitRepository/rootを消すcluster write、`gotk-components.yaml`の削除はCRD/controller/RBACを消す破壊的なcluster writeである。後者はFlux custom resourceも失わせる可能性がある。
- uninstallは、packageが一度もactivationされていないこと、Flux CR inventory、他ownerの有無を確認し、専用の明示承認を得た別手順で行う。
- workload activation後のrollbackはbootstrap uninstallではなく、対象activation commitのrevertを優先する。

## Primary sources

- Flux v2.9.3 release: <https://github.com/fluxcd/flux2/releases/tag/v2.9.3>
- Flux installation: <https://fluxcd.io/flux/installation/>
- `flux install`: <https://fluxcd.io/flux/cmd/flux_install/>
- `flux create source git`: <https://fluxcd.io/flux/cmd/flux_create_source_git/>
- `flux create kustomization`: <https://fluxcd.io/flux/cmd/flux_create_kustomization/>
