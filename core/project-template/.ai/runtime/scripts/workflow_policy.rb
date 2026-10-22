#!/usr/bin/env ruby

require_relative "workflow_lib"
require_relative "workflow_evidence"

module WorkflowPolicy
  DEFAULT_TIER3_PATTERNS = [
    "db/**",
    "database/**",
    "migrations/**",
    "prisma/**",
    "supabase/**",
    "deploy/**",
    "deployment/**",
    "infra/**",
    "infrastructure/**",
    ".github/workflows/**",
    "Dockerfile",
    "**/Dockerfile",
    "docker-compose*.yml",
    "docker-compose*.yaml",
    "**/auth/**",
    "**/authentication/**",
    "**/authorization/**",
    "**/permissions/**",
    "**/payments/**",
    "**/billing/**",
    "**/secrets/**",
    ".env",
    ".env.*",
  ].freeze
  DEFAULT_TIER3_RISK_SIGNALS = %w[
    database
    authentication
    authorization
    payments
    privacy
    personal_data
    deployment
    environment
    secrets
    permissions
    data_migration
  ].freeze
  TIER_RANK = { "tier1" => 1, "tier2" => 2, "tier3" => 3 }.freeze

  module_function

  def tier3_patterns
    (DEFAULT_TIER3_PATTERNS + Array(AgentWorkflow.project_map["tier3_path_patterns"])).uniq
  end

  def tier3_risk_signal_names
    configured = Array(AgentWorkflow.project_map["tier3_risk_signals"])
    (DEFAULT_TIER3_RISK_SIGNALS + configured.map(&:to_s)).uniq
  end

  def tier3_path?(path)
    rel = AgentWorkflow.relative_to_root(path) || path.to_s.sub(%r{\A\./}, "")
    tier3_patterns.any? { |pattern| AgentWorkflow.path_glob_match?(rel, pattern) }
  end

  def feature_tier(feature)
    tier = feature["workflow_tier"].to_s
    AgentWorkflow::WORKFLOW_TIERS.include?(tier) ? tier : "tier2"
  end

  def truthy?(value)
    value == true || value.to_s.downcase == "true"
  end

  def active_risk_signals(feature)
    signals = feature["risk_signals"].is_a?(Hash) ? feature["risk_signals"] : {}
    tier3_risk_signal_names.select { |name| truthy?(signals[name]) }
  end

  def required_approvals(feature, effective_tier)
    declared = feature["required_approvals"].is_a?(Hash) ? feature["required_approvals"] : {}
    {
      "reviewer" => effective_tier == "tier3" || truthy?(declared["reviewer"]),
      "human" => effective_tier == "tier3" || truthy?(declared["human"]),
    }
  end

  def review_gate_passed?(feature_dir)
    return false unless feature_dir

    feature_id = AgentWorkflow.feature_id_from_task_folder(feature_dir)
    feature = AgentWorkflow.load_yaml(File.join(feature_dir, "feature.yaml"), {})
    tier = feature_tier(feature)
    required = required_approvals(feature, tier)
    errors, = WorkflowEvidence.review_errors(feature_id, require_human: required["human"])
    errors.empty?
  rescue StandardError
    false
  end

  def evaluate(feature_id, finish: false, paths: [])
    feature_dir = AgentWorkflow.resolve_feature_dir(feature_id)
    unless feature_dir
      return {
        "feature_id" => feature_id,
        "errors" => [{ "code" => "POLICY_FEATURE_MISSING", "message" => "Missing feature #{feature_id}" }],
      }
    end

    feature = AgentWorkflow.load_yaml(File.join(feature_dir, "feature.yaml"), {})
    declared_tier = feature_tier(feature)
    normalized_paths = Array(paths).map(&:to_s).reject(&:empty?).uniq
    tier3_paths = normalized_paths.select { |path| tier3_path?(path) }
    risk_signals = active_risk_signals(feature)
    detected_tier = (!tier3_paths.empty? || !risk_signals.empty?) ? "tier3" : declared_tier
    effective_tier = TIER_RANK.fetch(detected_tier) > TIER_RANK.fetch(declared_tier) ? detected_tier : declared_tier
    approvals = required_approvals(feature, effective_tier)
    errors = []

    if effective_tier == "tier3" && declared_tier != "tier3"
      reasons = []
      reasons << "paths=#{tier3_paths.join(', ')}" unless tier3_paths.empty?
      reasons << "risk_signals=#{risk_signals.join(', ')}" unless risk_signals.empty?
      errors << {
        "code" => "POLICY_TIER_TOO_LOW",
        "message" => "#{feature_id} declares #{declared_tier}, but actual risk requires tier3 (#{reasons.join('; ')})",
        "paths" => tier3_paths,
        "risk_signals" => risk_signals,
      }
    end

    if finish && approvals["reviewer"]
      review_errors, = WorkflowEvidence.review_errors(feature_id, require_human: approvals["human"])
      review_errors.each do |message|
        code = message.include?("stale") || message.include?("current change-set") ? "POLICY_REVIEW_STALE" :
          (message.include?("human") ? "POLICY_HUMAN_APPROVAL_REQUIRED" : "POLICY_REVIEW_REQUIRED")
        errors << { "code" => code, "message" => message }
      end
    end

    {
      "feature_id" => feature_id,
      "feature_dir" => feature_dir,
      "declared_tier" => declared_tier,
      "detected_tier" => detected_tier,
      "effective_tier" => effective_tier,
      "tier3_paths" => tier3_paths,
      "risk_signals" => risk_signals,
      "required_approvals" => approvals,
      "errors" => errors,
    }
  end

  # Backwards-compatible interface used by existing scripts and adopters.
  def validation_errors(feature_id, finish: false, paths: [])
    result = evaluate(feature_id, finish: finish, paths: paths)
    errors = Array(result["errors"]).map { |entry| "#{entry['code']}: #{entry['message']}" }
    info = {
      "tier" => result["effective_tier"],
      "declared_tier" => result["declared_tier"],
      "detected_tier" => result["detected_tier"],
      "tier3_paths" => Array(result["tier3_paths"]),
      "risk_signals" => Array(result["risk_signals"]),
      "required_approvals" => result["required_approvals"] || {},
      "feature_dir" => result["feature_dir"],
      "error_details" => Array(result["errors"]),
    }
    [errors, info]
  end
end
