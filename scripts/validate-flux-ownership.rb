#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "yaml"
require "set"

root = Pathname.new(ARGV.fetch(0, File.expand_path("..", __dir__))).realpath
failures = []

def yaml_documents(path)
  File.read(path).split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?

    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
rescue Psych::Exception => e
  raise "#{path}: YAML parse failed: #{e.message.lines.first.strip}"
end

def repository_path(root, path, description)
  unless path.exist?
    raise "#{description}: path is missing: #{path}"
  end

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
    if resolved.directory?
      package_files(root, resolved, seen)
    else
      [resolved]
    end
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

flux_files = root.join("clusters").glob("**/*.{yaml,yml,Kustomization}").select(&:file?)
flux_entries = flux_files.flat_map do |path|
  yaml_documents(path).filter_map do |doc|
    next unless doc.is_a?(Hash) && doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && doc["kind"] == "Kustomization"

    [repository_path(root, path, "Flux input"), doc]
  end
end
flux_kustomizations = flux_entries.map(&:last)
raise "no Flux Kustomizations found" if flux_kustomizations.empty?

seen_objects = {}
seen_flux_identities = {}
flux_entries.each do |source_path, resource|
  name = resource.dig("metadata", "name")
  namespace = resource.dig("metadata", "namespace").to_s
  unless name.is_a?(String) && !name.empty?
    raise "#{source_path}: Flux Kustomization is missing metadata.name"
  end
  flux_id = required_identity(resource, source_path.to_s)
  if seen_flux_identities.key?(flux_id)
    raise "duplicate Flux Kustomization #{flux_id}: #{seen_flux_identities[flux_id]} and #{source_path}"
  end
  seen_flux_identities[flux_id] = source_path

  spec = resource["spec"]
  raise "Flux Kustomization #{name}: spec is missing" unless spec.is_a?(Hash)
  failures << "Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
  failures << "Flux Kustomization #{name}: suspend must be true" unless spec["suspend"] == true

  source_ref = spec["sourceRef"]
  if source_ref
    failures << "Flux Kustomization #{name}: sourceRef.kind must be GitRepository" unless source_ref["kind"] == "GitRepository"
    failures << "Flux Kustomization #{name}: sourceRef.name is required" unless source_ref["name"].is_a?(String) && !source_ref["name"].empty?
    if source_ref["namespace"] && source_ref["namespace"] != namespace
      failures << "Flux Kustomization #{name}: sourceRef.namespace must match metadata.namespace"
    end
  end
  Array(spec["dependsOn"]).each do |dependency|
    unless dependency.is_a?(Hash) && dependency["name"].is_a?(String) && !dependency["name"].empty?
      failures << "Flux Kustomization #{name}: dependsOn entries require name"
    end
    if dependency.is_a?(Hash) && dependency["namespace"] && dependency["namespace"] != namespace
      failures << "Flux Kustomization #{name}: dependsOn.namespace must match metadata.namespace"
    end
  end

  path_value = spec["path"]
  raise "Flux Kustomization #{name}: spec.path is required" unless path_value.is_a?(String) && !path_value.empty?
  package_dir = root.join(path_value.sub(%r{\A\./}, "")).cleanpath
  package_files(root, package_dir).each do |path|
    yaml_documents(path).each do |document|
      resource_documents(document).each do |doc|
        next unless doc.is_a?(Hash)

        id = required_identity(doc, path.to_s)
        if seen_objects.key?(id)
          previous_owner, previous_path = seen_objects[id]
          raise "duplicate Flux-owned object #{id}: owner #{previous_owner} source #{previous_path}; owner #{name} source #{path}"
        end
        seen_objects[id] = [name, path]
        if doc["kind"] == "HelmRelease"
          failures << "HelmRelease #{id}: suspend must be true" unless doc.dig("spec", "suspend") == true
        end
      end
    end
  end
end

if failures.any?
  warn failures.sort.join("\n")
  exit 1
end

puts "Validated #{flux_kustomizations.length} Flux Kustomizations and #{seen_objects.length} unique declared objects."
