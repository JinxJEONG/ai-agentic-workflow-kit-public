#!/usr/bin/env ruby

require "date"
require "fileutils"
require "open3"
require "securerandom"
require "time"
require "yaml"

module AgentWorkflow
  ROOT = File.expand_path("../../..", __dir__)
  AI_ROOT = File.join(ROOT, ".ai")
  CANONICAL_ROOT = File.join(AI_ROOT, "canonical")
  LOCAL_ROOT = File.join(AI_ROOT, "local")
  ACTIVE_CONTEXT_PATH = File.join(LOCAL_ROOT, "ACTIVE_CONTEXT.yaml")
  LEGACY_ACTIVE_CONTEXT_PATH = File.join(AI_ROOT, "ACTIVE_CONTEXT.yaml")
  LOCAL_LOCKS_ROOT = File.join(LOCAL_ROOT, "locks")
  LOCAL_STATE_LOCK_PATH = File.join(LOCAL_ROOT, ".workflow-state.lock")
  TASKS_ROOT = File.join(AI_ROOT, "tasks")
  PROJECT_MAP_PATH = File.join(CANONICAL_ROOT, "PROJECT_MAP.yaml")
  ENV_MATRIX_PATH = File.join(CANONICAL_ROOT, "ENV_MATRIX.yaml")
  PROJECT_RULES_PATH = File.join(CANONICAL_ROOT, "PROJECT_RULES.md")
  CONTEXT_MAP_PATH = File.join(CANONICAL_ROOT, "context-map.yaml")
  AGENT_PROFILES = %w[architect backend frontend reviewer pm ai-worker].freeze
  OWNER_AGENTS = %w[codex-app codex-cli kiro-cli kiro-ide human].freeze
  WORKFLOW_TIERS = %w[tier1 tier2 tier3].freeze
  STREAM_DOC_SCOPE_KEYS = %w[can_edit must_update must_review].freeze
  STREAM_SCOPE_KEYS = %w[read_scope write_scope state_write_scope shared_write_scope].freeze
  INSTALLATION_BOOTSTRAP_PATH_PATTERNS = [
    "AGENTS.md",
    ".ai/KIT_INSTALLATION.yaml",
    ".ai/canonical/**",
    ".ai/generated/**",
    ".ai/project/**",
    ".ai/runtime/**",
    ".ai/scripts/**",
    ".ai/templates/**",
    ".ai/local/.gitignore",
    ".githooks/**",
    ".github/workflows/agent-workflow-policy.yml",
  ].freeze
  LOCAL_STATE_SCHEMA_VERSION = 2

  module_function

  def safe_yaml_load(content)
    YAML.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
    )
  rescue ArgumentError
    # Psych 3, bundled with macOS Ruby 2.6, uses positional arguments.
    YAML.safe_load(content, [], [], false)
  end

  def load_yaml(path, default = {})
    return default unless File.exist?(path)

    safe_yaml_load(File.read(path)) || default
  rescue Psych::Exception => error
    raise "Cannot safely parse YAML #{path}: #{error.message}"
  end

  def atomic_write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    temporary_path = File.join(
      File.dirname(path),
      ".#{File.basename(path)}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}",
    )
    mode = File.exist?(path) ? File.stat(path).mode & 0o777 : 0o644

    File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
    File.rename(temporary_path, path)
  ensure
    FileUtils.rm_f(temporary_path) if temporary_path && File.exist?(temporary_path)
  end

  def write_yaml(path, data)
    atomic_write(path, data.to_yaml(line_width: -1))
  end

  def project_map
    load_yaml(PROJECT_MAP_PATH, {})
  end

  def default_active_context
    {
      "schema_version" => LOCAL_STATE_SCHEMA_VERSION,
      "last_updated" => Date.today.to_s,
      "status" => "idle",
      "active_streams" => [],
      "active_features" => [],
      "default_feature" => nil,
      "state_revision" => 0,
      "version" => LOCAL_STATE_SCHEMA_VERSION,
    }
  end

  def normalize_active_context(value)
    raise "Active context must be a YAML map" unless value.is_a?(Hash)

    context = value.dup
    defaults = default_active_context
    defaults.each { |key, default| context[key] = default unless context.key?(key) }
    raise "Active context active_streams must be an array" unless context["active_streams"].is_a?(Array)
    raise "Active context active_features must be an array" unless context["active_features"].is_a?(Array)

    context["state_revision"] = Integer(context["state_revision"] || 0)
    context
  rescue ArgumentError, TypeError
    raise "Active context state_revision must be an integer"
  end

  def active_context_unlocked
    source = if File.exist?(ACTIVE_CONTEXT_PATH)
      ACTIVE_CONTEXT_PATH
    elsif File.exist?(LEGACY_ACTIVE_CONTEXT_PATH)
      LEGACY_ACTIVE_CONTEXT_PATH
    end
    return default_active_context unless source

    value = load_yaml(source, nil)
    raise "#{source} must contain a YAML map" unless value.is_a?(Hash)

    normalize_active_context(value)
  end

  def with_local_state_lock(mode = File::LOCK_EX)
    FileUtils.mkdir_p(LOCAL_ROOT)
    File.open(LOCAL_STATE_LOCK_PATH, File::RDWR | File::CREAT, 0o644) do |lock|
      raise "Could not lock local workflow state: #{LOCAL_STATE_LOCK_PATH}" unless lock.flock(mode)

      begin
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end
  end

  def active_context
    with_local_state_lock(File::LOCK_SH) { active_context_unlocked }
  end

  def write_active_context_unlocked(context, expected_revision:)
    current = active_context_unlocked
    current_revision = Integer(current["state_revision"] || 0)
    unless current_revision == expected_revision
      raise "Active context changed concurrently (expected revision #{expected_revision}, found #{current_revision}); retry the operation"
    end

    context = normalize_active_context(context)
    context["schema_version"] = LOCAL_STATE_SCHEMA_VERSION
    context["version"] = LOCAL_STATE_SCHEMA_VERSION
    context["state_revision"] = current_revision + 1
    context["last_updated"] = Date.today.to_s
    context["status"] = context["active_streams"].empty? ? "idle" : "streams_in_progress"
    context["default_feature"] = context["active_features"].first && context["active_features"].first["feature_id"]
    write_yaml(ACTIVE_CONTEXT_PATH, context)
    context
  end

  def write_active_context(context)
    expected_revision = Integer(context["state_revision"] || 0)
    with_local_state_lock do
      write_active_context_unlocked(context, expected_revision: expected_revision)
    end
  end

  def update_active_context
    with_local_state_lock do
      context = active_context_unlocked
      expected_revision = Integer(context["state_revision"] || 0)
      result = yield(context)
      write_active_context_unlocked(context, expected_revision: expected_revision)
      result
    end
  end

  def workspace_name
    project_map.dig("workspace", "name").to_s.empty? ? File.basename(ROOT) : project_map.dig("workspace", "name").to_s
  end

  def relative_to_root(path)
    expanded = File.expand_path(path, ROOT)
    root = File.expand_path(ROOT)
    return "." if expanded == root
    return nil unless expanded.start_with?("#{root}/")

    expanded.delete_prefix("#{root}/")
  end

  def absolute_path(path)
    value = path.to_s
    return value if value.start_with?("/")

    File.expand_path(value, ROOT)
  end

  def realpath_with_missing_tail(path)
    expanded = File.expand_path(path)
    cursor = expanded
    tail = []

    until File.exist?(cursor) || File.dirname(cursor) == cursor
      tail.unshift(File.basename(cursor))
      cursor = File.dirname(cursor)
    end

    resolved = File.realpath(cursor)
    tail.empty? ? resolved : File.join(resolved, *tail)
  rescue SystemCallError
    expanded
  end

  def glob_pattern?(value)
    value.to_s.match?(/[\*?\[\{]/)
  end

  def normalize_scope_pattern(pattern)
    value = pattern.to_s.strip
    return nil if value.empty?

    expanded = File.expand_path(value, ROOT)
    components = expanded.split(File::SEPARATOR)
    glob_index = components.index { |component| glob_pattern?(component) }
    return realpath_with_missing_tail(expanded) unless glob_index

    fixed_components = components[0...glob_index]
    fixed_path = File::SEPARATOR + fixed_components.reject(&:empty?).join(File::SEPARATOR)
    fixed_path = File::SEPARATOR if fixed_path.empty?
    resolved_prefix = realpath_with_missing_tail(fixed_path)
    File.join(resolved_prefix, *components[glob_index..-1])
  end

  def path_glob_match?(relative_path, pattern)
    value = pattern.to_s
    return false if value.empty?

    normalized = relative_path.to_s.delete_prefix("./")
    glob = value.delete_prefix("./")
    return normalized == glob.delete_suffix("/") || normalized.start_with?("#{glob.delete_suffix("/")}/") if glob.end_with?("/")

    File.fnmatch?(glob, normalized, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
      File.fnmatch?(glob, normalized, File::FNM_DOTMATCH)
  end

  def protected_path?(relative_path)
    patterns = Array(project_map["protected_paths"])
    patterns.any? { |pattern| path_glob_match?(relative_path, pattern) }
  end

  def installation_bootstrap_path?(relative_path)
    INSTALLATION_BOOTSTRAP_PATH_PATTERNS.any? do |pattern|
      path_glob_match?(relative_path, pattern)
    end
  end

  def feature_id_from_task_folder(folder)
    File.basename(folder).split("--", 2).first
  end

  def feature_dirs
    Dir.glob(File.join(TASKS_ROOT, "FEATURE-*")).select do |path|
      File.exist?(File.join(path, "feature.yaml"))
    end.sort
  end

  def resolve_feature_dir(feature_id)
    exact = File.join(TASKS_ROOT, feature_id)
    return exact if File.exist?(File.join(exact, "feature.yaml"))

    matches = Dir.glob(File.join(TASKS_ROOT, "#{feature_id}--*")).select do |path|
      File.exist?(File.join(path, "feature.yaml"))
    end.sort
    matches.length == 1 ? matches.first : nil
  end

  def feature_path(feature_id)
    feature_dir = resolve_feature_dir(feature_id)
    feature_dir && File.join(feature_dir, "feature.yaml")
  end

  def load_feature(feature_id)
    path = feature_path(feature_id)
    raise "Missing feature #{feature_id}" unless path

    load_yaml(path, {})
  end

  def stream_manifest_path(feature_id, stream_id)
    feature_dir = resolve_feature_dir(feature_id)
    return nil unless feature_dir

    path = File.join(feature_dir, "streams", stream_id, "manifest.yaml")
    File.exist?(path) ? path : nil
  end

  def load_stream_manifest(feature_id, stream_id)
    path = stream_manifest_path(feature_id, stream_id)
    raise "Missing stream manifest for #{feature_id}/#{stream_id}" unless path

    manifest = load_yaml(path, {})
    manifest["_manifest_path"] = path
    manifest
  end

  def stream_dir(feature_id, stream_id)
    File.dirname(stream_manifest_path(feature_id, stream_id) || File.join(resolve_feature_dir(feature_id).to_s, "streams", stream_id, "manifest.yaml"))
  end

  def slugify(text)
    slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
    slug.empty? ? "feature" : slug
  end

  def next_feature_id
    today = Date.today.strftime("%Y%m%d")
    nums = feature_dirs.map { |dir| File.basename(dir)[/FEATURE-#{today}-(\d{3})/, 1].to_i }
    "FEATURE-#{today}-#{format('%03d', nums.max.to_i + 1)}"
  end

  def run_git(repo_path, *args)
    stdout, stderr, status = Open3.capture3("git", "-C", repo_path, *args)
    [stdout.chomp, stderr.chomp, status.success?]
  end

  def resolve_git_commit(ref, repo_root = ROOT)
    value = ref.to_s.strip
    return nil if value.empty?

    stdout, _stderr, ok = run_git(repo_root, "rev-parse", "--verify", "#{value}^{commit}")
    return nil unless ok && stdout.match?(/\A[0-9a-f]{40,64}\z/i)

    stdout
  end


  def current_git_head(repo_root = ROOT)
    resolve_git_commit("HEAD", repo_root)
  end

  def current_git_repo_root
    stdout, = Open3.capture3("git", "rev-parse", "--show-toplevel")
    value = stdout.strip
    value.empty? ? nil : value
  end

  def changed_files_for_repo(repo_root, staged:)
    cmd = staged ? %w[diff --cached --name-only --diff-filter=ACMR] : %w[diff --name-only --diff-filter=ACMR HEAD]
    stdout, stderr, ok = run_git(repo_root, *cmd)
    raise "#{repo_root}: failed to inspect changed files: #{stderr}" unless ok

    stdout.lines.map(&:chomp).reject(&:empty?).map { |path| File.expand_path(path, repo_root) }
  end

  def manifest_scope_version(manifest)
    Integer(manifest["scope_version"] || 1)
  rescue ArgumentError, TypeError
    1
  end

  def scope_sets(manifest)
    if manifest_scope_version(manifest) >= 2
      STREAM_SCOPE_KEYS.each_with_object({}) do |key, result|
        result[key] = Array(manifest[key]).map(&:to_s).reject(&:empty?).uniq
      end
    else
      doc_scope = manifest["doc_scope"].is_a?(Hash) ? manifest["doc_scope"] : {}
      legacy_writes = Array(manifest["write_scope"])
      STREAM_DOC_SCOPE_KEYS.each { |key| legacy_writes.concat(Array(doc_scope[key])) }
      {
        "read_scope" => [],
        "write_scope" => legacy_writes.map(&:to_s).reject(&:empty?).uniq,
        "state_write_scope" => [],
        "shared_write_scope" => [],
      }
    end
  end

  def effective_scopes(manifest)
    scopes = scope_sets(manifest)
    writable = %w[write_scope state_write_scope shared_write_scope].flat_map { |key| scopes[key] }
    (writable + editable_document_scopes(manifest)).uniq
  end

  def implementation_scopes(manifest)
    scope_sets(manifest)["write_scope"]
  end

  def editable_document_scopes(manifest)
    doc_scope = manifest["doc_scope"].is_a?(Hash) ? manifest["doc_scope"] : {}
    %w[can_edit must_update].flat_map { |key| Array(doc_scope[key]) }.map(&:to_s).reject(&:empty?).uniq
  end

  def activation_scopes(manifest)
    effective_scopes(manifest)
  end

  def parallel_allowed?(manifest)
    manifest["parallel_allowed"] == true
  end

  def scope_literal_prefix(pattern)
    normalized = normalize_scope_pattern(pattern)
    return nil unless normalized

    components = normalized.split(File::SEPARATOR)
    glob_index = components.index { |component| glob_pattern?(component) }
    literal_components = glob_index ? components[0...glob_index] : components
    prefix = File::SEPARATOR + literal_components.reject(&:empty?).join(File::SEPARATOR)
    prefix.empty? ? File::SEPARATOR : prefix
  end

  def path_ancestor_or_same?(left, right)
    left == right || right.start_with?("#{left.delete_suffix(File::SEPARATOR)}#{File::SEPARATOR}")
  end

  def scope_patterns_overlap?(left, right)
    normalized_left = normalize_scope_pattern(left)
    normalized_right = normalize_scope_pattern(right)
    return false unless normalized_left && normalized_right
    return true if normalized_left == normalized_right

    unless glob_pattern?(normalized_left) || glob_pattern?(normalized_right)
      return path_ancestor_or_same?(normalized_left, normalized_right) ||
        path_ancestor_or_same?(normalized_right, normalized_left)
    end

    left_prefix = scope_literal_prefix(normalized_left)
    right_prefix = scope_literal_prefix(normalized_right)
    return true if path_ancestor_or_same?(left_prefix, right_prefix)
    return true if path_ancestor_or_same?(right_prefix, left_prefix)

    false
  end

  def scope_overlap?(left, right)
    scope_patterns_overlap?(left, right)
  end

  def overlapping_scope_pair(left_scopes, right_scopes)
    Array(left_scopes).each do |left|
      Array(right_scopes).each do |right|
        return [left, right] if scope_patterns_overlap?(left, right)
      end
    end
    nil
  end

  def scopes_overlap?(left_scopes, right_scopes)
    !overlapping_scope_pair(left_scopes, right_scopes).nil?
  end

  def path_in_scope?(absolute_path_value, scope)
    normalized_path = realpath_with_missing_tail(absolute_path_value)
    normalized_scope = normalize_scope_pattern(scope)
    return false unless normalized_scope

    if glob_pattern?(normalized_scope)
      fixed_prefix = scope_literal_prefix(normalized_scope)
      return true if normalized_path == fixed_prefix

      flags = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB
      return File.fnmatch?(normalized_scope, normalized_path, flags) ||
        File.fnmatch?(normalized_scope, normalized_path, File::FNM_DOTMATCH | File::FNM_EXTGLOB)
    end

    path_ancestor_or_same?(normalized_scope, normalized_path)
  end

  def matching_active_streams(absolute_path_value, active_streams)
    active_streams.select do |entry|
      manifest = load_stream_manifest(entry["feature_id"].to_s, entry["stream_id"].to_s)
      effective_scopes(manifest).any? { |scope| path_in_scope?(absolute_path_value, scope) }
    rescue StandardError
      false
    end
  end

  def task_feature_id(relative_path)
    parts = relative_path.to_s.split("/")
    return nil unless parts[0] == ".ai" && parts[1] == "tasks" && parts[2]

    feature_id_from_task_folder(parts[2])
  end

  def local_state_token(value, label)
    token = value.to_s
    unless token.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
      raise "Invalid #{label} for local state path: #{value.inspect}"
    end

    token
  end

  def stream_lock_path(feature_id, stream_id)
    feature_token = local_state_token(feature_id, "feature_id")
    stream_token = local_state_token(stream_id, "stream_id")
    File.join(LOCAL_LOCKS_ROOT, "#{feature_token}--#{stream_token}.lock")
  end

  def legacy_stream_lock_path(feature_id, stream_id)
    manifest_path = stream_manifest_path(feature_id, stream_id)
    manifest_path && File.join(File.dirname(manifest_path), "LOCK.yaml")
  end

  def load_stream_lock(feature_id, stream_id)
    local_path = stream_lock_path(feature_id, stream_id)
    return [load_stream_lock_file(local_path), local_path] if File.exist?(local_path)

    legacy_path = legacy_stream_lock_path(feature_id, stream_id)
    return [load_stream_lock_file(legacy_path), legacy_path] if legacy_path && File.exist?(legacy_path)

    [{}, local_path]
  end

  def load_stream_lock_file(path)
    lock = load_yaml(path, nil)
    raise "expected a YAML map" unless lock.is_a?(Hash)

    lock
  rescue StandardError => error
    raise "Stream lock is malformed and requires explicit recovery: #{path} (#{error.message})"
  end
end
