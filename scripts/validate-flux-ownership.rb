#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "yaml"
require "set"

root = Pathname.new(ARGV.fetch(0, File.expand_path("..", __dir__))).realpath
failures = []

def yaml_documents(path)
  YAML.load_stream(File.read(path), permitted_classes: [], aliases: false).compact
rescue Psych::Exception => e
  raise "#{path}: YAML parse failed: #{e.message.lines.first.strip}"
end

def package_files(root, package_dir, seen = Set.new)
  kustomization = %w[kustomization.yaml kustomization.yml Kustomization]
    .map { |name| package_dir.join(name) }.find(&:file?)
  raise "#{package_dir}: package Kustomization not found" unless kustomization
  return [] if seen.include?(kustomization.to_s)

  seen << kustomization.to_s
  document = yaml_documents(kustomization).first || {}
  Array(document["resources"]).flat_map do |entry|
    path = package_dir.join(entry.to_s).cleanpath
    unless path.to_s.start_with?("#{root}/") && path.exist?
      raise "#{kustomization}: resource is missing or escapes repository: #{entry}"
    end
    if path.directory?
      package_files(root, path, seen)
    else
      [path]
    end
  end
end

flux_files = root.join("clusters").glob("**/*.{yaml,yml,Kustomization}").select(&:file?)
flux_kustomizations = flux_files.flat_map { |path| yaml_documents(path).select { |doc|
  doc.is_a?(Hash) && doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && doc["kind"] == "Kustomization"
} }
raise "no Flux Kustomizations found" if flux_kustomizations.empty?

seen_objects = {}
flux_kustomizations.each do |resource|
  name = resource.dig("metadata", "name").to_s
  spec = resource["spec"] || {}
  failures << "Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
  failures << "Flux Kustomization #{name}: suspend must be true" unless spec["suspend"] == true
  package_dir = root.join(spec.fetch("path").sub(%r{\A\./}, "")).cleanpath
  package_files(root, package_dir).each do |path|
    yaml_documents(path).each do |doc|
      next unless doc.is_a?(Hash) && doc["apiVersion"] && doc["kind"]
      namespace = doc.dig("metadata", "namespace").to_s
      id = [doc["apiVersion"], doc["kind"], namespace, doc.dig("metadata", "name").to_s].join("/")
      previous = seen_objects[id]
      failures << "duplicate Flux-owned object #{id}: #{previous} and #{name}" if previous && previous != name
      seen_objects[id] ||= name
      if doc["kind"] == "HelmRelease"
        failures << "HelmRelease #{id}: suspend must be true" unless doc.dig("spec", "suspend") == true
      end
    end
  end
end

if failures.any?
  warn failures.sort.join("\n")
  exit 1
end

puts "Validated #{flux_kustomizations.length} Flux Kustomizations and #{seen_objects.length} unique declared objects."
