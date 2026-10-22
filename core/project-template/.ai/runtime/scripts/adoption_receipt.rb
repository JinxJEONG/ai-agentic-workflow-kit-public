#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "optparse"
require_relative "workflow_lib"

module AgentWorkflow
  module AdoptionReceipt
    RECEIPT_SCHEMA = 1
    TREE_DIGEST_ALGO = "sha256-framed-git-tree-v1"
    RECEIPT_PATH = File.join(".ai", "generated", "adoption-receipt.json")
    LOCK_PATH = File.join(".ai", "KIT_INSTALLATION.yaml")
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze
    ALLOWED_FIELDS = %w[
      receipt_schema
      kit_version
      kit_bundle_digest
      rendered_install_digest
      plan_digest
      adopted_branch
      harness_tree_digest_algo
      harness_tree_digest
    ].freeze

    class ReceiptError < StandardError; end

    module_function

    def git(root, *arguments)
      stdout, stderr, status = Open3.capture3(
        { "GIT_OPTIONAL_LOCKS" => "0" },
        "git", "-C", root, *arguments,
      )
      raise ReceiptError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def repository_root(path)
      root = File.realpath(path)
      top = File.realpath(git(root, "rev-parse", "--show-toplevel").strip)
      raise ReceiptError, "target must be a Git top-level" unless root == top

      root
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ReceiptError, "cannot resolve repository: #{error.message}"
    end

    def parse_index_entry(raw)
      match = raw.match(/\A([0-7]{6}) ([0-9a-f]{40,64}) ([0-3])\t(.*)\z/m)
      raise ReceiptError, "invalid Git index entry" unless match
      raise ReceiptError, "unmerged Git index entry: #{match[4]}" unless match[3] == "0"

      { "mode" => match[1], "oid" => match[2], "path" => normalized_path(match[4]) }
    end

    def parse_tree_entry(raw)
      match = raw.match(/\A([0-7]{6}) ([^ ]+) ([0-9a-f]{40,64})\t(.*)\z/m)
      raise ReceiptError, "invalid Git tree entry" unless match
      raise ReceiptError, "non-blob harness entry: #{match[4]}" unless match[2] == "blob"

      { "mode" => match[1], "oid" => match[3], "path" => normalized_path(match[4]) }
    end

    def normalized_path(value)
      path = value.to_s.dup.force_encoding(Encoding::UTF_8)
      raise ReceiptError, "harness path is not valid UTF-8" unless path.valid_encoding?
      raise ReceiptError, "unsafe harness path: #{path.inspect}" if path.empty? || path.start_with?("/") || path.split("/").include?("..")

      path
    end

    def source_entries(root, source)
      raw = if source.to_s == "index"
        git(root, "ls-files", "--stage", "-z", "--", ".ai", "AGENTS.md", ".githooks")
      else
        git(root, "rev-parse", "--verify", "#{source}^{commit}")
        git(root, "ls-tree", "-rz", "--full-tree", source.to_s, "--", ".ai", "AGENTS.md", ".githooks")
      end
      parser = source.to_s == "index" ? method(:parse_index_entry) : method(:parse_tree_entry)
      raw.split("\0").reject(&:empty?).map { |entry| parser.call(entry) }
        .select { |entry| harness_path?(entry.fetch("path")) }
        .reject { |entry| entry.fetch("path") == RECEIPT_PATH }
        .sort_by { |entry| entry.fetch("path").b }
    end

    def harness_path?(path)
      path == "AGENTS.md" || path.start_with?(".ai/") || path.start_with?(".githooks/")
    end

    def source_entry(root, source, path)
      raw = if source.to_s == "index"
        git(root, "ls-files", "--stage", "-z", "--", path)
      else
        git(root, "ls-tree", "-z", "--full-tree", source.to_s, "--", path)
      end
      records = raw.split("\0").reject(&:empty?)
      raise ReceiptError, "missing #{path} in Git #{source}" unless records.length == 1

      entry = source.to_s == "index" ? parse_index_entry(records.first) : parse_tree_entry(records.first)
      raise ReceiptError, "Git lookup returned the wrong path for #{path}" unless entry.fetch("path") == path

      entry
    end

    def source_blob(root, source, path)
      entry = source_entry(root, source, path)
      git(root, "cat-file", "blob", entry.fetch("oid")).b
    end

    def framed(material, value)
      bytes = value.to_s.b
      material << bytes.bytesize.to_s.b << ":".b << bytes
    end

    def harness_tree_digest(root, source: "HEAD")
      entries = source_entries(root, source)
      raise ReceiptError, "harness tree is empty" if entries.empty?

      material = +"workflow-kit-adoption-harness-tree\0#{TREE_DIGEST_ALGO}\0#{entries.length}\0".b
      entries.each do |entry|
        framed(material, entry.fetch("mode"))
        framed(material, entry.fetch("path"))
        framed(material, git(root, "cat-file", "blob", entry.fetch("oid")).b)
      end
      "sha256:#{Digest::SHA256.hexdigest(material)}"
    end

    def load_mapping(content, label)
      value = AgentWorkflow.safe_yaml_load(content)
      raise ReceiptError, "#{label} must contain a mapping" unless value.is_a?(Hash)

      value
    rescue Psych::Exception => error
      raise ReceiptError, "cannot parse #{label}: #{error.message}"
    end

    def installation_lock(root, source)
      load_mapping(source_blob(root, source, LOCK_PATH), LOCK_PATH)
    end

    def latest_plan_digest(lock)
      migration = Array(lock["migration_history"]).reverse.find do |entry|
        entry.is_a?(Hash) && !entry["plan_digest"].to_s.empty?
      end
      digest = migration && migration["plan_digest"].to_s
      raise ReceiptError, "installation lock has no migration plan_digest" unless digest && digest.match?(DIGEST_PATTERN)

      digest
    end

    def checked_digest(value, label)
      digest = value.to_s
      raise ReceiptError, "#{label} must be sha256:<64 lowercase hex>" unless digest.match?(DIGEST_PATTERN)

      digest
    end

    def current_branch(root)
      branch = git(root, "symbolic-ref", "--quiet", "--short", "HEAD").strip
      raise ReceiptError, "adoption receipt generation requires an attached branch" if branch.empty?

      branch
    rescue ReceiptError => error
      raise error if error.message.include?("attached branch")

      raise ReceiptError, "adoption receipt generation requires an attached branch"
    end

    def generate!(path:, plan_digest:)
      root = repository_root(path)
      supplied = checked_digest(plan_digest, "plan_digest")
      lock = installation_lock(root, "index")
      recorded = latest_plan_digest(lock)
      raise ReceiptError, "plan_digest does not match the staged installation lock" unless supplied == recorded

      payload = {
        "receipt_schema" => RECEIPT_SCHEMA,
        "kit_version" => lock["kit_version"].to_s,
        "kit_bundle_digest" => checked_digest(lock["kit_bundle_digest"], "kit_bundle_digest"),
        "rendered_install_digest" => checked_digest(lock["rendered_install_digest"], "rendered_install_digest"),
        "plan_digest" => supplied,
        "adopted_branch" => current_branch(root),
        "harness_tree_digest_algo" => TREE_DIGEST_ALGO,
        "harness_tree_digest" => harness_tree_digest(root, source: "index"),
      }
      raise ReceiptError, "kit_version must not be empty" if payload["kit_version"].empty?

      AgentWorkflow.atomic_write(File.join(root, RECEIPT_PATH), "#{JSON.pretty_generate(payload)}\n")
      payload
    end

    def validate_payload!(payload, lock, root, source)
      raise ReceiptError, "adoption receipt must contain a JSON object" unless payload.is_a?(Hash)

      unknown = payload.keys.map(&:to_s) - ALLOWED_FIELDS
      missing = ALLOWED_FIELDS - payload.keys.map(&:to_s)
      raise ReceiptError, "adoption receipt has unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?
      raise ReceiptError, "adoption receipt is missing fields: #{missing.sort.join(', ')}" unless missing.empty?
      raise ReceiptError, "receipt_schema must be #{RECEIPT_SCHEMA}" unless payload["receipt_schema"] == RECEIPT_SCHEMA
      raise ReceiptError, "harness_tree_digest_algo mismatch" unless payload["harness_tree_digest_algo"] == TREE_DIGEST_ALGO
      raise ReceiptError, "kit_version mismatch" unless payload["kit_version"] == lock["kit_version"]
      raise ReceiptError, "kit_bundle_digest mismatch" unless payload["kit_bundle_digest"] == checked_digest(lock["kit_bundle_digest"], "kit_bundle_digest")
      unless payload["rendered_install_digest"] == checked_digest(lock["rendered_install_digest"], "rendered_install_digest")
        raise ReceiptError, "rendered_install_digest mismatch"
      end
      raise ReceiptError, "plan_digest mismatch" unless payload["plan_digest"] == latest_plan_digest(lock)
      checked_digest(payload["plan_digest"], "plan_digest")
      checked_digest(payload["harness_tree_digest"], "harness_tree_digest")
      branch = payload["adopted_branch"].to_s
      raise ReceiptError, "adopted_branch must not be empty" if branch.empty?
      git(root, "check-ref-format", "--branch", branch)

      actual_tree = harness_tree_digest(root, source: source)
      raise ReceiptError, "harness_tree_digest mismatch" unless payload["harness_tree_digest"] == actual_tree

      payload
    end

    def verify!(path:, source: "HEAD")
      root = repository_root(path)
      lock = installation_lock(root, source)
      raw = source_blob(root, source, RECEIPT_PATH)
      payload = JSON.parse(raw)
      validate_payload!(payload, lock, root, source)
    rescue JSON::ParserError => error
      raise ReceiptError, "cannot parse #{RECEIPT_PATH}: #{error.message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  begin
    case command
    when "generate"
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adoption_receipt.rb generate --plan-digest DIGEST [REPOSITORY]"
        opts.on("--plan-digest DIGEST") { |value| options[:plan_digest] = value }
      end
      parser.parse!(ARGV)
      raise AgentWorkflow::AdoptionReceipt::ReceiptError, parser.to_s unless options[:plan_digest] && ARGV.length <= 1
      payload = AgentWorkflow::AdoptionReceipt.generate!(path: ARGV.first || AgentWorkflow::ROOT, plan_digest: options.fetch(:plan_digest))
      puts JSON.generate(payload)
    when "verify"
      options = { source: "HEAD" }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: adoption_receipt.rb verify [--source HEAD|index] [REPOSITORY]"
        opts.on("--source SOURCE") { |value| options[:source] = value }
      end
      parser.parse!(ARGV)
      raise AgentWorkflow::AdoptionReceipt::ReceiptError, parser.to_s unless ARGV.length <= 1
      payload = AgentWorkflow::AdoptionReceipt.verify!(path: ARGV.first || AgentWorkflow::ROOT, source: options.fetch(:source))
      puts "OK: adoption receipt is valid (#{payload.fetch('harness_tree_digest')})."
    else
      raise AgentWorkflow::AdoptionReceipt::ReceiptError, "Usage: adoption_receipt.rb generate|verify [options] [REPOSITORY]"
    end
  rescue AgentWorkflow::AdoptionReceipt::ReceiptError, Errno::ENOENT, Errno::EACCES => error
    warn "ERROR: #{error.message}"
    exit 1
  end
end
