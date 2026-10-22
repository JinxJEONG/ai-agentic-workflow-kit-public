#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "nested_clone"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: verify_nested_clone.rb [required options]"
  %w[repo central-kit baseline-ref phase3 phase4 checkpoint-root bundle state].each do |name|
    key = name.tr("-", "_").to_sym
    opts.on("--#{name} VALUE") { |value| options[key] = value }
  end
end
parser.parse!(ARGV)
required = %i[repo central_kit baseline_ref phase3 phase4 checkpoint_root bundle state]
abort parser.to_s unless required.all? { |key| options[key] } && ARGV.empty?

result = WorkflowKit::NestedClone.verify(**options)
puts JSON.pretty_generate(result)
exit(result["eligible"] ? 0 : 30)
