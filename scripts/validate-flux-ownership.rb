#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "set"
require "digest"
require "yaml"

root = Pathname.new(ARGV.fetch(0, File.expand_path("..", __dir__))).realpath
failures = []

BOOTSTRAP_SOURCE_POLICY_KEY = "bootstrapManagedSources"
FLUX_BOOTSTRAP_POLICY_KEY = "fluxBootstrap"
ACTIVATION_BLOCKED = "flux.takutk.com/activation-blocked"
KUBECTL = ENV.fetch("FLUX_OWNERSHIP_KUBECTL", "kubectl")
KUSTOMIZATION_FILENAMES = %w[kustomization.yaml kustomization.yml Kustomization].freeze
EXPECTED_BOOTSTRAP_SOURCE = {
  "apiVersion" => "source.toolkit.fluxcd.io/v1",
  "kind" => "GitRepository",
  "namespace" => "flux-system",
  "name" => "flux-system",
  "url" => "https://github.com/tauto1127/k8s-home-lab",
  "branch" => "main"
}.freeze
EXPECTED_BOOTSTRAP_ROOT = {
  "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
  "kind" => "Kustomization",
  "namespace" => "flux-system",
  "name" => "flux-system",
  "path" => "./clusters/home",
  "prune" => false
}.freeze

# Parse the YAML stream without permitting Ruby objects or aliases.
def yaml_documents(content, source)
  content.split(/^---[ \t]*(?:#.*)?$\n?/).filter_map do |document|
    next if document.strip.empty?
    YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
  end
rescue Psych::Exception => e
  raise "#{source}: YAML parse failed: #{e.message.lines.first.strip}"
end

def yaml_file_documents(path)
  yaml_documents(File.read(path), path.to_s)
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

def render_package(root, package_dir, owner)
  package_dir = repository_path(root, package_dir, "package")
  stdout, _stderr, status = Open3.capture3(KUBECTL, "kustomize", package_dir.to_s, chdir: root.to_s)
  raise "Flux Kustomization #{owner}: Kustomize render failed" unless status.success?
  raise "Flux Kustomization #{owner}: Kustomize render was empty" if stdout.strip.empty?
  yaml_documents(stdout, "rendered package #{package_dir}").flat_map { |document| resource_documents(document).map { |doc| [package_dir, doc] } }
rescue Errno::ENOENT
  raise "Flux Kustomization #{owner}: Kustomize renderer is unavailable (#{KUBECTL})"
end

def kustomization_file_in(directory)
  KUSTOMIZATION_FILENAMES.map { |name| directory.join(name) }.find(&:file?)
end

def validate_kustomize_composition!(root, package_dir)
  visiting = Set.new
  visited = Set.new
  walk = lambda do |directory|
    directory = repository_path(root, directory, "Kustomize composition")
    return if visited.include?(directory)
    raise "Kustomize composition cycle detected at #{directory.relative_path_from(root)}" if visiting.include?(directory)

    kustomization = kustomization_file_in(directory)
    raise "Kustomize composition has no Kustomization at #{directory.relative_path_from(root)}" unless kustomization

    visiting << directory
    document = yaml_file_documents(kustomization).first || {}
    %w[resources components bases].flat_map { |key| Array(document[key]) }.each do |resource|
      next unless resource.is_a?(String)
      next if resource.match?(%r{\Ahttps?://})

      target = directory.join(resource).cleanpath
      next unless target.directory?

      walk.call(target)
    end
    visiting.delete(directory)
    visited << directory
  end
  walk.call(package_dir)
end

def policy_identity(entry, description)
  raise "#{description} must be a mapping" unless entry.is_a?(Hash)
  %w[apiVersion kind namespace name].each do |field|
    raise "#{description}.#{field} is required" if entry[field].to_s.empty?
  end
  [entry["apiVersion"], entry["kind"], entry["namespace"].to_s, entry["name"]].join("/")
end

def component_inventory(documents)
  inventory = {
    "controllers" => {},
    "crds" => Set.new,
    "clusterRoles" => Set.new,
    "clusterRoleBindings" => Set.new
  }

  documents.each do |document|
    resource_documents(document).each do |resource|
      next unless resource.is_a?(Hash)

      name = resource.dig("metadata", "name").to_s
      case resource["kind"]
      when "Deployment"
        images = Array(resource.dig("spec", "template", "spec", "initContainers"))
          .concat(Array(resource.dig("spec", "template", "spec", "containers")))
          .filter_map { |container| container.is_a?(Hash) ? container["image"] : nil }
        inventory["controllers"][name] = images
      when "CustomResourceDefinition"
        inventory["crds"] << name
      when "ClusterRole"
        inventory["clusterRoles"] << name
      when "ClusterRoleBinding"
        inventory["clusterRoleBindings"] << name
      end
    end
  end
  inventory
end

def validate_components!(root, bootstrap, failures)
  version = bootstrap["version"].to_s
  unless version.match?(/\Av\d+\.\d+\.\d+\z/)
    failures << "fluxBootstrap.version must be an exact vMAJOR.MINOR.PATCH"
  end

  expected_release_url = "https://github.com/fluxcd/flux2/releases/tag/#{version}"
  failures << "fluxBootstrap.releaseUrl must be #{expected_release_url}" unless bootstrap["releaseUrl"] == expected_release_url

  components = bootstrap["components"]
  raise "fluxBootstrap.components must be a mapping" unless components.is_a?(Hash)
  expected_source_url = "https://github.com/fluxcd/flux2/releases/download/#{version}/install.yaml"
  unless components["sourceUrl"] == expected_source_url
    failures << "fluxBootstrap components sourceUrl must be pinned to #{version}: #{expected_source_url}"
  end
  unless components["sourceSha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    failures << "fluxBootstrap.components.sourceSha256 must be an exact lowercase SHA256"
  end

  relative_path = components["path"].to_s
  raise "fluxBootstrap.components.path is required" if relative_path.empty?
  path = repository_path(root, root.join(relative_path).cleanpath, "gotk-components")
  expected_sha = components["sha256"].to_s
  failures << "fluxBootstrap.components.sha256 must be an exact lowercase SHA256" unless expected_sha.match?(/\A[0-9a-f]{64}\z/)
  failures << "gotk-components checksum mismatch: #{relative_path}" unless Digest::SHA256.file(path).hexdigest == expected_sha

  documents = yaml_file_documents(path)
  identities = documents.flat_map { |document| resource_documents(document) }.map do |document|
    required_identity(document, path.to_s)
  end.to_set
  inventory = component_inventory(documents)

  expected_controllers = Array(components["controllers"])
  raise "fluxBootstrap.components.controllers must not be empty" if expected_controllers.empty?
  controller_names = Set.new
  expected_controllers.each do |controller|
    raise "fluxBootstrap.components.controllers entries must be mappings" unless controller.is_a?(Hash)
    name = controller["name"].to_s
    image = controller["image"].to_s
    raise "fluxBootstrap.components controller name and image are required" if name.empty? || image.empty?
    failures << "Flux controller image is not pinned: #{image}" unless image.match?(%r{\Aghcr\.io/fluxcd/[a-z0-9-]+(?::v\d+\.\d+\.\d+|@sha256:[0-9a-f]{64})\z})
    failures << "Flux controller #{name} image must be exactly #{image}" unless inventory["controllers"][name] == [image]
    failures << "duplicate Flux controller policy entry: #{name}" unless controller_names.add?(name)
  end
  unexpected_controllers = inventory["controllers"].keys.to_set - controller_names
  failures << "unexpected Flux controllers in gotk-components: #{unexpected_controllers.to_a.sort.join(', ')}" if unexpected_controllers.any?

  {
    "requiredCRDs" => "crds",
    "requiredClusterRoles" => "clusterRoles",
    "requiredClusterRoleBindings" => "clusterRoleBindings"
  }.each do |policy_key, inventory_key|
    expected = Array(components[policy_key])
    raise "fluxBootstrap.components.#{policy_key} must not be empty" if expected.empty?
    missing = expected.to_set - inventory[inventory_key]
    failures << "gotk-components is missing #{policy_key}: #{missing.to_a.sort.join(', ')}" if missing.any?
  end

  identities
end

def validate_flux_schemas!(root, bootstrap, failures)
  version = bootstrap["version"].to_s
  schemas = bootstrap["schemas"]
  raise "fluxBootstrap.schemas must be a mapping" unless schemas.is_a?(Hash)

  expected_source_url = "https://github.com/fluxcd/flux2/releases/download/#{version}/crd-schemas.tar.gz"
  failures << "fluxBootstrap schemas sourceUrl must be pinned to #{version}: #{expected_source_url}" unless schemas["sourceUrl"] == expected_source_url
  unless schemas["sourceSha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    failures << "fluxBootstrap.schemas.sourceSha256 must be an exact lowercase SHA256"
  end

  relative_directory = schemas["directory"].to_s
  raise "fluxBootstrap.schemas.directory is required" if relative_directory.empty?
  unless relative_directory.split(File::SEPARATOR).include?(version)
    failures << "fluxBootstrap.schemas.directory must include pinned version #{version}"
  end
  directory = repository_path(root, root.join(relative_directory).cleanpath, "Flux schema directory")
  raise "Flux schema directory is not a directory: #{relative_directory}" unless directory.directory?

  entries = Array(schemas["files"])
  raise "fluxBootstrap.schemas.files must not be empty" if entries.empty?
  expected_files = Set.new
  entries.each do |entry|
    raise "fluxBootstrap.schemas.files entries must be mappings" unless entry.is_a?(Hash)
    filename = entry["path"].to_s
    expected_sha = entry["sha256"].to_s
    raise "fluxBootstrap.schemas file path is required" if filename.empty?
    failures << "Flux schema #{filename} sha256 must be an exact lowercase SHA256" unless expected_sha.match?(/\A[0-9a-f]{64}\z/)
    failures << "duplicate Flux schema policy entry: #{filename}" unless expected_files.add?(filename)
    path = repository_path(root, directory.join(filename).cleanpath, "Flux schema")
    failures << "Flux schema checksum mismatch: #{filename}" unless Digest::SHA256.file(path).hexdigest == expected_sha
  end

  actual_files = directory.glob("*.json").select(&:file?).map { |path| path.basename.to_s }.to_set
  unless actual_files == expected_files
    failures << "Flux schema inventory mismatch: expected #{expected_files.to_a.sort.join(', ')}; found #{actual_files.to_a.sort.join(', ')}"
  end
end

def validate_bootstrap_contract!(bootstrap, failures)
  {
    "source" => EXPECTED_BOOTSTRAP_SOURCE,
    "root" => EXPECTED_BOOTSTRAP_ROOT
  }.each do |section, expected|
    actual = bootstrap[section]
    raise "fluxBootstrap.#{section} must be a mapping" unless actual.is_a?(Hash)
    expected.each do |field, value|
      failures << "fluxBootstrap.#{section}.#{field} must be #{value.inspect}" unless actual[field] == value
    end
  end
end

policy_path = root.join(".github/manifest-policy.yaml")
policy = if policy_path.file?
           YAML.safe_load(File.read(policy_path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
         else
           {BOOTSTRAP_SOURCE_POLICY_KEY => [{"apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "GitRepository", "namespace" => "flux-system", "name" => "flux-system"}]}
         end
bootstrap = policy[FLUX_BOOTSTRAP_POLICY_KEY]
bootstrap_component_identities = Set.new
bootstrap_root_id = nil
bootstrap_root_owner = nil
bootstrap_source_id = nil
if bootstrap
  raise "#{FLUX_BOOTSTRAP_POLICY_KEY} must be a mapping" unless bootstrap.is_a?(Hash)
  validate_bootstrap_contract!(bootstrap, failures)
  bootstrap_component_identities = validate_components!(root, bootstrap, failures)
  validate_flux_schemas!(root, bootstrap, failures)
  bootstrap_source_id = policy_identity(bootstrap["source"], "fluxBootstrap.source")
  bootstrap_root_id = policy_identity(bootstrap["root"], "fluxBootstrap.root")
  root_policy = bootstrap.fetch("root")
  bootstrap_root_owner = namespaced_identity("Kustomization", root_policy["namespace"], root_policy["name"])
end
allowed_bootstrap_sources = Set.new(Array(policy[BOOTSTRAP_SOURCE_POLICY_KEY]).map do |entry|
  [entry.fetch("apiVersion"), entry.fetch("kind"), entry.fetch("namespace").to_s, entry.fetch("name")].join("/")
end)

flux_files = root.join("clusters").glob("**/*.{yaml,yml,Kustomization}").select(&:file?)
flux_entries = flux_files.flat_map do |path|
  yaml_file_documents(path).filter_map do |doc|
    next unless doc.is_a?(Hash) && doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && doc["kind"] == "Kustomization"
    [repository_path(root, path, "Flux input"), doc]
  end
end
raise "no Flux Kustomizations found" if flux_entries.empty?

if bootstrap
  source_policy = bootstrap.fetch("source")
  source_inputs = flux_files.flat_map do |path|
    yaml_file_documents(path).filter_map do |document|
      next unless document.is_a?(Hash) && document["apiVersion"] == source_policy["apiVersion"] && document["kind"] == source_policy["kind"]
      next unless required_identity(document, path.to_s) == bootstrap_source_id
      [path, document]
    end
  end
  failures << "bootstrap GitRepository must be declared exactly once in Git; found #{source_inputs.length}" unless source_inputs.length == 1
  source_inputs.each do |_path, source|
    failures << "bootstrap GitRepository url must be #{source_policy['url']}" unless source.dig("spec", "url") == source_policy["url"]
    failures << "bootstrap GitRepository branch must be #{source_policy['branch']}" unless source.dig("spec", "ref") == {"branch" => source_policy["branch"]}
    failures << "bootstrap GitRepository must not reference credentials for the public repository" if source.dig("spec", "secretRef")
  end
end

seen_flux_identities = {}
flux_by_identity = {}
package_objects = {}

# First pass: collect every Flux identity and render every target package. No dependency
# or source validation is performed here, so declaration order cannot affect the result.
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
  is_bootstrap_root = bootstrap_root_id == flux_id
  if is_bootstrap_root
    root_policy = bootstrap.fetch("root")
    failures << "bootstrap root prune must be #{root_policy['prune'].inspect}" unless spec["prune"] == root_policy["prune"]
    failures << "bootstrap root must not be suspended" if spec["suspend"] == true
  else
    failures << "Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
    failures << "Flux Kustomization #{name}: suspend must be true" unless spec["suspend"] == true
  end
  path_value = spec["path"]
  raise "Flux Kustomization #{name}: spec.path is required" unless path_value.is_a?(String) && !path_value.empty?
  if is_bootstrap_root && path_value != bootstrap.dig("root", "path")
    raise "bootstrap root path must be #{bootstrap.dig('root', 'path')}"
  end
  package_dir = root.join(path_value.sub(%r{\A\./}, "")).cleanpath
  validate_kustomize_composition!(root, package_dir) if is_bootstrap_root
  package_objects[namespaced_identity("Kustomization", namespace, name)] = render_package(root, package_dir, name)
end
failures << "bootstrap root Kustomization is missing: #{bootstrap_root_id}" if bootstrap_root_id && !seen_flux_identities.key?(bootstrap_root_id)

# Collect declared GitRepositories from the rendered package output plus the explicit
# bootstrap allowlist before validating any Flux sourceRef.
declared_git_repositories = Set.new
package_objects.each_value do |entries|
  entries.each do |path, doc|
    next unless doc.is_a?(Hash) && doc["kind"] == "GitRepository"
    declared_git_repositories << required_identity(doc, path.to_s)
  end
end

if bootstrap
  root_entries = package_objects.fetch(bootstrap_root_owner, [])
  root_identities = root_entries.filter_map do |path, document|
    next unless document.is_a?(Hash)
    required_identity(document, path.to_s)
  end
  missing_components = bootstrap_component_identities - root_identities.to_set
  if missing_components.any?
    failures << "bootstrap root render is missing gotk-components objects: #{missing_components.to_a.sort.join(', ')}"
  end

  source_policy = bootstrap.fetch("source")
  source_entries = root_entries.select do |path, document|
    document.is_a?(Hash) && required_identity(document, path.to_s) == bootstrap_source_id
  end
  if source_entries.length != 1
    failures << "bootstrap root must render exactly one #{bootstrap_source_id}; found #{source_entries.length}"
  else
    source = source_entries.first.last
    failures << "bootstrap GitRepository url must be #{source_policy['url']}" unless source.dig("spec", "url") == source_policy["url"]
    failures << "bootstrap GitRepository branch must be #{source_policy['branch']}" unless source.dig("spec", "ref") == {"branch" => source_policy["branch"]}
    failures << "bootstrap GitRepository must not reference credentials for the public repository" if source.dig("spec", "secretRef")
  end

  root_resource_count = root_entries.count do |path, document|
    document.is_a?(Hash) && required_identity(document, path.to_s) == bootstrap_root_id
  end
  failures << "bootstrap root must render itself exactly once; found #{root_resource_count}" unless root_resource_count == 1
end

# Second pass: validate source references and dependencies against the complete inventory.
flux_entries.each do |_path, resource|
  name = resource.dig("metadata", "name")
  namespace = resource.dig("metadata", "namespace").to_s
  spec = resource.fetch("spec")
  source_ref = spec["sourceRef"]
  unless source_ref.is_a?(Hash)
    failures << "Flux Kustomization #{name}: sourceRef is required"
  else
    failures << "Flux Kustomization #{name}: sourceRef.kind must be GitRepository" unless source_ref["kind"] == "GitRepository"
    failures << "Flux Kustomization #{name}: sourceRef.name is required" unless source_ref["name"].is_a?(String) && !source_ref["name"].empty?
    source_namespace = source_ref["namespace"] || namespace
    failures << "Flux Kustomization #{name}: sourceRef.namespace must match metadata.namespace" if source_ref["namespace"] && source_ref["namespace"] != namespace
    source_id = ["source.toolkit.fluxcd.io/v1", source_ref["kind"], source_namespace.to_s, source_ref["name"]].join("/")
    unless declared_git_repositories.include?(source_id) || allowed_bootstrap_sources.include?(source_id)
      failures << "Flux Kustomization #{name}: GitRepository sourceRef is neither declared in rendered packages nor explicitly allowlisted: #{source_id}"
    end
    if bootstrap_root_id == required_identity(resource, "Flux Kustomization #{name}")
      source_policy = bootstrap.fetch("source")
      failures << "bootstrap root sourceRef.kind must be #{source_policy['kind']}" unless source_ref["kind"] == source_policy["kind"]
      failures << "bootstrap root sourceRef.name must be #{source_policy['name']}" unless source_ref["name"] == source_policy["name"]
      failures << "bootstrap root sourceRef.namespace must be #{source_policy['namespace']}" unless source_namespace == source_policy["namespace"]
    end
  end
end

# Build and validate the dependency graph only after all Flux identities are known.
flux_by_identity.each do |node, resource|
  Array(resource.dig("spec", "dependsOn")).each do |dependency|
    unless dependency.is_a?(Hash) && dependency["name"].is_a?(String) && !dependency["name"].empty?
      failures << "Flux Kustomization #{resource.dig("metadata", "name")}: dependsOn entries require name"
      next
    end
    namespace = resource.dig("metadata", "namespace").to_s
    dep_namespace = dependency["namespace"] || namespace
    failures << "Flux Kustomization #{resource.dig("metadata", "name")}: dependsOn.namespace must match metadata.namespace" if dependency["namespace"] && dependency["namespace"] != namespace
    dep_id = namespaced_identity("Kustomization", dep_namespace, dependency["name"])
    failures << "Flux Kustomization #{resource.dig("metadata", "name")}: unknown dependency #{dep_id}" unless flux_by_identity.key?(dep_id)
    resource["__dep_ids"] ||= []
    resource["__dep_ids"] << dep_id
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
  end
end
package_objects.each do |_owner, entries|
  entries.each do |path, doc|
    next unless doc.is_a?(Hash) && doc["kind"] == "HelmRelease"
    id = required_identity(doc, path.to_s)
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

# The outer Nextcloud Flux Kustomization is not part of a package render, so inspect it
# explicitly. The inner rendered Kustomization/HelmRelease is checked below as well.
flux_entries.each do |path, doc|
  next unless doc.dig("metadata", "name") == "nextcloud"
  annotation = doc.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  failures << "Nextcloud #{required_identity(doc, path.to_s)}: activation-blocked annotation must be true" unless annotation == "true"
end
package_objects.values.flat_map { |entries| entries }.each do |path, doc|
  next unless doc.is_a?(Hash) && ["HelmRelease", "Kustomization"].include?(doc["kind"]) && doc.dig("metadata", "name") == "nextcloud"
  annotation = doc.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  failures << "Nextcloud #{required_identity(doc, path.to_s)}: activation-blocked annotation must be true" unless annotation == "true"
end
outer_nextcloud = flux_entries.any? { |_path, doc| doc.dig("metadata", "name") == "nextcloud" }
inner_nextcloud = package_objects.values.flat_map { |entries| entries }.any? do |_path, doc|
  doc.is_a?(Hash) && doc["kind"] == "HelmRelease" && doc.dig("metadata", "name") == "nextcloud"
end
failures << "Nextcloud HelmRelease is required in the rendered package" if outer_nextcloud && !inner_nextcloud

if failures.any?
  warn failures.sort.uniq.join("\n")
  exit 1
end

puts "Validated #{flux_entries.length} Flux Kustomizations and #{seen_objects.length} unique rendered objects."
