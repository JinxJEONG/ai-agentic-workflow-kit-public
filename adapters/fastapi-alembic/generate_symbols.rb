#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../common/generator_cli"
require "open3"

options, = WorkflowKit::GeneratorCLI.parse(ARGV, fact_type: "python-symbols", default_globs: ["**/*.py"])
records = WorkflowKit::GeneratorCLI.source_records(
  options[:root], options[:ref], options[:source_globs], extensions: [".py"],
)
helper = File.join(__dir__, "python_facts.py")
stdout, stderr, status = Open3.capture3(
  ENV.fetch("PYTHON", "python3"), helper,
  stdin_data: JSON.generate({ "mode" => "symbols", "records" => records }),
)
unless status.success?
  warn stderr
  exit(status.exitstatus || 30)
end
parsed = JSON.parse(stdout)

document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "python-symbols", source_globs: options[:source_globs],
  facts: parsed,
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
