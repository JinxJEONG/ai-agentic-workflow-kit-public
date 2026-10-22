#!/usr/bin/env ruby

require "json"
require "optparse"
require_relative "workflow_policy"

options = {
  paths: [],
  finish: false,
  json: false,
  staged: false,
  repo_root: AgentWorkflow::ROOT,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: check_workflow_policy.rb --feature FEATURE-ID [--path PATH ...] [--staged|--range REV] [--finish] [--json]"
  opts.on("--feature FEATURE-ID", "Feature id") { |value| options[:feature_id] = value }
  opts.on("--path PATH", "Path to classify; repeatable") { |value| options[:paths] << value }
  opts.on("--staged", "Classify all staged paths") { options[:staged] = true }
  opts.on("--range REV", "Classify paths changed in a Git diff range") { |value| options[:range] = value }
  opts.on("--repo-root PATH", "Git repository root") { |value| options[:repo_root] = File.expand_path(value) }
  opts.on("--finish", "Apply finish-time approval gates") { options[:finish] = true }
  opts.on("--json", "Emit machine-readable JSON") { options[:json] = true }
end

parser.parse!(ARGV)
unless options[:feature_id]
  warn parser
  exit 1
end
if options[:staged] && options[:range]
  warn "--staged and --range are mutually exclusive"
  exit 1
end

if options[:staged] || options[:range]
  changes = WorkflowEvidence.git_changes(
    repo_root: options[:repo_root],
    staged: options[:staged],
    range: options[:range],
  )
  options[:paths].concat(changes.flat_map { |entry| WorkflowEvidence.entry_paths(entry) })
end

result = WorkflowPolicy.evaluate(options[:feature_id], finish: options[:finish], paths: options[:paths])
if options[:json]
  puts JSON.pretty_generate(result)
else
  puts "Workflow policy"
  puts "feature: #{options[:feature_id]}"
  puts "declared_tier: #{result['declared_tier']}"
  puts "detected_tier: #{result['detected_tier']}"
  puts "effective_tier: #{result['effective_tier']}"
  puts "feature_dir: #{result['feature_dir']}"
  paths = Array(result["tier3_paths"])
  puts "tier3_paths: #{paths.empty? ? 'none' : paths.join(', ')}"
  signals = Array(result["risk_signals"])
  puts "risk_signals: #{signals.empty? ? 'none' : signals.join(', ')}"
  approvals = result["required_approvals"] || {}
  puts "required_approvals: reviewer=#{approvals['reviewer'] == true}, human=#{approvals['human'] == true}"

  if Array(result["errors"]).empty?
    puts "OK: workflow policy passed"
  else
    puts "ERROR: workflow policy failed"
    Array(result["errors"]).each { |error| puts "- [#{error['code']}] #{error['message']}" }
  end
end

exit(Array(result["errors"]).empty? ? 0 : 1)
