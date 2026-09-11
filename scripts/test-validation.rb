#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "base64"
require "digest"
require "json"
require "open3"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "yaml"
require "zlib"

def build_fixture_schema_archive
  buffer = StringIO.new("".b)
  gzip = Zlib::GzipWriter.new(buffer)
  # Ruby 2.6 rewrites gzip mtime=0 to the current time; 1 is stable across processes.
  gzip.mtime = 1
  Gem::Package::TarWriter.new(gzip) do |archive|
    content = "{}\n"
    archive.add_file_simple("gitrepository-source-v1.json", 0o644, content.bytesize) do |entry|
      entry.write(content)
    end
  end
  gzip.close
  buffer.string
end

def test_cumulative_activation_validation
  source = File.read(File.join(ROOT, "scripts/validate-flux-ownership.rb"))
  eval(source.split(/^policy_path =/).first, TOPLEVEL_BINDING, "validate-flux-ownership.rb", 1)
  policy = YAML.safe_load(File.read(File.join(ROOT, ".github/manifest-policy.yaml")))
  activation = Marshal.load(Marshal.dump(policy.fetch("fluxActivation")))
  failures = []
  validate_activation_phase_contract!(activation, failures)
  assert(failures.empty?, "cumulative ESO phase contract rejected the repository policy: #{failures.join('; ')}")

  previous_activation = {
    "phase" => "eso-controller",
    "reason" => "previous controller-only activation phase",
    "activeKustomizations" => Marshal.load(Marshal.dump(ESO_CONTROLLER_ACTIVATION_CONTRACT.fetch("activeKustomizations"))),
    "activeHelmReleases" => Marshal.load(Marshal.dump(ESO_CONTROLLER_ACTIVATION_CONTRACT.fetch("activeHelmReleases")))
  }
  failures = []
  validate_activation_phase_contract!(previous_activation, failures)
  assert(failures.empty?, "previous eso-controller phase contract was rejected: #{failures.join('; ')}")

  previous_config_activation = {
    "phase" => "eso-config",
    "reason" => "previous controller and config activation phase",
    "activeKustomizations" => Marshal.load(Marshal.dump(ESO_CONFIG_ACTIVATION_CONTRACT.fetch("activeKustomizations"))),
    "activeHelmReleases" => Marshal.load(Marshal.dump(ESO_CONFIG_ACTIVATION_CONTRACT.fetch("activeHelmReleases")))
  }
  failures = []
  validate_activation_phase_contract!(previous_config_activation, failures)
  assert(failures.empty?, "previous eso-config phase contract was rejected: #{failures.join('; ')}")
  assert(eso_config_active_phase?("eso-config"), "eso-config phase lost its cumulative ESO config contract")
  assert(eso_config_active_phase?("csi-secrets-store"), "CSI phase lost its cumulative ESO config contract")
  assert(!eso_config_active_phase?("eso-controller"), "ESO controller phase incorrectly gained ESO config resources")
  assert(active_cluster_secret_store_policies_for_phase("eso-config").key?(ESO_CONFIG_STORE_IDENTITY), "eso-config phase lost ClusterSecretStore policy")
  assert(active_cluster_secret_store_policies_for_phase("csi-secrets-store").key?(ESO_CONFIG_STORE_IDENTITY), "CSI phase lost ClusterSecretStore policy")
  assert(active_cluster_secret_store_policies_for_phase("eso-controller").empty?, "ESO controller phase incorrectly gained ClusterSecretStore policy")

  csi_kustomization = CSI_SECRETS_STORE_ACTIVATION_CONTRACT.fetch("activeKustomizations").find { |entry| entry["name"] == "csi-secrets-store" }
  csi_release = CSI_SECRETS_STORE_ACTIVATION_CONTRACT.fetch("activeHelmReleases").find { |entry| entry["name"] == "csi-secrets-store" }
  assert(csi_kustomization.fetch("inventory").map { |entry| entry["name"] } == ["secrets-store-csi-driver", "csi-secrets-store"], "CSI inventory must contain repository and HelmRelease")
  assert(csi_release.dig("chart", "name") == "secrets-store-csi-driver", "CSI chart name drifted")
  assert(csi_release.dig("chart", "version") == "1.4.8", "CSI chart version drifted")
  assert(csi_release.dig("chart", "artifact", "url") == "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.4.8.tgz", "CSI artifact URL drifted")
  assert(csi_release.dig("chart", "artifact", "sha256") == "894ee5351f615184af4ad0f4ea03be35485e65bc1797c10e315fcd1bcc3aef13", "CSI artifact digest drifted")
  assert(csi_release.dig("chart", "artifact", "crdInventory", "count") == 2, "CSI CRD inventory count drifted")
  assert(csi_release.dig("chart", "artifact", "crdInventory", "setSha256") == "43551fdd7c965bd461dc91d6c08448e0d501e1abd378b2bfb09c24170f79f258", "CSI CRD set digest drifted")
  assert(csi_release.dig("chart", "artifact", "resourceInventory").length == 10, "CSI stable inventory count drifted")
  assert(csi_release.dig("safety", "disableHooks") == true, "CSI hook safety gate drifted")
  assert(csi_release.dig("safety", "linuxCRDsEnabled") == false, "CSI CRD value safety gate drifted")

  store = {"spec" => Marshal.load(Marshal.dump(ESO_CONFIG_STORE_SPEC))}
  store_failures = []
  validate_active_cluster_secret_store!(store, ESO_CONFIG_STORE_IDENTITY, {"spec" => ESO_CONFIG_STORE_SPEC}, store_failures)
  assert(store_failures.empty?, "reviewed ClusterSecretStore spec was rejected")

  mutated_store = Marshal.load(Marshal.dump(store))
  mutated_store["spec"]["provider"]["gcpsm"]["projectID"] = "123"
  store_failures = []
  validate_active_cluster_secret_store!(mutated_store, ESO_CONFIG_STORE_IDENTITY, {"spec" => ESO_CONFIG_STORE_SPEC}, store_failures)
  assert(store_failures.any? { |failure| failure.include?("spec must exactly match") }, "projectID drift was accepted")

  mutated_store = Marshal.load(Marshal.dump(store))
  mutated_store["spec"]["provider"]["gcpsm"]["auth"]["secretRef"]["secretAccessKeySecretRef"]["key"] = "wrong"
  store_failures = []
  validate_active_cluster_secret_store!(mutated_store, ESO_CONFIG_STORE_IDENTITY, {"spec" => ESO_CONFIG_STORE_SPEC}, store_failures)
  assert(store_failures.any? { |failure| failure.include?("spec must exactly match") }, "credential key drift was accepted")
  csi_store_failures = []
  validate_active_cluster_secret_store!(mutated_store, ESO_CONFIG_STORE_IDENTITY, active_cluster_secret_store_policies_for_phase("csi-secrets-store").fetch(ESO_CONFIG_STORE_IDENTITY), csi_store_failures)
  assert(csi_store_failures.any? { |failure| failure.include?("spec must exactly match") }, "CSI phase accepted ClusterSecretStore spec drift")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeKustomizations").find { |entry| entry["name"] == "eso-config" }["inventory"].clear
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeKustomizations contract") }, "ESO inventory drift was accepted")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeKustomizations").find { |entry| entry["name"] == "eso-config" }["path"] = "./clusters/other"
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeKustomizations contract") }, "ESO path drift was accepted")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation["phase"] = "eso-controller"
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("ESO config identities must use fluxActivation phase eso-config") }, "ESO config phase bypass was accepted")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeKustomizations").find { |entry| entry["name"] == "csi-secrets-store" }["inventory"].pop
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeKustomizations contract") }, "CSI inventory drift was accepted")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeHelmReleases").find { |entry| entry["name"] == "csi-secrets-store" }.fetch("chart").fetch("artifact")["sha256"] = "0" * 64
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeHelmReleases contract") }, "CSI artifact drift was accepted")

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeHelmReleases").find { |entry| entry["name"] == "csi-secrets-store" }.fetch("chart").fetch("artifact").fetch("crdInventory")["setSha256"] = "0" * 64
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeHelmReleases contract") }, "CSI CRD set checksum drift was accepted")

  fixture_files = safe_archive_files(FIXTURE_CHART_ASSET, "fixture chart")
  fixture_crd_paths = fixture_files.keys.select { |path| path.start_with?("external-secrets/templates/crds/") }
  mutated_fixture_files = fixture_files.merge(fixture_crd_paths.fetch(0) => fixture_files.fetch(fixture_crd_paths.fetch(0)) + "mutation")
  assert(
    archive_file_set_sha256(mutated_fixture_files, fixture_crd_paths) != FIXTURE_CHART_CRD_SET_SHA,
    "CSI-style CRD inventory checksum accepted mutated CRD bytes"
  )

  mutated_activation = Marshal.load(Marshal.dump(activation))
  mutated_activation.fetch("activeHelmReleases").find { |entry| entry["name"] == "csi-secrets-store" }.fetch("safety")["disableHooks"] = false
  failures = []
  validate_activation_phase_contract!(mutated_activation, failures)
  assert(failures.any? { |failure| failure.include?("activeHelmReleases contract") }, "CSI hook safety drift was accepted")

  config_failures = []
  validate_eso_config_kustomization!({"spec" => {"wait" => true, "dependsOn" => [{"name" => "eso-controller"}]}}, config_failures)
  assert(config_failures.empty?, "reviewed ESO dependency contract was rejected")
  config_failures = []
  validate_eso_config_kustomization!({"spec" => {"wait" => false, "dependsOn" => [{"name" => "other"}]}}, config_failures)
  assert(config_failures.any? { |failure| failure.include?("wait must be true") }, "wait:false was accepted")
  assert(config_failures.any? { |failure| failure.include?("dependsOn must exactly") }, "dependency drift was accepted")
  csi_config_failures = []
  validate_eso_config_kustomization_for_phase!("csi-secrets-store", "eso-config", "flux-system", {"spec" => {"wait" => false, "dependsOn" => [{"name" => "other"}]}}, csi_config_failures)
  assert(csi_config_failures.any? { |failure| failure.include?("wait must be true") }, "CSI phase accepted eso-config wait:false")
  assert(csi_config_failures.any? { |failure| failure.include?("dependsOn must exactly") }, "CSI phase accepted eso-config dependency drift")
  controller_config_failures = []
  validate_eso_config_kustomization_for_phase!("eso-controller", "eso-config", "flux-system", {"spec" => {"wait" => false, "dependsOn" => [{"name" => "other"}]}}, controller_config_failures)
  assert(controller_config_failures.empty?, "ESO controller phase incorrectly validated ESO config")

  csi_failures = []
  validate_csi_secrets_store_kustomization!({"spec" => {"wait" => true, "dependsOn" => [{"name" => "eso-config"}]}}, csi_failures)
  assert(csi_failures.empty?, "reviewed CSI dependency contract was rejected")
  csi_failures = []
  validate_csi_secrets_store_kustomization!({"spec" => {"wait" => true, "dependsOn" => [{"name" => "eso-controller"}]}}, csi_failures)
  assert(csi_failures.any? { |failure| failure.include?("dependsOn must exactly") }, "CSI dependency bypass was accepted")
end

def build_fixture_chart_archive
  previous_source_date_epoch = ENV["SOURCE_DATE_EPOCH"]
  ENV["SOURCE_DATE_EPOCH"] = "0"
  buffer = StringIO.new("".b)
  gzip = Zlib::GzipWriter.new(buffer)
  # Ruby 2.6 rewrites gzip mtime=0 to the current time; 1 is stable across processes.
  gzip.mtime = 1
  Gem::Package::TarWriter.new(gzip) do |archive|
    content = "apiVersion: example.invalid/v1\nkind: FixtureCRD\n"
    path = "external-secrets/templates/crds/fixture.yaml"
    archive.add_file_simple(path, 0o644, content.bytesize) { |entry| entry.write(content) }
  end
  gzip.close
  buffer.string
ensure
  if previous_source_date_epoch
    ENV["SOURCE_DATE_EPOCH"] = previous_source_date_epoch
  else
    ENV.delete("SOURCE_DATE_EPOCH")
  end
end

def fixture_chart_crd_set_sha256(bytes)
  files = {}
  gzip = Zlib::GzipReader.new(StringIO.new(bytes))
  Gem::Package::TarReader.new(gzip) do |archive|
    archive.each { |entry| files[entry.full_name] = entry.read.b if entry.file? }
  end
  digest = Digest::SHA256.new
  files.keys.sort.each do |path|
    digest.update(path)
    digest.update("\0")
    digest.update(files.fetch(path))
    digest.update("\0")
  end
  digest.hexdigest
ensure
  gzip&.close
end

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(__dir__, "fixtures")
FAKE_KUBECTL_DIR = Dir.mktmpdir("flux-ownership-kubectl")
FAKE_KUBECTL = File.join(FAKE_KUBECTL_DIR, "kubectl")
FAKE_CURL = File.join(FAKE_KUBECTL_DIR, "curl")
FAKE_FLUX = File.join(FAKE_KUBECTL_DIR, "flux")
FAKE_HELM = File.join(FAKE_KUBECTL_DIR, "helm")
FIXTURE_INSTALL_ASSET = "fixture Flux install asset v2.9.3\n"
FIXTURE_SCHEMA_ASSET = build_fixture_schema_archive
FIXTURE_CHART_ASSET = build_fixture_chart_archive
FIXTURE_CHART_CRD_SET_SHA = fixture_chart_crd_set_sha256(FIXTURE_CHART_ASSET)
File.write(FAKE_KUBECTL, <<~'SH')
  #!/usr/bin/env bash
  set -euo pipefail
  test "${1:-}" = kustomize
  package_dir="$2"
  if test -f "$package_dir/render-mode"; then
    mode="$(cat "$package_dir/render-mode")"
    if test "$mode" = nonzero; then exit 42; fi
    if test "$mode" = empty; then exit 0; fi
  fi
  if test -f "$package_dir/rendered.out"; then
    cat "$package_dir/rendered.out"
  elif test -f "$package_dir/rendered.yaml"; then
    cat "$package_dir/rendered.yaml"
  else
    first=1
    while IFS= read -r -d '' file; do
      if test "$first" -eq 0; then printf '%s\n' '---'; fi
      cat "$file"
      first=0
    done < <(find "$package_dir" -maxdepth 1 -type f -name '*.yaml' ! -name 'kustomization.yaml' -print0 | sort -z)
  fi
SH
FileUtils.chmod(0o755, FAKE_KUBECTL)
fake_curl_script = <<~'SH'
  #!/usr/bin/env bash
  set -euo pipefail
  url="${!#}"
  case "$url" in
    https://github.com/fluxcd/flux2/releases/download/v2.9.3/install.yaml)
      printf '%s\n' 'fixture Flux install asset v2.9.3'
      ;;
    https://github.com/fluxcd/flux2/releases/download/v2.9.3/crd-schemas.tar.gz)
      ruby -rbase64 -e 'STDOUT.binmode; STDOUT.write(Base64.strict_decode64(ARGV.fetch(0)))' '__FIXTURE_SCHEMA_ARCHIVE__'
      ;;
    https://github.com/external-secrets/external-secrets/releases/download/helm-chart-0.14.4/external-secrets-0.14.4.tgz)
      ruby -rbase64 -e 'STDOUT.binmode; STDOUT.write(Base64.strict_decode64(ARGV.fetch(0)))' '__FIXTURE_CHART_ARCHIVE__'
      ;;
    https://fixture.invalid/external-secrets-0.14.4.tgz)
      ruby -rbase64 -e 'STDOUT.binmode; STDOUT.write(Base64.strict_decode64(ARGV.fetch(0)))' '__FIXTURE_CHART_ARCHIVE__'
      ;;
    *)
      exit 22
      ;;
  esac
SH
fake_curl_script = fake_curl_script.sub("__FIXTURE_SCHEMA_ARCHIVE__", Base64.strict_encode64(FIXTURE_SCHEMA_ASSET))
fake_curl_script = fake_curl_script.gsub("__FIXTURE_CHART_ARCHIVE__", Base64.strict_encode64(FIXTURE_CHART_ASSET))
File.write(FAKE_CURL, fake_curl_script)
FileUtils.chmod(0o755, FAKE_CURL)
File.write(FAKE_FLUX, <<~'SH')
  #!/usr/bin/env bash
  set -euo pipefail
  test "$*" = 'install --version=v2.9.3 --components=source-controller,kustomize-controller,helm-controller,notification-controller --namespace=flux-system --export'
  cat .flux-test/generated-components.yaml
SH
FileUtils.chmod(0o755, FAKE_FLUX)
File.write(FAKE_HELM, <<~'SH')
  #!/usr/bin/env bash
  set -euo pipefail
  test "${1:-}" = template
  test -n "${2:-}"
  test -n "${3:-}" && test -f "$3"
  test "${4:-}" = --namespace
  test -n "${5:-}"
  test "${6:-}" = --include-crds
  test "${7:-}" = --no-hooks
  test "${8:-}" = --set
  test "${9:-}" = linux.crds.enabled=false
  test "$#" -eq 9
  case "${FAKE_HELM_MODE:-ok}" in
    nonzero) exit 42 ;;
    empty) exit 0 ;;
    duplicate)
      cat <<'YAML'
  apiVersion: example.invalid/v1
  kind: FixtureCRD
  metadata:
    name: fixture-crd
  ---
  apiVersion: example.invalid/v1
  kind: FixtureCRD
  metadata:
    name: fixture-crd
  YAML
      ;;
    drift)
      cat <<'YAML'
  apiVersion: example.invalid/v1
  kind: FixtureCRD
  metadata:
    name: drifted
  YAML
      ;;
    *)
      cat <<'YAML'
  apiVersion: example.invalid/v1
  kind: FixtureCRD
  metadata:
    name: fixture-crd
  YAML
      ;;
  esac
SH
FileUtils.chmod(0o755, FAKE_HELM)

def run_command(*command, env: {})
  validator = command.any? { |part| part.to_s.end_with?("validate-flux-ownership.rb") }
  inherited = validator ? {
    "FLUX_OWNERSHIP_KUBECTL" => FAKE_KUBECTL,
    "FLUX_OWNERSHIP_CURL" => FAKE_CURL,
    "FLUX_OWNERSHIP_FLUX" => FAKE_FLUX,
    "FLUX_OWNERSHIP_HELM" => FAKE_HELM
  } : {}
  Open3.capture3(inherited.merge(env), *command, chdir: ROOT)
end

def run_in_directory(directory, *command, env: {})
  Open3.capture3(env, *command, chdir: directory)
end

def assert(condition, message)
  raise message unless condition
end

def assert_success(*command, env: {})
  stdout, stderr, status = run_command(*command, env: env)
  assert(status.success?, "expected success: #{command.join(' ')}\n#{stdout}\n#{stderr}")
  [stdout, stderr]
end

def assert_failure(*command, env: {})
  stdout, stderr, status = run_command(*command, env: env)
  assert(!status.success?, "expected failure: #{command.join(' ')}\n#{stdout}\n#{stderr}")
  [stdout, stderr]
end

def write_flux_bootstrap_fixture(temporary_root, source_url: "https://github.com/tauto1127/k8s-home-lab", branch: "main", root_path: "./clusters/home", root_suspend: nil)
  flux_system = File.join(temporary_root, "clusters/home/flux-system")
  package = File.join(temporary_root, "clusters/home/packages/app")
  FileUtils.mkdir_p(flux_system)
  FileUtils.mkdir_p(package)
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  FileUtils.mkdir_p(File.join(temporary_root, ".flux-test"))
  schema_directory = File.join(temporary_root, ".github/schemas/flux/v2.9.3/v1.36.0-standalone-strict")
  FileUtils.mkdir_p(schema_directory)
  schema_content = "{}\n"
  File.write(File.join(schema_directory, "gitrepository-source-v1.json"), schema_content)
  schema_sha = Digest::SHA256.hexdigest(schema_content)

  components = <<~YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: flux-system
    ---
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: gitrepositories.source.toolkit.fluxcd.io
    spec: {}
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: source-controller-flux-system
    rules: []
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: source-controller-flux-system
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: source-controller-flux-system
    subjects: []
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: source-controller
      namespace: flux-system
    spec:
      selector:
        matchLabels:
          app: source-controller
      template:
        metadata:
          labels:
            app: source-controller
        spec:
          containers:
            - name: manager
              image: ghcr.io/fluxcd/source-controller:v1.9.3
  YAML
  components_path = File.join(flux_system, "gotk-components.yaml")
  File.write(components_path, components)
  File.write(File.join(temporary_root, ".flux-test/generated-components.yaml"), components)
  components_sha = Digest::SHA256.hexdigest(components)

  root_suspend_line = root_suspend.nil? ? "" : "  suspend: #{root_suspend}\n"
  git_repository = <<~YAML
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: GitRepository
    metadata:
      name: flux-system
      namespace: flux-system
    spec:
      interval: 1m0s
      ref:
        branch: #{branch}
      url: #{source_url}
  YAML
  root_kustomization = <<~YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: flux-system
      namespace: flux-system
    spec:
      interval: 10m0s
      path: #{root_path}
      prune: false
    #{root_suspend_line}  sourceRef:
        kind: GitRepository
        name: flux-system
  YAML
  File.write(File.join(flux_system, "gotk-sync.yaml"), "#{git_repository}---\n#{root_kustomization}")
  File.write(File.join(flux_system, "sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: app
      namespace: flux-system
    spec:
      interval: 30m
      path: ./clusters/home/packages/app
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
  YAML
  File.write(File.join(flux_system, "kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - gotk-components.yaml
      - gotk-sync.yaml
      - sync.yaml
  YAML
  File.write(File.join(temporary_root, "clusters/home/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - flux-system
  YAML
  File.write(File.join(package, "kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - resource.yaml
  YAML
  File.write(File.join(package, "resource.yaml"), <<~YAML)
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: app
      namespace: default
  YAML

  # The unit-test renderer emits the root composition without recursively parsing
  # Kustomize. Production validation still uses the real pinned kubectl binary.
  File.write(
    File.join(temporary_root, "clusters/home/rendered.out"),
    "#{components}---\n#{git_repository}---\n#{root_kustomization}---\n#{File.read(File.join(flux_system, "sync.yaml"))}"
  )

  File.write(File.join(temporary_root, ".github/manifest-policy.yaml"), <<~YAML)
    bootstrapManagedSources: []
    fluxBootstrap:
      version: v2.9.3
      releaseUrl: https://github.com/fluxcd/flux2/releases/tag/v2.9.3
      components:
        path: clusters/home/flux-system/gotk-components.yaml
        sourceUrl: https://github.com/fluxcd/flux2/releases/download/v2.9.3/install.yaml
        sourceSha256: #{Digest::SHA256.hexdigest(FIXTURE_INSTALL_ASSET)}
        sha256: #{components_sha}
        controllers:
          - name: source-controller
            image: ghcr.io/fluxcd/source-controller:v1.9.3
        requiredCRDs:
          - gitrepositories.source.toolkit.fluxcd.io
        requiredClusterRoles:
          - source-controller-flux-system
        requiredClusterRoleBindings:
          - source-controller-flux-system
      schemas:
        sourceUrl: https://github.com/fluxcd/flux2/releases/download/v2.9.3/crd-schemas.tar.gz
        sourceSha256: #{Digest::SHA256.hexdigest(FIXTURE_SCHEMA_ASSET)}
        directory: .github/schemas/flux/v2.9.3/v1.36.0-standalone-strict
        files:
          - path: gitrepository-source-v1.json
            sha256: #{schema_sha}
      source:
        apiVersion: source.toolkit.fluxcd.io/v1
        kind: GitRepository
        namespace: flux-system
        name: flux-system
        url: https://github.com/tauto1127/k8s-home-lab
        branch: main
      root:
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        namespace: flux-system
        name: flux-system
        path: ./clusters/home
        prune: false
  YAML
end

require_relative "manifest-policy-helpers"

include ManifestPolicyHelpers

assert(sensitive_environment_name?("AWS_SECRET_ACCESS_KEY"), "AWS secret key was not classified")
assert(sensitive_environment_name?("CLIENT_SECRET"), "client secret was not classified")
assert(sensitive_environment_name?("SECRET_KEY_BASE"), "secret key base was not classified")
assert(sensitive_environment_name?("DATABASE_URL"), "database URL was not classified")
assert(!sensitive_environment_name?("ALLOW_EMPTY_PASSWORD"), "non-secret password flag was classified")
assert(!sensitive_environment_name?("CLUSTER_NAME"), "non-sensitive env name was classified")

sanitized_annotations = {
  "annotations" => {
    "checksum/secret" => "SECRET_CHECKSUM",
    "checksum-secrets" => "SECRET_CHECKSUMS",
    "checksum/configmap" => "CONFIGMAP_CHECKSUM"
  }
}
redact_secret_checksums!(sanitized_annotations)
assert(sanitized_annotations["annotations"]["checksum/secret"] == "REDACTED", "Secret checksum annotation was not redacted")
assert(sanitized_annotations["annotations"]["checksum-secrets"] == "REDACTED", "plural Secret checksum annotation was not redacted")
assert(sanitized_annotations["annotations"]["checksum/configmap"] == "CONFIGMAP_CHECKSUM", "non-Secret checksum annotation was redacted")

literal_names = []
each_sensitive_environment_literal(
  "extraEnv" => {
    "CLIENT_SECRET" => "REDACTED",
    "AWS_SECRET_ACCESS_KEY" => {"valueFrom" => {"secretKeyRef" => {"name" => "secret", "key" => "value"}}}
  }
) { |name, _value| literal_names << name }
assert(literal_names == ["CLIENT_SECRET"], "extraEnv map/list handling is incorrect")

assert(
  package_kustomization?("kustomization.yaml", "apiVersion" => "kustomize.config.k8s.io/v1beta1", "kind" => "Kustomization"),
  "package Kustomization was not recognized"
)
assert(
  !package_kustomization?("flux.yaml", "apiVersion" => "kustomize.toolkit.fluxcd.io/v1", "kind" => "Kustomization"),
  "Flux Kustomization was incorrectly exempted"
)

Dir.mktmpdir("source-policy-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "scripts"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  FileUtils.mkdir_p(File.join(temporary_root, "apps/test"))
  %w[manifest-policy-helpers.rb validate-manifest-policy.rb].each do |script|
    FileUtils.cp(File.join(__dir__, script), File.join(temporary_root, "scripts", script))
  end
  File.write(
    File.join(temporary_root, ".github/manifest-policy.yaml"),
    <<~YAML
      clusterAdminBindings:
        - path: apps/test/bad.yaml
          name: nested-admin
          sha256: #{"0" * 64}
          reason: Fixture-only stale binding hash.
    YAML
  )
  File.write(
    File.join(temporary_root, "apps/test/kustomization.yaml"),
    <<~YAML
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      resources:
        - bad.yaml
        - linked.yaml
        - ../../../outside.yaml
        - https://example.invalid/unpinned.yaml
    YAML
  )
  File.write(
    File.join(temporary_root, "apps/test/bad.yaml"),
    <<~YAML
      apiVersion: v1
      kind: List
      items:
        - apiVersion: v1
          kind: Secret
          metadata:
            name: nested-secret
          stringData:
            password: FIXTURE_SOURCE_SECRET_VALUE
        - apiVersion: rbac.authorization.k8s.io/v1
          kind: RoleBinding
          metadata:
            name: nested-admin
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: cluster-admin
          subjects: []
        - apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: sensitive-env
          spec:
            selector:
              matchLabels:
                app: sensitive-env
            template:
              metadata:
                labels:
                  app: sensitive-env
              spec:
                containers:
                  - name: app
                    image: example.invalid/app@sha256:#{"0" * 64}
                    env:
                      - name: AWS_SECRET_ACCESS_KEY
                        value: FIXTURE_SOURCE_ENV_VALUE
    YAML
  )
  File.symlink("bad.yaml", File.join(temporary_root, "apps/test/linked.yaml"))
  _stdout, stderr, status = run_in_directory(temporary_root, "git", "init", "--quiet")
  assert(status.success?, "fixture repository init failed: #{stderr}")
  _stdout, stderr, status = run_in_directory(temporary_root, "git", "add", ".")
  assert(status.success?, "fixture repository staging failed: #{stderr}")
  stdout, stderr, status = run_in_directory(temporary_root, "ruby", "scripts/validate-manifest-policy.rb")
  assert(!status.success?, "source policy accepted unsafe fixture manifests")
  output = stdout + stderr
  [
    "literal Secret data is forbidden",
    "AWS_SECRET_ACCESS_KEY must use valueFrom",
    "approved cluster-admin binding changed",
    "resource escapes the repository",
    "symlinked YAML is forbidden",
    "remote Kustomize resource is not allowlisted"
  ].each do |needle|
    assert(output.include?(needle), "source policy regression is not reported: #{needle}")
  end
  assert(!output.include?("FIXTURE_SOURCE_SECRET_VALUE"), "source policy output disclosed a fixture Secret value")
  assert(!output.include?("FIXTURE_SOURCE_ENV_VALUE"), "source policy output disclosed a fixture environment value")
end

Dir.mktmpdir("manifest-validation-test") do |temporary_root|
  rendered_root = File.join(temporary_root, "rendered-root")
  rendered_fixture_root = File.join(rendered_root, "rendered-policy")
  FileUtils.mkdir_p(rendered_fixture_root)
  Dir.glob(File.join(FIXTURES, "rendered-policy/*.yaml.fixture")).each do |fixture|
    destination = File.join(rendered_fixture_root, File.basename(fixture, ".fixture"))
    FileUtils.cp(fixture, destination)
  end

  source_map = File.join(temporary_root, "source-map.tsv")
  File.write(
    source_map,
    <<~TSV
      rendered-policy/secret.yaml	apps/wordpress/helmfile.yaml
      rendered-policy/env-list.yaml	apps/wordpress/helmfile.yaml
      rendered-policy/env-map.yaml	apps/wordpress/helmfile.yaml
      rendered-policy/rolebinding.yaml	apps/wordpress/helmfile.yaml
      rendered-policy/list.yaml	apps/wordpress/helmfile.yaml
    TSV
  )

  stdout, stderr = assert_failure(
    "ruby", "scripts/validate-rendered-policy.rb", rendered_root,
    source_map
  )
  output = stdout + stderr
  %w[literal rendered Secret AWS_SECRET_ACCESS_KEY CLIENT_SECRET SECRET_KEY_BASE DATABASE_URL].each do |needle|
    assert(output.include?(needle), "rendered policy regression is not reported: #{needle}")
  end
  assert(output.include?("RoleBinding/bad-admin"), "RoleBinding cluster-admin reference was not reported")
  assert(output.include?("nested-secret"), "Secret nested in a List was not reported")
  assert(output.include?("RoleBinding/nested-admin"), "RoleBinding nested in a List was not reported")
  assert(!output.include?("REDACTED"), "rendered policy output disclosed a fixture value")

  allowed_policy = File.join(temporary_root, "allowed-policy.yaml")
  File.write(
    allowed_policy,
    <<~YAML
      renderedSecretExceptions:
        - sourcePath: apps/wordpress/helmfile.yaml
          namespace: default
          kind: Secret
          name: existing
          allowedKeys:
            - password
          reason: Fixture-only generated Secret exception.
    YAML
  )
  secret_root = File.join(temporary_root, "secret-only")
  sanitized_root = File.join(temporary_root, "sanitized")
  FileUtils.mkdir_p(secret_root)
  FileUtils.mkdir_p(sanitized_root)
  FileUtils.cp(File.join(FIXTURES, "rendered-policy/secret.yaml.fixture"), File.join(secret_root, "secret.yaml"))
  File.write(File.join(secret_root, "source-map.tsv"), "secret.yaml\tapps/wordpress/helmfile.yaml\n")
  stdout, stderr = assert_success(
    "ruby", "scripts/validate-rendered-policy.rb", secret_root, File.join(secret_root, "source-map.tsv"), sanitized_root,
    env: {"MANIFEST_POLICY_PATH" => allowed_policy}
  )
  assert(!(stdout + stderr).include?("FIXTURE_SECRET_VALUE"), "allowed Secret policy output disclosed a fixture value")
  sanitized_secret = File.read(File.join(sanitized_root, "secret.yaml"))
  assert(!sanitized_secret.include?("FIXTURE_SECRET_VALUE"), "sanitized output retained an allowed Secret value")
  assert(!sanitized_secret.include?("FIXTURE_SECRET_CHECKSUM"), "sanitized output retained a Secret-derived checksum")
  assert(sanitized_secret.include?("FIXTURE_CONFIGMAP_CHECKSUM"), "sanitization changed a non-Secret checksum")
  assert(sanitized_secret.include?("REDACTED"), "sanitized output did not redact an allowed Secret value")
end

Dir.mktmpdir("hidden-rendered-policy-test") do |temporary_root|
  hidden_root = File.join(temporary_root, ".hidden")
  FileUtils.mkdir_p(hidden_root)
  FileUtils.cp(File.join(FIXTURES, "rendered-policy/env-list.yaml.fixture"), File.join(hidden_root, "env-list.yaml"))
  stdout, stderr = assert_failure("ruby", "scripts/validate-rendered-policy.rb", temporary_root)
  assert((stdout + stderr).include?(".hidden/env-list.yaml"), "rendered policy skipped a dot-directory manifest")
end

assert_success("ruby", "scripts/validate-kubeconform-policy.rb", File.join(FIXTURES, "kubeconform/allowed-schema.json"))
stdout, stderr = assert_failure("ruby", "scripts/validate-kubeconform-policy.rb", File.join(FIXTURES, "kubeconform/unknown-schema.json"))
assert((stdout + stderr).include?("apps/v999/Deployment"), "unknown apiVersion/kind was not rejected")

Dir.mktmpdir("kustomization-roots-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "parent/child"))
  FileUtils.mkdir_p(File.join(temporary_root, "standalone"))
  FileUtils.mkdir_p(File.join(temporary_root, "alternate"))
  FileUtils.mkdir_p(File.join(temporary_root, ".hidden"))
  outside_root = Dir.mktmpdir("outside-kustomization")
  File.write(
    File.join(temporary_root, ".hidden/kustomization.yaml"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n"
  )
  File.write(
    File.join(temporary_root, "parent/kustomization.yaml"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - child\n"
  )
  File.write(
    File.join(temporary_root, "parent/child/Kustomization"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n"
  )
  File.write(
    File.join(temporary_root, "standalone/kustomization.yaml"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n"
  )
  File.write(
    File.join(temporary_root, "alternate/kustomization.yml"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n"
  )
  FileUtils.mkdir_p(File.join(outside_root, "escaped"))
  File.write(
    File.join(outside_root, "escaped/kustomization.yaml"),
    "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n"
  )
  File.symlink(File.join(outside_root, "escaped"), File.join(temporary_root, "escaped"))
  stdout, stderr, status = run_command("ruby", "scripts/discover-kustomization-roots.rb", temporary_root)
  FileUtils.remove_entry(outside_root)
  assert(status.success?, "kustomization root discovery failed: #{stderr}")
  roots = stdout.lines.map(&:chomp)
  assert(
    roots == [".hidden/kustomization.yaml", "alternate/kustomization.yml", "parent/kustomization.yaml", "standalone/kustomization.yaml"],
    "Kustomization variants or nested package discovery are incorrect: #{roots.inspect}"
  )
  assert(!roots.any? { |path| path.start_with?("../") || path.start_with?("escaped") }, "external symlinked Kustomization escaped root discovery")
end

Dir.mktmpdir("flux-ownership-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/home/flux-system"))
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/home/packages/a"))
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/home/packages/b"))
  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: a
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/a
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/a/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: [resource.yaml]
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/a/resource.yaml"), <<~YAML)
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: unique
      namespace: default
    YAML
  assert_success("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)

  outside_root = Dir.mktmpdir("flux-ownership-outside", File.dirname(temporary_root))
  FileUtils.mkdir_p(File.join(outside_root, "empty-package"))
  File.write(File.join(outside_root, "empty-package/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n")
  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: escape
      namespace: flux-system
    spec:
      path: ../#{File.basename(outside_root)}/empty-package
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("escapes repository"), "Flux ownership validator accepted a path escape")

  FileUtils.rm_rf(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"))
  File.symlink(File.join(outside_root, "empty-package"), File.join(temporary_root, "clusters/home/packages/escaped"))
  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: symlink-escape
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/escaped
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("escapes repository"), "Flux ownership validator accepted a symlink escape")
  FileUtils.remove_entry(outside_root)

  FileUtils.rm_f(File.join(temporary_root, "clusters/home/packages/escaped"))
  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: a
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/a
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/a/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: [resource.yaml, resource.yaml]
    YAML
  resource = File.read(File.join(temporary_root, "clusters/home/packages/a/resource.yaml"))
  File.write(File.join(temporary_root, "clusters/home/packages/a/rendered.yaml"), "#{resource}---\n#{resource}")
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("duplicate Flux-owned object"), "Flux ownership validator accepted a same-owner duplicate")
  FileUtils.rm_f(File.join(temporary_root, "clusters/home/packages/a/rendered.yaml"))
  File.write(File.join(temporary_root, "clusters/home/packages/a/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: [resource.yaml]
    YAML
  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: duplicate
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/a
      prune: false
      suspend: true
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: duplicate
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/b
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("duplicate Flux Kustomization"), "Flux ownership validator accepted duplicate Flux metadata identity")

  File.write(File.join(temporary_root, "clusters/home/flux-system/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: a
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/a
      prune: false
      suspend: true
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: b
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/b
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/a/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: [resource.yaml]
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/b/kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources: [resource.yaml]
    YAML
  File.write(File.join(temporary_root, "clusters/home/packages/b/resource.yaml"), File.read(File.join(temporary_root, "clusters/home/packages/a/resource.yaml")))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("duplicate Flux-owned object"), "Flux ownership validator did not catch duplicate object")
end

Dir.mktmpdir("flux-reference-validation-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/flux"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  File.write(File.join(temporary_root, ".github/manifest-policy.yaml"), "bootstrapManagedSources:\n  - apiVersion: source.toolkit.fluxcd.io/v1\n    kind: GitRepository\n    namespace: flux-system\n    name: flux-system\n    reason: fixture\n")
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/pkg"))
  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [repo.yaml, release.yaml]\n")
  File.write(File.join(temporary_root, "clusters/pkg/repo.yaml"), "apiVersion: source.toolkit.fluxcd.io/v1\nkind: HelmRepository\nmetadata:\n  name: charts\n  namespace: flux-system\nspec:\n  interval: 1h\n  url: https://example.invalid\n")
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), "apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: app\n  namespace: default\nspec:\n  suspend: true\n  chart:\n    spec:\n      chart: app\n      sourceRef:\n        kind: HelmRepository\n        name: charts\n        namespace: flux-system\n")
  flux_path = File.join(temporary_root, "clusters/flux/sync.yaml")
  valid = "apiVersion: kustomize.toolkit.fluxcd.io/v1\nkind: Kustomization\nmetadata:\n  name: app\n  namespace: flux-system\nspec:\n  path: ./clusters/pkg\n  prune: false\n  suspend: true\n  sourceRef:\n    kind: GitRepository\n    name: flux-system\n"
  File.write(flux_path, valid)
  assert_success("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)

  File.write(flux_path, valid.gsub(/  sourceRef:\n    kind: GitRepository\n    name: flux-system\n/, ""))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("sourceRef is required"), "missing sourceRef was accepted")
  File.write(flux_path, valid.sub("  sourceRef:\n", "  dependsOn:\n    - name: missing\n  sourceRef:\n"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("unknown dependency"), "unknown dependency was accepted")
  cycle = valid.sub("  sourceRef:\n", "  dependsOn:\n    - name: app\n  sourceRef:\n")
  File.write(flux_path, cycle)
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("dependency cycle"), "dependency cycle was accepted")
  File.write(flux_path, valid)
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), File.read(File.join(temporary_root, "clusters/pkg/release.yaml")).sub("name: charts", "name: missing"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("HelmRepository sourceRef is missing or mismatched"), "missing HelmRepository was accepted")

  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [repo.yaml, release.yaml]\n")
  File.write(File.join(temporary_root, "clusters/pkg/repo.yaml"), "apiVersion: source.toolkit.fluxcd.io/v1\nkind: GitRepository\nmetadata:\n  name: flux-system\n  namespace: flux-system\nspec:\n  interval: 1m\n  url: https://github.com/tauto1127/k8s-home-lab\n  ref:\n    branch: main\n")
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), "apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: app\n  namespace: default\nspec:\n  suspend: true\n  chart:\n    spec:\n      chart: ./apps/memos/chart\n      sourceRef:\n        kind: GitRepository\n        name: flux-system\n        namespace: flux-system\n")
  File.write(flux_path, valid)
  assert_success("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)

  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [release.yaml]\n")
  FileUtils.rm_f(File.join(temporary_root, "clusters/pkg/repo.yaml"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("GitRepository sourceRef is missing or mismatched"), "undeclared GitRepository chart source was accepted")

  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [repo.yaml, release.yaml]\n")
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), "apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: app\n  namespace: default\nspec:\n  suspend: true\n  chart:\n    spec:\n      chart: ./apps/memos/chart\n      sourceRef:\n        kind: GitRepository\n        name: flux-system\n        namespace: flux-system\n")
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), File.read(File.join(temporary_root, "clusters/pkg/release.yaml")).sub("chart: ./apps/memos/chart", "chart: apps/memos/chart"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("GitRepository chart path must be repository-relative"), "relative Git chart path without ./ was accepted")

  File.write(File.join(temporary_root, "clusters/pkg/repo.yaml"), "apiVersion: source.toolkit.fluxcd.io/v1\nkind: GitRepository\nmetadata:\n  name: other\n  namespace: flux-system\nspec:\n  interval: 1m\n  url: https://github.com/tauto1127/k8s-home-lab\n  ref:\n    branch: main\n")
  File.write(File.join(temporary_root, "clusters/pkg/release.yaml"), "apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: app\n  namespace: default\nspec:\n  suspend: true\n  chart:\n    spec:\n      chart: ./apps/memos/chart\n      sourceRef:\n        kind: GitRepository\n        name: other\n        namespace: flux-system\n")
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("GitRepository sourceRef must be the bootstrap flux-system source"), "non-bootstrap GitRepository chart source was accepted")
end

Dir.mktmpdir("flux-activation-policy-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/flux"))
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/pkg"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  policy_path = File.join(temporary_root, ".github/manifest-policy.yaml")
  flux_path = File.join(temporary_root, "clusters/flux/sync.yaml")
  release_path = File.join(temporary_root, "clusters/pkg/release.yaml")
  validator = File.join(ROOT, "scripts/validate-flux-ownership.rb")

  inactive_flux = <<~YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: fixture-controller
      namespace: flux-system
    spec:
      path: ./clusters/pkg
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
  YAML
  inactive_release = <<~YAML
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: fixture-release
      namespace: fixture-system
    spec:
      suspend: true
      releaseName: fixture-release
      targetNamespace: fixture-system
      storageNamespace: fixture-system
      chart:
        spec:
          chart: external-secrets
          version: 0.14.4
          sourceRef:
            kind: HelmRepository
            name: fixture-repository
            namespace: flux-system
      install:
        crds: Skip
        disableTakeOwnership: true
      upgrade:
        crds: Skip
        disableTakeOwnership: true
      values:
        installCRDs: true
  YAML
  activation_policy = <<~YAML
    bootstrapManagedSources:
      - apiVersion: source.toolkit.fluxcd.io/v1
        kind: GitRepository
        namespace: flux-system
        name: flux-system
    fluxActivation:
      phase: test-fixture-helm-adoption
      reason: Fixture activation requires the outer and inner resources together.
      activeKustomizations:
        - apiVersion: kustomize.toolkit.fluxcd.io/v1
          kind: Kustomization
          namespace: flux-system
          name: fixture-controller
          path: ./clusters/pkg
          inventory:
            - apiVersion: v1
              kind: Namespace
              namespace: ""
              name: fixture-system
            - apiVersion: source.toolkit.fluxcd.io/v1
              kind: HelmRepository
              namespace: flux-system
              name: fixture-repository
            - apiVersion: helm.toolkit.fluxcd.io/v2
              kind: HelmRelease
              namespace: fixture-system
              name: fixture-release
      activeHelmReleases:
        - apiVersion: helm.toolkit.fluxcd.io/v2
          kind: HelmRelease
          namespace: fixture-system
          name: fixture-release
          owner:
            apiVersion: kustomize.toolkit.fluxcd.io/v1
            kind: Kustomization
            namespace: flux-system
            name: fixture-controller
          chart:
            name: external-secrets
            version: 0.14.4
            repository:
              apiVersion: source.toolkit.fluxcd.io/v1
              kind: HelmRepository
              namespace: flux-system
              name: fixture-repository
              url: https://charts.external-secrets.io
            artifact:
              url: https://fixture.invalid/external-secrets-0.14.4.tgz
              sha256: #{Digest::SHA256.hexdigest(FIXTURE_CHART_ASSET)}
              crdTemplates:
                pathPrefix: external-secrets/templates/crds/
                count: 1
                sha256: #{FIXTURE_CHART_CRD_SET_SHA}
              crdInventory:
                pathPrefix: external-secrets/templates/crds/
                count: 1
                setSha256: #{FIXTURE_CHART_CRD_SET_SHA}
              resourceInventory:
                - apiVersion: example.invalid/v1
                  kind: FixtureCRD
                  namespace: ""
                  name: fixture-crd
          safety:
            installCRDs: true
  YAML
  File.write(policy_path, activation_policy)
  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [namespace.yaml, repo.yaml, release.yaml]\n")
  File.write(File.join(temporary_root, "clusters/pkg/namespace.yaml"), "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: fixture-system\n")
  File.write(File.join(temporary_root, "clusters/pkg/repo.yaml"), "apiVersion: source.toolkit.fluxcd.io/v1\nkind: HelmRepository\nmetadata:\n  name: fixture-repository\n  namespace: flux-system\nspec:\n  interval: 1h\n  url: https://charts.external-secrets.io\n")

  File.write(flux_path, inactive_flux.sub("suspend: true", "suspend: false"))
  File.write(release_path, inactive_release.sub("suspend: true", "suspend: false"))
  assert_success("ruby", validator, temporary_root)

  stdout, stderr = assert_failure("ruby", validator, temporary_root, env: {"FAKE_HELM_MODE" => "drift"})
  assert((stdout + stderr).include?("rendered resource inventory mismatch"), "Helm chart resource inventory drift was accepted")
  stdout, stderr = assert_failure("ruby", validator, temporary_root, env: {"FAKE_HELM_MODE" => "nonzero"})
  assert((stdout + stderr).include?("pinned Helm renderer failed"), "non-zero Helm renderer was accepted")
  stdout, stderr = assert_failure("ruby", validator, temporary_root, env: {"FAKE_HELM_MODE" => "empty"})
  assert((stdout + stderr).include?("pinned Helm render was empty"), "empty Helm render was accepted")
  stdout, stderr = assert_failure("ruby", validator, temporary_root, env: {"FAKE_HELM_MODE" => "duplicate"})
  assert((stdout + stderr).include?("duplicate identities"), "duplicate rendered resource identities were accepted")
  stdout, stderr = assert_failure(
    "ruby", validator, temporary_root,
    env: {"FLUX_OWNERSHIP_HELM" => File.join(temporary_root, "missing-helm")}
  )
  assert((stdout + stderr).include?("pinned Helm renderer is unavailable"), "unavailable Helm renderer was accepted")

  unknown_phase_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  unknown_phase_document["fluxActivation"]["phase"] = "unexpected-phase"
  File.write(policy_path, YAML.dump(unknown_phase_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("fluxActivation phase is not recognized: unexpected-phase"), "unknown activation phase was accepted")
  File.write(policy_path, activation_policy)

  File.write(release_path, inactive_release)
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("approved active HelmRelease"), "activation policy accepted a suspended inner HelmRelease")

  unsafe_release = inactive_release
    .sub("suspend: true", "suspend: false")
    .sub("disableTakeOwnership: true", "disableTakeOwnership: false")
  File.write(release_path, unsafe_release)
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("install.disableTakeOwnership must be true"), "active HelmRelease was allowed to take ownership")

  File.write(flux_path, inactive_flux)
  File.write(release_path, inactive_release.sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("rendered by a suspended Flux Kustomization"), "activation policy accepted an active inner HelmRelease under a suspended owner")

  File.write(flux_path, inactive_flux.sub("suspend: true", "suspend: false"))
  File.write(release_path, inactive_release.sub("suspend: true", "suspend: false"))
  policy_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  policy_document["fluxActivation"]["activeHelmReleases"] = []
  File.write(policy_path, YAML.dump(policy_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("active HelmRelease policy must exactly match active Kustomization inventory"), "empty active HelmRelease policy was accepted")

  policy_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  policy_document["fluxActivation"]["activeHelmReleases"][0]["name"] = "missing"
  File.write(policy_path, YAML.dump(policy_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("approved active HelmRelease is missing"), "stale active HelmRelease policy identity was accepted")

  policy_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  policy_document["fluxActivation"]["activeKustomizations"][0]["path"] = "./clusters/other"
  File.write(policy_path, YAML.dump(policy_document))
  File.write(flux_path, inactive_flux.sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("active Kustomization path must be ./clusters/other"), "active Kustomization path change was accepted")

  File.write(flux_path, inactive_flux.sub("suspend: true", "suspend: false"))
  File.write(release_path, inactive_release.sub("suspend: true", "suspend: false"))
  policy_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  policy_document["fluxActivation"]["activeHelmReleases"][0]["chart"]["version"] = "9.9.9"
  File.write(policy_path, YAML.dump(policy_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("chart version must be 9.9.9"), "active HelmRelease chart version drift was accepted")

  File.write(policy_path, activation_policy)
  inventory_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  inventory_document["fluxActivation"]["activeKustomizations"][0]["inventory"].shift
  File.write(policy_path, YAML.dump(inventory_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("rendered inventory mismatch"), "active Kustomization inventory drift was accepted")

  File.write(policy_path, activation_policy)
  repository_path = File.join(temporary_root, "clusters/pkg/repo.yaml")
  repository = File.read(repository_path)
  File.write(repository_path, repository.sub("https://charts.external-secrets.io", "https://example.invalid"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("HelmRepository URL must be https://charts.external-secrets.io"), "active HelmRepository URL drift was accepted")
  File.write(repository_path, repository)

  phase_bypass_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  phase_bypass_document["fluxActivation"]["activeKustomizations"][0]["name"] = "eso-controller"
  phase_bypass_document["fluxActivation"]["activeHelmReleases"][0]["namespace"] = "external-secrets"
  phase_bypass_document["fluxActivation"]["activeHelmReleases"][0]["name"] = "external-secrets"
  File.write(policy_path, YAML.dump(phase_bypass_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux ESO controller identities must use fluxActivation phase eso-controller"), "ESO identities bypassed their fixed contract by changing phase")

  self_approved_source_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  self_approved_source_document["fluxActivation"]["phase"] = "eso-controller"
  self_approved_source_document["fluxActivation"]["activeHelmReleases"][0]["chart"]["repository"]["url"] = "https://example.invalid"
  File.write(policy_path, YAML.dump(self_approved_source_document))
  File.write(repository_path, repository.sub("https://charts.external-secrets.io", "https://example.invalid"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("fluxActivation eso-controller activeHelmReleases contract must exactly match"), "ESO policy and manifest could self-approve an unexpected HelmRepository URL")
  File.write(repository_path, repository)

  artifact_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  artifact_document["fluxActivation"]["activeHelmReleases"][0]["chart"]["artifact"]["sha256"] = "0" * 64
  File.write(policy_path, YAML.dump(artifact_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("upstream artifact checksum mismatch"), "active chart artifact checksum drift was accepted")

  artifact_url_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  artifact_url_document["fluxActivation"]["activeHelmReleases"][0]["chart"]["artifact"]["url"] = "http://example.invalid/external-secrets-0.14.4.tgz"
  File.write(policy_path, YAML.dump(artifact_url_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("chart.artifact.url must use HTTPS"), "non-HTTPS active chart artifact URL was accepted")

  crd_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  crd_document["fluxActivation"]["activeHelmReleases"][0]["chart"]["artifact"]["crdTemplates"]["sha256"] = "0" * 64
  File.write(policy_path, YAML.dump(crd_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("CRD template inventory checksum mismatch"), "active chart CRD template drift was accepted")

  owner_document = YAML.safe_load(activation_policy, permitted_classes: [], permitted_symbols: [], aliases: false)
  owner_document["fluxActivation"]["activeHelmReleases"][0]["owner"]["name"] = "other-controller"
  File.write(policy_path, YAML.dump(owner_document))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("owner must be an approved active Kustomization"), "active HelmRelease owner drift was accepted")

  File.write(policy_path, activation_policy)
  File.write(release_path, inactive_release.sub("suspend: true", "suspend: false").sub("installCRDs: true", "installCRDs: false"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("spec.values.installCRDs must be true"), "active chart could omit the existing template-managed CRDs")

  File.write(release_path, inactive_release.sub(/spec:\n(?:  .*\n|\n)*/m, "spec: invalid\n"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("spec must be a mapping"), "malformed active HelmRelease spec did not fail clearly: #{stdout + stderr}")
end

Dir.mktmpdir("flux-render-and-gate-validation-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/flux"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  policy_path = File.join(temporary_root, ".github/manifest-policy.yaml")
  File.write(policy_path, "bootstrapManagedSources:\n  - apiVersion: source.toolkit.fluxcd.io/v1\n    kind: GitRepository\n    namespace: flux-system\n    name: flux-system\n")
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/pkg"))
  File.write(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [rendered.yaml]\n")
  File.write(File.join(temporary_root, "clusters/pkg/rendered.yaml"), <<~YAML)
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: HelmRepository
    metadata:
      name: charts
      namespace: flux-system
    spec:
      interval: 1h
      url: https://example.invalid
    ---
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: nextcloud
      namespace: nextcloud
      annotations:
        flux.takutk.com/activation-blocked: "true"
    spec:
      suspend: true
      chart:
        spec:
          chart: nextcloud
          sourceRef:
            kind: HelmRepository
            name: charts
            namespace: flux-system
  YAML
  flux_path = File.join(temporary_root, "clusters/flux/sync.yaml")
  valid = <<~YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: nextcloud
      namespace: flux-system
      annotations:
        flux.takutk.com/activation-blocked: "true"
    spec:
      path: ./clusters/pkg
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: flux-system
  YAML
  File.write(flux_path, valid)
  assert_success("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)

  blocked_package = File.join(temporary_root, "clusters/home/packages/nextcloud")
  FileUtils.mkdir_p(blocked_package)
  FileUtils.cp(File.join(temporary_root, "clusters/pkg/kustomization.yaml"), blocked_package)
  FileUtils.cp(File.join(temporary_root, "clusters/pkg/rendered.yaml"), blocked_package)
  disguised_outer = valid
    .sub("name: nextcloud", "name: disguised-workload")
    .sub("path: ./clusters/pkg", "path: ./clusters/home/packages/nextcloud")
    .sub("      flux.takutk.com/activation-blocked: \"true\"\n", "")
    .sub("suspend: true", "suspend: false")
  File.write(flux_path, disguised_outer)
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  disguised_output = stdout + stderr
  assert(disguised_output.include?("Nextcloud package path must remain suspended"), "renamed outer Kustomization bypassed the blocked Nextcloud path")
  assert(disguised_output.include?("renders a blocked Nextcloud object"), "renamed outer Kustomization bypassed the blocked Nextcloud inventory")
  File.write(flux_path, valid)

  File.write(File.join(temporary_root, "clusters/pkg/rendered.yaml"), File.read(File.join(temporary_root, "clusters/pkg/rendered.yaml")).sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("suspend must be true"), "rendered HelmRelease suspend:false was accepted")
  File.write(File.join(temporary_root, "clusters/pkg/rendered.yaml"), File.read(File.join(temporary_root, "clusters/pkg/rendered.yaml")).sub("suspend: false", "suspend: true"))

  File.write(flux_path, valid.sub("flux.takutk.com/activation-blocked", "flux.takutk.com/activation-typo"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("activation-blocked annotation must be true"), "outer Nextcloud gate typo was accepted")
  File.write(flux_path, valid)
  rendered = File.read(File.join(temporary_root, "clusters/pkg/rendered.yaml"))
  File.write(File.join(temporary_root, "clusters/pkg/rendered.yaml"), rendered.split("---").first)
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("Nextcloud HelmRelease is required"), "inner Nextcloud HelmRelease omission was accepted")

  File.write(policy_path, <<~YAML)
    bootstrapManagedSources:
      - apiVersion: source.toolkit.fluxcd.io/v1
        kind: GitRepository
        namespace: flux-system
        name: flux-system
    fluxActivation:
      phase: forbidden-nextcloud
      reason: Fixture proves the activation-blocked package cannot be allowlisted active.
      activeKustomizations:
        - apiVersion: kustomize.toolkit.fluxcd.io/v1
          kind: Kustomization
          namespace: flux-system
          name: nextcloud
      activeHelmReleases:
        - apiVersion: helm.toolkit.fluxcd.io/v2
          kind: HelmRelease
          namespace: nextcloud
          name: nextcloud
  YAML
  File.write(flux_path, valid.sub("suspend: true", "suspend: false"))
  File.write(File.join(temporary_root, "clusters/pkg/rendered.yaml"), rendered.sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  output = stdout + stderr
  assert(output.include?("Nextcloud Flux Kustomization must remain suspended"), "Nextcloud outer activation was allowlisted")
  assert(output.include?("Nextcloud HelmRelease must remain suspended"), "Nextcloud inner activation was allowlisted")
end

Dir.mktmpdir("flux-order-and-source-validation-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/flux"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  File.write(File.join(temporary_root, ".github/manifest-policy.yaml"), "bootstrapManagedSources: []\n")
  %w[a b].each do |name|
    FileUtils.mkdir_p(File.join(temporary_root, "clusters/pkg-#{name}"))
    File.write(File.join(temporary_root, "clusters/pkg-#{name}/kustomization.yaml"), "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [resource.yaml]\n")
    File.write(File.join(temporary_root, "clusters/pkg-#{name}/resource.yaml"), "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: unique-#{name}\n  namespace: default\n")
  end
  File.write(File.join(temporary_root, "clusters/pkg-b/gitrepository.yaml"), "apiVersion: source.toolkit.fluxcd.io/v1\nkind: GitRepository\nmetadata:\n  name: declared\n  namespace: flux-system\nspec:\n  interval: 1h\n  url: https://example.invalid\n")
  File.write(File.join(temporary_root, "clusters/flux/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: a
      namespace: flux-system
    spec:
      path: ./clusters/pkg-a
      prune: false
      suspend: true
      dependsOn:
        - name: b
      sourceRef:
        kind: GitRepository
        name: declared
        namespace: flux-system
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: b
      namespace: flux-system
    spec:
      path: ./clusters/pkg-b
      prune: false
      suspend: true
      sourceRef:
        kind: GitRepository
        name: declared
        namespace: flux-system
  YAML
  stdout, stderr = assert_success("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert(stdout.include?("Validated 2 Flux Kustomizations"), "backward dependency or declared GitRepository failed")

  sync = File.read(File.join(temporary_root, "clusters/flux/sync.yaml"))
  File.write(File.join(temporary_root, "clusters/flux/sync.yaml"), sync.sub("name: declared\n", "name: missing\n"))
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("neither declared in rendered packages nor explicitly allowlisted"), "undeclared GitRepository was accepted")

  # Replace the second document with a two-node cycle fixture explicitly.
  File.write(File.join(temporary_root, "clusters/flux/sync.yaml"), <<~YAML)
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: a
      namespace: flux-system
    spec:
      path: ./clusters/pkg-a
      prune: false
      suspend: true
      dependsOn:
        - name: b
      sourceRef:
        kind: GitRepository
        name: declared
        namespace: flux-system
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: b
      namespace: flux-system
    spec:
      path: ./clusters/pkg-b
      prune: false
      suspend: true
      dependsOn:
        - name: a
      sourceRef:
        kind: GitRepository
        name: declared
        namespace: flux-system
  YAML
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("dependency cycle"), "two-node dependency cycle was accepted")
end

Dir.mktmpdir("flux-bootstrap-unexpected-source-test") do |temporary_root|
  write_flux_bootstrap_fixture(
    temporary_root,
    source_url: "https://github.com/example/unexpected",
    root_suspend: true
  )
  stdout, stderr = assert_failure("ruby", File.join(ROOT, "scripts/validate-flux-ownership.rb"), temporary_root)
  assert((stdout + stderr).include?("bootstrap GitRepository url must be https://github.com/tauto1127/k8s-home-lab"), "unexpected bootstrap repository URL was not rejected exactly")
end

Dir.mktmpdir("flux-bootstrap-validation-test") do |temporary_root|
  write_flux_bootstrap_fixture(temporary_root)
  validator = File.join(ROOT, "scripts/validate-flux-ownership.rb")
  assert_success("ruby", validator, temporary_root)

  sync_path = File.join(temporary_root, "clusters/home/flux-system/gotk-sync.yaml")
  original_sync = File.read(sync_path)
  policy_path = File.join(temporary_root, ".github/manifest-policy.yaml")
  original_policy = File.read(policy_path)
  components_path = File.join(temporary_root, "clusters/home/flux-system/gotk-components.yaml")
  original_components = File.read(components_path)
  package_sync_path = File.join(temporary_root, "clusters/home/flux-system/sync.yaml")
  original_package_sync = File.read(package_sync_path)
  root_render_path = File.join(temporary_root, "clusters/home/rendered.out")
  original_root_render = File.read(root_render_path)

  File.write(policy_path, original_policy.sub("version: v2.9.3", "version: latest"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("fluxBootstrap.version must be an exact vMAJOR.MINOR.PATCH"), "floating Flux version was accepted")
  File.write(policy_path, original_policy)

  File.write(policy_path, original_policy.sub("releases/download/v2.9.3/install.yaml", "releases/latest/download/install.yaml"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("components sourceUrl must be pinned to v2.9.3"), "floating Flux components URL was accepted")
  File.write(policy_path, original_policy)

  File.write(policy_path, original_policy.sub(Digest::SHA256.hexdigest(FIXTURE_INSTALL_ASSET), "f" * 64))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("upstream artifact checksum mismatch"), "incorrect upstream Flux source checksum was not reported:\n#{stdout}\n#{stderr}")
  File.write(policy_path, original_policy)

  stdout, stderr = assert_failure(
    "ruby", validator, temporary_root,
    env: {"FLUX_OWNERSHIP_CURL" => File.join(temporary_root, "missing-curl")}
  )
  assert((stdout + stderr).include?("upstream artifact fetcher is unavailable"), "unavailable upstream artifact fetcher was accepted")

  File.write(policy_path, original_policy.sub("url: https://github.com/tauto1127/k8s-home-lab", "url: https://github.com/example/unexpected"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("fluxBootstrap.source.url must be"), "bootstrap policy accepted an unexpected repository URL")
  File.write(policy_path, original_policy)

  File.write(sync_path, original_sync.sub("branch: main", "branch: unsafe"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("bootstrap GitRepository branch must be main"), "unexpected bootstrap branch was accepted")
  File.write(sync_path, original_sync)

  File.write(sync_path, original_sync.sub("path: ./clusters/home", "path: ./clusters/other"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("bootstrap root path must be ./clusters/home"), "unexpected bootstrap path was accepted")
  File.write(sync_path, original_sync)

  File.write(components_path, "#{File.read(components_path)}\n# changed\n")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("gotk-components checksum mismatch"), "changed bootstrap components were accepted")
  write_flux_bootstrap_fixture(temporary_root)

  File.write(components_path, "#{original_components}\n# content not produced by the pinned Flux CLI\n")
  changed_sha = Digest::SHA256.file(components_path).hexdigest
  File.write(policy_path, original_policy.sub(/^(        sha256: )[0-9a-f]{64}$/, "\\1#{changed_sha}"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("does not match pinned Flux CLI generation"), "components unrelated to pinned Flux CLI generation were accepted")
  write_flux_bootstrap_fixture(temporary_root)

  stdout, stderr = assert_failure(
    "ruby", validator, temporary_root,
    env: {"FLUX_OWNERSHIP_FLUX" => File.join(temporary_root, "missing-flux")}
  )
  assert((stdout + stderr).include?("pinned Flux generator is unavailable"), "unavailable pinned Flux generator was accepted")

  extra_cluster_role = <<~YAML
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: unexpected-flux-system
    rules: []
  YAML
  File.write(components_path, "#{original_components}#{extra_cluster_role}")
  changed_sha = Digest::SHA256.file(components_path).hexdigest
  File.write(policy_path, original_policy.sub(/^(        sha256: )[0-9a-f]{64}$/, "\\1#{changed_sha}"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("ClusterRole inventory mismatch"), "unexpected Flux ClusterRole was accepted")
  write_flux_bootstrap_fixture(temporary_root)

  duplicate_crd = <<~YAML
    ---
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: gitrepositories.source.toolkit.fluxcd.io
    spec: {}
  YAML
  File.write(components_path, "#{original_components}#{duplicate_crd}")
  changed_sha = Digest::SHA256.file(components_path).hexdigest
  File.write(policy_path, original_policy.sub(/^(        sha256: )[0-9a-f]{64}$/, "\\1#{changed_sha}"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("duplicate gotk-components resource identity"), "duplicate Flux component identity was accepted")
  write_flux_bootstrap_fixture(temporary_root)

  schema_path = File.join(temporary_root, ".github/schemas/flux/v2.9.3/v1.36.0-standalone-strict/gitrepository-source-v1.json")
  changed_schema = "{ }\n"
  File.write(schema_path, changed_schema)
  changed_schema_sha = Digest::SHA256.hexdigest(changed_schema)
  original_schema_sha = Digest::SHA256.hexdigest("{}\n")
  File.write(policy_path, original_policy.sub(original_schema_sha, changed_schema_sha))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("does not match upstream schema archive"), "schema unrelated to the pinned upstream archive was accepted")
  write_flux_bootstrap_fixture(temporary_root)

  File.write(package_sync_path, original_package_sync.sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization app: suspend must be true"), "active workload Kustomization was accepted")
  File.write(package_sync_path, original_package_sync.sub("prune: false", "prune: true"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization app: prune must be false"), "pruning workload Kustomization was accepted")
  File.write(package_sync_path, original_package_sync)

  hidden_package = File.join(temporary_root, "clusters/home/packages/hidden")
  FileUtils.mkdir_p(hidden_package)
  File.write(File.join(hidden_package, "kustomization.yaml"), <<~YAML)
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - resource.yaml
  YAML
  File.write(File.join(hidden_package, "resource.yaml"), <<~YAML)
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: hidden
      namespace: default
  YAML
  hidden_flux = <<~YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: hidden
      namespace: flux-system
    spec:
      path: ./clusters/home/packages/hidden
      prune: false
      suspend: false
      sourceRef:
        kind: GitRepository
        name: flux-system
  YAML

  hidden_list_path = File.join(temporary_root, "clusters/home/flux-system/hidden-list.yaml")
  hidden_list_item = hidden_flux.lines.each_with_index.map { |line, index| index.zero? ? "  - #{line}" : "    #{line}" }.join
  File.write(hidden_list_path, "apiVersion: v1\nkind: List\nitems:\n#{hidden_list_item}")
  File.write(root_render_path, "#{original_root_render}---\n#{hidden_flux}")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization hidden: suspend must be true"), "active Flux Kustomization nested in List.items was not reported:\n#{stdout}\n#{stderr}")
  FileUtils.rm_f(hidden_list_path)
  File.write(root_render_path, original_root_render)

  hidden_json_path = File.join(temporary_root, "clusters/home/flux-system/hidden.json")
  File.write(hidden_json_path, JSON.pretty_generate(YAML.safe_load(hidden_flux)))
  File.write(root_render_path, "#{original_root_render}---\n#{hidden_flux}")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization hidden: suspend must be true"), "active Flux Kustomization declared as JSON was accepted")
  FileUtils.rm_f(hidden_json_path)
  File.write(root_render_path, original_root_render)

  outside_flux_root = File.join(temporary_root, "shared")
  FileUtils.mkdir_p(outside_flux_root)
  File.write(File.join(outside_flux_root, "hidden-flux.yaml"), hidden_flux)
  File.write(root_render_path, "#{original_root_render}---\n#{hidden_flux}")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("rendered Flux Kustomization is not declared under clusters"), "Flux Kustomization rendered from outside clusters was accepted")
  File.write(root_render_path, original_root_render)

  duplicate = <<~YAML
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: app
      namespace: default
  YAML
  File.write(root_render_path, "#{original_root_render}#{duplicate}")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("duplicate Flux-owned object"), "bootstrap root duplicate ownership was accepted")
  File.write(root_render_path, original_root_render)

  root_kustomization_path = File.join(temporary_root, "clusters/home/kustomization.yaml")
  original_root_kustomization = File.read(root_kustomization_path)
  File.write(root_kustomization_path, original_root_kustomization.sub("- flux-system", "- ."))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Kustomize composition cycle"), "recursive bootstrap root was accepted")
  File.write(root_kustomization_path, original_root_kustomization)

  Dir.mktmpdir("flux-bootstrap-outside-resource") do |outside_root|
    outside_resource = File.join(outside_root, "outside.yaml")
    File.write(outside_resource, "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: outside\n")
    linked_resource = File.join(temporary_root, "clusters/home/linked.yaml")
    File.symlink(outside_resource, linked_resource)
    File.write(root_kustomization_path, original_root_kustomization.sub("- flux-system", "- flux-system\n  - linked.yaml"))
    stdout, stderr = assert_failure("ruby", validator, temporary_root)
    assert((stdout + stderr).include?("path escapes repository"), "external symlink file in bootstrap composition was accepted")
    FileUtils.rm_f(linked_resource)
    File.write(root_kustomization_path, original_root_kustomization)
  end

  File.write(File.join(temporary_root, "clusters/home/render-mode"), "nonzero\n")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Kustomize render failed"), "non-zero bootstrap renderer was accepted")
  File.write(File.join(temporary_root, "clusters/home/render-mode"), "empty\n")
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Kustomize render was empty"), "empty bootstrap renderer was accepted")
  FileUtils.rm_f(File.join(temporary_root, "clusters/home/render-mode"))
  stdout, stderr = assert_failure(
    "ruby", validator, temporary_root,
    env: {"FLUX_OWNERSHIP_KUBECTL" => File.join(temporary_root, "missing-kubectl")}
  )
  assert((stdout + stderr).include?("Kustomize renderer is unavailable"), "unavailable bootstrap renderer was accepted")
end

def test_trek_activation_and_render_contract
  sync = YAML.load_stream(File.read(File.join(ROOT, "clusters/home/flux-system/sync.yaml")))
  trek_sync = sync.find { |resource| resource.dig("metadata", "name") == "trek" }
  assert(trek_sync, "TREK Flux Kustomization is missing")
  assert(trek_sync.dig("spec", "suspend") == false, "TREK config activation must enable outer Kustomization")
  assert(trek_sync.dig("metadata", "annotations", "flux.takutk.com/activation-blocked").nil?, "TREK outer activation marker must be removed")
  package_root = File.join(ROOT, "clusters/home/packages/trek")
  namespace = YAML.load_stream(File.read(File.join(package_root, "namespace.yaml"))).first
  assert(namespace.dig("metadata", "labels", "flux.takutk.com/activation-blocked").nil?, "TREK Namespace activation label must be removed")
  assert(namespace.dig("metadata", "annotations", "flux.takutk.com/activation-blocked").nil?, "TREK Namespace activation annotation must be removed")
  package = YAML.load_stream(File.read(File.join(package_root, "helmrelease.yaml"))).first
  assert(package.dig("spec", "suspend") == false, "TREK app activation must enable inner HelmRelease")
  assert(package.dig("metadata", "annotations", "flux.takutk.com/activation-blocked").nil?, "TREK HelmRelease activation marker must be removed")
  assert(package.dig("spec", "chart", "spec", "version") == "4.2.1", "TREK chart version drifted")
  assert(package.dig("spec", "values", "image", "tag") == "4.2.1@sha256:777f4d647e973fe7d87fecd957e854b86d57e8d977fd041763e0ca19b3c2e2c0", "TREK image digest drifted")

  ingress_annotations = package.dig("spec", "values", "ingress", "annotations")
  assert(ingress_annotations == {"konghq.com/strip-path" => "false"}, "TREK Ingress must contain only strip-path")
  patches = package.dig("spec", "postRenderers", 0, "kustomize", "patches")
  assert(patches.length == 2, "TREK must have Service timeout and DEFAULT_LANGUAGE post-renderer patches")
  timeout_patch = patches.first
  assert(timeout_patch["target"] == {"version" => "v1", "kind" => "Service", "name" => "trek"}, "TREK timeout patch target drifted")
  timeout_document = YAML.load_stream(timeout_patch.fetch("patch")).first
  assert(timeout_document.first["path"] == "/metadata/annotations", "TREK timeout patch path drifted")
  assert(timeout_document.first.dig("value") == {
    "konghq.com/connect-timeout" => "60000",
    "konghq.com/read-timeout" => "86400000",
    "konghq.com/write-timeout" => "86400000"
  }, "TREK Service timeout annotations drifted")
  language_patch = patches[1]
  assert(language_patch["target"] == {"version" => "v1", "kind" => "ConfigMap", "name" => "trek-config"}, "TREK language patch target drifted")
  language_document = YAML.load_stream(language_patch.fetch("patch")).first
  assert(language_document.first == {
    "op" => "add",
    "path" => "/data/DEFAULT_LANGUAGE",
    "value" => "ja"
  }, "TREK DEFAULT_LANGUAGE patch drifted")

  policy = YAML.safe_load(File.read(File.join(ROOT, ".github/manifest-policy.yaml")))
  activation = policy.fetch("fluxActivation")
  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek"
  active_kustomizations = {outer_id => activation.fetch("activeKustomizations").find { |entry| entry["name"] == "trek" }}
  active_helm_releases = {inner_id => activation.fetch("activeHelmReleases").find { |entry| entry["name"] == "trek" }}
  failures = []
  validate_trek_stage_state!("app-active", trek_sync, package, active_kustomizations, active_helm_releases, failures)
  assert(failures.empty?, "TREK app-active state was rejected: #{failures.join('; ')}")

  config_outer = Marshal.load(Marshal.dump(trek_sync))
  config_outer["spec"]["suspend"] = false
  config_outer["metadata"]["annotations"] ||= {}
  config_outer["metadata"]["annotations"].delete("flux.takutk.com/activation-blocked")
  config_policy = {outer_id => {}}
  config_helm_policy = {inner_id => {}}
  config_inner = Marshal.load(Marshal.dump(package))
  config_inner["spec"]["suspend"] = true
  config_inner["metadata"]["annotations"] ||= {}
  config_inner["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
  failures = []
  validate_trek_stage_state!("config-active", config_outer, config_inner, config_policy, config_helm_policy, failures)
  assert(failures.empty?, "TREK config-active state was rejected: #{failures.join('; ')}")

  app_inner = Marshal.load(Marshal.dump(package))
  app_inner["spec"]["suspend"] = false
  app_inner["metadata"]["annotations"] ||= {}
  app_inner["metadata"]["annotations"].delete("flux.takutk.com/activation-blocked")
  app_policy = {outer_id => {}}
  app_helm_policy = {inner_id => {}}
  failures = []
  validate_trek_stage_state!("app-active", config_outer, app_inner, app_policy, app_helm_policy, failures)
  assert(failures.empty?, "TREK app-active state was rejected: #{failures.join('; ')}")

  invalid_cases = [
    ["preparation with active outer", Marshal.load(Marshal.dump(config_outer)), Marshal.load(Marshal.dump(package)), active_kustomizations, active_helm_releases],
    ["config-active with blocked outer", begin
      blocked_outer = Marshal.load(Marshal.dump(config_outer))
      blocked_outer["spec"]["suspend"] = true
      blocked_outer["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
      blocked_outer
    end, Marshal.load(Marshal.dump(package)), config_policy, config_helm_policy],
    ["app-active with blocked inner", config_outer, begin
      blocked_inner = Marshal.load(Marshal.dump(app_inner))
      blocked_inner["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
      blocked_inner
    end, app_policy, app_helm_policy],
    ["app-active under suspended outer", begin
      suspended_outer = Marshal.load(Marshal.dump(config_outer))
      suspended_outer["spec"]["suspend"] = true
      suspended_outer["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
      suspended_outer
    end, app_inner, app_policy, app_helm_policy],
    ["config-active with active inner", config_outer, app_inner, config_policy, config_helm_policy]
  ]
  invalid_cases.each do |label, outer, inner, kustomizations, helm_releases|
    failures = []
    validate_trek_stage_state!(label.start_with?("preparation") ? "preparation" : label.start_with?("config") ? "config-active" : "app-active", outer, inner, kustomizations, helm_releases, failures)
    assert(failures.any?, "TREK invalid state was accepted: #{label}")
  end
end

def write_yaml_stream(path, documents)
  File.write(path, YAML.dump_stream(*documents))
end

def build_trek_activation_fixture(root, stage, sabotage: nil)
  sync_path = File.join(root, "clusters/home/flux-system/sync.yaml")
  sync = YAML.load_stream(File.read(sync_path))
  trek_sync = sync.find { |resource| resource.dig("metadata", "name") == "trek" }
  trek_sync["spec"]["suspend"] = stage == "preparation"
  sync.each do |resource|
    if ["eso-config", "csi-secrets-store", "memos"].include?(resource.dig("metadata", "name"))
      resource["spec"]["suspend"] = true
    end
    if resource.dig("metadata", "name") == "memos"
      resource["metadata"]["annotations"] ||= {}
      resource["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
    end
  end
  csi_helm_path = File.join(root, "clusters/home/packages/csi-secrets-store/helmrelease.yaml")
  csi_helm = YAML.load_stream(File.read(csi_helm_path)).first
  csi_helm["spec"]["suspend"] = true
  write_yaml_stream(csi_helm_path, [csi_helm])
  trek_sync["metadata"]["annotations"] ||= {}
  if stage == "preparation"
    trek_sync["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
  else
    trek_sync["metadata"]["annotations"].delete("flux.takutk.com/activation-blocked")
  end
  write_yaml_stream(sync_path, sync)

  package_root = File.join(root, "clusters/home/packages/trek")
  namespace_path = File.join(package_root, "namespace.yaml")
  namespace = YAML.load_stream(File.read(namespace_path)).first
  if stage == "preparation"
    namespace["metadata"]["labels"]["flux.takutk.com/activation-blocked"] = "true"
    namespace["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
  else
    namespace["metadata"].delete("labels")
    namespace["metadata"].delete("annotations")
  end
  write_yaml_stream(namespace_path, [namespace])

  helm_path = File.join(package_root, "helmrelease.yaml")
  helm = YAML.load_stream(File.read(helm_path)).first
  helm["spec"]["suspend"] = stage != "app-active"
  helm["metadata"]["annotations"] ||= {}
  if stage == "app-active"
    helm["metadata"]["annotations"].delete("flux.takutk.com/activation-blocked")
  else
    helm["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
  end
  write_yaml_stream(helm_path, [helm])

  policy_path = File.join(root, ".github/manifest-policy.yaml")
  policy = YAML.safe_load(File.read(policy_path))
  policy["trekActivation"]["stage"] = stage
  if policy["memosActivation"]
    policy["memosActivation"]["stage"] = "preparation"
  end
  activation = policy.fetch("fluxActivation")
  activation["phase"] = "eso-controller"
  activation["activeKustomizations"] = activation["activeKustomizations"].select { |entry| entry["name"] == "eso-controller" }
  activation["activeHelmReleases"] = activation["activeHelmReleases"].select { |entry| entry["name"] == "external-secrets" }
  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek"
  activation["activeKustomizations"] << {
    "apiVersion" => "kustomize.toolkit.fluxcd.io/v1", "kind" => "Kustomization",
    "namespace" => "flux-system", "name" => "trek", "path" => "./clusters/home/packages/trek",
    "inventory" => [
      {"apiVersion" => "v1", "kind" => "Namespace", "namespace" => "", "name" => "trek"},
      {"apiVersion" => "external-secrets.io/v1beta1", "kind" => "ExternalSecret", "namespace" => "trek", "name" => "trek-secrets"},
      {"apiVersion" => "helm.toolkit.fluxcd.io/v2", "kind" => "HelmRelease", "namespace" => "trek", "name" => "trek"},
      {"apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "HelmRepository", "namespace" => "flux-system", "name" => "trek"}
    ]
  }
  activation["activeHelmReleases"] << {
    "apiVersion" => "helm.toolkit.fluxcd.io/v2", "kind" => "HelmRelease", "namespace" => "trek", "name" => "trek",
    "owner" => {"apiVersion" => "kustomize.toolkit.fluxcd.io/v1", "kind" => "Kustomization", "namespace" => "flux-system", "name" => "trek"},
    "chart" => {"name" => "trek", "version" => "4.2.1", "repository" => {"apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "HelmRepository", "namespace" => "flux-system", "name" => "trek", "url" => "https://chart.liketrek.com"}},
    "safety" => {"trekStage" => stage}
  }
  case sabotage
  when :unrelated_blocked
    secret = YAML.load_stream(File.read(File.join(package_root, "external-secret.yaml"))).first
    secret["metadata"]["annotations"] = {"flux.takutk.com/activation-blocked" => "true"}
    write_yaml_stream(File.join(package_root, "external-secret.yaml"), [secret])
  when :unapproved_suspended
    activation["activeHelmReleases"].reject! { |entry| entry["namespace"] == "trek" && entry["name"] == "trek" }
  when :inner_active_outer_suspended
    trek_sync["spec"]["suspend"] = true
    trek_sync["metadata"]["annotations"]["flux.takutk.com/activation-blocked"] = "true"
    write_yaml_stream(sync_path, sync)
    helm["spec"]["suspend"] = false
    helm["metadata"]["annotations"].delete("flux.takutk.com/activation-blocked")
    write_yaml_stream(helm_path, [helm])
  end
  write_yaml_stream(policy_path, [policy])

  components = File.read(File.join(root, "clusters/home/flux-system/gotk-components.yaml"))
  gotk_sync = File.read(File.join(root, "clusters/home/flux-system/gotk-sync.yaml"))
  File.write(File.join(root, "clusters/home/rendered.out"), "#{components}---\n#{gotk_sync}---\n#{File.read(sync_path)}")
  FileUtils.mkdir_p(File.join(root, ".flux-test"))
  File.write(File.join(root, ".flux-test/generated-components.yaml"), components)
  File.write(File.join(root, ".flux-test/flux"), "#!/usr/bin/env bash\nset -euo pipefail\ncat .flux-test/generated-components.yaml\n")
  FileUtils.chmod(0o755, File.join(root, ".flux-test/flux"))
  File.write(File.join(root, ".flux-test/curl"), "#!/usr/bin/env bash\nset -euo pipefail\nurl=\"${!#}\"\nexec ruby -ropen-uri -e 'STDOUT.binmode; STDOUT.write(URI.open(ARGV.fetch(0)).read)' \"$url\"\n")
  FileUtils.chmod(0o755, File.join(root, ".flux-test/curl"))
  [File.join(root, ".flux-test/flux"), File.join(root, ".flux-test/curl")]
end

def test_trek_production_activation_states
  validator = File.join(ROOT, "scripts/validate-flux-ownership.rb")
  %w[config-active app-active].each do |stage|
    Dir.mktmpdir("trek-production-#{stage}") do |temporary_root|
      fixture_root = File.join(temporary_root, "repo")
      FileUtils.cp_r(ROOT, fixture_root)
      flux_path, curl_path = build_trek_activation_fixture(fixture_root, stage)
      stdout, stderr, status = run_command("ruby", validator, fixture_root, env: {"FLUX_OWNERSHIP_FLUX" => flux_path, "FLUX_OWNERSHIP_CURL" => curl_path})
      assert(status.success?, "full TREK #{stage} fixture was rejected:\n#{stdout}\n#{stderr}")
      puts "TREK production #{stage} fixture passed."
    end
  end

  {
    unrelated_blocked: "unexpected activation-blocked marker",
    unapproved_suspended: "active HelmRelease policy must exactly match",
    inner_active_outer_suspended: "TREK outer Kustomization suspend state does not match stage"
  }.each do |sabotage, expected|
    Dir.mktmpdir("trek-production-sabotage") do |temporary_root|
      fixture_root = File.join(temporary_root, "repo")
      FileUtils.cp_r(ROOT, fixture_root)
      flux_path, curl_path = build_trek_activation_fixture(fixture_root, "config-active", sabotage: sabotage)
      stdout, stderr, status = run_command("ruby", validator, fixture_root, env: {"FLUX_OWNERSHIP_FLUX" => flux_path, "FLUX_OWNERSHIP_CURL" => curl_path})
      assert(!status.success?, "TREK sabotage was accepted: #{sabotage}\n#{stdout}\n#{stderr}")
      assert((stdout + stderr).include?(expected), "TREK sabotage #{sabotage} was not reported: #{expected}")
    end
  end
end


def test_mortis_preparation_contract
  package_root = File.join(ROOT, "clusters/home/packages/mortis")
  package_kustomization = YAML.safe_load(File.read(File.join(package_root, "kustomization.yaml")), permitted_classes: [], permitted_symbols: [], aliases: false)
  assert(package_kustomization["resources"] == ["mortis.yaml"], "Mortis package composition drifted")

  rendered, = assert_success("kubectl", "kustomize", package_root)
  resources = rendered.split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
  identities = resources.map { |resource| [resource["apiVersion"], resource["kind"], resource.dig("metadata", "namespace").to_s, resource.dig("metadata", "name")].join("/") }
  assert(identities == ["v1/Namespace//mortis", "v1/Service/mortis/mortis", "apps/v1/Deployment/mortis/mortis"], "Mortis package resource inventory drifted")

  deployment = resources.find { |resource| resource["kind"] == "Deployment" }
  container = deployment.dig("spec", "template", "spec", "containers", 0)
  assert(container["image"] == "ghcr.io/mudkipme/mortis:0.29.0", "Mortis image drifted")
  assert(container.dig("args", 2) == "-grpc-addr=memos.memos.svc.cluster.local:5230", "Mortis Memos dependency drifted")
  assert(deployment.dig("spec", "template", "spec", "volumes").nil?, "Mortis preparation unexpectedly gained volumes")
  assert(resources.none? { |resource| ["Secret", "PersistentVolume", "PersistentVolumeClaim"].include?(resource["kind"]) }, "Mortis package contains protected resource types")

  sync = File.read(File.join(ROOT, "clusters/home/flux-system/sync.yaml")).split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
  mortis = sync.find { |resource| resource.dig("metadata", "name") == "mortis" }
  assert(mortis, "Mortis Flux Kustomization is missing")
  assert(mortis.dig("spec", "path") == "./clusters/home/packages/mortis", "Mortis Flux path drifted")
  assert(mortis.dig("spec", "suspend") == true, "Mortis preparation must remain suspended")
  assert(mortis.dig("spec", "prune") == false, "Mortis preparation must keep prune:false")
end

def test_memos_preparation_contract
  package_root = File.join(ROOT, "clusters/home/packages/memos")
  package_kustomization = YAML.safe_load(File.read(File.join(package_root, "kustomization.yaml")), permitted_classes: [], permitted_symbols: [], aliases: false)
  assert(package_kustomization["resources"] == ["namespace.yaml", "helmrelease.yaml"], "Memos package composition drifted")

  helm = YAML.safe_load(File.read(File.join(package_root, "helmrelease.yaml")), permitted_classes: [], permitted_symbols: [], aliases: false)
  assert(helm.dig("spec", "suspend") == true, "Memos HelmRelease must remain suspended at config-active")
  assert(helm.dig("metadata", "annotations", "flux.takutk.com/activation-blocked") == "true", "Memos HelmRelease must stay activation-blocked at config-active")
  assert(helm.dig("spec", "chart", "spec", "chart") == "./apps/memos/chart", "Memos chart path drifted")
  assert(helm.dig("spec", "chart", "spec", "sourceRef") == {
    "kind" => "GitRepository",
    "name" => "flux-system",
    "namespace" => "flux-system"
  }, "Memos chart sourceRef drifted")
  assert(helm.dig("spec", "values", "image", "tag") == "0.29.0", "Memos image tag drifted")
  assert(helm.dig("spec", "values", "service", "type") == "LoadBalancer", "Memos service type drifted")
  assert(helm.dig("spec", "values", "service", "annotations", "metallb.io/loadBalancerIPs") == "192.168.11.209", "Memos MetalLB IP drifted")
  assert(helm.dig("spec", "values", "persistence", "enabled") == true, "Memos persistence drifted")
  assert(helm.dig("spec", "install", "disableTakeOwnership") == true, "Memos adopt flag drifted")

  rendered, = assert_success("kubectl", "kustomize", package_root)
  resources = rendered.split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
  identities = resources.map { |resource| [resource["apiVersion"], resource["kind"], resource.dig("metadata", "namespace").to_s, resource.dig("metadata", "name")].join("/") }
  assert(identities == ["v1/Namespace//memos", "helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos"], "Memos package resource inventory drifted")
  namespace = resources.find { |resource| resource["kind"] == "Namespace" }
  assert(namespace.dig("metadata", "labels", "flux.takutk.com/activation-blocked").nil?, "Memos Namespace activation label must be removed")
  assert(namespace.dig("metadata", "annotations", "flux.takutk.com/activation-blocked").nil?, "Memos Namespace activation annotation must be removed")

  sync = File.read(File.join(ROOT, "clusters/home/flux-system/sync.yaml")).split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
  memos = sync.find { |resource| resource.dig("metadata", "name") == "memos" }
  assert(memos, "Memos Flux Kustomization is missing")
  assert(memos.dig("spec", "path") == "./clusters/home/packages/memos", "Memos Flux path drifted")
  assert(memos.dig("spec", "suspend") == false, "Memos config-active outer Kustomization must run")
  assert(memos.dig("spec", "prune") == false, "Memos preparation must keep prune:false")
  assert(memos.dig("metadata", "annotations", "flux.takutk.com/activation-blocked").nil?, "Memos outer Kustomization marker must be removed at config-active")
end

test_mortis_preparation_contract
test_memos_preparation_contract
test_cumulative_activation_validation
test_trek_activation_and_render_contract
test_trek_production_activation_states
puts "Validation fixtures passed."
