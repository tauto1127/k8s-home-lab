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

def run_command(*command, env: {})
  validator = command.any? { |part| part.to_s.end_with?("validate-flux-ownership.rb") }
  inherited = validator ? {
    "FLUX_OWNERSHIP_KUBECTL" => FAKE_KUBECTL,
    "FLUX_OWNERSHIP_CURL" => FAKE_CURL,
    "FLUX_OWNERSHIP_FLUX" => FAKE_FLUX
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

puts "Validation fixtures passed."
