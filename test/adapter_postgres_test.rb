# frozen_string_literal: true

require_relative "test_helper"
require_relative "../adapters/postgresql/introspect"

class AdapterPostgresTest < Minitest::Test
  def test_non_loopback_database_is_refused_before_any_command
    error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
      WorkflowKit::PostgresIntrospection.collect(
        url: "postgres://user:secret@db.example.com/app",
        container_id: "container",
      )
    end
    assert_includes error.message, "loopback"
  end

  def test_container_id_is_mandatory
    error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
      WorkflowKit::PostgresIntrospection.collect(
        url: "postgres://user:secret@127.0.0.1:55432/app",
        container_id: nil,
      )
    end
    assert_includes error.message, "container-id"
  end

  def test_disposable_container_and_metadata_only_query
    Dir.mktmpdir("postgres-adapter-test") do |directory|
      docker = File.join(directory, "docker")
      psql = File.join(directory, "psql")
      write_file(docker, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "State" => { "Running" => true },
          "Config" => {
            "Image" => "postgres:16-alpine",
            "Labels" => { "org.example.workflow-kit.disposable" => "true" }
          },
          "HostConfig" => { "AutoRemove" => true },
          "NetworkSettings" => { "Ports" => { "5432/tcp" => [{ "HostIp" => "127.0.0.1", "HostPort" => "55432" }] } }
        }])
      RUBY
      write_file(psql, <<~RUBY)
        #!/usr/bin/env ruby
        abort "password leaked in argv" if ARGV.join(" ").include?("secret")
        query = ARGV.last
        if query.include?("information_schema.columns")
          puts "public\\twidgets\\t1\\tid\\tbigint\\tNO"
        else
          puts "public\\twidgets\\twidgets_pkey\\tPRIMARY KEY\\tid"
        end
      RUBY
      File.chmod(0o755, docker)
      File.chmod(0o755, psql)

      original_docker = ENV["DOCKER"]
      original_psql = ENV["PSQL"]
      ENV["DOCKER"] = docker
      ENV["PSQL"] = psql
      result = WorkflowKit::PostgresIntrospection.collect(
        url: "postgres://user:secret@127.0.0.1:55432/app",
        container_id: "container",
      )
      assert_equal "app", result["database"]
      assert_equal "widgets", result["columns"].first["table"]
      refute_includes JSON.generate(result), "secret"
      assert_match(/\Asha256:[0-9a-f]{64}\z/, WorkflowKit::PostgresIntrospection.content_digest(result))
    ensure
      ENV["DOCKER"] = original_docker
      ENV["PSQL"] = original_psql
    end
  end

  def test_content_digest_is_independent_of_hash_insertion_order
    first = {
      "database" => "app",
      "columns" => [{ "table" => "widgets", "column" => "id" }],
    }
    second = {
      "columns" => [{ "column" => "id", "table" => "widgets" }],
      "database" => "app",
    }

    assert_equal WorkflowKit::PostgresIntrospection.content_digest(first),
      WorkflowKit::PostgresIntrospection.content_digest(second)
  end

  def test_non_postgres_16_alpine_container_is_refused_before_psql
    Dir.mktmpdir("postgres-image-test") do |directory|
      docker = File.join(directory, "docker")
      write_file(docker, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "State" => { "Running" => true },
          "Config" => {
            "Image" => "postgres:15-alpine",
            "Labels" => { "org.example.workflow-kit.disposable" => "true" }
          },
          "HostConfig" => { "AutoRemove" => true },
          "NetworkSettings" => { "Ports" => { "5432/tcp" => [{ "HostIp" => "127.0.0.1", "HostPort" => "55432" }] } }
        }])
      RUBY
      File.chmod(0o755, docker)

      original_docker = ENV["DOCKER"]
      ENV["DOCKER"] = docker
      error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
        WorkflowKit::PostgresIntrospection.collect(
          url: "postgres://user:secret@127.0.0.1:55432/app",
          container_id: "container",
        )
      end
      assert_includes error.message, "postgres:16-alpine"
    ensure
      ENV["DOCKER"] = original_docker
    end
  end

  def test_container_port_binding_must_match_the_loopback_url
    Dir.mktmpdir("postgres-binding-test") do |directory|
      docker = File.join(directory, "docker")
      write_file(docker, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "State" => { "Running" => true },
          "Config" => {
            "Image" => "postgres:16-alpine",
            "Labels" => { "org.example.workflow-kit.disposable" => "true" }
          },
          "HostConfig" => { "AutoRemove" => true },
          "NetworkSettings" => { "Ports" => { "5432/tcp" => [{ "HostIp" => "127.0.0.1", "HostPort" => "55433" }] } }
        }])
      RUBY
      File.chmod(0o755, docker)

      original_docker = ENV["DOCKER"]
      ENV["DOCKER"] = docker
      error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
        WorkflowKit::PostgresIntrospection.collect(
          url: "postgres://user:secret@127.0.0.1:55432/app",
          container_id: "container",
        )
      end
      assert_includes error.message, "loopback-only PostgreSQL binding"
    ensure
      ENV["DOCKER"] = original_docker
    end
  end

  def test_any_non_loopback_postgres_binding_is_refused
    Dir.mktmpdir("postgres-public-binding-test") do |directory|
      docker = File.join(directory, "docker")
      write_file(docker, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "State" => { "Running" => true },
          "Config" => {
            "Image" => "postgres:16-alpine",
            "Labels" => { "org.example.workflow-kit.disposable" => "true" }
          },
          "HostConfig" => { "AutoRemove" => true },
          "NetworkSettings" => { "Ports" => { "5432/tcp" => [
            { "HostIp" => "127.0.0.1", "HostPort" => "55432" },
            { "HostIp" => "0.0.0.0", "HostPort" => "55432" }
          ] } }
        }])
      RUBY
      File.chmod(0o755, docker)

      original_docker = ENV["DOCKER"]
      ENV["DOCKER"] = docker
      error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
        WorkflowKit::PostgresIntrospection.collect(
          url: "postgres://user:secret@127.0.0.1:55432/app",
          container_id: "container",
        )
      end
      assert_includes error.message, "loopback-only PostgreSQL binding"
    ensure
      ENV["DOCKER"] = original_docker
    end
  end

  def test_container_binding_host_must_match_the_url_host
    Dir.mktmpdir("postgres-host-binding-test") do |directory|
      docker = File.join(directory, "docker")
      write_file(docker, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        puts JSON.generate([{
          "State" => { "Running" => true },
          "Config" => {
            "Image" => "postgres:16-alpine",
            "Labels" => { "org.example.workflow-kit.disposable" => "true" }
          },
          "HostConfig" => { "AutoRemove" => true },
          "NetworkSettings" => { "Ports" => { "5432/tcp" => [{ "HostIp" => "::1", "HostPort" => "55432" }] } }
        }])
      RUBY
      File.chmod(0o755, docker)

      original_docker = ENV["DOCKER"]
      ENV["DOCKER"] = docker
      error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
        WorkflowKit::PostgresIntrospection.collect(
          url: "postgres://user:secret@127.0.0.1:55432/app",
          container_id: "container",
        )
      end
      assert_includes error.message, "loopback-only PostgreSQL binding"
    ensure
      ENV["DOCKER"] = original_docker
    end
  end

  def test_container_id_cannot_be_a_docker_option
    original_docker = ENV["DOCKER"]
    ENV["DOCKER"] = "/command/that/must/not/run"
    error = assert_raises(WorkflowKit::PostgresIntrospection::Refused) do
      WorkflowKit::PostgresIntrospection.collect(
        url: "postgres://user:secret@127.0.0.1:55432/app",
        container_id: "--format={{json .}}",
      )
    end
    assert_includes error.message, "Docker container ID or name"
  ensure
    ENV["DOCKER"] = original_docker
  end
end
