#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_root="$(mktemp -d)"
sanitized_root="$(mktemp -d)"

cleanup() {
  rm -rf "${render_root}"
  rm -rf "${sanitized_root}"
}
trap cleanup EXIT

cd "${repo_root}"
mkdir -p "${render_root}/kustomize" "${render_root}/helmfile"
: > "${render_root}/source-map.tsv"

ruby scripts/validate-manifest-policy.rb

kustomizations=()
while IFS= read -r kustomization; do
  kustomizations+=("${kustomization}")
done < <(ruby scripts/discover-kustomization-roots.rb)
if ((${#kustomizations[@]} == 0)); then
  echo "No Kustomization roots found" >&2
  exit 1
fi

for kustomization in "${kustomizations[@]}"; do
  package_dir="$(dirname "${kustomization}")"
  output_name="${package_dir//\//_}.yaml"
  kubectl kustomize "${package_dir}" > "${render_root}/kustomize/${output_name}"
  printf 'kustomize/%s\t%s\n' "${output_name}" "${kustomization}" >> "${render_root}/source-map.tsv"
done

helm lint apps/memos/chart

while IFS= read -r helmfile_path; do
  output_name="${helmfile_path//\//_}"
  helmfile --file "${helmfile_path}" lint
  helmfile --file "${helmfile_path}" template > "${render_root}/helmfile/${output_name}"
  printf 'helmfile/%s\t%s\n' "${output_name}" "${helmfile_path}" >> "${render_root}/source-map.tsv"
done < <(find . -name helmfile.yaml -type f -not -path './.git/*' | sort | sed 's#^\./##')

rendered_files=()
while IFS= read -r -d '' rendered_file; do
  rendered_files+=("${rendered_file}")
done < <(find "${render_root}" -name '*.yaml' -type f -print0)
if ((${#rendered_files[@]} == 0)); then
  echo "No rendered manifests found" >&2
  exit 1
fi

kubeconform \
  -strict \
  -summary \
  -verbose \
  -output json \
  -ignore-missing-schemas \
  -kubernetes-version 1.36.0 \
  "${rendered_files[@]}" > "${render_root}/kubeconform.json"

ruby scripts/validate-kubeconform-policy.rb "${render_root}/kubeconform.json"

ruby scripts/validate-rendered-policy.rb "${render_root}" "${render_root}/source-map.tsv" "${sanitized_root}"

gitleaks dir --redact=100 --no-banner --no-color "${repo_root}"
gitleaks dir --redact=100 --no-banner --no-color "${sanitized_root}"
