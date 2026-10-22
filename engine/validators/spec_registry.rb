#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

require_relative "schema"
require_relative "../facts/source_tree"

module WorkflowKit
  module SpecRegistry
    KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
    SCHEMA_PATH = File.join(KIT_ROOT, "schemas", "spec-registry.schema.yaml")
    DEFAULT_HIGH_RISK_PATH = File.join(__dir__, "high_risk_paths.yaml")

    module_function

    def load(path)
      data = WorkflowKit::Schema.load_yaml(path)
      errors = validate(data)
      raise ArgumentError, errors.join("\n") unless errors.empty?
      data
    end

    def validate(data)
      schema = WorkflowKit::Schema.load_yaml(SCHEMA_PATH)
      errors = WorkflowKit::Schema.validate(data, schema)
      return errors unless data.is_a?(Hash)

      rules = Array(data["rules"])
      ids = rules.select { |rule| rule.is_a?(Hash) }.map { |rule| rule["id"].to_s }
      ids.group_by(&:itself).each { |id, values| errors << "$.rules: duplicate id #{id.inspect}" if values.length > 1 }

      rules.each_with_index do |rule, index|
        next unless rule.is_a?(Hash)
        sources = Array(rule["source_globs"])
        paths = Array(rule["canonical_specs"]) + Array(rule["generated_facts"])
        paths.each do |path|
          if sources.any? { |glob| WorkflowKit::SourceTree.glob_match?(path.to_s, glob.to_s) }
            errors << "$.rules[#{index}]: self_referencing_rule path=#{path.inspect}"
          end
        end
        Array(rule["generated_facts"]).each do |path|
          unless path.to_s.start_with?(".ai/generated/")
            errors << "$.rules[#{index}].generated_facts: must stay below .ai/generated/"
          end
        end
        Array(rule["codeowners"]).group_by(&:itself).each do |owner, values|
          if values.length > 1
            errors << "$.rules[#{index}].codeowners: duplicate owner #{owner.inspect}"
          end
        end
      end
      errors
    end

    def default_high_risk_globs
      data = WorkflowKit::Schema.load_yaml(DEFAULT_HIGH_RISK_PATH)
      Array(data["high_risk_globs"])
    end

    def matching_rules(registry, path)
      Array(registry["rules"]).select do |rule|
        Array(rule["source_globs"]).any? { |glob| WorkflowKit::SourceTree.glob_match?(path, glob) }
      end
    end
  end
end
