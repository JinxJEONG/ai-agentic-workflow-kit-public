#!/usr/bin/env ruby

require "json"
require "digest"
require "optparse"
require "open3"
require "rbconfig"
require "yaml"
require_relative "../resolver/project_context"

KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
BOOTSTRAP = File.join(KIT_ROOT, "engine", "install", "bootstrap_project.rb")
CURRENT_MANIFEST_SCHEMA = 2

EXIT_OK = 0
EXIT_ACTION_REQUIRED = 10
EXIT_REVIEW_REQUIRED = 20
EXIT_BLOCKED = 30
EXIT_INVALID = 40

def git_value(target, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", target, *args)
  [stdout.strip, stderr.strip, status.success?]
end

def safe_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
rescue ArgumentError
  YAML.safe_load(File.read(path), [], [], false)
end

def target_git?(target)
  value, = git_value(target, "rev-parse", "--is-inside-work-tree")
  value == "true"
end

def manifest_for(target)
  path = File.join(target, ".ai", "KIT_INSTALLATION.yaml")
  return [path, nil] unless File.file?(path)

  [path, safe_yaml(path)]
rescue Psych::Exception => error
  [path, { "_invalid_error" => error.message }]
end

def legacy_markers?(target)
  [
    File.join(target, ".ai"),
    File.join(target, "AGENTS.md"),
    File.join(target, ".ai", "runtime", "githooks"),
    File.join(target, ".githooks"),
  ].any? { |path| File.exist?(path) }
end

def dirty_count(target)
  output, _error, ok = git_value(target, "status", "--porcelain=v1", "--untracked-files=all")
  return nil unless ok

  output.empty? ? 0 : output.lines.length
end

def hooks_path(target)
  output, error, ok = Open3.capture3("git", "-C", target, "config", "--show-origin", "--get", "core.hooksPath")
  return { "configured" => false, "value" => nil, "error" => error } unless ok

  origin, value = output.strip.split("\t", 2)
  { "configured" => !value.to_s.empty?, "value" => value, "origin" => origin }
end

def bootstrap_plan(target, manifest, options)
  args = [RbConfig.ruby, BOOTSTRAP, "--dry-run", "--json"]
  source = manifest.is_a?(Hash) && manifest["source"].is_a?(Hash) ? manifest["source"] : {}
  source_manifest = options[:source_manifest] || source["manifest_locator"]
  expected_digest = options[:expected_bundle_digest] || (manifest.is_a?(Hash) && manifest["kit_bundle_digest"])
  expected_manifest_digest = options[:expected_manifest_digest] || (manifest.is_a?(Hash) && manifest["release_manifest_digest"])
  args.concat(["--source-manifest", source_manifest]) if source_manifest
  args.concat(["--expected-kit-bundle-digest", expected_digest]) if expected_digest
  args.concat(["--expected-release-manifest-digest", expected_manifest_digest]) if expected_manifest_digest
  if manifest.is_a?(Hash)
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
  end
  args << target
  stdout, stderr, status = Open3.capture3(*args)
  begin
    plan = JSON.parse(stdout)
    plan["command"] = {
      "exit_code" => status.exitstatus,
      "stderr" => stderr.empty? ? nil : stderr,
    }
    plan
  rescue JSON::ParserError
    {
      "command" => { "exit_code" => status.exitstatus, "stderr" => stderr },
      "error" => stdout.empty? ? stderr : stdout,
    }
  end
end

def managed_file_drift?(target, manifest)
  Array(manifest["installed_files"]).any? do |entry|
    next false unless entry.is_a?(Hash)

    ownership = entry["ownership"].to_s
    managed = %w[kit kit-owned merge-owned legacy].include?(ownership)
    next false unless managed

    relative = entry["path"].to_s
    expected = entry["sha256"].to_s
    destination = File.join(target, relative)
    !File.file?(destination) || File.symlink?(destination) || !expected.match?(/\A[0-9a-f]{64}\z/) || Digest::SHA256.file(destination).hexdigest != expected
  end
end

def classify(target, manifest, plan)
  return ["invalid", EXIT_INVALID] if manifest.is_a?(Hash) && manifest.key?("_invalid_error")
  activity = plan.dig("activity") || {}
  return ["blocked", EXIT_BLOCKED] if Array(activity["active_streams"]).any? || Array(activity["lock_paths"]).any?
  return ["not_installed", EXIT_ACTION_REQUIRED] unless manifest || legacy_markers?(target)
  return ["legacy_unknown", EXIT_REVIEW_REQUIRED] unless manifest
  return ["invalid", EXIT_INVALID] unless manifest.is_a?(Hash)

  schema_value = manifest["schema_version"]
  return ["invalid", EXIT_INVALID] unless schema_value.is_a?(Integer) && schema_value.positive?

  schema = schema_value
  return ["unsupported", EXIT_INVALID] if schema > CURRENT_MANIFEST_SCHEMA
  return ["blocked", EXIT_BLOCKED] if plan["error"] || plan["status"] == "blocked"
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if schema != CURRENT_MANIFEST_SCHEMA
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if manifest["kit_version"].to_s != plan.dig("source", "kit_version").to_s
  return ["blocked", EXIT_BLOCKED] if manifest["installation_state"] == "managed" && plan.dig("source", "kit_bundle_digest").to_s.empty?
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if manifest["kit_bundle_digest"] != plan.dig("source", "kit_bundle_digest")
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if manifest["release_manifest_digest"] != plan.dig("source", "release_manifest_digest")
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if manifest["rendered_install_digest"] != plan.dig("source", "rendered_install_digest")
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if managed_file_drift?(target, manifest)

  counts = plan["counts"] || {}
  return ["review_required", EXIT_REVIEW_REQUIRED] if counts["conflict"].to_i.positive?
  return ["upgrade_available", EXIT_ACTION_REQUIRED] if %w[create update delete].any? { |action| counts[action].to_i.positive? }
  return ["legacy_review", EXIT_REVIEW_REQUIRED] if manifest["installation_state"].to_s == "legacy"

  ["current", EXIT_OK]
end

def status_record(target, options)
  target = File.realpath(target)
  unless target_git?(target)
    return {
      "target" => target,
      "state" => "invalid",
      "exit_code" => EXIT_INVALID,
      "error" => "target is not a Git work tree",
    }
  end

  manifest_path, manifest = manifest_for(target)
  plan = bootstrap_plan(target, manifest, options)
  state, exit_code = classify(target, manifest, plan)
  context_checks = %w[database authentication deployment].each_with_object({}) do |operation, result|
    begin
      WorkflowKit::ProjectContext.build(target, operation: operation)
      result[operation] = { "ready" => true }
    rescue WorkflowKit::ContextError => error
      result[operation] = { "ready" => false, "error" => error.message }
    end
  end
  incomplete_context = context_checks.values.any? do |result|
    result["ready"] == false && result["error"].to_s.match?(/incomplete|identity is missing/)
  end
  if incomplete_context && state == "current"
    state = "review_required"
    exit_code = EXIT_REVIEW_REQUIRED
  end
  release_resolved = !plan.dig("source", "kit_bundle_digest").to_s.empty?
  source = if release_resolved
    {
      "kind" => "release",
      "kit_version" => plan.dig("source", "kit_version") || manifest["kit_version"],
      "kit_bundle_digest" => plan.dig("source", "kit_bundle_digest") || manifest["kit_bundle_digest"],
      "release_manifest_digest" => plan.dig("source", "release_manifest_digest") || manifest["release_manifest_digest"],
      "release_ref" => manifest.is_a?(Hash) ? manifest.dig("provenance", "release_ref") : nil,
      "release_commit" => manifest.is_a?(Hash) ? manifest.dig("provenance", "release_commit") : nil,
      "working_tree_dirty" => nil,
    }
  else
    {
      "kind" => "unresolved",
      "kit_version" => plan.dig("source", "kit_version"),
      "kit_bundle_digest" => plan.dig("source", "kit_bundle_digest"),
      "release_manifest_digest" => plan.dig("source", "release_manifest_digest"),
      "working_tree_dirty" => nil,
    }
  end
  {
    "target" => target,
    "state" => state,
    "exit_code" => exit_code,
    "source" => source,
    "manifest" => {
      "path" => manifest_path,
      "present" => !manifest.nil?,
      "schema_version" => manifest.is_a?(Hash) ? manifest["schema_version"] : nil,
      "kit_version" => manifest.is_a?(Hash) ? manifest["kit_version"] : nil,
      "kit_bundle_digest" => manifest.is_a?(Hash) ? manifest["kit_bundle_digest"] : nil,
      "release_manifest_digest" => manifest.is_a?(Hash) ? manifest["release_manifest_digest"] : nil,
      "rendered_install_digest" => manifest.is_a?(Hash) ? manifest["rendered_install_digest"] : nil,
      "installation_state" => manifest.is_a?(Hash) ? manifest["installation_state"] : nil,
    },
    "worktree" => { "dirty_entries" => dirty_count(target) },
    "hooks" => hooks_path(target),
    "sensitive_context" => context_checks,
    "plan" => plan,
  }
rescue SystemCallError, Psych::Exception => error
  {
    "target" => target,
    "state" => "invalid",
    "exit_code" => EXIT_INVALID,
    "error" => "#{error.class}: #{error.message}",
  }
end

options = { json: false, source_manifest: nil, expected_bundle_digest: nil, expected_manifest_digest: nil }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: status.rb [options] /path/to/project"
  opts.on("--json", "Print machine-readable status") { options[:json] = true }
  opts.on("--source-manifest PATH", "Use this reviewed release sidecar manifest") { |value| options[:source_manifest] = value }
  opts.on("--expected-kit-bundle-digest DIGEST", "Use this independently reviewed trust-root digest") { |value| options[:expected_bundle_digest] = value }
  opts.on("--expected-release-manifest-digest DIGEST", "Use the independently reviewed sidecar digest") { |value| options[:expected_manifest_digest] = value }
end
parser.parse!(ARGV)

target = ARGV.first
unless target && ARGV.length == 1
  warn parser
  exit EXIT_INVALID
end

record = status_record(target, options)
if options[:json]
  puts JSON.pretty_generate(record)
else
  puts "Workflow Kit status: #{record['target']}"
  puts "State: #{record['state']}"
  source = record["source"] || {}
  source_suffix = source['commit'] ? " @ #{source['commit']}" : ''
  source_suffix += " (dirty)" if source['working_tree_dirty']
  puts "Source: #{source['kit_version']}#{source_suffix}"
  manifest = record["manifest"] || {}
  puts "Installed: #{manifest['kit_version'] || 'none'}#{manifest['schema_version'] ? " (schema #{manifest['schema_version']})" : ''}"
  puts "Dirty entries: #{record.dig('worktree', 'dirty_entries') || 'unknown'}"
  hooks = record["hooks"] || {}
  hooks_label = hooks["configured"] ? "#{hooks['value']} (#{hooks['origin']})" : "inactive"
  puts "Hooks: #{hooks_label}"
  activity = record.dig("plan", "activity") || {}
  puts "Active streams: #{Array(activity['active_streams']).length}"
  puts "Locks: #{Array(activity['lock_paths']).length}"
  counts = record.dig("plan", "counts") || {}
  puts "Plan: #{counts.map { |key, value| "#{key}=#{value}" }.sort.join(', ')}"
  puts "Error: #{record['error']}" if record["error"]
end

exit record.fetch("exit_code", EXIT_INVALID)
