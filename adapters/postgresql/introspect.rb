#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "uri"

module WorkflowKit
  module PostgresIntrospection
    class Refused < StandardError; end
    LOOPBACK_HOSTS = %w[127.0.0.1 ::1].freeze
    DISPOSABLE_LABEL = "org.example.workflow-kit.disposable"
    EXPECTED_IMAGE = "postgres:16-alpine"
    CONTAINER_ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/

    COLUMNS_QUERY = <<~SQL.freeze
      SELECT table_schema, table_name, ordinal_position, column_name,
             data_type, is_nullable
      FROM information_schema.columns
      WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
      ORDER BY table_schema, table_name, ordinal_position;
    SQL

    CONSTRAINTS_QUERY = <<~SQL.freeze
      SELECT tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type,
             COALESCE(kcu.column_name, '')
      FROM information_schema.table_constraints tc
      LEFT JOIN information_schema.key_column_usage kcu
        ON tc.constraint_catalog = kcu.constraint_catalog
       AND tc.constraint_schema = kcu.constraint_schema
       AND tc.constraint_name = kcu.constraint_name
      WHERE tc.table_schema NOT IN ('pg_catalog', 'information_schema')
      ORDER BY tc.table_schema, tc.table_name, tc.constraint_name, kcu.ordinal_position;
    SQL

    module_function

    def command(name)
      ENV.fetch(name.upcase, name)
    end

    def capture(*arguments, env: {})
      stdout, stderr, status = Open3.capture3(env, *arguments)
      raise Refused, "#{File.basename(arguments.first)} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def parse_url(value)
      uri = URI.parse(value.to_s)
      unless %w[postgres postgresql].include?(uri.scheme) && LOOPBACK_HOSTS.include?(uri.host) && uri.port
        raise Refused, "only a PostgreSQL URL published on an explicit loopback port is allowed"
      end
      raise Refused, "database name is required" if uri.path.to_s.sub(%r{\A/}, "").empty?

      uri
    rescue URI::InvalidURIError
      raise Refused, "invalid PostgreSQL URL"
    end

    def verify_container!(container_id, uri)
      raise Refused, "--container-id is required; production endpoints are never inferred" if container_id.to_s.empty?
      unless CONTAINER_ID_PATTERN.match?(container_id.to_s)
        raise Refused, "--container-id must be a Docker container ID or name"
      end

      raw = capture(command("docker"), "inspect", container_id)
      data = JSON.parse(raw)
      record = data.first
      raise Refused, "container inspect returned no record" unless record.is_a?(Hash)
      raise Refused, "container is not running" unless record.dig("State", "Running") == true
      unless record.dig("Config", "Labels", DISPOSABLE_LABEL) == "true"
        raise Refused, "container lacks the disposable-test label"
      end
      raise Refused, "container must use --rm" unless record.dig("HostConfig", "AutoRemove") == true
      unless record.dig("Config", "Image") == EXPECTED_IMAGE
        raise Refused, "container image must be exactly #{EXPECTED_IMAGE}"
      end

      bindings = Array(record.dig("NetworkSettings", "Ports", "5432/tcp"))
      loopback_only = !bindings.empty? && bindings.all? do |binding|
        LOOPBACK_HOSTS.include?(binding["HostIp"].to_s)
      end
      url_binding_matches = bindings.any? do |binding|
        binding["HostIp"].to_s == uri.host && binding["HostPort"].to_i == uri.port
      end
      unless loopback_only && url_binding_matches
        raise Refused, "URL port is not the container's loopback-only PostgreSQL binding"
      end

      true
    rescue JSON::ParserError => error
      raise Refused, "cannot parse docker inspect output: #{error.message}"
    end

    def safe_connection_url(uri)
      clean = uri.dup
      clean.user = URI.encode_www_form_component(uri.user.to_s) unless uri.user.to_s.empty?
      clean.password = nil
      clean.to_s
    end

    def query(uri, sql)
      env = {}
      env["PGPASSWORD"] = URI.decode_www_form_component(uri.password) if uri.password
      capture(
        command("psql"), safe_connection_url(uri),
        "--no-password", "--tuples-only", "--no-align", "--field-separator", "\t",
        "--set", "ON_ERROR_STOP=1", "--command", sql,
        env: env,
      )
    end

    def rows(raw, fields)
      raw.lines.map(&:strip).reject(&:empty?).map do |line|
        values = line.split("\t", -1)
        fields.zip(values).to_h
      end
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical(value[source_key])
        end
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    def content_digest(facts)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(facts)))}"
    end

    def collect(url:, container_id:)
      uri = parse_url(url)
      verify_container!(container_id, uri)
      columns = rows(query(uri, COLUMNS_QUERY), %w[schema table ordinal column data_type nullable])
      constraints = rows(query(uri, CONSTRAINTS_QUERY), %w[schema table name type column])
      {
        "database" => uri.path.sub(%r{\A/}, ""),
        "columns" => columns,
        "constraints" => constraints,
      }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: introspect.rb --url URL --container-id ID"
    opts.on("--url URL") { |value| options[:url] = value }
    opts.on("--container-id ID") { |value| options[:container_id] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.empty? && options[:url]

  begin
    puts JSON.pretty_generate(WorkflowKit::PostgresIntrospection.collect(**options))
  rescue WorkflowKit::PostgresIntrospection::Refused => error
    warn JSON.generate({ "state" => "blocked", "error" => error.message })
    exit 30
  end
end
