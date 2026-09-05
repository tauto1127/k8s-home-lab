#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"
require "digest"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__))
ROOT_REAL = ROOT.realpath
POLICY_PATH = ROOT.join(".github/manifest-policy.yaml")

Dir.chdir(ROOT)

def load_yaml_stream(path)
  File.read(path).split(/^---[ \t]*(?:#.*)?$\n?/).each_with_object([]) do |document, parsed|
    next if document.strip.empty?

    value = YAML.safe_load(
      document,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: true
    )
    parsed << value if value
  end
rescue Psych::Exception => e
  raise "#{path}: YAML parse failed: #{e.message.lines.first.strip}"
end

def tracked_yaml_files
  output = IO.popen(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.yaml", "*.yml"],
    &:read
  )

  output.split("\0").select { |path| File.file?(path) }.sort
end

def local_resource_paths(kustomization_path, failures)
  base = Pathname.new(kustomization_path).dirname
  document = load_yaml_stream(kustomization_path).first || {}

  Array(document["resources"]).each_with_object([]) do |resource, paths|
    next if resource.match?(%r{\Ahttps?://})

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

    paths << (expanded.directory? ? expanded.join("kustomization.yaml") : expanded)
  end
end

def each_container_image(value, &block)
  case value
  when Hash
    %w[containers initContainers ephemeralContainers].each do |key|
      Array(value[key]).each do |container|
        block.call(container["image"]) if container.is_a?(Hash) && container["image"]
      end
    end
    value.each_value { |child| each_container_image(child, &block) }
  when Array
    value.each { |child| each_container_image(child, &block) }
  end
end

def each_mapping(value, &block)
  case value
  when Hash
    block.call(value)
    value.each_value { |child| each_mapping(child, &block) }
  when Array
    value.each { |child| each_mapping(child, &block) }
  end
end

def sensitive_environment_name?(name)
  name.to_s.match?(/(?:password|passwd|token|api_?key|private_?key|encryption_?key)\z/i)
end

def floating_image?(image)
  return false if image.include?("@sha256:")

  last_segment = image.split("/").last
  return true unless last_segment.include?(":")

  %w[latest release].include?(last_segment.split(":", 2).last)
end

failures = []
policy = YAML.safe_load(
  File.read(POLICY_PATH),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
) || {}

excluded = Set.new(Array(policy["excludedManifests"]).map { |entry| entry.fetch("path") })
migration_pending = Set.new(Array(policy["migrationPendingManifests"]).map { |entry| entry.fetch("path") })
floating_exceptions = Set.new(
  Array(policy["floatingImages"]).map { |entry| [entry.fetch("path"), entry.fetch("image")] }
)
cluster_admin_exceptions = Set.new(
  Array(policy["clusterAdminBindings"]).map { |entry| [entry.fetch("path"), entry.fetch("name")] }
)

policy.values.flatten.each do |entry|
  next unless entry.is_a?(Hash)

  failures << "policy exception is missing a reason: #{entry.inspect}" if entry["reason"].to_s.strip.empty?
  if entry["path"] && !File.file?(entry["path"])
    failures << "policy exception references a missing path: #{entry['path']}"
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
yaml_files.grep(%r{(?:\A|/)kustomization\.yaml\z}).each do |path|
  local_resource_paths(path, failures).each do |resource_path|
    relative = resource_path.relative_path_from(ROOT).to_s
    kustomized_resources << relative if resource_path.file?
  end
end

(excluded | migration_pending).each do |path|
  failures << "#{path}: excluded or migration-pending manifest is referenced by a package kustomization" if kustomized_resources.include?(path)
end

documents.each do |path, stream|
  repository_manifest = path.match?(%r{\A(?:apps|middlewares|pv)/})
  chart_input = path.match?(%r{/chart/(?:Chart|values)\.yaml\z})
  helmfile_input = File.basename(path) == "helmfile.yaml"
  kustomization_input = File.basename(path) == "kustomization.yaml"
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

    if kubernetes_manifest && kind != "Kustomization" && !excluded.include?(path) && !migration_pending.include?(path) && !kustomized_resources.include?(path)
      failures << "#{path}: Kubernetes manifest is not listed by a package kustomization"
    end

    each_mapping(document) do |mapping|
      next unless mapping["kind"] == "Secret" && mapping["apiVersion"]
      next unless mapping["data"].to_h.any? || mapping["stringData"].to_h.any?

      failures << "#{path}: literal Secret data is forbidden; use ExternalSecret"
    end

    each_mapping(document) do |mapping|
      next unless sensitive_environment_name?(mapping["name"])
      next unless mapping.key?("value") && !mapping["value"].to_s.empty?

      failures << "#{path}: sensitive environment variable #{mapping['name']} must use valueFrom"
    end

    each_container_image(document) do |image|
      next unless floating_image?(image)
      next if excluded.include?(path)
      next if floating_exceptions.include?([path, image])

      failures << "#{path}: floating container image is forbidden: #{image}"
    end

    next unless kind == "ClusterRoleBinding" && document.dig("roleRef", "name") == "cluster-admin"

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
