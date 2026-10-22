#!/usr/bin/env ruby

require "optparse"
require "pathname"
require_relative "workflow_lib"

options = { paths: [] }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: collect_context.rb FEATURE-ID STREAM-ID [--path PATH ...]"
  opts.on("--path PATH", "Intended path; repeatable") { |value| options[:paths] << value }
end
parser.parse!(ARGV)

feature_id, stream_id = ARGV
unless feature_id && stream_id
  warn parser
  exit 1
end

manifest = AgentWorkflow.load_stream_manifest(feature_id, stream_id)
feature = AgentWorkflow.load_feature(feature_id)
context_map = AgentWorkflow.load_yaml(AgentWorkflow::CONTEXT_MAP_PATH, {})
profile = manifest["agent_profile"].to_s
paths = options[:paths].empty? ? Array(manifest["write_scope"]) : options[:paths]

def patterns_overlap?(left, right)
  if AgentWorkflow.respond_to?(:scope_patterns_overlap?)
    AgentWorkflow.scope_patterns_overlap?(left, right)
  else
    left_value = left.to_s.delete_prefix("./")
    right_value = right.to_s.delete_prefix("./")
    left_prefix = left_value.split(/[\*\?\[]/, 2).first.to_s.sub(%r{/+\z}, "")
    right_prefix = right_value.split(/[\*\?\[]/, 2).first.to_s.sub(%r{/+\z}, "")
    left_value == right_value || (!left_prefix.empty? && right_prefix.start_with?(left_prefix)) || (!right_prefix.empty? && left_prefix.start_with?(right_prefix))
  end
rescue StandardError
  false
end

protected_patterns = Array(AgentWorkflow.project_map["protected_paths"])
unsafe_intents = paths.select do |path|
  rel = AgentWorkflow.relative_to_root(path) || path.to_s.delete_prefix("./")
  AgentWorkflow.protected_path?(rel) || protected_patterns.any? { |protected| patterns_overlap?(rel, protected) }
end
unless unsafe_intents.empty?
  warn "Context collection refused: intended paths overlap protected paths:"
  unsafe_intents.each { |path| warn "- #{path}" }
  exit 1
end

includes = []
profile_context = context_map.dig("agent_profiles", profile)
includes.concat(Array(profile_context["include"])) if profile_context.is_a?(Hash)

Array(context_map["path_contexts"]).each do |entry|
  next unless entry.is_a?(Hash)

  patterns = Array(entry["patterns"])
  matched = paths.any? do |path|
    rel = AgentWorkflow.relative_to_root(path) || path.to_s
    patterns.any? { |pattern| AgentWorkflow.path_glob_match?(rel, pattern) }
  end
  includes.concat(Array(entry["include"])) if matched
end

includes.concat(Array(manifest["canonical_inputs"]))
includes.concat(Array(manifest["contract_inputs"]))
includes << AgentWorkflow.feature_path(feature_id)
includes = includes.compact.map { |path| AgentWorkflow.absolute_path(path) }.uniq

workspace_real = File.realpath(AgentWorkflow::ROOT)
safe_includes = []
errors = []
includes.each do |path|
  expanded = File.expand_path(path)
  rel = AgentWorkflow.relative_to_root(expanded)
  if rel.nil?
    errors << "#{path}: context include is outside the workspace"
    next
  end
  if AgentWorkflow.protected_path?(rel)
    errors << "#{rel}: context include is protected"
    next
  end
  next unless File.exist?(expanded)

  real = File.realpath(expanded)
  unless real == workspace_real || real.start_with?("#{workspace_real}/")
    errors << "#{rel}: symlink resolves outside the workspace"
    next
  end
  real_rel = AgentWorkflow.relative_to_root(real)
  if real_rel.nil? || AgentWorkflow.protected_path?(real_rel)
    errors << "#{rel}: resolved context include is protected or outside the workspace"
    next
  end
  safe_includes << real if File.file?(real)
end

unless errors.empty?
  warn "Context collection refused:"
  errors.uniq.each { |error| warn "- #{error}" }
  exit 1
end

puts "Context bundle"
puts "feature: #{feature_id} #{feature['title']}"
puts "stream: #{stream_id}"
puts "agent_profile: #{profile.empty? ? 'unspecified' : profile}"
puts

safe_includes.uniq.each do |path|
  rel = AgentWorkflow.relative_to_root(path) || path
  puts "--- #{rel} ---"
  File.readlines(path).first(160).each { |line| print line }
  puts
end
