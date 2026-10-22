#!/usr/bin/env ruby

require "date"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "open3"
require "shellwords"
require "tempfile"
require "time"
require "yaml"

require_relative "../../installer/lib/install_integrity"
require_relative "../../installer/lib/release_source"

KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
INSTALLATION_MANIFEST = File.join(".ai", "KIT_INSTALLATION.yaml")
MANIFEST_SCHEMA_VERSION = 2
SUPPORTED_MANIFEST_SCHEMA_VERSIONS = [1, MANIFEST_SCHEMA_VERSION].freeze

class InstallError < StandardError; end

def capture_git(path, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", path, *args)
  [stdout.strip, stderr.strip, status.success?]
end

def resolve_git_path(root, value)
  candidate = value.start_with?(File::SEPARATOR) ? value : File.expand_path(value, root)
  File.realpath(candidate)
rescue Errno::ENOENT, Errno::EACCES => error
  raise InstallError, "Cannot resolve Git path #{candidate}: #{error.message}"
end

def git_repository_info(root)
  inside, error, ok = capture_git(root, "rev-parse", "--is-inside-work-tree")
  unless ok && inside == "true"
    detail = error.empty? ? "not a Git work tree" : error
    raise InstallError, "Target must be a Git work tree: #{root} (#{detail})"
  end

  top_level, error, ok = capture_git(root, "rev-parse", "--show-toplevel")
  raise InstallError, "Cannot determine Git top-level: #{error}" unless ok

  normalized_top_level = File.realpath(top_level)
  unless normalized_top_level == root
    raise InstallError, "Target must be the Git top-level. Target: #{root}; Git top-level: #{normalized_top_level}"
  end

  git_dir_value, error, ok = capture_git(root, "rev-parse", "--git-dir")
  raise InstallError, "Cannot determine Git directory: #{error}" unless ok

  common_dir_value, error, ok = capture_git(root, "rev-parse", "--git-common-dir")
  raise InstallError, "Cannot determine Git common directory: #{error}" unless ok

  git_dir = resolve_git_path(root, git_dir_value)
  common_dir = resolve_git_path(root, common_dir_value)
  dot_git = File.join(root, ".git")

  {
    "top_level" => normalized_top_level,
    "git_dir_kind" => File.file?(dot_git) ? "file" : "directory",
    "linked_worktree" => git_dir != common_dir,
  }
end

def git_branch(path)
  branch, = capture_git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
  return branch unless branch.empty?

  branch, = capture_git(path, "rev-parse", "--abbrev-ref", "HEAD")
  branch.empty? || branch == "HEAD" ? "main" : branch
end

def file?(root, path)
  File.file?(File.join(root, path))
end

def dir?(root, path)
  Dir.exist?(File.join(root, path))
end

def detect_services(root)
  services = {}

  if dir?(root, "apps/web")
    services["frontend"] = {
      "path" => "apps/web",
      "role" => "frontend",
      "stack" => file?(root, "apps/web/package.json") ? "node" : "unknown",
    }
  elsif file?(root, "package.json")
    services["app"] = { "path" => ".", "role" => "app", "stack" => "node" }
  end

  if dir?(root, "apps/api")
    stack = if file?(root, "apps/api/pyproject.toml") || file?(root, "apps/api/requirements.txt")
      "python"
    elsif file?(root, "apps/api/package.json")
      "node"
    else
      "unknown"
    end
    services["backend"] = { "path" => "apps/api", "role" => "backend", "stack" => stack }
  elsif file?(root, "pyproject.toml") || file?(root, "requirements.txt")
    services["backend"] ||= { "path" => ".", "role" => "backend", "stack" => "python" }
  end

  services
end

def workspace_mode(root)
  return "monorepo" if dir?(root, "apps") || file?(root, "turbo.json") || file?(root, "pnpm-workspace.yaml")

  "single-repo"
end

def render_services_yaml(services)
  return "{}" if services.empty?

  yaml = YAML.dump(services).sub(/\A---\s*\n/, "")
  "\n" + yaml.lines.map { |line| "  #{line}" }.join.rstrip
end

def normalized_yaml(value)
  YAML.dump(value).gsub(/[ \t]+(?=\n|\z)/, "")
end

def render_project_map(source, values, services)
  rendered = source.dup
  values.each do |token, value|
    # JSON string literals are valid YAML scalars and safely preserve quotes,
    # whitespace, and non-ASCII project names and paths.
    rendered.gsub!("'#{token}'", JSON.generate(value.to_s))
  end
  rendered.gsub!("{{SERVICES_YAML}}", render_services_yaml(services))

  unresolved = rendered.scan(/\{\{[A-Z_]+\}\}/).uniq
  raise InstallError, "Unresolved PROJECT_MAP token(s): #{unresolved.join(', ')}" unless unresolved.empty?

  data = YAML.safe_load(rendered, permitted_classes: [], permitted_symbols: [], aliases: false)
  raise InstallError, "PROJECT_MAP template must contain a YAML mapping" unless data.is_a?(Hash)

  normalized_yaml(data)
rescue Psych::Exception => error
  raise InstallError, "Cannot render PROJECT_MAP.yaml safely: #{error.message}"
end

def render_template(source_path, relative_path, tokens, services)
  content = File.binread(source_path)
  if relative_path == File.join(".ai", "canonical", "PROJECT_MAP.yaml")
    return render_project_map(content, tokens, services)
  end

  tokens.reduce(content) { |memo, (key, value)| memo.gsub(key, value.to_s) }
end

def template_files(template_root)
  Dir.glob(File.join(template_root, "**", "*"), File::FNM_DOTMATCH).sort.select do |path|
    ![".", ".."].include?(File.basename(path)) && File.file?(path)
  end
end

def kit_version(source_root = KIT_ROOT)
  version_path = File.join(source_root, "VERSION")
  return "development" unless File.file?(version_path)

  value = File.read(version_path).strip
  value.empty? ? "development" : value
end

def sha256(content)
  Digest::SHA256.hexdigest(content)
end

def file_sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def safe_load_manifest(path)
  return {} unless File.file?(path)

  data = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  raise InstallError, "Existing installation manifest must contain a YAML mapping: #{path}" unless data.is_a?(Hash)

  data
rescue Psych::Exception => error
  raise InstallError, "Cannot parse existing installation manifest #{path}: #{error.message}"
end

def workflow_activity(root)
  active_streams = []
  state_paths = [
    File.join(root, ".ai", "local", "ACTIVE_CONTEXT.yaml"),
    File.join(root, ".ai", "ACTIVE_CONTEXT.yaml"),
  ]
  state_paths.each do |path|
    next unless File.file?(path)

    data = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
    next unless data.is_a?(Hash)

    Array(data["active_streams"]).each do |stream|
      active_streams << (stream.is_a?(Hash) ? "#{stream['feature_id']}/#{stream['stream_id']}" : stream.to_s)
    end
  rescue Psych::Exception => error
    raise InstallError, "Cannot inspect workflow activity safely at #{path}: #{error.message}"
  end

  lock_paths = Dir.glob(File.join(root, ".ai", "local", "locks", "*.lock"))
  lock_paths.concat(Dir.glob(File.join(root, ".ai", "tasks", "**", "LOCK.yaml")))
  {
    active_streams: active_streams.reject(&:empty?).uniq,
    lock_paths: lock_paths.select { |path| File.file?(path) }.map { |path| path.delete_prefix("#{root}/") }.uniq.sort,
  }
end

def previous_digests(manifest)
  Array(manifest["installed_files"]).each_with_object({}) do |entry, result|
    next unless entry.is_a?(Hash)

    path = entry["path"].to_s
    digest = entry["sha256"].to_s
    result[path] = digest if !path.empty? && digest.match?(/\A[0-9a-f]{64}\z/)
  end
end

def previous_entry(manifest, relative)
  Array(manifest["installed_files"]).find do |entry|
    entry.is_a?(Hash) && entry["path"].to_s == relative
  end || {}
end

def assert_destination_within_root!(root, destination)
  relative = destination.delete_prefix("#{root}/")
  if relative == destination || relative.split(File::SEPARATOR).include?("..")
    raise InstallError, "Installation destination escapes the Git top-level: #{destination}"
  end

  current = destination
  current = File.dirname(current) until File.exist?(current) || File.symlink?(current)
  resolved = File.realpath(current)
  return if resolved == root || resolved.start_with?("#{root}/")

  raise InstallError, "Installation destination resolves outside the Git top-level: #{destination} -> #{resolved}"
rescue Errno::ENOENT, Errno::EACCES => error
  raise InstallError, "Cannot validate installation destination #{destination}: #{error.message}"
end

def atomic_write(path, content, mode)
  FileUtils.mkdir_p(File.dirname(path))
  Tempfile.create([".workflow-kit-install-", ".tmp"], File.dirname(path)) do |temporary|
    temporary.binmode
    temporary.write(content)
    temporary.flush
    temporary.fsync
    File.chmod(mode, temporary.path)
    File.rename(temporary.path, path)
  end
end

def copy_with_mode(source, destination)
  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(source, destination, preserve: true)
end

def action_for(previous_manifest, plans, force, target_kit_version)
  return "install" if previous_manifest.empty?
  return "upgrade" if previous_manifest["kit_version"].to_s != target_kit_version || previous_manifest["schema_version"].to_i != MANIFEST_SCHEMA_VERSION
  return "repair" if force && plans.any? { |plan| plan[:status] == :replace }

  "refresh"
end

def normalized_action(status)
  case status
  when :create then "create"
  when :update, :replace then "update"
  when :delete then "delete"
  when :conflict then "conflict"
  else "skip"
  end
end

def previous_expected_digest(entry)
  %w[template_sha256 baseline_sha256 sha256].each do |key|
    value = entry[key].to_s
    return value if value.match?(/\A[0-9a-f]{64}\z/)
  end
  nil
end

def normalized_project_id(previous_manifest, project_name)
  existing = previous_manifest["project_id"].to_s
  return existing unless existing.empty?

  normalized = project_name.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
  normalized = normalized.sub(/\A[^A-Za-z0-9]+/, "").sub(/[^A-Za-z0-9]+\z/, "")
  normalized.empty? ? "project" : normalized
end

def plan_expected_digest(entry)
  value = entry["template_sha256"].to_s
  value.match?(/\A[0-9a-f]{64}\z/) ? value : nil
end

def approved_for_plan?(approvals, relative, current_digest, desired_digest, previous_entry)
  approved = approvals[relative]
  return false unless approved

  expected = current_digest || previous_expected_digest(previous_entry) || desired_digest
  unless expected && approved == expected
    raise InstallError, "--approve-path digest for #{relative} does not match the reviewed current/expected content"
  end
  true
end

def plan_payload(target_root, plans, dry_run, force, previous_manifest, activity, source_context, target_context, approvals, merge_overrides)
  rendered_digest = WorkflowKit::Install::Integrity.rendered_install_digest(plans.reject { |plan| plan[:digest].nil? })
  source = {
    "kind" => source_context.fetch("kind"),
    "kit_version" => source_context.fetch("kit_version"),
    "kit_bundle_digest" => source_context["kit_bundle_digest"],
    "bundle_digest_algo" => source_context.fetch("bundle_digest_algo"),
    "rendered_digest_algo" => source_context.fetch("rendered_digest_algo"),
    "dirty_snapshot_algo" => source_context.fetch("dirty_snapshot_algo"),
    "rendered_install_digest" => rendered_digest,
    "pinnable" => source_context.fetch("pinnable"),
    "release_manifest_digest" => source_context["release_manifest_digest"],
    "locator" => source_context.dig("source", "locator"),
    "manifest_locator" => source_context.dig("source", "manifest_locator"),
  }
  files = plans.sort_by { |plan| plan[:relative] }.map do |plan|
    {
      "path" => plan[:relative],
      "ownership" => plan[:ownership],
      "current_digest" => plan[:current_digest],
      "expected_digest" => plan[:expected_digest],
      "desired_digest" => plan[:digest],
      "action" => normalized_action(plan[:status]),
      "reason" => plan[:reason],
      "mode" => plan[:mode] && format("%04o", plan[:mode]),
    }
  end
  approval_entries = approvals.keys.sort.map do |path|
    { "path" => path, "expected_digest" => approvals.fetch(path), "actor" => ENV.fetch("USER", "unknown") }
  end
  approval_required = approval_entries.select do |entry|
    WorkflowKit::Install::Integrity.path_matches_any?(entry.fetch("path"), source_context.fetch("approval_required_paths"))
  end
  protected = approval_entries - approval_required
  payload = {
    "target_path" => target_root,
    "source" => source,
    "target" => target_context,
    "manifest" => {
      "present" => !previous_manifest.empty?,
      "schema_version" => previous_manifest["schema_version"],
      "kit_version" => previous_manifest["kit_version"],
      "state" => previous_manifest["installation_state"] || (previous_manifest.empty? ? "legacy_unknown" : "managed"),
    },
    "mode" => force ? "replace_kit_owned" : "safe",
    "dry_run" => dry_run,
    "activity" => {
      "active_streams" => Array(activity[:active_streams]).sort,
      "lock_paths" => Array(activity[:lock_paths]).sort,
    },
    "counts" => files.group_by { |entry| entry.fetch("action") }.transform_values(&:length),
    "approvals" => {
      "protected_path_approvals" => protected,
      "approval_required_path_approvals" => approval_required,
      "merge_content_approvals" => merge_overrides.keys.sort.map do |path|
        { "path" => path, "desired_digest" => sha256(merge_overrides.fetch(path)) }
      end,
    },
    "files" => files,
    "plans" => files,
    "digest_excluded_fields" => WorkflowKit::Install::Integrity::DIGEST_EXCLUDED_FIELDS,
  }
  payload["plan_digest"] = WorkflowKit::Install::Integrity.plan_digest(payload)
  payload
end

def print_plan(payload, json)
  if json
    puts JSON.generate(payload)
    return
  end

  puts "#{payload['dry_run'] ? 'Dry-run' : 'Installation'} plan for #{payload['target_path']}"
  puts "Mode: #{payload['mode']}"
  puts "Plan digest: #{payload['plan_digest']}"
  payload.fetch("files").group_by { |entry| entry.fetch("action") }.sort.each do |action, entries|
    puts "#{action.upcase} (#{entries.length})"
    entries.each { |entry| puts "- #{entry['path']} [#{entry['reason']}]" }
  end
end

options = {
  force: false,
  dry_run: false,
  json: false,
  approve_paths: [],
  merge_paths: [],
  plan_digest: nil,
  source_manifest: nil,
  expected_bundle_digest: nil,
  expected_manifest_digest: nil,
}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: bootstrap_project.rb [options] /path/to/git-top-level"
  opts.on("--dry-run", "Preview the normalized plan without writing") { options[:dry_run] = true }
  opts.on("--json", "Print the plan as machine-readable JSON") { options[:json] = true }
  opts.on("--force", "Back up and replace reviewed kit-owned conflicts") { options[:force] = true }
  opts.on("--plan-digest DIGEST", "Apply only when the recomputed plan has this digest") { |value| options[:plan_digest] = value }
  opts.on("--approve-path PATH=EXPECTED_SHA256", "Approve one reviewed path at its exact expected digest") { |value| options[:approve_paths] << value }
  opts.on("--merge-path PATH=FILE", "Use reviewed merged content for one approval-required merge-owned path") { |value| options[:merge_paths] << value }
  opts.on("--source-manifest PATH", "Use this reviewed release sidecar manifest") { |value| options[:source_manifest] = value }
  opts.on("--expected-kit-bundle-digest DIGEST", "Trust-root digest reviewed independently of the source manifest") { |value| options[:expected_bundle_digest] = value }
  opts.on("--expected-release-manifest-digest DIGEST", "Trust-root digest of the reviewed release sidecar bytes") { |value| options[:expected_manifest_digest] = value }
end
parser.parse!(ARGV)

target = ARGV.first
unless target && ARGV.length == 1
  warn parser
  exit 1
end

target_root = nil
begin
  target_root = File.realpath(target)
rescue Errno::ENOENT, Errno::EACCES => error
  warn "Target directory cannot be resolved: #{target} (#{error.message})"
  exit 1
end

unless Dir.exist?(target_root)
  warn "Target is not a directory: #{target_root}"
  exit 1
end

begin
  approvals = WorkflowKit::Install::Integrity.parse_approvals(options[:approve_paths])
  merge_overrides = options[:merge_paths].each_with_object({}) do |value, result|
    relative, source_path = value.to_s.split("=", 2)
    raise InstallError, "--merge-path must use PATH=FILE" if relative.to_s.empty? || source_path.to_s.empty?

    WorkflowKit::Install::Integrity.safe_relative_path!(relative)
    raise InstallError, "duplicate --merge-path for #{relative}" if result.key?(relative)
    raise InstallError, "--merge-path source must be a regular non-symlink file: #{source_path}" unless File.file?(source_path) && !File.symlink?(source_path)

    result[relative] = File.binread(source_path)
  end
  git_info = git_repository_info(target_root)
  project_name = File.basename(target_root)
  services = detect_services(target_root)
  tokens = {
    "{{PROJECT_ROOT}}" => target_root,
    "{{PROJECT_NAME}}" => project_name,
    "{{DATE}}" => Date.today.to_s,
    "{{DEFAULT_BRANCH}}" => git_branch(target_root),
    "{{WORKSPACE_MODE}}" => workspace_mode(target_root),
  }

  manifest_path = File.join(target_root, INSTALLATION_MANIFEST)
  assert_destination_within_root!(target_root, manifest_path)
  raise InstallError, "Installation manifest must not be a symbolic link: #{manifest_path}" if File.symlink?(manifest_path)
  previous_manifest = safe_load_manifest(manifest_path)
  previous_schema = previous_manifest["schema_version"]
  if !previous_manifest.empty? && !SUPPORTED_MANIFEST_SCHEMA_VERSIONS.include?(previous_schema)
    raise InstallError, "Installation manifest schema #{previous_schema.inspect} is not supported by this installer (supported: #{SUPPORTED_MANIFEST_SCHEMA_VERSIONS.join(', ')})"
  end
  managed_digests = previous_digests(previous_manifest)
  source_context = WorkflowKit::Install::ReleaseSource.resolve(
    kit_root: KIT_ROOT,
    previous_manifest: previous_manifest,
    manifest_locator: options[:source_manifest],
    expected_bundle_digest: options[:expected_bundle_digest],
    expected_manifest_digest: options[:expected_manifest_digest],
  )
  source_root = source_context.fetch("resolved_release_root")
  template_root = File.join(source_root, "core", "project-template")
  raise InstallError, "resolved release template root is missing: #{template_root}" unless Dir.exist?(template_root)
  resolved_version = kit_version(source_root)
  if source_context.fetch("kit_version") != resolved_version
    raise InstallError, "release manifest kit_version #{source_context.fetch('kit_version').inspect} does not match resolved release VERSION #{resolved_version.inspect}"
  end
  ownership_rules = source_context.fetch("ownership_rules")
  protected_paths = source_context.fetch("protected_paths")
  approval_required_paths = source_context.fetch("approval_required_paths")

  plans = template_files(template_root).map do |source|
    relative = source.delete_prefix("#{template_root}/")
    destination = File.join(target_root, relative)
    assert_destination_within_root!(target_root, destination)
    source_mode = File.stat(source).mode & 0o7777
    ownership = WorkflowKit::Install::Integrity.ownership_for(relative, ownership_rules)
    approval_required = WorkflowKit::Install::Integrity.path_matches_any?(relative, approval_required_paths)
    if merge_overrides.key?(relative) && !(ownership == "merge-owned" && approval_required)
      raise InstallError, "--merge-path is allowed only for approval-required merge-owned paths: #{relative}"
    end
    content = merge_overrides.fetch(relative) { render_template(source, relative, tokens, services) }
    desired_digest = sha256(content)
    entry = previous_entry(previous_manifest, relative)
    expected_digest = plan_expected_digest(entry)
    baseline_digest = entry["baseline_sha256"].to_s
    baseline_digest = entry["sha256"].to_s if baseline_digest.empty?
    legacy_entry = entry["state"].to_s == "legacy" || entry["ownership"].to_s == "legacy"
    current_digest = (!File.symlink?(destination) && File.file?(destination)) ? file_sha256(destination) : nil
    approved = approved_for_plan?(approvals, relative, current_digest, desired_digest, entry)

    if !File.exist?(destination) && !File.symlink?(destination)
      if !entry.empty? && (ownership == "project-owned" || approval_required) && !approved
        status = :conflict
        reason = ownership == "project-owned" ? "project_owned_missing" : "approval_required_missing"
      else
        status = :create
        reason = ownership == "generated" ? "missing_generated_scaffold" : "missing"
      end
    elsif !File.file?(destination) || File.symlink?(destination)
      status = :conflict
      reason = "non_regular_destination"
    else
      current_mode = File.stat(destination).mode & 0o7777
      if current_digest == desired_digest
        if current_mode == source_mode
          status = :unchanged
          reason = "matches_template"
        elsif ownership == "generated" || (ownership == "project-owned" && !approved)
          status = :preserve
          reason = "owned_mode_drift"
        elsif approval_required && !approved
          status = :conflict
          reason = "approval_required_mode_drift"
        else
          status = :update
          reason = "mode_mismatch"
        end
      elsif ownership == "generated"
        status = :preserve
        reason = "generated_by_project"
      elsif ownership == "project-owned"
        status = approved ? :replace : :preserve
        reason = approved ? "approved_project_owned_replacement" : "project_owned_drift"
      elsif approval_required
        status = approved ? :replace : :conflict
        reason = approved ? "approved_merge" : "approval_required"
      elsif managed_digests[relative] == current_digest || baseline_digest == current_digest
        status = :update
        reason = "managed_unmodified"
      elsif legacy_entry && options[:force]
        status = :replace
        reason = "legacy_kit_replacement"
      elsif options[:force]
        status = :replace
        reason = "forced_kit_owned_conflict"
      else
        status = :conflict
        reason = "existing_content_differs"
      end
    end

    {
      source: source,
      relative: relative,
      destination: destination,
      content: content,
      digest: desired_digest,
      expected_digest: expected_digest,
      mode: source_mode,
      ownership: ownership,
      current_digest: current_digest,
      approved: approved,
      protected: WorkflowKit::Install::Integrity.path_matches_any?(relative, protected_paths),
      approval_required: approval_required,
      status: status,
      reason: reason,
    }
  end

  template_paths = plans.map { |plan| plan[:relative] }
  Array(previous_manifest["installed_files"]).each do |entry|
    next unless entry.is_a?(Hash)
    relative = entry["path"].to_s
    next if relative.empty? || template_paths.include?(relative)

    WorkflowKit::Install::Integrity.safe_relative_path!(relative)
    destination = File.join(target_root, relative)
    assert_destination_within_root!(target_root, destination)
    current_digest = (!File.symlink?(destination) && File.file?(destination)) ? file_sha256(destination) : nil
    expected_digest = plan_expected_digest(entry)
    ownership = WorkflowKit::Install::Integrity.normalize_previous_ownership(entry["ownership"], relative, ownership_rules)
    protected = WorkflowKit::Install::Integrity.path_matches_any?(relative, protected_paths)
    approval_required = WorkflowKit::Install::Integrity.path_matches_any?(relative, approval_required_paths)
    approved = approved_for_plan?(approvals, relative, current_digest, nil, entry)
    tombstone = Array(source_context["tombstones"]).find { |value| value.is_a?(Hash) && value["path"].to_s == relative }
    relocated_to = WorkflowKit::Install::Integrity.legacy_relocation_target(relative)
    legacy_relocated = relocated_to && template_paths.include?(relocated_to)

    if File.symlink?(destination) || (File.exist?(destination) && !File.file?(destination))
      status = :conflict
      reason = "non_regular_destination"
    elsif current_digest.nil?
      status = :unchanged
      reason = "removed_before_upgrade"
    elsif legacy_relocated
      status = :preserve
      reason = "legacy_relocated_path_preserved"
    elsif ownership == "project-owned" || ownership == "generated" || protected
      status = :preserve
      reason = "deletion_protected"
    elsif tombstone.nil?
      status = :conflict
      reason = "missing_tombstone"
    elsif WorkflowKit::Install::Integrity.digest_hex(tombstone["expected_digest"], "tombstone expected_digest") != current_digest
      status = :conflict
      reason = "tombstone_digest_mismatch"
    elsif !approved
      status = :conflict
      reason = "tombstone_approval_required"
    else
      status = :delete
      reason = "approved_tombstone"
    end

    plans << {
      source: nil,
      relative: relative,
      destination: destination,
      content: nil,
      digest: nil,
      expected_digest: expected_digest,
      mode: File.file?(destination) ? File.stat(destination).mode & 0o7777 : entry["mode"].to_s.to_i(8),
      ownership: ownership,
      current_digest: current_digest,
      approved: approved,
      protected: protected,
      approval_required: approval_required,
      status: status,
      reason: reason,
    }
  end

  unknown_approvals = approvals.keys - plans.map { |plan| plan[:relative] }
  raise InstallError, "--approve-path names a path outside this plan: #{unknown_approvals.join(', ')}" unless unknown_approvals.empty?
  unknown_merges = merge_overrides.keys - plans.map { |plan| plan[:relative] }
  raise InstallError, "--merge-path names a path outside this plan: #{unknown_merges.join(', ')}" unless unknown_merges.empty?

  activity = workflow_activity(target_root)
  project_id = normalized_project_id(previous_manifest, project_name)
  dirty_snapshot_paths = plans.map { |plan| plan[:relative] }.uniq.sort
  target_binding = WorkflowKit::Install::Integrity.target_context(
    target_root,
    manifest_path,
    project_id: project_id,
    scope_paths: dirty_snapshot_paths,
    scope_globs: WorkflowKit::Install::Integrity::HARNESS_DIRTY_SNAPSHOT_SCOPE,
    scope_mode: "plan_targets_plus_harness_allowlist",
  )
  payload = plan_payload(
    target_root,
    plans,
    options[:dry_run],
    options[:force],
    previous_manifest,
    activity,
    source_context,
    target_binding,
    approvals,
    merge_overrides,
  )

  if options[:plan_digest]
    supplied = WorkflowKit::Install::Integrity.digest_label(options[:plan_digest], "plan digest")
    unless supplied == payload.fetch("plan_digest")
      raise InstallError, "plan digest mismatch; source or target changed after review (expected #{supplied}, recomputed #{payload.fetch('plan_digest')})"
    end
  elsif !options[:dry_run]
    raise InstallError, "apply requires --plan-digest from a reviewed dry-run plan"
  end

  print_plan(payload, options[:json]) if options[:dry_run] || !options[:json]
  unless activity[:active_streams].empty? && activity[:lock_paths].empty?
    details = []
    details << "active streams: #{activity[:active_streams].join(', ')}" unless activity[:active_streams].empty?
    details << "stream locks: #{activity[:lock_paths].join(', ')}" unless activity[:lock_paths].empty?
    if options[:dry_run]
      warn "WARNING: an actual migration is blocked while workflow activity exists (#{details.join('; ')})."
    else
      puts JSON.generate({ "status" => "blocked", "target" => target_root, "plan" => payload, "error" => "active workflow streams or locks remain" }) if options[:json]
      raise InstallError, "Migration is blocked while workflow activity exists (#{details.join('; ')})"
    end
  end

  conflicts = plans.select { |plan| plan[:status] == :conflict }
  unless conflicts.empty?
    warn "Installation stopped: #{conflicts.length} unresolved file conflict(s)."
    warn "Resolve directory or symbolic-link conflicts explicitly; --force does not replace them." if conflicts.any? { |plan| plan[:reason] == "non_regular_destination" }
    warn "Use --approve-path PATH=EXPECTED_SHA256 only after reviewing protected or merge-owned content." if conflicts.any? { |plan| plan[:reason].include?("approval") || plan[:reason].include?("project_owned") }
    warn "Review differing kit-owned files; --force never replaces project-owned or approval-required paths." if conflicts.any? { |plan| plan[:reason] == "existing_content_differs" }
    puts JSON.generate({ "status" => "blocked", "target" => target_root, "plan" => payload, "error" => "unresolved file conflicts remain" }) if options[:json] && !options[:dry_run]
    exit 2
  end

  if options[:dry_run]
    puts "Dry-run complete. No files or Git configuration were changed." unless options[:json]
    exit 0
  end

  timestamp = Time.now.utc.iso8601
  backup_stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
  mutating_plans = plans.select { |plan| [:update, :replace, :delete].include?(plan[:status]) }
  backup_root = mutating_plans.empty? ? nil : File.join(target_root, ".ai", "local", "backups", "kit-installation-#{backup_stamp}-#{Process.pid}")
  assert_destination_within_root!(target_root, backup_root) if backup_root
  created_paths = []
  backed_up_paths = []

  begin
    mutating_plans.each do |plan|
      backup_path = File.join(backup_root, plan[:relative])
      copy_with_mode(plan[:destination], backup_path) if File.file?(plan[:destination])
      backed_up_paths << [plan[:destination], backup_path] if File.file?(backup_path)
    end

    plans.each do |plan|
      next if [:unchanged, :preserve].include?(plan[:status])
      if plan[:status] == :delete
        FileUtils.rm_f(plan[:destination])
      else
        created_paths << plan[:destination] if plan[:status] == :create
        atomic_write(plan[:destination], plan[:content], plan[:mode])
      end
    end

    FileUtils.mkdir_p(File.join(target_root, ".ai", "tasks"))
    history = Array(previous_manifest["migration_history"]).select { |entry| entry.is_a?(Hash) }
    migration = {
      "at" => timestamp,
      "action" => action_for(previous_manifest, plans, options[:force], source_context.fetch("kit_version")),
      "from_schema_version" => previous_manifest["schema_version"],
      "to_schema_version" => MANIFEST_SCHEMA_VERSION,
      "from_kit_version" => previous_manifest["kit_version"],
      "to_kit_version" => source_context.fetch("kit_version"),
      "plan_digest" => payload.fetch("plan_digest"),
    }
    reviewed_path_approvals = payload.fetch("approvals").values.flatten.each_with_object({}) do |entry, result|
      path = entry.fetch("path")
      record = result[path] ||= { "path" => path }
      record["expected_digest"] = entry["expected_digest"] if entry["expected_digest"]
      record["desired_digest"] = entry["desired_digest"] if entry["desired_digest"]
    end.values.sort_by { |entry| entry.fetch("path") }
    migration["reviewed_path_approvals"] = reviewed_path_approvals unless reviewed_path_approvals.empty?
    migration["backup_path"] = backup_root.delete_prefix("#{target_root}/") if backup_root
    history << migration

    installed_files = plans.reject { |plan| plan[:status] == :delete || (plan[:digest].nil? && plan[:current_digest].nil?) }.map do |plan|
      previous = previous_entry(previous_manifest, plan[:relative])
      actual_digest = File.file?(plan[:destination]) ? file_sha256(plan[:destination]) : plan[:digest]
      baseline_digest = if [:preserve, :unchanged].include?(plan[:status])
        previous["baseline_sha256"].to_s.empty? ? previous["sha256"].to_s : previous["baseline_sha256"].to_s
      else
        plan[:digest]
      end
      baseline_digest = plan[:digest] || actual_digest if baseline_digest.to_s.empty?
      template_file_digest = plan[:digest] || previous_expected_digest(previous) || actual_digest
      actual_mode = File.stat(plan[:destination]).mode & 0o7777
      preserved = plan[:status] == :preserve || (plan[:status] == :unchanged && plan[:digest] != actual_digest)
      legacy_relocated_to = if plan[:reason] == "legacy_relocated_path_preserved"
        WorkflowKit::Install::Integrity.legacy_relocation_target(plan[:relative])
      end
      installed_entry = {
        "path" => plan[:relative],
        "sha256" => actual_digest,
        "baseline_sha256" => baseline_digest,
        "template_sha256" => template_file_digest,
        "mode" => format("%04o", actual_mode),
        "ownership" => plan[:ownership],
        "state" => legacy_relocated_to ? "legacy" : (preserved ? "preserved" : "managed"),
      }
      installed_entry["relocated_to"] = legacy_relocated_to if legacy_relocated_to
      installed_entry
    end

    provenance = Marshal.load(Marshal.dump(source_context.fetch("provenance")))
    manifest = {
      "schema_version" => MANIFEST_SCHEMA_VERSION,
      "project_id" => project_id,
      "kit_version" => source_context.fetch("kit_version"),
      "bundle_digest_algo" => source_context.fetch("bundle_digest_algo"),
      "kit_bundle_digest" => source_context["kit_bundle_digest"],
      "release_manifest_digest" => source_context["release_manifest_digest"],
      "rendered_digest_algo" => source_context.fetch("rendered_digest_algo"),
      "rendered_install_digest" => payload.dig("source", "rendered_install_digest"),
      "rendered_digest_excluded_fields" => %w[installed_at updated_at workspace_root],
      "dirty_snapshot_algo" => source_context.fetch("dirty_snapshot_algo"),
      "repository_fingerprint" => target_binding.fetch("repository_fingerprint"),
      "profile" => previous_manifest["profile"] || "generic",
      "protected_paths" => source_context.fetch("protected_paths"),
      "ownership_rules" => source_context.fetch("ownership_rules"),
      "approval_required_paths" => source_context.fetch("approval_required_paths"),
      "source" => source_context.fetch("source"),
      "provenance" => provenance,
      "installation_state" => "managed",
      "installed_at" => previous_manifest["installed_at"] || timestamp,
      "updated_at" => timestamp,
      "workspace_root" => target_root,
      "git" => git_info,
      "installed_files" => installed_files,
      "migration_history" => history,
    }
    manifest_existed = File.exist?(manifest_path)
    manifest_backup = backup_root && File.join(backup_root, INSTALLATION_MANIFEST)
    if manifest_existed && manifest_backup
      copy_with_mode(manifest_path, manifest_backup)
      backed_up_paths << [manifest_path, manifest_backup]
    elsif !manifest_existed
      created_paths << manifest_path
    end
    atomic_write(manifest_path, normalized_yaml(manifest), 0o644)
  rescue StandardError => error
    rollback_errors = []
    created_paths.reverse_each do |path|
      FileUtils.rm_f(path)
    rescue StandardError => rollback_error
      rollback_errors << "remove #{path}: #{rollback_error.message}"
    end
    backed_up_paths.reverse_each do |destination, backup|
      copy_with_mode(backup, destination)
    rescue StandardError => rollback_error
      rollback_errors << "restore #{destination}: #{rollback_error.message}"
    end
    FileUtils.rm_rf(backup_root) if backup_root && rollback_errors.empty?

    message = "Installation failed and changes were rolled back: #{error.message}"
    message += "\nRollback also reported: #{rollback_errors.join('; ')}" unless rollback_errors.empty?
    raise InstallError, message
  end

  unless options[:json]
    puts "Installed AI Agentic Workflow Kit #{source_context.fetch('kit_version')} into #{target_root}"
    puts "Installation manifest: #{manifest_path}"
    puts "Backup: #{backup_root}" if backup_root
    puts "Next: ruby #{Shellwords.escape(File.join(KIT_ROOT, 'engine', 'validators', 'validate_install.rb'))} #{Shellwords.escape(target_root)}"
  else
    puts JSON.generate({
      "status" => "installed",
      "target" => target_root,
      "kit_version" => source_context.fetch("kit_version"),
      "manifest" => manifest_path,
      "backup" => backup_root,
      "plan" => payload,
    })
  end
rescue InstallError, WorkflowKit::Install::Integrity::IntegrityError, WorkflowKit::Install::ReleaseSource::SourceError => error
  puts JSON.generate({ "status" => "blocked", "target" => target_root, "error" => error.message }) if options[:json]
  warn "ERROR: #{error.message}"
  exit 1
rescue StandardError => error
  puts JSON.generate({ "status" => "blocked", "target" => target_root, "error" => "#{error.class}: #{error.message}" }) if options[:json]
  warn "ERROR: installation failed: #{error.class}: #{error.message}"
  exit 1
end
