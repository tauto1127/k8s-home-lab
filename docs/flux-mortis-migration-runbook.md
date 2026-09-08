# Flux Mortis migration runbook

## Scope

This runbook covers the Mortis preparation and later activation as separate PRs.
Cronus, Portainer, Nextcloud, Argo CD resources, test resources, and generated
child resources are out of scope.

## Preparation PR

The preparation package is:

- `clusters/home/packages/mortis/`
- Flux `Kustomization` `flux-system/mortis`
- `spec.path: ./clusters/home/packages/mortis`
- `spec.suspend: true`
- `spec.prune: false`
- `spec.wait: true`

The package declares only the existing Mortis Namespace, Service, and Deployment.
It does not declare Memos or any Secret, PVC, PV, operator child, or generated
resource. The Deployment references the existing `memos.memos.svc.cluster.local`
Service but does not take ownership of it.

Preparation validation must confirm:

- rendered package identity is exactly `v1/Namespace//mortis`,
  `v1/Service/mortis/mortis`, and `apps/v1/Deployment/mortis/mortis`;
- image is `ghcr.io/mudkipme/mortis:0.29.0`;
- Service is a `LoadBalancer` on port `5231` with MetalLB address
  `192.168.11.212`;
- Deployment probes, arguments, requests, limits, and selector match live;
- no PVC/PV, Secret, Ingress, Cronus, or Portainer resource is rendered;
- no direct cluster write is performed.

## Activation PR

Do not activate from the preparation PR. After the preparation PR is merged and
Flux has created the suspended Kustomization, a separate activation PR may change
only `flux-system/mortis` from `suspend: true` to `suspend: false`. Keep
`prune: false`. Do not use `flux resume`, `flux reconcile`, `kubectl apply`, or
manual rollout commands.

Before activation, verify that the live Mortis resources still match the package
and that no other Kustomization owns the same identities. After the PR is merged,
verify Flux readiness and Mortis readiness without changing any other workload.

## Rollback

Suspend `flux-system/mortis` through a reviewed Git PR. Do not delete the
Namespace, Service, or Deployment as part of rollback. PVC/PV and external data
are not part of this package.
