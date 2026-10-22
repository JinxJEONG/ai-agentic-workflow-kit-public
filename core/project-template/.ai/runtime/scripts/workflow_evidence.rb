#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "pathname"
require "time"
require_relative "workflow_lib"

# Shared, side-effect-free helpers for Git change collection and lifecycle
# evidence.  This file deliberately keeps compatibility with scope schema v1
# while preferring the scope-v2 APIs when workflow_lib provides them.
module WorkflowEvidence
  ZERO_SHA = "0" * 40
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze
  PLACEHOLDER_PATTERNS = [
    /\bTBD\b/i,
    /\bNot\s+started\b/i,
    /^\s*[-*]\s*Pending\s*\.?\s*$/i,
    /^\s*[-*]?\s*Status:\s*pending\s*$/i,
    /^\s*[-*]\s*\[\s\]\s+/,
  ].freeze
  TRANSIENT_PATH_PATTERNS = [
    ".ai/local/**",
    ".ai/ACTIVE_CONTEXT.yaml",
    ".ai/tasks/**/streams/**/LOCK.yaml",
    ".ai/tasks/**/streams/**/manifest.yaml",
    ".ai/tasks/**/streams/**/handoff.md",
    ".ai/tasks/**/streams/**/evidence.yaml",
    ".ai/tasks/**/streams/**/review.yaml",
    ".ai/tasks/**/feature.yaml",
  ].freeze
  SECRET_PATTERNS = [
    /\b(?:API[_-]?KEY|TOKEN|PASSWORD|PASSWD|SECRET)\s*[:=]\s*["']?[^\s"']{4,}/i,
    /\bBearer\s+[A-Za-z0-9._~+\/=:-]{8,}/i,
    /\b(?:sk|ghp|github_pat)_[A-Za-z0-9_-]{12,}\b/,
    /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
    /\bxox(?:b|p|a|r|s)-[A-Za-z0-9-]{20,}\b/,
    /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  ].freeze
  RAW_OUTPUT_KEYS = %w[output stdout stderr raw_output command_output log logs].freeze

  module_function

  def git(repo_root, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", repo_root, *args)
    raise "#{repo_root}: git #{args.join(' ')} failed: #{stderr.strip}" unless status.success?

    stdout
  end

  def normalize_repo_path(path)
    value = Pathname.new(path.to_s).cleanpath.to_s.sub(%r{\A\./}, "")
    raise "unsafe Git path: #{path.inspect}" if value == ".." || value.start_with?("../") || value.start_with?("/")

    value
  end

  def parse_name_status_z(output, repo_root)
    fields = output.split("\0")
    fields.pop while fields.last == ""
    entries = []
    index = 0

    while index < fields.length
      raw_status = fields[index].to_s
      index += 1
      status = raw_status[0, 1]
      if %w[R C].include?(status)
        old_rel = normalize_repo_path(fields.fetch(index))
        new_rel = normalize_repo_path(fields.fetch(index + 1))
        index += 2
      else
        old_rel = nil
        new_rel = normalize_repo_path(fields.fetch(index))
        index += 1
      end

      entries << {
        "status" => status,
        "raw_status" => raw_status,
        "old_relative_path" => old_rel,
        "new_relative_path" => new_rel,
        "old_path" => old_rel && File.expand_path(old_rel, repo_root),
        "new_path" => new_rel && File.expand_path(new_rel, repo_root),
      }
    end

    entries
  rescue IndexError => error
    raise "invalid git --name-status -z output: #{error.message}"
  end

  def git_changes(repo_root:, staged: false, range: nil, include_untracked: false)
    repo_root = File.realpath(repo_root)
    args = %w[diff --name-status -z --find-renames --find-copies]
    args << "--cached" if staged
    args << range.to_s unless range.to_s.empty?
    args << "--"
    entries = parse_name_status_z(git(repo_root, *args), repo_root)

    if include_untracked
      git(repo_root, "ls-files", "--others", "--exclude-standard", "-z").split("\0").reject(&:empty?).each do |path|
        rel = normalize_repo_path(path)
        entries << {
          "status" => "A",
          "raw_status" => "A-untracked",
          "old_relative_path" => nil,
          "new_relative_path" => rel,
          "old_path" => nil,
          "new_path" => File.expand_path(rel, repo_root),
        }
      end
    end

    entries.uniq { |entry| [entry["raw_status"], entry["old_relative_path"], entry["new_relative_path"]] }
  end

  def entry_paths(entry)
    [entry["old_path"], entry["new_path"]].compact.uniq
  end

  def entry_relative_paths(entry)
    [entry["old_relative_path"], entry["new_relative_path"]].compact.uniq
  end

  def baseline_ref(feature)
    feature["baseline_ref"].to_s.strip.empty? ? "HEAD" : feature["baseline_ref"].to_s.strip
  end

  def resolve_git_commit(repo_root, ref)
    stdout, _stderr, status = Open3.capture3("git", "-C", repo_root, "rev-parse", "--verify", "#{ref}^{commit}")
    value = stdout.strip
    status.success? && value.match?(/\A[0-9a-f]{40,64}\z/i) ? value.downcase : nil
  end

  def single_commit_range?(repo_root, range)
    range_parts = range.to_s.split("..", -1)
    return false unless range_parts.length == 2

    base_ref, head_ref = range_parts
    return false if base_ref.to_s.empty? || head_ref.to_s.empty?

    head = resolve_git_commit(repo_root, head_ref)
    return false unless head

    fields = git(repo_root, "rev-list", "--parents", "-n", "1", head).strip.split
    return false unless fields.shift.to_s.downcase == head

    base = resolve_git_commit(repo_root, base_ref)
    return fields == [base] if base

    base_tree = git(repo_root, "rev-parse", "--verify", "#{base_ref}^{tree}").strip.downcase
    empty_tree, _stderr, status = Open3.capture3("git", "-C", repo_root, "mktree", stdin_data: "")
    status.success? && base_tree == empty_tree.strip.downcase && fields.empty?
  rescue StandardError
    false
  end

  def git_index_contains_paths?(repo_root, paths)
    Array(paths).all? do |path|
      relative = normalize_repo_path(path)
      _stdout, _stderr, status = Open3.capture3(
        "git",
        "-C",
        repo_root,
        "ls-files",
        "--error-unmatch",
        "--",
        relative,
      )
      status.success?
    end
  rescue StandardError
    false
  end

  def git_index_matches_worktree?(repo_root, path)
    relative = normalize_repo_path(path)
    _stdout, _stderr, status = Open3.capture3(
      "git",
      "-C",
      repo_root,
      "diff",
      "--quiet",
      "--",
      relative,
    )
    status.success?
  rescue StandardError
    false
  end

  def stream_scopes(manifest)
    if AgentWorkflow.respond_to?(:implementation_scopes)
      Array(AgentWorkflow.implementation_scopes(manifest))
    else
      Array(manifest["write_scope"])
    end
  end

  def feature_scopes(feature_id)
    feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
    return [] unless feature_dir

    scopes = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).flat_map do |manifest_path|
      stream_scopes(AgentWorkflow.load_yaml(manifest_path, {}))
    end
    scopes.concat([
      File.join(feature_dir, "spec.md"),
      File.join(feature_dir, "contracts/**"),
    ])
    scopes.compact.uniq
  end

  def transient_path?(absolute_path)
    relative = AgentWorkflow.relative_to_root(absolute_path)
    return true unless relative

    TRANSIENT_PATH_PATTERNS.any? { |pattern| AgentWorkflow.path_glob_match?(relative, pattern) }
  end

  def entry_matches_scopes?(entry, scopes)
    entry_paths(entry).any? do |path|
      !transient_path?(path) && scopes.any? { |scope| AgentWorkflow.path_in_scope?(path, scope) }
    end
  end

  def file_fingerprint(path)
    return "deleted" unless File.exist?(path) || File.symlink?(path)
    return "symlink:#{File.readlink(path)}" if File.symlink?(path)
    return "non-file" unless File.file?(path)

    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end

  def digest_entries(entries)
    records = entries.flat_map do |entry|
      old_rel = entry["old_relative_path"]
      new_rel = entry["new_relative_path"]
      normalized_status = entry["status"].to_s
      if %w[R C].include?(entry["status"])
        [
          [normalized_status, "old", old_rel, "moved"],
          [normalized_status, "new", new_rel, file_fingerprint(entry["new_path"])],
        ]
      else
        [[normalized_status, "path", new_rel, file_fingerprint(entry["new_path"])]]
      end
    end.sort_by { |record| record.join("\0") }

    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(records))}"
  end

  def feature_change_set(feature_id, repo_root: AgentWorkflow::ROOT)
    feature = AgentWorkflow.load_feature(feature_id)
    baseline_value = baseline_ref(feature)
    baseline = resolve_git_commit(repo_root, baseline_value)
    raise "#{feature_id} baseline_ref is not a commit: #{baseline_value}" unless baseline

    entries = git_changes(repo_root: repo_root, range: baseline, include_untracked: true)
    selected = entries.select { |entry| entry_matches_scopes?(entry, feature_scopes(feature_id)) }
    {
      "baseline_ref" => baseline,
      "digest" => digest_entries(selected),
      "changes" => selected,
    }
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def placeholder_lines(path)
    return ["missing file"] unless File.file?(path)

    File.readlines(path).each_with_index.each_with_object([]) do |(line, index), matches|
      matches << "line #{index + 1}: #{line.strip}" if PLACEHOLDER_PATTERNS.any? { |pattern| line.match?(pattern) }
    end
  end

  def sensitive_scalar_errors(value, prefix, errors)
    case value
    when Hash
      value.each do |key, child|
        child_prefix = "#{prefix}.#{key}"
        if RAW_OUTPUT_KEYS.include?(key.to_s)
          errors << "#{child_prefix}: raw command output is forbidden; store only output_digest"
        else
          sensitive_scalar_errors(child, child_prefix, errors)
        end
      end
    when Array
      value.each_with_index { |child, index| sensitive_scalar_errors(child, "#{prefix}[#{index}]", errors) }
    when String
      errors << "#{prefix}: value appears to contain a secret and must not be recorded" if SECRET_PATTERNS.any? { |pattern| value.match?(pattern) }
    end
    errors
  end

  def evidence_errors(feature_id, stream_id, repo_root: AgentWorkflow::ROOT)
    stream_dir = AgentWorkflow.stream_dir(feature_id, stream_id)
    path = File.join(stream_dir, "evidence.yaml")
    errors = []
    return [["#{path}: missing structured completion evidence"], { "path" => path }] unless File.file?(path)

    evidence = AgentWorkflow.load_yaml(path, {})
    sensitive_scalar_errors(evidence, path, errors)
    errors << "#{path}: schema_version must be 1" unless evidence["schema_version"].to_i == 1
    errors << "#{path}: feature_id must be #{feature_id}" unless evidence["feature_id"].to_s == feature_id
    errors << "#{path}: stream_id must be #{stream_id}" unless evidence["stream_id"].to_s == stream_id
    %w[implementation_complete acceptance_complete docs_synced].each do |key|
      errors << "#{path}: #{key} must be true" unless evidence[key] == true
    end
    errors << "#{path}: remaining_drift must be an empty array" unless evidence["remaining_drift"].is_a?(Array) && evidence["remaining_drift"].empty?

    validations = evidence["validations"]
    if !validations.is_a?(Array) || validations.empty?
      errors << "#{path}: validations must contain at least one executed command"
    else
      validations.each_with_index do |validation, index|
        prefix = "#{path}: validations[#{index}]"
        unless validation.is_a?(Hash)
          errors << "#{prefix} must be a map"
          next
        end
        command = validation["command"].to_s.strip
        errors << "#{prefix}.command is required" if command.empty? || command.match?(/TBD|Pending|Not started/i)
        errors << "#{prefix}.exit_code must be integer 0" unless validation["exit_code"].is_a?(Integer) && validation["exit_code"].zero?
        executed_at = parse_time(validation["executed_at"])
        errors << "#{prefix}.executed_at must be ISO-8601" unless executed_at
        errors << "#{prefix}.executed_at cannot be in the future" if executed_at && executed_at > Time.now.utc + 300
        digest = validation["output_digest"].to_s
        errors << "#{prefix}.output_digest must be sha256:<64 lowercase hex>" unless digest.match?(DIGEST_PATTERN)
      end
    end

    change_set = feature_change_set(feature_id, repo_root: repo_root)
    revision = evidence["validated_revision"]
    unless revision.is_a?(Hash)
      errors << "#{path}: validated_revision must be a map"
    else
      errors << "#{path}: validated_revision.type must be change_set_digest" unless revision["type"].to_s == "change_set_digest"
      errors << "#{path}: validated_revision.value is stale; expected #{change_set['digest']}" unless revision["value"].to_s == change_set["digest"]
      errors << "#{path}: validated_revision.baseline_ref must be #{change_set['baseline_ref']}" unless revision["baseline_ref"].to_s == change_set["baseline_ref"]
    end

    [errors, {
      "path" => path,
      "evidence" => evidence,
      "change_set" => change_set,
    }]
  rescue StandardError => error
    [["#{path}: failed to validate evidence: #{error.message}"], { "path" => path }]
  end

  def review_file(feature_dir)
    candidates = Dir.glob(File.join(feature_dir, "streams", "*", "review.yaml")).select do |path|
      manifest_path = File.join(File.dirname(path), "manifest.yaml")
      AgentWorkflow.load_yaml(manifest_path, {})["agent_profile"].to_s == "reviewer"
    end
    candidates.length == 1 ? candidates.first : nil
  end

  def review_errors(feature_id, require_human: false, repo_root: AgentWorkflow::ROOT)
    feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
    return [["Missing feature #{feature_id}"], {}] unless feature_dir

    path = review_file(feature_dir)
    return [["#{feature_id}: exactly one reviewer-profile review.yaml is required"], {}] unless path

    review = AgentWorkflow.load_yaml(path, {})
    manifest = AgentWorkflow.load_yaml(File.join(File.dirname(path), "manifest.yaml"), {})
    change_set = feature_change_set(feature_id, repo_root: repo_root)
    errors = []
    sensitive_scalar_errors(review, path, errors)
    errors << "#{path}: schema_version must be 1" unless review["schema_version"].to_i == 1
    errors << "#{path}: feature_id must be #{feature_id}" unless review["feature_id"].to_s == feature_id
    errors << "#{path}: reviewer_profile must be reviewer" unless review["reviewer_profile"].to_s == "reviewer"
    errors << "#{path}: status must be passed" unless review["status"].to_s == "passed"
    errors << "#{path}: findings_open must be integer 0" unless review["findings_open"].is_a?(Integer) && review["findings_open"].zero?
    errors << "#{path}: reviewer_owner_agent must match reviewer manifest owner_agent" unless review["reviewer_owner_agent"].to_s == manifest["owner_agent"].to_s && !review["reviewer_owner_agent"].to_s.empty?
    reviewed_at = parse_time(review["reviewed_at"])
    errors << "#{path}: reviewed_at must be ISO-8601" unless reviewed_at
    errors << "#{path}: reviewed_at cannot be in the future" if reviewed_at && reviewed_at > Time.now.utc + 300

    revision = review["reviewed_revision"]
    unless revision.is_a?(Hash)
      errors << "#{path}: reviewed_revision must be a map"
    else
      errors << "#{path}: reviewed_revision.type must be change_set_digest" unless revision["type"].to_s == "change_set_digest"
      errors << "#{path}: review is stale; expected #{change_set['digest']}" unless revision["value"].to_s == change_set["digest"]
      if revision.key?("baseline_ref") && revision["baseline_ref"].to_s != change_set["baseline_ref"]
        errors << "#{path}: reviewed_revision.baseline_ref must be #{change_set['baseline_ref']}"
      end
    end

    human = review["human_approval"]
    if require_human
      unless human.is_a?(Hash)
        errors << "#{path}: tier3 requires human_approval"
      else
        errors << "#{path}: human_approval.required must be true" unless human["required"] == true
        errors << "#{path}: human_approval.status must be approved" unless human["status"].to_s == "approved"
        errors << "#{path}: human_approval.approved_by is required" if human["approved_by"].to_s.strip.empty?
        errors << "#{path}: human_approval.source is required" if human["source"].to_s.strip.empty?
        approved_at = parse_time(human["approved_at"])
        errors << "#{path}: human_approval.approved_at must be ISO-8601" unless approved_at
        approved_revision = human["approved_revision"]
        unless approved_revision.is_a?(Hash) && approved_revision["type"].to_s == "change_set_digest" && approved_revision["value"].to_s == change_set["digest"]
          errors << "#{path}: human approval must bind to current change-set digest #{change_set['digest']}"
        end
      end
    end

    [errors, { "path" => path, "review" => review, "change_set" => change_set }]
  rescue StandardError => error
    [["#{feature_id}: failed to validate review: #{error.message}"], {}]
  end

  def completed_feature_errors(feature_id, repo_root: AgentWorkflow::ROOT)
    feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
    return [["Missing feature #{feature_id}"], {}] unless feature_dir

    feature_path = File.join(feature_dir, "feature.yaml")
    feature = AgentWorkflow.load_yaml(feature_path, {})
    errors = []
    errors << "#{feature_path}: completed change set requires feature status done" unless feature["status"].to_s == "done"
    if feature["deployment_status"].to_s.empty?
      errors << "#{feature_path}: completed feature must record deployment_status separately"
    end

    manifest_paths = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).sort
    declared_streams = Array(feature["streams"]).map(&:to_s).sort
    actual_streams = manifest_paths.map { |path| AgentWorkflow.load_yaml(path, {})["stream_id"].to_s }.sort
    errors << "#{feature_path}: declared streams do not match manifest directories" unless declared_streams == actual_streams

    manifest_paths.each do |manifest_path|
      manifest = AgentWorkflow.load_yaml(manifest_path, {})
      stream_id = manifest["stream_id"].to_s
      errors << "#{manifest_path}: completed feature requires stream status done" unless manifest["status"].to_s == "done"
      evidence_errors_for_stream, = evidence_errors(feature_id, stream_id, repo_root: repo_root)
      errors.concat(evidence_errors_for_stream)
    end

    acceptance_path = feature.dig("contracts", "acceptance").to_s
    acceptance_path = File.join(feature_dir, "contracts", "acceptance.md") if acceptance_path.empty?
    acceptance_path = AgentWorkflow.absolute_path(acceptance_path)
    placeholder_lines(acceptance_path).each do |line|
      errors << "#{acceptance_path}: acceptance is incomplete (#{line})"
    end

    change_set = feature_change_set(feature_id, repo_root: repo_root)
    change_set_path = feature["change_set"].to_s
    change_set_path = File.join(feature_dir, "change-set.yaml") if change_set_path.empty?
    change_set_path = AgentWorkflow.absolute_path(change_set_path)
    record = AgentWorkflow.load_yaml(change_set_path, {})
    errors << "#{change_set_path}: status must be validated" unless record["status"].to_s == "validated"
    errors << "#{change_set_path}: change_set_digest is stale; expected #{change_set['digest']}" unless record["change_set_digest"].to_s == change_set["digest"]
    errors << "#{change_set_path}: baseline_ref must be #{change_set['baseline_ref']}" unless record["baseline_ref"].to_s == change_set["baseline_ref"]

    [errors, { "feature" => feature, "change_set" => change_set, "change_set_path" => change_set_path }]
  rescue StandardError => error
    [["#{feature_id}: failed to validate completed feature: #{error.message}"], {}]
  end
end
