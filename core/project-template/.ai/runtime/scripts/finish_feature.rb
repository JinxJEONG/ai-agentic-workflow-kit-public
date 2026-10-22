#!/usr/bin/env ruby

require_relative "workflow_lib"
require_relative "workflow_evidence"
require_relative "workflow_policy"

feature_id = ARGV.first
unless feature_id
  warn "Usage: finish_feature.rb FEATURE-ID"
  exit 1
end

feature_path = AgentWorkflow.feature_path(feature_id)
feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
unless feature_path && feature_dir
  warn "Missing feature #{feature_id}"
  exit 1
end

feature = AgentWorkflow.load_yaml(feature_path, {})
errors = []
manifest_paths = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).sort
declared_streams = Array(feature["streams"]).map(&:to_s).sort
actual_streams = manifest_paths.map { |path| AgentWorkflow.load_yaml(path, {})["stream_id"].to_s }.sort
errors << "#{feature_path}: declared streams do not match manifest directories" unless declared_streams == actual_streams

manifest_paths.each do |manifest_path|
  manifest = AgentWorkflow.load_yaml(manifest_path, {})
  stream_id = manifest["stream_id"].to_s
  errors << "#{manifest_path} status is #{manifest['status'].inspect}, expected done" unless manifest["status"] == "done"
  lock_paths = []
  lock_paths << AgentWorkflow.stream_lock_path(feature_id, stream_id) if AgentWorkflow.respond_to?(:stream_lock_path)
  if AgentWorkflow.respond_to?(:legacy_stream_lock_path)
    lock_paths << AgentWorkflow.legacy_stream_lock_path(feature_id, stream_id)
  else
    lock_paths << File.join(File.dirname(manifest_path), "LOCK.yaml")
  end
  lock_paths.compact.uniq.each { |path| errors << "#{path} still exists" if File.exist?(path) }
  evidence_errors, = WorkflowEvidence.evidence_errors(feature_id, stream_id)
  errors.concat(evidence_errors)
end

acceptance_path = feature.dig("contracts", "acceptance").to_s
acceptance_path = File.join(feature_dir, "contracts", "acceptance.md") if acceptance_path.empty?
acceptance_path = AgentWorkflow.absolute_path(acceptance_path)
WorkflowEvidence.placeholder_lines(acceptance_path).each do |line|
  errors << "#{acceptance_path}: acceptance is incomplete (#{line})"
end

begin
  change_set = WorkflowEvidence.feature_change_set(feature_id)
  policy_paths = change_set["changes"].flat_map { |entry| WorkflowEvidence.entry_paths(entry) }
  policy_errors, = WorkflowPolicy.validation_errors(feature_id, finish: true, paths: policy_paths)
  errors.concat(policy_errors)
rescue StandardError => error
  errors << "#{feature_id}: cannot calculate final change set: #{error.message}"
end

unless errors.empty?
  warn "Cannot finish #{feature_id}:"
  errors.uniq.each { |error| warn "- #{error}" }
  exit 1
end

system("ruby", File.join(AgentWorkflow::AI_ROOT, "runtime", "scripts", "validate_agent_structure.rb")) || exit(1)
system("ruby", File.join(AgentWorkflow::AI_ROOT, "runtime", "scripts", "validate_docs_sync.rb"), "--feature", feature_id, "--full") || exit(1)

change_set_path = feature["change_set"].to_s
change_set_path = File.join(feature_dir, "change-set.yaml") if change_set_path.empty?
change_set_path = AgentWorkflow.absolute_path(change_set_path)
finalize_records = lambda do
  if File.file?(change_set_path)
    change_set_record = AgentWorkflow.load_yaml(change_set_path, {})
    change_set_record["change_set_digest"] = change_set["digest"]
    change_set_record["baseline_ref"] = change_set["baseline_ref"]
    change_set_record["status"] = "validated"
    change_set_record["validated_at"] = Time.now.utc.iso8601
    AgentWorkflow.write_yaml(change_set_path, change_set_record)
  end

  feature["status"] = "done"
  feature["deployment_status"] ||= "not_deployed"
  feature["notes"] = Array(feature["notes"])
  feature["notes"] << "Completed on #{Date.today} via finish_feature.rb. Deployment status remains separate."
  AgentWorkflow.write_yaml(feature_path, feature)
end

if AgentWorkflow.respond_to?(:update_active_context)
  begin
    AgentWorkflow.update_active_context do |context|
      active = Array(context["active_streams"]).select { |entry| entry["feature_id"].to_s == feature_id }
      raise "feature gained active streams while finishing: #{active.map { |entry| entry['stream_id'] }.join(', ')}" unless active.empty?

      manifest_paths.each do |manifest_path|
        current_manifest = AgentWorkflow.load_yaml(manifest_path, {})
        raise "#{manifest_path} changed while finishing" unless current_manifest["status"].to_s == "done"
      end
      finalize_records.call
      context["active_features"] = Array(context["active_features"]).reject { |entry| entry["feature_id"].to_s == feature_id }
    end
  rescue StandardError => error
    warn "Cannot finish #{feature_id}: #{error.message}"
    exit 1
  end
else
  finalize_records.call
  context = AgentWorkflow.active_context
  context["active_features"] = Array(context["active_features"]).reject { |entry| entry["feature_id"].to_s == feature_id }
  AgentWorkflow.write_active_context(context)
end

puts "Marked #{feature_id} as done (deployment_status=#{feature['deployment_status']})"
