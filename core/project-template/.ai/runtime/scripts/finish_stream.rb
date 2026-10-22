#!/usr/bin/env ruby

require_relative "workflow_lib"
require_relative "workflow_evidence"
require_relative "workflow_policy"

feature_id, stream_id, status = ARGV
status ||= "done"
unless feature_id && stream_id
  warn "Usage: finish_stream.rb FEATURE-ID STREAM-ID [done|blocked]"
  exit 1
end

unless %w[done blocked].include?(status)
  warn "status must be done or blocked"
  exit 1
end

manifest_path = AgentWorkflow.stream_manifest_path(feature_id, stream_id)
unless manifest_path
  warn "Missing stream manifest for #{feature_id}/#{stream_id}"
  exit 1
end

manifest = AgentWorkflow.load_yaml(manifest_path, {})
errors = []
unless manifest["status"].to_s == "in_progress"
  errors << "#{manifest_path}: invalid state transition #{manifest['status'].inspect} -> #{status}; stream must be in_progress"
end

lock, lock_path = if AgentWorkflow.respond_to?(:load_stream_lock)
  AgentWorkflow.load_stream_lock(feature_id, stream_id)
elsif AgentWorkflow.respond_to?(:stream_lock_path)
  path = AgentWorkflow.stream_lock_path(feature_id, stream_id)
  [AgentWorkflow.load_yaml(path, {}), path]
else
  path = File.join(File.dirname(manifest_path), "LOCK.yaml")
  [AgentWorkflow.load_yaml(path, {}), path]
end
if !File.file?(lock_path)
  errors << "#{lock_path}: active stream lock is missing"
else
  errors << "#{lock_path}: owner_agent does not match manifest" unless lock["owner_agent"].to_s == manifest["owner_agent"].to_s && !manifest["owner_agent"].to_s.empty?
end

context = AgentWorkflow.active_context
active_entry = Array(context["active_streams"]).find do |entry|
  entry["feature_id"].to_s == feature_id && entry["stream_id"].to_s == stream_id
end
if active_entry.nil?
  errors << "active context does not contain #{feature_id}/#{stream_id}"
elsif active_entry["owner_agent"].to_s != manifest["owner_agent"].to_s
  errors << "active context owner does not match manifest owner for #{feature_id}/#{stream_id}"
end

if status == "done"
  Array(manifest["depends_on"]).each do |dependency|
    dependency_manifest = AgentWorkflow.stream_manifest_path(feature_id, dependency.to_s)
    if !dependency_manifest || AgentWorkflow.load_yaml(dependency_manifest, {})["status"].to_s != "done"
      errors << "#{manifest_path}: dependency #{dependency} must be done first"
    end
  end

  handoff_path = File.join(File.dirname(manifest_path), "handoff.md")
  handoff = File.file?(handoff_path) ? File.read(handoff_path) : ""
  %w[Status Validation].each do |heading|
    errors << "#{handoff_path}: missing ## #{heading} section" unless handoff.match?(/^##\s+#{Regexp.escape(heading)}\s*$/i)
  end
  errors << "#{handoff_path}: missing ## Doc Sync section" unless handoff.match?(/^##\s+Doc Sync\s*$/i)
  WorkflowEvidence.placeholder_lines(handoff_path).each do |line|
    errors << "#{handoff_path}: unresolved placeholder (#{line})"
  end

  evidence_errors, evidence_info = WorkflowEvidence.evidence_errors(feature_id, stream_id)
  errors.concat(evidence_errors)

  feature = AgentWorkflow.load_feature(feature_id)
  acceptance_path = feature.dig("contracts", "acceptance").to_s
  acceptance_path = File.join(AgentWorkflow.resolve_feature_dir(feature_id), "contracts", "acceptance.md") if acceptance_path.empty?
  acceptance_path = AgentWorkflow.absolute_path(acceptance_path)
  WorkflowEvidence.placeholder_lines(acceptance_path).each do |line|
    errors << "#{acceptance_path}: acceptance is incomplete (#{line})"
  end

  if manifest["agent_profile"].to_s == "reviewer"
    tier = WorkflowPolicy.feature_tier(feature)
    approvals = WorkflowPolicy.required_approvals(feature, tier)
    review_errors, = WorkflowEvidence.review_errors(feature_id, require_human: approvals["human"])
    errors.concat(review_errors)
  end

  if !errors.empty? && evidence_info && evidence_info["change_set"]
    warn "Expected change-set digest: #{evidence_info['change_set']['digest']}"
    warn "Expected baseline_ref: #{evidence_info['change_set']['baseline_ref']}"
  end
end

unless errors.empty?
  warn "Cannot mark #{feature_id}/#{stream_id} as #{status}:"
  errors.uniq.each { |error| warn "- #{error}" }
  exit 1
end

if AgentWorkflow.respond_to?(:update_active_context)
  begin
    AgentWorkflow.update_active_context do |current|
      current_entry = Array(current["active_streams"]).find do |entry|
        entry["feature_id"].to_s == feature_id && entry["stream_id"].to_s == stream_id
      end
      raise "active stream changed while finishing #{feature_id}/#{stream_id}" unless current_entry && current_entry["owner_agent"].to_s == manifest["owner_agent"].to_s

      fresh_manifest = AgentWorkflow.load_yaml(manifest_path, {})
      raise "stream state changed while finishing #{feature_id}/#{stream_id}" unless fresh_manifest["status"].to_s == "in_progress" && fresh_manifest["owner_agent"].to_s == manifest["owner_agent"].to_s

      fresh_lock, fresh_lock_path = if AgentWorkflow.respond_to?(:load_stream_lock)
        AgentWorkflow.load_stream_lock(feature_id, stream_id)
      else
        [AgentWorkflow.load_yaml(lock_path, {}), lock_path]
      end
      unless File.file?(fresh_lock_path) && fresh_lock["owner_agent"].to_s == manifest["owner_agent"].to_s
        raise "stream lock changed while finishing #{feature_id}/#{stream_id}: #{fresh_lock_path}"
      end

      fresh_manifest["status"] = status
      fresh_manifest["last_updated"] = Date.today.to_s
      AgentWorkflow.write_yaml(manifest_path, fresh_manifest)
      FileUtils.rm_f(fresh_lock_path)
      current["active_streams"] = Array(current["active_streams"]).reject do |entry|
        entry["feature_id"].to_s == feature_id && entry["stream_id"].to_s == stream_id
      end
    end
  rescue StandardError => error
    warn "Cannot finish #{feature_id}/#{stream_id}: #{error.message}"
    exit 1
  end
else
  manifest["status"] = status
  manifest["last_updated"] = Date.today.to_s
  AgentWorkflow.write_yaml(manifest_path, manifest)
  FileUtils.rm_f(lock_path)
  context["active_streams"] = Array(context["active_streams"]).reject do |entry|
    entry["feature_id"].to_s == feature_id && entry["stream_id"].to_s == stream_id
  end
  AgentWorkflow.write_active_context(context)
end

puts "Marked #{feature_id}/#{stream_id} as #{status}"
