#!/usr/bin/env ruby

require "optparse"
require_relative "workflow_lib"
require_relative "workflow_evidence"

options = {
  staged: false,
  repo_root: AgentWorkflow::ROOT,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: validate_work_scope.rb [--staged|--range REV] [--repo-root PATH]"
  opts.on("--staged", "Validate staged files") { options[:staged] = true }
  opts.on("--range REV", "Validate a Git commit/diff range") { |value| options[:range] = value }
  opts.on("--repo-root PATH", "Git repo root") { |value| options[:repo_root] = File.expand_path(value) }
end
parser.parse!(ARGV)

if options[:staged] && options[:range]
  warn "--staged and --range are mutually exclusive"
  exit 1
end

repo_root = options[:repo_root]
changes = WorkflowEvidence.git_changes(
  repo_root: repo_root,
  staged: options[:staged],
  range: options[:range],
  include_untracked: !options[:staged] && options[:range].to_s.empty?,
)
context = AgentWorkflow.active_context
active_streams = Array(context["active_streams"])
errors = []

def installed_bootstrap_paths
  path = File.join(AgentWorkflow::AI_ROOT, "KIT_INSTALLATION.yaml")
  return [] unless File.file?(path)

  manifest = AgentWorkflow.load_yaml(path, {})
  entries = manifest["installed_files"] || manifest["files"]
  paths = Array(entries).map { |entry| entry.is_a?(Hash) ? entry["path"] : entry }.map(&:to_s).reject(&:empty?)
  paths << ".ai/KIT_INSTALLATION.yaml"
  paths.uniq
rescue StandardError
  []
end

def installation_manifest_added?(changes)
  changes.any? do |change|
    change["status"].to_s == "A" &&
      change["old_relative_path"].nil? &&
      change["new_relative_path"].to_s == ".ai/KIT_INSTALLATION.yaml"
  end
end

def feature_ids_from_changes(changes)
  ids = changes.flat_map do |change|
    WorkflowEvidence.entry_paths(change).map do |path|
      rel = AgentWorkflow.relative_to_root(path)
      AgentWorkflow.task_feature_id(rel) if rel
    end
  end.compact

  changes.each do |change|
    WorkflowEvidence.entry_paths(change).each do |path|
      next unless File.file?(path) && File.basename(path) == "change-set.yaml"

      data = AgentWorkflow.load_yaml(path, {})
      ids << data["feature_id"].to_s unless data["feature_id"].to_s.empty?
      ids.concat(Array(data["features"]).map { |item| item.is_a?(Hash) ? item["feature_id"] : item }.map(&:to_s))
    end
  end
  ids.reject(&:empty?).uniq
end

def stream_entries_for_features(feature_ids)
  feature_ids.flat_map do |feature_id|
    feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
    next [] unless feature_dir

    Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).sort.map do |manifest_path|
      manifest = AgentWorkflow.load_yaml(manifest_path, {})
      {
        "feature_id" => feature_id,
        "stream_id" => manifest["stream_id"].to_s,
        "source" => "tracked-change-set",
      }
    end
  end
end

def inferred_feature_ids_for_changes(changes)
  matching = AgentWorkflow.feature_dirs.select do |feature_dir|
    manifests = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).map do |path|
      AgentWorkflow.load_yaml(path, {})
    end
    changes.any? do |change|
      WorkflowEvidence.entry_paths(change).any? do |path|
        manifests.any? { |manifest| AgentWorkflow.effective_scopes(manifest).any? { |scope| AgentWorkflow.path_in_scope?(path, scope) } }
      end
    end
  end

  open_features = matching.select do |feature_dir|
    AgentWorkflow.load_yaml(File.join(feature_dir, "feature.yaml"), {})["status"].to_s != "done"
  end
  selected = open_features.empty? ? matching : open_features
  selected.map { |feature_dir| AgentWorkflow.feature_id_from_task_folder(feature_dir) }.uniq
end

def initial_feature_scaffold_owned?(relative_path, change, task_feature, active_streams)
  return false unless change["status"] == "A" && task_feature

  coordinator = active_streams.find do |entry|
    next false unless entry["feature_id"].to_s == task_feature

    manifest = AgentWorkflow.load_stream_manifest(task_feature, entry["stream_id"].to_s)
    manifest["agent_profile"].to_s == "architect"
  rescue StandardError
    false
  end
  return false unless coordinator

  suffix = relative_path.split("/", 4)[3].to_s
  allowed_root = %w[feature.yaml change-set.yaml spec.md]
  return true if allowed_root.include?(suffix)
  return true if suffix.match?(%r{\Acontracts/(api|db|acceptance)\.md\z})

  match = suffix.match(%r{\Astreams/([^/]+)/(manifest\.yaml|plan\.md|handoff\.md|evidence\.yaml|review\.yaml)\z})
  return false unless match

  sibling_path = AgentWorkflow.stream_manifest_path(task_feature, match[1])
  return false unless sibling_path

  sibling = AgentWorkflow.load_yaml(sibling_path, {})
  sibling["status"].to_s == "planned" && sibling["owner_agent"].to_s.empty?
end

ownership_streams = active_streams
if ownership_streams.empty? && options[:range]
  feature_ids = feature_ids_from_changes(changes)
  feature_ids = inferred_feature_ids_for_changes(changes) if feature_ids.empty?
  ownership_streams = stream_entries_for_features(feature_ids)
end

bootstrap_paths = installed_bootstrap_paths
manifest_added = installation_manifest_added?(changes)
bootstrap_range_allowed = options[:range].to_s.empty? ||
  WorkflowEvidence.single_commit_range?(repo_root, options[:range])
bootstrap_index_complete = WorkflowEvidence.git_index_contains_paths?(repo_root, bootstrap_paths) &&
  WorkflowEvidence.git_index_matches_worktree?(repo_root, ".ai/KIT_INSTALLATION.yaml")
if manifest_added && !bootstrap_range_allowed
  errors << ".ai/KIT_INSTALLATION.yaml: initial bootstrap must be exactly one installation commit"
end
if manifest_added && !bootstrap_index_complete
  errors << ".ai/KIT_INSTALLATION.yaml: initial bootstrap must stage every installed file without manifest worktree drift"
end
initial_bootstrap = manifest_added &&
  bootstrap_range_allowed &&
  bootstrap_index_complete &&
  active_streams.empty? &&
  AgentWorkflow.feature_dirs.empty? &&
  !bootstrap_paths.empty?

changes.each do |change|
  WorkflowEvidence.entry_paths(change).each do |path|
    rel = AgentWorkflow.relative_to_root(path)
    unless rel
      errors << "#{path}: changed path is outside the configured workspace root"
      next
    end

    bootstrap_owned = initial_bootstrap &&
      bootstrap_paths.include?(rel) &&
      AgentWorkflow.installation_bootstrap_path?(rel)
    next if bootstrap_owned

    if rel == ".ai/ACTIVE_CONTEXT.yaml" || rel.start_with?(".ai/local/") || rel.match?(%r{\A\.ai/tasks/[^/]+/streams/[^/]+/LOCK\.yaml\z})
      errors << "#{rel}: local active-state files must not be committed"
      next
    end

    matches = AgentWorkflow.matching_active_streams(path, ownership_streams)
    task_feature = AgentWorkflow.task_feature_id(rel)
    matches = matches.select { |entry| entry["feature_id"].to_s == task_feature } if task_feature

    if matches.empty?
      next if initial_feature_scaffold_owned?(rel, change, task_feature, active_streams)

      detail = ownership_streams.empty? ? "no owning stream is active or declared by the change set" : "path is outside every owning stream write/state/doc scope"
      errors << "#{rel}: #{detail}"
      next
    end

    if matches.length > 1
      owners = matches.map { |entry| "#{entry['feature_id']}/#{entry['stream_id']}" }.join(", ")
      errors << "#{rel}: ambiguous stream ownership (#{owners})"
      next
    end

    if AgentWorkflow.protected_path?(rel)
      feature = AgentWorkflow.load_feature(matches.first["feature_id"].to_s)
      unless feature["workflow_tier"].to_s == "tier3"
        errors << "#{rel}: protected path ownership requires a tier3 feature and human approval evidence"
      end
    end
  end
end

mode = options[:staged] ? "staged" : (options[:range] ? "range #{options[:range]}" : "working tree")
puts "[work-scope] repo: #{repo_root}"
puts "[work-scope] change set: #{mode} (#{changes.length} entries)"
if errors.empty?
  puts "[work-scope] OK"
  exit 0
end

puts "[work-scope] ERROR"
errors.uniq.each { |error| puts "- #{error}" }
exit 1
