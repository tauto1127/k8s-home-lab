#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"
require "yaml"
require "json"

ROOT = File.expand_path("..", __dir__)
POLICY_PATH = File.join(ROOT, ".github/manifest-policy.yaml")

policy = YAML.safe_load(
  File.read(ENV.fetch("MANIFEST_POLICY_PATH", POLICY_PATH)),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
) || {}

allowed = Set.new(
  Array(policy["allowedMissingSchemas"]).map do |entry|
    [entry.fetch("apiVersion"), entry.fetch("kind")]
  end
)

report = JSON.parse(File.read(ARGV.fetch(0)))
failures = []

Array(report["resources"]).each do |resource|
  next unless resource["status"] == "statusSkipped"

  api_version = resource["version"].to_s
  kind = resource["kind"].to_s
  next if allowed.include?([api_version, kind])

  failures << "#{resource['filename']}: missing schema is not allowlisted for #{api_version}/#{kind}"
end

if failures.any?
  warn failures.sort.uniq.join("\n")
  exit 1
end

summary = report["summary"] || {}
puts "Kubeconform schema policy passed (skipped=#{summary['skipped'] || 0})."
