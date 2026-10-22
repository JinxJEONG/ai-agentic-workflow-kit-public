# frozen_string_literal: true

require "digest"
require "time"
require_relative "test_helper"

class LifecyclePolicyTest < Minitest::Test
  def test_initial_installation_change_set_is_allowed
    with_project do |project|
      bootstrap!(project)
      run!("git", "add", ".", chdir: project)

      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      assert result.success?, result.combined
      assert_includes result.combined, "initial kit installation manifest owns this bootstrap change set"

      commit_all!(project, "initial workflow kit installation")
      empty_tree = run!("git", "mktree", chdir: project, stdin_data: "").stdout.strip
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      range_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{empty_tree}..#{head}",
        chdir: project,
      )

      assert range_result.success?, range_result.combined
      assert_includes range_result.combined, "initial kit installation manifest owns this bootstrap change set"
    end
  end

  def test_existing_project_accepts_one_dedicated_install_commit
    with_project do |project|
      write_file(File.join(project, "README.md"), "# Existing project\n")
      commit_all!(project, "existing project baseline")
      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      bootstrap!(project)
      commit_all!(project, "initial workflow kit installation")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{head}",
        chdir: project,
      )

      assert result.success?, result.combined
      assert_includes result.combined, "initial kit installation manifest owns this bootstrap change set"
    end
  end

  def test_partial_initial_installation_is_rejected_before_commit_and_push
    with_project do |project|
      write_file(File.join(project, "README.md"), "# Existing project\n")
      commit_all!(project, "existing project baseline")
      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      bootstrap!(project)
      run!("git", "add", ".ai/KIT_INSTALLATION.yaml", chdir: project)
      staged_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      refute staged_result.success?
      assert_includes staged_result.combined, "initial bootstrap must stage every installed file"

      run!("git", "commit", "--no-verify", "-m", "partial workflow kit installation", chdir: project)
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      input = "refs/heads/main #{head} refs/heads/main #{baseline}\n"
      pre_push_result = run_command(
        File.join(project, ".ai", "runtime", "githooks", "pre-push"),
        "origin",
        "example.invalid/repo.git",
        chdir: project,
        stdin_data: input,
      )

      refute pre_push_result.success?
      assert_includes pre_push_result.combined, "initial bootstrap must stage every installed file"
    end
  end

  def test_installation_manifest_cannot_reopen_bootstrap_after_baseline
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)

      application_path = File.join(project, "src", "unowned.rb")
      write_file(application_path, "UNOWNED = true\n")
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest.fetch("installed_files") << {
        "path" => "src/unowned.rb",
        "sha256" => Digest::SHA256.file(application_path).hexdigest,
        "mode" => format("%04o", File.stat(application_path).mode & 0o7777),
        "ownership" => "kit",
      }
      write_yaml(manifest_path, manifest)
      run!("git", "add", ".ai/KIT_INSTALLATION.yaml", "src/unowned.rb", chdir: project)

      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      refute result.success?
      assert_includes result.combined, "src/unowned.rb"
      assert_includes result.combined, "does not declare or activate an owning feature"

      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      commit_all!(project, "attempt to reopen bootstrap ownership")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      range_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{head}",
        chdir: project,
      )

      refute range_result.success?
      assert_includes range_result.combined, "src/unowned.rb"
      assert_includes range_result.combined, "does not declare or activate an owning feature"
    end
  end

  def test_initial_push_range_cannot_bundle_manifest_ownership_escalation
    with_project do |project|
      write_file(File.join(project, "README.md"), "# Existing project\n")
      commit_all!(project, "existing project baseline")
      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      bootstrap!(project)
      commit_all!(project, "initial workflow kit installation")

      application_path = File.join(project, "src", "unowned.rb")
      write_file(application_path, "UNOWNED = true\n")
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest.fetch("installed_files") << {
        "path" => "src/unowned.rb",
        "sha256" => Digest::SHA256.file(application_path).hexdigest,
        "mode" => format("%04o", File.stat(application_path).mode & 0o7777),
        "ownership" => "kit",
      }
      write_yaml(manifest_path, manifest)
      commit_all!(project, "attempt bundled bootstrap ownership escalation")

      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{head}",
        chdir: project,
      )

      refute result.success?
      assert_includes result.combined, "src/unowned.rb"
      assert_includes result.combined, "does not declare or activate an owning feature"

      input = "refs/heads/main #{head} refs/heads/main #{baseline}\n"
      pre_push_result = run_command(
        File.join(project, ".ai", "runtime", "githooks", "pre-push"),
        "origin",
        "example.invalid/repo.git",
        chdir: project,
        stdin_data: input,
      )

      refute pre_push_result.success?
      assert_includes pre_push_result.combined, "src/unowned.rb"
      assert_includes pre_push_result.combined, "change-set validation failed"
    end
  end

  def test_initial_push_range_rejects_kit_tamper_after_install_commit
    with_project do |project|
      write_file(File.join(project, "README.md"), "# Existing project\n")
      commit_all!(project, "existing project baseline")
      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      bootstrap!(project)
      commit_all!(project, "initial workflow kit installation")

      relative_path = ".ai/runtime/scripts/workflow_policy.rb"
      managed_path = File.join(project, relative_path)
      write_file(managed_path, File.binread(managed_path) + "\n# bundled post-install tamper\n")
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      entry = manifest.fetch("installed_files").find { |item| item["path"] == relative_path }
      entry["sha256"] = Digest::SHA256.file(managed_path).hexdigest
      write_yaml(manifest_path, manifest)
      commit_all!(project, "tamper with installed workflow policy")

      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{head}",
        chdir: project,
      )

      refute result.success?
      assert_includes result.combined, "initial bootstrap must be exactly one installation commit"

      input = "refs/heads/main #{head} refs/heads/main #{baseline}\n"
      pre_push_result = run_command(
        File.join(project, ".ai", "runtime", "githooks", "pre-push"),
        "origin",
        "example.invalid/repo.git",
        chdir: project,
        stdin_data: input,
      )

      refute pre_push_result.success?
      assert_includes pre_push_result.combined, "initial bootstrap must be exactly one installation commit"
    end
  end

  def test_initial_installation_rejects_kit_owned_digest_and_mode_drift
    with_project do |project|
      bootstrap!(project)
      relative_path = ".ai/runtime/scripts/workflow_policy.rb"
      managed_path = File.join(project, relative_path)
      original_content = File.binread(managed_path)
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      entry = manifest.fetch("installed_files").find { |item| item["path"] == relative_path }

      drifted_content = original_content + "\n# unrecorded bootstrap drift\n"
      write_file(managed_path, drifted_content)
      run!("git", "add", ".", chdir: project)
      write_file(managed_path, original_content)
      snapshot_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      refute snapshot_result.success?
      assert_includes snapshot_result.combined, "#{relative_path}: kit-owned index and working tree differ"

      write_file(managed_path, drifted_content)
      run!("git", "add", managed_path, chdir: project)
      digest_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      refute digest_result.success?
      assert_includes digest_result.combined, "#{relative_path}: kit-owned digest mismatch"

      write_file(managed_path, original_content)
      expected_mode = entry.fetch("mode").to_i(8)
      File.chmod(expected_mode == 0o644 ? 0o755 : 0o644, managed_path)
      run!("git", "add", managed_path, chdir: project)
      mode_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )

      refute mode_result.success?
      assert_includes mode_result.combined, "#{relative_path}: kit-owned mode mismatch"
    end
  end

  def test_tier1_feature_scaffold_passes_the_real_pre_commit_gate
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Commit owned scaffold")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "docs-sync", "codex-app", chdir: project)
      run!("git", "add", ".ai/tasks", chdir: project)

      result = run_command(File.join(project, ".ai", "runtime", "githooks", "pre-commit"), chdir: project)
      assert result.success?, result.combined
      assert_includes result.combined, "change-set validation passed"
    end
  end

  def test_valid_tier1_feature_finishes_without_claiming_deployment
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier1", title: "Validated local completion")
      complete_stream_documents(project, id, "docs-sync")
      run!(RbConfig.ruby, script(project, "activate_stream.rb"), id, "docs-sync", "codex-app", chdir: project)
      write_valid_evidence(project, id, "docs-sync")

      run!(RbConfig.ruby, script(project, "finish_stream.rb"), id, "docs-sync", chdir: project)
      result = run!(RbConfig.ruby, script(project, "finish_feature.rb"), id, chdir: project)

      feature = load_yaml(File.join(feature_dir(project), "feature.yaml"))
      change_set = load_yaml(File.join(feature_dir(project), "change-set.yaml"))
      context = load_yaml(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))
      assert_equal "done", feature["status"]
      assert_equal "not_deployed", feature["deployment_status"]
      assert_equal "validated", change_set["status"]
      assert_match(/\Asha256:[0-9a-f]{64}\z/, change_set["change_set_digest"])
      assert_empty context.fetch("active_streams")
      assert_empty context.fetch("active_features")
      assert_includes result.stdout, "deployment_status=not_deployed"

      commit_all!(project, "completed feature")
      baseline = feature.fetch("baseline_ref")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      ci_result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{head}",
        chdir: project,
      )
      assert ci_result.success?, ci_result.combined

      evidence_path = File.join(feature_dir(project), "streams", "docs-sync", "evidence.yaml")
      evidence = load_yaml(evidence_path)
      evidence["validations"].first["stdout"] = "raw output must not be trusted by CI"
      write_yaml(evidence_path, evidence)
      commit_all!(project, "tampered evidence")
      tampered_head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      tampered = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "range",
        "--range",
        "#{baseline}..#{tampered_head}",
        chdir: project,
      )
      refute tampered.success?
      assert_includes tampered.combined, "POLICY_COMPLETION_INVALID"
      assert_includes tampered.combined, "raw command output is forbidden"
    end
  end

  def test_declared_tier_cannot_downgrade_path_or_explicit_risk
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      id = create_feature!(project, tier: "tier2", title: "Tier downgrade attempt")

      path_result = run_command(
        RbConfig.ruby,
        script(project, "check_workflow_policy.rb"),
        "--feature",
        id,
        "--path",
        "deploy/application.yaml",
        chdir: project,
      )
      refute path_result.success?
      assert_includes path_result.combined, "POLICY_TIER_TOO_LOW"

      feature_path = File.join(feature_dir(project), "feature.yaml")
      feature = load_yaml(feature_path)
      feature.fetch("risk_signals")["authentication"] = true
      write_yaml(feature_path, feature)
      signal_result = run_command(
        RbConfig.ruby,
        script(project, "check_workflow_policy.rb"),
        "--feature",
        id,
        chdir: project,
      )
      refute signal_result.success?
      assert_includes signal_result.combined, "POLICY_TIER_TOO_LOW"
      assert_includes signal_result.combined, "authentication"
    end
  end

  def test_pre_push_rejects_an_unowned_commit_even_with_an_empty_index
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      create_feature!(project, tier: "tier2", title: "Owned backend change")
      commit_all!(project, "feature metadata")
      remote_sha = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      write_file(File.join(project, "misc", "unowned.rb"), "UNOWNED = true\n")
      commit_all!(project, "hook-bypassed unowned change")
      local_sha = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      assert_empty run!("git", "diff", "--cached", "--name-only", chdir: project).stdout
      FileUtils.rm_f(File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"))

      input = "refs/heads/main #{local_sha} refs/heads/main #{remote_sha}\n"
      result = run_command(
        File.join(project, ".ai", "runtime", "githooks", "pre-push"),
        "origin",
        "example.invalid/repo.git",
        chdir: project,
        stdin_data: input,
      )
      refute result.success?
      assert_includes result.combined, "misc/unowned.rb"
      assert_includes result.combined, "change-set validation failed"
    end
  end

  def test_one_change_set_cannot_mix_multiple_features
    with_project do |project|
      bootstrap!(project)
      commit_all!(project)
      create_feature!(project, tier: "tier1", title: "First isolated feature")
      create_feature!(project, tier: "tier1", title: "Second isolated feature")
      run!("git", "add", ".ai/tasks", chdir: project)

      result = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode",
        "staged",
        chdir: project,
      )
      refute result.success?
      assert_includes result.combined, "one feature is allowed per change set"
      assert_match(/FEATURE-\d{8}-001.*FEATURE-\d{8}-002/, result.combined)
    end
  end

  private

  def complete_stream_documents(project, _id, stream_id)
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

  def write_valid_evidence(project, id, stream_id)
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
      "command" => "ruby .ai/runtime/scripts/validate_agent_structure.rb",
      "exit_code" => 0,
      "executed_at" => Time.now.utc.iso8601,
      "output_digest" => "sha256:#{Digest::SHA256.hexdigest('synthetic successful validation')}",
    }]
    evidence["remaining_drift"] = []
    write_yaml(path, evidence)
  end
end
