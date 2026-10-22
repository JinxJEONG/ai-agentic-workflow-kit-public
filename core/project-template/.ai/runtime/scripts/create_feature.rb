#!/usr/bin/env ruby

require "optparse"
require_relative "workflow_lib"

include AgentWorkflow

options = {
  activate: true,
  baseline_ref: nil,
  workflow_tier: "tier2",
  risk_level: "medium",
  product_area: "unspecified",
  work_type: "feature",
  owner: "human",
  target_repos: ["main"],
  summary: nil,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: create_feature.rb [options] \"Feature title\""
  opts.on("--no-activate", "Do not add the feature to ACTIVE_CONTEXT.yaml") { options[:activate] = false }
  opts.on("--baseline REF", "Git commit used as the feature change-set baseline") { |value| options[:baseline_ref] = value }
  opts.on("--tier TIER", "Workflow tier: tier1, tier2, tier3") { |value| options[:workflow_tier] = value }
  opts.on("--risk LEVEL", "Risk level: low, medium, high") { |value| options[:risk_level] = value }
  opts.on("--area AREA", "Product/project area") { |value| options[:product_area] = value }
  opts.on("--work-type TYPE", "Work type") { |value| options[:work_type] = value }
  opts.on("--owner OWNER", "Human owner") { |value| options[:owner] = value }
  opts.on("--repo REPO", "Target repo key; repeatable") { |value| (options[:target_repos] ||= []) << value }
  opts.on("--summary TEXT", "Feature summary") { |value| options[:summary] = value }
end

parser.parse!(ARGV)
title = ARGV.join(" ").strip
if title.empty?
  warn parser
  exit 1
end

unless AgentWorkflow::WORKFLOW_TIERS.include?(options[:workflow_tier])
  warn "--tier must be one of: #{AgentWorkflow::WORKFLOW_TIERS.join(', ')}"
  exit 1
end

unless %w[low medium high].include?(options[:risk_level])
  warn "--risk must be one of: low, medium, high"
  exit 1
end

FileUtils.mkdir_p(AgentWorkflow::TASKS_ROOT)
feature_id = AgentWorkflow.next_feature_id
slug = AgentWorkflow.slugify(title)
feature_dir = File.join(AgentWorkflow::TASKS_ROOT, "#{feature_id}--#{slug}")
if File.exist?(feature_dir)
  warn "Feature directory already exists: #{feature_dir}"
  exit 1
end

streams_by_tier = {
  "tier1" => [["docs-sync", "docs-sync", "ai-worker"]],
  "tier2" => [
    ["architect", "architecture", "architect"],
    ["backend-dev", "implementation", "backend"],
    ["frontend-dev", "implementation", "frontend"],
    ["reviewer", "review", "reviewer"],
    ["docs-sync", "docs-sync", "ai-worker"],
  ],
  "tier3" => [
    ["architect", "architecture", "architect"],
    ["backend-dev", "implementation", "backend"],
    ["frontend-dev", "implementation", "frontend"],
    ["db-design", "data", "architect"],
    ["reviewer", "review", "reviewer"],
    ["docs-sync", "docs-sync", "ai-worker"],
  ],
}

service_paths = AgentWorkflow.project_map.fetch("services", {}).each_with_object(Hash.new { |h, k| h[k] = [] }) do |(name, spec), acc|
  path = spec.is_a?(Hash) ? spec["path"].to_s : ""
  next if path.empty?

  label = [name, spec["role"], spec["stack"]].compact.join(" ").downcase
  if label.match?(/front|web|client|ui/)
    acc["frontend"] << path
  elsif label.match?(/back|api|server/)
    acc["backend"] << path
  end
end

default_backend = service_paths["backend"].empty? ? %w[backend apps/api services/api src/server] : service_paths["backend"]
default_frontend = service_paths["frontend"].empty? ? %w[frontend apps/web src/app src/components] : service_paths["frontend"]
feature_relative_dir = AgentWorkflow.relative_to_root(feature_dir)
requested_baseline = options[:baseline_ref].to_s.strip
requested_baseline = "HEAD" if requested_baseline.empty?
baseline_ref = AgentWorkflow.resolve_git_commit(requested_baseline)
unless baseline_ref
  warn "--baseline must resolve to an existing Git commit: #{requested_baseline}"
  exit 1
end

tree_scope = lambda do |path|
  value = path.to_s.sub(%r{\A\./}, "").sub(%r{/+\z}, "")
  value.empty? || value == "." ? "**" : "#{value}/**"
end

implementation_scope_for = lambda do |stream_id, profile|
  if stream_id == "db-design"
    next %w[db/** database/** migrations/** prisma/** supabase/**]
  end

  case profile
  when "backend"
    default_backend.map { |path| tree_scope.call(path) }
  when "frontend"
    default_frontend.map { |path| tree_scope.call(path) }
  when "architect"
    [
      ".ai/canonical/architecture/**",
      ".ai/canonical/decisions/**",
      ".ai/canonical/PROJECT_RULES.md",
    ]
  when "reviewer"
    []
  else
    [
      ".ai/canonical/**",
      ".ai/runtime/templates/**",
      ".ai/runtime/githooks/**",
      "AGENTS.md",
    ]
  end
end

shared_scope_for = lambda do |stream_id, profile|
  if stream_id == "db-design"
    [File.join(feature_relative_dir, "contracts", "db.md")]
  elsif profile == "architect" || (stream_id == "docs-sync" && options[:workflow_tier] == "tier1")
    scopes = [
      File.join(feature_relative_dir, "feature.yaml"),
      File.join(feature_relative_dir, "change-set.yaml"),
      File.join(feature_relative_dir, "spec.md"),
      File.join(feature_relative_dir, "contracts", "api.md"),
      File.join(feature_relative_dir, "contracts", "acceptance.md"),
    ]
    if stream_id == "docs-sync" && options[:workflow_tier] == "tier1"
      scopes << File.join(feature_relative_dir, "contracts", "db.md")
    end
    scopes
  else
    []
  end
end

read_scope = [
  ".ai/canonical/**",
  File.join(feature_relative_dir, "feature.yaml"),
  File.join(feature_relative_dir, "spec.md"),
  File.join(feature_relative_dir, "contracts/**"),
  File.join(feature_relative_dir, "streams/**"),
]

FileUtils.mkdir_p(File.join(feature_dir, "contracts"))
FileUtils.mkdir_p(File.join(feature_dir, "streams"))

feature = {
  "schema_version" => 2,
  "feature_id" => feature_id,
  "feature_slug" => slug,
  "title" => title,
  "status" => "draft",
  "summary" => options[:summary] || title,
  "product_area" => options[:product_area],
  "work_type" => options[:work_type],
  "risk_level" => options[:risk_level],
  "workflow_tier" => options[:workflow_tier],
  "baseline_ref" => baseline_ref,
  "risk_signals" => {
    "database" => false,
    "authentication" => false,
    "authorization" => false,
    "payments" => false,
    "privacy" => false,
    "personal_data" => false,
    "deployment" => false,
    "environment" => false,
    "secrets" => false,
    "permissions" => false,
    "data_migration" => false,
  },
  "required_approvals" => {
    "reviewer" => options[:workflow_tier] != "tier1",
    "human" => options[:workflow_tier] == "tier3",
  },
  "feature_owner" => options[:owner],
  "target_repos" => options[:target_repos].uniq,
  "collaborators" => [],
  "contracts" => {
    "api" => File.join(feature_relative_dir, "contracts", "api.md"),
    "db" => File.join(feature_relative_dir, "contracts", "db.md"),
    "acceptance" => File.join(feature_relative_dir, "contracts", "acceptance.md"),
  },
  "streams" => streams_by_tier.fetch(options[:workflow_tier]).map(&:first),
  "change_set" => File.join(feature_relative_dir, "change-set.yaml"),
  "doc_impact" => {
    "must_update" => [],
    "no_impact_reason" => "No canonical documentation impact is declared at feature creation; update this assessment when implementation scope is finalized.",
    "legacy_review" => ["AGENTS.md"],
    "generated_from_code" => [],
    "drift_risk" => options[:workflow_tier] == "tier3" ? "high" : "medium",
  },
  "notes" => ["Created from AI Agentic Workflow Kit on #{Date.today}."],
}

AgentWorkflow.write_yaml(File.join(feature_dir, "feature.yaml"), feature)
AgentWorkflow.write_yaml(File.join(feature_dir, "change-set.yaml"), {
  "schema_version" => 1,
  "baseline_ref" => baseline_ref,
  "features" => [{
    "feature_id" => feature_id,
    "streams" => streams_by_tier.fetch(options[:workflow_tier]).map(&:first),
  }],
  "change_set_digest" => nil,
  "status" => "draft",
})
AgentWorkflow.atomic_write(File.join(feature_dir, "spec.md"), "# #{title}\n\n## Summary\n\n#{feature["summary"]}\n\n## Scope\n\nTBD\n")
AgentWorkflow.atomic_write(File.join(feature_dir, "contracts", "api.md"), "# API Contract\n\nNo API contract changes recorded yet.\n")
AgentWorkflow.atomic_write(File.join(feature_dir, "contracts", "db.md"), "# DB Contract\n\nNo DB contract changes recorded yet.\n")
AgentWorkflow.atomic_write(File.join(feature_dir, "contracts", "acceptance.md"), "# Acceptance Contract\n\n- TBD\n")

streams_by_tier.fetch(options[:workflow_tier]).each do |stream_id, stream_type, profile|
  dir = File.join(feature_dir, "streams", stream_id)
  FileUtils.mkdir_p(dir)
  state_write_scope = %w[manifest.yaml plan.md handoff.md evidence.yaml].map { |name| File.join(AgentWorkflow.relative_to_root(dir), name) }
  state_write_scope << File.join(AgentWorkflow.relative_to_root(dir), "review.yaml") if profile == "reviewer"
  implementation_scope = implementation_scope_for.call(stream_id, profile).uniq
  shared_write_scope = shared_scope_for.call(stream_id, profile).uniq
  manifest = {
    "feature_id" => feature_id,
    "stream_id" => stream_id,
    "stream_type" => stream_type,
    "title" => "#{stream_id} stream",
    "status" => "planned",
    "owner_agent" => nil,
    "human_owner" => options[:owner],
    "assigned_to" => nil,
    "handoff_required" => true,
    "review_required" => options[:workflow_tier] != "tier1",
    "created" => Date.today.to_s,
    "last_updated" => Date.today.to_s,
    "agent_profile" => profile,
    "scope_version" => 2,
    "canonical_inputs" => [
      ".ai/canonical/PROJECT_RULES.md",
      ".ai/canonical/ENV_MATRIX.yaml",
      ".ai/canonical/PROJECT_MAP.yaml",
      ".ai/canonical/context-map.yaml",
    ],
    "contract_inputs" => feature["contracts"].values,
    "depends_on" => [],
    "read_scope" => read_scope.uniq,
    "write_scope" => implementation_scope,
    "state_write_scope" => state_write_scope,
    "shared_write_scope" => shared_write_scope,
    "validation_scope" => [
      "ruby .ai/runtime/scripts/validate_agent_structure.rb",
      "ruby .ai/runtime/scripts/validate_docs_sync.rb --active-registry --full",
    ],
    "doc_scope" => {
      "can_edit" => (implementation_scope + shared_write_scope + state_write_scope).uniq,
      "must_update" => [File.join(AgentWorkflow.relative_to_root(dir), "handoff.md")],
      "must_review" => [".ai/canonical/PROJECT_RULES.md"],
    },
    "parallel_allowed" => stream_id != "docs-sync",
    "acceptance_criteria" => ["Stream work is complete and validation passes."],
    "blocked_by" => [],
    "notes" => [],
  }
  AgentWorkflow.write_yaml(File.join(dir, "manifest.yaml"), manifest)
  AgentWorkflow.write_yaml(File.join(dir, "evidence.yaml"), {
    "schema_version" => 1,
    "feature_id" => feature_id,
    "stream_id" => stream_id,
    "validated_revision" => {
      "type" => "change_set_digest",
      "value" => nil,
      "baseline_ref" => baseline_ref,
    },
    "implementation_complete" => false,
    "acceptance_complete" => false,
    "docs_synced" => false,
    "validations" => [],
    "remaining_drift" => ["Not evaluated."],
  })
  if profile == "reviewer"
    AgentWorkflow.write_yaml(File.join(dir, "review.yaml"), {
      "schema_version" => 1,
      "feature_id" => feature_id,
      "reviewed_revision" => {
        "type" => "change_set_digest",
        "value" => nil,
        "baseline_ref" => baseline_ref,
      },
      "reviewer_profile" => "reviewer",
      "reviewer_owner_agent" => nil,
      "status" => "pending",
      "reviewed_at" => nil,
      "findings_open" => nil,
      "human_approval" => {
        "required" => options[:workflow_tier] == "tier3",
        "status" => options[:workflow_tier] == "tier3" ? "pending" : "not_required",
      },
    })
  end
  AgentWorkflow.atomic_write(File.join(dir, "plan.md"), "# Plan\n\n- Read context.\n- Execute scoped work.\n- Validate and hand off.\n")
  AgentWorkflow.atomic_write(File.join(dir, "handoff.md"), "# Handoff\n\n## Status\n\nNot started.\n\n## Validation\n\n- Pending\n\n## Doc Sync\n\n- Canonical updated: no\n- Remaining drift:\n  - none\n")
end

if options[:activate]
  AgentWorkflow.update_active_context do |context|
    context["active_features"] ||= []
    unless context["active_features"].any? { |entry| entry["feature_id"] == feature_id }
      context["active_features"] << {
        "feature_id" => feature_id,
        "path" => feature_dir,
        "title" => title,
        "state" => "draft",
      }
    end
  end
end

puts "Created #{feature_id} at #{feature_dir}"
