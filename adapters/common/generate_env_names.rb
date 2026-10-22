#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "generator_cli"

options, = WorkflowKit::GeneratorCLI.parse(
  ARGV,
  fact_type: "environment-variables",
  default_globs: ["**/*.rb", "**/*.py", "**/*.js", "**/*.jsx", "**/*.ts", "**/*.tsx", "**/*.env.example", ".env.example"],
)

records = WorkflowKit::GeneratorCLI.source_records(options[:root], options[:ref], options[:source_globs])
names = records.flat_map do |record|
  content = record["content"]
  values = []
  values.concat(content.scan(/ENV\[['\"]([A-Z][A-Z0-9_]*)['\"]\]/).flatten)
  values.concat(content.scan(/process\.env\.([A-Z][A-Z0-9_]*)/).flatten)
  values.concat(content.scan(/os\.environ\[['\"]([A-Z][A-Z0-9_]*)['\"]\]/).flatten)
  values.concat(content.scan(/os\.environ\.get\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]/).flatten)
  values.concat(content.scan(/os\.getenv\(\s*['\"]([A-Z][A-Z0-9_]*)['\"]/).flatten)
  values.concat(content.scan(/^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=/).flatten) if record["path"].include?(".env")
  values
end.uniq.sort

document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "environment-variables", source_globs: options[:source_globs],
  facts: { "names" => names },
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
