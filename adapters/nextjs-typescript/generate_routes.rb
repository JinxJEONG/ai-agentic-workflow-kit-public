#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../common/generator_cli"

options, = WorkflowKit::GeneratorCLI.parse(
  ARGV,
  fact_type: "nextjs-routes",
  default_globs: ["app/**/page.*", "app/**/route.*", "src/app/**/page.*", "src/app/**/route.*"],
)

records = WorkflowKit::GeneratorCLI.source_records(options[:root], options[:ref], options[:source_globs])
routes = records.map do |record|
  path = record["path"]
  match = path.match(%r{(?:\A|/)(?:src/)?app/(.*?)(?:/)?(page|route)\.[^.]+\z})
  next unless match

  relative = match[1]
  route = "/" + relative.split("/").reject { |part| part.start_with?("(") && part.end_with?(")") }.join("/")
  route = "/" if route == "/"
  methods = if match[2] == "page"
    ["GET"]
  else
    record["content"].scan(/\bexport\s+(?:async\s+)?(?:function|const)\s+(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b/).flatten.uniq.sort
  end
  { "path" => path, "route" => route, "methods" => methods }
end.compact.sort_by { |entry| [entry["route"], entry["path"]] }

document = WorkflowKit::GeneratedDocument.build(
  root: options[:root], ref: options[:ref], rule_id: options[:rule_id],
  fact_type: "nextjs-routes", source_globs: options[:source_globs],
  facts: { "routes" => routes },
)
WorkflowKit::GeneratorCLI.emit(document, options[:output])
