# Manifest ownership during the Flux migration

Last verified: 2026-09-05

This inventory defines which declarations may become Flux inputs. Nothing in
this document means that Flux currently owns a resource. The first migration
PR changes repository validation only and does not apply anything to the
cluster.

## Classification

- `flux-candidate`: declarative input that can move behind a Flux
  `Kustomization` after a render and live-state comparison.
- `migration-pending`: desired configuration whose owner, privilege, or
  HelmRelease conversion still needs an explicit review.
- `excluded`: diagnostics or test resources that must not enter a production
  reconciliation path.
- `generated`: child resources produced by a controller. Git owns the
  controller configuration or custom resource, not the generated child.

PVCs, PVs, namespaces, CRDs, and privileged bindings require an initial
`prune: false` migration and an explicit deletion-safety review.

## Repository declarations

| Path | Classification | Notes |
| --- | --- | --- |
| `apps/dashboard/dashboard-ingress.yaml`, `dashboard-user-root.yaml`, `kustomization.yaml` | flux-candidate | Dashboard routing and ServiceAccount. |
| `apps/dashboard/crb-user-root.yaml` | migration-pending | Grants `cluster-admin`; replace with least privilege before reconciliation. |
| `apps/dashboard/helmfile.yaml` | migration-pending | The archived Dashboard is pinned to 7.13.0 from its retired repository. Evaluate Headlamp or another maintained UI before HelmRelease conversion. |
| `apps/immich/*.yaml` | flux-candidate | Excludes the removed `.env` and inspector Pod. The machine-learning `release` tag remains a documented policy exception until image parity is verified. |
| `apps/jellyfin/jellyfin-pvc.yaml`, `kustomization.yaml` | flux-candidate | PVC needs deletion protection. |
| `apps/jellyfin/helmfile.yaml` | migration-pending | Convert after comparing rendered and live resources. |
| `apps/memos/chart/**`, `apps/memos/helmfile.yaml` | migration-pending | Local chart is linted and rendered in CI; convert to a Flux HelmRelease. |
| `apps/metube/*.yaml`, `apps/mortis/*.yaml` | flux-candidate | Raw workload packages. |
| `apps/n8n/test-pvc.yaml`, `kustomization.yaml` | flux-candidate | Despite the filename, these are the three live n8n PVCs referenced by the Helm release. |
| `apps/n8n/helmfile.yaml` | migration-pending | Convert the release and its ExternalSecret extra object together. |
| `apps/nextcloud/helmfile.yaml` | migration-pending | PR #36 contains the fuller desired configuration; reconcile ownership before conversion. |
| `apps/portainer/portainer-pvc.yaml`, `kustomization.yaml` | flux-candidate | PVC needs deletion protection. |
| `apps/portainer/helmfile.yaml` | migration-pending | Convert after render comparison. |
| `apps/wordpress/external-secret.yaml`, `wordpress-deployment.yaml`, `wordpress-pvc.yaml`, `kustomization.yaml` | flux-candidate | WordPress workload inputs; the package intentionally excludes MySQL for now. |
| `apps/wordpress/mysql-deployment.yaml` | migration-pending | The tracked root password was removed. Its provisional ExternalSecret reference must not be reconciled until credentials are rotated and verified. |
| `middlewares/cert-manager/helmfile.yaml` | migration-pending | Convert the controller release before dependent resources. |
| `middlewares/couchdb/*.yaml` | flux-candidate | Workload, PVC, ConfigMap, ExternalSecret, and package Kustomization. |
| `middlewares/external-secrets-operator/gcp-provider.yaml`, `kustomization.yaml` | flux-candidate | Existing secret-store configuration. |
| `middlewares/external-secrets-operator/helmfile.yaml` | migration-pending | Installs Secrets Store CSI Driver despite the directory name; rename during conversion. |
| `middlewares/grafana/grafana-external-secrets.yaml`, `kustomization.yaml` | flux-candidate | Secret material remains external. |
| `middlewares/grafana/helmfile.yaml` | migration-pending | Convert after render comparison. |
| `middlewares/metallb-native/*.yaml` | flux-candidate | Vendored controller bundle plus address configuration. |
| `middlewares/metrics-server/*.yaml` | flux-candidate | Vendored controller bundle and package Kustomization. |
| `middlewares/nfs-subdir-external-provisioner/helmfile.yaml` | migration-pending | Storage controller migration needs PVC/PV safety review. |
| `middlewares/pg-operator/**` | flux-candidate | Operator and Barman plugin inputs; their generated resources are not direct Git inputs. |
| `middlewares/pg/*.yaml` | flux-candidate | CloudNativePG custom resources and ExternalSecrets. The former inline app-user Secret was replaced with the matching live ExternalSecret spec (`Ready=True`, `SecretSynced` on 2026-09-05). |
| `middlewares/redis/helmfile.yaml` | migration-pending | Convert after render comparison. The former empty YAML placeholder was removed. |
| `pv/pv-md0.yaml`, `pv/kustomization.yaml` | flux-candidate | Static PV; require deletion protection and `prune: false` initially. |
| `pv/storageTest.yaml` | excluded | Test Pod; it is not live. |
| `pv/test-pvc.yaml` | excluded | Test PVC is still Bound, so cleanup is a separate storage decision. |

Every raw `flux-candidate` package has a `kustomization.yaml`. Helm chart
templates are validated only after `helm template`; they are not parsed as raw
Kubernetes YAML.

These Kustomizations are CI render packages, not the final Flux reconciliation
boundaries. Later migration PRs must separate controllers and CRDs from their
dependent custom resources, then express ordering with `dependsOn` and health
checks. The Dashboard cluster-admin binding is intentionally absent from its
package.

## Live-only desired workloads

The 2026-09-05 live inventory also contains resources with no declaration in
this repository: Audiobookshelf, Cronus, Glance, Honcho, Kubero, and Percona
MongoDB workloads. Locate their owning repository first. If none exists,
reconstruct only desired configuration, excluding Secret values, status,
generated fields, and controller-owned children.

## Generated resources

Do not copy these live objects back into Git:

- Helm-generated Deployments, Services, release Secrets, and similar children;
- Secrets generated by External Secrets or cert-manager;
- Pods, Services, and certificates generated by CloudNativePG;
- child resources generated by MetalLB, Kubero, Percona, and other operators.

## Removed from the current tree

The migration baseline removes the unused Argo CD bundle and tracked local
credential artifacts. Git history still contains earlier values, so credential
rotation and any history rewrite are separate security operations.
