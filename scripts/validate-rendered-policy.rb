#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"
require "digest"
require "fileutils"
require "json"
require "yaml"

require_relative "manifest-policy-helpers"

include ManifestPolicyHelpers

ROOT = Pathname.new(File.expand_path("..", __dir__))
POLICY_PATH = ROOT.join(".github/manifest-policy.yaml")

render_root = Pathname.new(ARGV.fetch(0)).realpath
source_map_path = ARGV[1]
sanitized_root = ARGV[2] && Pathname.new(ARGV[2]).expand_path
source_map = {}
if source_map_path
  File.foreach(source_map_path) do |line|
    relative_path, source_path = line.chomp.split("\t", 2)
    source_map[relative_path] = source_path if relative_path && source_path
  end
end

policy = YAML.safe_load(
  File.read(ENV.fetch("MANIFEST_POLICY_PATH", POLICY_PATH.to_s)),
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
    [entry["namespace"], entry["kind"], entry["name"]]
  end
)
secret_exceptions = Array(policy["renderedSecretExceptions"])

failures = []
resource_count = 0

Dir.glob(render_root.join("**/*.yaml")).sort.each do |path|
  relative_path = Pathname.new(path).relative_path_from(render_root).to_s
  source_path = source_map[relative_path]
  stream = load_yaml_stream(path)
  sanitized_stream = Marshal.load(Marshal.dump(stream))

  stream.each_with_index do |document, document_index|
    next unless document.is_a?(Hash) && document["kind"]

    resource_count += 1
    namespace = document.dig("metadata", "namespace") || "default"
    kind = document["kind"]
    name = document.dig("metadata", "name").to_s

    each_sensitive_environment_literal(document) do |env_name, _value|
      failures << "#{source_path || relative_path}: sensitive rendered environment variable #{env_name} must use valueFrom"
    end

    if document["kind"] == "Secret" && (document["data"].to_h.any? || document["stringData"].to_h.any?)
      literal_keys = (document["data"].to_h.keys + document["stringData"].to_h.keys).map(&:to_s).uniq
      exception = secret_exceptions.find do |entry|
        entry["sourcePath"] == source_path &&
          entry["namespace"].to_s == namespace.to_s &&
          entry["kind"] == document["kind"] &&
          entry["name"] == name
      end
      allowed_keys = Array(exception && exception["allowedKeys"]).map(&:to_s)
      unexpected_keys = literal_keys - allowed_keys
      if exception.nil? || unexpected_keys.any?
        suffix = unexpected_keys.empty? ? "" : ": unexpected keys #{unexpected_keys.join(', ')}"
        failures << "#{source_path || relative_path}: literal rendered Secret is forbidden for #{namespace}/#{document['kind']}/#{name}#{suffix}"
      elsif sanitized_root
        sanitized_document = sanitized_stream.fetch(document_index)
        %w[data stringData].each do |field|
          sanitized_document[field].to_h.each_key do |key|
            sanitized_document[field][key] = "REDACTED" if allowed_keys.include?(key.to_s)
          end
        end
      end
    end

    each_container_image(document) do |image|
      next unless floating_image?(image)
      next if floating_exceptions.include?([namespace, kind, name, image])

      failures << "#{namespace}/#{kind}/#{name}: floating rendered image is forbidden: #{image}"
    end

    next unless cluster_admin_binding?(document)
    exception = Array(policy["renderedClusterAdminBindings"]).find do |entry|
      entry["namespace"] == namespace && entry["kind"] == kind && entry["name"] == name
    end
    unless exception && cluster_admin_exceptions.include?([namespace, kind, name])
      failures << "#{kind}/#{name}: rendered cluster-admin binding is forbidden"
      next
    end

    binding = {"roleRef" => document["roleRef"], "subjects" => document["subjects"]}
    actual_hash = Digest::SHA256.hexdigest(JSON.generate(deep_sort(binding)))
    failures << "#{kind}/#{name}: approved rendered cluster-admin binding changed" unless actual_hash == exception["sha256"]
  end

  next unless sanitized_root

  sanitized_path = sanitized_root.join(relative_path)
  FileUtils.mkdir_p(sanitized_path.dirname)
  File.write(sanitized_path, sanitized_stream.map { |document| YAML.dump(document) }.join)
end

if failures.any?
  warn failures.sort.uniq.join("\n")
  exit 1
end

puts "Validated policy for #{resource_count} rendered resources."
