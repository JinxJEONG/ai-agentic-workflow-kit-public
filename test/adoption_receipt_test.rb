# frozen_string_literal: true

require "digest"
require "json"
require_relative "test_helper"
require_relative "../engine/validators/schema"

class AdoptionReceiptTest < Minitest::Test
  RECEIPT_PATH = File.join(".ai", "generated", "adoption-receipt.json")

  def test_receipt_is_deterministic_self_excluding_and_verifies_from_head
    with_project do |project|
      write_file(File.join(project, "README.md"), "# Existing project\n")
      commit_all!(project, "existing baseline")
      baseline = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      plan_digest = apply_with_reviewed_plan(project)
      run!("git", "add", "-A", chdir: project)

      first = generate_receipt(project, plan_digest)
      first_bytes = File.binread(File.join(project, RECEIPT_PATH))
      run!("git", "add", RECEIPT_PATH, chdir: project)
      second = generate_receipt(project, plan_digest)
      second_bytes = File.binread(File.join(project, RECEIPT_PATH))

      assert_equal first, second
      assert_equal first_bytes, second_bytes
      assert_equal 1, first.fetch("receipt_schema")
      assert_equal "main", first.fetch("adopted_branch")
      assert_equal plan_digest, first.fetch("plan_digest")
      refute first.keys.any? { |key| key.match?(/commit|code_sha/) }

      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      assert_equal manifest.fetch("kit_version"), first.fetch("kit_version")
      assert_equal manifest.fetch("kit_bundle_digest"), first.fetch("kit_bundle_digest")
      assert_equal manifest.fetch("rendered_install_digest"), first.fetch("rendered_install_digest")
      schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "adoption-receipt.schema.yaml"))
      assert_empty WorkflowKit::Schema.validate(first, schema)

      run!("git", "add", RECEIPT_PATH, chdir: project)
      commit_all!(project, "adopt workflow kit")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      verified = run!(RbConfig.ruby, script(project, "adoption_receipt.rb"), "verify", "--source", "HEAD", chdir: project)
      assert_includes verified.stdout, "adoption receipt is valid"
      range = run_command(
        RbConfig.ruby,
        script(project, "validate_change_set.rb"),
        "--mode", "range",
        "--range", "#{baseline}..#{head}",
        chdir: project,
      )
      assert range.success?, range.combined
      assert_includes range.combined, "reviewed adoption receipt owns this bounded change set"
    end
  end

  def test_receipt_rejects_harness_tamper_and_unknown_self_reference_field
    with_project do |project|
      run!("git", "commit", "--allow-empty", "-m", "baseline", chdir: project)
      plan_digest = apply_with_reviewed_plan(project)
      run!("git", "add", "-A", chdir: project)
      generate_receipt(project, plan_digest)
      commit_all!(project, "adopt workflow kit")

      managed = File.join(project, ".ai", "runtime", "scripts", "workflow_policy.rb")
      write_file(managed, File.binread(managed) + "\n# receipt tamper\n")
      commit_all!(project, "tamper harness")
      tampered = run_command(RbConfig.ruby, script(project, "adoption_receipt.rb"), "verify", "--source", "HEAD", chdir: project)
      refute tampered.success?
      assert_includes tampered.combined, "harness_tree_digest mismatch"

      receipt_path = File.join(project, RECEIPT_PATH)
      receipt = JSON.parse(File.read(receipt_path))
      receipt["commit"] = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      write_file(receipt_path, "#{JSON.pretty_generate(receipt)}\n")
      commit_all!(project, "add forbidden self reference")
      forbidden = run_command(RbConfig.ruby, script(project, "adoption_receipt.rb"), "verify", "--source", "HEAD", chdir: project)
      refute forbidden.success?
      assert_includes forbidden.combined, "unknown fields: commit"
    end
  end

  def test_bounded_receipt_change_set_passes_but_business_and_project_owned_modifications_fail
    with_project do |project|
      bootstrap!(project)
      commit_all!(project, "installed baseline")
      create_feature!(project, tier: "tier1", title: "Unrelated historical feature one")
      create_feature!(project, tier: "tier1", title: "Unrelated historical feature two")
      commit_all!(project, "managed baseline")

      plan_digest = apply_with_reviewed_plan(project)
      run!("git", "add", "-A", chdir: project)
      generate_receipt(project, plan_digest)
      run!("git", "add", RECEIPT_PATH, chdir: project)

      accepted = validate_staged(project)
      assert accepted.success?, accepted.combined
      assert_includes accepted.combined, "reviewed adoption receipt owns this bounded change set"
      assert_includes accepted.combined, "isolates unrelated historical feature evidence"
      refute_includes accepted.combined, "one feature is allowed per change set"

      write_file(File.join(project, "src", "business.rb"), "BUSINESS = true\n")
      run!("git", "add", "src/business.rb", chdir: project)
      business = validate_staged(project)
      refute business.success?
      assert_includes business.combined, "does not declare or activate an owning feature"

      run!("git", "restore", "--staged", "src/business.rb", chdir: project)
      project_owned = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      write_file(project_owned, File.binread(project_owned) + "\nProject-owned adoption drift.\n")
      run!("git", "add", ".ai/canonical/PROJECT_RULES.md", chdir: project)
      generate_receipt(project, plan_digest)
      run!("git", "add", RECEIPT_PATH, chdir: project)
      project_change = validate_staged(project)
      refute project_change.success?
      assert_includes project_change.combined, "change-set validation failed"
      refute_includes project_change.combined, "reviewed adoption receipt owns this bounded change set"
    end
  end

  def test_reviewed_merge_owned_change_is_bound_in_migration_and_allowed
    with_project do |project|
      bootstrap!(project)
      commit_all!(project, "managed baseline")

      agents_path = File.join(project, "AGENTS.md")
      write_file(agents_path, File.binread(agents_path) + "\nProject customization.\n")
      commit_all!(project, "customize merge-owned adapter")
      current_digest = Digest::SHA256.file(agents_path).hexdigest
      approval = "AGENTS.md=#{current_digest}"
      Dir.mktmpdir("workflow-kit-reviewed-merge", WorkflowKitTestHelpers::FIXTURES_ROOT) do |directory|
        merged_path = File.join(directory, "AGENTS.md")
        merged_content = File.binread(agents_path) + "\nReviewed shared merge.\n"
        write_file(merged_path, merged_content)
        desired_digest = Digest::SHA256.hexdigest(merged_content)
        plan_digest = apply_with_reviewed_plan(
          project,
          "--approve-path", approval,
          "--merge-path", "AGENTS.md=#{merged_path}",
        )
        run!("git", "add", "-A", chdir: project)
        generate_receipt(project, plan_digest)
        run!("git", "add", RECEIPT_PATH, chdir: project)

        manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
        migration = manifest.fetch("migration_history").last
        assert_equal [{
          "path" => "AGENTS.md",
          "expected_digest" => current_digest,
          "desired_digest" => desired_digest,
        }], migration.fetch("reviewed_path_approvals")
        assert_equal merged_content, File.binread(agents_path)

        result = validate_staged(project)
        assert result.success?, result.combined
        assert_includes result.combined, "reviewed adoption receipt owns this bounded change set"
      end
    end
  end

  def test_merge_owned_adoption_rejects_forged_expected_digest
    with_reviewed_merge_adoption do |project, plan_digest|
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      approval = manifest.fetch("migration_history").last.fetch("reviewed_path_approvals").first
      approval["expected_digest"] = "0" * 64
      stage_manifest_and_receipt(project, manifest, plan_digest)

      result = validate_staged(project)
      refute result.success?
      assert_includes result.combined, "does not declare or activate an owning feature"
      refute_includes result.combined, "reviewed adoption receipt owns this bounded change set"
    end
  end

  def test_merge_owned_adoption_rejects_forged_desired_digest
    with_reviewed_merge_adoption do |project, plan_digest|
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      approval = manifest.fetch("migration_history").last.fetch("reviewed_path_approvals").first
      approval["desired_digest"] = "0" * 64
      stage_manifest_and_receipt(project, manifest, plan_digest)

      result = validate_staged(project)
      refute result.success?
      assert_includes result.combined, "does not declare or activate an owning feature"
      refute_includes result.combined, "reviewed adoption receipt owns this bounded change set"
    end
  end

  def test_merge_owned_adoption_rejects_forged_installed_digest
    with_reviewed_merge_adoption do |project, plan_digest|
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      installed = manifest.fetch("installed_files").find { |entry| entry.fetch("path") == "AGENTS.md" }
      installed["sha256"] = "0" * 64
      stage_manifest_and_receipt(project, manifest, plan_digest)

      result = validate_staged(project)
      refute result.success?
      assert_includes result.combined, "does not declare or activate an owning feature"
      refute_includes result.combined, "reviewed adoption receipt owns this bounded change set"
    end
  end

  def test_bounded_phase4_registry_bootstrap_uses_immutable_historical_receipt
    with_project do |project|
      bootstrap!(project)
      existing_contract = File.join(project, ".ai", "canonical", "contracts", "workflow.md")
      write_file(existing_contract, "# Existing workflow contract\n")
      reviewer_handoffs = [
        write_completed_reviewer_handoff(project, "FEATURE-20260101-001--historical-review"),
        write_completed_reviewer_handoff(project, "FEATURE-20260101-002"),
      ]
      ambiguous_handoffs = {
        "FEATURE-20260101-010--fenced-review" => :fenced,
        "FEATURE-20260101-011--commented-review" => :commented,
        "FEATURE-20260101-012--nested-review" => :nested,
        "FEATURE-20260101-013--setext-review" => :setext,
      }.map do |task_name, variant|
        path = write_completed_reviewer_handoff(project, task_name)
        write_ambiguous_reviewer_handoff(path, variant)
        path
      end
      commit_all!(project, "managed baseline")
      plan_digest = apply_with_reviewed_plan(project)
      run!("git", "add", "-A", chdir: project)
      generate_receipt(project, plan_digest)
      commit_all!(project, "adopt workflow kit")

      workflow_path = File.join(project, ".github", "workflows", "agent-workflow-policy.yml")
      current_digest = Digest::SHA256.file(workflow_path).hexdigest
      Dir.mktmpdir("workflow-kit-phase4-caller", WorkflowKitTestHelpers::FIXTURES_ROOT) do |directory|
        merged = File.join(directory, "agent-workflow-policy.yml")
        write_file(merged, File.binread(workflow_path) + "\n# reviewed Phase 4 caller\n")
        apply_with_reviewed_plan(
          project,
          "--approve-path", ".github/workflows/agent-workflow-policy.yml=#{current_digest}",
          "--merge-path", ".github/workflows/agent-workflow-policy.yml=#{merged}",
        )
      end

      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), {
        "schema_version" => 1,
        "project_id" => "fixture",
        "rules" => [{
          "id" => "workflow-contract",
          "source_globs" => [".github/workflows/**"],
          "canonical_specs" => [".ai/canonical/contracts/workflow.md"],
          "generated_facts" => [".ai/generated/workflow-inputs.json"],
          "checks" => ["deployment-inputs"],
          "impact_policy" => "spec_update_required",
          "codeowners" => ["@fixture-owner"],
        }],
      })
      write_file(existing_contract, <<~MARKDOWN)
        ---
        verified_against:
          rule_id: workflow-contract
          source_tree_digest: sha256:#{"0" * 64}
        ---

        # Existing workflow contract
      MARKDOWN
      write_file(File.join(project, ".ai", "generated", "workflow-inputs.json"), "{}\n")
      write_file(File.join(project, ".github", "CODEOWNERS"), "/.ai/SPEC_REGISTRY.yaml @fixture-owner\n")
      rebind_reviewer_handoff(project, reviewer_handoffs.first, "1" * 64)
      run!("git", "add", "-A", chdir: project)

      accepted = validate_staged(project)
      assert accepted.success?, accepted.combined
      assert_includes accepted.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      assert_includes accepted.combined, "immutable adoption receipt authorizes"
      assert_includes accepted.combined, "it is not approval evidence"
      refute_includes accepted.combined, "one feature is allowed per change set"

      restore_phase4_test_paths(project, [reviewer_handoffs.first])
      ambiguous_handoffs.each do |path|
        rebind_reviewer_handoff(project, path, "1" * 64)
        ambiguous = validate_staged(project)
        refute ambiguous.success?
        refute_includes ambiguous.combined, "bounded Phase 4 registry bootstrap owns governance paths"
        restore_phase4_test_paths(project, [path])
      end
      rebind_reviewer_handoff(project, reviewer_handoffs.first, "1" * 64)

      original_handoff = File.binread(reviewer_handoffs.first)
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        write_file(reviewer_handoffs.first, original_handoff.sub("## Findings", "## Findings\n\nChanged body."))
      end
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        write_file(reviewer_handoffs.first, original_handoff.sub("- Status: passed", "- Status: failed"))
      end
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        write_file(reviewer_handoffs.first, original_handoff.sub("## Doc Sync", "## Review Gate\n\n## Doc Sync"))
      end
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        write_file(
          reviewer_handoffs.first,
          original_handoff.sub("## Doc Sync", "- Approved Manifest SHA256: #{'2' * 64}\n\n## Doc Sync"),
        )
      end

      feature_path = File.join(File.dirname(File.dirname(File.dirname(reviewer_handoffs.first))), "feature.yaml")
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        feature = load_yaml(feature_path)
        feature["status"] = "in_progress"
        write_yaml(feature_path, feature)
      end
      manifest_path = File.join(File.dirname(reviewer_handoffs.first), "manifest.yaml")
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        manifest = load_yaml(manifest_path)
        manifest["status"] = "in_progress"
        write_yaml(manifest_path, manifest)
      end
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        File.chmod(0o755, reviewer_handoffs.first)
      end
      assert_phase4_handoff_rebind_rejected(project, reviewer_handoffs.first) do
        File.unlink(reviewer_handoffs.first)
        File.symlink("handoff-target.md", reviewer_handoffs.first)
      end

      rebind_reviewer_handoff(project, reviewer_handoffs.last, "2" * 64)
      run!("git", "add", "-A", chdir: project)
      two_handoffs = validate_staged(project)
      refute two_handoffs.success?
      refute_includes two_handoffs.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      restore_phase4_test_paths(project, reviewer_handoffs)

      rebind_reviewer_handoff(project, reviewer_handoffs.first, "1" * 64)
      write_file(File.join(project, "src", "business.rb"), "BUSINESS = true\n")
      run!("git", "add", "-A", chdir: project)
      unrelated = validate_staged(project)
      refute unrelated.success?
      refute_includes unrelated.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      run!("git", "restore", "--staged", "src/business.rb", chdir: project)
      File.unlink(File.join(project, "src", "business.rb"))
      run!("git", "add", "-A", chdir: project)

      restore_phase4_test_paths(project, [reviewer_handoffs.first])
      run!("git", "rm", reviewer_handoffs.first, chdir: project)
      assert_match(/^D\s/, staged_name_status(project, reviewer_handoffs.first))
      deleted = validate_staged(project)
      refute deleted.success?
      refute_includes deleted.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      restore_phase4_test_paths(project, [reviewer_handoffs.first])

      renamed_path = reviewer_handoffs.last.sub("FEATURE-20260101-002", "FEATURE-20260101-003--renamed-review")
      FileUtils.mkdir_p(File.dirname(renamed_path))
      run!("git", "mv", reviewer_handoffs.first, renamed_path, chdir: project)
      assert_match(/^R[0-9]+\s/, staged_name_status(project, reviewer_handoffs.first, renamed_path))
      renamed = validate_staged(project)
      refute renamed.success?
      refute_includes renamed.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      run!("git", "reset", "--quiet", "HEAD", "--", reviewer_handoffs.first, renamed_path, chdir: project)
      FileUtils.rm_rf(File.dirname(File.dirname(File.dirname(renamed_path))))
      run!("git", "restore", reviewer_handoffs.first, chdir: project)
      run!("git", "add", "-A", chdir: project)

      copied_path = reviewer_handoffs.last.sub("FEATURE-20260101-002", "FEATURE-20260101-004--copied-review")
      FileUtils.mkdir_p(File.dirname(copied_path))
      FileUtils.cp(reviewer_handoffs.first, copied_path)
      run!("git", "add", copied_path, chdir: project)
      assert_match(/^A\s/, staged_name_status(project, copied_path))
      copied = validate_staged(project)
      refute copied.success?
      refute_includes copied.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      run!("git", "reset", "--quiet", "HEAD", "--", copied_path, chdir: project)
      FileUtils.rm_rf(File.dirname(File.dirname(File.dirname(copied_path))))
      run!("git", "add", "-A", chdir: project)

      copied_path = reviewer_handoffs.last.sub("FEATURE-20260101-002", "FEATURE-20260101-005--copied-review")
      FileUtils.mkdir_p(File.dirname(copied_path))
      FileUtils.cp(reviewer_handoffs.first, copied_path)
      rebind_reviewer_handoff(project, reviewer_handoffs.first, "1" * 64)
      run!("git", "add", copied_path, chdir: project)
      assert_match(/^C[0-9]+\s/, staged_name_status(project, reviewer_handoffs.first, copied_path))
      copied = validate_staged(project)
      refute copied.success?
      refute_includes copied.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      run!("git", "reset", "--quiet", "HEAD", "--", reviewer_handoffs.first, copied_path, chdir: project)
      run!("git", "restore", reviewer_handoffs.first, chdir: project)
      FileUtils.rm_rf(File.dirname(File.dirname(File.dirname(copied_path))))
      run!("git", "add", "-A", chdir: project)

      write_file(existing_contract, File.binread(existing_contract) + "\nUnreviewed body rewrite.\n")
      run!("git", "add", ".ai/canonical/contracts/workflow.md", chdir: project)
      canonical_rewrite = validate_staged(project)
      refute canonical_rewrite.success?
      refute_includes canonical_rewrite.combined, "bounded Phase 4 registry bootstrap owns governance paths"
      run!("git", "restore", "--staged", ".ai/canonical/contracts/workflow.md", chdir: project)
      run!("git", "restore", ".ai/canonical/contracts/workflow.md", chdir: project)

      write_file(File.join(project, "src", "business.rb"), "BUSINESS = true\n")
      run!("git", "add", "src/business.rb", chdir: project)
      rejected = validate_staged(project)
      refute rejected.success?
      refute_includes rejected.combined, "bounded Phase 4 registry bootstrap owns governance paths"
    end
  end

  private

  def write_completed_reviewer_handoff(project, task_name)
    task_root = File.join(project, ".ai", "tasks", task_name)
    feature_id = task_name.split("--", 2).first
    write_yaml(File.join(task_root, "feature.yaml"), {
      "feature_id" => feature_id,
      "status" => "done",
      "workflow_tier" => "tier3",
    })
    reviewer_root = File.join(task_root, "streams", "reviewer")
    write_yaml(File.join(reviewer_root, "manifest.yaml"), {
      "feature_id" => feature_id,
      "stream_id" => "reviewer",
      "stream_type" => "review",
      "status" => "done",
      "agent_profile" => "reviewer",
      "review_required" => true,
      "handoff_required" => true,
    })
    handoff_path = File.join(reviewer_root, "handoff.md")
    write_file(handoff_path, <<~MARKDOWN)
      # Handoff

      ## Findings

      - 과거 검토가 완료되었습니다.

      ## Review Gate

      - Status: passed
      - Approved Manifest SHA256: #{"0" * 64}

      ## Doc Sync

      - Remaining drift: none
    MARKDOWN
    handoff_path
  end

  def rebind_reviewer_handoff(project, path, digest)
    content = File.binread(path)
    updated = content.sub(
      /^- Approved Manifest SHA256: [0-9a-f]{64}$/,
      "- Approved Manifest SHA256: #{digest}",
    )
    refute_equal content, updated
    write_file(path, updated)
    run!("git", "add", path, chdir: project)
  end

  def write_ambiguous_reviewer_handoff(path, variant)
    content = File.binread(path)
    gate = <<~MARKDOWN.chomp
      ## Review Gate

      - Status: passed
      - Approved Manifest SHA256: #{"0" * 64}
    MARKDOWN
    replacement = case variant
                  when :fenced
                    "```text\n#{gate}\n```"
                  when :commented
                    "<!--\n#{gate}\n-->"
                  when :nested
                    "### Hidden subsection\n\n#{gate}"
                  when :setext
                    "Hidden section\n==============\n\n#{gate}"
                  else
                    raise "unknown ambiguous handoff variant: #{variant}"
                  end
    updated = content.sub(gate, replacement)
    refute_equal content, updated
    write_file(path, updated)
  end

  def restore_phase4_test_paths(project, paths)
    paths.each do |path|
      run!("git", "restore", "--staged", path, chdir: project)
      run!("git", "restore", path, chdir: project)
    end
  end

  def staged_name_status(project, *paths)
    run!(
      "git", "diff", "--cached", "--name-status", "--find-renames", "--find-copies", "--", *paths,
      chdir: project,
    ).stdout
  end

  def assert_phase4_handoff_rebind_rejected(project, handoff_path)
    yield
    run!("git", "add", "-A", chdir: project)
    result = validate_staged(project)
    refute result.success?
    refute_includes result.combined, "bounded Phase 4 registry bootstrap owns governance paths"
  ensure
    restore_phase4_test_paths(project, [handoff_path]) if File.exist?(File.join(project, ".git"))
    feature_path = File.join(File.dirname(File.dirname(File.dirname(handoff_path))), "feature.yaml")
    manifest_path = File.join(File.dirname(handoff_path), "manifest.yaml")
    [feature_path, manifest_path].each do |path|
      run!("git", "restore", "--staged", path, chdir: project)
      run!("git", "restore", path, chdir: project)
    end
    rebind_reviewer_handoff(project, handoff_path, "1" * 64)
  end

  def with_reviewed_merge_adoption
    with_project do |project|
      bootstrap!(project)
      commit_all!(project, "managed baseline")

      agents_path = File.join(project, "AGENTS.md")
      write_file(agents_path, File.binread(agents_path) + "\nProject customization.\n")
      commit_all!(project, "customize merge-owned adapter")
      current_digest = Digest::SHA256.file(agents_path).hexdigest
      Dir.mktmpdir("workflow-kit-reviewed-merge", WorkflowKitTestHelpers::FIXTURES_ROOT) do |directory|
        merged_path = File.join(directory, "AGENTS.md")
        write_file(merged_path, File.binread(agents_path) + "\nReviewed shared merge.\n")
        plan_digest = apply_with_reviewed_plan(
          project,
          "--approve-path", "AGENTS.md=#{current_digest}",
          "--merge-path", "AGENTS.md=#{merged_path}",
        )
        yield project, plan_digest
      end
    end
  end

  def stage_manifest_and_receipt(project, manifest, plan_digest)
    write_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"), manifest)
    run!("git", "add", "-A", chdir: project)
    generate_receipt(project, plan_digest)
    run!("git", "add", RECEIPT_PATH, chdir: project)
  end

  def apply_with_reviewed_plan(project, *options)
    plan = bootstrap_plan(project, *options)
    assert plan.success?, plan.combined
    digest = JSON.parse(plan.stdout).fetch("plan_digest")
    result = run_command(
      RbConfig.ruby,
      WorkflowKitTestHelpers::BOOTSTRAP,
      *reviewed_release_options,
      *options,
      "--plan-digest",
      digest,
      project,
    )
    assert result.success?, result.combined
    digest
  end

  def generate_receipt(project, plan_digest)
    result = run_command(
      RbConfig.ruby,
      script(project, "adoption_receipt.rb"),
      "generate",
      "--plan-digest",
      plan_digest,
      chdir: project,
    )
    assert result.success?, result.combined
    JSON.parse(result.stdout)
  end

  def validate_staged(project)
    run_command(
      RbConfig.ruby,
      script(project, "validate_change_set.rb"),
      "--mode",
      "staged",
      chdir: project,
    )
  end
end
