#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

module ManifestPolicyHelpers
  module_function

  KUSTOMIZATION_FILENAMES = %w[kustomization.yaml kustomization.yml Kustomization].freeze

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
    return false if name.to_s.match?(/\AALLOW_EMPTY_(?:PASSWORD|PASSWD)\z/i)

    name.to_s.match?(
      /(?:password|passwd|token|api_?key|private_?key|encryption_?key|secret(?:_?key(?:_?base)?)?|credential|access_?key|client_?secret|database_?url)\z/i
    ) || name.to_s.match?(/\Aaws_?secret_?access_?key\z/i)
  end

  def literal_value?(value)
    !value.nil? && !value.is_a?(Hash) && !value.is_a?(Array) && !value.to_s.empty?
  end

  def each_extra_env_literal(value, &block)
    case value
    when Hash
      value.each do |name, entry|
        if sensitive_environment_name?(name)
          literal = if entry.is_a?(Hash) && entry.key?("value")
                      entry["value"]
                    elsif literal_value?(entry)
                      entry
                    end
          block.call(name, literal) if literal_value?(literal)
        end
        each_extra_env_literal(entry, &block) if entry.is_a?(Hash) || entry.is_a?(Array)
      end
    when Array
      value.each { |child| each_extra_env_literal(child, &block) }
    end
  end

  def each_sensitive_environment_literal(value, &block)
    case value
    when Hash
      if sensitive_environment_name?(value["name"]) && value.key?("value") && literal_value?(value["value"])
        block.call(value["name"], value["value"])
      end
      each_extra_env_literal(value["extraEnv"], &block) if value.key?("extraEnv")
      value.each_value { |child| each_sensitive_environment_literal(child, &block) }
    when Array
      value.each { |child| each_sensitive_environment_literal(child, &block) }
    end
  end

  def floating_image?(image)
    return false if image.include?("@sha256:")

    last_segment = image.split("/").last
    return true unless last_segment.include?(":")

    %w[latest release].include?(last_segment.split(":", 2).last)
  end

  def package_kustomization?(path, document)
    document["kind"] == "Kustomization" &&
      document["apiVersion"] == "kustomize.config.k8s.io/v1beta1" &&
      kustomization_file?(path)
  end

  def kustomization_file?(path)
    KUSTOMIZATION_FILENAMES.include?(File.basename(path))
  end

  def kustomization_in(directory)
    KUSTOMIZATION_FILENAMES
      .map { |filename| File.join(directory.to_s, filename) }
      .find { |candidate| File.file?(candidate) }
  end

  def cluster_admin_binding?(document)
    %w[RoleBinding ClusterRoleBinding].include?(document["kind"]) &&
      document.dig("roleRef", "name") == "cluster-admin"
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
end
