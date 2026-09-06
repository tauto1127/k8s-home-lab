#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"
require "yaml"

require_relative "manifest-policy-helpers"

include ManifestPolicyHelpers

root = Pathname.new(File.expand_path(ARGV.fetch(0, File.expand_path("..", __dir__)))).realpath

def load_kustomization(path)
  YAML.safe_load(
    File.read(path),
    permitted_classes: [],
    permitted_symbols: [],
    aliases: true
  ) || {}
end

kustomizations = KUSTOMIZATION_FILENAMES.flat_map do |filename|
  Dir.glob(root.join("**", filename).to_s, File::FNM_DOTMATCH)
end.each_with_object([]) do |path, entries|
  pathname = Pathname.new(path)
  next if pathname.symlink?

  realpath = pathname.realpath
  next unless realpath.to_s.start_with?("#{root}/")

  entries << realpath
end.uniq.sort_by(&:to_s)
referenced_package_dirs = Set.new

kustomizations.each do |kustomization|
  document = load_kustomization(kustomization)
  base = kustomization.dirname
  Array(document["resources"]).concat(Array(document["components"])).concat(Array(document["bases"])).each do |resource|
    next unless resource.is_a?(String) && !resource.match?(%r{\Ahttps?://})

    expanded = base.join(resource).cleanpath
    next unless expanded.exist?

    realpath = expanded.realpath
    next unless realpath.to_s.start_with?("#{root}/")

    candidate = if expanded.directory?
                  nested = kustomization_in(expanded)
                  nested && Pathname.new(nested)
                else
                  expanded
                end
    next unless candidate && kustomization_file?(candidate) && candidate.file?

    referenced_package_dirs << candidate.dirname.realpath
  end
end

roots = kustomizations.reject { |kustomization| referenced_package_dirs.include?(kustomization.dirname) }

roots.each do |kustomization|
  puts kustomization.relative_path_from(root)
end
