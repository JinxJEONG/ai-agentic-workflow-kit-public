# frozen_string_literal: true

require_relative "test_helper"
require_relative "../fixtures/build_fixture"
require_relative "../engine/resolver/project_context"

class ContextIsolationTest < Minitest::Test
  ISOLATION_CHECKS = {
    "I-1" => "Git root reused from the previous project",
    "I-2" => "repository fingerprint reused from the previous project",
    "I-3" => "service names reused from the previous project",
    "I-4" => "database name reused from the previous project",
    "I-5" => "API prefix reused from the previous project",
    "I-6" => "canonical path reused from the previous project",
    "I-7" => "memory scope reused from the previous project",
    "I-8" => "environment-variable name reused from the previous project",
    "I-9" => "plan target reused from the previous project",
  }.freeze

  def with_fixture(type)
    fixture = WorkflowKit::FixtureBuilder.build(
      type,
      parent: WorkflowKitTestHelpers::FIXTURES_ROOT,
    )
    yield fixture.fetch("path")
  ensure
    WorkflowKit::FixtureBuilder.cleanup(fixture) if fixture
  end

  def with_isolation_fixtures
    with_fixture("isolation-alpha") do |alpha|
      with_fixture("isolation-beta") do |beta|
        yield alpha, beta
      end
    end
  end

  def context_resolver
    ->(path) { WorkflowKit::ProjectContext.build(path) }
  end

  def plan_resolver
    lambda do |path|
      result = bootstrap_plan(path)
      raise "cannot build isolation plan: #{result.combined}" unless result.success?

      JSON.parse(result.stdout)
    end
  end

  def absolute_canonical_paths(context)
    root = context.fetch("root").to_s
    Array(context["canonical_paths"]).map do |path|
      File.expand_path(path.to_s, root)
    end
  end

  def isolation_violations(source, target, resolve_context:, resolve_plan:)
    source_root = File.realpath(source)
    source_side = File.basename(source_root).delete_prefix("isolation-")

    # Enter the source first, then switch roots in the same resolver/session.
    # A process-global cache variant will return this source state for target.
    source_context = resolve_context.call(source)
    resolve_plan.call(source)
    target_context = resolve_context.call(target)
    target_plan = resolve_plan.call(target)
    target_services = target_context["services"].is_a?(Hash) ? target_context["services"] : {}
    canonical_paths = absolute_canonical_paths(target_context)

    checks = {
      "I-1" => target_context["root"].to_s.include?(source_root),
      "I-2" => target_context["repository_fingerprint"] == source_context["repository_fingerprint"],
      "I-3" => target_services.keys.any? { |name| name.to_s.start_with?(source_side) },
      "I-4" => target_context["database"].to_s.include?("#{source_side}_db"),
      "I-5" => target_context["api_prefix"].to_s.include?("/api/#{source_side}"),
      "I-6" => canonical_paths.any? { |path| path.start_with?("#{source_root}/.ai/") },
      "I-7" => target_context["memory_scope"].to_s.include?(source_context["project_id"].to_s),
      "I-8" => Array(target_context["environment_variable_names"]).include?("#{source_side.upcase}_ONLY_VAR"),
      "I-9" => JSON.generate(target_plan.fetch("target", {})).include?(source_root),
    }

    checks.select { |_id, failed| failed }.keys
  end

  def assert_bidirectional_isolation(alpha, beta, resolve_context: context_resolver, resolve_plan: plan_resolver)
    violations = [
      [alpha, beta],
      [beta, alpha],
    ].flat_map do |source, target|
      isolation_violations(
        source,
        target,
        resolve_context: resolve_context,
        resolve_plan: resolve_plan,
      ).map { |id| "#{id} #{File.basename(source)} -> #{File.basename(target)}: #{ISOLATION_CHECKS.fetch(id)}" }
    end

    assert_empty violations, "cross-project context contamination:\n#{violations.join("\n")}"
  end

  def test_i1_through_i9_are_isolated_in_both_directions
    with_isolation_fixtures do |alpha, beta|
      assert_bidirectional_isolation(alpha, beta)
    end
  end

  def test_session_re_resolves_when_current_git_root_changes
    with_isolation_fixtures do |alpha, beta|
      contexts = [alpha, beta, alpha].map do |root|
        Dir.chdir(root) { WorkflowKit::ProjectContext.build(".") }
      end

      assert_equal [File.realpath(alpha), File.realpath(beta), File.realpath(alpha)],
        contexts.map { |context| context.fetch("root") }
      assert_equal contexts[0].fetch("repository_fingerprint"), contexts[2].fetch("repository_fingerprint")
      refute_equal contexts[0].fetch("repository_fingerprint"), contexts[1].fetch("repository_fingerprint")
      assert_equal %w[isolation-alpha isolation-beta isolation-alpha],
        contexts.map { |context| context.fetch("project_id") }
    end
  end

  def test_unknown_project_fails_closed_for_sensitive_operation
    with_fixture("unknown-project") do |path|
      error = assert_raises(WorkflowKit::ContextError) do
        WorkflowKit::ProjectContext.build(path, operation: "database")
      end
      assert_includes error.message, "refusing to infer"
    end
  end

  def test_draft_project_context_fails_closed_for_sensitive_operation
    with_project(prefix: "context-draft") do |project|
      write_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml"), {
        "status" => "draft",
        "project_id" => "draft",
        "workspace" => { "name" => "draft", "root" => project },
        "services" => { "api" => { "path" => "." } },
      })
      commit_all!(project)

      error = assert_raises(WorkflowKit::ContextError) do
        WorkflowKit::ProjectContext.build(project, operation: "deployment")
      end
      assert_match(/not approved/, error.message)
    end
  end

  def test_missing_or_unknown_approval_status_fails_closed_with_services_present
    %w[missing unknown rejected].each do |status|
      with_project(prefix: "context-unapproved") do |project|
        project_map = {
          "project_id" => "unapproved",
          "workspace" => { "name" => "unapproved", "root" => project },
          "services" => { "api" => { "path" => "." } },
        }
        project_map["status"] = status unless status == "missing"
        write_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml"), project_map)
        commit_all!(project)

        error = assert_raises(WorkflowKit::ContextError) do
          WorkflowKit::ProjectContext.build(project, operation: "authentication")
        end
        assert_match(/not approved/, error.message)
      end
    end
  end

  def test_same_i1_through_i9_assertion_rejects_process_global_cache_variant
    with_isolation_fixtures do |alpha, beta|
      cached_context = nil
      cached_plan = nil
      contaminated_context_resolver = lambda do |path|
        cached_context ||= WorkflowKit::ProjectContext.build(path)
      end
      contaminated_plan_resolver = lambda do |path|
        cached_plan ||= plan_resolver.call(path)
      end

      error = assert_raises(Minitest::Assertion) do
        assert_bidirectional_isolation(
          alpha,
          beta,
          resolve_context: contaminated_context_resolver,
          resolve_plan: contaminated_plan_resolver,
        )
      end
      assert_match(/I-[1-9]/, error.message)
      assert_match(/cross-project context contamination/, error.message)
    end
  end
end
