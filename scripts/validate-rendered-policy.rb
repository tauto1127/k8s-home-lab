#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"
require "digest"
require "json"
require "yaml"

ROOT = Pathname.new(File.expand_path("..", __dir__))
POLICY_PATH = ROOT.join(".github/manifest-policy.yaml")

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

def floating_image?(image)
  return false if image.include?("@sha256:")

  last_segment = image.split("/").last
  return true unless last_segment.include?(":")

  %w[latest release].include?(last_segment.split(":", 2).last)
end

def deep_sort(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) { |key, sorted| sorted[key] = deep_sort(value[key]) }
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

render_root = Pathname.new(ARGV.fetch(0)).realpath
policy = YAML.safe_load(
  File.read(POLICY_PATH),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
) || {}

floating_exceptions = Set.new(
  Array(policy["renderedFloatingImages"]).map do |entry|
    [entry["namespace"], entry["kind"], entry["name"], entry["image"]]
  end
)
cluster_admin_exceptions = Set.new(
  Array(policy["renderedClusterAdminBindings"]).map do |entry|
    [entry["namespace"], entry["name"]]
  end
)

failures = []
resource_count = 0

Dir.glob(render_root.join("**/*.yaml")).sort.each do |path|
  load_yaml_stream(path).each do |document|
    next unless document.is_a?(Hash) && document["kind"]

    resource_count += 1
    namespace = document.dig("metadata", "namespace") || "default"
    kind = document["kind"]
    name = document.dig("metadata", "name").to_s

    each_container_image(document) do |image|
      next unless floating_image?(image)
      next if floating_exceptions.include?([namespace, kind, name, image])

      failures << "#{namespace}/#{kind}/#{name}: floating rendered image is forbidden: #{image}"
    end

    next unless kind == "ClusterRoleBinding" && document.dig("roleRef", "name") == "cluster-admin"
    exception = Array(policy["renderedClusterAdminBindings"]).find do |entry|
      entry["namespace"] == namespace && entry["name"] == name
    end
    unless exception && cluster_admin_exceptions.include?([namespace, name])
      failures << "#{kind}/#{name}: rendered cluster-admin binding is forbidden"
      next
    end

    binding = {"roleRef" => document["roleRef"], "subjects" => document["subjects"]}
    actual_hash = Digest::SHA256.hexdigest(JSON.generate(deep_sort(binding)))
    failures << "#{kind}/#{name}: approved rendered cluster-admin binding changed" unless actual_hash == exception["sha256"]
  end
end

if failures.any?
  warn failures.sort.uniq.join("\n")
  exit 1
end

puts "Validated policy for #{resource_count} rendered resources."
