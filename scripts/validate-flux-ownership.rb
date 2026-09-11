#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "set"
require "digest"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "yaml"
require "zlib"

root = Pathname.new(ARGV.fetch(0, File.expand_path("..", __dir__))).realpath
failures = []

BOOTSTRAP_SOURCE_POLICY_KEY = "bootstrapManagedSources"
FLUX_BOOTSTRAP_POLICY_KEY = "fluxBootstrap"
FLUX_ACTIVATION_POLICY_KEY = "fluxActivation"
ACTIVATION_BLOCKED = "flux.takutk.com/activation-blocked"
BLOCKED_ACTIVATION_PATHS = Set.new(["./clusters/home/packages/nextcloud"]).freeze
BLOCKED_ACTIVATION_OBJECTS = Set.new([
  "v1/Namespace//nextcloud",
  "helm.toolkit.fluxcd.io/v2/HelmRelease/nextcloud/nextcloud",
  "external-secrets.io/v1beta1/ExternalSecret/nextcloud/nextcloud-db-secret"
]).freeze
TREK_PACKAGE_PATH = "./clusters/home/packages/trek"
MEMOS_PACKAGE_PATH = "./clusters/home/packages/memos"
N8N_PACKAGE_PATH = "./clusters/home/packages/n8n"
JELLYFIN_PACKAGE_PATH = "./clusters/home/packages/jellyfin"
GRAFANA_PACKAGE_PATH = "./clusters/home/packages/grafana"
TREK_ACTIVATION_BLOCKED = "true"
KUBECTL = ENV.fetch("FLUX_OWNERSHIP_KUBECTL", "kubectl")
CURL = ENV.fetch("FLUX_OWNERSHIP_CURL", "curl")
FLUX = ENV.fetch("FLUX_OWNERSHIP_FLUX", "flux")
HELM = ENV.fetch("FLUX_OWNERSHIP_HELM", "helm")
KUSTOMIZATION_FILENAMES = %w[kustomization.yaml kustomization.yml Kustomization].freeze
BOOTSTRAP_GIT_REPOSITORY_ID = "source.toolkit.fluxcd.io/v1/GitRepository/flux-system/flux-system"

def local_chart_files_sha256(root, chart_path)
  relative = chart_path.to_s.sub(%r{\A\./}, "")
  chart_dir = root.join(relative).cleanpath
  unless chart_dir.to_s == root.to_s || chart_dir.to_s.start_with?(root.to_s + File::SEPARATOR)
    return nil
  end
  return nil unless chart_dir.directory?

  entries = []
  chart_dir.find do |path|
    next unless path.file?
    relative_file = path.relative_path_from(chart_dir).to_s
    next if relative_file.split(File::SEPARATOR).include?("..")
    entries << [relative_file, Digest::SHA256.hexdigest(path.binread)]
  end
  Digest::SHA256.hexdigest(entries.sort.map { |name, digest| "#{name}\n#{digest}\n" }.join)
end

def bootstrap_git_repository_id(bootstrap_source_id)
  bootstrap_source_id || BOOTSTRAP_GIT_REPOSITORY_ID
end
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
ESO_CONTROLLER_ACTIVATION_CONTRACT = {
  "activeKustomizations" => [{
    "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
    "kind" => "Kustomization",
    "namespace" => "flux-system",
    "name" => "eso-controller",
    "path" => "./clusters/home/packages/eso-controller",
    "inventory" => [
      {
        "apiVersion" => "v1",
        "kind" => "Namespace",
        "namespace" => "",
        "name" => "external-secrets"
      },
      {
        "apiVersion" => "source.toolkit.fluxcd.io/v1",
        "kind" => "HelmRepository",
        "namespace" => "flux-system",
        "name" => "external-secrets"
      },
      {
        "apiVersion" => "helm.toolkit.fluxcd.io/v2",
        "kind" => "HelmRelease",
        "namespace" => "external-secrets",
        "name" => "external-secrets"
      }
    ]
  }],
  "activeHelmReleases" => [{
    "apiVersion" => "helm.toolkit.fluxcd.io/v2",
    "kind" => "HelmRelease",
    "namespace" => "external-secrets",
    "name" => "external-secrets",
    "owner" => {
      "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
      "kind" => "Kustomization",
      "namespace" => "flux-system",
      "name" => "eso-controller"
    },
    "chart" => {
      "name" => "external-secrets",
      "version" => "0.14.4",
      "repository" => {
        "apiVersion" => "source.toolkit.fluxcd.io/v1",
        "kind" => "HelmRepository",
        "namespace" => "flux-system",
        "name" => "external-secrets",
        "url" => "https://charts.external-secrets.io"
      },
      "artifact" => {
        "url" => "https://github.com/external-secrets/external-secrets/releases/download/helm-chart-0.14.4/external-secrets-0.14.4.tgz",
        "sha256" => "cfda856bdfab922a92c1e0ca199811edae21ad529484f3669b8233e813168779",
        "crdTemplates" => {
          "pathPrefix" => "external-secrets/templates/crds/",
          "count" => 19,
          "sha256" => "5fa17b33c731ab29d089f2bfd350342b002c6758db9ad7f7667c71c809f23ab5"
        }
      }
    },
    "safety" => {"installCRDs" => true}
  }]
}.freeze
ESO_CONFIG_ACTIVATION_CONTRACT = {
  "activeKustomizations" => ESO_CONTROLLER_ACTIVATION_CONTRACT["activeKustomizations"] + [{
    "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
    "kind" => "Kustomization",
    "namespace" => "flux-system",
    "name" => "eso-config",
    "path" => "./clusters/home/packages/eso-config",
    "inventory" => [{
      "apiVersion" => "external-secrets.io/v1beta1",
      "kind" => "ClusterSecretStore",
      "namespace" => "",
      "name" => "secret-store-provider"
    }]
  }],
  "activeHelmReleases" => ESO_CONTROLLER_ACTIVATION_CONTRACT["activeHelmReleases"]
}.freeze

CSI_SECRETS_STORE_KUSTOMIZATION = {
  "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
  "kind" => "Kustomization",
  "namespace" => "flux-system",
  "name" => "csi-secrets-store",
  "path" => "./clusters/home/packages/csi-secrets-store",
  "inventory" => [
    {
      "apiVersion" => "source.toolkit.fluxcd.io/v1",
      "kind" => "HelmRepository",
      "namespace" => "flux-system",
      "name" => "secrets-store-csi-driver"
    },
    {
      "apiVersion" => "helm.toolkit.fluxcd.io/v2",
      "kind" => "HelmRelease",
      "namespace" => "kube-system",
      "name" => "csi-secrets-store"
    }
  ]
}.freeze
CSI_SECRETS_STORE_STABLE_INVENTORY = [
  {
    "apiVersion" => "apiextensions.k8s.io/v1",
    "kind" => "CustomResourceDefinition",
    "namespace" => "",
    "name" => "secretproviderclasses.secrets-store.csi.x-k8s.io"
  },
  {
    "apiVersion" => "apiextensions.k8s.io/v1",
    "kind" => "CustomResourceDefinition",
    "namespace" => "",
    "name" => "secretproviderclasspodstatuses.secrets-store.csi.x-k8s.io"
  },
  {
    "apiVersion" => "v1",
    "kind" => "ServiceAccount",
    "namespace" => "kube-system",
    "name" => "secrets-store-csi-driver"
  },
  {
    "apiVersion" => "rbac.authorization.k8s.io/v1",
    "kind" => "ClusterRole",
    "namespace" => "",
    "name" => "secretproviderclasses-admin-role"
  },
  {
    "apiVersion" => "rbac.authorization.k8s.io/v1",
    "kind" => "ClusterRole",
    "namespace" => "",
    "name" => "secretproviderclasses-viewer-role"
  },
  {
    "apiVersion" => "rbac.authorization.k8s.io/v1",
    "kind" => "ClusterRole",
    "namespace" => "",
    "name" => "secretproviderclasspodstatuses-viewer-role"
  },
  {
    "apiVersion" => "rbac.authorization.k8s.io/v1",
    "kind" => "ClusterRole",
    "namespace" => "",
    "name" => "secretproviderclasses-role"
  },
  {
    "apiVersion" => "rbac.authorization.k8s.io/v1",
    "kind" => "ClusterRoleBinding",
    "namespace" => "",
    "name" => "secretproviderclasses-rolebinding"
  },
  {
    "apiVersion" => "apps/v1",
    "kind" => "DaemonSet",
    "namespace" => "kube-system",
    "name" => "csi-secrets-store-secrets-store-csi-driver"
  },
  {
    "apiVersion" => "storage.k8s.io/v1",
    "kind" => "CSIDriver",
    "namespace" => "",
    "name" => "secrets-store.csi.k8s.io"
  }
].freeze
CSI_SECRETS_STORE_ARTIFACT = {
  "url" => "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts/secrets-store-csi-driver-1.4.8.tgz",
  "sha256" => "894ee5351f615184af4ad0f4ea03be35485e65bc1797c10e315fcd1bcc3aef13",
  "crdInventory" => {
    "pathPrefix" => "secrets-store-csi-driver/crds/",
    "count" => 2,
    "setSha256" => "43551fdd7c965bd461dc91d6c08448e0d501e1abd378b2bfb09c24170f79f258"
  },
  "resourceInventory" => CSI_SECRETS_STORE_STABLE_INVENTORY
}.freeze
CSI_SECRETS_STORE_HELM_RELEASE = {
  "apiVersion" => "helm.toolkit.fluxcd.io/v2",
  "kind" => "HelmRelease",
  "namespace" => "kube-system",
  "name" => "csi-secrets-store",
  "owner" => {
    "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
    "kind" => "Kustomization",
    "namespace" => "flux-system",
    "name" => "csi-secrets-store"
  },
  "chart" => {
    "name" => "secrets-store-csi-driver",
    "version" => "1.4.8",
    "repository" => {
      "apiVersion" => "source.toolkit.fluxcd.io/v1",
      "kind" => "HelmRepository",
      "namespace" => "flux-system",
      "name" => "secrets-store-csi-driver",
      "url" => "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
    },
    "artifact" => CSI_SECRETS_STORE_ARTIFACT
  },
  "safety" => {"disableHooks" => true, "linuxCRDsEnabled" => false}
}.freeze
CSI_SECRETS_STORE_ACTIVATION_CONTRACT = {
  "activeKustomizations" => ESO_CONFIG_ACTIVATION_CONTRACT["activeKustomizations"] + [CSI_SECRETS_STORE_KUSTOMIZATION],
  "activeHelmReleases" => ESO_CONFIG_ACTIVATION_CONTRACT["activeHelmReleases"] + [CSI_SECRETS_STORE_HELM_RELEASE]
}.freeze

ESO_CONFIG_STORE_IDENTITY = "external-secrets.io/v1beta1/ClusterSecretStore//secret-store-provider"
ESO_CONFIG_STORE_POLICY = {
  "apiVersion" => "external-secrets.io/v1beta1",
  "kind" => "ClusterSecretStore",
  "namespace" => "",
  "name" => "secret-store-provider"
}.freeze
ESO_CONFIG_STORE_SPEC = {
  "provider" => {
    "gcpsm" => {
      "auth" => {
        "secretRef" => {
          "secretAccessKeySecretRef" => {
            "name" => "gcpsm-secret",
            "key" => "secret-access-credentials",
            "namespace" => "gcpsm-secret"
          }
        }
      },
      "projectID" => "269357193809"
    }
  }
}.freeze
TEST_FIXTURE_ACTIVATION_CONTRACT = {
  "activeKustomizations" => [{
    "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
    "kind" => "Kustomization",
    "namespace" => "flux-system",
    "name" => "fixture-controller",
    "path" => "./clusters/pkg",
    "inventory" => [
      {"apiVersion" => "v1", "kind" => "Namespace", "namespace" => "", "name" => "fixture-system"},
      {"apiVersion" => "source.toolkit.fluxcd.io/v1", "kind" => "HelmRepository", "namespace" => "flux-system", "name" => "fixture-repository"},
      {"apiVersion" => "helm.toolkit.fluxcd.io/v2", "kind" => "HelmRelease", "namespace" => "fixture-system", "name" => "fixture-release"}
    ]
  }],
  "activeHelmReleases" => [{
    "apiVersion" => "helm.toolkit.fluxcd.io/v2",
    "kind" => "HelmRelease",
    "namespace" => "fixture-system",
    "name" => "fixture-release",
    "owner" => {
      "apiVersion" => "kustomize.toolkit.fluxcd.io/v1",
      "kind" => "Kustomization",
      "namespace" => "flux-system",
      "name" => "fixture-controller"
    },
    "chart" => {
      "name" => "external-secrets",
      "version" => "0.14.4",
      "repository" => {
        "apiVersion" => "source.toolkit.fluxcd.io/v1",
        "kind" => "HelmRepository",
        "namespace" => "flux-system",
        "name" => "fixture-repository",
        "url" => "https://charts.external-secrets.io"
      },
      "artifact" => {
        "url" => "https://fixture.invalid/external-secrets-0.14.4.tgz",
        "sha256" => "a17555a4b06afbf37d0739bba7198d6c3cd871aa1143fe26a1d16e26c53eecf4",
        "crdTemplates" => {
          "pathPrefix" => "external-secrets/templates/crds/",
          "count" => 1,
          "sha256" => "336717a1613029971faf17d3accd4ac7eb549dcd2de227da8211794d9c7ac654"
        },
        "crdInventory" => {
          "pathPrefix" => "external-secrets/templates/crds/",
          "count" => 1,
          "setSha256" => "336717a1613029971faf17d3accd4ac7eb549dcd2de227da8211794d9c7ac654"
        },
        "resourceInventory" => [{
          "apiVersion" => "example.invalid/v1",
          "kind" => "FixtureCRD",
          "namespace" => "",
          "name" => "fixture-crd"
        }]
      }
    },
    "safety" => {"installCRDs" => true}
  }]
}.freeze
ACTIVATION_PHASE_CONTRACTS = {
  "eso-controller" => ESO_CONTROLLER_ACTIVATION_CONTRACT,
  "eso-config" => ESO_CONFIG_ACTIVATION_CONTRACT,
  "csi-secrets-store" => CSI_SECRETS_STORE_ACTIVATION_CONTRACT,
  # This reserved phase is usable only by the offline fake transport in test-validation.rb.
  # Its .invalid artifact URL makes it fail closed under the real CI transport.
  "test-fixture-helm-adoption" => TEST_FIXTURE_ACTIVATION_CONTRACT
}.freeze
ESO_CONFIG_ACTIVE_PHASES = %w[eso-config csi-secrets-store].freeze

def eso_config_active_phase?(phase)
  ESO_CONFIG_ACTIVE_PHASES.include?(phase.to_s)
end

def active_cluster_secret_store_policies_for_phase(phase)
  return {} unless eso_config_active_phase?(phase)

  {ESO_CONFIG_STORE_IDENTITY => ESO_CONFIG_STORE_POLICY.merge("spec" => ESO_CONFIG_STORE_SPEC)}
end

# Parse the YAML stream without permitting Ruby objects or aliases.
def yaml_documents(content, source)
  content.split(/^---[ \t]*(?:#.*)?$\n?/).each_with_object([]) do |document, documents|
    next if document.strip.empty?
    documents << YAML.safe_load(document, permitted_classes: [], permitted_symbols: [], aliases: false)
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

def verify_remote_sha256!(url, expected_sha, description, failures)
  stdout, _stderr, status = Open3.capture3(
    CURL,
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--proto", "=https",
    "--proto-redir", "=https",
    "--tlsv1.2",
    "--connect-timeout", "10",
    "--max-time", "60",
    "--", url
  )
  raise "#{description}: upstream artifact fetch failed" unless status.success?

  actual_sha = Digest::SHA256.hexdigest(stdout.b)
  unless actual_sha == expected_sha
    failures << "#{description}: upstream artifact checksum mismatch"
    return nil
  end
  stdout.b
rescue Errno::ENOENT
  raise "#{description}: upstream artifact fetcher is unavailable (#{CURL})"
end

def validate_regenerated_components!(root, path, version, failures)
  stdout, _stderr, status = Open3.capture3(
    FLUX,
    "install",
    "--version=#{version}",
    "--components=source-controller,kustomize-controller,helm-controller,notification-controller",
    "--namespace=flux-system",
    "--export",
    chdir: root.to_s
  )
  raise "gotk-components: pinned Flux generator failed" unless status.success?
  unless stdout.b == File.binread(path)
    failures << "gotk-components does not match pinned Flux CLI generation"
  end
rescue Errno::ENOENT
  raise "gotk-components: pinned Flux generator is unavailable (#{FLUX})"
end

def safe_archive_files(bytes, description)
  files = {}
  gzip = Zlib::GzipReader.new(StringIO.new(bytes))
  archive = Gem::Package::TarReader.new(gzip)
  archive.each do |entry|
    next unless entry.file?

    name = entry.full_name.sub(%r{\A\./}, "")
    path = Pathname.new(name)
    if name.empty? || path.absolute? || path.each_filename.include?("..")
      raise "#{description}: unsafe archive path"
    end
    raise "#{description}: duplicate archive file #{name}" if files.key?(name)
    files[name] = entry.read.b
  end
  files
rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError
  raise "#{description}: invalid archive"
ensure
  archive&.close
  gzip&.close
end

def archive_file_set_sha256(files, paths)
  digest = Digest::SHA256.new
  paths.sort.each do |path|
    digest.update(path)
    digest.update("\0")
    digest.update(files.fetch(path))
    digest.update("\0")
  end
  digest.hexdigest
end

def validate_chart_resource_inventory!(bytes, identity, namespace, resource_inventory, failures)
  release_name = identity.split("/").last
  expected_ids = resource_inventory.map do |resource|
    inventory_policy_identity(resource, "active HelmRelease #{identity} chart.artifact.resourceInventory entry")
  end.to_set

  Dir.mktmpdir("flux-ownership-helm-") do |directory|
    chart_path = File.join(directory, "chart.tgz")
    File.binwrite(chart_path, bytes)
    stdout, _stderr, status = Open3.capture3(
      HELM,
      "template",
      release_name,
      chart_path,
      "--namespace", namespace.to_s,
      "--include-crds",
      "--no-hooks",
      "--set", "linux.crds.enabled=false"
    )
    raise "active HelmRelease #{identity}: pinned Helm renderer failed" unless status.success?
    raise "active HelmRelease #{identity}: pinned Helm render was empty" if stdout.strip.empty?

    rendered_ids = yaml_documents(stdout, "rendered Helm chart #{identity}")
      .flat_map { |document| resource_documents(document) }
      .map { |document| required_identity(document, "rendered Helm chart #{identity}") }
    duplicate_ids = rendered_ids.group_by(&:itself).select { |_resource_id, occurrences| occurrences.length > 1 }.keys.sort
    raise "active HelmRelease #{identity}: rendered resource inventory contains duplicate identities: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?

    actual_ids = rendered_ids.to_set
    unless actual_ids == expected_ids
      failures << "active HelmRelease #{identity}: rendered resource inventory mismatch: " \
                  "expected #{expected_ids.to_a.sort.join(', ')}; " \
                  "found #{actual_ids.to_a.sort.join(', ')}"
    end
  end
rescue Errno::ENOENT
  raise "active HelmRelease #{identity}: pinned Helm renderer is unavailable (#{HELM})"
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

      target = repository_path(root, directory.join(resource).cleanpath, "Kustomize composition resource")
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

def activation_policy_map(activation, key, expected_api_version, expected_kind, failures)
  entries = activation[key]
  raise "#{FLUX_ACTIVATION_POLICY_KEY}.#{key} must be an array" unless entries.is_a?(Array)

  entries.each_with_object({}) do |entry, policies|
    identity = policy_identity(entry, "#{FLUX_ACTIVATION_POLICY_KEY}.#{key} entry")
    unless entry["apiVersion"] == expected_api_version && entry["kind"] == expected_kind
      failures << "#{FLUX_ACTIVATION_POLICY_KEY}.#{key} entry must identify #{expected_api_version}/#{expected_kind}: #{identity}"
    end
    if policies.key?(identity)
      failures << "duplicate #{FLUX_ACTIVATION_POLICY_KEY}.#{key} entry: #{identity}"
    else
      policies[identity] = entry
    end
  end
end

def inventory_policy_identity(entry, description)
  raise "#{description} must be a mapping" unless entry.is_a?(Hash)
  %w[apiVersion kind name].each do |field|
    raise "#{description}.#{field} is required" if entry[field].to_s.empty?
  end
  raise "#{description}.namespace is required" unless entry.key?("namespace")
  [entry["apiVersion"], entry["kind"], entry["namespace"].to_s, entry["name"]].join("/")
end

def validate_activation_phase_contract!(activation, failures)
  phase = activation["phase"].to_s
  expected_kustomization = ESO_CONTROLLER_ACTIVATION_CONTRACT.fetch("activeKustomizations").first
  expected_helm_release = ESO_CONTROLLER_ACTIVATION_CONTRACT.fetch("activeHelmReleases").first
  expected_config_kustomization = ESO_CONFIG_ACTIVATION_CONTRACT.fetch("activeKustomizations").find { |entry| entry["name"] == "eso-config" }
  expected_csi_kustomization = CSI_SECRETS_STORE_KUSTOMIZATION
  expected_csi_helm_release = CSI_SECRETS_STORE_HELM_RELEASE
  known_identity_present = Array(activation["activeKustomizations"]).any? do |entry|
    entry.is_a?(Hash) && %w[apiVersion kind namespace name].all? { |field| entry[field] == expected_kustomization[field] }
  end
  known_identity_present ||= Array(activation["activeHelmReleases"]).any? do |entry|
    entry.is_a?(Hash) && %w[apiVersion kind namespace name].all? { |field| entry[field] == expected_helm_release[field] }
  end
  known_config_identity_present = Array(activation["activeKustomizations"]).any? do |entry|
    entry.is_a?(Hash) && %w[apiVersion kind namespace name].all? { |field| entry[field] == expected_config_kustomization[field] }
  end
  if known_identity_present && !["eso-controller", "eso-config", "csi-secrets-store"].include?(phase)
    failures << "Flux ESO controller identities must use fluxActivation phase eso-controller, eso-config, or csi-secrets-store"
  end
  if known_config_identity_present && !["eso-config", "csi-secrets-store"].include?(phase)
    failures << "Flux ESO config identities must use fluxActivation phase eso-config or csi-secrets-store"
  end
  known_csi_identity_present = Array(activation["activeKustomizations"]).any? do |entry|
    entry.is_a?(Hash) && %w[apiVersion kind namespace name].all? { |field| entry[field] == expected_csi_kustomization[field] }
  end
  known_csi_identity_present ||= Array(activation["activeHelmReleases"]).any? do |entry|
    entry.is_a?(Hash) && %w[apiVersion kind namespace name].all? { |field| entry[field] == expected_csi_helm_release[field] }
  end
  if known_csi_identity_present && phase != "csi-secrets-store"
    failures << "Flux CSI identities must use fluxActivation phase csi-secrets-store"
  end

  expected_contract = ACTIVATION_PHASE_CONTRACTS[phase]
  unless expected_contract
    failures << "fluxActivation phase is not recognized: #{phase}"
    return
  end

  expected_contract.each do |key, expected|
    actual = activation[key]
    if %w[activeKustomizations activeHelmReleases].include?(key)
      actual = Array(actual).reject do |entry|
        next false unless entry.is_a?(Hash)
        pair = [entry["namespace"], entry["name"]]
        if key == "activeKustomizations"
          [
            ["flux-system", "trek"],
            ["flux-system", "memos"],
            ["flux-system", "n8n"],
            ["flux-system", "jellyfin"],
            ["flux-system", "grafana"]
          ].include?(pair)
        else
          [
            ["trek", "trek"],
            ["memos", "memos"],
            ["n8n", "n8n"],
            ["jellyfin", "jellyfin"],
            ["grafana", "grafana-k8s-monitoring"]
          ].include?(pair)
        end
      end
    end
    unless actual == expected
      failures << "fluxActivation #{phase} #{key} contract must exactly match the reviewed phase boundary"
    end
  end
end

def validate_active_cluster_secret_store!(document, identity, contract, failures)
  unless document["spec"] == contract["spec"]
    failures << "active ClusterSecretStore #{identity}: spec must exactly match the reviewed ESO config"
  end
end

def validate_trek_stage_state!(stage, outer, inner, active_kustomizations, active_helm_releases, failures)
  allowed_stages = %w[preparation config-active app-active]
  unless allowed_stages.include?(stage)
    failures << "TREK activation stage is not recognized: #{stage}"
    return
  end
  unless outer.is_a?(Hash) && inner.is_a?(Hash)
    failures << "TREK activation state requires both outer Kustomization and inner HelmRelease"
    return
  end

  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek"
  outer_suspend = outer.dig("spec", "suspend")
  inner_suspend = inner.dig("spec", "suspend")
  outer_marker = outer.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  inner_marker = inner.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  outer_blocked = stage == "preparation"
  inner_blocked = stage != "app-active"

  failures << "TREK outer Kustomization path must be #{TREK_PACKAGE_PATH}" unless outer.dig("spec", "path") == TREK_PACKAGE_PATH
  failures << "TREK outer Kustomization dependsOn must be exactly eso-controller then eso-config" unless outer.dig("spec", "dependsOn") == [{"name" => "eso-controller"}, {"name" => "eso-config"}]
  failures << "TREK outer Kustomization prune must remain false" unless outer.dig("spec", "prune") == false
  failures << "TREK outer Kustomization suspend state does not match stage #{stage}" unless outer_suspend == outer_blocked
  failures << "TREK inner HelmRelease suspend state does not match stage #{stage}" unless inner_suspend == inner_blocked
  failures << "TREK outer Kustomization activation marker does not match stage #{stage}" unless (outer_marker == TREK_ACTIVATION_BLOCKED) == outer_blocked
  failures << "TREK inner HelmRelease activation marker does not match stage #{stage}" unless (inner_marker == TREK_ACTIVATION_BLOCKED) == inner_blocked
  failures << "TREK stage #{stage} must not activate an inner HelmRelease under a suspended outer Kustomization" if outer_suspend == true && inner_suspend == false

  if stage == "preparation"
    failures << "TREK preparation must not be in active Kustomization ownership policy" if active_kustomizations.key?(outer_id)
    failures << "TREK preparation must not be in active HelmRelease ownership policy" if active_helm_releases.key?(inner_id)
  else
    failures << "TREK stage #{stage} requires active Kustomization ownership policy" unless active_kustomizations.key?(outer_id)
    failures << "TREK stage #{stage} requires active HelmRelease ownership policy" unless active_helm_releases.key?(inner_id)
  end
end

def validate_memos_stage_state!(stage, outer, inner, active_kustomizations, active_helm_releases, failures)
  allowed_stages = %w[preparation config-active app-active]
  unless allowed_stages.include?(stage)
    failures << "Memos activation stage is not recognized: #{stage}"
    return
  end
  unless outer.is_a?(Hash) && inner.is_a?(Hash)
    failures << "Memos activation state requires both outer Kustomization and inner HelmRelease"
    return
  end

  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/memos"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos"
  outer_suspend = outer.dig("spec", "suspend")
  inner_suspend = inner.dig("spec", "suspend")
  outer_marker = outer.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  inner_marker = inner.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  outer_blocked = stage == "preparation"
  inner_blocked = stage != "app-active"

  failures << "Memos outer Kustomization path must be #{MEMOS_PACKAGE_PATH}" unless outer.dig("spec", "path") == MEMOS_PACKAGE_PATH
  failures << "Memos outer Kustomization prune must remain false" unless outer.dig("spec", "prune") == false
  failures << "Memos outer Kustomization suspend state does not match stage #{stage}" unless outer_suspend == outer_blocked
  failures << "Memos inner HelmRelease suspend state does not match stage #{stage}" unless inner_suspend == inner_blocked
  failures << "Memos outer Kustomization activation marker does not match stage #{stage}" unless (outer_marker == TREK_ACTIVATION_BLOCKED) == outer_blocked
  failures << "Memos inner HelmRelease activation marker does not match stage #{stage}" unless (inner_marker == TREK_ACTIVATION_BLOCKED) == inner_blocked
  failures << "Memos stage #{stage} must not activate an inner HelmRelease under a suspended outer Kustomization" if outer_suspend == true && inner_suspend == false

  if stage == "preparation"
    failures << "Memos preparation must not be in active Kustomization ownership policy" if active_kustomizations.key?(outer_id)
    failures << "Memos preparation must not be in active HelmRelease ownership policy" if active_helm_releases.key?(inner_id)
  else
    failures << "Memos stage #{stage} requires active Kustomization ownership policy" unless active_kustomizations.key?(outer_id)
    failures << "Memos stage #{stage} requires active HelmRelease ownership policy" unless active_helm_releases.key?(inner_id)
  end
end

def validate_n8n_stage_state!(stage, outer, inner, active_kustomizations, active_helm_releases, failures)
  allowed_stages = %w[preparation config-active app-active]
  unless allowed_stages.include?(stage)
    failures << "n8n activation stage is not recognized: #{stage}"
    return
  end
  unless outer.is_a?(Hash) && inner.is_a?(Hash)
    failures << "n8n activation state requires both outer Kustomization and inner HelmRelease"
    return
  end

  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/n8n"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/n8n/n8n"
  outer_suspend = outer.dig("spec", "suspend")
  inner_suspend = inner.dig("spec", "suspend")
  outer_marker = outer.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  inner_marker = inner.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  outer_blocked = stage == "preparation"
  inner_blocked = stage != "app-active"

  failures << "n8n outer Kustomization path must be #{N8N_PACKAGE_PATH}" unless outer.dig("spec", "path") == N8N_PACKAGE_PATH
  failures << "n8n outer Kustomization dependsOn must be exactly eso-controller then eso-config" unless outer.dig("spec", "dependsOn") == [{"name" => "eso-controller"}, {"name" => "eso-config"}]
  failures << "n8n outer Kustomization prune must remain false" unless outer.dig("spec", "prune") == false
  failures << "n8n outer Kustomization suspend state does not match stage #{stage}" unless outer_suspend == outer_blocked
  failures << "n8n inner HelmRelease suspend state does not match stage #{stage}" unless inner_suspend == inner_blocked
  failures << "n8n outer Kustomization activation marker does not match stage #{stage}" unless (outer_marker == TREK_ACTIVATION_BLOCKED) == outer_blocked
  failures << "n8n inner HelmRelease activation marker does not match stage #{stage}" unless (inner_marker == TREK_ACTIVATION_BLOCKED) == inner_blocked
  failures << "n8n stage #{stage} must not activate an inner HelmRelease under a suspended outer Kustomization" if outer_suspend == true && inner_suspend == false

  if stage == "preparation"
    failures << "n8n preparation must not be in active Kustomization ownership policy" if active_kustomizations.key?(outer_id)
    failures << "n8n preparation must not be in active HelmRelease ownership policy" if active_helm_releases.key?(inner_id)
  else
    failures << "n8n stage #{stage} requires active Kustomization ownership policy" unless active_kustomizations.key?(outer_id)
    failures << "n8n stage #{stage} requires active HelmRelease ownership policy" unless active_helm_releases.key?(inner_id)
  end
end

def validate_jellyfin_stage_state!(stage, outer, inner, active_kustomizations, active_helm_releases, failures)
  allowed_stages = %w[preparation config-active app-active]
  unless allowed_stages.include?(stage)
    failures << "Jellyfin activation stage is not recognized: #{stage}"
    return
  end
  unless outer.is_a?(Hash) && inner.is_a?(Hash)
    failures << "Jellyfin activation state requires both outer Kustomization and inner HelmRelease"
    return
  end

  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/jellyfin"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/jellyfin/jellyfin"
  outer_suspend = outer.dig("spec", "suspend")
  inner_suspend = inner.dig("spec", "suspend")
  outer_marker = outer.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  inner_marker = inner.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  outer_blocked = stage == "preparation"
  inner_blocked = stage != "app-active"

  failures << "Jellyfin outer Kustomization path must be #{JELLYFIN_PACKAGE_PATH}" unless outer.dig("spec", "path") == JELLYFIN_PACKAGE_PATH
  failures << "Jellyfin outer Kustomization must not depend on ESO" unless outer.dig("spec", "dependsOn").nil?
  failures << "Jellyfin outer Kustomization prune must remain false" unless outer.dig("spec", "prune") == false
  failures << "Jellyfin outer Kustomization suspend state does not match stage #{stage}" unless outer_suspend == outer_blocked
  failures << "Jellyfin inner HelmRelease suspend state does not match stage #{stage}" unless inner_suspend == inner_blocked
  failures << "Jellyfin outer Kustomization activation marker does not match stage #{stage}" unless (outer_marker == TREK_ACTIVATION_BLOCKED) == outer_blocked
  failures << "Jellyfin inner HelmRelease activation marker does not match stage #{stage}" unless (inner_marker == TREK_ACTIVATION_BLOCKED) == inner_blocked
  failures << "Jellyfin stage #{stage} must not activate an inner HelmRelease under a suspended outer Kustomization" if outer_suspend == true && inner_suspend == false

  if stage == "preparation"
    failures << "Jellyfin preparation must not be in active Kustomization ownership policy" if active_kustomizations.key?(outer_id)
    failures << "Jellyfin preparation must not be in active HelmRelease ownership policy" if active_helm_releases.key?(inner_id)
  else
    failures << "Jellyfin stage #{stage} requires active Kustomization ownership policy" unless active_kustomizations.key?(outer_id)
    failures << "Jellyfin stage #{stage} requires active HelmRelease ownership policy" unless active_helm_releases.key?(inner_id)
  end
end

def validate_grafana_stage_state!(stage, outer, inner, active_kustomizations, active_helm_releases, failures)
  allowed_stages = %w[preparation config-active app-active]
  unless allowed_stages.include?(stage)
    failures << "Grafana activation stage is not recognized: #{stage}"
    return
  end
  unless outer.is_a?(Hash) && inner.is_a?(Hash)
    failures << "Grafana activation state requires both outer Kustomization and inner HelmRelease"
    return
  end

  outer_id = "kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/grafana"
  inner_id = "helm.toolkit.fluxcd.io/v2/HelmRelease/grafana/grafana-k8s-monitoring"
  outer_suspend = outer.dig("spec", "suspend")
  inner_suspend = inner.dig("spec", "suspend")
  outer_marker = outer.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  inner_marker = inner.dig("metadata", "annotations", ACTIVATION_BLOCKED)
  outer_blocked = stage == "preparation"
  inner_blocked = stage != "app-active"

  failures << "Grafana outer Kustomization path must be #{GRAFANA_PACKAGE_PATH}" unless outer.dig("spec", "path") == GRAFANA_PACKAGE_PATH
  failures << "Grafana outer Kustomization dependsOn must be exactly eso-controller then eso-config" unless outer.dig("spec", "dependsOn") == [{"name" => "eso-controller"}, {"name" => "eso-config"}]
  failures << "Grafana outer Kustomization prune must remain false" unless outer.dig("spec", "prune") == false
  failures << "Grafana outer Kustomization suspend state does not match stage #{stage}" unless outer_suspend == outer_blocked
  failures << "Grafana inner HelmRelease suspend state does not match stage #{stage}" unless inner_suspend == inner_blocked
  failures << "Grafana outer Kustomization activation marker does not match stage #{stage}" unless (outer_marker == TREK_ACTIVATION_BLOCKED) == outer_blocked
  failures << "Grafana inner HelmRelease activation marker does not match stage #{stage}" unless (inner_marker == TREK_ACTIVATION_BLOCKED) == inner_blocked
  failures << "Grafana stage #{stage} must not activate an inner HelmRelease under a suspended outer Kustomization" if outer_suspend == true && inner_suspend == false

  if stage == "preparation"
    failures << "Grafana preparation must not be in active Kustomization ownership policy" if active_kustomizations.key?(outer_id)
    failures << "Grafana preparation must not be in active HelmRelease ownership policy" if active_helm_releases.key?(inner_id)
  else
    failures << "Grafana stage #{stage} requires active Kustomization ownership policy" unless active_kustomizations.key?(outer_id)
    failures << "Grafana stage #{stage} requires active HelmRelease ownership policy" unless active_helm_releases.key?(inner_id)
  end
end

def trek_config_active_release?(identity, stage, outer, active_kustomization_policies, active_helm_release_policies, active_helm_release_contracts)
  stage == "config-active" &&
    identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek" &&
    outer.is_a?(Hash) && outer.dig("spec", "suspend") == false &&
    outer.dig("metadata", "annotations", ACTIVATION_BLOCKED) != TREK_ACTIVATION_BLOCKED &&
    active_kustomization_policies.key?("kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek") &&
    active_helm_release_policies.key?(identity) &&
    active_helm_release_contracts.dig(identity, "trekStage") == "config-active"
end

def validate_eso_config_kustomization!(document, failures)
  spec = document.fetch("spec", {})
  failures << "active Kustomization eso-config: wait must be true" unless spec["wait"] == true
  unless spec["dependsOn"] == [{"name" => "eso-controller"}]
    failures << "active Kustomization eso-config: dependsOn must exactly be [{name: eso-controller}]"
  end
end

def validate_csi_secrets_store_kustomization!(document, failures)
  spec = document.fetch("spec", {})
  failures << "active Kustomization csi-secrets-store: wait must be true" unless spec["wait"] == true
  unless spec["dependsOn"] == [{"name" => "eso-config"}]
    failures << "active Kustomization csi-secrets-store: dependsOn must exactly be [{name: eso-config}]"
  end
end

def validate_eso_config_kustomization_for_phase!(phase, name, namespace, document, failures)
  return unless eso_config_active_phase?(phase) && name == "eso-config" && namespace == "flux-system"

  validate_eso_config_kustomization!(document, failures)
end

def validate_activation_chart_policy!(policy, identity, failures, artifact_cache, root, bootstrap_source_id)
  chart = policy["chart"]
  raise "active HelmRelease #{identity}: chart policy must be a mapping" unless chart.is_a?(Hash)

  chart_name = chart["name"].to_s
  chart_version = chart["version"].to_s
  raise "active HelmRelease #{identity}: chart.name is required" if chart_name.empty?
  unless chart_version.match?(/\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/)
    failures << "active HelmRelease #{identity}: chart.version must be an exact semantic version"
  end

  repository = chart["repository"]
  raise "active HelmRelease #{identity}: chart.repository must be a mapping" unless repository.is_a?(Hash)
  repository_identity = policy_identity(repository, "active HelmRelease #{identity} chart.repository")
  git_chart = repository["kind"] == "GitRepository"
  if git_chart
    unless repository["apiVersion"] == "source.toolkit.fluxcd.io/v1"
      failures << "active HelmRelease #{identity}: chart.repository must identify source.toolkit.fluxcd.io/v1/GitRepository"
    end
    expected_git = bootstrap_git_repository_id(bootstrap_source_id)
    unless repository_identity == expected_git
      failures << "active HelmRelease #{identity}: GitRepository must be the bootstrap flux-system source"
    end
    chart_path = chart["path"].to_s
    path_pathname = Pathname.new(chart_path)
    unless chart_path.start_with?("./") && !path_pathname.absolute? && !path_pathname.each_filename.include?("..")
      failures << "active HelmRelease #{identity}: chart.path must be a repository-relative path beginning with ./"
    end
    files_sha = chart["filesSha256"].to_s
    unless files_sha.match?(/\A[0-9a-f]{64}\z/)
      failures << "active HelmRelease #{identity}: chart.filesSha256 must be an exact lowercase SHA256"
    end
    actual_sha = local_chart_files_sha256(root, chart_path)
    if actual_sha.nil?
      failures << "active HelmRelease #{identity}: local chart path is missing or escapes the repository"
    elsif files_sha.match?(/\A[0-9a-f]{64}\z/) && actual_sha != files_sha
      failures << "active HelmRelease #{identity}: local chart filesSha256 mismatch"
    end
    repository_url = nil
  else
    unless repository["apiVersion"] == "source.toolkit.fluxcd.io/v1" && repository["kind"] == "HelmRepository"
      failures << "active HelmRelease #{identity}: chart.repository must identify source.toolkit.fluxcd.io/v1/HelmRepository"
    end
    repository_url = repository["url"].to_s
    unless repository_url.match?(%r{\Ahttps://[^[:space:]]+\z}) || repository_url.match?(%r{\Aoci://[^[:space:]]+\z})
      failures << "active HelmRelease #{identity}: chart.repository.url must use HTTPS or OCI"
    end
  end

  artifact = chart["artifact"]
  artifact_contract = nil
  if artifact
    raise "active HelmRelease #{identity}: chart.artifact must be a mapping" unless artifact.is_a?(Hash)
    artifact_url = artifact["url"].to_s
    artifact_sha = artifact["sha256"].to_s
    artifact_url_valid = artifact_url.match?(%r{\Ahttps://[^[:space:]]+\z})
    failures << "active HelmRelease #{identity}: chart.artifact.url must use HTTPS" unless artifact_url_valid
    unless artifact_sha.match?(/\A[0-9a-f]{64}\z/)
      failures << "active HelmRelease #{identity}: chart.artifact.sha256 must be an exact lowercase SHA256"
    end

    crd_templates = artifact["crdTemplates"]
    if crd_templates
      raise "active HelmRelease #{identity}: chart.artifact.crdTemplates must be a mapping" unless crd_templates.is_a?(Hash)
      prefix = crd_templates["pathPrefix"].to_s
      prefix_path = Pathname.new(prefix)
      prefix_valid = prefix.end_with?("/") && !prefix_path.absolute? && !prefix_path.each_filename.include?("..")
      failures << "active HelmRelease #{identity}: CRD template pathPrefix must be a safe archive prefix" unless prefix_valid
      expected_count = crd_templates["count"]
      unless expected_count.is_a?(Integer) && expected_count.positive?
        failures << "active HelmRelease #{identity}: CRD template count must be a positive integer"
      end
      expected_crd_sha = crd_templates["sha256"].to_s
      unless expected_crd_sha.match?(/\A[0-9a-f]{64}\z/)
        failures << "active HelmRelease #{identity}: CRD template sha256 must be an exact lowercase SHA256"
      end
    end

    crd_inventory = artifact["crdInventory"]
    if crd_inventory
      raise "active HelmRelease #{identity}: chart.artifact.crdInventory must be a mapping" unless crd_inventory.is_a?(Hash)
      prefix = crd_inventory["pathPrefix"].to_s
      prefix_path = Pathname.new(prefix)
      prefix_valid = prefix.end_with?("/") && !prefix_path.absolute? && !prefix_path.each_filename.include?("..")
      failures << "active HelmRelease #{identity}: CRD inventory pathPrefix must be a safe archive prefix" unless prefix_valid
      expected_count = crd_inventory["count"]
      failures << "active HelmRelease #{identity}: CRD inventory count must be a positive integer" unless expected_count.is_a?(Integer) && expected_count.positive?
      unless crd_inventory["setSha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
        failures << "active HelmRelease #{identity}: CRD inventory setSha256 must be an exact lowercase SHA256"
      end
    end

    resource_inventory = artifact["resourceInventory"]
    if resource_inventory
      unless resource_inventory.is_a?(Array) && !resource_inventory.empty?
        raise "active HelmRelease #{identity}: chart.artifact.resourceInventory must be a non-empty array"
      end
      inventory_ids = Set.new
      resource_inventory.each do |resource|
        resource_id = inventory_policy_identity(resource, "active HelmRelease #{identity} chart.artifact.resourceInventory entry")
        failures << "active HelmRelease #{identity}: duplicate chart artifact inventory entry #{resource_id}" unless inventory_ids.add?(resource_id)
      end
    end

    if artifact_url_valid && artifact_sha.match?(/\A[0-9a-f]{64}\z/)
      bytes = artifact_cache.fetch([artifact_url, artifact_sha]) do
        artifact_cache[[artifact_url, artifact_sha]] = verify_remote_sha256!(
          artifact_url,
          artifact_sha,
          "active HelmRelease #{identity} chart artifact",
          failures
        )
      end
      if bytes && crd_templates
        files = safe_archive_files(bytes, "active HelmRelease #{identity} chart artifact")
        prefix = crd_templates["pathPrefix"].to_s
        paths = files.keys.select { |path| path.start_with?(prefix) }
        expected_count = crd_templates["count"]
        unless paths.length == expected_count
          failures << "active HelmRelease #{identity}: CRD template inventory count mismatch: expected #{expected_count}; found #{paths.length}"
        end
        actual_crd_sha = archive_file_set_sha256(files, paths)
        unless actual_crd_sha == crd_templates["sha256"]
          failures << "active HelmRelease #{identity}: CRD template inventory checksum mismatch"
        end
      end
      if bytes && crd_inventory
        files = safe_archive_files(bytes, "active HelmRelease #{identity} chart artifact")
        prefix = crd_inventory["pathPrefix"].to_s
        paths = files.keys.select { |path| path.start_with?(prefix) }
        expected_count = crd_inventory["count"]
        unless paths.length == expected_count
          failures << "active HelmRelease #{identity}: CRD inventory count mismatch: expected #{expected_count}; found #{paths.length}"
        end
        actual_crd_sha = archive_file_set_sha256(files, paths)
        unless actual_crd_sha == crd_inventory["setSha256"]
          failures << "active HelmRelease #{identity}: CRD inventory set checksum mismatch"
        end
      end
      if bytes && resource_inventory
        validate_chart_resource_inventory!(bytes, identity, policy["namespace"], resource_inventory, failures)
      end
    end
    artifact_contract = artifact
  end

  safety = policy.fetch("safety", {})
  raise "active HelmRelease #{identity}: safety policy must be a mapping" unless safety.is_a?(Hash)
  if safety.key?("installCRDs") && ![true, false].include?(safety["installCRDs"])
    failures << "active HelmRelease #{identity}: safety.installCRDs must be a boolean"
  end
  if safety.key?("linuxCRDsEnabled") && ![true, false].include?(safety["linuxCRDsEnabled"])
    failures << "active HelmRelease #{identity}: safety.linuxCRDsEnabled must be a boolean"
  end
  if safety.key?("disableHooks") && ![true, false].include?(safety["disableHooks"])
    failures << "active HelmRelease #{identity}: safety.disableHooks must be a boolean"
  end
  if safety.key?("trekStage") && !%w[config-active app-active].include?(safety["trekStage"])
    failures << "active HelmRelease #{identity}: safety.trekStage must be config-active or app-active"
  end
  if safety.key?("activationStage") && !%w[config-active app-active].include?(safety["activationStage"])
    failures << "active HelmRelease #{identity}: safety.activationStage must be config-active or app-active"
  end

  owner_policy = policy.fetch("owner")
  policy_identity(owner_policy, "active HelmRelease #{identity} owner")
  {
    "sourceKind" => git_chart ? "GitRepository" : "HelmRepository",
    "chartName" => git_chart ? chart["path"].to_s : chart_name,
    "chartPath" => git_chart ? chart["path"].to_s : nil,
    "chartVersion" => chart_version,
    "repositoryIdentity" => repository_identity,
    "repositoryUrl" => repository_url,
    "ownerIdentity" => namespaced_identity("Kustomization", owner_policy["namespace"], owner_policy["name"]),
    "artifact" => artifact_contract,
    "installCRDs" => safety["installCRDs"],
    "disableHooks" => safety["disableHooks"],
    "linuxCRDsEnabled" => safety["linuxCRDsEnabled"],
    "trekStage" => safety["trekStage"],
    "activationStage" => safety["activationStage"]
  }
end

def validate_active_helm_release_safety(document, identity, contract, failures, memos_stage: nil, trek_stage: nil, n8n_stage: nil, jellyfin_stage: nil, grafana_stage: nil)
  spec = document["spec"]
  unless spec.is_a?(Hash)
    failures << "active HelmRelease #{identity}: spec must be a mapping"
    return
  end
  namespace = document.dig("metadata", "namespace").to_s
  name = document.dig("metadata", "name").to_s
  {
    "releaseName" => name,
    "targetNamespace" => namespace,
    "storageNamespace" => namespace
  }.each do |field, expected|
    failures << "active HelmRelease #{identity}: spec.#{field} must be #{expected}" unless spec[field] == expected
  end
  config_bypass = (contract["trekStage"] == "config-active" || contract["activationStage"] == "config-active") && spec["suspend"] == true
  if identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos"
    config_bypass &&= memos_stage == "config-active"
  end
  if identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek"
    config_bypass &&= trek_stage == "config-active"
  end
  if identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/n8n/n8n"
    config_bypass &&= n8n_stage == "config-active"
  end
  if identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/jellyfin/jellyfin"
    config_bypass &&= jellyfin_stage == "config-active"
  end
  if identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/grafana/grafana-k8s-monitoring"
    config_bypass &&= grafana_stage == "config-active"
  end
  return if config_bypass
  %w[install upgrade].each do |action|
    action_spec = spec[action]
    unless action_spec.is_a?(Hash)
      failures << "active HelmRelease #{identity}: spec.#{action} is required"
      next
    end
    failures << "active HelmRelease #{identity}: #{action}.crds must be Skip" unless action_spec["crds"] == "Skip"
    if contract["disableHooks"] == true && action_spec["disableHooks"] != true
      failures << "active HelmRelease #{identity}: #{action}.disableHooks must be true"
    end
    unless action_spec["disableTakeOwnership"] == true
      failures << "active HelmRelease #{identity}: #{action}.disableTakeOwnership must be true"
    end
  end
  unless contract["installCRDs"].nil?
    expected = contract["installCRDs"]
    unless spec.dig("values", "installCRDs") == expected
      failures << "active HelmRelease #{identity}: spec.values.installCRDs must be #{expected.inspect}"
    end
  end
  unless contract["linuxCRDsEnabled"].nil?
    expected = contract["linuxCRDsEnabled"]
    unless spec.dig("values", "linux", "crds", "enabled") == expected
      failures << "active HelmRelease #{identity}: spec.values.linux.crds.enabled must be #{expected.inspect}"
    end
  end
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
          .map { |container| container.is_a?(Hash) ? container["image"] : nil }
          .compact
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
  version_valid = version.match?(/\Av\d+\.\d+\.\d+\z/)
  unless version_valid
    failures << "fluxBootstrap.version must be an exact vMAJOR.MINOR.PATCH"
  end

  expected_release_url = "https://github.com/fluxcd/flux2/releases/tag/#{version}"
  failures << "fluxBootstrap.releaseUrl must be #{expected_release_url}" unless bootstrap["releaseUrl"] == expected_release_url

  components = bootstrap["components"]
  raise "fluxBootstrap.components must be a mapping" unless components.is_a?(Hash)
  expected_source_url = "https://github.com/fluxcd/flux2/releases/download/#{version}/install.yaml"
  source_url_valid = components["sourceUrl"] == expected_source_url
  unless source_url_valid
    failures << "fluxBootstrap components sourceUrl must be pinned to #{version}: #{expected_source_url}"
  end
  components_source_sha = components["sourceSha256"].to_s
  if components_source_sha.match?(/\A[0-9a-f]{64}\z/)
    verify_remote_sha256!(expected_source_url, components_source_sha, "Flux install.yaml", failures) if version_valid && source_url_valid
  else
    failures << "fluxBootstrap.components.sourceSha256 must be an exact lowercase SHA256"
  end

  relative_path = components["path"].to_s
  raise "fluxBootstrap.components.path is required" if relative_path.empty?
  path = repository_path(root, root.join(relative_path).cleanpath, "gotk-components")
  expected_sha = components["sha256"].to_s
  failures << "fluxBootstrap.components.sha256 must be an exact lowercase SHA256" unless expected_sha.match?(/\A[0-9a-f]{64}\z/)
  failures << "gotk-components checksum mismatch: #{relative_path}" unless Digest::SHA256.file(path).hexdigest == expected_sha
  validate_regenerated_components!(root, path, version, failures) if version_valid

  documents = yaml_file_documents(path)
  identity_list = documents.flat_map { |document| resource_documents(document) }.map do |document|
    required_identity(document, path.to_s)
  end
  duplicate_identities = identity_list.each_with_object(Hash.new(0)) { |identity, counts| counts[identity] += 1 }
    .select { |_identity, count| count > 1 }.keys
  if duplicate_identities.any?
    failures << "duplicate gotk-components resource identity: #{duplicate_identities.sort.join(', ')}"
  end
  identities = identity_list.to_set
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
    "requiredCRDs" => ["crds", "CRD"],
    "requiredClusterRoles" => ["clusterRoles", "ClusterRole"],
    "requiredClusterRoleBindings" => ["clusterRoleBindings", "ClusterRoleBinding"]
  }.each do |policy_key, inventory_key|
    expected = Array(components[policy_key])
    raise "fluxBootstrap.components.#{policy_key} must not be empty" if expected.empty?
    expected_set = expected.to_set
    failures << "duplicate fluxBootstrap.components.#{policy_key} entry" unless expected.length == expected_set.length
    actual_set = inventory.fetch(inventory_key.first)
    unless actual_set == expected_set
      failures << "gotk-components #{inventory_key.last} inventory mismatch: expected #{expected_set.to_a.sort.join(', ')}; found #{actual_set.to_a.sort.join(', ')}"
    end
  end

  identities
end

def validate_flux_schemas!(root, bootstrap, failures)
  version = bootstrap["version"].to_s
  version_valid = version.match?(/\Av\d+\.\d+\.\d+\z/)
  schemas = bootstrap["schemas"]
  raise "fluxBootstrap.schemas must be a mapping" unless schemas.is_a?(Hash)

  expected_source_url = "https://github.com/fluxcd/flux2/releases/download/#{version}/crd-schemas.tar.gz"
  source_url_valid = schemas["sourceUrl"] == expected_source_url
  failures << "fluxBootstrap schemas sourceUrl must be pinned to #{version}: #{expected_source_url}" unless source_url_valid
  schemas_source_sha = schemas["sourceSha256"].to_s
  archive_bytes = nil
  if schemas_source_sha.match?(/\A[0-9a-f]{64}\z/)
    if version_valid && source_url_valid
      archive_bytes = verify_remote_sha256!(expected_source_url, schemas_source_sha, "Flux crd-schemas.tar.gz", failures)
    end
  else
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
  upstream_files = archive_bytes ? safe_archive_files(archive_bytes, "Flux crd-schemas.tar.gz") : {}
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
    if archive_bytes
      upstream_content = upstream_files[filename]
      if upstream_content.nil?
        failures << "Flux schema #{filename} is missing from upstream schema archive"
      elsif File.binread(path) != upstream_content
        failures << "Flux schema #{filename} does not match upstream schema archive"
      end
    end
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
activation = policy[FLUX_ACTIVATION_POLICY_KEY]
approved_active_kustomizations = Set.new
approved_active_helm_releases = Set.new
active_kustomization_policies = {}
active_helm_release_policies = {}
active_cluster_secret_store_policies = {}
active_helm_release_contracts = {}
if activation
  raise "#{FLUX_ACTIVATION_POLICY_KEY} must be a mapping" unless activation.is_a?(Hash)
  %w[phase reason].each do |field|
    raise "#{FLUX_ACTIVATION_POLICY_KEY}.#{field} is required" if activation[field].to_s.strip.empty?
  end
  validate_activation_phase_contract!(activation, failures)
  active_kustomization_policies = activation_policy_map(
    activation,
    "activeKustomizations",
    "kustomize.toolkit.fluxcd.io/v1",
    "Kustomization",
    failures
  )
  active_helm_release_policies = activation_policy_map(
    activation,
    "activeHelmReleases",
    "helm.toolkit.fluxcd.io/v2",
    "HelmRelease",
    failures
  )
  active_cluster_secret_store_policies = active_cluster_secret_store_policies_for_phase(activation["phase"])
  approved_active_kustomizations = active_kustomization_policies.keys.to_set
  approved_active_helm_releases = active_helm_release_policies.keys.to_set
  raise "#{FLUX_ACTIVATION_POLICY_KEY} must approve at least one active Kustomization" if approved_active_kustomizations.empty?
  blocked_policy_failures = []
  if active_kustomization_policies.values.any? { |entry| entry["name"] == "nextcloud" }
    blocked_policy_failures << "Nextcloud Flux Kustomization must remain suspended"
  end
  if active_helm_release_policies.values.any? { |entry| entry["name"] == "nextcloud" }
    blocked_policy_failures << "Nextcloud HelmRelease must remain suspended"
  end
  raise blocked_policy_failures.join("\n") if blocked_policy_failures.any?
  if bootstrap_root_id && approved_active_kustomizations.include?(bootstrap_root_id)
    failures << "bootstrap root must not be listed in #{FLUX_ACTIVATION_POLICY_KEY}.activeKustomizations"
  end
  artifact_cache = {}
  active_kustomization_policies.each do |identity, entry|
    path = entry["path"].to_s
    raise "active Kustomization #{identity}: path is required" if path.empty?
    failures << "active Kustomization #{identity}: path must be repository-relative and begin with ./" unless path.start_with?("./")
    if BLOCKED_ACTIVATION_PATHS.include?(path)
      failures << "active Kustomization #{identity}: Nextcloud package path must remain blocked"
    end
    inventory = entry["inventory"]
    raise "active Kustomization #{identity}: inventory must be a non-empty array" unless inventory.is_a?(Array) && !inventory.empty?
    inventory_ids = Set.new
    inventory.each do |resource|
      resource_id = inventory_policy_identity(resource, "active Kustomization #{identity} inventory entry")
      failures << "active Kustomization #{identity}: duplicate inventory entry #{resource_id}" unless inventory_ids.add?(resource_id)
    end
    if (inventory_ids & BLOCKED_ACTIVATION_OBJECTS).any?
      failures << "active Kustomization #{identity}: Nextcloud inventory must remain blocked"
    end
    entry["__inventory_ids"] = inventory_ids
  end
  active_helm_release_policies.each do |identity, entry|
    contract = validate_activation_chart_policy!(entry, identity, failures, artifact_cache, root, bootstrap_source_id)
    active_helm_release_contracts[identity] = contract
    owner = entry.fetch("owner")
    unless approved_active_kustomizations.any? do |kustomization_id|
      expected_owner = active_kustomization_policies.fetch(kustomization_id)
      %w[apiVersion kind namespace name].all? { |field| owner[field] == expected_owner[field] }
    end
      failures << "active HelmRelease #{identity}: owner must be an approved active Kustomization"
    end
  end
  inventory_helm_releases = active_kustomization_policies.values.flat_map do |entry|
    entry.fetch("__inventory_ids").select { |identity| identity.start_with?("helm.toolkit.fluxcd.io/v2/HelmRelease/") }
  end.to_set
  unless inventory_helm_releases == approved_active_helm_releases
    failures << "#{FLUX_ACTIVATION_POLICY_KEY}: active HelmRelease policy must exactly match active Kustomization inventory"
  end
end
allowed_bootstrap_sources = Set.new(Array(policy[BOOTSTRAP_SOURCE_POLICY_KEY]).map do |entry|
  [entry.fetch("apiVersion"), entry.fetch("kind"), entry.fetch("namespace").to_s, entry.fetch("name")].join("/")
end)

flux_files = root.join("clusters").glob("**/*").select do |path|
  path.file? && (KUSTOMIZATION_FILENAMES.include?(path.basename.to_s) || %w[.yaml .yml .json].include?(path.extname.downcase))
end
flux_entries = flux_files.flat_map do |path|
  yaml_file_documents(path).flat_map { |document| resource_documents(document) }.each_with_object([]) do |doc, entries|
    next unless doc.is_a?(Hash) && doc["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && doc["kind"] == "Kustomization"
    entries << [repository_path(root, path, "Flux input"), doc]
  end
end
raise "no Flux Kustomizations found" if flux_entries.empty?

if bootstrap
  source_policy = bootstrap.fetch("source")
  source_inputs = flux_files.flat_map do |path|
    yaml_file_documents(path).flat_map { |document| resource_documents(document) }.each_with_object([]) do |document, entries|
      next unless document.is_a?(Hash) && document["apiVersion"] == source_policy["apiVersion"] && document["kind"] == source_policy["kind"]
      next unless required_identity(document, path.to_s) == bootstrap_source_id
      entries << [path, document]
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
declared_flux_resources = {}
flux_by_identity = {}
package_objects = {}
actual_active_kustomization_owners = Set.new

# First pass: collect every Flux identity and render every target package. No dependency
# or source validation is performed here, so declaration order cannot affect the result.
flux_entries.each do |source_path, resource|
  name = resource.dig("metadata", "name")
  namespace = resource.dig("metadata", "namespace").to_s
  raise "#{source_path}: Flux Kustomization is missing metadata.name" unless name.is_a?(String) && !name.empty?
  flux_id = required_identity(resource, source_path.to_s)
  raise "duplicate Flux Kustomization #{flux_id}: #{seen_flux_identities[flux_id]} and #{source_path}" if seen_flux_identities.key?(flux_id)
  seen_flux_identities[flux_id] = source_path
  declared_flux_resources[flux_id] = resource
  flux_by_identity[namespaced_identity("Kustomization", namespace, name)] = resource

  spec = resource["spec"]
  raise "Flux Kustomization #{name}: spec is missing" unless spec.is_a?(Hash)
  is_bootstrap_root = bootstrap_root_id == flux_id
  if is_bootstrap_root
    root_policy = bootstrap.fetch("root")
    failures << "bootstrap root prune must be #{root_policy['prune'].inspect}" unless spec["prune"] == root_policy["prune"]
    failures << "bootstrap root must not be suspended" if spec["suspend"] == true
  elsif approved_active_kustomizations.include?(flux_id)
    failures << "approved active Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
    failures << "approved active Flux Kustomization #{name}: suspend must be false" unless spec["suspend"] == false
    expected_path = active_kustomization_policies.fetch(flux_id)["path"]
    failures << "active Kustomization path must be #{expected_path}: #{flux_id}" unless spec["path"] == expected_path
    validate_eso_config_kustomization_for_phase!(activation&.fetch("phase", nil), name, namespace, resource, failures)
    if activation && activation["phase"] == "csi-secrets-store" && name == "csi-secrets-store" && namespace == "flux-system"
      validate_csi_secrets_store_kustomization!(resource, failures)
    end
  else
    failures << "Flux Kustomization #{name}: prune must be false" unless spec["prune"] == false
    failures << "Flux Kustomization #{name}: suspend must be true" unless spec["suspend"] == true
  end
  owner = namespaced_identity("Kustomization", namespace, name)
  actual_active_kustomization_owners << owner if !is_bootstrap_root && spec["suspend"] == false
  if name == "nextcloud" && spec["suspend"] != true
    failures << "Nextcloud Flux Kustomization must remain suspended"
  end
  path_value = spec["path"]
  raise "Flux Kustomization #{name}: spec.path is required" unless path_value.is_a?(String) && !path_value.empty?
  if !is_bootstrap_root && BLOCKED_ACTIVATION_PATHS.include?(path_value) && spec["suspend"] != true
    failures << "Nextcloud package path must remain suspended: #{path_value}"
  end
  if is_bootstrap_root && path_value != bootstrap.dig("root", "path")
    raise "bootstrap root path must be #{bootstrap.dig('root', 'path')}"
  end
  package_dir = root.join(path_value.sub(%r{\A\./}, "")).cleanpath
  validate_kustomize_composition!(root, package_dir) if is_bootstrap_root
  package_objects[namespaced_identity("Kustomization", namespace, name)] = render_package(root, package_dir, name)
end
failures << "bootstrap root Kustomization is missing: #{bootstrap_root_id}" if bootstrap_root_id && !seen_flux_identities.key?(bootstrap_root_id)
missing_active_kustomizations = approved_active_kustomizations - seen_flux_identities.keys.to_set
missing_active_kustomizations.each do |identity|
  failures << "approved active Flux Kustomization is missing: #{identity}"
end

# Every rendered Flux Kustomization must have an identical declaration under clusters/.
# This rejects Flux CRs smuggled through external package resources while still allowing
# the bootstrap root to render its own reviewed declarations.
package_objects.each do |owner, entries|
  entries.each do |path, resource|
    next unless resource.is_a?(Hash) && resource["apiVersion"] == "kustomize.toolkit.fluxcd.io/v1" && resource["kind"] == "Kustomization"

    flux_id = required_identity(resource, path.to_s)
    declared = declared_flux_resources[flux_id]
    if declared.nil?
      failures << "rendered Flux Kustomization is not declared under clusters: #{flux_id} (owner #{owner})"
    elsif declared != resource
      failures << "rendered Flux Kustomization differs from its declaration under clusters: #{flux_id} (owner #{owner})"
    end
  end
end

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
  root_identities = root_entries.each_with_object([]) do |(path, document), identities|
    next unless document.is_a?(Hash)
    identities << required_identity(document, path.to_s)
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
rendered_documents = {}
package_objects.each do |owner, entries|
  entries.each do |path, doc|
    next unless doc.is_a?(Hash)
    id = required_identity(doc, path.to_s)
    if seen_objects.key?(id)
      previous_owner, previous_path = seen_objects[id]
      raise "duplicate Flux-owned object #{id}: owner #{previous_owner} source #{previous_path}; owner #{owner} source #{path}"
    end
    seen_objects[id] = [owner, path]
    rendered_documents[id] = doc
  end
end
active_kustomization_policies.each do |identity, entry|
  policy_owner = namespaced_identity("Kustomization", entry["namespace"], entry["name"])
  actual_inventory = Array(package_objects[policy_owner]).each_with_object(Set.new) do |(path, document), identities|
    identities << required_identity(document, path.to_s) if document.is_a?(Hash)
  end
  expected_inventory = entry.fetch("__inventory_ids")
  unless actual_inventory == expected_inventory
    failures << "active Kustomization #{identity}: rendered inventory mismatch: " \
                "expected #{expected_inventory.to_a.sort.join(', ')}; " \
                "found #{actual_inventory.to_a.sort.join(', ')}"
  end
end

trek_activation = policy["trekActivation"]
trek_activation_stage = trek_activation.is_a?(Hash) ? trek_activation["stage"] : nil
trek_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek"]
memos_activation = policy["memosActivation"]
memos_activation_stage = memos_activation.is_a?(Hash) ? memos_activation["stage"] : nil
n8n_activation = policy["n8nActivation"]
n8n_activation_stage = n8n_activation.is_a?(Hash) ? n8n_activation["stage"] : nil
jellyfin_activation = policy["jellyfinActivation"]
jellyfin_activation_stage = jellyfin_activation.is_a?(Hash) ? jellyfin_activation["stage"] : nil
grafana_activation = policy["grafanaActivation"]
grafana_activation_stage = grafana_activation.is_a?(Hash) ? grafana_activation["stage"] : nil
config_active_release = lambda do |identity|
  trek_config_active_release?(identity, trek_activation_stage, trek_outer, active_kustomization_policies, active_helm_release_policies, active_helm_release_contracts) ||
    (
      identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos" &&
        memos_activation_stage == "config-active" &&
        active_helm_release_contracts.dig(identity, "activationStage") == "config-active"
    ) ||
    (
      identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/n8n/n8n" &&
        n8n_activation_stage == "config-active" &&
        active_helm_release_contracts.dig(identity, "activationStage") == "config-active"
    ) ||
    (
      identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/jellyfin/jellyfin" &&
        jellyfin_activation_stage == "config-active" &&
        active_helm_release_contracts.dig(identity, "activationStage") == "config-active"
    ) ||
    (
      identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/grafana/grafana-k8s-monitoring" &&
        grafana_activation_stage == "config-active" &&
        active_helm_release_contracts.dig(identity, "activationStage") == "config-active"
    )
end

actual_active_kustomization_owners.each do |owner|
  Array(package_objects[owner]).each do |path, document|
    next unless document.is_a?(Hash)

    object_id = required_identity(document, path.to_s)
    trek_config_exception = config_active_release.call(object_id)
    if (BLOCKED_ACTIVATION_OBJECTS.include?(object_id) || document.dig("metadata", "annotations", ACTIVATION_BLOCKED) == "true") && !trek_config_exception
      failures << "active Flux Kustomization #{owner} renders a blocked Nextcloud object: #{object_id}"
    end
  end
end

trek_activation = policy["trekActivation"]
if trek_activation
  unless trek_activation.is_a?(Hash) && trek_activation["stage"].is_a?(String) && !trek_activation["stage"].empty? && trek_activation["reason"].to_s.strip != ""
    failures << "trekActivation must declare a stage and reason"
  else
    trek_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/trek"]
    trek_inner = rendered_documents["helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek"]
    validate_trek_stage_state!(trek_activation["stage"], trek_outer, trek_inner, active_kustomization_policies, active_helm_release_policies, failures)
  end
end

if memos_activation
  unless memos_activation.is_a?(Hash) && memos_activation["stage"].is_a?(String) && !memos_activation["stage"].empty? && memos_activation["reason"].to_s.strip != ""
    failures << "memosActivation must declare a stage and reason"
  else
    memos_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/memos"]
    memos_inner = rendered_documents["helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos"]
    validate_memos_stage_state!(memos_activation["stage"], memos_outer, memos_inner, active_kustomization_policies, active_helm_release_policies, failures)
  end
end

if n8n_activation
  unless n8n_activation.is_a?(Hash) && n8n_activation["stage"].is_a?(String) && !n8n_activation["stage"].empty? && n8n_activation["reason"].to_s.strip != ""
    failures << "n8nActivation must declare a stage and reason"
  else
    n8n_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/n8n"]
    n8n_inner = rendered_documents["helm.toolkit.fluxcd.io/v2/HelmRelease/n8n/n8n"]
    validate_n8n_stage_state!(n8n_activation["stage"], n8n_outer, n8n_inner, active_kustomization_policies, active_helm_release_policies, failures)
  end
end

if jellyfin_activation
  unless jellyfin_activation.is_a?(Hash) && jellyfin_activation["stage"].is_a?(String) && !jellyfin_activation["stage"].empty? && jellyfin_activation["reason"].to_s.strip != ""
    failures << "jellyfinActivation must declare a stage and reason"
  else
    jellyfin_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/jellyfin"]
    jellyfin_inner = rendered_documents["helm.toolkit.fluxcd.io/v2/HelmRelease/jellyfin/jellyfin"]
    validate_jellyfin_stage_state!(jellyfin_activation["stage"], jellyfin_outer, jellyfin_inner, active_kustomization_policies, active_helm_release_policies, failures)
  end
end

if grafana_activation
  unless grafana_activation.is_a?(Hash) && grafana_activation["stage"].is_a?(String) && !grafana_activation["stage"].empty? && grafana_activation["reason"].to_s.strip != ""
    failures << "grafanaActivation must declare a stage and reason"
  else
    grafana_outer = declared_flux_resources["kustomize.toolkit.fluxcd.io/v1/Kustomization/flux-system/grafana"]
    grafana_inner = rendered_documents["helm.toolkit.fluxcd.io/v2/HelmRelease/grafana/grafana-k8s-monitoring"]
    validate_grafana_stage_state!(grafana_activation["stage"], grafana_outer, grafana_inner, active_kustomization_policies, active_helm_release_policies, failures)
  end
end

# Config activation removes markers from configuration resources while retaining the
# deliberate blocked marker on the suspended inner HelmRelease.
trek_package_owner = namespaced_identity("Kustomization", "flux-system", "trek")
if trek_activation_stage && Array(package_objects[trek_package_owner]).any?
  Array(package_objects[trek_package_owner]).each do |path, document|
    next unless document.is_a?(Hash)
    identity = required_identity(document, path.to_s)
    annotations = document.dig("metadata", "annotations") || {}
    labels = document.dig("metadata", "labels") || {}
    marked = annotations[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED || labels[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED
    allowed_inner = identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/trek/trek" && trek_activation_stage != "app-active"
    allowed_namespace = identity == "v1/Namespace//trek" && trek_activation_stage == "preparation"
    failures << "TREK stage #{trek_activation_stage}: unexpected activation-blocked marker on #{identity}" if marked && !allowed_inner && !allowed_namespace
    if trek_activation_stage != "preparation" && allowed_namespace && marked
      failures << "TREK stage #{trek_activation_stage}: Namespace/trek activation markers must be removed"
    end
  end
end

memos_package_owner = namespaced_identity("Kustomization", "flux-system", "memos")
if memos_activation_stage && Array(package_objects[memos_package_owner]).any?
  Array(package_objects[memos_package_owner]).each do |path, document|
    next unless document.is_a?(Hash)
    identity = required_identity(document, path.to_s)
    annotations = document.dig("metadata", "annotations") || {}
    labels = document.dig("metadata", "labels") || {}
    marked = annotations[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED || labels[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED
    allowed_inner = identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/memos/memos" && memos_activation_stage != "app-active"
    allowed_namespace = identity == "v1/Namespace//memos" && memos_activation_stage == "preparation"
    failures << "Memos stage #{memos_activation_stage}: unexpected activation-blocked marker on #{identity}" if marked && !allowed_inner && !allowed_namespace
    if memos_activation_stage != "preparation" && identity == "v1/Namespace//memos" && marked
      failures << "Memos stage #{memos_activation_stage}: Namespace/memos activation markers must be removed"
    end
  end
end

n8n_package_owner = namespaced_identity("Kustomization", "flux-system", "n8n")
if n8n_activation_stage && Array(package_objects[n8n_package_owner]).any?
  Array(package_objects[n8n_package_owner]).each do |path, document|
    next unless document.is_a?(Hash)
    identity = required_identity(document, path.to_s)
    annotations = document.dig("metadata", "annotations") || {}
    labels = document.dig("metadata", "labels") || {}
    marked = annotations[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED || labels[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED
    allowed_inner = identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/n8n/n8n" && n8n_activation_stage != "app-active"
    allowed_namespace = identity == "v1/Namespace//n8n" && n8n_activation_stage == "preparation"
    failures << "n8n stage #{n8n_activation_stage}: unexpected activation-blocked marker on #{identity}" if marked && !allowed_inner && !allowed_namespace
    if n8n_activation_stage != "preparation" && identity == "v1/Namespace//n8n" && marked
      failures << "n8n stage #{n8n_activation_stage}: Namespace/n8n activation markers must be removed"
    end
  end
end

jellyfin_package_owner = namespaced_identity("Kustomization", "flux-system", "jellyfin")
if jellyfin_activation_stage && Array(package_objects[jellyfin_package_owner]).any?
  Array(package_objects[jellyfin_package_owner]).each do |path, document|
    next unless document.is_a?(Hash)
    identity = required_identity(document, path.to_s)
    annotations = document.dig("metadata", "annotations") || {}
    labels = document.dig("metadata", "labels") || {}
    marked = annotations[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED || labels[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED
    allowed_inner = identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/jellyfin/jellyfin" && jellyfin_activation_stage != "app-active"
    allowed_namespace = identity == "v1/Namespace//jellyfin" && jellyfin_activation_stage == "preparation"
    failures << "Jellyfin stage #{jellyfin_activation_stage}: unexpected activation-blocked marker on #{identity}" if marked && !allowed_inner && !allowed_namespace
    if jellyfin_activation_stage != "preparation" && identity == "v1/Namespace//jellyfin" && marked
      failures << "Jellyfin stage #{jellyfin_activation_stage}: Namespace/jellyfin activation markers must be removed"
    end
  end
end

grafana_package_owner = namespaced_identity("Kustomization", "flux-system", "grafana")
if grafana_activation_stage && Array(package_objects[grafana_package_owner]).any?
  Array(package_objects[grafana_package_owner]).each do |path, document|
    next unless document.is_a?(Hash)
    identity = required_identity(document, path.to_s)
    annotations = document.dig("metadata", "annotations") || {}
    labels = document.dig("metadata", "labels") || {}
    marked = annotations[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED || labels[ACTIVATION_BLOCKED] == TREK_ACTIVATION_BLOCKED
    allowed_inner = identity == "helm.toolkit.fluxcd.io/v2/HelmRelease/grafana/grafana-k8s-monitoring" && grafana_activation_stage != "app-active"
    allowed_namespace = identity == "v1/Namespace//grafana" && grafana_activation_stage == "preparation"
    failures << "Grafana stage #{grafana_activation_stage}: unexpected activation-blocked marker on #{identity}" if marked && !allowed_inner && !allowed_namespace
    if grafana_activation_stage != "preparation" && identity == "v1/Namespace//grafana" && marked
      failures << "Grafana stage #{grafana_activation_stage}: Namespace/grafana activation markers must be removed"
    end
  end
end

package_objects.each do |_owner, entries|
  entries.each do |path, doc|
    next unless doc.is_a?(Hash) && doc["kind"] == "HelmRelease"
    id = required_identity(doc, path.to_s)
    if doc["spec"].is_a?(Hash)
    else
      failures << "HelmRelease #{id}: spec must be a mapping"
      next
    end
    if approved_active_helm_releases.include?(id)
      contract = active_helm_release_contracts.fetch(id)
      suspended_config_stage = contract["trekStage"] == "config-active" || contract["activationStage"] == "config-active"
      unless doc.dig("spec", "suspend") == false || (suspended_config_stage && config_active_release.call(id))
        failures << "approved active HelmRelease #{id}: suspend must be false"
      end
      validate_active_helm_release_safety(doc, id, contract, failures, memos_stage: memos_activation_stage, trek_stage: trek_activation_stage, n8n_stage: n8n_activation_stage, jellyfin_stage: jellyfin_activation_stage, grafana_stage: grafana_activation_stage)
      chart_spec = doc.dig("spec", "chart", "spec")
      unless chart_spec.is_a?(Hash) && chart_spec["chart"] == contract["chartName"]
        failures << "active HelmRelease #{id}: chart name must be #{contract['chartName']}"
      end
      if contract["sourceKind"] != "GitRepository"
        unless chart_spec.is_a?(Hash) && chart_spec["version"] == contract["chartVersion"]
          failures << "active HelmRelease #{id}: chart version must be #{contract['chartVersion']}"
        end
      end
    else
      failures << "HelmRelease #{id}: suspend must be true" unless doc.dig("spec", "suspend") == true
    end
    if doc.dig("metadata", "name") == "nextcloud" && doc.dig("spec", "suspend") != true
      failures << "Nextcloud HelmRelease must remain suspended"
    end
    chart_ref = doc.dig("spec", "chart", "spec", "sourceRef")
    chart_kind = chart_ref.is_a?(Hash) ? chart_ref["kind"].to_s : ""
    chart_name = chart_ref.is_a?(Hash) ? chart_ref["name"].to_s : ""
    if !chart_ref.is_a?(Hash) || chart_name.empty? || !%w[HelmRepository GitRepository].include?(chart_kind)
      failures << "HelmRelease #{id}: chart.spec.sourceRef HelmRepository is required"
    elsif chart_kind == "GitRepository"
      ref_ns = chart_ref["namespace"] || doc.dig("metadata", "namespace").to_s
      repo_id = ["source.toolkit.fluxcd.io/v1", "GitRepository", ref_ns.to_s, chart_name].join("/")
      expected_git = bootstrap_git_repository_id(bootstrap_source_id)
      failures << "HelmRelease #{id}: GitRepository sourceRef is missing or mismatched: #{repo_id}" unless seen_objects.key?(repo_id)
      failures << "HelmRelease #{id}: GitRepository sourceRef must be the bootstrap flux-system source" unless repo_id == expected_git
      chart_path = doc.dig("spec", "chart", "spec", "chart").to_s
      failures << "HelmRelease #{id}: GitRepository chart path must be repository-relative and begin with ./" unless chart_path.start_with?("./")
      if approved_active_helm_releases.include?(id)
        contract = active_helm_release_contracts.fetch(id)
        if contract["sourceKind"] != "GitRepository"
          failures << "active HelmRelease #{id}: GitRepository chart source is not approved"
        else
          unless repo_id == contract["repositoryIdentity"]
            failures << "active HelmRelease #{id}: GitRepository identity must be #{contract['repositoryIdentity']}"
          end
          unless chart_path == contract["chartPath"]
            failures << "active HelmRelease #{id}: GitRepository chart path must be #{contract['chartPath']}"
          end
        end
      end
    else
      ref_ns = chart_ref["namespace"] || doc.dig("metadata", "namespace").to_s
      repo_id = ["source.toolkit.fluxcd.io/v1", "HelmRepository", ref_ns.to_s, chart_name].join("/")
      failures << "HelmRelease #{id}: HelmRepository sourceRef is missing or mismatched: #{repo_id}" unless seen_objects.key?(repo_id)
      if approved_active_helm_releases.include?(id)
        contract = active_helm_release_contracts.fetch(id)
        unless repo_id == contract["repositoryIdentity"]
          failures << "active HelmRelease #{id}: HelmRepository identity must be #{contract['repositoryIdentity']}"
        end
        repository = rendered_documents[repo_id]
        unless repository && repository.dig("spec", "url") == contract["repositoryUrl"]
          failures << "active HelmRelease #{id}: HelmRepository URL must be #{contract['repositoryUrl']}"
        end
      end
    end
  end
end
missing_active_helm_releases = approved_active_helm_releases - seen_objects.keys.to_set
missing_active_helm_releases.each do |identity|
  failures << "approved active HelmRelease is missing: #{identity}"
end
missing_active_cluster_secret_stores = active_cluster_secret_store_policies.keys.to_set - seen_objects.keys.to_set
missing_active_cluster_secret_stores.each do |identity|
  failures << "approved active ClusterSecretStore is missing: #{identity}"
end
active_cluster_secret_store_policies.each do |identity, policy_entry|
  next unless seen_objects.key?(identity)

  owner = seen_objects.fetch(identity).first
  expected_owner = namespaced_identity("Kustomization", "flux-system", "eso-config")
  failures << "active ClusterSecretStore #{identity}: owner must be #{expected_owner}" unless owner == expected_owner
  unless actual_active_kustomization_owners.include?(owner)
    failures << "active ClusterSecretStore #{identity} is rendered by a suspended Flux Kustomization #{owner}"
  end
  validate_active_cluster_secret_store!(rendered_documents.fetch(identity), identity, policy_entry, failures)
end
approved_active_helm_releases.each do |identity|
  next unless seen_objects.key?(identity)

  owner = seen_objects.fetch(identity).first
  expected_owner = active_helm_release_contracts.fetch(identity)["ownerIdentity"]
  failures << "active HelmRelease #{identity}: owner must be #{expected_owner}" unless owner == expected_owner
  unless actual_active_kustomization_owners.include?(owner)
    failures << "active HelmRelease #{identity} is rendered by a suspended Flux Kustomization #{owner}"
  end
end
actual_active_kustomization_owners.each do |owner|
  Array(package_objects[owner]).each do |path, doc|
    next unless doc.is_a?(Hash) && doc["kind"] == "HelmRelease"

    identity = required_identity(doc, path.to_s)
    release_active = doc["spec"].is_a?(Hash) && doc["spec"]["suspend"] == false
    config_exception = config_active_release.call(identity) && !release_active
    unless approved_active_helm_releases.include?(identity) && (release_active || config_exception)
      failures << "active Flux Kustomization #{owner} must activate HelmRelease #{identity} in the same policy"
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
