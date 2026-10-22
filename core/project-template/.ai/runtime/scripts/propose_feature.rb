#!/usr/bin/env ruby

require "optparse"
require "shellwords"
require_relative "workflow_lib"

options = {
  dry_run: false,
  tier: "tier2",
  area: "unspecified",
  work_type: "feature",
  risk: "medium",
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: propose_feature.rb [options] \"Feature title\""
  opts.on("--dry-run", "Print the command without creating files") { options[:dry_run] = true }
  opts.on("--tier TIER", "Workflow tier") { |value| options[:tier] = value }
  opts.on("--area AREA", "Product/project area") { |value| options[:area] = value }
  opts.on("--work-type TYPE", "Work type") { |value| options[:work_type] = value }
  opts.on("--risk LEVEL", "Risk level") { |value| options[:risk] = value }
  opts.on("--summary TEXT", "Summary") { |value| options[:summary] = value }
end

parser.parse!(ARGV)
title = ARGV.join(" ").strip
if title.empty?
  warn parser
  exit 1
end

command = [
  "ruby",
  File.join(AgentWorkflow::AI_ROOT, "runtime", "scripts", "create_feature.rb"),
  "--no-activate",
  "--tier", options[:tier],
  "--area", options[:area],
  "--work-type", options[:work_type],
  "--risk", options[:risk],
]
command += ["--summary", options[:summary]] if options[:summary]
command << title

if options[:dry_run]
  puts command.shelljoin
  exit 0
end

exec(*command)
