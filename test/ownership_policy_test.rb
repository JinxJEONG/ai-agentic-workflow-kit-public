# frozen_string_literal: true

require "digest"
require "json"
require_relative "test_helper"
require_relative "../installer/lib/install_integrity"

class OwnershipPolicyTest < Minitest::Test
  def test_phase4_repository_artifacts_have_explicit_ownership
    rules = WorkflowKit::Install::Integrity::DEFAULT_OWNERSHIP_RULES

    assert_equal "project-owned", WorkflowKit::Install::Integrity.ownership_for(
      ".ai/SPEC_REGISTRY.yaml", rules,
    )
    assert_equal "project-owned", WorkflowKit::Install::Integrity.ownership_for(
      ".github/CODEOWNERS", rules,
    )
    assert_equal "merge-owned", WorkflowKit::Install::Integrity.ownership_for(
      ".github/workflows/agent-workflow-policy.yml", rules,
    )
    assert_includes(
      WorkflowKit::Install::Integrity::DEFAULT_APPROVAL_REQUIRED_PATHS,
      ".github/workflows/agent-workflow-policy.yml",
    )
  end

  def test_project_owned_and_task_content_is_preserved_during_force_upgrade
    with_project do |project|
      bootstrap!(project)
      project_rules = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      File.open(project_rules, "ab") { |file| file.write("\nProject rule.\n") }
      rules_before = File.binread(project_rules)
      task_path = File.join(project, ".ai", "tasks", "FEATURE-TEST", "user-note.md")
      write_file(task_path, "keep me\n")

      bootstrap!(project, "--force")

      assert_equal rules_before, File.binread(project_rules)
      assert_equal "keep me\n", File.binread(task_path)
    end
  end

  def test_agents_merge_is_blocked_without_exact_path_approval
    with_project do |project|
      bootstrap!(project)
      agents_path = File.join(project, "AGENTS.md")
      File.open(agents_path, "ab") { |file| file.write("\nLocal agent rule.\n") }
      before = File.binread(agents_path)

      plan_result = bootstrap_plan(project, "--force")
      refute plan_result.success?
      plan = JSON.parse(plan_result.stdout)
      agents = plan.fetch("files").find { |entry| entry.fetch("path") == "AGENTS.md" }
      assert_equal "merge-owned", agents.fetch("ownership")
      assert_equal "conflict", agents.fetch("action")
      assert_equal before, File.binread(agents_path)

      approval = Digest::SHA256.hexdigest(before)
      bootstrap!(project, "--force", "--approve-path", "AGENTS.md=#{approval}")
      refute_equal before, File.binread(agents_path)
    end
  end

  def test_approval_rejects_a_digest_that_does_not_match_current_content
    with_project do |project|
      bootstrap!(project)
      rules_path = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      File.open(rules_path, "ab") { |file| file.write("\nLocal.\n") }
      before = File.binread(rules_path)

      result = bootstrap_plan(project, "--approve-path", ".ai/canonical/PROJECT_RULES.md=#{'0' * 64}")

      refute result.success?
      assert_includes result.combined, "does not match"
      assert_equal before, File.binread(rules_path)
    end
  end

  def test_orphaned_kit_file_cannot_be_deleted_without_a_tombstone
    with_project do |project|
      bootstrap!(project)
      orphan = File.join(project, ".ai", "runtime", "scripts", "removed-from-release.rb")
      write_file(orphan, "puts :keep\n")
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      digest = Digest::SHA256.file(orphan).hexdigest
      manifest.fetch("installed_files") << {
        "path" => ".ai/runtime/scripts/removed-from-release.rb",
        "sha256" => digest,
        "baseline_sha256" => digest,
        "template_sha256" => digest,
        "mode" => "0644",
        "ownership" => "kit-owned",
        "state" => "managed",
      }
      write_yaml(manifest_path, manifest)

      result = bootstrap_plan(project, "--force")
      refute result.success?
      plan = JSON.parse(result.stdout)
      orphan_plan = plan.fetch("files").find { |entry| entry.fetch("path") == ".ai/runtime/scripts/removed-from-release.rb" }
      assert_equal "conflict", orphan_plan.fetch("action")
      assert_equal "missing_tombstone", orphan_plan.fetch("reason")
      assert File.file?(orphan)
    end
  end

  def test_equal_specificity_conflicting_ownership_rules_fail_closed
    rules = [
      { "glob" => ".ai/canonical/**", "ownership" => "project-owned" },
      { "glob" => ".ai/canonical/**", "ownership" => "kit-owned" },
    ]

    error = assert_raises(WorkflowKit::Install::Integrity::IntegrityError) do
      WorkflowKit::Install::Integrity.ownership_for(".ai/canonical/PROJECT_RULES.md", rules)
    end
    assert_includes error.message, "ambiguous ownership"
  end
end
