# Flux bootstrap runbook（未実行）

対象はFlux `v2.9.3`、cluster `home`、public repository `https://github.com/tauto1127/k8s-home-lab`の`main` branchである。この文書のcluster writeコマンドは、このPRでは一度も実行していない。PRのmergeとclusterへのbootstrap適用は別の操作であり、適用には改めて人間の明示承認が必要である。

## Phase boundary

このrunbookが扱うのはFlux CRD/controllerのinstallと、GitRepository/root Kustomizationの作成までである。rootは`clusters/home/flux-system/`だけを構成し、4つのworkload package Kustomizationを停止状態で作成する。ESO、CSI、Nextcloudのactivation、prune有効化、既存Helm release adoptionは扱わない。

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

期待diffは次だけである。

- `flux-system` Namespace、Flux `v2.9.3`のCRD/controller/RBAC/network policy
- credentialを持たない`flux-system/flux-system` GitRepository
- `./clusters/home`、`prune: false`の`flux-system/flux-system` root Kustomization
- root reconciliation後に、4つのpackage Kustomizationが`suspend: true`、`prune: false`で存在する
- 3つのHelmReleaseが`suspend: true`で存在する
- Nextcloudの外側・内側activation gateが`"true"`のままである

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
- 4つのpackage Kustomizationまたは3つのHelmReleaseの停止状態が崩れる
- Nextcloudのどちらかのactivation gateが欠ける
- 認証、source取得、RBAC、admission、ownership collisionのerrorが出る

緊急停止が必要な場合、次のpatchはcluster writeであり、別の明示承認後にだけ使う。rootを停止した後もpackageはGit上の`suspend: true`を正とする。

```bash
ssh kube 'kubectl patch -n flux-system kustomization flux-system --type=merge -p '\''{"spec":{"suspend":true}}'\'''
```

## Post-install verification（値を限定したread-only確認）

```bash
ssh kube 'kubectl get deployment -n flux-system -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,IMAGE:.spec.template.spec.containers[0].image'
ssh kube 'kubectl get gitrepository -n flux-system flux-system -o custom-columns=NAME:.metadata.name,URL:.spec.url,BRANCH:.spec.ref.branch,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason'
ssh kube 'kubectl get kustomization -n flux-system -o custom-columns=NAME:.metadata.name,PATH:.spec.path,SUSPEND:.spec.suspend,PRUNE:.spec.prune,READY:.status.conditions[0].status'
ssh kube 'kubectl get helmrelease -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend,BLOCKED:.metadata.annotations.flux\\.takutk\\.com/activation-blocked'
```

期待状態は、rootだけがreconcile可能、package Kustomizationはすべて`suspend: true`/`prune: false`、HelmReleaseはすべて`suspend: true`、Nextcloudはblockedである。「controllerがAvailable」と「bootstrap/rootがReady」は、workload activation成功を意味しない。

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
