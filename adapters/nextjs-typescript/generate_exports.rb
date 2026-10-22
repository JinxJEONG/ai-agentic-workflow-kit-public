#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "../common/generator_cli"

options, = WorkflowKit::GeneratorCLI.parse(
  ARGV,
  fact_type: "typescript-exports",
  default_globs: ["**/*.ts", "**/*.tsx"],
)
records = WorkflowKit::GeneratorCLI.source_records(
  options[:root], options[:ref], options[:source_globs], extensions: [".ts", ".tsx"],
)
node = ENV.fetch("NODE", "node")
helper = File.join(__dir__, "typescript_exports.mjs")
stdout, stderr, status = Open3.capture3(
  node,
  helper,
  stdin_data: JSON.generate({ "root" => File.realpath(options[:root]), "records" => records }),
)
unless status.success?
  warn stderr
  exit(status.exitstatus || 30)
end
facts = JSON.parse(stdout)

document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "typescript-exports", source_globs: options[:source_globs],
  facts: facts,
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
