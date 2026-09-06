#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "yaml"
require "set"

root = Pathname.new(ARGV.fetch(0, File.expand_path("..", __dir__))).realpath
failures = []

BOOTSTRAP_SOURCE_POLICY_KEY = "bootstrapManagedSources"
ACTIVATION_BLOCKED = "flux.takuto.dev/activation-blocked"

def yaml_documents(path)
  File.read(path).split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
rescue Psych::Exception => e
  raise "#{path}: YAML parse failed: #{e.message.lines.first.strip}"
end

def repository_path(root, path, description)
  raise "#{description}: path is missing: #{path}" unless path.exist?
  resolved = Pathname.new(File.realpath(path.to_s))
  relative = resolved.relative_path_from(root)
  if relative.absolute? || relative.to_s == ".." || relative.to_s.start_with?("..#{File::SEPARATOR}")
    raise "#{description}: path escapes repository: #{path}"
  end
  resolved
rescue Errno::ENOENT
  raise "#{description}: path is missing: #{path}"
end

def package_files(root, package_dir, seen = Set.new)
  package_dir = repository_path(root, package_dir, "package")
  kustomization_names = %w[kustomization.yaml kustomization.yml Kustomization]
  kustomization = kustomization_names.map { |name| package_dir.join(name) }.find(&:file?)
  raise "#{package_dir}: package Kustomization not found" unless kustomization
  kustomization = repository_path(root, kustomization, "package Kustomization")
  return [] if seen.include?(kustomization.to_s)
  seen << kustomization.to_s
  document = yaml_documents(kustomization).first || {}
  Array(document["resources"]).flat_map do |entry|
    path = package_dir.join(entry.to_s).cleanpath
    resolved = repository_path(root, path, "#{kustomization}: resource #{entry}")
    resolved.directory? ? package_files(root, resolved, seen) : [resolved]
  end
end

def resource_documents(document)
  return [] unless document.is_a?(Hash)
  return [document] unless document["kind"] == "List" && document["items"].is_a?(Array)
  document["items"].flat_map { |item| resource_documents(item) }
end

def required_identity(document, source)
  metadata = document["metadata"]
  unless document["apiVersion"].is_a?(String) && !document["apiVersion"].empty? &&
         document["kind"].is_a?(String) && !document["kind"].empty? &&
         metadata.is_a?(Hash) && metadata["name"].is_a?(String) && !metadata["name"].empty?
    raise "#{source}: resource is missing apiVersion, kind, or metadata.name"
  end
  [document["apiVersion"], document["kind"], metadata["namespace"].to_s, metadata["name"]].join("/")
end

def namespaced_identity(kind, namespace, name)
  [kind, namespace.to_s, name].join("/")
end

policy_path = root.join(".github/manifest-policy.yaml")
policy = if policy_path.file?
           YAML.safe_load(File.read(policy_path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
         else
           {BOOTSTRAP_SOURCE_POLICY_KEY => [{"apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "GitRepository", "namespace" => "flux-system", "name" => "flux-system"}]}
         end
allowed_bootstrap_sources = Set.new(Array(policy[BOOTSTRAP_SOURCE_POLICY_KEY]).map do |entry|
  [entry.fetch("apiVersion"), entry.fetch("kind"), entry.fetch("namespace").to_s, entry.fetch("name")].join("/")
end)

flux_files = root.join("clusters").glob("**/*.{yaml,yml,Kustomization}").select(&:file?)
flux_entries = flux_files.flat_map do |path|
  yaml_documents(path).filter_map do |doc|
    next unless doc.is_a?(Hash) && doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && doc["kind"] == "Kustomization"
    [repository_path(root, path, "Flux input"), doc]
  end
end
raise "no Flux Kustomizations found" if flux_entries.empty?

seen_objects = {}
seen_flux_identities = {}
flux_by_identity = {}
package_objects = {}

flux_entries.each do |source_path, resource|
  name = resource.dig("metadata", "name")
  namespace = resource.dig("metadata", "namespace").to_s
  raise "#{source_path}: Flux Kustomization is missing metadata.name" unless name.is_a?(String) && !name.empty?
  flux_id = required_identity(resource, source_path.to_s)
  raise "duplicate Flux Kustomization #{flux_id}: #{seen_flux_identities[flux_id]} and #{source_path}" if seen_flux_identities.key?(flux_id)
  seen_flux_identities[flux_id] = source_path
  flux_by_identity[namespaced_identity("Kustomization", namespace, name)] = resource

  spec = resource["spec"]
  raise "Flux Kustomization #{name}: spec is missing" unless spec.is_a?(Hash)
  failures << "Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
  failures << "Flux Kustomization #{name}: suspend must be true" unless spec["suspend"] == true
  source_ref = spec["sourceRef"]
  unless source_ref.is_a?(Hash)
    failures << "Flux Kustomization #{name}: sourceRef is required"
  else
    failures << "Flux Kustomization #{name}: sourceRef.kind must be GitRepository" unless source_ref["kind"] == "GitRepository"
    failures << "Flux Kustomization #{name}: sourceRef.name is required" unless source_ref["name"].is_a?(String) && !source_ref["name"].empty?
    source_namespace = source_ref["namespace"] || namespace
    failures << "Flux Kustomization #{name}: sourceRef.namespace must match metadata.namespace" if source_ref["namespace"] && source_ref["namespace"] != namespace
    source_id = ["source.toolkit.fluxcd.io/v1", source_ref["kind"], source_namespace.to_s, source_ref["name"]].join("/")
    failures << "Flux Kustomization #{name}: GitRepository sourceRef is neither declared nor explicitly allowlisted: #{source_id}" unless allowed_bootstrap_sources.include?(source_id)
  end
  Array(spec["dependsOn"]).each do |dependency|
    unless dependency.is_a?(Hash) && dependency["name"].is_a?(String) && !dependency["name"].empty?
      failures << "Flux Kustomization #{name}: dependsOn entries require name"
      next
    end
    dep_namespace = dependency["namespace"] || namespace
    failures << "Flux Kustomization #{name}: dependsOn.namespace must match metadata.namespace" if dependency["namespace"] && dependency["namespace"] != namespace
    dep_id = namespaced_identity("Kustomization", dep_namespace, dependency["name"])
    failures << "Flux Kustomization #{name}: unknown dependency #{dep_id}" unless flux_by_identity.key?(dep_id)
  end

  path_value = spec["path"]
  raise "Flux Kustomization #{name}: spec.path is required" unless path_value.is_a?(String) && !path_value.empty?
  package_dir = root.join(path_value.sub(%r{\A\./}, "")).cleanpath
  package_objects[name] = package_files(root, package_dir).flat_map do |path|
    yaml_documents(path).flat_map { |document| resource_documents(document).map { |doc| [path, doc] } }
  end
end

# Dependency graph is checked after all Flux identities are known.
flux_entries.each do |_path, resource|
  name = resource.dig("metadata", "name")
  namespace = resource.dig("metadata", "namespace").to_s
  node = namespaced_identity("Kustomization", namespace, name)
  Array(resource.dig("spec", "dependsOn")).each do |dependency|
    next unless dependency.is_a?(Hash) && dependency["name"]
    dep_namespace = dependency["namespace"] || namespace
    flux_by_identity[node] ||= resource
    resource["__dep_ids"] ||= []
    resource["__dep_ids"] << namespaced_identity("Kustomization", dep_namespace, dependency["name"])
  end
end
visiting = Set.new
visited = Set.new
walk = lambda do |node|
  if visiting.include?(node)
    failures << "Flux Kustomization dependency cycle detected at #{node}"
    next
  end
  next if visited.include?(node)
  visiting << node
  Array(flux_by_identity[node].to_h["__dep_ids"]).each { |dep| walk.call(dep) }
  visiting.delete(node)
  visited << node
end
flux_by_identity.each_key { |node| walk.call(node) }

seen_objects = {}
package_objects.each do |owner, entries|
  entries.each do |path, doc|
    next unless doc.is_a?(Hash)
    id = required_identity(doc, path.to_s)
    if seen_objects.key?(id)
      previous_owner, previous_path = seen_objects[id]
      raise "duplicate Flux-owned object #{id}: owner #{previous_owner} source #{previous_path}; owner #{owner} source #{path}"
    end
    seen_objects[id] = [owner, path]
    if doc["kind"] == "HelmRelease"
      failures << "HelmRelease #{id}: suspend must be true" unless doc.dig("spec", "suspend") == true
      chart_ref = doc.dig("spec", "chart", "spec", "sourceRef")
      if !chart_ref.is_a?(Hash) || chart_ref["kind"] != "HelmRepository" || chart_ref["name"].to_s.empty?
        failures << "HelmRelease #{id}: chart.spec.sourceRef HelmRepository is required"
      else
        ref_ns = chart_ref["namespace"] || doc.dig("metadata", "namespace").to_s
        repo_id = ["source.toolkit.fluxcd.io/v1", "HelmRepository", ref_ns.to_s, chart_ref["name"]].join("/")
        failures << "HelmRelease #{id}: HelmRepository sourceRef is missing or mismatched: #{repo_id}" unless seen_objects.key?(repo_id)
      end
    end
  end
end

# Nextcloud is fail-closed until full release parity is independently proven.
package_objects.values.flatten.each do |path, doc|
  next unless doc.is_a?(Hash) && ["HelmRelease", "Kustomization"].include?(doc["kind"]) && doc.dig("metadata", "name") == "nextcloud"
  annotation = doc.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  failures << "Nextcloud #{required_identity(doc, path.to_s)}: activation-blocked annotation must be true" unless annotation == "true"
end

if failures.any?
  warn failures.sort.uniq.join("\n")
  exit 1
end

puts "Validated #{flux_entries.length} Flux Kustomizations and #{seen_objects.length} unique declared objects."
