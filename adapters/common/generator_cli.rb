#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"

require_relative "../../engine/facts/generated_document"

module WorkflowKit
  module GeneratorCLI
    module_function

    def parse(argv, fact_type:, default_globs:)
      options = { root: ".", ref: "HEAD", source_globs: default_globs, output: nil, rule_id: fact_type }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
        opts.on("--root DIR") { |value| options[:root] = value }
        opts.on("--ref REF") { |value| options[:ref] = value }
        opts.on("--rule ID") { |value| options[:rule_id] = value }
        opts.on("--source-glob GLOB") { |value| (options[:source_globs] ||= []) << value }
        opts.on("--clear-default-globs") { options[:source_globs] = [] }
        opts.on("--output PATH") { |value| options[:output] = value }
      end
      parser.parse!(argv)
      abort parser.to_s unless argv.empty?
      [options, parser]
    end

    def emit(document, output)
      rendered = JSON.pretty_generate(document) + "\n"
      if output
        root = File.dirname(File.expand_path(output))
        FileUtils.mkdir_p(root)
        File.write(output, rendered)
      else
        $stdout.write(rendered)
      end
    end

    def source_records(root, ref, globs, extensions: nil)
      entries = WorkflowKit::SourceTree.entries(root, globs, ref: ref)
      if extensions
        suffixes = Array(extensions).map(&:to_s)
        entries = entries.select { |entry| suffixes.any? { |suffix| entry.path.end_with?(suffix) } }
      end
      entries.map do |entry|
        { "path" => entry.path, "content" => entry.content.dup.force_encoding(Encoding::UTF_8) }
      end
    end
  end
end
