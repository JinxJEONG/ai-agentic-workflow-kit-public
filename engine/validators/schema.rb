#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "uri"
require "yaml"

module WorkflowKit
  # Small, dependency-free validator for the harness-schema/v1 dialect.
  # The dialect intentionally covers only the primitives used by this kit so
  # validation behaves identically on the Ruby versions supported by the kit.
  module Schema
    DIALECT = "harness-schema/v1"

    module_function

    def load_yaml(path)
      YAML.safe_load(
        File.read(path),
        permitted_classes: [],
        permitted_symbols: [],
        aliases: false,
      )
    rescue Psych::Exception => error
      raise ArgumentError, "cannot parse YAML #{path}: #{error.message}"
    end

    def validate_file(document_path, schema_path)
      document = load_yaml(document_path)
      schema = load_yaml(schema_path)
      validate(document, schema)
    end

    def validate(document, schema)
      unless schema.is_a?(Hash) && schema["dialect"] == DIALECT
        return ["$: schema dialect must be #{DIALECT.inspect}"]
      end

      errors = []
      validate_node(document, schema, "$", errors)
      errors
    end

    def validate_node(value, schema, path, errors)
      unless schema.is_a?(Hash)
        errors << "#{path}: schema node must be a mapping"
        return
      end

      if schema.key?("const") && value != schema["const"]
        errors << "#{path}: must equal #{schema['const'].inspect}"
      end

      if schema["enum"].is_a?(Array) && !schema["enum"].include?(value)
        errors << "#{path}: must be one of #{schema['enum'].map(&:inspect).join(', ')}"
      end

      type = schema["type"]
      return errors << "#{path}: must be #{type}" unless type_matches?(value, type)

      case type
      when "mapping"
        validate_mapping(value, schema, path, errors)
      when "sequence"
        validate_sequence(value, schema, path, errors)
      when "string"
        validate_string(value, schema, path, errors)
      when "integer"
        minimum = schema["minimum"]
        errors << "#{path}: must be >= #{minimum}" if minimum && value < minimum
      end
    end

    def type_matches?(value, type)
      case type
      when nil, "any" then true
      when "mapping" then value.is_a?(Hash)
      when "sequence" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else false
      end
    end

    def validate_mapping(value, schema, path, errors)
      Array(schema["required"]).each do |key|
        errors << "#{path}.#{key}: is required" unless value.key?(key)
      end

      properties = schema["properties"].is_a?(Hash) ? schema["properties"] : {}
      value.each do |key, child|
        child_schema = properties[key]
        if child_schema
          validate_node(child, child_schema, "#{path}.#{key}", errors)
        elsif schema["additional_properties"] == false
          errors << "#{path}.#{key}: is not allowed"
        end
      end
    end

    def validate_sequence(value, schema, path, errors)
      minimum = schema["min_items"]
      errors << "#{path}: must contain at least #{minimum} item(s)" if minimum && value.length < minimum

      item_schema = schema["items"]
      return unless item_schema

      value.each_with_index do |child, index|
        validate_node(child, item_schema, "#{path}[#{index}]", errors)
      end
    end

    def validate_string(value, schema, path, errors)
      minimum = schema["min_length"]
      errors << "#{path}: must contain at least #{minimum} character(s)" if minimum && value.length < minimum

      pattern = schema["pattern"]
      if pattern && !Regexp.new(pattern).match?(value)
        errors << "#{path}: does not match required pattern"
      end

      return unless schema["format"]

      errors << "#{path}: is not a valid #{schema['format']}" unless valid_format?(value, schema["format"])
    rescue RegexpError => error
      errors << "#{path}: schema has invalid pattern: #{error.message}"
    end

    def valid_format?(value, format)
      case format
      when "sha256"
        value.match?(/\Asha256:[0-9a-f]{64}\z/)
      when "git-object"
        value.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
      when "relative-path"
        relative_path?(value)
      when "uri"
        parsed = URI.parse(value)
        !parsed.scheme.to_s.empty?
      else
        false
      end
    rescue URI::InvalidURIError
      false
    end

    def relative_path?(value)
      return false if value.empty? || Pathname.new(value).absolute?
      return false if value.split(/[\\\/]/).include?("..")

      Pathname.new(value).cleanpath.to_s == value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  document_path, schema_path = ARGV
  unless document_path && schema_path && ARGV.length == 2
    warn "Usage: schema.rb DOCUMENT.yaml SCHEMA.yaml"
    exit 40
  end

  begin
    errors = WorkflowKit::Schema.validate_file(document_path, schema_path)
  rescue ArgumentError, SystemCallError => error
    warn JSON.generate({ "valid" => false, "errors" => [error.message] })
    exit 40
  end
  puts JSON.pretty_generate({ "valid" => errors.empty?, "errors" => errors })
  exit(errors.empty? ? 0 : 40)
end
