# frozen_string_literal: true

require "json"
require_relative "test_helper"

class GeneratedFactsTest < Minitest::Test
  def prepare_project(project)
    write_file(File.join(project, "backend", "app", "main.py"), <<~PYTHON)
      from fastapi import FastAPI
      app = FastAPI()
      @app.get("/health")
      def health():
          return {"ok": True}
    PYTHON
    write_file(File.join(project, "src", "app", "api", "items", "route.ts"), <<~TS)
      export async function GET() { return Response.json({ ok: true }) }
      export const POST = async () => Response.json({ ok: true })
    TS
    write_file(File.join(project, "deploy", "manifest.yaml"), "image: example@sha256:deadbeef\n")
    write_file(File.join(project, "db", "migrate", "001_create_items.sql"), "create table items(id bigint primary key);\n")
    write_file(File.join(project, ".env.example"), "PUBLIC_NAME=\nSECRET_VALUE=must-not-appear\n")
    write_file(File.join(project, "backend", "app", "settings.py"), <<~PYTHON)
      import os
      API_KEY = os.getenv("API_KEY", "must-not-appear")
      MODEL = os.environ.get("OPENAI_MODEL", "must-not-appear")
      DIRECT = os.environ["DIRECT_NAME"]
    PYTHON
    commit_all!(project)
  end

  def generate(script, project, *globs)
    command = [
      RbConfig.ruby, File.join(KIT_ROOT, script), "--root", project,
      "--ref", "HEAD", "--rule", "fixture", "--clear-default-globs",
    ]
    globs.each { |glob| command.concat(["--source-glob", glob]) }
    result = run_command(*command, chdir: KIT_ROOT)
    assert result.success?, result.combined
    JSON.parse(result.stdout)
  end

  def test_route_and_symbol_generators_are_deterministic
    with_project do |project|
      prepare_project(project)
      scripts = {
        "adapters/fastapi-alembic/generate_routes.rb" => ["backend/**/*.py"],
        "adapters/fastapi-alembic/generate_symbols.rb" => ["backend/**/*.py"],
        "adapters/nextjs-typescript/generate_routes.rb" => ["src/app/**/route.ts"],
        "adapters/common/generate_deploy_inputs.rb" => ["deploy/**"],
        "adapters/common/generate_migration_checksums.rb" => ["db/migrate/**"],
      }
      scripts.each do |script, globs|
        first = generate(script, project, *globs)
        second = generate(script, project, *globs)
        assert_equal first["content_digest"], second["content_digest"], script
        assert_equal first["source_tree_digest"], second["source_tree_digest"], script
      end
    end
  end

  def test_python_generators_ignore_non_python_files_in_a_broad_rule
    with_project do |project|
      prepare_project(project)
      write_file(
        File.join(project, "backend", "app", "templates", "account.html"),
        "{% if account %}{{ account.name }}{% endif %}\n",
      )
      commit_all!(project, "add backend template")

      routes = generate("adapters/fastapi-alembic/generate_routes.rb", project, "backend/app/**")
      symbols = generate("adapters/fastapi-alembic/generate_symbols.rb", project, "backend/app/**")

      assert_equal ["/health"], routes.dig("facts", "routes").map { |entry| entry["route"] }
      assert_equal "python-ast-v1", routes.dig("facts", "parser")
      assert symbols.dig("facts", "symbols").all? { |entry| entry["path"].end_with?(".py") }
      assert_match(/\Asha256:[0-9a-f]{64}\z/, routes.fetch("source_tree_digest"))
    end
  end

  def test_nextjs_routes_support_monorepo_prefixes_and_ignore_non_routes
    with_project do |project|
      prepare_project(project)
      write_file(
        File.join(project, "apps", "public-web", "src", "app", "news", "[slug]", "page.tsx"),
        "export default function NewsPage() { return null }\n",
      )
      write_file(File.join(project, "apps", "public-web", "package.json"), "{\"private\":true}\n")
      commit_all!(project, "add prefixed next app")

      result = generate(
        "adapters/nextjs-typescript/generate_routes.rb", project, "apps/public-web/**",
      )
      routes = result.dig("facts", "routes")

      assert_equal ["/news/[slug]"], routes.map { |entry| entry["route"] }
      assert_equal ["GET"], routes.first["methods"]
      refute routes.any? { |entry| entry["path"].end_with?("package.json") }
    end
  end

  def test_environment_generator_records_names_not_values
    with_project do |project|
      prepare_project(project)
      result = generate("adapters/common/generate_env_names.rb", project, ".env.example", "backend/**/*.py")
      serialized = JSON.generate(result)
      assert_includes result.dig("facts", "names"), "SECRET_VALUE"
      assert_includes result.dig("facts", "names"), "API_KEY"
      assert_includes result.dig("facts", "names"), "OPENAI_MODEL"
      assert_includes result.dig("facts", "names"), "DIRECT_NAME"
      refute_includes serialized, "must-not-appear"
    end
  end

  def test_typescript_export_generator_fails_closed_without_compiler_api
    with_project do |project|
      prepare_project(project)
      result = run_command(
        RbConfig.ruby, File.join(KIT_ROOT, "adapters", "nextjs-typescript", "generate_exports.rb"),
        "--root", project, "--ref", "HEAD", "--clear-default-globs", "--source-glob", "**/*.ts",
        chdir: KIT_ROOT,
      )
      refute result.success?
      assert_equal 30, result.status.exitstatus
      assert_includes result.stderr, "compiler API"
    end
  end

  def test_migration_generator_records_sorted_paths_and_content_checksums
    with_project do |project|
      prepare_project(project)
      write_file(File.join(project, "db", "migrate", "002_add_name.sql"), "alter table items add column name text;\n")
      commit_all!(project, "add migration")

      result = generate("adapters/common/generate_migration_checksums.rb", project, "db/migrate/**")
      migrations = result.dig("facts", "migrations")
      assert_equal ["db/migrate/001_create_items.sql", "db/migrate/002_add_name.sql"], migrations.map { |entry| entry["path"] }
      assert migrations.all? { |entry| entry["sha256"].match?(/\Asha256:[0-9a-f]{64}\z/) }
      refute_includes JSON.generate(result), "create table items"
    end
  end
end
