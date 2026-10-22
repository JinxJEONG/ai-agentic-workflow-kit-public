# frozen_string_literal: true

require "digest"
require "json"
require_relative "test_helper"
require_relative "../engine/validators/validate_spec_freshness"

class SpecFreshnessTest < Minitest::Test
  def registry
    {
      "schema_version" => 1,
      "project_id" => "fixture",
      "rules" => [{
        "id" => "authentication-contract",
        "source_globs" => ["src/auth/**"],
        "canonical_specs" => [".ai/canonical/auth.md"],
        "generated_facts" => [".ai/generated/env-names.json"],
        "checks" => ["environment-names"],
        "impact_policy" => "spec_update_or_approved_no_impact",
        "codeowners" => ["@fixture-owner"],
      }],
    }
  end

  def setup_project(project)
    write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), registry)
    write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['LOGIN_TOKEN']\n")
    write_file(File.join(project, ".ai", "canonical", "auth.md"), "---\nverified_against: {}\n---\n# Auth\n")
    commit_all!(project, "initial")
    run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
  end

  def update_evidence(project)
    write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['LOGIN_TOKEN']\nMODE = ENV['LOGIN_MODE']\n")
    commit_all!(project, "change auth")
    source_digest = WorkflowKit::SourceTree.digest(
      WorkflowKit::SourceTree.entries(project, ["src/auth/**"], ref: "HEAD"),
    )
    spec = <<~MARKDOWN
      ---
      verified_against:
        rule_id: authentication-contract
        source_digest_algo: 1
        source_tree_digest: '#{source_digest}'
      ---
      # Authentication contract
    MARKDOWN
    write_file(File.join(project, ".ai", "canonical", "auth.md"), spec)

    result = run_command(
      RbConfig.ruby, File.join(KIT_ROOT, "adapters", "common", "generate_env_names.rb"),
      "--root", project, "--ref", "HEAD", "--rule", "authentication-contract",
      "--clear-default-globs", "--source-glob", "src/auth/**",
      chdir: KIT_ROOT,
    )
    assert result.success?, result.combined
    write_file(File.join(project, ".ai", "generated", "env-names.json"), result.stdout)
    commit_all!(project, "update auth evidence")
  end

  def add_typescript_evidence_rule(project)
    value = load_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"))
    value["rules"] << {
      "id" => "typescript-contract",
      "source_globs" => ["src/contracts/**"],
      "canonical_specs" => [".ai/canonical/typescript.md"],
      "generated_facts" => [".ai/generated/typescript-exports.json"],
      "checks" => ["typescript-exports"],
      "impact_policy" => "spec_update_required",
      "codeowners" => ["@fixture-owner"],
    }
    write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), value)
    write_file(
      File.join(project, "src", "contracts", "public.ts"),
      "export interface PublicContract { id: string }\n",
    )
    commit_all!(project, "add TypeScript contract source")

    source_digest = WorkflowKit::SourceTree.digest(
      WorkflowKit::SourceTree.entries(project, ["src/contracts/**"], ref: "HEAD"),
    )
    write_file(File.join(project, ".ai", "canonical", "typescript.md"), <<~MARKDOWN)
      ---
      verified_against:
        rule_id: typescript-contract
        source_digest_algo: 1
        source_tree_digest: '#{source_digest}'
      ---
      # TypeScript contract
    MARKDOWN
    document = WorkflowKit::GeneratedDocument.build(
      root: project,
      ref: "HEAD",
      rule_id: "typescript-contract",
      fact_type: "typescript-exports",
      source_globs: ["src/contracts/**"],
      facts: { "parser" => "typescript-fixture", "exports" => [] },
    )
    write_file(
      File.join(project, ".ai", "generated", "typescript-exports.json"),
      JSON.pretty_generate(document) + "\n",
    )
    commit_all!(project, "add TypeScript contract evidence")
  end

  def test_current_spec_and_generated_facts_pass
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert result["valid"], result["errors"].join("\n")
      assert_equal ["authentication-contract"], result["touched_rules"]
    end
  end

  def test_hosted_no_project_code_profile_accepts_audited_blob_only_adapters
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)

      result = WorkflowKit::SpecFreshness.validate(
        root: project,
        base: base,
        head: "HEAD",
        registry_path: ".ai/SPEC_REGISTRY.yaml",
        execution_profile: "hosted-no-project-code",
      )

      assert result["valid"], result["errors"].join("\n")
      assert_equal ["authentication-contract"], result["touched_rules"]
    end
  end

  def test_hosted_no_project_code_profile_rejects_project_dependency_adapter_without_running_it
    with_project do |project|
      base = setup_project(project)
      add_typescript_evidence_rule(project)
      Dir.mktmpdir("forbidden-typescript-adapter-") do |temporary|
        marker = File.join(temporary, "executed")
        executable = File.join(temporary, "node")
        write_file(executable, "#!/bin/sh\ntouch \"$FORBIDDEN_ADAPTER_MARKER\"\nexit 99\n")
        FileUtils.chmod(0o755, executable)
        previous_node = ENV["NODE"]
        previous_marker = ENV["FORBIDDEN_ADAPTER_MARKER"]
        ENV["NODE"] = executable
        ENV["FORBIDDEN_ADAPTER_MARKER"] = marker
        begin
          result = WorkflowKit::SpecFreshness.validate(
            root: project,
            base: base,
            head: "HEAD",
            registry_path: ".ai/SPEC_REGISTRY.yaml",
            execution_profile: "hosted-no-project-code",
          )
        ensure
          ENV["NODE"] = previous_node
          ENV["FORBIDDEN_ADAPTER_MARKER"] = previous_marker
        end

        refute result["valid"]
        assert_includes result["errors"],
          "hosted_unsafe_adapter: rule=typescript-contract path=.ai/generated/typescript-exports.json fact_type=typescript-exports"
        refute File.exist?(marker), "hosted profile executed the target project's TypeScript dependency path"
      end
    end
  end

  def test_hosted_profile_rejects_unsafe_adapter_from_a_non_touched_registry_rule
    with_project do |project|
      setup_project(project)
      update_evidence(project)
      add_typescript_evidence_rule(project)
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      write_file(File.join(project, "README.md"), "unrelated documentation change\n")
      commit_all!(project, "change unrelated documentation")

      result = WorkflowKit::SpecFreshness.validate(
        root: project,
        base: base,
        head: "HEAD",
        registry_path: ".ai/SPEC_REGISTRY.yaml",
        execution_profile: "hosted-no-project-code",
      )

      refute result["valid"]
      assert_includes result["errors"],
        "hosted_unsafe_adapter: rule=typescript-contract path=.ai/generated/typescript-exports.json fact_type=typescript-exports"
    end
  end

  def test_unknown_execution_profile_is_rejected
    with_project do |project|
      base = setup_project(project)
      result = WorkflowKit::SpecFreshness.validate(
        root: project,
        base: base,
        head: "HEAD",
        registry_path: ".ai/SPEC_REGISTRY.yaml",
        execution_profile: "hosted-trust-me",
      )

      refute result["valid"]
      assert_equal ["unknown_execution_profile: hosted-trust-me"], result["errors"]
    end
  end

  def test_stale_spec_and_generated_facts_fail
    with_project do |project|
      base = setup_project(project)
      write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['CHANGED_TOKEN']\n")
      commit_all!(project, "change without evidence")
      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      refute result["valid"]
      assert result["errors"].any? { |error| error.include?("spec_update_required") }
      assert result["errors"].any? { |error| error.include?("generated_facts_missing") }
    end
  end

  def test_unmapped_default_high_risk_path_fails
    with_project do |project|
      base = setup_project(project)
      write_file(File.join(project, "db", "orphan.sql"), "create table orphan(id int);\n")
      commit_all!(project, "unmapped database change")
      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert_includes result["errors"], "unmapped_high_risk_path: db/orphan.sql"
    end
  end

  def test_deeply_nested_high_risk_path_is_not_skipped
    with_project do |project|
      base = setup_project(project)
      write_file(
        File.join(project, "deploy", "macos", "bin", "release.sh"),
        "#!/bin/sh\nexit 0\n",
      )
      commit_all!(project, "add nested deployment path")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )

      assert_includes result["errors"], "unmapped_high_risk_path: deploy/macos/bin/release.sh"
    end
  end

  def test_registry_rejects_self_reference
    value = registry
    value["rules"].first["source_globs"] << ".ai/canonical/**"
    errors = WorkflowKit::SpecRegistry.validate(value)
    assert errors.any? { |error| error.include?("self_referencing_rule") }
  end

  def test_generated_fact_from_another_rule_is_rejected
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      path = File.join(project, ".ai", "generated", "env-names.json")
      fact = JSON.parse(File.read(path))
      fact["rule_id"] = "copied-from-another-rule"
      write_file(path, JSON.pretty_generate(fact))
      commit_all!(project, "copy wrong rule evidence")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert_includes result["errors"], "generated_facts_rule_mismatch: .ai/generated/env-names.json"
    end
  end

  def test_generated_fact_schema_is_enforced_before_it_can_satisfy_a_check
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      path = File.join(project, ".ai", "generated", "env-names.json")
      fact = JSON.parse(File.read(path))
      fact.delete("generated_at")
      write_file(path, JSON.pretty_generate(fact))
      commit_all!(project, "remove required generated metadata")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert result["errors"].any? { |error| error.include?("generated_facts_schema_invalid") && error.include?("generated_at") }
      assert_includes result["errors"], "check_evidence_missing: rule=authentication-contract check=environment-names fact_type=environment-variables"
    end
  end

  def test_check_cannot_be_satisfied_by_a_different_valid_fact_type
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      value = registry
      value["rules"].first["checks"] = ["migration-checksum"]
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), value)
      commit_all!(project, "require migration evidence")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert_includes result["errors"], "check_evidence_missing: rule=authentication-contract check=migration-checksum fact_type=migration-checksums"
    end
  end

  def test_every_generated_evidence_check_has_an_explicit_fact_binding
    expected = WorkflowKit::SpecFreshness::KNOWN_CHECKS - ["release-wrapper-required"]
    assert_equal expected.sort, WorkflowKit::SpecFreshness::CHECK_EVIDENCE_TYPES.keys.sort
  end

  def test_hosted_adapter_allowlist_is_an_exact_audited_blob_only_set
    expected = {
      "fastapi-routes" => "adapters/fastapi-alembic/generate_routes.rb",
      "nextjs-routes" => "adapters/nextjs-typescript/generate_routes.rb",
      "python-symbols" => "adapters/fastapi-alembic/generate_symbols.rb",
      "environment-variables" => "adapters/common/generate_env_names.rb",
      "deployment-inputs" => "adapters/common/generate_deploy_inputs.rb",
      "migration-checksums" => "adapters/common/generate_migration_checksums.rb",
    }

    assert_equal expected, WorkflowKit::SpecFreshness::HOSTED_NO_PROJECT_CODE_GENERATORS
    refute_includes WorkflowKit::SpecFreshness::HOSTED_NO_PROJECT_CODE_GENERATORS,
      "typescript-exports"
    refute_includes WorkflowKit::SpecFreshness::HOSTED_NO_PROJECT_CODE_GENERATORS,
      "postgresql-schema"
  end

  def test_migration_checksum_generator_satisfies_its_bound_check
    with_project do |project|
      migration_registry = {
        "schema_version" => 1,
        "project_id" => "migration-fixture",
        "rules" => [{
          "id" => "database-schema",
          "source_globs" => ["db/migrate/**"],
          "canonical_specs" => [".ai/canonical/database.md"],
          "generated_facts" => [".ai/generated/migration-checksums.json"],
          "checks" => ["migration-checksum"],
          "impact_policy" => "spec_update_required",
          "codeowners" => ["@database-owner"],
        }],
      }
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), migration_registry)
      write_file(File.join(project, "db", "migrate", "001_create_items.sql"), "create table items(id bigint primary key);\n")
      write_file(File.join(project, ".ai", "canonical", "database.md"), "# Database\n")
      commit_all!(project, "initial database")
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      write_file(File.join(project, "db", "migrate", "002_add_name.sql"), "alter table items add column name text;\n")
      commit_all!(project, "change database")
      source_digest = WorkflowKit::SourceTree.digest(
        WorkflowKit::SourceTree.entries(project, ["db/migrate/**"], ref: "HEAD"),
      )
      write_file(File.join(project, ".ai", "canonical", "database.md"), <<~MARKDOWN)
        ---
        verified_against:
          rule_id: database-schema
          source_digest_algo: 1
          source_tree_digest: '#{source_digest}'
        ---
        # Database
      MARKDOWN
      generated = run_command(
        RbConfig.ruby, File.join(KIT_ROOT, "adapters", "common", "generate_migration_checksums.rb"),
        "--root", project, "--ref", "HEAD", "--rule", "database-schema",
        "--clear-default-globs", "--source-glob", "db/migrate/**",
        chdir: KIT_ROOT,
      )
      assert generated.success?, generated.combined
      write_file(File.join(project, ".ai", "generated", "migration-checksums.json"), generated.stdout)
      commit_all!(project, "update database evidence")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert result["valid"], result["errors"].join("\n")
    end
  end

  def test_generated_fact_tamper_is_checked_even_without_a_source_change
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      path = File.join(project, ".ai", "generated", "env-names.json")
      fact = JSON.parse(File.read(path))
      fact["facts"] = { "names" => ["FORGED"] }
      write_file(path, JSON.pretty_generate(fact))
      commit_all!(project, "forge generated fact only")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      refute result["valid"]
      assert_includes result["touched_rules"], "authentication-contract"
      assert result["errors"].any? { |error| error.include?("generated_facts_content_invalid") }
    end
  end

  def test_registry_only_change_cannot_remove_an_existing_rule
    with_project do |project|
      setup_project(project)
      update_evidence(project)
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      weakened = registry
      weakened["rules"] = [{
        "id" => "unrelated",
        "source_globs" => ["lib/**"],
        "canonical_specs" => [".ai/canonical/unrelated.md"],
        "generated_facts" => [],
        "checks" => ["release-wrapper-required"],
        "impact_policy" => "spec_update_required",
        "codeowners" => ["@fixture-owner"],
      }]
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), weakened)
      write_file(File.join(project, ".ai", "canonical", "unrelated.md"), "# unrelated\n")
      commit_all!(project, "weaken registry only")

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert_includes result["errors"], "registry_rule_removed: authentication-contract"
      assert_includes result["errors"], "unmapped_high_risk_path: src/auth/login.rb"
    end
  end

  def test_spec_update_required_policy_never_accepts_an_exemption
    with_project do |project|
      value = registry
      value["rules"].first["impact_policy"] = "spec_update_required"
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), value)
      write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['LOGIN_TOKEN']\n")
      write_file(File.join(project, ".ai", "canonical", "auth.md"), "# stale\n")
      commit_all!(project, "initial")
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['CHANGED_TOKEN']\n")
      commit_all!(project, "change")
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, "HEAD")
      exemptions = [{
        "rule_id" => "authentication-contract",
        "reason" => "Reviewed by two maintainers and proven not to affect the public contract.",
        "change_set_digest" => digest,
      }]

      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
        exemptions: exemptions, approved_rules: ["authentication-contract"],
      )
      assert_includes result["errors"], "spec_update_required: rule=authentication-contract"
    end
  end

  def test_change_set_digest_matches_the_documented_shell_framing
    with_project do |project|
      write_file(File.join(project, "zeta.txt"), "before\n")
      write_file(File.join(project, "alpha.txt"), "before\n")
      commit_all!(project, "initial")
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      write_file(File.join(project, "zeta.txt"), "after\n")
      write_file(File.join(project, "alpha.txt"), "after\n")
      commit_all!(project, "change files")

      names = run!("git", "diff", "--name-status", "#{base}..HEAD", chdir: project).stdout.lines.sort.join
      patch = run!("git", "diff", "#{base}..HEAD", chdir: project).stdout
      documented_stream = names + "#{Digest::SHA256.hexdigest(patch)}\n"
      expected = "sha256:#{Digest::SHA256.hexdigest(documented_stream)}"

      assert_equal expected, WorkflowKit::SpecFreshness.change_set_digest(project, base, "HEAD")
    end
  end

  def test_pr_docs_impact_exemption_requires_latest_codeowner_approval_for_head
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      write_file(File.join(project, ".ai", "canonical", "auth.md"), "# intentionally unchanged contract\n")
      commit_all!(project, "leave canonical contract unchanged")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, head)
      body = <<~MARKDOWN
        ```yaml
        docs-impact:
          - rule_id: authentication-contract
            decision: none
            reason: A maintainer verified this refactor changes internal logging only and preserves the documented contract.
            change_set_digest: #{digest}
        ```
      MARKDOWN
      event = {
        "repository" => { "full_name" => "fixture/project" },
        "pull_request" => {
          "body" => body,
          "base" => { "sha" => base },
          "head" => { "sha" => head },
        },
      }
      reviews = [{
        "id" => 10,
        "state" => "APPROVED",
        "submitted_at" => "2026-08-14T00:00:00Z",
        "commit_id" => head,
        "user" => { "login" => "fixture-owner" },
      }]

      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        event: event, reviews: reviews, repository: "fixture/project",
      )
      assert_empty evidence[:errors]
      assert_equal ["authentication-contract"], evidence[:approved_rules]
      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        exemptions: evidence[:exemptions], approved_rules: evidence[:approved_rules],
        evidence_errors: evidence[:errors],
      )
      assert result["valid"], result["errors"].join("\n")
    end
  end

  def test_latest_non_approval_and_old_head_approval_fail_closed
    with_project do |project|
      base = setup_project(project)
      update_evidence(project)
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, head)
      event = {
        "repository" => { "full_name" => "fixture/project" },
        "pull_request" => {
          "body" => <<~MARKDOWN,
            ```yaml
            docs-impact:
              - rule_id: authentication-contract
                decision: none
                reason: A maintainer verified the implementation is internal and the documented public contract remains accurate.
                change_set_digest: #{digest}
            ```
          MARKDOWN
          "base" => { "sha" => base },
          "head" => { "sha" => head },
        },
      }
      reviews = [
        {
          "id" => 10, "state" => "APPROVED", "submitted_at" => "2026-08-14T00:00:00Z",
          "commit_id" => "f" * 40, "user" => { "login" => "fixture-owner" },
        },
        {
          "id" => 11, "state" => "CHANGES_REQUESTED", "submitted_at" => "2026-08-14T00:01:00Z",
          "commit_id" => head, "user" => { "login" => "fixture-owner" },
        },
      ]

      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        event: event, reviews: reviews, repository: "fixture/project",
      )
      assert_includes evidence[:errors], "docs_impact_codeowner_approval_missing: authentication-contract"
      assert_empty evidence[:approved_rules]
    end
  end

  def test_push_event_never_creates_exemption_evidence
    evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
      root: ".", base: "HEAD", head: "HEAD", registry_path: ".ai/SPEC_REGISTRY.yaml",
      event: { "repository" => { "full_name" => "fixture/project" }, "after" => "f" * 40 },
      reviews: [{ "state" => "APPROVED" }], repository: "fixture/project",
    )
    assert_equal({ exemptions: [], approved_rules: [], errors: [] }, evidence)
  end

  def test_pr_cannot_rebind_codeowner_and_use_the_new_owner_for_an_exemption
    with_project do |project|
      base = setup_project(project)
      changed = registry
      changed["rules"].first["codeowners"] = ["@attacker"]
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), changed)
      commit_all!(project, "rebind owner")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, head)
      event = {
        "repository" => { "full_name" => "fixture/project" },
        "pull_request" => {
          "body" => <<~MARKDOWN,
            ```yaml
            docs-impact:
              - rule_id: authentication-contract
                decision: none
                reason: This text is deliberately long enough, but a pull request cannot appoint its own approving owner.
                change_set_digest: #{digest}
            ```
          MARKDOWN
          "base" => { "sha" => base }, "head" => { "sha" => head },
        },
      }
      reviews = [{
        "id" => 12, "state" => "APPROVED", "submitted_at" => "2026-08-14T00:02:00Z",
        "commit_id" => head, "user" => { "login" => "attacker" },
      }]

      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        event: event, reviews: reviews, repository: "fixture/project",
      )
      assert_includes evidence[:errors], "docs_impact_codeowners_changed: authentication-contract"
      assert_empty evidence[:approved_rules]
      result = WorkflowKit::SpecFreshness.validate(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
      )
      assert_includes result["errors"], "registry_rule_codeowners_changed: rule=authentication-contract"
    end
  end

  def test_new_rule_cannot_claim_an_exemption_in_the_same_pull_request
    with_project do |project|
      base = setup_project(project)
      changed = registry
      changed["rules"] << {
        "id" => "new-contract", "codeowners" => ["@fixture-owner"], "source_globs" => ["lib/**"],
        "canonical_specs" => [".ai/canonical/new.md"], "generated_facts" => [],
        "checks" => ["release-wrapper-required"], "impact_policy" => "spec_update_or_approved_no_impact",
      }
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), changed)
      write_file(File.join(project, ".ai", "canonical", "new.md"), "# new\n")
      commit_all!(project, "add new rule")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, head)
      event = {
        "repository" => { "full_name" => "fixture/project" },
        "pull_request" => {
          "body" => <<~MARKDOWN,
            ```yaml
            docs-impact:
              - rule_id: new-contract
                decision: none
                reason: A newly introduced rule must establish its contract before any exemption can be considered by reviewers.
                change_set_digest: #{digest}
            ```
          MARKDOWN
          "base" => { "sha" => base }, "head" => { "sha" => head },
        },
      }
      reviews = [{
        "id" => 13, "state" => "APPROVED", "submitted_at" => "2026-08-14T00:03:00Z",
        "commit_id" => head, "user" => { "login" => "fixture-owner" },
      }]

      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        event: event, reviews: reviews, repository: "fixture/project",
      )
      assert_includes evidence[:errors], "docs_impact_new_rule_exemption_forbidden: new-contract"
      assert_empty evidence[:approved_rules]
    end
  end

  def test_team_only_codeowner_fails_without_membership_api_evidence
    with_project do |project|
      value = registry
      value["rules"].first["codeowners"] = ["@fixture/security"]
      write_yaml(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), value)
      write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['LOGIN_TOKEN']\n")
      write_file(File.join(project, ".ai", "canonical", "auth.md"), "# Auth\n")
      commit_all!(project, "initial team ownership")
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      write_file(File.join(project, "src", "auth", "login.rb"), "TOKEN = ENV['CHANGED_TOKEN']\n")
      commit_all!(project, "change auth")
      head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      digest = WorkflowKit::SpecFreshness.change_set_digest(project, base, head)
      event = {
        "repository" => { "full_name" => "fixture/project" },
        "pull_request" => {
          "body" => <<~MARKDOWN,
            ```yaml
            docs-impact:
              - rule_id: authentication-contract
                decision: none
                reason: A team member review alone cannot prove current team membership to this deterministic offline validator.
                change_set_digest: #{digest}
            ```
          MARKDOWN
          "base" => { "sha" => base }, "head" => { "sha" => head },
        },
      }
      reviews = [{
        "id" => 14, "state" => "APPROVED", "submitted_at" => "2026-08-14T00:04:00Z",
        "commit_id" => head, "user" => { "login" => "team-member" },
      }]

      evidence = WorkflowKit::SpecFreshness.github_approval_evidence(
        root: project, base: base, head: head, registry_path: ".ai/SPEC_REGISTRY.yaml",
        event: event, reviews: reviews, repository: "fixture/project",
      )
      assert_includes evidence[:errors], "docs_impact_team_membership_evidence_missing: authentication-contract"
      assert_empty evidence[:approved_rules]
    end
  end
end
