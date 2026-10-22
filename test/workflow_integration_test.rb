# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "test_helper"

class WorkflowIntegrationTest < Minitest::Test
  def test_backend_and_frontend_streams_can_run_in_parallel
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Parallel feature")

      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "frontend-dev", "kiro-cli", chdir: project)

      context = load_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      active_ids = context.fetch("active_streams").map { |entry| entry.fetch("stream_id") }
      assert_includes active_ids, "backend-dev"
      assert_includes active_ids, "frontend-dev"
      assert File.exist?(File.join(project, ".ai", "local", "locks", "#{id}--backend-dev.lock"))
      assert File.exist?(File.join(project, ".ai", "local", "locks", "#{id}--frontend-dev.lock"))
      assert_empty run!("git", "status", "--porcelain", "--", ".ai/local", chdir: project).stdout
    end
  end

  def test_streams_with_the_same_write_scope_cannot_run_in_parallel
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Conflicting scopes")
      commit_all!(project)

      backend_manifest_path = File.join(feature_dir(project), "streams", "backend-dev", "manifest.yaml")
      frontend_manifest_path = File.join(feature_dir(project), "streams", "frontend-dev", "manifest.yaml")
      backend_manifest = load_yaml(backend_manifest_path)
      frontend_manifest = load_yaml(frontend_manifest_path)
      frontend_manifest["write_scope"] = backend_manifest.fetch("write_scope")
      write_yaml(frontend_manifest_path, frontend_manifest)

      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      result = run_command(RbConfig.ruby, script(project, "activate_stream.rb"), id, "frontend-dev", "kiro-cli", chdir: project)

      refute result.success?
      assert_match(/writable scope overlaps/i, result.combined)
      context = load_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      assert_equal ["backend-dev"], context.fetch("active_streams").map { |entry| entry.fetch("stream_id") }
      refute File.exist?(File.join(project, ".ai", "local", "locks", "#{id}--frontend-dev.lock"))
    end
  end

  def test_concurrent_stream_activation_does_not_lose_or_duplicate_state
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Concurrent activation")

      commands = 10.times.map do |index|
        if index.even?
          [id, "backend-dev", "codex-app"]
        else
          [id, "frontend-dev", "kiro-cli"]
        end
      end
      pids = commands.map do |arguments|
        Process.spawn(
          RbConfig.ruby,
          script(project, "activate_stream.rb"),
          *arguments,
          chdir: project,
          out: File::NULL,
          err: File::NULL,
        )
      end
      statuses = pids.map { |pid| Process.wait2(pid).last }

      assert statuses.all?(&:success?), "concurrent activation failures: #{statuses.map(&:exitstatus).inspect}"
      context = load_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      active_ids = context.fetch("active_streams").map { |entry| entry.fetch("stream_id") }
      assert_equal %w[backend-dev frontend-dev], active_ids.sort
      assert_equal active_ids.length, active_ids.uniq.length
      assert_operator context.fetch("state_revision"), :>=, 11
      assert File.exist?(File.join(project, ".ai", "local", "locks", "#{id}--backend-dev.lock"))
      assert File.exist?(File.join(project, ".ai", "local", "locks", "#{id}--frontend-dev.lock"))
    end
  end

  def test_malformed_and_stale_local_locks_require_explicit_recovery
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Lock recovery")

      locks_dir = File.join(project, ".ai", "local", "locks")
      malformed_lock = File.join(locks_dir, "#{id}--backend-dev.lock")
      stale_lock = File.join(locks_dir, "#{id}--frontend-dev.lock")
      write_file(malformed_lock, "---\nowner_agent: [\n")
      write_yaml(stale_lock, {
        "schema_version" => 1,
        "feature_id" => id,
        "stream_id" => "frontend-dev",
        "owner_agent" => "kiro-cli",
        "locked_at" => "2000-01-01T00:00:00Z",
      })
      malformed_before = File.binread(malformed_lock)
      stale_before = File.binread(stale_lock)

      malformed_result = run_command(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      stale_result = run_command(RbConfig.ruby, script(project, "activate_stream.rb"), id, "frontend-dev", "kiro-cli", chdir: project)

      refute malformed_result.success?
      assert_match(/malformed.*explicit recovery|explicit recovery.*malformed/i, malformed_result.combined)
      refute stale_result.success?
      assert_match(/stale|orphan/i, stale_result.combined)
      assert_match(/explicit recovery/i, stale_result.combined)
      assert_equal malformed_before, File.binread(malformed_lock)
      assert_equal stale_before, File.binread(stale_lock)
      context = load_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      assert_empty context.fetch("active_streams")
    end
  end

  def test_linked_worktrees_keep_local_active_contexts_isolated
    with_project do |project|
      linked_worktree = "#{project}-linked"
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Worktree isolation")
      commit_all!(project)
      run!("git", "worktree", "add", "-b", "linked-scope", linked_worktree, "HEAD", chdir: project)

      begin
        run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
        run!(RbConfig.ruby, script(linked_worktree, "activate_stream.rb"), id, "backend-dev", "kiro-cli", chdir: linked_worktree)

        primary_context_path = File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml")
        linked_context_path = File.join(linked_worktree, ".ai", "local", "ACTIVE_CONTEXT.yaml")
        primary_context = load_yaml(primary_context_path)
        linked_context = load_yaml(linked_context_path)
        primary_entry = primary_context.fetch("active_streams").fetch(0)
        linked_entry = linked_context.fetch("active_streams").fetch(0)

        refute_equal File.realpath(primary_context_path), File.realpath(linked_context_path)
        assert_equal "codex-app", primary_entry.fetch("owner_agent")
        assert_equal "kiro-cli", linked_entry.fetch("owner_agent")
        assert_equal File.realpath(File.join(project, ".ai", "local", "locks")), File.dirname(File.realpath(primary_entry.fetch("lock_path")))
        assert_equal File.realpath(File.join(linked_worktree, ".ai", "local", "locks")), File.dirname(File.realpath(linked_entry.fetch("lock_path")))
        assert_empty run!("git", "status", "--porcelain", "--", ".ai/local", chdir: project).stdout
        assert_empty run!("git", "status", "--porcelain", "--", ".ai/local", chdir: linked_worktree).stdout
      ensure
        if Dir.exist?(linked_worktree)
          run_command("git", "worktree", "remove", "--force", linked_worktree, chdir: project)
          FileUtils.remove_entry(linked_worktree) if Dir.exist?(linked_worktree)
        end
      end
    end
  end

  def test_default_deny_rejects_an_out_of_scope_application_file
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Backend only")
      commit_all!(project)
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      write_file(File.join(project, "frontend", "out-of-scope.js"), "export const unsafe = true;\n")
      run!("git", "add", "frontend/out-of-scope.js", chdir: project)

      result = run_command(RbConfig.ruby, script(project, "validate_work_scope.rb"), "--staged", "--repo-root", project, chdir: project)
      refute result.success?
      assert_match(/outside|owning|scope|unowned/i, result.combined)
    end
  end

  def test_scope_validation_rejects_out_of_scope_deletion_and_rename_destination
    with_project do |project|
      bootstrap!(project)
      write_file(File.join(project, "frontend", "delete-me.js"), "export const obsolete = true;\n")
      write_file(File.join(project, "backend", "owned.js"), "export const owned = true;\n")
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Delete and rename scope")
      commit_all!(project)
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)

      FileUtils.rm(File.join(project, "frontend", "delete-me.js"))
      run!("git", "add", "-u", "--", "frontend/delete-me.js", chdir: project)
      run!("git", "mv", "backend/owned.js", "frontend/escaped.js", chdir: project)

      result = run_command(RbConfig.ruby, script(project, "validate_work_scope.rb"), "--staged", "--repo-root", project, chdir: project)
      refute result.success?
      assert_includes result.combined, "frontend/delete-me.js"
      assert_includes result.combined, "frontend/escaped.js"
    end
  end

  def test_tier2_database_change_is_rejected_by_policy
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Unsafe database change")
      commit_all!(project)
      write_file(File.join(project, "db", "unreviewed.sql"), "select 1;\n")
      run!("git", "add", "db/unreviewed.sql", chdir: project)

      result = run_command(RbConfig.ruby, script(project, "check_workflow_policy.rb"), "--feature", id, "--staged", chdir: project)
      refute result.success?
      assert_includes result.combined, "POLICY_TIER_TOO_LOW"
    end
  end

  def test_default_feature_cannot_finish_without_activation_and_evidence
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Premature completion")

      result = run_command(RbConfig.ruby, script(project, "finish_stream.rb"), id, "docs-sync", chdir: project)
      refute result.success?
      assert_match(/in_progress|lock|evidence|Pending|Not started/i, result.combined)

      feature = load_yaml(File.join(feature_dir(project), "feature.yaml"))
      refute_equal "done", feature["status"]
    end
  end

  def test_tier3_policy_declares_reviewer_and_human_approvals
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier3", title: "Protected deployment")

      result = run!(RbConfig.ruby, script(project, "check_workflow_policy.rb"), "--feature", id, "--json", chdir: project)
      policy = JSON.parse(result.stdout)
      assert_equal "tier3", policy.fetch("effective_tier")
      assert_equal true, policy.dig("required_approvals", "reviewer")
      assert_equal true, policy.dig("required_approvals", "human")
    end
  end

  def test_context_collection_refuses_a_protected_path
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Protected context")
      context_map_path = File.join(project, ".ai", "canonical", "context-map.yaml")
      context_map = load_yaml(context_map_path)
      context_map.fetch("agent_profiles").fetch("ai-worker").fetch("include") << ".env"
      write_yaml(context_map_path, context_map)
      write_file(File.join(project, ".env"), "SECRET_DO_NOT_PRINT=synthetic\n")

      result = run_command(RbConfig.ruby, script(project, "collect_context.rb"), id, "docs-sync", chdir: project)
      refute result.success?
      refute_includes result.combined, "SECRET_DO_NOT_PRINT"
      assert_match(/protected/i, result.combined)
    end
  end

  def test_source_only_pre_push_range_is_inferred_without_local_active_context
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      create_feature!(project, tier: "tier2", title: "Source only push")
      feature = load_yaml(File.join(feature_dir(project), "feature.yaml"))
      feature["doc_impact"]["must_update"] = []
      feature["doc_impact"]["no_impact_reason"] = "No durable contract changes in this fixture."
      write_yaml(File.join(feature_dir(project), "feature.yaml"), feature)
      backend_manifest_path = File.join(feature_dir(project), "streams", "backend-dev", "manifest.yaml")
      backend_manifest = load_yaml(backend_manifest_path)
      backend_manifest["doc_scope"]["must_update"] = []
      write_yaml(backend_manifest_path, backend_manifest)
      commit_all!(project, "feature ownership metadata")
      remote_sha = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      write_file(File.join(project, "backend", "source_only.rb"), "SOURCE_ONLY = true\n")
      commit_all!(project, "source-only commit")
      local_sha = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      FileUtils.rm_f(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))

      input = "refs/heads/main #{local_sha} refs/heads/main #{remote_sha}\n"
      result = run_command(
        File.join(project, ".ai", "runtime", "githooks", "pre-push"),
        "origin",
        "example.invalid/repo.git",
        chdir: project,
        stdin_data: input,
      )
      assert result.success?, result.combined
      assert_includes result.combined, "#{remote_sha}..#{local_sha}"
      assert_includes result.combined, "change-set validation passed"
    end
  end

  def test_failed_validation_evidence_cannot_finish_a_stream
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Failed evidence")
      complete_stream_documents(project, id, "docs-sync")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "docs-sync", "codex-app", chdir: project)
      write_completion_evidence(project, id, "docs-sync", exit_code: 1)

      result = run_command(RbConfig.ruby, script(project, "finish_stream.rb"), id, "docs-sync", chdir: project)
      refute result.success?
      assert_match(/exit_code must be integer 0/, result.combined)
      refute_equal "done", load_yaml(File.join(feature_dir(project), "streams", "docs-sync", "manifest.yaml"))["status"]
    end
  end

  def test_tier3_review_and_human_approval_bind_to_revision_and_become_stale
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier3", title: "Bound approval")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "reviewer", "codex-app", chdir: project)
      write_valid_review(project, id, require_human: true)

      passed = run_command(RbConfig.ruby, script(project, "check_workflow_policy.rb"), "--feature", id, "--finish", chdir: project)
      assert passed.success?, passed.combined

      write_file(File.join(project, "backend", "changed_after_review.rb"), "CHANGED = true\n")
      stale = run_command(RbConfig.ruby, script(project, "check_workflow_policy.rb"), "--feature", id, "--finish", chdir: project)
      refute stale.success?
      assert_includes stale.combined, "POLICY_REVIEW_STALE"
    end
  end

  def test_non_reviewer_stream_cannot_supply_review_approval
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Independent reviewer")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      FileUtils.rm_f(File.join(feature_dir(project), "streams", "reviewer", "review.yaml"))
      digest = feature_digest(project, id)
      now = Time.now.utc.iso8601
      write_yaml(File.join(feature_dir(project), "streams", "backend-dev", "review.yaml"), {
        "schema_version" => 1,
        "feature_id" => id,
        "reviewed_revision" => { "type" => "change_set_digest", "value" => digest },
        "reviewer_profile" => "reviewer",
        "reviewer_owner_agent" => "codex-app",
        "status" => "passed",
        "reviewed_at" => now,
        "findings_open" => 0,
      })

      result = run_command(RbConfig.ruby, script(project, "check_workflow_policy.rb"), "--feature", id, "--finish", chdir: project)
      refute result.success?
      assert_match(/reviewer-profile review\.yaml is required/, result.combined)
    end
  end

  def test_staged_implementation_requires_declared_documents
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Document impact")
      commit_all!(project, "feature scaffold")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "backend-dev", "codex-app", chdir: project)
      write_file(File.join(project, "backend", "change.rb"), "CHANGE = true\n")
      run!("git", "add", "backend/change.rb", chdir: project)

      result = run_command(
        RbConfig.ruby,
        script(project, "validate_docs_sync.rb"),
        "--staged",
        "--repo-root",
        project,
        chdir: project,
      )
      refute result.success?
      assert_match(/required document was not added or updated/, result.combined)
      assert_match(/handoff\.md|PROJECT_RULES\.md/, result.combined)
    end
  end

  def test_completion_evidence_rejects_secrets_and_raw_output
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Secret evidence")
      complete_stream_documents(project, id, "docs-sync")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "docs-sync", "codex-app", chdir: project)
      evidence_path = write_completion_evidence(
        project,
        id,
        "docs-sync",
        command: "TOKEN=synthetic-secret-value ruby test.rb",
      )
      evidence = load_yaml(evidence_path)
      evidence["validations"].first["stdout"] = "sensitive command output"
      write_yaml(evidence_path, evidence)

      result = run_command(RbConfig.ruby, script(project, "finish_stream.rb"), id, "docs-sync", chdir: project)
      refute result.success?
      assert_match(/appears to contain a secret/, result.combined)
      assert_match(/raw command output is forbidden/, result.combined)
      refute_includes result.combined, "synthetic-secret-value"
    end
  end

  private

  def complete_stream_documents(project, id, stream_id)
    directory = feature_dir(project)
    write_file(File.join(directory, "spec.md"), "# Complete scope\n\n## Scope\n\nImplemented and validated.\n")
    write_file(File.join(directory, "contracts", "acceptance.md"), "# Acceptance Contract\n\n- [x] Verified locally.\n")
    write_file(File.join(directory, "streams", stream_id, "handoff.md"), <<~MARKDOWN)
      # Handoff

      ## Status

      Complete.

      ## Validation

      - Workflow validation passed.

      ## Doc Sync

      - Canonical updated: yes
      - Remaining drift: none
    MARKDOWN
  end

  def feature_digest(project, id)
    code = 'require ARGV.shift; puts WorkflowEvidence.feature_change_set(ARGV.shift)["digest"]'
    run!(RbConfig.ruby, "-e", code, script(project, "workflow_evidence.rb"), id, chdir: project).stdout.strip
  end

  def write_completion_evidence(project, id, stream_id, exit_code: 0, command: "ruby .ai/runtime/scripts/validate_agent_structure.rb")
    directory = feature_dir(project)
    feature = load_yaml(File.join(directory, "feature.yaml"))
    path = File.join(directory, "streams", stream_id, "evidence.yaml")
    evidence = load_yaml(path)
    evidence["validated_revision"] = {
      "type" => "change_set_digest",
      "value" => feature_digest(project, id),
      "baseline_ref" => feature["baseline_ref"],
    }
    evidence["implementation_complete"] = true
    evidence["acceptance_complete"] = true
    evidence["docs_synced"] = true
    evidence["validations"] = [{
      "command" => command,
      "exit_code" => exit_code,
      "executed_at" => Time.now.utc.iso8601,
      "output_digest" => "sha256:#{Digest::SHA256.hexdigest('synthetic validation output')}",
    }]
    evidence["remaining_drift"] = []
    write_yaml(path, evidence)
    path
  end

  def write_valid_review(project, id, require_human:)
    directory = feature_dir(project)
    feature = load_yaml(File.join(directory, "feature.yaml"))
    digest = feature_digest(project, id)
    now = Time.now.utc.iso8601
    review = {
      "schema_version" => 1,
      "feature_id" => id,
      "reviewed_revision" => {
        "type" => "change_set_digest",
        "value" => digest,
        "baseline_ref" => feature["baseline_ref"],
      },
      "reviewer_profile" => "reviewer",
      "reviewer_owner_agent" => "codex-app",
      "status" => "passed",
      "reviewed_at" => now,
      "findings_open" => 0,
      "human_approval" => {
        "required" => require_human,
        "status" => require_human ? "approved" : "not_required",
        "approved_by" => require_human ? "workflow-test-human" : nil,
        "source" => require_human ? "human_record" : nil,
        "approved_at" => require_human ? now : nil,
        "approved_revision" => require_human ? { "type" => "change_set_digest", "value" => digest } : nil,
      },
    }
    write_yaml(File.join(directory, "streams", "reviewer", "review.yaml"), review)
  end
end
