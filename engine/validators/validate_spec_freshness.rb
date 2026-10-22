#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tempfile"
require "time"
require "yaml"

require_relative "spec_registry"
require_relative "schema"
require_relative "../facts/generated_document"

module WorkflowKit
  module SpecFreshness
    KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
    GENERATORS = {
      "fastapi-routes" => "adapters/fastapi-alembic/generate_routes.rb",
      "nextjs-routes" => "adapters/nextjs-typescript/generate_routes.rb",
      "python-symbols" => "adapters/fastapi-alembic/generate_symbols.rb",
      "typescript-exports" => "adapters/nextjs-typescript/generate_exports.rb",
      "postgresql-schema" => "adapters/postgresql/generate_schema.rb",
      "environment-variables" => "adapters/common/generate_env_names.rb",
      "deployment-inputs" => "adapters/common/generate_deploy_inputs.rb",
      "migration-checksums" => "adapters/common/generate_migration_checksums.rb",
    }.freeze
    EXECUTION_PROFILES = %w[local hosted-no-project-code].freeze
    # Hosted validation must not load a dependency or executable module from
    # the target project. Every entry here was audited to consume immutable Git
    # blobs with kit-owned Ruby/Python parsing code only. In particular,
    # typescript-exports is intentionally absent because its adapter imports the
    # target project's TypeScript compiler module. PostgreSQL introspection is
    # also local-only because it launches environment-selected Docker/psql
    # executables and connects to a disposable runtime rather than parsing blobs.
    HOSTED_NO_PROJECT_CODE_GENERATORS = {
      "fastapi-routes" => "adapters/fastapi-alembic/generate_routes.rb",
      "nextjs-routes" => "adapters/nextjs-typescript/generate_routes.rb",
      "python-symbols" => "adapters/fastapi-alembic/generate_symbols.rb",
      "environment-variables" => "adapters/common/generate_env_names.rb",
      "deployment-inputs" => "adapters/common/generate_deploy_inputs.rb",
      "migration-checksums" => "adapters/common/generate_migration_checksums.rb",
    }.freeze
    KNOWN_CHECKS = %w[
      migration-checksum disposable-database-introspection runtime-input-manifest-digest
      release-wrapper-required fastapi-routes nextjs-routes python-symbols typescript-exports
      environment-names deployment-inputs
    ].freeze
    CHECK_EVIDENCE_TYPES = {
      "migration-checksum" => "migration-checksums",
      "disposable-database-introspection" => "postgresql-schema",
      "runtime-input-manifest-digest" => "deployment-inputs",
      "fastapi-routes" => "fastapi-routes",
      "nextjs-routes" => "nextjs-routes",
      "python-symbols" => "python-symbols",
      "typescript-exports" => "typescript-exports",
      "environment-names" => "environment-variables",
      "deployment-inputs" => "deployment-inputs",
    }.freeze
    GENERATED_FACTS_SCHEMA = File.join(KIT_ROOT, "schemas", "generated-facts.schema.yaml")
    DOCS_IMPACT_FIELDS = %w[change_set_digest decision reason rule_id].freeze

    module_function

    def git(root, *arguments, allow_failure: false)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      return nil if allow_failure && !status.success?
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?
      stdout
    end

    def blob(root, ref, path)
      git(root, "show", "#{ref}:#{path}", allow_failure: true)
    end

    def changed_paths(root, base, head)
      git(root, "diff", "--name-only", "-z", "#{base}..#{head}").split("\0").reject(&:empty?).sort
    end

    def tracked_paths(root, ref)
      git(root, "ls-tree", "-r", "--name-only", "-z", ref).split("\0").reject(&:empty?).sort
    end

    def change_set_digest(root, base, head)
      names = git(root, "diff", "--name-status", "#{base}..#{head}").lines.sort.join
      patch = git(root, "diff", "#{base}..#{head}")
      patch_digest_line = "#{Digest::SHA256.hexdigest(patch)}\n"
      "sha256:#{Digest::SHA256.hexdigest(names + patch_digest_line)}"
    end

    def front_matter(markdown)
      return {} unless markdown.to_s.start_with?("---\n")
      closing = markdown.index("\n---\n", 4)
      return {} unless closing
      value = YAML.safe_load(markdown[4...closing], permitted_classes: [], permitted_symbols: [], aliases: false)
      value.is_a?(Hash) ? value : {}
    rescue Psych::Exception
      {}
    end

    def exemption_valid?(exemptions, rule_id, digest, approved_rules)
      item = Array(exemptions).find { |entry| entry.is_a?(Hash) && entry["rule_id"] == rule_id }
      return false unless item
      reason = item["reason"].to_s.strip
      reason.length >= 40 && !reason.match?(/no impact|n\/a|template/i) &&
        item["change_set_digest"] == digest && approved_rules.include?(rule_id)
    end

    def docs_impact_entries(body)
      documents = body.to_s.scan(/```ya?ml[ \t]*\r?\n(.*?)\r?\n```/mi).each_with_object([]) do |match, result|
        value = YAML.safe_load(match.first, permitted_classes: [], permitted_symbols: [], aliases: false)
        result << value if value.is_a?(Hash) && value.key?("docs-impact")
      rescue Psych::Exception
        next
      end
      raise ArgumentError, "docs_impact_block_ambiguous" if documents.length > 1
      return [] if documents.empty?

      entries = documents.first["docs-impact"]
      raise ArgumentError, "docs_impact_block_invalid: docs-impact must be a sequence" unless entries.is_a?(Array)

      seen = {}
      entries.map.with_index do |entry, index|
        unless entry.is_a?(Hash) && entry.keys.map(&:to_s).sort == DOCS_IMPACT_FIELDS
          raise ArgumentError, "docs_impact_block_invalid: entry=#{index} fields"
        end
        normalized = entry.transform_keys(&:to_s)
        rule_id = normalized["rule_id"].to_s
        raise ArgumentError, "docs_impact_block_invalid: entry=#{index} rule_id" if rule_id.empty? || seen[rule_id]
        raise ArgumentError, "docs_impact_block_invalid: entry=#{index} decision" unless normalized["decision"] == "none"
        seen[rule_id] = true
        normalized
      end
    end

    def latest_reviews_by_login(reviews)
      Array(reviews).select { |review| review.is_a?(Hash) }.each_with_object({}) do |review, latest|
        login = review.dig("user", "login").to_s.downcase
        next if login.empty?
        submitted = Time.iso8601(review["submitted_at"].to_s)
        ordering = [submitted.to_f, review["id"].to_i]
        previous = latest[login]
        latest[login] = [ordering, review] if previous.nil? || (ordering <=> previous.first) == 1
      rescue ArgumentError
        next
      end.transform_values(&:last)
    end

    def github_approval_evidence(root:, base:, head:, registry_path:, event:, reviews:, repository:)
      pull_request = event.is_a?(Hash) ? event["pull_request"] : nil
      return { exemptions: [], approved_rules: [], errors: [] } unless pull_request.is_a?(Hash)

      errors = []
      event_repository = event.dig("repository", "full_name").to_s
      errors << "github_event_repository_mismatch" unless !repository.to_s.empty? && event_repository == repository
      resolved_base = git(root, "rev-parse", "#{base}^{commit}").strip
      resolved_head = git(root, "rev-parse", "#{head}^{commit}").strip
      errors << "github_event_base_mismatch" unless pull_request.dig("base", "sha") == resolved_base
      errors << "github_event_head_mismatch" unless pull_request.dig("head", "sha") == resolved_head

      entries = docs_impact_entries(pull_request["body"])
      return { exemptions: [], approved_rules: [], errors: errors } if entries.empty?

      registry_raw = blob(root, resolved_head, registry_path)
      base_registry_raw = blob(root, resolved_base, registry_path)
      raise ArgumentError, "registry_missing: #{registry_path}" unless registry_raw
      registry = YAML.safe_load(registry_raw, permitted_classes: [], permitted_symbols: [], aliases: false)
      base_registry = base_registry_raw && YAML.safe_load(
        base_registry_raw,
        permitted_classes: [], permitted_symbols: [], aliases: false,
      )
      rules = Array(registry["rules"]).select { |rule| rule.is_a?(Hash) }
        .each_with_object({}) { |rule, result| result[rule["id"]] = rule }
      base_rules = Array(base_registry && base_registry["rules"]).select { |rule| rule.is_a?(Hash) }
        .each_with_object({}) { |rule, result| result[rule["id"]] = rule }
      latest_reviews = latest_reviews_by_login(reviews)
      approved_rules = []

      entries.each do |entry|
        rule_id = entry["rule_id"]
        rule = rules[rule_id]
        unless rule
          errors << "docs_impact_unknown_rule: #{rule_id}"
          next
        end
        base_rule = base_rules[rule_id]
        unless base_rule
          errors << "docs_impact_new_rule_exemption_forbidden: #{rule_id}"
          next
        end
        head_owners = Array(rule["codeowners"]).map(&:to_s).sort
        owners = Array(base_rule["codeowners"]).map(&:to_s).sort
        unless owners == head_owners
          errors << "docs_impact_codeowners_changed: #{rule_id}"
          next
        end
        user_logins = owners.each_with_object([]) do |owner, result|
          match = owner.match(/\A@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\z/)
          result << match[1].downcase if match
        end
        if user_logins.empty? && owners.any? { |owner| owner.include?("/") }
          errors << "docs_impact_team_membership_evidence_missing: #{rule_id}"
          next
        end
        approved = user_logins.any? do |login|
          review = latest_reviews[login]
          review && review["state"] == "APPROVED" && review["commit_id"] == resolved_head
        end
        if approved
          approved_rules << rule_id
        else
          errors << "docs_impact_codeowner_approval_missing: #{rule_id}"
        end
      end

      {
        exemptions: entries.map do |entry|
          entry.slice("rule_id", "reason", "change_set_digest")
        end,
        approved_rules: approved_rules.uniq.sort,
        errors: errors,
      }
    rescue Psych::Exception, ArgumentError => error
      { exemptions: [], approved_rules: [], errors: [error.message] }
    end

    def validate_generated(root, head, rule, path, errors)
      error_count = errors.length
      raw = blob(root, head, path)
      unless raw
        errors << "generated_facts_missing: #{path}"
        return nil
      end
      begin
        document = JSON.parse(raw)
      rescue JSON::ParserError => error
        errors << "generated_facts_invalid: #{path}: #{error.message}"
        return nil
      end

      schema = WorkflowKit::Schema.load_yaml(GENERATED_FACTS_SCHEMA)
      schema_errors = WorkflowKit::Schema.validate(document, schema)
      unless schema_errors.empty?
        schema_errors.each { |error| errors << "generated_facts_schema_invalid: #{path}: #{error}" }
        return nil
      end

      actual_source = WorkflowKit::SourceTree.digest(
        WorkflowKit::SourceTree.entries(root, rule["source_globs"], ref: head),
      )
      errors << "generated_facts_source_mismatch: #{path}" unless document["source_tree_digest"] == actual_source
      internal = "sha256:#{Digest::SHA256.hexdigest(WorkflowKit::GeneratedDocument.canonical_json(document["facts"]))}"
      errors << "generated_facts_content_invalid: #{path}" unless document["content_digest"] == internal

      # A generated document is only evidence for the rule that declared it.
      # Without this binding a valid fact file from another rule can be copied
      # into place and may accidentally satisfy a stale-content check.
      errors << "generated_facts_rule_mismatch: #{path}" unless document["rule_id"] == rule["id"]
      errors << "generated_facts_source_algo_invalid: #{path}" unless document["source_digest_algo"] == 1

      generator = GENERATORS[document["fact_type"]]
      unless generator
        errors << "generated_facts_unknown_type: #{path}"
        return nil
      end
      command = [
        RbConfig.ruby, File.join(KIT_ROOT, generator), "--root", root, "--ref", head,
        "--rule", rule["id"], "--clear-default-globs",
      ]
      Array(rule["source_globs"]).each { |glob| command.concat(["--source-glob", glob]) }
      stdout, stderr, status = Open3.capture3(*command)
      unless status.success?
        errors << "generated_facts_regeneration_failed: #{path}: #{stderr.strip}"
        return nil
      end
      regenerated = JSON.parse(stdout)
      unless regenerated["content_digest"] == document["content_digest"]
        errors << "generated_facts_stale: #{path}"
      end
      unless regenerated["source_tree_digest"] == document["source_tree_digest"]
        errors << "generated_facts_regeneration_source_mismatch: #{path}"
      end
      document["fact_type"] if errors.length == error_count
    rescue ArgumentError, JSON::ParserError => error
      errors << "generated_facts_invalid: #{path}: #{error.message}"
      nil
    end

    def execution_profile_errors(root, head, registry, execution_profile)
      unless EXECUTION_PROFILES.include?(execution_profile)
        return ["unknown_execution_profile: #{execution_profile}"]
      end
      return [] if execution_profile == "local"

      # Preflight the complete registry before any adapter is invoked. Checking
      # only touched rules would let an unsafe project executable remain armed
      # in a non-touched rule and run on a later change.
      Array(registry["rules"]).each_with_object([]) do |rule, errors|
        next unless rule.is_a?(Hash)

        Array(rule["generated_facts"]).each do |path|
          raw = blob(root, head, path)
          unless raw
            errors << "hosted_generated_facts_uninspectable: rule=#{rule['id']} path=#{path} reason=missing"
            next
          end
          begin
            document = JSON.parse(raw)
          rescue JSON::ParserError
            errors << "hosted_generated_facts_uninspectable: rule=#{rule['id']} path=#{path} reason=invalid-json"
            next
          end
          fact_type = document.is_a?(Hash) ? document["fact_type"].to_s : ""
          generator = HOSTED_NO_PROJECT_CODE_GENERATORS[fact_type]
          unless generator && GENERATORS[fact_type] == generator
            errors << "hosted_unsafe_adapter: rule=#{rule['id']} path=#{path} fact_type=#{fact_type.empty? ? '(missing)' : fact_type}"
          end
        end
      end
    end

    def validate_registry_transition(base_registry, registry, errors)
      return unless base_registry.is_a?(Hash)

      old_rules = Array(base_registry["rules"]).select { |rule| rule.is_a?(Hash) }
        .each_with_object({}) { |rule, result| result[rule["id"]] = rule }
      new_rules = Array(registry["rules"]).select { |rule| rule.is_a?(Hash) }
        .each_with_object({}) { |rule, result| result[rule["id"]] = rule }
      old_rules.each do |id, old_rule|
        new_rule = new_rules[id]
        unless new_rule
          errors << "registry_rule_removed: #{id}"
          next
        end

        %w[source_globs canonical_specs generated_facts checks].each do |field|
          removed = Array(old_rule[field]) - Array(new_rule[field])
          errors << "registry_rule_weakened: rule=#{id} field=#{field} removed=#{removed.sort.join(',')}" unless removed.empty?
        end
        unless Array(old_rule["codeowners"]).sort == Array(new_rule["codeowners"]).sort
          errors << "registry_rule_codeowners_changed: rule=#{id}"
        end
        if old_rule["impact_policy"] == "spec_update_required" &&
            new_rule["impact_policy"] != "spec_update_required"
          errors << "registry_rule_weakened: rule=#{id} field=impact_policy"
        end
      end
    end

    def validate(
      root:, base:, head:, registry_path:, exemptions: [], approved_rules: [], evidence_errors: [],
      execution_profile: "local"
    )
      unless EXECUTION_PROFILES.include?(execution_profile)
        return { "valid" => false, "errors" => ["unknown_execution_profile: #{execution_profile}"] }
      end
      registry_raw = blob(root, head, registry_path)
      return { "valid" => false, "errors" => ["registry_missing: #{registry_path}"] } unless registry_raw
      registry = YAML.safe_load(registry_raw, permitted_classes: [], permitted_symbols: [], aliases: false)
      errors = WorkflowKit::SpecRegistry.validate(registry) + Array(evidence_errors)
      return { "valid" => false, "errors" => errors } unless errors.empty?

      profile_errors = execution_profile_errors(root, head, registry, execution_profile)
      return { "valid" => false, "errors" => profile_errors } unless profile_errors.empty?

      changed = changed_paths(root, base, head)
      high = (WorkflowKit::SpecRegistry.default_high_risk_globs + Array(registry["additional_high_risk_globs"])).uniq
      touched_rules = {}
      changed.each do |path|
        rules = WorkflowKit::SpecRegistry.matching_rules(registry, path)
        is_high = high.any? { |glob| WorkflowKit::SourceTree.glob_match?(path, glob) }
        errors << "unmapped_high_risk_path: #{path}" if is_high && rules.empty?
        rules.each { |rule| touched_rules[rule["id"]] = rule }
      end

      # Registry-owned artifacts can be changed independently of their source
      # paths. They must still select the declaring rule, and a registry edit
      # must not make the old obligations disappear from the gate.
      Array(registry["rules"]).each do |rule|
        declared = Array(rule["canonical_specs"]) + Array(rule["generated_facts"])
        if changed.any? { |path| declared.include?(path) }
          touched_rules[rule["id"]] = rule
        end
      end
      if changed.include?(registry_path)
        Array(registry["rules"]).each { |rule| touched_rules[rule["id"]] = rule }
        base_raw = blob(root, base, registry_path)
        if base_raw
          base_registry = YAML.safe_load(base_raw, permitted_classes: [], permitted_symbols: [], aliases: false)
          validate_registry_transition(base_registry, registry, errors)
        end
      end

      # Coverage is a property of the complete head tree, not only of the
      # current diff. Otherwise a registry-only PR could silently unmap an
      # existing migration, deploy, auth, workflow, or infrastructure path.
      tracked_paths(root, head).each do |path|
        next unless high.any? { |glob| WorkflowKit::SourceTree.glob_match?(path, glob) }
        next unless WorkflowKit::SpecRegistry.matching_rules(registry, path).empty?

        errors << "unmapped_high_risk_path: #{path}"
      end

      digest = change_set_digest(root, base, head)
      Array(registry["rules"]).each do |rule|
        actual = WorkflowKit::SourceTree.digest(
          WorkflowKit::SourceTree.entries(root, rule["source_globs"], ref: head),
        )
        verified = Array(rule["canonical_specs"]).all? do |path|
          metadata = front_matter(blob(root, head, path))
          metadata.dig("verified_against", "rule_id") == rule["id"] &&
            metadata.dig("verified_against", "source_tree_digest") == actual
        end
        exemption_allowed = rule["impact_policy"] == "spec_update_or_approved_no_impact" &&
          exemption_valid?(exemptions, rule["id"], digest, approved_rules)
        unless verified || exemption_allowed
          errors << "spec_update_required: rule=#{rule['id']}"
        end

        valid_fact_types = Array(rule["generated_facts"]).each_with_object([]) do |path, result|
          fact_type = validate_generated(root, head, rule, path, errors)
          result << fact_type if fact_type
        end
        Array(rule["checks"]).each do |check|
          errors << "unknown_check: rule=#{rule['id']} check=#{check}" unless KNOWN_CHECKS.include?(check)
          required_fact_type = CHECK_EVIDENCE_TYPES[check]
          if required_fact_type && !valid_fact_types.include?(required_fact_type)
            errors << "check_evidence_missing: rule=#{rule['id']} check=#{check} fact_type=#{required_fact_type}"
          end
          if check == "release-wrapper-required" && blob(root, head, "deploy/release.rb").nil?
            errors << "release_wrapper_missing: rule=#{rule['id']}"
          end
        end
      end

      {
        "valid" => errors.empty?,
        "base" => base,
        "head" => head,
        "changed_paths" => changed,
        "change_set_digest" => digest,
        "touched_rules" => touched_rules.keys.sort,
        "errors" => errors.uniq,
      }
    rescue Psych::Exception, ArgumentError => error
      { "valid" => false, "errors" => [error.message] }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    root: ".", head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml", approved_rules: [],
    execution_profile: "local",
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: validate_spec_freshness.rb --base REF [options]"
    opts.on("--root DIR") { |value| options[:root] = value }
    opts.on("--base REF") { |value| options[:base] = value }
    opts.on("--head REF") { |value| options[:head] = value }
    opts.on("--registry PATH") { |value| options[:registry_path] = value }
    opts.on("--exemptions FILE") { |value| options[:exemptions_path] = value }
    opts.on("--approved-rule ID") { |value| options[:approved_rules] << value }
    opts.on("--execution-profile PROFILE", WorkflowKit::SpecFreshness::EXECUTION_PROFILES) do |value|
      options[:execution_profile] = value
    end
    opts.on("--github-event FILE") { |value| options[:github_event_path] = value }
    opts.on("--github-reviews FILE") { |value| options[:github_reviews_path] = value }
    opts.on("--github-repository OWNER/REPO") { |value| options[:github_repository] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless options[:base] && ARGV.empty?
  github_mode = options[:github_event_path]
  if github_mode && (options[:exemptions_path] || !options[:approved_rules].empty?)
    abort "--github-event cannot be combined with manual exemption approval inputs"
  end
  if github_mode && options[:github_repository].to_s.empty?
    abort "--github-repository is required with --github-event"
  end
  exemptions = options[:exemptions_path] ? JSON.parse(File.read(options[:exemptions_path])) : []
  evidence_errors = []
  if github_mode
    event = JSON.parse(File.read(options[:github_event_path]))
    pull_request = event["pull_request"]
    if pull_request.is_a?(Hash) && options[:github_reviews_path].to_s.empty?
      evidence_errors << "github_reviews_missing"
      exemptions = []
      options[:approved_rules] = []
    else
      reviews = options[:github_reviews_path] ? JSON.parse(File.read(options[:github_reviews_path])) : []
      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: options[:root], base: options[:base], head: options[:head],
        registry_path: options[:registry_path], event: event, reviews: reviews,
        repository: options[:github_repository],
      )
      exemptions = evidence[:exemptions]
      options[:approved_rules] = evidence[:approved_rules]
      evidence_errors.concat(evidence[:errors])
    end
  end
  internal_keys = %i[exemptions_path github_event_path github_reviews_path github_repository]
  result = WorkflowKit::SpecFreshness.validate(
    **options.reject { |key, _| internal_keys.include?(key) }
      .merge(exemptions: exemptions, evidence_errors: evidence_errors),
  )
  puts JSON.pretty_generate(result)
  exit(result["valid"] ? 0 : 30)
end
