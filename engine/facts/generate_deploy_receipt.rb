#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "yaml"

require_relative "artifact_file"
require_relative "generated_document"
require_relative "source_tree"
require_relative "../validators/schema"
require_relative "../validators/spec_registry"

module WorkflowKit
  module DeployReceiptGenerator
    KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
    RECEIPT_SCHEMA = File.join(KIT_ROOT, "schemas", "deploy-receipt.schema.yaml")
    GENERATED_FACT_SCHEMA = File.join(KIT_ROOT, "schemas", "generated-facts.schema.yaml")
    RELEASE_WRAPPER = "deploy/release.rb"

    module_function

    def git(root, *arguments, allow_failure: false)
      stdout, stderr, status = Open3.capture3(
        { "GIT_OPTIONAL_LOCKS" => "0" },
        "git", "-C", root, *arguments,
      )
      return nil if allow_failure && !status.success?
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def blob(root, commit, path)
      git(root, "show", "#{commit}:#{path}", allow_failure: true)
    end

    def parse_yaml(raw, name)
      value = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise ArgumentError, "#{name} must be a mapping" unless value.is_a?(Hash)

      value
    rescue Psych::Exception => error
      raise ArgumentError, "#{name} is invalid: #{error.message}"
    end

    def artifact_digest(path)
      WorkflowKit::ArtifactFile.snapshot(path).digest
    rescue WorkflowKit::ArtifactFile::Refused => error
      raise ArgumentError, error.message
    end

    def build(
      root:, ref: "HEAD", artifact_path:, db_migration_head: nil,
      db_migration_checksum: nil, attestation: nil, note: nil
    )
      root = File.realpath(root)
      commit = git(root, "rev-parse", "#{ref}^{commit}").strip
      lock_raw = blob(root, commit, ".ai/KIT_INSTALLATION.yaml")
      registry_raw = blob(root, commit, ".ai/SPEC_REGISTRY.yaml")
      raise ArgumentError, "installation_lock_missing" unless lock_raw
      raise ArgumentError, "registry_missing" unless registry_raw

      lock = parse_yaml(lock_raw, "installation lock")
      registry = parse_yaml(registry_raw, "spec registry")
      registry_errors = WorkflowKit::SpecRegistry.validate(registry)
      unless registry_errors.empty?
        raise ArgumentError, "spec registry is invalid: #{registry_errors.join('; ')}"
      end

      rules = Array(registry["rules"]).sort_by { |rule| rule.fetch("id") }
      source_digests = rules.each_with_object({}) do |rule, result|
        result[rule.fetch("id")] = WorkflowKit::SourceTree.digest(
          WorkflowKit::SourceTree.entries(root, rule.fetch("source_globs"), ref: commit),
        )
      end

      fact_owners = {}
      rules.each do |rule|
        Array(rule["generated_facts"]).each do |path|
          if fact_owners.key?(path)
            raise ArgumentError, "generated fact is declared by multiple rules: #{path}"
          end
          fact_owners[path] = rule
        end
      end
      generated_schema = WorkflowKit::Schema.load_yaml(GENERATED_FACT_SCHEMA)
      facts = fact_owners.keys.sort.map do |path|
        raw = blob(root, commit, path)
        raise ArgumentError, "generated_fact_missing: #{path}" unless raw

        fact = JSON.parse(raw)
        schema_errors = WorkflowKit::Schema.validate(fact, generated_schema)
        unless schema_errors.empty?
          raise ArgumentError, "generated_fact_schema_invalid: #{path}: #{schema_errors.join('; ')}"
        end
        owner = fact_owners.fetch(path)
        rule_id = owner.fetch("id")
        expected_source = source_digests.fetch(rule_id)
        raise ArgumentError, "generated_fact_rule_mismatch: #{path}" unless fact["rule_id"] == rule_id
        unless fact["source_tree_digest"] == expected_source
          raise ArgumentError, "generated_fact_source_mismatch: #{path}"
        end

        content_digest = "sha256:#{Digest::SHA256.hexdigest(
          WorkflowKit::GeneratedDocument.canonical_json(fact["facts"]),
        )}"
        raise ArgumentError, "generated_fact_invalid: #{path}" unless fact["content_digest"] == content_digest

        { "path" => path, "content_digest" => content_digest }
      rescue JSON::ParserError => error
        raise ArgumentError, "generated_fact_invalid: #{path}: #{error.message}"
      end

      release_evidence = {
        "artifact_digest" => artifact_digest(artifact_path),
        "immutable_copy_required" => true,
      }
      wrapper_required = rules.any? { |rule| Array(rule["checks"]).include?("release-wrapper-required") }
      if wrapper_required
        raise ArgumentError, "release_wrapper_missing: #{RELEASE_WRAPPER}" unless blob(root, commit, RELEASE_WRAPPER)
        release_evidence["wrapper"] = RELEASE_WRAPPER
      end
      release_evidence["attestation"] = attestation if attestation

      receipt = {
        "receipt_schema" => 2,
        "kit_version" => lock["kit_version"],
        "kit_bundle_digest" => lock["kit_bundle_digest"],
        "rendered_install_digest" => lock["rendered_install_digest"] || lock["template_digest"],
        "spec_registry_digest" => "sha256:#{Digest::SHA256.hexdigest(registry_raw)}",
        "source_digest_algo" => 1,
        "rules" => rules.map do |rule|
          { "rule_id" => rule.fetch("id"), "source_tree_digest" => source_digests.fetch(rule.fetch("id")) }
        end,
        "generated_facts" => facts,
        "project_release_evidence" => release_evidence,
      }

      if db_migration_head || db_migration_checksum
        unless db_migration_head && db_migration_checksum
          raise ArgumentError, "db migration head and checksum must be supplied together"
        end
        receipt["db_migration"] = {
          "head" => db_migration_head,
          "checksum" => db_migration_checksum,
        }
      end
      receipt["note"] = note if note

      receipt_errors = WorkflowKit::Schema.validate(
        receipt,
        WorkflowKit::Schema.load_yaml(RECEIPT_SCHEMA),
      )
      raise ArgumentError, "deploy receipt is invalid: #{receipt_errors.join('; ')}" unless receipt_errors.empty?

      receipt
    end

    def emit(receipt, output)
      rendered = JSON.pretty_generate(receipt) + "\n"
      if output
        if File.symlink?(output)
          raise ArgumentError, "output must not be a symbolic link"
        end
        FileUtils.mkdir_p(File.dirname(File.expand_path(output)))
        File.binwrite(output, rendered)
      else
        $stdout.write(rendered)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = { root: ".", ref: "HEAD" }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: generate_deploy_receipt.rb --artifact FILE [options]"
      opts.on("--root DIR") { |value| options[:root] = value }
      opts.on("--ref REF", "--sha REF") { |value| options[:ref] = value }
      opts.on("--artifact FILE") { |value| options[:artifact_path] = value }
      opts.on("--output FILE") { |value| options[:output] = value }
      opts.on("--db-migration-head VALUE") { |value| options[:db_migration_head] = value }
      opts.on("--db-migration-checksum SHA256") { |value| options[:db_migration_checksum] = value }
      opts.on("--attestation VALUE") { |value| options[:attestation] = value }
      opts.on("--note TEXT") { |value| options[:note] = value }
    end
    parser.parse!(ARGV)
    abort parser.to_s unless options[:artifact_path] && ARGV.empty?
    output = options.delete(:output)
    WorkflowKit::DeployReceiptGenerator.emit(
      WorkflowKit::DeployReceiptGenerator.build(**options),
      output,
    )
  rescue ArgumentError => error
    warn error.message
    exit 30
  end
end
