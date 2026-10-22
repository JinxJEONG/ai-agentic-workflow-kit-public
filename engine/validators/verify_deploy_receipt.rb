#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "yaml"

require_relative "schema"
require_relative "spec_registry"
require_relative "../facts/artifact_file"
require_relative "../facts/generated_document"

module WorkflowKit
  module DeployReceipt
    KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
    SCHEMA = File.join(KIT_ROOT, "schemas", "deploy-receipt.schema.yaml")
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

    def blob(root, ref, path)
      git(root, "show", "#{ref}:#{path}", allow_failure: true)
    end

    def required_check_requirements(value)
      contexts = if value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
        value
      elsif value.is_a?(Hash)
        Array(value["contexts"])
      else
        []
      end
      checks = value.is_a?(Hash) ? Array(value["checks"]) : []
      errors = []
      bindings = {}

      checks.each do |entry|
        unless entry.is_a?(Hash)
          errors << "required_check_binding_invalid"
          next
        end
        name = entry["context"] || entry["name"]
        app_id = entry["app_id"]
        unless name.is_a?(String) && !name.empty?
          errors << "required_check_binding_invalid"
          next
        end
        if bindings.key?(name)
          errors << "required_check_binding_ambiguous: #{name}"
          next
        end
        unless app_id.is_a?(Integer) && app_id.positive?
          errors << "required_check_app_binding_missing: #{name}"
          next
        end
        bindings[name] = app_id
      end

      names = contexts.empty? ? bindings.keys : contexts
      unless names.all? { |name| name.is_a?(String) && !name.empty? }
        errors << "required_check_set_invalid"
        names = names.select { |name| name.is_a?(String) && !name.empty? }
      end
      names.uniq.each do |name|
        errors << "required_check_app_binding_missing: #{name}" unless bindings.key?(name)
      end
      (bindings.keys - names).each { |name| errors << "required_check_binding_unexpected: #{name}" }

      [names.uniq.sort.map { |name| { "name" => name, "app_id" => bindings[name] } }, errors]
    end

    def check_runs(value)
      records = value.is_a?(Hash) ? value["check_runs"] : value
      Array(records).select { |item| item.is_a?(Hash) }
    end

    def artifact_error(error)
      case error.code
      when :symlink
        "deployment_artifact_symlink"
      when :not_regular, :not_directory
        "deployment_artifact_not_regular"
      when :changed
        "deployment_artifact_changed_during_verification"
      else
        "deployment_artifact_missing"
      end
    end

    def verify(root:, ref:, receipt_path:, required_checks:, actual_checks:, artifact_path:)
      root = File.realpath(root)
      errors = []
      resolved_ref = git(root, "rev-parse", "#{ref}^{commit}").strip
      raw = blob(root, resolved_ref, receipt_path)
      return { "valid" => false, "errors" => ["receipt_missing: #{receipt_path}"] } unless raw
      receipt = JSON.parse(raw)
      schema = WorkflowKit::Schema.load_yaml(SCHEMA)
      errors.concat(WorkflowKit::Schema.validate(receipt, schema))

      lock_raw = blob(root, resolved_ref, ".ai/KIT_INSTALLATION.yaml")
      registry_raw = blob(root, resolved_ref, ".ai/SPEC_REGISTRY.yaml")
      errors << "installation_lock_missing" unless lock_raw
      errors << "registry_missing" unless registry_raw
      if lock_raw
        lock = YAML.safe_load(lock_raw, permitted_classes: [], permitted_symbols: [], aliases: false)
        errors << "kit_version_mismatch" unless lock["kit_version"] == receipt["kit_version"]
        errors << "kit_bundle_digest_mismatch" unless lock["kit_bundle_digest"] == receipt["kit_bundle_digest"]
        expected_rendered = lock["rendered_install_digest"] || lock["template_digest"]
        errors << "rendered_install_digest_mismatch" unless expected_rendered == receipt["rendered_install_digest"]
      end

      if registry_raw
        expected = "sha256:#{Digest::SHA256.hexdigest(registry_raw)}"
        errors << "spec_registry_digest_mismatch" unless receipt["spec_registry_digest"] == expected
        registry = YAML.safe_load(registry_raw, permitted_classes: [], permitted_symbols: [], aliases: false)
        rules = Array(registry["rules"]).each_with_object({}) { |rule, index| index[rule["id"]] = rule }
        Array(receipt["rules"]).each do |entry|
          rule = rules[entry["rule_id"]]
          if rule.nil?
            errors << "unknown_receipt_rule: #{entry['rule_id']}"
            next
          end
          actual = WorkflowKit::SourceTree.digest(
            WorkflowKit::SourceTree.entries(root, rule["source_globs"], ref: resolved_ref),
          )
          errors << "source_tree_digest_mismatch: #{entry['rule_id']}" unless entry["source_tree_digest"] == actual
        end
        missing = rules.keys - Array(receipt["rules"]).map { |entry| entry["rule_id"] }
        missing.each { |id| errors << "receipt_rule_missing: #{id}" }

        declared_facts = rules.values.flat_map do |rule|
          Array(rule["generated_facts"]).map { |path| [path, rule] }
        end.to_h
        receipt_fact_paths = Array(receipt["generated_facts"]).map { |entry| entry["path"] }
        (declared_facts.keys - receipt_fact_paths).each do |path|
          errors << "generated_fact_receipt_missing: #{path}"
        end
        (receipt_fact_paths - declared_facts.keys).each do |path|
          errors << "generated_fact_not_declared: #{path}"
        end
      end

      generated_schema = WorkflowKit::Schema.load_yaml(
        File.join(KIT_ROOT, "schemas", "generated-facts.schema.yaml"),
      )
      Array(receipt["generated_facts"]).each do |entry|
        fact_raw = blob(root, resolved_ref, entry["path"])
        if fact_raw.nil?
          errors << "generated_fact_missing: #{entry['path']}"
          next
        end
        fact = JSON.parse(fact_raw)
        WorkflowKit::Schema.validate(fact, generated_schema).each do |schema_error|
          errors << "generated_fact_schema_invalid: #{entry['path']}: #{schema_error}"
        end
        internal = "sha256:#{Digest::SHA256.hexdigest(WorkflowKit::GeneratedDocument.canonical_json(fact["facts"]))}"
        errors << "generated_fact_invalid: #{entry['path']}" unless fact["content_digest"] == internal
        errors << "generated_fact_receipt_mismatch: #{entry['path']}" unless entry["content_digest"] == internal
        if registry_raw
          rule = declared_facts[entry["path"]]
          if rule
            errors << "generated_fact_rule_mismatch: #{entry['path']}" unless fact["rule_id"] == rule["id"]
            actual_source = WorkflowKit::SourceTree.digest(
              WorkflowKit::SourceTree.entries(root, rule["source_globs"], ref: resolved_ref),
            )
            unless fact["source_tree_digest"] == actual_source
              errors << "generated_fact_source_mismatch: #{entry['path']}"
            end
          end
        end
      rescue JSON::ParserError
        errors << "generated_fact_invalid: #{entry['path']}"
      end

      wrapper_required = registry_raw && rules.values.any? do |rule|
        Array(rule["checks"]).include?("release-wrapper-required")
      end
      if wrapper_required
        wrapper = receipt.dig("project_release_evidence", "wrapper")
        errors << "release_wrapper_mismatch: expected #{RELEASE_WRAPPER}" unless wrapper == RELEASE_WRAPPER
        errors << "release_wrapper_missing: #{RELEASE_WRAPPER}" unless blob(root, resolved_ref, RELEASE_WRAPPER)
      end

      required, requirement_errors = required_check_requirements(required_checks)
      errors.concat(requirement_errors)
      runs = check_runs(actual_checks)
      errors << "required_check_set_empty" if required.empty?
      required.each do |requirement|
        name = requirement.fetch("name")
        expected_app_id = requirement["app_id"]
        matching = runs.select { |run| run["name"] == name }
        errors << "required_check_ambiguous: #{name}" if matching.length != 1
        run = matching.first
        if run
          errors << "required_check_wrong_sha: #{name}" unless run["head_sha"] == resolved_ref
          errors << "required_check_not_completed: #{name}" unless run["status"] == "completed"
          app_id = run.dig("app", "id")
          errors << "required_check_untrusted_app: #{name}" unless app_id.is_a?(Integer) && app_id.positive?
          if expected_app_id && app_id != expected_app_id
            errors << "required_check_wrong_app: #{name} expected=#{expected_app_id} actual=#{app_id.inspect}"
          end
        end
        success = matching.length == 1 && run && run["conclusion"] == "success" &&
          run["head_sha"] == resolved_ref && run["status"] == "completed" &&
          run.dig("app", "id").is_a?(Integer) && run.dig("app", "id").positive? &&
          run.dig("app", "id") == expected_app_id
        errors << "required_check_not_successful: #{name}" unless success
      end

      artifact_snapshot = nil
      begin
        artifact_snapshot = WorkflowKit::ArtifactFile.snapshot(artifact_path)
        unless receipt.dig("project_release_evidence", "artifact_digest") == artifact_snapshot.digest
          errors << "deployment_artifact_digest_mismatch"
        end

        # This verifier cannot hand its already-open file descriptor to a later
        # deploy process. Re-open through the same no-symlink component walk
        # immediately before returning and require the exact same inode,
        # metadata, and bytes. The receipt separately requires deployment to
        # consume an immutable artifact copy after this boundary.
        final_snapshot = WorkflowKit::ArtifactFile.snapshot(artifact_path)
        unless artifact_snapshot.same_artifact?(final_snapshot)
          errors << "deployment_artifact_changed_during_verification"
        end
      rescue WorkflowKit::ArtifactFile::Refused => error
        errors << if artifact_snapshot
          "deployment_artifact_changed_during_verification"
        else
          artifact_error(error)
        end
      end

      result = { "valid" => errors.empty?, "ref" => resolved_ref, "errors" => errors.uniq }
      if artifact_snapshot
        result["artifact"] = {
          "digest" => artifact_snapshot.digest,
          "immutable_copy_required" => true,
        }
      end
      result
    rescue JSON::ParserError, Psych::Exception, ArgumentError => error
      { "valid" => false, "errors" => [error.message] }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: ".", ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json" }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: verify_deploy_receipt.rb --required-checks FILE --check-runs FILE --artifact FILE [options]"
    opts.on("--root DIR") { |value| options[:root] = value }
    opts.on("--sha REF") { |value| options[:ref] = value }
    opts.on("--receipt PATH") { |value| options[:receipt_path] = value }
    opts.on("--required-checks FILE") { |value| options[:required_path] = value }
    opts.on("--check-runs FILE") { |value| options[:checks_path] = value }
    opts.on("--artifact FILE") { |value| options[:artifact_path] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless options[:required_path] && options[:checks_path] && options[:artifact_path] && ARGV.empty?
  required = JSON.parse(File.read(options.delete(:required_path)))
  actual = JSON.parse(File.read(options.delete(:checks_path)))
  result = WorkflowKit::DeployReceipt.verify(**options.merge(required_checks: required, actual_checks: actual))
  puts JSON.pretty_generate(result)
  exit(result["valid"] ? 0 : 30)
end
