#!/usr/bin/env ruby

require_relative "workflow_lib"
require "digest"
require "open3"
require "pathname"
require "time"

errors = []
notices = []

required_files = [
  AgentWorkflow::PROJECT_MAP_PATH,
  AgentWorkflow::ENV_MATRIX_PATH,
  AgentWorkflow::PROJECT_RULES_PATH,
  AgentWorkflow::CONTEXT_MAP_PATH,
  File.join(AgentWorkflow::ROOT, "AGENTS.md"),
  File.join(AgentWorkflow::ROOT, ".ai", "runtime", "githooks", "pre-commit"),
  File.join(AgentWorkflow::ROOT, ".ai", "runtime", "githooks", "pre-push"),
  File.join(AgentWorkflow::ROOT, ".github", "workflows", "agent-workflow-policy.yml"),
]

AgentWorkflow::AGENT_PROFILES.each do |profile|
  required_files << File.join(AgentWorkflow::AI_ROOT, "runtime", "agents", "base", "#{profile}.md")
end

%w[
  workflow_lib.rb
  create_feature.rb
  activate_stream.rb
  finish_stream.rb
  finish_feature.rb
  validate_agent_structure.rb
  validate_docs_sync.rb
  validate_work_scope.rb
  workflow_policy.rb
  check_workflow_policy.rb
  collect_context.rb
  propose_feature.rb
  setup_local_hooks.sh
  workflow_evidence.rb
  adoption_receipt.rb
  validate_change_set.rb
  scan_repository_secrets.rb
].each do |name|
  required_files << File.join(AgentWorkflow::AI_ROOT, "runtime", "scripts", name)
end

required_files.each do |path|
  errors << "Missing required file: #{path}" unless File.exist?(path)
end

headings = ["## Role", "## Editable Areas", "## Never Edit", "## Coding Style", "## Review Rules"]
AgentWorkflow::AGENT_PROFILES.each do |profile|
  path = File.join(AgentWorkflow::AI_ROOT, "runtime", "agents", "base", "#{profile}.md")
  next unless File.exist?(path)

  text = File.read(path)
  headings.each do |heading|
    errors << "#{path} is missing required heading: #{heading}" unless text.include?(heading)
  end
end

project_map = AgentWorkflow.project_map
configured_workspace_root = project_map.dig("workspace", "root").to_s
if configured_workspace_root.empty?
  errors << "#{AgentWorkflow::PROJECT_MAP_PATH} must define workspace.root"
elsif configured_workspace_root == "."
  # A relative dot is the portable representation used by projects that own
  # their context. It always means the current checkout root.
elsif !configured_workspace_root.start_with?(File::SEPARATOR)
  errors << "#{AgentWorkflow::PROJECT_MAP_PATH} workspace.root must be . or an absolute canonical-workspace hint"
else
  begin
    configured_root = File.realpath(configured_workspace_root)
    actual_root = File.realpath(AgentWorkflow::ROOT)
    if configured_root != actual_root
      notices << "#{AgentWorkflow::PROJECT_MAP_PATH} workspace.root names another checkout: #{configured_workspace_root}"
    end
  rescue Errno::ENOENT, Errno::EACCES
    notices << "#{AgentWorkflow::PROJECT_MAP_PATH} workspace.root is an unavailable canonical-workspace hint: #{configured_workspace_root}"
  end
end

local_root = if AgentWorkflow.const_defined?(:LOCAL_ROOT)
  AgentWorkflow::LOCAL_ROOT
else
  File.join(AgentWorkflow::AI_ROOT, "local")
end
if File.exist?(local_root)
  errors << "#{local_root} must be a directory, not a symlink" unless File.directory?(local_root) && !File.symlink?(local_root)
  local_active_path = if AgentWorkflow.const_defined?(:ACTIVE_CONTEXT_PATH) && AgentWorkflow::ACTIVE_CONTEXT_PATH.start_with?(local_root)
    AgentWorkflow::ACTIVE_CONTEXT_PATH
  else
    File.join(local_root, "ACTIVE_CONTEXT.yaml")
  end
  if File.file?(local_active_path)
    local_context = AgentWorkflow.load_yaml(local_active_path, {})
    errors << "#{local_active_path} must be a map" unless local_context.is_a?(Hash)
    errors << "#{local_active_path} active_streams must be an array" unless local_context["active_streams"].is_a?(Array)
    errors << "#{local_active_path} active_features must be an array" unless local_context["active_features"].is_a?(Array)
  end

  stdout, _stderr, status = Open3.capture3("git", "-C", AgentWorkflow::ROOT, "ls-files", "--", ".ai/local")
  tracked_local = stdout.lines.map(&:strip).reject(&:empty?).reject { |path| path == ".ai/local/.gitignore" }
  if status.success? && !tracked_local.empty?
    errors << "#{local_root} contains Git-tracked local execution state: #{tracked_local.join(', ')}"
  end
end

installation_path = File.join(AgentWorkflow::AI_ROOT, "KIT_INSTALLATION.yaml")
installation_required = project_map["version"].to_i >= 2
if installation_required && !File.file?(installation_path)
  errors << "Missing required installation manifest: #{installation_path}"
elsif File.file?(installation_path)
  installation = AgentWorkflow.load_yaml(installation_path, {})
  schema_version = installation["schema_version"]
  errors << "#{installation_path} schema_version must be integer 1 or 2" unless schema_version.is_a?(Integer) && [1, 2].include?(schema_version)
  errors << "#{installation_path} kit_version must be a non-empty string" if installation["kit_version"].to_s.strip.empty?
  if schema_version == 2
    state = installation["installation_state"].to_s
    errors << "#{installation_path} installation_state must be managed or legacy" unless %w[managed legacy].include?(state)
    bundle_digest = installation["kit_bundle_digest"]
    release_manifest_digest = installation["release_manifest_digest"]
    if state == "managed"
      errors << "#{installation_path} kit_bundle_digest must be a sha256-prefixed digest" unless bundle_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      errors << "#{installation_path} release_manifest_digest must be a sha256-prefixed digest" unless release_manifest_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    elsif !bundle_digest.nil? && !bundle_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      errors << "#{installation_path} kit_bundle_digest must be null or a sha256-prefixed digest"
    elsif !release_manifest_digest.nil?
      errors << "#{installation_path} release_manifest_digest must be null for an unmanaged install"
    end
    rendered_digest = installation["rendered_install_digest"].to_s
    errors << "#{installation_path} rendered_install_digest must be a sha256-prefixed digest" unless rendered_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
    errors << "#{installation_path} bundle_digest_algo must be 2" unless installation["bundle_digest_algo"] == 2
    errors << "#{installation_path} rendered_digest_algo must be 2" unless installation["rendered_digest_algo"] == 2
    errors << "#{installation_path} dirty_snapshot_algo must be 4" unless installation["dirty_snapshot_algo"] == 4
    errors << "#{installation_path} repository_fingerprint must be a sha256-prefixed digest" unless installation["repository_fingerprint"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    errors << "#{installation_path} profile must be a non-empty string" if installation["profile"].to_s.empty?
    protected_paths = installation["protected_paths"]
    errors << "#{installation_path} protected_paths must be a non-empty array" unless protected_paths.is_a?(Array) && !protected_paths.empty?
    source = installation["source"]
    if !source.is_a?(Hash)
      errors << "#{installation_path} source must be a map"
    elsif state == "managed"
      errors << "#{installation_path} managed source.kind must be local or github-release" unless %w[local github-release].include?(source["kind"].to_s)
      errors << "#{installation_path} managed source.manifest_locator is required" if source["manifest_locator"].to_s.empty?
      errors << "#{installation_path} managed source.bundle_archive_sha256 must be a sha256-prefixed digest" unless source["bundle_archive_sha256"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    end
    errors << "#{installation_path} provenance must be a map" unless installation["provenance"].is_a?(Hash)
  end
  %w[installed_at updated_at].each do |key|
    begin
      Time.iso8601(installation[key].to_s)
    rescue ArgumentError
      errors << "#{installation_path} #{key} must be ISO-8601"
    end
  end
  installed_workspace_root = installation["workspace_root"].to_s
  if installed_workspace_root.empty?
    errors << "#{installation_path} workspace_root is required"
  elsif installed_workspace_root == "."
    # Portable lock representation.
  elsif !installed_workspace_root.start_with?(File::SEPARATOR)
    errors << "#{installation_path} workspace_root must be . or an absolute installation-worktree hint"
  else
    begin
      installed_root = File.realpath(installed_workspace_root)
      if installed_root != File.realpath(AgentWorkflow::ROOT)
        notices << "#{installation_path} workspace_root names the installation worktree, not this checkout: #{installed_workspace_root}"
      end
    rescue Errno::ENOENT, Errno::EACCES
      notices << "#{installation_path} workspace_root is an unavailable installation-worktree hint: #{installed_workspace_root}"
    end
  end

  git_info = installation["git"]
  unless git_info.is_a?(Hash)
    errors << "#{installation_path} git must be a map"
  else
    errors << "#{installation_path} git.top_level is required" if git_info["top_level"].to_s.empty?
    errors << "#{installation_path} git.git_dir_kind must be directory or file" unless %w[directory file].include?(git_info["git_dir_kind"].to_s)
    errors << "#{installation_path} git.linked_worktree must be boolean" unless [true, false].include?(git_info["linked_worktree"])
  end

  installed_files = installation["installed_files"] || installation["files"]
  unless installed_files.is_a?(Array) && !installed_files.empty?
    errors << "#{installation_path} installed_files must be a non-empty array"
  else
    seen_paths = {}
    installed_files.each_with_index do |entry, index|
      prefix = "#{installation_path} installed_files[#{index}]"
      unless entry.is_a?(Hash)
        errors << "#{prefix} must be a map"
        next
      end
      path = entry["path"].to_s
      clean = Pathname.new(path).cleanpath.to_s rescue ""
      safe_path = !path.empty? && clean != ".." && !clean.start_with?("../") && !clean.start_with?("/")
      errors << "#{prefix}.path must be a safe relative path" unless safe_path
      errors << "#{prefix}.path is duplicated: #{path}" if seen_paths[path]
      seen_paths[path] = true
      digest = entry["sha256"].to_s
      valid_digest = digest.match?(/\A[0-9a-f]{64}\z/)
      errors << "#{prefix}.sha256 must be 64 lowercase hex" unless valid_digest
      baseline_digest = entry["baseline_sha256"].to_s
      errors << "#{prefix}.baseline_sha256 must be 64 lowercase hex" unless baseline_digest.empty? || baseline_digest.match?(/\A[0-9a-f]{64}\z/)
      template_digest = entry["template_sha256"].to_s
      errors << "#{prefix}.template_sha256 must be 64 lowercase hex" unless template_digest.empty? || template_digest.match?(/\A[0-9a-f]{64}\z/)
      mode = entry["mode"].to_s
      valid_mode = mode.match?(/\A[0-7]{3,4}\z/)
      errors << "#{prefix}.mode must be 3 or 4 octal digits" unless valid_mode
      ownership = entry["ownership"].to_s
      allowed_ownership = %w[project kit legacy kit-owned merge-owned project-owned generated]
      errors << "#{prefix}.ownership must use a supported ownership class" unless allowed_ownership.include?(ownership)

      next unless %w[kit legacy kit-owned merge-owned].include?(ownership) && safe_path

      destination = File.join(AgentWorkflow::ROOT, path)
      if File.symlink?(destination)
        errors << "#{path}: kit-owned managed file must not be a symbolic link"
        next
      end
      unless File.file?(destination)
        errors << "#{path}: kit-owned managed file is missing"
        next
      end

      next if ownership == "legacy"

      _stdout, _stderr, index_matches_worktree = AgentWorkflow.run_git(
        AgentWorkflow::ROOT,
        "diff",
        "--quiet",
        "--",
        path,
      )
      errors << "#{path}: kit-owned index and working tree differ" unless index_matches_worktree

      if valid_digest
        actual_digest = Digest::SHA256.file(destination).hexdigest
        errors << "#{path}: kit-owned digest mismatch" unless digest == actual_digest
      end
      if valid_mode
        expected_mode = format("%04o", mode.to_i(8))
        actual_mode = format("%04o", File.stat(destination).mode & 0o7777)
        errors << "#{path}: kit-owned mode mismatch (expected #{expected_mode}, got #{actual_mode})" unless expected_mode == actual_mode
      end
    end
  end

  history = installation["migration_history"]
  errors << "#{installation_path} migration_history must be an array" unless history.is_a?(Array)
end

if errors.empty?
  puts "OK: agent workflow structure is valid."
  notices.uniq.sort.each { |notice| puts "NOTICE: #{notice}" }
  exit 0
end

puts "ERROR: agent workflow structure is invalid."
errors.each { |error| puts "- #{error}" }
exit 1
