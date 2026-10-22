#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "uri"
require "yaml"

module WorkflowKit
  class ContextError < StandardError; end

  # Resolves project facts afresh for every call. It deliberately has no
  # process-global project cache: changing Git roots must also change context.
  module ProjectContext
    SENSITIVE_OPERATIONS = %w[database authentication deployment].freeze
    APPROVED_STATUSES = %w[approved verified].freeze

    module_function

    def git(root, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      raise ContextError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def root_for(path)
      candidate = File.realpath(path)
      root = git(candidate, "rev-parse", "--show-toplevel").strip
      File.realpath(root)
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ContextError, "cannot resolve project root: #{error.message}"
    end

    def safe_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue Psych::Exception => error
      raise ContextError, "cannot parse #{path}: #{error.message}"
    end

    def normalize_remote(value)
      raw = value.to_s.strip
      return "" if raw.empty?

      raw = raw.sub(/\A[^@\s]+@([^:]+):/, 'ssh://\1/')
      uri = URI.parse(raw)
      host = uri.host.to_s.downcase
      path = uri.path.to_s.sub(/\A\//, "").sub(/\.git\z/, "")
      return [host, path].reject(&:empty?).join("/") unless host.empty?

      raw.sub(%r{\A(?:file://)?}, "").sub(/\.git\z/, "")
    rescue URI::InvalidURIError
      raw.gsub(%r{\A[^@/]+@}, "").sub(/\.git\z/, "")
    end

    def project_id(root, installation, project_map)
      candidates = [
        installation.is_a?(Hash) ? installation["project_id"] : nil,
        project_map.is_a?(Hash) ? project_map["project_id"] : nil,
        project_map.is_a?(Hash) ? project_map.dig("project", "id") : nil,
        project_map.is_a?(Hash) ? project_map.dig("workspace", "name") : nil,
      ].map { |value| value.to_s.strip }.reject(&:empty?).uniq
      raise ContextError, "project identity is missing" if candidates.empty?
      raise ContextError, "project identity conflicts: #{candidates.join(', ')}" if candidates.length > 1

      candidates.first
    end

    def repository_fingerprint(root, id)
      first = git(root, "rev-list", "--max-parents=0", "HEAD").lines.map(&:strip).reject(&:empty?).sort
      raise ContextError, "repository has no baseline commit" if first.empty?

      remotes = git(root, "remote").lines.map(&:strip).reject(&:empty?).map do |name|
        normalize_remote(git(root, "remote", "get-url", name).strip)
      end.reject(&:empty?).uniq.sort
      material = "#{first.join("\n")}\n#{remotes.join("\n")}\n#{id}"
      "sha256:#{Digest::SHA256.hexdigest(material)}"
    end

    def environment_names(root)
      names = []
      Dir.glob(File.join(root, "{.env.example,.env.sample,config/*.env.example}"), File::FNM_EXTGLOB).sort.each do |path|
        File.foreach(path) do |line|
          match = line.match(/\A\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=/)
          names << match[1] if match
        end
      end
      names.uniq.sort
    end

    def build(path, operation: "general")
      root = root_for(path)
      installation_path = File.join(root, ".ai", "KIT_INSTALLATION.yaml")
      project_map_path = File.join(root, ".ai", "canonical", "PROJECT_MAP.yaml")
      installation = File.file?(installation_path) ? safe_yaml(installation_path) : {}
      project_map = File.file?(project_map_path) ? safe_yaml(project_map_path) : {}
      raise ContextError, "PROJECT_MAP.yaml must contain a mapping" unless project_map.is_a?(Hash)

      id = project_id(root, installation, project_map)
      services = project_map["services"]
      services = {} unless services.is_a?(Hash)
      status = project_map["status"].to_s.downcase
      if SENSITIVE_OPERATIONS.include?(operation) && !APPROVED_STATUSES.include?(status)
        raise ContextError, "#{operation} context is not approved; PROJECT_MAP status is #{status.empty? ? 'missing' : status}"
      end
      if SENSITIVE_OPERATIONS.include?(operation) && services.empty?
        raise ContextError, "#{operation} context is incomplete; refusing to infer services"
      end

      canonical = Dir.glob(File.join(root, ".ai", "canonical", "**", "*")).select { |entry| File.file?(entry) }.sort
      unless canonical.all? { |entry| File.realpath(entry).start_with?("#{root}/") }
        raise ContextError, "canonical context escapes the current project root"
      end

      {
        "project_id" => id,
        "root" => root,
        "repository_fingerprint" => repository_fingerprint(root, id),
        "services" => services,
        "project_map_status" => project_map["status"],
        "database" => project_map["database"],
        "api_prefix" => project_map["api_prefix"],
        "canonical_paths" => canonical.map { |entry| entry.delete_prefix("#{root}/") },
        "environment_variable_names" => environment_names(root),
        "memory_scope" => id,
        "operation" => operation,
      }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { operation: "general" }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: project_context.rb [--operation TYPE] PROJECT"
    opts.on("--operation TYPE", WorkflowKit::ProjectContext::SENSITIVE_OPERATIONS + ["general"]) do |value|
      options[:operation] = value
    end
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.length == 1

  begin
    puts JSON.pretty_generate(WorkflowKit::ProjectContext.build(ARGV.first, operation: options[:operation]))
  rescue WorkflowKit::ContextError => error
    warn JSON.generate({ "state" => "blocked", "error" => error.message })
    exit 30
  end
end
