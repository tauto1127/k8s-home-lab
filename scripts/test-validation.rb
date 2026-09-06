#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(__dir__, "fixtures")
FAKE_KUBECTL_DIR = Dir.mktmpdir("flux-ownership-kubectl")
FAKE_KUBECTL = File.join(FAKE_KUBECTL_DIR, "kubectl")
FAKE_CURL = File.join(FAKE_KUBECTL_DIR, "curl")
FIXTURE_INSTALL_ASSET = "fixture Flux install asset v2.9.3\n"
FIXTURE_SCHEMA_ASSET = "fixture Flux schema asset v2.9.3\n"
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
File.write(FAKE_CURL, <<~'SH')
  #!/usr/bin/env bash
  set -euo pipefail
  url="${!#}"
  case "$url" in
    https://github.com/fluxcd/flux2/releases/download/v2.9.3/install.yaml)
      printf '%s\n' 'fixture Flux install asset v2.9.3'
      ;;
    https://github.com/fluxcd/flux2/releases/download/v2.9.3/crd-schemas.tar.gz)
      printf '%s\n' 'fixture Flux schema asset v2.9.3'
      ;;
    *)
      exit 22
      ;;
  esac
SH
FileUtils.chmod(0o755, FAKE_CURL)

def run_command(*command, env: {})
  validator = command.any? { |part| part.to_s.end_with?("validate-flux-ownership.rb") }
  inherited = validator ? {"FLUX_OWNERSHIP_KUBECTL" => FAKE_KUBECTL, "FLUX_OWNERSHIP_CURL" => FAKE_CURL} : {}
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

Dir.mktmpdir("flux-render-and-gate-validation-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "clusters/flux"))
  FileUtils.mkdir_p(File.join(temporary_root, ".github"))
  File.write(File.join(temporary_root, ".github/manifest-policy.yaml"), "bootstrapManagedSources:\n  - apiVersion: source.toolkit.fluxcd.io/v1\n    kind: GitRepository\n    namespace: flux-system\n    name: flux-system\n")
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

  File.write(package_sync_path, original_package_sync.sub("suspend: true", "suspend: false"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization app: suspend must be true"), "active workload Kustomization was accepted")
  File.write(package_sync_path, original_package_sync.sub("prune: false", "prune: true"))
  stdout, stderr = assert_failure("ruby", validator, temporary_root)
  assert((stdout + stderr).include?("Flux Kustomization app: prune must be false"), "pruning workload Kustomization was accepted")
  File.write(package_sync_path, original_package_sync)

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
