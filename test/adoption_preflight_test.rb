# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/adoption/preflight"

class AdoptionPreflightTest < Minitest::Test
  def ready_context(
    project,
    project_status: "verified_local_and_production_preflight_target_staged",
    environment_status: "foundation_inactive"
  )
    write_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml"), {
      "status" => project_status,
      "project_id" => "adoption-fixture",
      "workspace" => { "root" => project },
      "services" => { "app" => { "path" => "app" } },
    })
    write_yaml(File.join(project, ".ai", "canonical", "ENV_MATRIX.yaml"), {
      "status" => environment_status,
      "environments" => { "local" => { "kind" => "local" } },
    })
    write_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"), {
      "status" => "idle",
      "active_streams" => [],
    })
  end

  def checkpoint_record(project, ref_suffix:, restore_verified: true, branch: nil, archive: nil, untracked_entries: 0)
    head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
    current_branch = run!("git", "branch", "--show-current", chdir: project).stdout.strip
    ref = "refs/harness-checkpoint/test/#{ref_suffix}"
    run!("git", "update-ref", ref, head, chdir: project)
    snapshot = WorkflowKit::Release::DirtySnapshot.snapshot(project)
    {
      "worktree_path" => File.realpath(project),
      "restore_verified" => restore_verified,
      "head" => head,
      "branch" => branch.nil? ? (current_branch.empty? ? nil : current_branch) : branch,
      "checkpoint_ref" => ref,
      "ref_target" => head,
      "untracked_entries" => untracked_entries,
      "untracked_archive" => archive,
      "dirty_snapshot_algo" => snapshot.fetch("dirty_snapshot_algo"),
      "dirty_snapshot_digest" => snapshot.fetch("dirty_snapshot_digest"),
      "dirty_snapshot_scope" => snapshot.fetch("dirty_snapshot_scope"),
    }
  end

  def write_checkpoint_records(directory, records)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "checkpoint.json"), JSON.pretty_generate({ "worktrees" => records }))
  end

  def test_clean_legacy_repository_with_semantic_context_is_technically_eligible_but_not_authorized
    with_project(prefix: "adoption-legacy") do |project|
      ready_context(project)
      commit_all!(project)

      result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
      assert_equal "legacy_adoption", result["track"]
      assert_equal true, result["technically_eligible"]
      assert_equal false, result["apply_authorized"]
      assert_equal true, result.dig("project_context", "ready")
      assert_equal 1, result.dig("project_context", "project_map", "section_count")
      assert_equal 1, result.dig("project_context", "env_matrix", "section_count")
      assert_includes result["external_requirements"], "fleet freeze release"
      assert_includes result["external_requirements"].join(" "), "human approval"
    end
  end

  def test_managed_repository_uses_upgrade_track
    with_project(prefix: "adoption-managed") do |project|
      ready_context(project)
      write_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"), {
        "manifest_schema" => 2,
        "kit_version" => "0.4.0",
      })
      commit_all!(project)

      result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
      assert_equal "managed_upgrade", result["track"]
      assert result["technically_eligible"]
    end
  end

  def test_active_stream_draft_context_and_dirty_tree_fail_closed
    with_project(prefix: "adoption-blocked") do |project|
      ready_context(project, project_status: "draft")
      write_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"), {
        "status" => "streams_in_progress",
        "active_streams" => [{ "feature_id" => "FEATURE-1" }],
      })
      commit_all!(project)
      write_file(File.join(project, "dirty.txt"), "do not mutate\n")

      result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
      refute result["technically_eligible"]
      refute result.dig("checks", "active_context_idle")
      refute result.dig("checks", "dirty_within_limit")
      refute result.dig("checks", "checkpoint_available_when_dirty")
      refute result.dig("checks", "project_context_ready")
      assert_includes result.dig("project_context", "project_map", "reasons"), "draft_or_placeholder_status"
      assert File.file?(File.join(project, "dirty.txt")), "preflight must not alter the target"
    end
  end

  def test_missing_placeholder_or_empty_context_is_not_ready
    cases = [
      [nil, { "app" => {} }, { "local" => {} }],
      ["unknown", { "app" => {} }, { "local" => {} }],
      ["approved", {}, { "local" => {} }],
      ["approved", { "app" => {} }, {}],
    ]
    cases.each do |status, services, environments|
      with_project(prefix: "adoption-unapproved") do |project|
        ready_context(project)
        project_map = {
          "project_id" => "adoption-fixture",
          "workspace" => { "root" => project },
          "services" => services,
        }
        project_map["status"] = status unless status.nil?
        write_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml"), project_map)
        env_matrix = { "status" => "approved", "environments" => environments }
        write_yaml(File.join(project, ".ai", "canonical", "ENV_MATRIX.yaml"), env_matrix)
        commit_all!(project)

        result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
        refute result["technically_eligible"]
        refute result.dig("checks", "project_context_ready")
        refute result.dig("project_context", "ready")
      end
    end
  end

  def test_missing_active_context_is_reported_as_idle_without_skipping_lock_scan
    with_project(prefix: "adoption-missing-activity") do |project|
      ready_context(project)
      FileUtils.rm(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      commit_all!(project)

      result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
      assert result["technically_eligible"]
      assert result.dig("checks", "active_context_idle")
      assert_nil result.dig("activity", "path")
      assert_equal "idle", result.dig("activity", "status")
      assert_empty result.dig("activity", "active_streams")
      assert_empty result["lock_paths"]
    end
  end

  def test_linked_worktree_activity_and_locks_are_inspected
    with_project(prefix: "adoption-linked-activity") do |project|
      ready_context(project)
      commit_all!(project)
      linked = "#{project}-linked"
      run!("git", "worktree", "add", "-b", "linked-active", linked, "HEAD", chdir: project)
      begin
        write_yaml(File.join(linked, ".ai", "local", "ACTIVE_CONTEXT.yaml"), {
          "status" => "streams_in_progress",
          "active_streams" => [{ "feature_id" => "FEATURE-LINKED" }],
        })
        write_file(File.join(linked, ".ai", "tasks", "FEATURE-LINKED", "streams", "backend", "LOCK.yaml"), "owner: test\n")
        commit_all!(linked, "active linked worktree")

        result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
        refute result["technically_eligible"]
        refute result.dig("checks", "active_context_idle")
        refute result.dig("checks", "stream_locks_absent")
        assert_equal 2, result["worktree_activity"].length
        assert_equal 1, result["lock_paths"].length
        linked_evidence = result["worktree_activity"].find { |entry| entry["path"] == File.realpath(linked) }
        refute linked_evidence.dig("activity", "ready")
        assert_equal 1, linked_evidence["lock_paths"].length
      ensure
        run_command("git", "worktree", "remove", "--force", linked, chdir: project)
        FileUtils.remove_entry(linked) if File.exist?(linked)
      end
    end
  end

  def test_dirty_worktree_requires_current_restore_verified_checkpoint_record
    with_project(prefix: "adoption-checkpoint") do |project|
      ready_context(project)
      write_file(File.join(project, "tracked.txt"), "baseline\n")
      commit_all!(project)
      write_file(File.join(project, "tracked.txt"), "dirty but preserved\n")
      Dir.mktmpdir("adoption-checkpoint-records") do |records|
        unrelated = checkpoint_record(project, ref_suffix: "unrelated")
        unrelated["worktree_path"] = File.join(File.dirname(project), "different-worktree")
        write_checkpoint_records(records, [unrelated])

        missing = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute missing["technically_eligible"]
        refute missing.dig("checks", "checkpoint_available_when_dirty")
        assert_equal "matching_checkpoint_record_missing",
                     missing.dig("checkpoint_evidence", "worktrees", 0, "reason")

        stale = checkpoint_record(project, ref_suffix: "stale", restore_verified: false)
        write_checkpoint_records(records, [stale])
        incomplete = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute incomplete.dig("checks", "checkpoint_available_when_dirty")
        refute incomplete.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0, "checks", "restore_verified"
        )

        stale["restore_verified"] = true
        stale["head"] = "0" * 40
        write_checkpoint_records(records, [stale])
        head_drift = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute head_drift.dig("checks", "checkpoint_available_when_dirty")
        refute head_drift.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0, "checks", "head_matches"
        )

        stale["head"] = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
        stale["branch"] = "different-branch"
        write_checkpoint_records(records, [stale])
        branch_drift = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute branch_drift.dig("checks", "checkpoint_available_when_dirty")
        refute branch_drift.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0, "checks", "branch_matches"
        )

        stale["branch"] = run!("git", "branch", "--show-current", chdir: project).stdout.strip
        stale["dirty_snapshot_algo"] = 3
        write_checkpoint_records(records, [stale])
        old_algorithm = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute old_algorithm.dig("checks", "checkpoint_available_when_dirty")
        refute old_algorithm.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0,
          "checks", "dirty_snapshot_algo_current"
        )

        current = checkpoint_record(project, ref_suffix: "current")
        write_checkpoint_records(records, [current])
        accepted = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        assert accepted["technically_eligible"]
        assert accepted.dig("checks", "checkpoint_available_when_dirty")
        assert accepted.dig("checkpoint_evidence", "worktrees", 0, "matched_record", "ready")
        assert_equal "dirty but preserved\n", File.read(File.join(project, "tracked.txt"))

        write_file(File.join(project, "tracked.txt"), "changed after checkpoint\n")
        digest_drift = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute digest_drift.dig("checks", "checkpoint_available_when_dirty")
        refute digest_drift.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0,
          "checks", "dirty_snapshot_digest_matches"
        )
      end
    end
  end

  def test_untracked_checkpoint_record_requires_external_archive_presence
    with_project(prefix: "adoption-checkpoint-archive") do |project|
      ready_context(project)
      commit_all!(project)
      write_file(File.join(project, "untracked.txt"), "preserve me\n")
      Dir.mktmpdir("adoption-checkpoint-records") do |records|
        archive = File.join(records, "external", "untracked.tar.gz")
        record = checkpoint_record(
          project,
          ref_suffix: "archive",
          archive: archive,
          untracked_entries: 1,
        )
        write_checkpoint_records(records, [record])

        missing = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        refute missing.dig("checks", "checkpoint_available_when_dirty")
        refute missing.dig(
          "checkpoint_evidence", "worktrees", 0, "candidate_checks", 0,
          "checks", "archive_present_when_required"
        )

        write_file(archive, "opaque archive evidence")
        accepted = WorkflowKit::Adoption::Preflight.inspect_repository(
          project,
          dirty_limit: 1,
          checkpoint_record_directory: records,
        )
        assert accepted["technically_eligible"]
        assert accepted.dig(
          "checkpoint_evidence", "worktrees", 0, "matched_record",
          "checks", "archive_present_when_required"
        )
      end
    end
  end

  def test_each_dirty_linked_worktree_requires_its_own_checkpoint_record
    with_project(prefix: "adoption-linked-checkpoint") do |project|
      ready_context(project)
      commit_all!(project)
      linked = "#{project}-linked"
      run!("git", "worktree", "add", "-b", "linked-dirty", linked, "HEAD", chdir: project)
      begin
        write_file(File.join(linked, "linked-dirty.txt"), "preserve linked work\n")
        Dir.mktmpdir("adoption-checkpoint-records") do |records|
          write_checkpoint_records(records, [])
          missing = WorkflowKit::Adoption::Preflight.inspect_repository(
            project,
            dirty_limit: 1,
            checkpoint_record_directory: records,
          )
          refute missing.dig("checks", "checkpoint_available_when_dirty")
          linked_evidence = missing.dig("checkpoint_evidence", "worktrees").find do |entry|
            entry["path"] == File.realpath(linked)
          end
          assert_equal "matching_checkpoint_record_missing", linked_evidence["reason"]

          linked_record = checkpoint_record(linked, ref_suffix: "linked-current")
          write_checkpoint_records(records, [linked_record])
          accepted = WorkflowKit::Adoption::Preflight.inspect_repository(
            project,
            dirty_limit: 1,
            checkpoint_record_directory: records,
          )
          assert accepted["technically_eligible"]
        end
      ensure
        run_command("git", "worktree", "remove", "--force", linked, chdir: project)
        FileUtils.remove_entry(linked) if File.exist?(linked)
      end
    end
  end

  def test_lock_and_detached_head_are_reported
    with_project(prefix: "adoption-detached") do |project|
      ready_context(project)
      write_file(File.join(project, ".ai", "tasks", "FEATURE-1", "streams", "S1", "LOCK.yaml"), "owner: test\n")
      commit_all!(project)
      run!("git", "checkout", "--detach", chdir: project)

      result = WorkflowKit::Adoption::Preflight.inspect_repository(project)
      refute result["technically_eligible"]
      refute result.dig("checks", "attached_branch")
      refute result.dig("checks", "stream_locks_absent")
      assert_equal 1, result["lock_paths"].length
    end
  end
end
