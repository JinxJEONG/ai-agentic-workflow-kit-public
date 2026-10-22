#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "source_tree"

module WorkflowKit
  module GeneratedDocument
    GENERATOR_VERSION = "1.0.0"

    module_function

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical(value[source_key])
        end
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def canonical_json(value)
      JSON.generate(canonical(value))
    end

    def build(root:, ref:, rule_id:, fact_type:, source_globs:, facts:, generated_at: Time.now.utc.iso8601)
      entries = WorkflowKit::SourceTree.entries(root, source_globs, ref: ref)
      normalized_facts = canonical(facts)
      commit = WorkflowKit::SourceTree.git(File.realpath(root), "rev-parse", ref).strip
      {
        "generated_schema" => 2,
        "rule_id" => rule_id,
        "fact_type" => fact_type,
        "source_digest_algo" => 1,
        "source_tree_digest" => WorkflowKit::SourceTree.digest(entries),
        "generator_version" => GENERATOR_VERSION,
        "generated_at" => generated_at,
        "content_digest" => "sha256:#{Digest::SHA256.hexdigest(canonical_json(normalized_facts))}",
        "source_commit_hint" => commit,
        "facts" => normalized_facts,
      }
    end
  end
end
