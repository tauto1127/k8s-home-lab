#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_root="$(mktemp -d)"

cleanup() {
  rm -rf "${render_root}"
}
trap cleanup EXIT

cd "${repo_root}"
mkdir -p "${render_root}/kustomize" "${render_root}/helmfile"

ruby scripts/validate-manifest-policy.rb

while IFS= read -r kustomization; do
  package_dir="$(dirname "${kustomization}")"
  output_name="${package_dir//\//_}.yaml"
  kubectl kustomize "${package_dir}" > "${render_root}/kustomize/${output_name}"
done < <(find apps middlewares pv -name kustomization.yaml -type f | sort)

helm lint apps/memos/chart

while IFS= read -r helmfile_path; do
  output_name="${helmfile_path//\//_}"
  helmfile --file "${helmfile_path}" lint
  helmfile --file "${helmfile_path}" template > "${render_root}/helmfile/${output_name}"
done < <(find apps middlewares -name helmfile.yaml -type f | sort)

# CRD-specific schemas are checked later with server-side dry-run.
find "${render_root}" -name '*.yaml' -type f -print0 \
  | xargs -0 kubeconform \
      -strict \
      -summary \
      -ignore-missing-schemas \
      -kubernetes-version 1.36.0

ruby scripts/validate-rendered-policy.rb "${render_root}"

gitleaks dir --redact=100 --no-banner --no-color "${repo_root}"
