#!/usr/bin/env ruby

require "optparse"
require_relative "workflow_lib"
require_relative "workflow_evidence"

options = {
  full: false,
  active_registry: false,
  staged: false,
  repo_root: AgentWorkflow::ROOT,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: validate_docs_sync.rb [--feature FEATURE-ID] [--active-registry] [--staged|--range REV] [--full]"
  opts.on("--feature FEATURE-ID", "Validate one feature") { |value| options[:feature_id] = value }
  opts.on("--active-registry", "Validate active registry") { options[:active_registry] = true }
  opts.on("--staged", "Validate staged docs impact") { options[:staged] = true }
  opts.on("--range REV", "Validate docs impact in a Git diff range") { |value| options[:range] = value }
  opts.on("--repo-root PATH", "Git repository root") { |value| options[:repo_root] = File.expand_path(value) }
  opts.on("--full", "Run full validation") { options[:full] = true }
end
parser.parse!(ARGV)

if options[:staged] && options[:range]
  warn "--staged and --range are mutually exclusive"
  exit 1
end

errors = []
changes = if options[:staged] || options[:range]
  WorkflowEvidence.git_changes(repo_root: options[:repo_root], staged: options[:staged], range: options[:range])
else
  []
end

context_map = AgentWorkflow.load_yaml(AgentWorkflow::CONTEXT_MAP_PATH, {})
errors << "#{AgentWorkflow::CONTEXT_MAP_PATH} must define agent_profiles" unless context_map["agent_profiles"].is_a?(Hash)
errors << "#{AgentWorkflow::CONTEXT_MAP_PATH} must define path_contexts" unless context_map["path_contexts"].is_a?(Array)

AgentWorkflow::AGENT_PROFILES.each do |profile|
  errors << "#{AgentWorkflow::CONTEXT_MAP_PATH} agent_profiles missing #{profile}" unless context_map.dig("agent_profiles", profile).is_a?(Hash)
end

context = AgentWorkflow.active_context
if options[:active_registry] || options[:full]
  errors << "active context active_streams must be an array" unless context["active_streams"].is_a?(Array)
  Array(context["active_streams"]).each do |entry|
    %w[feature_id stream_id path owner_agent status].each do |key|
      errors << "active context stream missing #{key}: #{entry.inspect}" if entry[key].to_s.empty?
    end
    manifest_path = AgentWorkflow.stream_manifest_path(entry["feature_id"].to_s, entry["stream_id"].to_s)
    errors << "active context references missing stream #{entry.inspect}" unless manifest_path
  end
end

def feature_ids_in_changes(changes)
  changes.flat_map do |change|
    WorkflowEvidence.entry_paths(change).map do |path|
      relative = AgentWorkflow.relative_to_root(path)
      AgentWorkflow.task_feature_id(relative) if relative
    end
  end.compact.uniq
end

def inferred_feature_ids_in_changes(changes)
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

feature_dirs = if options[:feature_id]
  dir = AgentWorkflow.resolve_feature_dir(options[:feature_id])
  dir ? [dir] : []
elsif options[:full]
  AgentWorkflow.feature_dirs
elsif options[:staged] || options[:range]
  feature_ids = Array(context["active_streams"]).map { |entry| entry["feature_id"].to_s }
  feature_ids.concat(feature_ids_in_changes(changes))
  feature_ids.concat(inferred_feature_ids_in_changes(changes)) if feature_ids.reject(&:empty?).empty?
  feature_ids.reject(&:empty?).uniq.map { |feature_id| AgentWorkflow.resolve_feature_dir(feature_id) }.compact
else
  []
end

errors << "Missing feature #{options[:feature_id]}" if options[:feature_id] && feature_dirs.empty?

changed_new_paths = changes.each_with_object([]) do |change, paths|
  next if change["status"] == "D"

  paths << change["new_path"] if change["new_path"]
end.uniq

feature_dirs.each do |feature_dir|
  feature_path = File.join(feature_dir, "feature.yaml")
  feature = AgentWorkflow.load_yaml(feature_path, {})
  feature_id = feature["feature_id"].to_s
  %w[feature_id title status workflow_tier contracts streams doc_impact].each do |key|
    errors << "#{feature_path} missing #{key}" unless feature.key?(key)
  end
  unless AgentWorkflow::WORKFLOW_TIERS.include?(feature["workflow_tier"].to_s)
    errors << "#{feature_path} workflow_tier must be one of #{AgentWorkflow::WORKFLOW_TIERS.join(', ')}"
  end

  declared_streams = Array(feature["streams"]).map(&:to_s)
  manifest_paths = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).sort
  actual_streams = manifest_paths.map { |path| AgentWorkflow.load_yaml(path, {})["stream_id"].to_s }
  errors << "#{feature_path} streams do not match manifest directories" unless declared_streams.sort == actual_streams.sort

  required_docs = Array(feature.dig("doc_impact", "must_update"))
  affected_manifests = []

  manifest_paths.each do |manifest_path|
    manifest = AgentWorkflow.load_yaml(manifest_path, {})
    %w[feature_id stream_id stream_type status write_scope doc_scope].each do |key|
      errors << "#{manifest_path} missing #{key}" unless manifest.key?(key)
    end
    errors << "#{manifest_path} feature_id must be #{feature_id}" unless manifest["feature_id"].to_s == feature_id
    profile = manifest["agent_profile"].to_s
    errors << "#{manifest_path} agent_profile must be one of #{AgentWorkflow::AGENT_PROFILES.join(', ')}" unless profile.empty? || AgentWorkflow::AGENT_PROFILES.include?(profile)
    doc_scope = manifest["doc_scope"]
    unless doc_scope.is_a?(Hash)
      errors << "#{manifest_path} doc_scope must be a map"
      next
    end
    AgentWorkflow::STREAM_DOC_SCOPE_KEYS.each do |key|
      errors << "#{manifest_path} doc_scope.#{key} must be an array" unless doc_scope[key].is_a?(Array)
    end

    if !changes.empty? && changes.any? { |change| WorkflowEvidence.entry_paths(change).any? { |path| WorkflowEvidence.stream_scopes(manifest).any? { |scope| AgentWorkflow.path_in_scope?(path, scope) } } }
      affected_manifests << manifest
      required_docs.concat(Array(doc_scope["must_update"]))
    end
  end

  required_docs = required_docs.compact.map { |path| AgentWorkflow.absolute_path(path) }.uniq
  feature_changes = changes.select { |change| WorkflowEvidence.entry_matches_scopes?(change, WorkflowEvidence.feature_scopes(feature_id)) }
  implementation_changes = feature_changes.reject do |change|
    WorkflowEvidence.entry_paths(change).all? { |path| required_docs.include?(path) || WorkflowEvidence.transient_path?(path) }
  end

  if (options[:staged] || options[:range]) && !implementation_changes.empty?
    if required_docs.empty?
      reason = feature.dig("doc_impact", "no_impact_reason").to_s.strip
      errors << "#{feature_path}: implementation changed but doc_impact.must_update is empty and no_impact_reason is missing" if reason.empty?
    else
      required_docs.each do |doc_path|
        next if changed_new_paths.include?(doc_path)

        rel = AgentWorkflow.relative_to_root(doc_path) || doc_path
        errors << "#{feature_id}: required document was not added or updated in this change set: #{rel}"
      end
    end
  end

  next unless options[:full] || options[:feature_id]

  required_docs.each do |doc_path|
    rel = AgentWorkflow.relative_to_root(doc_path) || doc_path
    errors << "#{feature_id}: required document is missing: #{rel}" unless File.file?(doc_path)
  end
end

if errors.empty?
  puts "OK: docs sync validation passed."
  puts "change_entries: #{changes.length}" if options[:staged] || options[:range]
  exit 0
end

puts "ERROR: docs sync validation failed."
errors.uniq.each { |error| puts "- #{error}" }
exit 1
