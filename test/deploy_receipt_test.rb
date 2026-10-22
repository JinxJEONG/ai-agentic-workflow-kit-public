# frozen_string_literal: true

require "digest"
require "json"
require_relative "test_helper"
require_relative "../engine/facts/generate_deploy_receipt"
require_relative "../engine/validators/verify_deploy_receipt"

class DeployReceiptTest < Minitest::Test
  CHECK_APP_ID = 15_368

  def build_project(project, release_wrapper_required: false)
    write_file(File.join(project, "src", "service.rb"), "VALUE = 1\n")
    registry = {
      "schema_version" => 1,
      "project_id" => "fixture",
      "additional_high_risk_globs" => ["src/**"],
      "rules" => [{
        "id" => "service", "source_globs" => ["src/**"],
        "canonical_specs" => [".ai/canonical/service.md"], "generated_facts" => [],
        "checks" => release_wrapper_required ? ["python-symbols", "release-wrapper-required"] : ["python-symbols"],
        "impact_policy" => "spec_update_required",
        "codeowners" => ["@fixture-owner"],
      }],
    }
    registry_raw = YAML.dump(registry)
    write_file(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), registry_raw)
    digest = "sha256:#{'a' * 64}"
    lock = {
      "schema_version" => 2, "project_id" => "fixture", "kit_version" => "0.4.0",
      "kit_bundle_digest" => digest, "rendered_install_digest" => "sha256:#{'b' * 64}",
    }
    write_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"), lock)
    write_file(File.join(project, ".ai", "canonical", "service.md"), "# service\n")
    write_file(File.join(project, "deploy", "release.rb"), "puts 'release wrapper'\n")
    commit_all!(project, "inputs")
    source_digest = WorkflowKit::SourceTree.digest(WorkflowKit::SourceTree.entries(project, ["src/**"], ref: "HEAD"))
    artifact = File.join(project, "build", "artifact.tar")
    write_file(artifact, "deployable artifact bytes\n")
    receipt = {
      "receipt_schema" => 2,
      "kit_version" => "0.4.0",
      "kit_bundle_digest" => digest,
      "rendered_install_digest" => "sha256:#{'b' * 64}",
      "spec_registry_digest" => "sha256:#{Digest::SHA256.hexdigest(registry_raw)}",
      "source_digest_algo" => 1,
      "rules" => [{ "rule_id" => "service", "source_tree_digest" => source_digest }],
      "generated_facts" => [],
      "project_release_evidence" => {
        "artifact_digest" => "sha256:#{Digest::SHA256.file(artifact).hexdigest}",
        "immutable_copy_required" => true,
      },
    }
    receipt["project_release_evidence"]["wrapper"] = "deploy/release.rb" if release_wrapper_required
    write_file(File.join(project, ".ai", "generated", "deploy-receipt.json"), JSON.pretty_generate(receipt))
    commit_all!(project, "receipt")
    artifact
  end

  def required_checks(name: "spec-gate", app_id: CHECK_APP_ID)
    {
      "contexts" => [name],
      "checks" => [{ "context" => name, "app_id" => app_id }],
    }
  end

  def successful_run(project, name: "spec-gate", head_sha: nil, app_id: CHECK_APP_ID)
    {
      "name" => name,
      "status" => "completed",
      "conclusion" => "success",
      "head_sha" => head_sha || run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip,
      "app" => { "id" => app_id, "slug" => "github-actions" },
    }
  end

  def test_exact_digest_and_external_check_evidence_pass
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )
      assert result["valid"], result["errors"].join("\n")
    end
  end

  def test_in_repo_required_checks_claim_is_rejected_by_schema
    with_project do |project|
      artifact = build_project(project)
      path = File.join(project, ".ai", "generated", "deploy-receipt.json")
      value = JSON.parse(File.read(path))
      value["required_checks"] = "success"
      write_file(path, JSON.pretty_generate(value))
      commit_all!(project, "forge receipt")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )
      refute result["valid"]
      assert result["errors"].any? { |error| error.include?("required_checks") }
    end
  end

  def test_receipt_requires_an_immutable_copy_for_the_later_deploy_boundary
    with_project do |project|
      artifact = build_project(project)
      path = File.join(project, ".ai", "generated", "deploy-receipt.json")
      value = JSON.parse(File.read(path))
      value["project_release_evidence"]["immutable_copy_required"] = false
      write_file(path, JSON.pretty_generate(value))
      commit_all!(project, "weaken artifact custody")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )

      refute result["valid"]
      assert result["errors"].any? { |error| error.include?("immutable_copy_required") }
    end
  end

  def test_failed_external_check_blocks_deploy
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project).merge("conclusion" => "failure")] }, artifact_path: artifact,
      )
      assert_includes result["errors"], "required_check_not_successful: spec-gate"
    end
  end

  def test_missing_required_check_fails_closed_without_an_exception
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [] }, artifact_path: artifact,
      )

      refute result["valid"]
      assert_includes result["errors"], "required_check_ambiguous: spec-gate"
      assert_includes result["errors"], "required_check_not_successful: spec-gate"
    end
  end

  def test_duplicate_check_name_cannot_hide_a_failure
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [
          successful_run(project).merge("conclusion" => "failure"),
          successful_run(project),
        ] }, artifact_path: artifact,
      )
      assert_includes result["errors"], "required_check_ambiguous: spec-gate"
      assert_includes result["errors"], "required_check_not_successful: spec-gate"
    end
  end

  def test_success_from_a_different_sha_is_rejected
    with_project do |project|
      artifact = build_project(project)
      wrong = successful_run(project).merge("head_sha" => "f" * 40)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [wrong] }, artifact_path: artifact,
      )
      assert_includes result["errors"], "required_check_wrong_sha: spec-gate"
    end
  end

  def test_artifact_bytes_are_bound_to_the_receipt
    with_project do |project|
      artifact = build_project(project)
      write_file(artifact, "tampered artifact\n")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )
      assert_includes result["errors"], "deployment_artifact_digest_mismatch"
    end
  end

  def test_required_check_is_bound_to_the_expected_github_app
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project, app_id: CHECK_APP_ID + 1)] },
        artifact_path: artifact,
      )

      refute result["valid"]
      assert_includes result["errors"],
        "required_check_wrong_app: spec-gate expected=#{CHECK_APP_ID} actual=#{CHECK_APP_ID + 1}"
      assert_includes result["errors"], "required_check_not_successful: spec-gate"
    end
  end

  def test_context_only_required_check_evidence_fails_closed
    with_project do |project|
      artifact = build_project(project)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: { "contexts" => ["spec-gate"] },
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )

      refute result["valid"]
      assert_includes result["errors"], "required_check_app_binding_missing: spec-gate"
    end
  end

  def test_artifact_symlink_is_rejected_before_following_it
    with_project do |project|
      artifact = build_project(project)
      link = File.join(project, "build", "artifact-link.tar")
      File.symlink(artifact, link)
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: link,
      )

      refute result["valid"]
      assert_includes result["errors"], "deployment_artifact_symlink"
    end
  end

  def test_artifact_path_with_a_symlinked_parent_is_rejected
    with_project do |project|
      artifact = build_project(project)
      parent_link = File.join(project, "linked-build")
      File.symlink(File.dirname(artifact), parent_link)
      linked_artifact = File.join(parent_link, File.basename(artifact))
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: linked_artifact,
      )

      refute result["valid"]
      assert_includes result["errors"], "deployment_artifact_symlink"
    end
  end

  def test_artifact_rename_swap_is_detected_by_the_final_recheck
    with_project do |project|
      artifact = build_project(project)
      original_snapshot = WorkflowKit::ArtifactFile.method(:snapshot)
      calls = 0
      snapshot_with_swap = lambda do |path|
        snapshot = original_snapshot.call(path)
        calls += 1
        if calls == 1
          File.rename(artifact, "#{artifact}.verified-original")
          write_file(artifact, "attacker replacement bytes\n")
        end
        snapshot
      end

      result = nil
      WorkflowKit::ArtifactFile.stub(:snapshot, snapshot_with_swap) do
        result = WorkflowKit::DeployReceipt.verify(
          root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
          required_checks: required_checks,
          actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
        )
      end

      refute result["valid"]
      assert_includes result["errors"], "deployment_artifact_changed_during_verification"
      assert_equal 2, calls
    end
  end

  def test_release_wrapper_is_only_required_when_the_registry_declares_the_check
    with_project do |project|
      artifact = build_project(project)
      FileUtils.rm(File.join(project, "deploy", "release.rb"))
      commit_all!(project, "remove unused wrapper")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )

      assert result["valid"], result["errors"].join("\n")
    end
  end

  def test_release_wrapper_check_requires_the_exact_wrapper
    with_project do |project|
      artifact = build_project(project, release_wrapper_required: true)
      receipt_path = File.join(project, ".ai", "generated", "deploy-receipt.json")
      receipt = JSON.parse(File.read(receipt_path))
      receipt["project_release_evidence"]["wrapper"] = "deploy/other.rb"
      write_file(File.join(project, "deploy", "other.rb"), "puts 'not the approved wrapper'\n")
      write_file(receipt_path, JSON.pretty_generate(receipt))
      commit_all!(project, "forge wrapper")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )

      refute result["valid"]
      assert_includes result["errors"], "release_wrapper_mismatch: expected deploy/release.rb"
    end
  end

  def test_symbolic_ref_is_pinned_once_for_every_repository_read
    with_project do |project|
      artifact = build_project(project)
      pinned = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      run!("git", "branch", "deploy-candidate", pinned, chdir: project)
      write_file(File.join(project, "src", "service.rb"), "VALUE = 999\n")
      commit_all!(project, "moving target")
      moved = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      blob_refs = []
      source_refs = []
      original_blob = WorkflowKit::DeployReceipt.method(:blob)
      original_entries = WorkflowKit::SourceTree.method(:entries)
      first_read = true
      blob_spy = lambda do |root, commit, path|
        blob_refs << commit
        if first_read
          run!("git", "update-ref", "refs/heads/deploy-candidate", moved, chdir: project)
          first_read = false
        end
        original_blob.call(root, commit, path)
      end
      entries_spy = lambda do |root, globs, ref: "HEAD"|
        source_refs << ref
        original_entries.call(root, globs, ref: ref)
      end

      result = nil
      WorkflowKit::DeployReceipt.stub(:blob, blob_spy) do
        WorkflowKit::SourceTree.stub(:entries, entries_spy) do
          result = WorkflowKit::DeployReceipt.verify(
            root: project, ref: "deploy-candidate", receipt_path: ".ai/generated/deploy-receipt.json",
            required_checks: required_checks,
            actual_checks: { "check_runs" => [successful_run(project, head_sha: pinned)] }, artifact_path: artifact,
          )
        end
      end

      assert result["valid"], result["errors"].join("\n")
      assert_equal pinned, result["ref"]
      assert_equal [pinned], blob_refs.uniq
      assert_equal [pinned], source_refs.uniq
      assert_equal moved, run!("git", "rev-parse", "deploy-candidate", chdir: project).stdout.strip
    end
  end

  def test_generator_is_deterministic_and_emits_a_verifiable_receipt
    with_project do |project|
      artifact = build_project(project)
      command = [
        RbConfig.ruby,
        File.join(KIT_ROOT, "engine", "facts", "generate_deploy_receipt.rb"),
        "--root", project,
        "--sha", "HEAD",
        "--artifact", artifact,
      ]
      first = run_command(*command)
      second = run_command(*command)
      assert first.success?, first.combined
      assert second.success?, second.combined
      assert_equal first.stdout, second.stdout

      generated = JSON.parse(first.stdout)
      assert_equal ["service"], generated.fetch("rules").map { |rule| rule.fetch("rule_id") }
      refute generated.fetch("project_release_evidence").key?("wrapper")
      output = File.join(project, ".ai", "generated", "deploy-receipt.json")
      write_file(output, first.stdout)
      commit_all!(project, "generated deterministic receipt")
      result = WorkflowKit::DeployReceipt.verify(
        root: project, ref: "HEAD", receipt_path: ".ai/generated/deploy-receipt.json",
        required_checks: required_checks,
        actual_checks: { "check_runs" => [successful_run(project)] }, artifact_path: artifact,
      )
      assert result["valid"], result["errors"].join("\n")
    end
  end

  def test_generator_emits_the_exact_wrapper_only_when_required
    with_project do |project|
      artifact = build_project(project, release_wrapper_required: true)
      receipt = WorkflowKit::DeployReceiptGenerator.build(
        root: project,
        ref: "HEAD",
        artifact_path: artifact,
      )

      assert_equal "deploy/release.rb", receipt.dig("project_release_evidence", "wrapper")
    end
  end

  def test_generator_rejects_an_artifact_symlink
    with_project do |project|
      artifact = build_project(project)
      link = File.join(project, "build", "generator-artifact-link.tar")
      File.symlink(artifact, link)

      error = assert_raises(ArgumentError) do
        WorkflowKit::DeployReceiptGenerator.build(
          root: project,
          ref: "HEAD",
          artifact_path: link,
        )
      end
      assert_match(/cannot securely open deployment artifact component/, error.message)
    end
  end
end
