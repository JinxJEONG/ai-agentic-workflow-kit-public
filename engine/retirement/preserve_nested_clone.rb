#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "nested_clone"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: preserve_nested_clone.rb --repo DIR --destination FILE"
  opts.on("--repo DIR") { |value| options[:repo] = value }
  opts.on("--destination FILE") { |value| options[:destination] = value }
end
parser.parse!(ARGV)
abort parser.to_s unless options.values_at(:repo, :destination).all? && ARGV.empty?

begin
  puts JSON.pretty_generate(WorkflowKit::NestedClone.preserve(**options))
rescue ArgumentError => error
  warn error.message
  exit 30
end
