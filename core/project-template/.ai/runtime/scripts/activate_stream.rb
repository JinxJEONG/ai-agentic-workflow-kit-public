#!/usr/bin/env ruby

require_relative "workflow_lib"

feature_id, stream_id, owner_agent = ARGV
unless feature_id && stream_id && owner_agent
  warn "Usage: activate_stream.rb FEATURE-ID STREAM-ID OWNER_AGENT"
  exit 1
end

unless AgentWorkflow::OWNER_AGENTS.include?(owner_agent)
  warn "OWNER_AGENT must be one of: #{AgentWorkflow::OWNER_AGENTS.join(', ')}"
  exit 1
end

feature_path = AgentWorkflow.feature_path(feature_id)
manifest_path = AgentWorkflow.stream_manifest_path(feature_id, stream_id)
unless feature_path && manifest_path
  warn "Missing feature or stream: #{feature_id}/#{stream_id}"
  exit 1
end

feature = AgentWorkflow.load_yaml(feature_path, {})
manifest = AgentWorkflow.load_yaml(manifest_path, {})
profile = manifest["agent_profile"].to_s
unless profile.empty? || AgentWorkflow::AGENT_PROFILES.include?(profile)
  warn "#{manifest_path} agent_profile must be one of: #{AgentWorkflow::AGENT_PROFILES.join(', ')}"
  exit 1
end

begin
  AgentWorkflow.update_active_context do |context|
    active_streams = Array(context["active_streams"])
    current_entry = active_streams.find do |entry|
      entry["feature_id"] == feature_id && entry["stream_id"] == stream_id
    end
    if current_entry && current_entry["owner_agent"].to_s != owner_agent
      raise "Stream is already active for #{current_entry['owner_agent']}: #{feature_id}/#{stream_id}"
    end

    active_streams.each do |entry|
      next if entry["feature_id"] == feature_id && entry["stream_id"] == stream_id

      other = AgentWorkflow.load_stream_manifest(entry["feature_id"].to_s, entry["stream_id"].to_s)
      unless AgentWorkflow.parallel_allowed?(manifest) && AgentWorkflow.parallel_allowed?(other)
        raise "Parallel activation is disabled by #{feature_id}/#{stream_id} or #{entry['feature_id']}/#{entry['stream_id']}"
      end

      overlap = AgentWorkflow.overlapping_scope_pair(
        AgentWorkflow.activation_scopes(manifest),
        AgentWorkflow.activation_scopes(other),
      )
      next unless overlap

      raise "Writable scope overlaps active stream #{entry['feature_id']}/#{entry['stream_id']}: #{overlap[0]} <-> #{overlap[1]}"
    end

    existing_lock, existing_lock_path = AgentWorkflow.load_stream_lock(feature_id, stream_id)
    if File.exist?(existing_lock_path) && existing_lock["owner_agent"].to_s.empty?
      raise "Stream lock is invalid and requires explicit recovery: #{existing_lock_path}"
    end
    if File.exist?(existing_lock_path) && current_entry.nil?
      raise "Stale or orphaned stream lock requires explicit recovery: #{existing_lock_path}"
    end
    unless existing_lock.empty? || existing_lock["owner_agent"].to_s == owner_agent
      raise "Stream is locked by #{existing_lock['owner_agent']} and requires explicit recovery: #{existing_lock_path}"
    end

    lock_path = AgentWorkflow.stream_lock_path(feature_id, stream_id)
    manifest["status"] = "in_progress"
    manifest["owner_agent"] = owner_agent
    manifest["last_updated"] = Date.today.to_s
    AgentWorkflow.write_yaml(manifest_path, manifest)

    feature["status"] = "in_progress"
    AgentWorkflow.write_yaml(feature_path, feature)

    AgentWorkflow.write_yaml(lock_path, {
      "schema_version" => 1,
      "feature_id" => feature_id,
      "stream_id" => stream_id,
      "owner_agent" => owner_agent,
      "locked_at" => Time.now.utc.iso8601,
    })

    context["active_streams"] = active_streams.reject do |entry|
      entry["feature_id"] == feature_id && entry["stream_id"] == stream_id
    end
    context["active_streams"] << {
      "feature_id" => feature_id,
      "stream_id" => stream_id,
      "path" => File.dirname(manifest_path),
      "owner_agent" => owner_agent,
      "status" => "in_progress",
      "lock_path" => lock_path,
      "scope_version" => AgentWorkflow.manifest_scope_version(manifest),
      "write_scope" => manifest["write_scope"],
      "state_write_scope" => manifest["state_write_scope"],
      "shared_write_scope" => manifest["shared_write_scope"],
      "parallel_allowed" => AgentWorkflow.parallel_allowed?(manifest),
    }
    context["active_features"] ||= []
    context["active_features"].reject! { |entry| entry["feature_id"] == feature_id }
    context["active_features"] << {
      "feature_id" => feature_id,
      "path" => File.dirname(File.dirname(File.dirname(manifest_path))),
      "title" => feature["title"],
      "state" => "in_progress",
    }
  end
rescue StandardError => error
  warn error.message
  exit 1
end

puts "Activated #{feature_id}/#{stream_id} for #{owner_agent}"
