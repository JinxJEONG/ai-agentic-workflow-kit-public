#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require_relative "generator_cli"

options, = WorkflowKit::GeneratorCLI.parse(
  ARGV,
  fact_type: "migration-checksums",
  default_globs: [
    "db/migrate/**",
    "db/migrations/**",
    "migrations/**",
    "**/migrations/**",
    "**/alembic/versions/**",
  ],
)

migrations = WorkflowKit::GeneratorCLI.source_records(
  options[:root], options[:ref], options[:source_globs],
).map do |record|
  {
    "path" => record["path"],
    "sha256" => "sha256:#{Digest::SHA256.hexdigest(record['content'])}",
  }
end.sort_by { |entry| entry["path"] }

document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "migration-checksums", source_globs: options[:source_globs],
  facts: { "migrations" => migrations },
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
