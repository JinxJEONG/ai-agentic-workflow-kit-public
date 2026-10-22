#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "time"
require "yaml"

require_relative "../../installer/lib/install_integrity"
require_relative "../release/release_digest"
require_relative "../release/release_manifest"
require_relative "schema"

KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
MANIFEST_SCHEMA_VERSION = 2
SUPPORTED_MANIFEST_SCHEMA_VERSIONS = [1, MANIFEST_SCHEMA_VERSION].freeze
INSTALLATION_MANIFEST = File.join(".ai", "KIT_INSTALLATION.yaml")
TRUSTED_KIT_SOURCE_MODES = %w[git action-source].freeze
EXECUTION_PROFILES = %w[local hosted-no-project-code].freeze
HOSTED_STRUCTURE_REQUIRED_PATHS = %w[
  .ai/canonical/PROJECT_MAP.yaml
  .ai/canonical/ENV_MATRIX.yaml
  .ai/canonical/PROJECT_RULES.md
  .ai/canonical/context-map.yaml
  AGENTS.md
  .ai/runtime/githooks/pre-commit
  .ai/runtime/githooks/pre-push
  .github/workflows/agent-workflow-policy.yml
  .ai/runtime/scripts/validate_agent_structure.rb
].freeze
HOSTED_AGENT_PROFILES = %w[architect backend frontend reviewer pm ai-worker].freeze
HOSTED_AGENT_HEADINGS = [
  "## Role", "## Editable Areas", "## Never Edit", "## Coding Style", "## Review Rules",
].freeze

def git_value(target, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", target, *args)
  [stdout.strip, stderr.strip, status.success?]
end

def resolved_git_path(target, value)
  File.realpath(File.expand_path(value, target))
end

def current_git_info(target, errors)
  inside, error, ok = git_value(target, "rev-parse", "--is-inside-work-tree")
  unless ok && inside == "true"
    errors << "Target is not a Git work tree: #{error}"
    return nil
  end

  top_level_value, error, ok = git_value(target, "rev-parse", "--show-toplevel")
  unless ok
    errors << "Cannot determine Git top-level: #{error}"
    return nil
  end
  top_level = File.realpath(top_level_value)
  errors << "Target is not the Git top-level: #{target} (Git top-level: #{top_level})" unless top_level == target

  git_dir_value, error, git_dir_ok = git_value(target, "rev-parse", "--git-dir")
  common_dir_value, common_error, common_dir_ok = git_value(target, "rev-parse", "--git-common-dir")
  unless git_dir_ok && common_dir_ok
    errors << "Cannot inspect Git worktree metadata: #{[error, common_error].reject(&:empty?).join('; ')}"
    return nil
  end

  dot_git = File.join(target, ".git")
  {
    "top_level" => top_level,
    "git_dir_kind" => File.file?(dot_git) ? "file" : "directory",
    "linked_worktree" => resolved_git_path(target, git_dir_value) != resolved_git_path(target, common_dir_value),
  }
rescue Errno::ENOENT, Errno::EACCES => error
  errors << "Cannot resolve Git metadata: #{error.message}"
  nil
end

def kit_version
  path = File.join(KIT_ROOT, "VERSION")
  return "development" unless File.file?(path)

  value = File.read(path).strip
  value.empty? ? "development" : value
end

def valid_iso8601?(value)
  Time.iso8601(value.to_s)
  true
rescue ArgumentError
  false
end

def safe_relative_path?(path)
  value = path.to_s
  return false if value.empty? || Pathname.new(value).absolute?
  return false if value.split(/[\\\/]/).include?("..")

  Pathname.new(value).cleanpath.to_s == value
end

def validate_hosted_structure(target, errors, notices)
  # This is the hosted equivalent of the installed structure script. It lives
  # in the trusted central validator and treats the target only as data: no Ruby,
  # shell, hook, or other executable below target is invoked.
  required = HOSTED_STRUCTURE_REQUIRED_PATHS + HOSTED_AGENT_PROFILES.map do |profile|
    ".ai/runtime/agents/base/#{profile}.md"
  end
  required.each do |relative|
    path = File.join(target, relative)
    if File.symlink?(path) || !File.file?(path)
      errors << "Missing or unsafe required structure file: #{relative}"
    end
  end

  HOSTED_AGENT_PROFILES.each do |profile|
    relative = ".ai/runtime/agents/base/#{profile}.md"
    path = File.join(target, relative)
    next unless File.file?(path) && !File.symlink?(path)

    text = File.read(path)
    HOSTED_AGENT_HEADINGS.each do |heading|
      errors << "#{relative} is missing required heading: #{heading}" unless text.include?(heading)
    end
  end

  local_root = File.join(target, ".ai", "local")
  if File.symlink?(local_root)
    errors << ".ai/local must be a directory, not a symlink"
  elsif File.exist?(local_root)
    errors << ".ai/local must be a directory, not a special file" unless File.directory?(local_root)
    active = File.join(local_root, "ACTIVE_CONTEXT.yaml")
    if File.file?(active) && !File.symlink?(active)
      begin
        context = YAML.safe_load(
          File.read(active), permitted_classes: [], permitted_symbols: [], aliases: false,
        )
        unless context.is_a?(Hash) && context["active_streams"].is_a?(Array) &&
            context["active_features"].is_a?(Array)
          errors << ".ai/local/ACTIVE_CONTEXT.yaml must be a map with active_streams and active_features arrays"
        end
      rescue Psych::Exception => error
        errors << "Cannot parse .ai/local/ACTIVE_CONTEXT.yaml safely: #{error.message}"
      end
    elsif File.symlink?(active)
      errors << ".ai/local/ACTIVE_CONTEXT.yaml must not be a symbolic link"
    end
  end

  tracked, detail, ok = git_value(target, "ls-files", "--", ".ai/local")
  if ok
    unexpected = tracked.lines.map(&:strip).reject(&:empty?).reject do |path|
      path == ".ai/local/.gitignore"
    end
    unless unexpected.empty?
      errors << ".ai/local contains Git-tracked local execution state: #{unexpected.join(', ')}"
    end
  else
    errors << "Cannot inspect Git-tracked local execution state: #{detail}"
  end

  notices << "hosted structure validation used trusted central code; target executables were not run"
rescue Errno::ENOENT, Errno::EACCES => error
  errors << "Cannot validate hosted structure safely: #{error.message}"
end

def load_manifest(path, errors)
  unless File.file?(path)
    errors << "Missing installation manifest: #{path}"
    return nil
  end

  value = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  unless value.is_a?(Hash)
    errors << "Installation manifest must contain a YAML mapping: #{path}"
    return nil
  end
  value
rescue Psych::Exception => error
  errors << "Cannot parse installation manifest safely: #{error.message}"
  nil
end

def git_blob(target, source, relative)
  spec = source == :index ? ":#{relative}" : "#{source}:#{relative}"
  stdout, stderr, status = Open3.capture3(
    "git", "-C", target, "show", spec,
    binmode: true,
  )
  [stdout, stderr.to_s.strip, status.success?]
end

def trusted_git_context(target, errors)
  _stdout, stderr, status = Open3.capture3(
    "git", "-C", target, "diff", "--cached", "--quiet", "--", INSTALLATION_MANIFEST,
  )
  if status.exitstatus == 1
    base_source = "HEAD"
    current_source = :index
  elsif status.success?
    lock_commit, detail, ok = git_value(
      target, "log", "-1", "--format=%H", "HEAD", "--", INSTALLATION_MANIFEST,
    )
    unless ok && lock_commit.match?(/\A[0-9a-f]{40}\z/)
      errors << "cannot identify the Git-bound installation lock: #{detail}"
      return nil
    end
    base_source, _detail, base_ok = git_value(target, "rev-parse", "#{lock_commit}^")
    base_source = nil unless base_ok && base_source.match?(/\A[0-9a-f]{40}\z/)
    current_source = "HEAD"
  else
    errors << "cannot inspect the staged installation transition: #{stderr.strip}"
    return nil
  end

  current_bytes, detail, ok = git_blob(target, current_source, INSTALLATION_MANIFEST)
  unless ok
    errors << "cannot read the selected Git installation lock: #{detail}"
    return nil
  end
  worktree_bytes = File.binread(File.join(target, INSTALLATION_MANIFEST))
  unless worktree_bytes == current_bytes
    errors << "worktree installation lock does not match the selected Git content"
  end

  {
    base_source: base_source,
    current_source: current_source,
  }
rescue Errno::ENOENT, Errno::EACCES => error
  errors << "cannot bind the worktree installation lock to Git: #{error.message}"
  nil
end

def trusted_transition_context(target, manifest, git_context, errors)
  unless git_context && git_context[:base_source]
    errors << "trusted installation transition requires a committed pre-installation base"
    return nil
  end

  base_source = git_context.fetch(:base_source)
  previous_bytes, detail, ok = git_blob(target, base_source, INSTALLATION_MANIFEST)
  unless ok
    errors << "cannot read the pre-installation lock at #{base_source}: #{detail}"
    return nil
  end
  previous_manifest = YAML.safe_load(
    previous_bytes, permitted_classes: [], permitted_symbols: [], aliases: false,
  )
  unless previous_manifest.is_a?(Hash)
    errors << "pre-installation lock must contain a YAML mapping"
    return nil
  end

  previous_history = Array(previous_manifest["migration_history"])
  current_history = Array(manifest["migration_history"])
  unless current_history.length == previous_history.length + 1 &&
      current_history.first(previous_history.length) == previous_history
    errors << "latest reviewed approval is not bound to one appended installation migration"
    return nil
  end

  {
    base_source: base_source,
    current_source: git_context.fetch(:current_source),
    migration: current_history.last,
    previous_entries: Array(previous_manifest["installed_files"]).select { |entry| entry.is_a?(Hash) }
      .each_with_object({}) { |entry, result| result[entry["path"].to_s] = entry },
  }
rescue Psych::Exception => error
  errors << "cannot parse the pre-installation lock safely: #{error.message}"
  nil
end

def trusted_reviewed_merge?(entry, relative, target, transition, errors)
  unless transition
    errors << "trusted merge-owned approval cannot be verified for #{relative}"
    return false
  end

  migration = transition.fetch(:migration)
  approvals = Array(migration.is_a?(Hash) ? migration["reviewed_path_approvals"] : [])
    .select { |approval| approval.is_a?(Hash) && approval["path"].to_s == relative }
  if approvals.length != 1
    errors << "trusted merge-owned approval must contain exactly one latest record for #{relative}"
    return false
  end

  approval = approvals.first
  expected = approval["expected_digest"].to_s
  desired = approval["desired_digest"].to_s
  unless expected.match?(/\A[0-9a-f]{64}\z/) && desired.match?(/\A[0-9a-f]{64}\z/)
    errors << "trusted merge-owned approval digests are invalid for #{relative}"
    return false
  end

  base_bytes, base_detail, base_ok = git_blob(
    target, transition.fetch(:base_source), relative,
  )
  current_bytes, current_detail, current_ok = git_blob(
    target, transition.fetch(:current_source), relative,
  )
  unless base_ok && current_ok
    detail = [base_detail, current_detail].reject(&:empty?).join("; ")
    errors << "trusted merge-owned approval cannot read its Git base/current blobs for #{relative}: #{detail}"
    return false
  end

  base_digest = Digest::SHA256.hexdigest(base_bytes)
  current_digest = Digest::SHA256.hexdigest(current_bytes)
  unless expected == base_digest
    errors << "trusted merge-owned approval expected digest does not match the Git base for #{relative}"
  end
  unless desired == current_digest && desired == entry["sha256"] &&
      desired == entry["baseline_sha256"] && desired == entry["template_sha256"]
    errors << "trusted merge-owned approval desired digest does not bind the installed Git content for #{relative}"
  end

  expected == base_digest && desired == current_digest &&
    desired == entry["sha256"] && desired == entry["baseline_sha256"] &&
    desired == entry["template_sha256"]
end

def git_blob_mode(target, source, relative)
  stdout, _stderr, status = Open3.capture3(
    "git", "-C", target, "ls-tree", source.to_s, "--", relative,
  )
  return nil unless status.success?

  mode = stdout.lines.first.to_s.split.first.to_s
  return nil unless mode.match?(/\A[0-7]{6}\z/)

  format("%04o", mode.to_i(8) & 0o7777)
end

def trusted_legacy_relocation?(entry, relative, entries, template_paths, ownership_rules, target, transition)
  return false unless entry["state"].to_s == "legacy"
  return false unless transition

  relocated_to = WorkflowKit::Install::Integrity.legacy_relocation_target(relative)
  return false unless relocated_to && entry["relocated_to"].to_s == relocated_to
  return false unless template_paths.include?(relocated_to)
  return false unless entry["ownership"].to_s == WorkflowKit::Install::Integrity.ownership_for(
    relative, ownership_rules,
  )

  previous_entry = transition.fetch(:previous_entries)[relative]
  return false unless previous_entry.is_a?(Hash)
  preserved_fields = %w[path sha256 baseline_sha256 template_sha256 mode ownership]
  return false unless preserved_fields.all? { |field| entry[field] == previous_entry[field] }
  normalized_previous = previous_entry.merge(
    "state" => "legacy",
    "relocated_to" => relocated_to,
  )
  return false unless entry == normalized_previous

  base_bytes, _detail, base_ok = git_blob(target, transition.fetch(:base_source), relative)
  return false unless base_ok && Digest::SHA256.hexdigest(base_bytes) == previous_entry["sha256"]
  return false unless git_blob_mode(target, transition.fetch(:base_source), relative) == previous_entry["mode"]

  relocated_entry = entries[relocated_to]
  relocated_entry.is_a?(Hash) &&
    relocated_entry["ownership"].to_s == WorkflowKit::Install::Integrity.ownership_for(
      relocated_to, ownership_rules,
    )
rescue WorkflowKit::Install::Integrity::IntegrityError
  false
end

def validate_phase4_caller(target, expected_commit, expected_digest, expected_version, errors)
  registry_path = File.join(target, ".ai", "SPEC_REGISTRY.yaml")
  return unless File.file?(registry_path)

  workflow_path = File.join(target, ".github", "workflows", "agent-workflow-policy.yml")
  workflow = YAML.safe_load(
    File.read(workflow_path), permitted_classes: [], permitted_symbols: [], aliases: false,
  )
  job = workflow.is_a?(Hash) ? workflow.dig("jobs", "spec-gate") : nil
  expected = {
    "name" => "spec-gate",
    "permissions" => {
      "contents" => "read",
      "pull-requests" => "read",
      "id-token" => "write",
    },
    "uses" => "JinxJEONG/ai-agentic-workflow-kit-public/.github/workflows/spec-gate.yml@#{expected_commit}",
    "with" => {
      "kit_repository" => "JinxJEONG/ai-agentic-workflow-kit-public",
      "kit_commit" => expected_commit,
      "kit_version" => expected_version,
      "kit_bundle_digest" => expected_digest,
    },
  }
  errors << "Phase 4 spec-gate caller does not match the trusted kit identity" unless job == expected
rescue Errno::ENOENT, Errno::EACCES, Psych::Exception => error
  errors << "cannot verify Phase 4 spec-gate caller: #{error.message}"
end

def validate_trusted_kit(
  manifest, target, trusted_root, source_mode, expected_commit, expected_digest, errors
)
  unless expected_commit.to_s.match?(/\A[0-9a-f]{40}\z/)
    errors << "trusted kit commit must be a full lowercase Git SHA"
    return
  end
  unless expected_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    errors << "trusted kit bundle digest must be a sha256-prefixed digest"
    return
  end

  unless TRUSTED_KIT_SOURCE_MODES.include?(source_mode)
    errors << "trusted kit source mode must be one of #{TRUSTED_KIT_SOURCE_MODES.join(', ')}"
    return
  end

  if source_mode == "git"
    root = File.realpath(trusted_root)
    head, detail, ok = git_value(root, "rev-parse", "HEAD^{commit}")
    unless ok && head == expected_commit
      errors << "trusted kit checkout does not match expected commit: #{detail.empty? ? head : detail}"
      return
    end
    actual_digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest(root, expected_commit)}"
  else
    root = WorkflowKit::Release::ReleaseDigest.strict_filesystem_root(trusted_root)
    actual_digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest_from_filesystem(root)}"
  end
  errors << "trusted kit source does not match expected bundle digest" unless actual_digest == expected_digest
  errors << "installation lock does not match trusted kit bundle digest" unless manifest["kit_bundle_digest"] == expected_digest

  trusted_version = File.read(File.join(root, "VERSION")).strip
  errors << "installation lock does not match trusted kit version" unless manifest["kit_version"] == trusted_version
  provenance_commit = manifest.dig("provenance", "release_commit")
  errors << "installation provenance does not match trusted kit commit" unless provenance_commit == expected_commit
  unless manifest["ownership_rules"] == WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES
    errors << "installation ownership rules do not match trusted kit policy"
  end
  unless manifest["protected_paths"] == WorkflowKit::Release::ReleaseManifest::PROTECTED_PATHS
    errors << "installation protected paths do not match trusted kit policy"
  end
  unless manifest["approval_required_paths"] == WorkflowKit::Release::ReleaseManifest::APPROVAL_REQUIRED_PATHS
    errors << "installation approval-required paths do not match trusted kit policy"
  end
  git_context = trusted_git_context(target, errors)

  template_root = File.join(root, "core", "project-template")
  template_paths = Dir.glob(File.join(template_root, "**", "*"), File::FNM_DOTMATCH).select do |path|
    ![".", ".."].include?(File.basename(path)) && File.file?(path) && !File.symlink?(path)
  end.map { |path| path.delete_prefix("#{template_root}/") }.sort
  entries = Array(manifest["installed_files"]).select { |entry| entry.is_a?(Hash) }
    .each_with_object({}) { |entry, result| result[entry["path"].to_s] = entry }
  transition = nil

  template_paths.each do |relative|
    entry = entries[relative]
    unless entry
      errors << "trusted kit template path is missing from installation lock: #{relative}"
      next
    end
    source = File.join(template_root, relative)
    expected_template_digest = Digest::SHA256.file(source).hexdigest
    expected_ownership = WorkflowKit::Install::Integrity.ownership_for(
      relative,
      WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES,
    )
    tokenized_project_template = expected_ownership == "project-owned" &&
      File.binread(source).match?(/\{\{[A-Z_]+\}\}/)
    reviewed_merge = false
    merge_content_differs = expected_ownership == "merge-owned" &&
      (entry["sha256"] != expected_template_digest ||
       entry["template_sha256"] != expected_template_digest)
    if !tokenized_project_template && merge_content_differs &&
        WorkflowKit::Install::Integrity.path_matches_any?(
          relative, WorkflowKit::Release::ReleaseManifest::APPROVAL_REQUIRED_PATHS,
        )
      transition ||= trusted_transition_context(target, manifest, git_context, errors)
      reviewed_merge = trusted_reviewed_merge?(
        entry, relative, target, transition, errors,
      )
    end
    trusted_template = entry["template_sha256"] == expected_template_digest &&
      (expected_ownership != "merge-owned" || entry["sha256"] == expected_template_digest)
    unless tokenized_project_template || trusted_template || reviewed_merge
      errors << "trusted kit template digest mismatch: #{relative}"
    end
    unless entry["ownership"] == expected_ownership
      errors << "trusted kit ownership mismatch: #{relative}"
    end
    expected_mode = format("%04o", File.stat(source).mode & 0o7777)
    unless entry["mode"].to_s == expected_mode
      errors << "trusted kit mode mismatch: #{relative}"
    end
    if expected_ownership == "kit-owned" && entry["sha256"] != expected_template_digest
      errors << "trusted kit-owned content mismatch: #{relative}"
    end
  end
  unexpected = entries.keys - template_paths
  unexpected.each do |relative|
    candidate = entries.fetch(relative)
    if candidate["state"].to_s == "legacy"
      transition ||= trusted_transition_context(target, manifest, git_context, errors)
    end
    next if trusted_legacy_relocation?(
      candidate, relative, entries, template_paths,
      WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES, target, transition,
    )

    errors << "installation lock contains a path outside the trusted template: #{relative}"
  end
  validate_phase4_caller(target, expected_commit, expected_digest, trusted_version, errors)
rescue Errno::ENOENT, Errno::EACCES, WorkflowKit::Release::ReleaseDigest::DigestError => error
  errors << "cannot verify trusted kit source: #{error.message}"
end

options = {
  target: nil,
  trusted_kit_root: nil,
  trusted_kit_source_mode: "git",
  trusted_kit_source_mode_explicit: false,
  expected_kit_commit: nil,
  expected_kit_bundle_digest: nil,
  execution_profile: "local",
}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: validate_install.rb [trusted kit options] [TARGET]"
  opts.on("--trusted-kit-root DIR") { |value| options[:trusted_kit_root] = value }
  opts.on(
    "--trusted-kit-source-mode MODE",
    "git (default) or action-source (downloaded archive tree)",
  ) do |value|
    options[:trusted_kit_source_mode] = value
    options[:trusted_kit_source_mode_explicit] = true
  end
  opts.on("--expected-kit-commit SHA") { |value| options[:expected_kit_commit] = value }
  opts.on("--expected-kit-bundle-digest DIGEST") { |value| options[:expected_kit_bundle_digest] = value }
  opts.on("--execution-profile PROFILE", EXECUTION_PROFILES) do |value|
    options[:execution_profile] = value
  end
end
parser.parse!(ARGV)
abort parser.to_s if ARGV.length > 1
options[:target] = ARGV.first || Dir.pwd
trusted_mode = !options[:trusted_kit_root].to_s.empty?
if trusted_mode && (options[:expected_kit_commit].to_s.empty? || options[:expected_kit_bundle_digest].to_s.empty?)
  abort "--trusted-kit-root requires --expected-kit-commit and --expected-kit-bundle-digest"
end
if !trusted_mode && (options[:expected_kit_commit] || options[:expected_kit_bundle_digest])
  abort "trusted kit identity options require --trusted-kit-root"
end
if !trusted_mode && options[:trusted_kit_source_mode_explicit]
  abort "--trusted-kit-source-mode requires --trusted-kit-root"
end
unless TRUSTED_KIT_SOURCE_MODES.include?(options[:trusted_kit_source_mode])
  abort "--trusted-kit-source-mode must be one of #{TRUSTED_KIT_SOURCE_MODES.join(', ')}"
end
unless EXECUTION_PROFILES.include?(options[:execution_profile])
  abort "--execution-profile must be one of #{EXECUTION_PROFILES.join(', ')}"
end
if options[:execution_profile] == "hosted-no-project-code" && !trusted_mode
  abort "--execution-profile hosted-no-project-code requires --trusted-kit-root"
end

requested_target = options[:target]
begin
  target = File.realpath(requested_target)
rescue Errno::ENOENT, Errno::EACCES => error
  abort "Target directory cannot be resolved: #{requested_target} (#{error.message})"
end
abort "Target is not a directory: #{target}" unless Dir.exist?(target)

errors = []
project_drift = []
portability_notices = []
git_info = current_git_info(target, errors)
manifest_path = File.join(target, INSTALLATION_MANIFEST)
manifest = load_manifest(manifest_path, errors)

if manifest
  schema_version = manifest["schema_version"]
  unless SUPPORTED_MANIFEST_SCHEMA_VERSIONS.include?(schema_version)
    errors << "schema_version must be one of #{SUPPORTED_MANIFEST_SCHEMA_VERSIONS.join(', ')}"
  end

  manifest_version = manifest["kit_version"].to_s
  errors << "kit_version must be a non-empty string" if manifest_version.empty?
  if schema_version != MANIFEST_SCHEMA_VERSION && !manifest_version.empty? && manifest_version != kit_version
    errors << "Installed kit_version #{manifest_version.inspect} does not match validator version #{kit_version.inspect}; run bootstrap migration first"
  end

  if schema_version == MANIFEST_SCHEMA_VERSION
    begin
      schema_path = File.join(KIT_ROOT, "schemas", "kit-installation.schema.yaml")
      schema = WorkflowKit::Schema.load_yaml(schema_path)
      WorkflowKit::Schema.validate(manifest, schema).each do |error|
        errors << "Installation manifest schema violation: #{error}"
      end
    rescue ArgumentError, SystemCallError => error
      errors << "Cannot validate installation manifest schema: #{error.message}"
    end

    installation_state = manifest["installation_state"].to_s
    errors << "installation_state must be managed or legacy" unless %w[managed legacy].include?(installation_state)

    bundle_digest = manifest["kit_bundle_digest"]
    release_manifest_digest = manifest["release_manifest_digest"]
    if installation_state == "managed"
      errors << "kit_bundle_digest must be a sha256-prefixed digest for a managed install" unless bundle_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      errors << "release_manifest_digest must be a sha256-prefixed digest for a managed install" unless release_manifest_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
    elsif !bundle_digest.nil? && !bundle_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      errors << "kit_bundle_digest must be null or a sha256-prefixed digest"
    end
    errors << "bundle_digest_algo must be #{WorkflowKit::Release::ReleaseDigest::BUNDLE_DIGEST_ALGO}" unless manifest["bundle_digest_algo"] == WorkflowKit::Release::ReleaseDigest::BUNDLE_DIGEST_ALGO
    errors << "rendered_digest_algo must be #{WorkflowKit::Install::Integrity::RENDERED_DIGEST_ALGO}" unless manifest["rendered_digest_algo"] == WorkflowKit::Install::Integrity::RENDERED_DIGEST_ALGO
    errors << "dirty_snapshot_algo must be #{WorkflowKit::Install::Integrity::DIRTY_SNAPSHOT_ALGO}" unless manifest["dirty_snapshot_algo"] == WorkflowKit::Install::Integrity::DIRTY_SNAPSHOT_ALGO
    rendered_digest = manifest["rendered_install_digest"].to_s
    errors << "rendered_install_digest must be a sha256-prefixed digest" unless rendered_digest.match?(/\Asha256:[0-9a-f]{64}\z/)
    unless manifest["rendered_digest_excluded_fields"] == %w[installed_at updated_at workspace_root]
      errors << "rendered_digest_excluded_fields must exclude installed_at, updated_at, and workspace_root"
    end
    source = manifest["source"]
    if !source.is_a?(Hash)
      errors << "source must be a mapping"
    elsif installation_state == "managed"
      errors << "managed installs require source.kind local or github-release" unless %w[local github-release].include?(source["kind"].to_s)
      errors << "managed installs require source.manifest_locator" if source["manifest_locator"].to_s.empty?
      unless source["bundle_archive_sha256"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        errors << "managed installs require source.bundle_archive_sha256 as a sha256-prefixed digest"
      end
    end
    errors << "provenance must be a mapping" unless manifest["provenance"].is_a?(Hash)

    project_id = manifest["project_id"].to_s
    unless project_id.empty?
      expected_fingerprint, = WorkflowKit::Install::Integrity.repository_fingerprint(target, project_id)
      unless manifest["repository_fingerprint"] == expected_fingerprint
        errors << "repository_fingerprint does not match the current repository identity"
      end
    end
  end

  %w[installed_at updated_at].each do |key|
    errors << "#{key} must be an ISO 8601 timestamp" unless valid_iso8601?(manifest[key])
  end

  workspace_root = manifest["workspace_root"].to_s
  if workspace_root.empty?
    errors << "workspace_root is required"
  elsif workspace_root != "." && !Pathname.new(workspace_root).absolute?
    errors << "workspace_root must be . or an absolute installation-worktree hint"
  elsif workspace_root != "." && workspace_root != target
    portability_notices << "workspace_root names the installation worktree, not this checkout: #{workspace_root}"
  end

  manifest_git = manifest["git"]
  if !manifest_git.is_a?(Hash)
    errors << "git must be a mapping"
  elsif git_info
    top_level = manifest_git["top_level"].to_s
    if top_level.empty?
      errors << "git.top_level is required"
    elsif top_level != "." && !Pathname.new(top_level).absolute?
      errors << "git.top_level must be . or an absolute installation-worktree hint"
    end
    errors << "git.git_dir_kind must be directory or file" unless %w[directory file].include?(manifest_git["git_dir_kind"].to_s)
    errors << "git.linked_worktree must be boolean" unless [true, false].include?(manifest_git["linked_worktree"])
    %w[top_level git_dir_kind linked_worktree].each do |key|
      next if manifest_git[key] == git_info[key]

      portability_notices << "git.#{key} records the installation worktree and differs in this checkout"
    end
  end

  installed_files = manifest["installed_files"]
  if !installed_files.is_a?(Array) || installed_files.empty?
    errors << "installed_files must be a non-empty array"
  else
    seen_paths = {}
    installed_files.each_with_index do |entry, index|
      label = "installed_files[#{index}]"
      unless entry.is_a?(Hash)
        errors << "#{label} must be a mapping"
        next
      end

      relative = entry["path"].to_s
      unless safe_relative_path?(relative)
        errors << "#{label}.path must be a normalized relative path: #{relative.inspect}"
        next
      end
      if seen_paths[relative]
        errors << "Duplicate installed_files path: #{relative}"
        next
      end
      seen_paths[relative] = true

      ownership = entry["ownership"].to_s
      unless %w[kit project legacy kit-owned merge-owned project-owned generated].include?(ownership)
        errors << "#{label}.ownership must use a supported ownership class"
      end

      destination = File.join(target, relative)
      if File.symlink?(destination)
        errors << "Managed file must not be a symbolic link: #{relative}"
        next
      end
      unless File.file?(destination)
        errors << "Missing managed file: #{relative}"
        next
      end

      digest = entry["sha256"].to_s
      actual_digest = nil
      if !digest.match?(/\A[0-9a-f]{64}\z/)
        errors << "#{label}.sha256 must be a lowercase SHA-256 digest"
      else
        actual_digest = Digest::SHA256.file(destination).hexdigest
        if digest != actual_digest
          if %w[project project-owned generated].include?(ownership)
            project_drift << relative
          else
            errors << "Digest mismatch for #{relative}: expected #{digest}, got #{actual_digest}"
          end
        end
      end

      template_digest = entry["template_sha256"].to_s
      if !template_digest.empty? && !template_digest.match?(/\A[0-9a-f]{64}\z/)
        errors << "#{label}.template_sha256 must be a lowercase SHA-256 digest"
      end

      baseline_digest = entry["baseline_sha256"].to_s
      if !baseline_digest.empty? && !baseline_digest.match?(/\A[0-9a-f]{64}\z/)
        errors << "#{label}.baseline_sha256 must be a lowercase SHA-256 digest"
      end
      if %w[project project-owned generated].include?(ownership) && actual_digest
        effective_baseline = baseline_digest.empty? ? digest : baseline_digest
        if effective_baseline.match?(/\A[0-9a-f]{64}\z/) && effective_baseline != actual_digest && !project_drift.include?(relative)
          project_drift << relative
        end
      end

      state = entry["state"].to_s
      unless state.empty? || %w[managed preserved legacy].include?(state)
        errors << "#{label}.state is invalid"
      end

      mode = entry["mode"].to_s
      if !mode.match?(/\A[0-7]{4}\z/)
        errors << "#{label}.mode must be a four-digit octal string"
      else
        actual_mode = format("%04o", File.stat(destination).mode & 0o7777)
        errors << "Mode mismatch for #{relative}: expected #{mode}, got #{actual_mode}" unless mode == actual_mode
      end

      begin
        resolved = File.realpath(destination)
        unless resolved.start_with?("#{target}/")
          errors << "Managed file resolves outside the Git top-level: #{relative} -> #{resolved}"
        end
      rescue Errno::ENOENT, Errno::EACCES => error
        errors << "Cannot resolve managed file #{relative}: #{error.message}"
      end
    end
  end

  history = manifest["migration_history"]
  if !history.is_a?(Array) || history.empty?
    errors << "migration_history must be a non-empty array"
  else
    history.each_with_index do |entry, index|
      label = "migration_history[#{index}]"
      unless entry.is_a?(Hash)
        errors << "#{label} must be a mapping"
        next
      end
      errors << "#{label}.at must be an ISO 8601 timestamp" unless valid_iso8601?(entry["at"])
      errors << "#{label}.action is invalid" unless %w[install upgrade repair refresh].include?(entry["action"].to_s)
      errors << "#{label}.to_schema_version must be an integer" unless entry["to_schema_version"].is_a?(Integer)
      errors << "#{label}.to_kit_version must be a non-empty string" if entry["to_kit_version"].to_s.empty?
    end

    last_entry = history.last
    if last_entry.is_a?(Hash)
      errors << "Latest migration does not bind to schema_version" unless last_entry["to_schema_version"] == schema_version
      errors << "Latest migration does not bind to kit_version" unless last_entry["to_kit_version"].to_s == manifest_version
    end
  end
end

if manifest && manifest["schema_version"] == MANIFEST_SCHEMA_VERSION && trusted_mode
  validate_trusted_kit(
    manifest,
    target,
    options[:trusted_kit_root],
    options[:trusted_kit_source_mode],
    options[:expected_kit_commit],
    options[:expected_kit_bundle_digest],
    errors,
  )
end

if manifest && manifest["schema_version"] == MANIFEST_SCHEMA_VERSION && !trusted_mode
  bootstrap = File.join(KIT_ROOT, "engine", "install", "bootstrap_project.rb")
  args = [RbConfig.ruby, bootstrap, "--dry-run", "--json"]
  source = manifest["source"].is_a?(Hash) ? manifest["source"] : {}
  args.concat(["--source-manifest", source["manifest_locator"]]) if source["manifest_locator"]
  args.concat(["--expected-kit-bundle-digest", manifest["kit_bundle_digest"]]) if manifest["kit_bundle_digest"]
  args.concat(["--expected-release-manifest-digest", manifest["release_manifest_digest"]]) if manifest["release_manifest_digest"]
  approval_patterns = Array(manifest["approval_required_paths"])
  Array(manifest["installed_files"]).each do |entry|
    next unless entry.is_a?(Hash) && entry["ownership"].to_s == "merge-owned"

    relative = entry["path"].to_s
    next unless approval_patterns.any? { |pattern| File.fnmatch?(pattern.to_s, relative, File::FNM_PATHNAME | File::FNM_DOTMATCH) }

    destination = File.join(target, relative)
    next unless File.file?(destination) && !File.symlink?(destination)

    args.concat(["--approve-path", "#{relative}=#{Digest::SHA256.file(destination).hexdigest}"])
    args.concat(["--merge-path", "#{relative}=#{destination}"])
  end
  args << target
  stdout, stderr, status = Open3.capture3(*args)
  begin
    current_plan = JSON.parse(stdout)
    if current_plan["error"] || current_plan["status"] == "blocked"
      errors << "Cannot verify current rendered installation/source: #{current_plan['error'] || stderr}"
    else
      expected_rendered = manifest["rendered_install_digest"]
      actual_rendered = current_plan.dig("source", "rendered_install_digest")
      errors << "rendered_install_digest does not match the current rendered source" unless expected_rendered == actual_rendered
      if manifest["kit_version"] != current_plan.dig("source", "kit_version")
        errors << "kit_version does not match the resolved source"
      end
      if manifest["kit_bundle_digest"] != current_plan.dig("source", "kit_bundle_digest")
        errors << "kit_bundle_digest does not match the resolved source"
      end
      if manifest["release_manifest_digest"] != current_plan.dig("source", "release_manifest_digest")
        errors << "release_manifest_digest does not match the resolved source"
      end
    end
  rescue JSON::ParserError
    errors << "Cannot verify current rendered installation/source: #{[stdout, stderr].reject(&:empty?).join("\n")}"
  end
end

project_map_path = File.join(target, ".ai", "canonical", "PROJECT_MAP.yaml")
if File.file?(project_map_path)
  begin
    project_map = YAML.safe_load(File.read(project_map_path), permitted_classes: [], permitted_symbols: [], aliases: false)
    root = project_map.is_a?(Hash) ? project_map.dig("workspace", "root").to_s : ""
    if root.empty?
      errors << "PROJECT_MAP workspace.root is required"
    elsif root != "." && !Pathname.new(root).absolute?
      errors << "PROJECT_MAP workspace.root must be . or an absolute canonical-workspace hint"
    elsif root != "." && root != target
      portability_notices << "PROJECT_MAP workspace.root names another checkout: #{root}"
    end
  rescue Psych::Exception => error
    errors << "Cannot parse PROJECT_MAP safely: #{error.message}"
  end
end

if options[:execution_profile] == "hosted-no-project-code"
  validate_hosted_structure(target, errors, portability_notices)
else
  structure_script = File.join(target, ".ai", "runtime", "scripts", "validate_agent_structure.rb")
  if !File.file?(structure_script)
    errors << "Workflow kit structure validator is missing: #{structure_script}"
  else
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, structure_script, chdir: target)
    unless status.success?
      detail = [stdout, stderr].reject(&:empty?).join("\n").strip
      errors << "Agent workflow structure validation failed#{detail.empty? ? '' : ":\n#{detail}"}"
    end
  end
end

if errors.empty?
  legacy_files = Array(manifest && manifest["installed_files"]).select do |entry|
    entry.is_a?(Hash) && (entry["ownership"].to_s == "legacy" || entry["state"].to_s == "legacy")
  end
  puts "OK: workflow kit #{manifest['kit_version']} installation is valid at #{target}."
  unless project_drift.empty?
    puts "NOTICE: #{project_drift.length} project-owned managed file(s) differ from their installation baseline:"
    project_drift.sort.each { |path| puts "- #{path}" }
  end
  unless legacy_files.empty?
    puts "NOTICE: #{legacy_files.length} legacy kit file(s) remain at their adopted baseline; run the upgrade planner before treating the installation as current:"
    legacy_files.sort_by { |entry| entry["path"].to_s }.each { |entry| puts "- #{entry['path']}" }
  end
  portability_notices.uniq.sort.each { |notice| puts "NOTICE: #{notice}" }
  exit 0
end

puts "ERROR: workflow kit installation is invalid."
errors.each { |error| puts "- #{error}" }
exit 1
