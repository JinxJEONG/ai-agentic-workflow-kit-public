# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "../engine/gardener/propose_drift_pr"
require_relative "../engine/inventory/fleet_report"

class OperationsTest < Minitest::Test
  def base_commit(project, branch = "main")
    run!("git", "rev-parse", branch, chdir: project).stdout.strip
  end

  def with_review_worktree(project, branch: "automation/harness-drift/test", start_point: "main")
    Dir.mktmpdir("gardener-linked-worktree") do |parent|
      worktree = File.join(parent, "worktree")
      run!("git", "worktree", "add", "--quiet", "-b", branch, worktree, start_point, chdir: project)
      yield worktree
    ensure
      run_command("git", "worktree", "remove", "--force", worktree, chdir: project) if worktree
    end
  end

  def apply_reviewed(worktree, project, plan, base_branch: "main", expected_base_commit: nil)
    WorkflowKit::Gardener.apply(
      worktree,
      base_branch,
      plan,
      expected_base_commit: expected_base_commit || base_commit(project, base_branch),
      expected_plan_digest: plan.fetch("plan_digest"),
    )
  end

  def gardener_plan(project, changes, base_branch: "main", expected_base_commit: nil)
    WorkflowKit::Gardener.plan(
      changes,
      base_branch: base_branch,
      base_commit: expected_base_commit || base_commit(project, base_branch),
    )
  end

  def test_gardener_refuses_project_owned_and_approval_required_paths
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/canonical/PROJECT_MAP.yaml", "content" => "unsafe" },
        { "path" => "AGENTS.md", "content" => "unsafe" },
        { "path" => "src/app.rb", "content" => "unsafe" },
      ])
      refute plan["valid"]
      assert plan["changes"].all? { |change| change["state"] == "refused" }
    end
  end

  def test_gardener_applies_only_to_a_separate_linked_review_worktree
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])
      with_review_worktree(project) do |worktree|
        result = apply_reviewed(worktree, project, plan)
        assert_equal [".ai/generated/routes.json"], result["written"]
        assert_equal plan.fetch("plan_digest"), result["plan_digest"]
        assert result["external_pr_required"]
        assert File.file?(File.join(worktree, ".ai", "generated", "routes.json"))
        refute File.exist?(File.join(project, ".ai", "generated", "routes.json"))
      end
    end
  end

  def test_gardener_refuses_the_primary_checkout_even_with_a_review_branch_name
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      expected = base_commit(project)
      run!("git", "switch", "-c", "automation/harness-drift", chdir: project)
      plan = gardener_plan(
        project,
        [{ "path" => ".ai/generated/routes.json", "content" => "{}" }],
        expected_base_commit: expected,
      )
      error = assert_raises(ArgumentError) do
        WorkflowKit::Gardener.apply(
          project,
          "main",
          plan,
          expected_base_commit: expected,
          expected_plan_digest: plan.fetch("plan_digest"),
        )
      end
      assert_match(/separate linked worktree/, error.message)
      refute File.exist?(File.join(project, ".ai", "generated", "routes.json"))
    end
  end

  def test_gardener_refuses_allowlisted_path_through_a_symlinked_parent
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      Dir.mktmpdir("gardener-outside") do |outside|
        plan = gardener_plan(project, [
          { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
        ])
        with_review_worktree(project) do |worktree|
          FileUtils.mkdir_p(File.join(worktree, ".ai"))
          File.symlink(outside, File.join(worktree, ".ai", "generated"))
          assert_raises(ArgumentError) do
            apply_reviewed(worktree, project, plan)
          end
        end
        refute File.exist?(File.join(outside, "routes.json"))
      end
    end
  end

  def test_gardener_refuses_a_branch_not_based_on_the_reviewed_base
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])
      with_review_worktree(project, branch: "automation/harness-drift/unrelated") do |worktree|
        write_file(File.join(worktree, "unrelated.txt"), "commit\n")
        commit_all!(worktree, "unrelated branch commit")
        assert_raises(ArgumentError) do
          apply_reviewed(worktree, project, plan)
        end
        refute File.exist?(File.join(worktree, ".ai", "generated", "routes.json"))
      end
    end
  end

  def test_gardener_cannot_treat_main_as_review_branch_by_lying_about_base_name
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      run!("git", "branch", "fake-base", chdir: project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])

      with_review_worktree(project) do |worktree|
        error = assert_raises(ArgumentError) do
          WorkflowKit::Gardener.apply(
            worktree,
            "fake-base",
            plan,
            expected_base_commit: base_commit(project, "fake-base"),
            expected_plan_digest: plan.fetch("plan_digest"),
          )
        end
        assert_match(/reviewed base branch and commit/, error.message)
        refute File.exist?(File.join(worktree, ".ai", "generated", "routes.json"))
      end
    end
  end

  def test_gardener_binds_the_reviewed_base_commit
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      expected = run!("git", "rev-parse", "main", chdir: project).stdout.strip
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ], expected_base_commit: expected)
      with_review_worktree(project) do |worktree|
        result = apply_reviewed(
          worktree,
          project,
          plan,
          expected_base_commit: expected,
        )
        assert_equal expected, result["base_commit"]
        assert_equal "main", result["base_branch"]
      end
    end
  end

  def test_gardener_requires_an_explicit_reviewed_plan_digest
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])
      with_review_worktree(project) do |worktree|
        error = assert_raises(ArgumentError) do
          WorkflowKit::Gardener.apply(
            worktree,
            "main",
            plan,
            expected_base_commit: base_commit(project),
            expected_plan_digest: nil,
          )
        end
        assert_match(/explicit expected_plan_digest/, error.message)
      end
    end
  end

  def test_gardener_rejects_plan_content_tampering
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "reviewed\n" },
      ])
      reviewed_digest = plan.fetch("plan_digest")
      plan.fetch("changes").first["content"] = "unreviewed\n"

      with_review_worktree(project) do |worktree|
        error = assert_raises(ArgumentError) do
          WorkflowKit::Gardener.apply(
            worktree,
            "main",
            plan,
            expected_base_commit: base_commit(project),
            expected_plan_digest: reviewed_digest,
          )
        end
        assert_match(/mutated after planning/, error.message)
        refute File.exist?(File.join(worktree, ".ai", "generated", "routes.json"))
      end
    end
  end

  def test_gardener_recalculates_each_content_digest
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "reviewed\n" },
      ])
      plan.fetch("changes").first["sha256"] = "sha256:#{'0' * 64}"
      plan["plan_digest"] = WorkflowKit::Gardener.canonical_plan_digest(plan)

      with_review_worktree(project) do |worktree|
        error = assert_raises(ArgumentError) do
          apply_reviewed(worktree, project, plan)
        end
        assert_match(/content digest mismatch/, error.message)
      end
    end
  end

  def test_gardener_rolls_back_original_bytes_modes_and_new_files
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      write_file(File.join(project, ".ai", "generated", "a.json"), "original\n")
      File.chmod(0o755, File.join(project, ".ai", "generated", "a.json"))
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/a.json", "content" => "replacement\n" },
        { "path" => ".ai/generated/b.json", "content" => "new\n" },
      ])

      with_review_worktree(project) do |worktree|
        original_writer = WorkflowKit::Gardener.method(:atomic_replace)
        calls = 0
        failing_writer = lambda do |destination, content, mode|
          calls += 1
          original_writer.call(destination, content, mode)
          raise IOError, "simulated second write failure" if calls == 2
        end

        assert_raises(IOError) do
          WorkflowKit::Gardener.stub(:atomic_replace, failing_writer) do
            apply_reviewed(worktree, project, plan)
          end
        end
        existing = File.join(worktree, ".ai", "generated", "a.json")
        assert_equal "original\n", File.binread(existing)
        assert_equal 0o755, File.stat(existing).mode & 0o777
        refute File.exist?(File.join(worktree, ".ai", "generated", "b.json"))
      end
    end
  end

  def test_local_maintenance_lifecycle_applies_and_always_removes_the_worktree
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])
      Dir.mktmpdir("gardener-maintenance-root") do |maintenance_root|
        before = run!("git", "status", "--porcelain=v1", "-z", chdir: project).stdout
        result = WorkflowKit::Gardener.apply_in_maintenance_worktree(
          repository: project,
          maintenance_root: maintenance_root,
          base_branch: "main",
          plan: plan,
          expected_base_commit: base_commit(project),
          expected_plan_digest: plan.fetch("plan_digest"),
        )

        assert result["external_pr_required"]
        assert result["maintenance_worktree_removed"]
        assert_equal false, result["commit_performed"]
        assert_equal false, result["push_performed"]
        assert_equal false, result["pr_created"]
        refute File.exist?(result.fetch("maintenance_worktree"))
        refute_includes run!("git", "worktree", "list", "--porcelain", chdir: project).stdout,
          maintenance_root
        assert_empty Dir.children(maintenance_root)
        assert_equal before, run!("git", "status", "--porcelain=v1", "-z", chdir: project).stdout
      end
    end
  end

  def test_local_maintenance_lifecycle_cleans_up_after_apply_failure
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      plan = gardener_plan(project, [
        { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
      ])
      Dir.mktmpdir("gardener-maintenance-failure") do |maintenance_root|
        assert_raises(RuntimeError) do
          WorkflowKit::Gardener.stub(:apply, lambda { |*_args| raise "simulated apply failure" }) do
            WorkflowKit::Gardener.apply_in_maintenance_worktree(
              repository: project,
              maintenance_root: maintenance_root,
              base_branch: "main",
              plan: plan,
              expected_base_commit: base_commit(project),
              expected_plan_digest: plan.fetch("plan_digest"),
            )
          end
        end
        refute_includes run!("git", "worktree", "list", "--porcelain", chdir: project).stdout,
          maintenance_root
        assert_empty Dir.children(maintenance_root)
      end
    end
  end

  def test_cli_plan_digest_drives_the_local_maintenance_lifecycle
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      expected = base_commit(project)
      Dir.mktmpdir("gardener-cli-test") do |directory|
        changes_path = File.join(directory, "changes.json")
        maintenance_root = File.join(directory, "maintenance")
        write_file(changes_path, JSON.generate([
          { "path" => ".ai/generated/routes.json", "content" => "{}\n" },
        ]))
        cli = File.join(KIT_ROOT, "engine", "gardener", "propose_drift_pr.rb")
        planned = run!(
          RbConfig.ruby,
          cli,
          "--changes",
          changes_path,
          "--base",
          "main",
          "--expected-base-commit",
          expected,
        )
        plan = JSON.parse(planned.stdout)
        assert_match(/\Asha256:[0-9a-f]{64}\z/, plan.fetch("plan_digest"))

        applied = run!(
          RbConfig.ruby,
          cli,
          "--changes",
          changes_path,
          "--repository",
          project,
          "--maintenance-root",
          maintenance_root,
          "--base",
          "main",
          "--expected-base-commit",
          expected,
          "--expected-plan-digest",
          plan.fetch("plan_digest"),
        )
        payload = JSON.parse(applied.stdout)
        assert_equal plan.fetch("plan_digest"), payload.dig("result", "plan_digest")
        assert_equal true, payload.dig("result", "maintenance_worktree_removed")
        assert_equal true, payload.dig("result", "external_pr_required")
        assert_empty Dir.children(maintenance_root)
      end
    end
  end

  def test_fleet_report_does_not_change_repository_status
    with_project do |project|
      write_file(File.join(project, "README.md"), "fixture\n")
      commit_all!(project)
      before = run!("git", "status", "--porcelain=v1", "-z", chdir: project).stdout
      report = WorkflowKit::FleetReport.build([project])
      after = run!("git", "status", "--porcelain=v1", "-z", chdir: project).stdout
      assert_equal before, after
      assert_equal 1, report["repos"].length
      assert report["repos"].first.key?("drift_state")
    end
  end

  def test_channel_config_has_human_promotion_gate
    channels = JSON.parse(File.read(File.join(KIT_ROOT, "release-channels.json")))
    assert_nil channels["stable"]
    assert channels.dig("promotion_policy", "requires_human_approval")
    assert_equal %w[sample-managed-service sample-legacy-service], channels.dig("promotion_policy", "requires_canary_repos")
  end
end
