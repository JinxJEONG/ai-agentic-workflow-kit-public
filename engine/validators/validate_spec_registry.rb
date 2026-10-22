#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "spec_registry"

path = ARGV.first
unless path && ARGV.length == 1
  warn "Usage: validate_spec_registry.rb SPEC_REGISTRY.yaml"
  exit 40
end

begin
  data = WorkflowKit::Schema.load_yaml(path)
  errors = WorkflowKit::SpecRegistry.validate(data)
rescue ArgumentError, SystemCallError => error
  errors = [error.message]
end
puts JSON.pretty_generate({ "valid" => errors.empty?, "errors" => errors })
exit(errors.empty? ? 0 : 40)
