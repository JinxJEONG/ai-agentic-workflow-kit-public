# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"
require_relative "test_helper"

class MergeOwnedAdoptionTest < Minitest::Test
  def test_reviewed_merge_content_is_bound_to_plan_apply_validation_and_status
    with_project(prefix: "workflow-kit-merge-owned") do |project|
      current = "# Project agent rules\n\nKeep the project-specific safety rule.\n"
      write_file(File.join(project, "AGENTS.md"), current)

      Dir.mktmpdir("workflow-kit-reviewed-merge") do |directory|
        merged_path = File.join(directory, "AGENTS.md")
        merged = "# AGENTS\n\n## Project Safety\n\nKeep the project-specific safety rule.\n"
        write_file(merged_path, merged)
        options = [
          "--approve-path", "AGENTS.md=#{Digest::SHA256.hexdigest(current)}",
          "--merge-path", "AGENTS.md=#{merged_path}",
        ]

        plan_result = bootstrap_plan(project, *options)
        assert plan_result.success?, plan_result.combined
        plan = JSON.parse(plan_result.stdout)
        agents = plan.fetch("files").find { |entry| entry.fetch("path") == "AGENTS.md" }
        assert_equal "update", agents.fetch("action")
        assert_equal Digest::SHA256.hexdigest(merged), agents.fetch("desired_digest")
        assert_equal Digest::SHA256.hexdigest(merged), plan.dig("approvals", "merge_content_approvals", 0, "desired_digest")

        run!(
          RbConfig.ruby,
          BOOTSTRAP,
          *reviewed_release_options,
          *options,
          "--plan-digest",
          plan.fetch("plan_digest"),
          project,
        )
        assert_equal merged, File.read(File.join(project, "AGENTS.md"))

        validation = run!(RbConfig.ruby, File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "validators", "validate_install.rb"), project)
        assert_includes validation.stdout, "installation is valid"

        status = run!(RbConfig.ruby, File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "install", "status.rb"), "--json", project)
        assert_equal "current", JSON.parse(status.stdout).fetch("state")
      end
    end
  end

  def test_merge_override_rejects_project_owned_path
    with_project(prefix: "workflow-kit-invalid-merge") do |project|
      Dir.mktmpdir("workflow-kit-invalid-reviewed-merge") do |directory|
        merged_path = File.join(directory, "PROJECT_MAP.yaml")
        write_file(merged_path, "workspace:\n  root: .\n")

        result = bootstrap_plan(project, "--merge-path", ".ai/canonical/PROJECT_MAP.yaml=#{merged_path}")
        refute result.success?
        assert_includes result.combined, "approval-required merge-owned"
        refute File.exist?(File.join(project, ".ai"))
      end
    end
  end
end
