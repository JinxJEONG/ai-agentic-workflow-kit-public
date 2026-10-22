#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "rbconfig"

KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
BOOTSTRAP = File.join(KIT_ROOT, "engine", "install", "bootstrap_project.rb")

EXIT_OK = 0
EXIT_REVIEW_REQUIRED = 20
EXIT_BLOCKED = 30
EXIT_INVALID = 40

options = {
  apply: false,
  json: false,
  replace_kit_owned: false,
  approve_paths: [],
  merge_paths: [],
  plan_digest: nil,
  source_manifest: nil,
  expected_bundle_digest: nil,
  expected_manifest_digest: nil,
}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: upgrade.rb [options] PROJECT..."
  opts.on("--apply", "Apply one reviewed plan; without this flag the command is read-only") { options[:apply] = true }
  opts.on("--json", "Print machine-readable plans") { options[:json] = true }
  opts.on("--replace-kit-owned", "Replace reviewed legacy or drifted kit-owned files") { options[:replace_kit_owned] = true }
  opts.on("--approve-path PATH=EXPECTED_SHA256", "Approve one exact protected or merge-owned path") { |value| options[:approve_paths] << value }
  opts.on("--merge-path PATH=FILE", "Use reviewed merged content for one approval-required merge-owned path") { |value| options[:merge_paths] << value }
  opts.on("--plan-digest DIGEST", "Require the generated plan to match this reviewed digest") { |value| options[:plan_digest] = value }
  opts.on("--source-manifest PATH", "Use this reviewed release sidecar manifest") { |value| options[:source_manifest] = value }
  opts.on("--expected-kit-bundle-digest DIGEST", "Trust-root digest reviewed independently of the source manifest") { |value| options[:expected_bundle_digest] = value }
  opts.on("--expected-release-manifest-digest DIGEST", "Trust-root digest of the reviewed release sidecar bytes") { |value| options[:expected_manifest_digest] = value }
end
parser.parse!(ARGV)

targets = ARGV
if targets.empty?
  warn parser
  exit EXIT_INVALID
end
if options[:apply] && targets.length != 1
  warn "ERROR: --apply accepts exactly one target; batch plans are read-only and each target must be applied from its own reviewed plan"
  exit EXIT_INVALID
end
if options[:apply] && options[:plan_digest].to_s.empty?
  warn "ERROR: --apply requires --plan-digest from a separately reviewed read-only plan"
  exit EXIT_INVALID
end

def bootstrap_args(target, options, dry_run:, plan_digest: nil)
  args = [RbConfig.ruby, BOOTSTRAP]
  args << "--dry-run" if dry_run
  args << "--json"
  args << "--force" if options[:replace_kit_owned]
  args.concat(["--source-manifest", options[:source_manifest]]) if options[:source_manifest]
  args.concat(["--expected-kit-bundle-digest", options[:expected_bundle_digest]]) if options[:expected_bundle_digest]
  args.concat(["--expected-release-manifest-digest", options[:expected_manifest_digest]]) if options[:expected_manifest_digest]
  options[:approve_paths].each { |value| args.concat(["--approve-path", value]) }
  options[:merge_paths].each { |value| args.concat(["--merge-path", value]) }
  args.concat(["--plan-digest", plan_digest]) if plan_digest
  args << target
  args
end

def run_bootstrap(target, options, dry_run:, plan_digest: nil)
  Open3.capture3(*bootstrap_args(target, options, dry_run: dry_run, plan_digest: plan_digest))
end

plans = []
targets.each do |target|
  stdout, stderr, status = run_bootstrap(target, options, dry_run: true)
  begin
    plan = JSON.parse(stdout)
    plan["command"] = { "exit_code" => status.exitstatus, "stderr" => stderr.empty? ? nil : stderr }
    plans << plan
    unless options[:json]
      counts = plan["counts"] || {}
      puts "Upgrade plan for #{target}: #{counts.map { |key, value| "#{key}=#{value}" }.sort.join(', ')}"
      puts "Plan digest: #{plan['plan_digest']}" if plan["plan_digest"]
    end
  rescue JSON::ParserError
    plans << { "target" => target, "error" => [stdout, stderr].reject(&:empty?).join("\n"), "exit_code" => status.exitstatus }
  end
  warn stderr unless stderr.empty?
end

has_errors = plans.any? do |plan|
  counts = plan["counts"] || {}
  counts["conflict"].to_i.positive? || plan.key?("error") || plan["status"] == "blocked" || plan["plan_digest"].nil?
end
has_blocking_activity = plans.any? do |plan|
  activity = plan["activity"] || {}
  Array(activity["active_streams"]).any? || Array(activity["lock_paths"]).any?
end

unless options[:apply]
  puts JSON.pretty_generate({ "mode" => "plan", "projects" => plans }) if options[:json]
  exit(has_blocking_activity ? EXIT_BLOCKED : has_errors ? EXIT_REVIEW_REQUIRED : EXIT_OK)
end

plan = plans.first
if options[:plan_digest] && plan["plan_digest"] != options[:plan_digest] && plan["plan_digest"] != "sha256:#{options[:plan_digest]}"
  plan["error"] = "generated plan does not match --plan-digest"
  has_errors = true
end

if has_errors || has_blocking_activity
  error_message = if has_blocking_activity
    "active workflow streams or locks remain; finish them before migration"
  else
    "the plan is blocked or has unresolved conflicts; review and regenerate it"
  end
  puts JSON.pretty_generate({ "mode" => "blocked", "projects" => plans, "error" => error_message }) if options[:json]
  warn "Upgrade not applied: #{error_message}."
  exit(has_blocking_activity ? EXIT_BLOCKED : EXIT_REVIEW_REQUIRED)
end

reviewed_digest = options.fetch(:plan_digest)
stdout, stderr, status = run_bootstrap(targets.first, options, dry_run: false, plan_digest: reviewed_digest)
warn stderr unless stderr.empty?
begin
  result = JSON.parse(stdout)
rescue JSON::ParserError
  result = { "target" => targets.first, "error" => [stdout, stderr].reject(&:empty?).join("\n"), "exit_code" => status.exitstatus }
end

if options[:json]
  mode = status.success? && result["status"] == "installed" ? "applied" : "blocked"
  puts JSON.pretty_generate({ "mode" => mode, "plans" => plans, "projects" => [result] })
else
  if status.success? && result["status"] == "installed"
    puts "Applied workflow kit to #{targets.first}: installed"
  else
    warn "Upgrade failed for #{targets.first}: #{result['error'] || 'unknown error'}"
  end
end

exit(status.success? && result["status"] == "installed" ? EXIT_OK : EXIT_BLOCKED)
