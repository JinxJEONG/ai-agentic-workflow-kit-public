#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../common/generator_cli"
require_relative "introspect"

options, = WorkflowKit::GeneratorCLI.parse(
  ARGV,
  fact_type: "postgresql-schema",
  default_globs: ["db/migrations/**", "**/migrations/**", "**/*.sql"],
)
connection = {}
connection_parser = OptionParser.new do |opts|
  opts.on("--url URL") { |value| connection[:url] = value }
  opts.on("--container-id ID") { |value| connection[:container_id] = value }
end
# GeneratorCLI consumes its own options and rejects unknowns, so allow
# connection settings through the environment for the shared gate runner.
connection[:url] ||= ENV["DISPOSABLE_DATABASE_URL"]
connection[:container_id] ||= ENV["DISPOSABLE_DATABASE_CONTAINER_ID"]
unless connection.values.all? { |value| value && !value.empty? }
  warn "DISPOSABLE_DATABASE_URL and DISPOSABLE_DATABASE_CONTAINER_ID are required"
  exit 30
end

begin
  facts = WorkflowKit::PostgresIntrospection.collect(**connection)
rescue WorkflowKit::PostgresIntrospection::Refused => error
  warn error.message
  exit 30
end
document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "postgresql-schema", source_globs: options[:source_globs], facts: facts,
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
