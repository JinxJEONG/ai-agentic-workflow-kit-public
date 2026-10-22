# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "../installer/lib/install_integrity"

class PlanBindingTest < Minitest::Test
  def test_rendered_digest_length_framing_prevents_newline_path_injection
    digest_a = Digest::SHA256.hexdigest("A")
    digest_b = Digest::SHA256.hexdigest("B")
    one = [{
      relative: "a\n#{digest_b} 0644 b kit-owned",
      digest: digest_a,
      mode: 0o644,
      ownership: "kit-owned",
    }]
    two = [
      { relative: "a", digest: digest_a, mode: 0o644, ownership: "kit-owned" },
      { relative: "b", digest: digest_b, mode: 0o644, ownership: "kit-owned" },
    ]

    refute_equal(
      WorkflowKit::Install::Integrity.rendered_install_digest(one),
      WorkflowKit::Install::Integrity.rendered_install_digest(two),
    )
  end

  def test_plan_digest_is_deterministic_for_unchanged_source_and_target
    with_project do |project|
      first = bootstrap_plan(project)
      second = bootstrap_plan(project)

      assert first.success?, first.combined
      assert second.success?, second.combined
      first_plan = JSON.parse(first.stdout)
      second_plan = JSON.parse(second.stdout)
      assert_equal first_plan.fetch("plan_digest"), second_plan.fetch("plan_digest")
      assert_equal first_plan.dig("source", "rendered_install_digest"), second_plan.dig("source", "rendered_install_digest")
      scope = first_plan.dig("target", "dirty_snapshot_scope")
      assert_equal "plan_targets_plus_harness_allowlist", scope.fetch("mode")
      assert_includes scope.fetch("globs"), ".ai/**"
      assert_includes scope.fetch("globs"), "AGENTS.md"
      assert_includes scope.fetch("globs"), ".githooks/**"
      assert_includes scope.fetch("globs"), ".github/workflows/**"
      assert_includes scope.fetch("paths"), ".ai/runtime/scripts/workflow_lib.rb"
    end
  end

  def test_exact_scope_path_is_not_reinterpreted_as_a_glob
    with_project do |project|
      exact = "target[1].rb"
      similar = "target1.rb"
      write_file(File.join(project, exact), "exact one\n")
      write_file(File.join(project, similar), "similar one\n")
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      context = lambda do
        WorkflowKit::Install::Integrity.target_context(
          project,
          manifest_path,
          project_id: "literal-scope",
          scope_paths: [exact],
          scope_globs: [],
          scope_mode: "plan_targets_plus_harness_allowlist",
        )
      end

      first = context.call
      write_file(File.join(project, similar), "similar two\n")
      second = context.call
      assert_equal first.fetch("dirty_snapshot_digest"), second.fetch("dirty_snapshot_digest")

      write_file(File.join(project, exact), "exact two\n")
      third = context.call
      refute_equal second.fetch("dirty_snapshot_digest"), third.fetch("dirty_snapshot_digest")
      assert_equal [exact], third.dig("dirty_snapshot_scope", "paths")
      assert_empty third.dig("dirty_snapshot_scope", "globs")
    end
  end

  def test_unrelated_dirty_file_does_not_invalidate_reviewed_plan
    with_project do |project|
      bootstrap!(project)
      plan = JSON.parse(bootstrap_plan(project).stdout)
      write_file(File.join(project, "untracked-after-review.txt"), "changed\n")

      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *reviewed_release_options,
        "--plan-digest",
        plan.fetch("plan_digest"),
        project,
      )

      assert result.success?, result.combined
      assert_equal "installed", JSON.parse(result.stdout).fetch("status")
      assert_equal "changed\n", File.read(File.join(project, "untracked-after-review.txt"))
    end
  end

  def test_harness_dirty_file_invalidates_reviewed_plan_without_writing
    with_project do |project|
      bootstrap!(project)
      plan = JSON.parse(bootstrap_plan(project).stdout)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest_before = File.binread(manifest_path)
      write_file(File.join(project, "AGENTS.md"), "changed after review\n")

      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *reviewed_release_options,
        "--plan-digest",
        plan.fetch("plan_digest"),
        project,
      )

      refute result.success?
      assert_includes result.combined, "plan digest mismatch"
      assert_equal manifest_before, File.binread(manifest_path)
    end
  end

  def test_initial_repository_fingerprint_uses_the_persisted_project_id
    with_project do |project|
      initial = JSON.parse(bootstrap_plan(project).stdout)
      initial_fingerprint = initial.dig("target", "repository_fingerprint")
      bootstrap!(project)
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      refreshed = JSON.parse(bootstrap_plan(project).stdout)

      assert_match(/\Asha256:[0-9a-f]{64}\z/, initial_fingerprint)
      assert_equal initial_fingerprint, manifest.fetch("repository_fingerprint")
      assert_equal initial_fingerprint, refreshed.dig("target", "repository_fingerprint")
      refute_empty manifest.fetch("project_id")
    end
  end

  def test_apply_rejects_head_and_branch_changed_after_plan
    with_project do |project|
      bootstrap!(project)
      commit_all!(project, "installed")
      plan = JSON.parse(bootstrap_plan(project).stdout)
      run!("git", "checkout", "-b", "changed-after-review", chdir: project)

      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *reviewed_release_options,
        "--plan-digest",
        plan.fetch("plan_digest"),
        project,
      )

      refute result.success?
      assert_includes result.combined, "plan digest mismatch"
    end
  end

  def test_apply_rejects_a_tampered_plan_digest
    with_project do |project|
      plan = JSON.parse(bootstrap_plan(project).stdout)
      digest = plan.fetch("plan_digest")
      tampered = "#{digest[0...-1]}#{digest[-1] == '0' ? '1' : '0'}"

      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *reviewed_release_options,
        "--plan-digest",
        tampered,
        project,
      )

      refute result.success?
      assert_includes result.combined, "plan digest mismatch"
      refute File.exist?(File.join(project, ".ai"))
    end
  end

  def test_apply_uses_reviewed_release_when_working_tree_changes_after_plan
    with_project do |project|
      plan = JSON.parse(bootstrap_plan(project).stdout)
      marker = File.join(WorkflowKitTestHelpers::KIT_ROOT, "installer", ".plan-binding-source-change")
      File.write(marker, "changed source\n")

      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *reviewed_release_options,
        "--plan-digest",
        plan.fetch("plan_digest"),
        project,
      )

      assert result.success?, result.combined
      assert_equal "installed", JSON.parse(result.stdout).fetch("status")
      assert File.exist?(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
    ensure
      FileUtils.rm_f(marker) if marker
    end
  end
end
