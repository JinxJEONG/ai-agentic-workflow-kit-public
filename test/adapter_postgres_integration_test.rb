# frozen_string_literal: true

require "securerandom"
require "uri"

require_relative "test_helper"
require_relative "../adapters/postgresql/introspect"

# Opt-in only: this test never pulls, starts, or removes a container. The caller
# must provide an already-running postgres:16-alpine container created with
# --rm, a loopback-only published port, and
# --label org.example.workflow-kit.disposable=true.
class AdapterPostgresIntegrationTest < Minitest::Test
  ENABLE_ENV = "WORKFLOW_KIT_REAL_POSTGRES_TEST"
  URL_ENV = "DISPOSABLE_DATABASE_URL"
  CONTAINER_ENV = "DISPOSABLE_DATABASE_CONTAINER_ID"

  def setup
    skip "set #{ENABLE_ENV}=1 to verify an already-running disposable PostgreSQL container" unless ENV[ENABLE_ENV] == "1"

    @url = required_env(URL_ENV)
    @container_id = required_env(CONTAINER_ENV)
  end

  def required_env(name)
    value = ENV[name].to_s
    flunk "#{name} is required when #{ENABLE_ENV}=1" if value.empty?
    value
  end

  def execute_sql(sql, assert_success: true)
    uri = WorkflowKit::PostgresIntrospection.parse_url(@url)
    WorkflowKit::PostgresIntrospection.verify_container!(@container_id, uri)
    env = {}
    env["PGPASSWORD"] = URI.decode_www_form_component(uri.password) if uri.password
    result = run_command(
      WorkflowKit::PostgresIntrospection.command("psql"),
      WorkflowKit::PostgresIntrospection.safe_connection_url(uri),
      "--no-password",
      "--set", "ON_ERROR_STOP=1",
      "--command", sql,
      env: env,
    )
    assert result.success?, result.combined if assert_success
    result
  end

  def collect
    WorkflowKit::PostgresIntrospection.collect(url: @url, container_id: @container_id)
  end

  def test_real_disposable_container_is_deterministic_and_metadata_only
    first = collect
    second = collect
    first_digest = WorkflowKit::PostgresIntrospection.content_digest(first)
    assert_equal first_digest, WorkflowKit::PostgresIntrospection.content_digest(second)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, first_digest)

    missing = "workflow-kit-missing-#{Process.pid}-#{SecureRandom.hex(6)}"
    error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
      WorkflowKit::PostgresIntrospection.collect(url: @url, container_id: missing)
    end
    assert_match(/docker failed/, error.message)

    table = "workflow_kit_probe_#{Process.pid}_#{SecureRandom.hex(6)}"
    row_public = "row-public-content-must-not-appear"
    row_secret = "row-secret-content-must-not-appear"
    execute_sql("DROP TABLE IF EXISTS #{table}")
    begin
      execute_sql(<<~SQL)
        CREATE TABLE #{table} (
          id bigint PRIMARY KEY,
          public_note text,
          secret_payload text
        );
        INSERT INTO #{table} (id, public_note, secret_payload)
        VALUES (1, '#{row_public}', '#{row_secret}');
      SQL

      after_migration = collect
      after_digest = WorkflowKit::PostgresIntrospection.content_digest(after_migration)
      refute_equal first_digest, after_digest

      serialized = JSON.generate(after_migration)
      refute_includes serialized, row_public
      refute_includes serialized, row_secret
      password = URI.parse(@url).password
      refute_includes serialized, URI.decode_www_form_component(password) if password
      assert_equal URI.parse(@url).path.delete_prefix("/"), after_migration.fetch("database")
    ensure
      execute_sql("DROP TABLE IF EXISTS #{table}", assert_success: false)
    end
  end
end
