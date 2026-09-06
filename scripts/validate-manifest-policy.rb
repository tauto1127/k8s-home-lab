#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"
require "digest"
require "open3"
require "uri"
require "yaml"

require_relative "manifest-policy-helpers"

include ManifestPolicyHelpers

ROOT = Pathname.new(File.expand_path("..", __dir__))
ROOT_REAL = ROOT.realpath
POLICY_PATH = ROOT.join(".github/manifest-policy.yaml")

Dir.chdir(ROOT)

def tracked_yaml_files
  output = IO.popen(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.yaml", "*.yml", "Kustomization"],
    &:read
  )

  output.split("\0").select { |path| File.file?(path) }.sort
end

def local_resource_paths(kustomization_path, failures, remote_resources)
  base = Pathname.new(kustomization_path).dirname
  document = load_yaml_stream(kustomization_path).first || {}

  local_paths = []
  resource_entries = %w[resources components bases].flat_map { |key| Array(document[key]) }
  resource_entries.each do |resource|
    unless resource.is_a?(String)
      failures << "#{kustomization_path}: Kustomize resource must be a path or URL string"
      next
    end

    if resource.match?(%r{\Ahttps?://})
      remote_resources << [kustomization_path, resource]
      next
    end

    expanded = ROOT.join(base, resource).cleanpath
    unless expanded.to_s.start_with?("#{ROOT}/")
      failures << "#{kustomization_path}: resource escapes the repository: #{resource}"
      next
    end

    unless expanded.exist?
      failures << "#{kustomization_path}: resource does not exist: #{resource}"
      next
    end

    if expanded.symlink? || !expanded.realpath.to_s.start_with?("#{ROOT_REAL}/")
      failures << "#{kustomization_path}: symlinked resource escapes policy checks: #{resource}"
      next
    end

    if expanded.directory?
      nested_kustomization = kustomization_in(expanded)
      unless nested_kustomization
        failures << "#{kustomization_path}: resource directory has no Kustomization: #{resource}"
        next
      end
      expanded = Pathname.new(nested_kustomization)
    end

    local_paths << expanded
  end

  patch_entries = []
  patch_entries.concat(Array(document["patches"]))
  patch_entries.concat(Array(document["patchesStrategicMerge"]))
  patch_entries.concat(Array(document["patchesJson6902"]))
  patch_entries.each do |patch|
    patch_path = patch.is_a?(Hash) ? patch["path"] : patch
    next unless patch_path.is_a?(String)

    if patch_path.match?(%r{\Ahttps?://})
      failures << "#{kustomization_path}: remote Kustomize patch is forbidden: #{patch_path}"
      next
    end

    expanded = ROOT.join(base, patch_path).cleanpath
    unless expanded.to_s.start_with?("#{ROOT}/")
      failures << "#{kustomization_path}: patch escapes the repository: #{patch_path}"
      next
    end

    unless expanded.file?
      failures << "#{kustomization_path}: patch does not exist or is not a file: #{patch_path}"
      next
    end

    if expanded.symlink? || !expanded.realpath.to_s.start_with?("#{ROOT_REAL}/")
      failures << "#{kustomization_path}: symlinked patch escapes policy checks: #{patch_path}"
      next
    end

    local_paths << expanded
  end

  local_paths
end

failures = []
policy_path = Pathname.new(ENV.fetch("MANIFEST_POLICY_PATH", POLICY_PATH.to_s))
policy = YAML.safe_load(
  File.read(policy_path),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
) || {}

remote_resources = Set.new

excluded = Set.new(Array(policy["excludedManifests"]).map { |entry| entry.fetch("path") })
migration_pending = Set.new(Array(policy["migrationPendingManifests"]).map { |entry| entry.fetch("path") })
floating_exceptions = Set.new(
  Array(policy["floatingImages"]).map { |entry| [entry.fetch("path"), entry.fetch("image")] }
)
cluster_admin_exceptions = Set.new(
  Array(policy["clusterAdminBindings"]).map { |entry| [entry.fetch("path"), entry.fetch("name")] }
)
remote_policy = Array(policy["remoteKustomizeResources"])

policy.values.flatten.each do |entry|
  next unless entry.is_a?(Hash)

  failures << "policy exception is missing a reason: #{entry.inspect}" if entry["reason"].to_s.strip.empty?
  if entry["path"] && !File.file?(entry["path"])
    failures << "policy exception references a missing path: #{entry['path']}"
  end
end

remote_policy.each do |entry|
  failures << "remote Kustomize policy entry is missing a URL" if entry["url"].to_s.strip.empty?
  failures << "remote Kustomize policy entry has an invalid SHA256" unless entry["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/i)
end

Array(policy["renderedSecretExceptions"]).each do |entry|
  %w[sourcePath namespace kind name].each do |field|
    failures << "rendered Secret exception is missing #{field}" if entry[field].to_s.strip.empty?
  end
  failures << "rendered Secret exception references a missing source path: #{entry['sourcePath']}" unless File.file?(entry["sourcePath"].to_s)
  unless Array(entry["allowedKeys"]).all? { |key| key.is_a?(String) && !key.empty? }
    failures << "rendered Secret exception has invalid allowedKeys for #{entry['sourcePath']}:#{entry['name']}"
  end
end

Array(policy["renderedClusterAdminBindings"]).each do |entry|
  %w[namespace kind name sha256 reason].each do |field|
    failures << "rendered cluster-admin exception is missing #{field}" if entry[field].to_s.strip.empty?
  end
  unless %w[RoleBinding ClusterRoleBinding].include?(entry["kind"])
    failures << "rendered cluster-admin exception has unsupported kind: #{entry['kind']}"
  end
end

yaml_files = tracked_yaml_files
documents = {}

yaml_files.each do |path|
  next if path.match?(%r{\Aapps/memos/chart/templates/})

  if File.symlink?(path)
    failures << "#{path}: symlinked YAML is forbidden"
    next
  end

  documents[path] = load_yaml_stream(path)
end

kustomized_resources = Set.new
yaml_files.select { |path| kustomization_file?(path) }.each do |path|
  local_resource_paths(path, failures, remote_resources).each do |resource_path|
    relative = resource_path.relative_path_from(ROOT).to_s
    kustomized_resources << relative if resource_path.file?
  end
end

remote_resources.each do |source_path, url|
  exception = remote_policy.find { |entry| entry["url"] == url }
  unless exception
    failures << "#{source_path}: remote Kustomize resource is not allowlisted: #{url}"
    next
  end

  uri = URI.parse(url)
  unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil?
    failures << "#{source_path}: remote Kustomize resource must use a host-verified HTTPS URL: #{url}"
    next
  end

  body, error, status = Open3.capture3(
    "curl", "--fail", "--silent", "--show-error", "--location",
    "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
    "--max-time", "30", "--", url
  )
  unless status.success?
    failures << "#{source_path}: remote Kustomize resource could not be fetched for checksum verification: #{url} (#{error.lines.first.to_s.strip})"
    next
  end

  actual_sha256 = Digest::SHA256.hexdigest(body)
  failures << "#{source_path}: remote Kustomize resource checksum mismatch: #{url}" unless actual_sha256 == exception["sha256"]
end

(excluded | migration_pending).each do |path|
  failures << "#{path}: excluded or migration-pending manifest is referenced by a package kustomization" if kustomized_resources.include?(path)
end

documents.each do |path, stream|
  repository_manifest = path.match?(%r{\A(?:apps|middlewares|pv)/})
  chart_input = path.match?(%r{/chart/(?:Chart|values)\.yaml\z})
  helmfile_input = File.basename(path) == "helmfile.yaml"
  kustomization_input = kustomization_file?(path)
  has_kubernetes_document = stream.any? do |document|
    document.is_a?(Hash) && document.key?("apiVersion") && document["kind"]
  end

  if repository_manifest && !chart_input && !helmfile_input && !kustomization_input && !has_kubernetes_document
    failures << "#{path}: YAML under a manifest tree is neither Kubernetes YAML nor an approved package input"
  end

  stream.each do |document|
    next unless document.is_a?(Hash)

    kind = document["kind"]
    kubernetes_manifest = document.key?("apiVersion") && kind

    if kubernetes_manifest && !package_kustomization?(path, document) && !excluded.include?(path) && !migration_pending.include?(path) && !kustomized_resources.include?(path)
      failures << "#{path}: Kubernetes manifest is not listed by a package kustomization"
    end

    each_mapping(document) do |mapping|
      next unless mapping["kind"] == "Secret" && mapping["apiVersion"]
      next unless mapping["data"].to_h.any? || mapping["stringData"].to_h.any?

      failures << "#{path}: literal Secret data is forbidden; use ExternalSecret"
    end

    each_sensitive_environment_literal(document) do |name, _value|
      failures << "#{path}: sensitive environment variable #{name} must use valueFrom"
    end

    each_container_image(document) do |image|
      next unless floating_image?(image)
      next if excluded.include?(path)
      next if floating_exceptions.include?([path, image])

      failures << "#{path}: floating container image is forbidden: #{image}"
    end

    next unless cluster_admin_binding?(document)

    name = document.dig("metadata", "name").to_s
    exception = Array(policy["clusterAdminBindings"]).find do |entry|
      entry["path"] == path && entry["name"] == name
    end
    unless exception && cluster_admin_exceptions.include?([path, name])
      failures << "#{path}: new cluster-admin binding is forbidden: #{name}"
      next
    end


    actual_hash = Digest::SHA256.file(path).hexdigest
    failures << "#{path}: approved cluster-admin binding changed" unless actual_hash == exception["sha256"]
  end

  next unless File.basename(path) == "helmfile.yaml"

  stream.each do |helmfile|
    Array(helmfile["releases"]).each do |release|
      chart = release["chart"].to_s
      next if chart.start_with?(".", "/")
      next unless release["version"].to_s.strip.empty?

      failures << "#{path}: Helm release #{release['name']} has no fixed chart version"
    end
  end
end

if failures.any?
  warn failures.sort.join("\n")
  exit 1
end

puts "Validated #{yaml_files.length} YAML files and #{kustomized_resources.length} local Kustomize resources."
