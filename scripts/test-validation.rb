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

assert_success("ruby", "scripts/validate-kubeconform-policy.rb", File.join(FIXTURES, "kubeconform/allowed-schema.json"))
stdout, stderr = assert_failure("ruby", "scripts/validate-kubeconform-policy.rb", File.join(FIXTURES, "kubeconform/unknown-schema.json"))
assert((stdout + stderr).include?("apps/v999/Deployment"), "unknown apiVersion/kind was not rejected")

Dir.mktmpdir("kustomization-roots-test") do |temporary_root|
  FileUtils.mkdir_p(File.join(temporary_root, "parent/child"))
  FileUtils.mkdir_p(File.join(temporary_root, "standalone"))
  FileUtils.mkdir_p(File.join(temporary_root, "alternate"))
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
  stdout, stderr, status = run_command("ruby", "scripts/discover-kustomization-roots.rb", temporary_root)
  assert(status.success?, "kustomization root discovery failed: #{stderr}")
  roots = stdout.lines.map(&:chomp)
  assert(
    roots == ["alternate/kustomization.yml", "parent/kustomization.yaml", "standalone/kustomization.yaml"],
    "Kustomization variants or nested package discovery are incorrect: #{roots.inspect}"
  )
end

puts "Validation fixtures passed."
