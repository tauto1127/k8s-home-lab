#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FIXTURES = File.join(__dir__, "fixtures")

def run_command(*command, env: {})
  Open3.capture3(env, *command, chdir: ROOT)
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
  assert(!status.success?, "expected failure: #{command.join(' ')}")
  [stdout, stderr]
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

puts "Validation fixtures passed."
