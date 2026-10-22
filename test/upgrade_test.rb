# frozen_string_literal: true

require "json"
require "digest"
require_relative "test_helper"

class UpgradeTest < Minitest::Test
  STATUS = File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "install", "status.rb")
  INVENTORY = File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "inventory", "inventory.rb")
  UPGRADE = File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "install", "upgrade.rb")
  ADOPT = File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "install", "adopt.rb")

  def test_status_reports_not_installed_and_current_states
    with_project do |project|
      not_installed = run_command(RbConfig.ruby, STATUS, "--json", project)
      refute not_installed.success?
      record = JSON.parse(not_installed.stdout)
      assert_equal "not_installed", record.fetch("state")
      assert_equal 10, record.fetch("exit_code")

      bootstrap!(project)
      current = run!(RbConfig.ruby, STATUS, "--json", project)
      record = JSON.parse(current.stdout)
      assert_equal "current", record.fetch("state")
      assert_equal 0, record.fetch("exit_code")
      assert_equal 2, record.dig("manifest", "schema_version")
      assert_equal File.read(File.join(WorkflowKitTestHelpers::KIT_ROOT, "VERSION")).strip, record.dig("source", "kit_version")
    end
  end

  def test_status_reports_legacy_unknown_without_a_manifest
    with_project do |project|
      bootstrap!(project)
      FileUtils.rm(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))

      result = run_command(RbConfig.ruby, STATUS, "--json", project)
      refute result.success?
      record = JSON.parse(result.stdout)
      assert_equal "legacy_unknown", record.fetch("state")
      assert_equal 20, record.fetch("exit_code")
      assert_equal false, record.dig("manifest", "present")
    end
  end

  def test_status_reports_an_available_upgrade_when_manifest_version_is_old
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest["kit_version"] = "0.2.0"
      write_yaml(manifest_path, manifest)

      result = run_command(RbConfig.ruby, STATUS, "--json", project)
      refute result.success?
      record = JSON.parse(result.stdout)
      assert_equal "upgrade_available", record.fetch("state")
      assert_equal 10, record.fetch("exit_code")
    end
  end

  def test_status_blocks_a_release_manifest_identity_change
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest["release_manifest_digest"] = "sha256:#{'a' * 64}"
      write_yaml(manifest_path, manifest)

      result = run_command(RbConfig.ruby, STATUS, "--json", project)
      refute result.success?
      record = JSON.parse(result.stdout)
      assert_equal "blocked", record.fetch("state")
      assert_equal 30, record.fetch("exit_code")
    end
  end

  def test_schema_one_manifest_is_migrated_without_replacing_unchanged_files
    with_project do |project|
      bootstrap!(project)
      kit_path = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      kit_before = File.binread(kit_path)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest["schema_version"] = 1
      manifest["kit_version"] = "0.2.0"
      manifest.delete("source_commit")
      manifest.delete("template_digest")
      manifest.delete("installation_state")
      manifest.fetch("installed_files").each do |entry|
        entry.delete("baseline_sha256")
        entry.delete("template_sha256")
        entry.delete("state")
      end
      write_yaml(manifest_path, manifest)

      bootstrap!(project)
      migrated = load_yaml(manifest_path)
      assert_equal 2, migrated.fetch("schema_version")
      assert_equal File.read(File.join(WorkflowKitTestHelpers::KIT_ROOT, "VERSION")).strip, migrated.fetch("kit_version")
      assert_equal kit_before, File.binread(kit_path)
      run!(RbConfig.ruby, File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "validators", "validate_install.rb"), project)
    end
  end

  def test_upgrade_preserves_legacy_relocated_paths_and_installs_runtime_replacements
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      relocations = {
        ".ai/runtime/scripts/collect_context.rb" => ".ai/scripts/collect_context.rb",
        ".ai/runtime/templates/README.md" => ".ai/templates/README.md",
        ".ai/runtime/githooks/pre-commit" => ".githooks/pre-commit",
        ".ai/runtime/agents/base/backend.md" => ".ai/canonical/agents/backend.md",
      }
      legacy_bytes = {}

      relocations.each do |runtime_path, legacy_path|
        runtime = File.join(project, runtime_path)
        legacy = File.join(project, legacy_path)
        FileUtils.mkdir_p(File.dirname(legacy))
        FileUtils.mv(runtime, legacy)
        legacy_bytes[legacy_path] = File.binread(legacy)
        entry = manifest.fetch("installed_files").find { |value| value.fetch("path") == runtime_path }
        refute_nil entry
        entry["path"] = legacy_path
      end
      write_yaml(manifest_path, manifest)

      reviewed = bootstrap_plan(project)
      assert reviewed.success?, reviewed.combined
      plan = JSON.parse(reviewed.stdout)
      entries = plan.fetch("files").to_h { |entry| [entry.fetch("path"), entry] }
      relocations.each do |runtime_path, legacy_path|
        assert_equal "skip", entries.fetch(legacy_path).fetch("action")
        assert_equal "legacy_relocated_path_preserved", entries.fetch(legacy_path).fetch("reason")
        assert_equal "create", entries.fetch(runtime_path).fetch("action")
      end

      applied = apply_reviewed(project)
      assert applied.success?, applied.combined
      relocations.each do |runtime_path, legacy_path|
        assert_equal legacy_bytes.fetch(legacy_path), File.binread(File.join(project, legacy_path))
        assert File.file?(File.join(project, runtime_path))
      end

      migrated = load_yaml(manifest_path).fetch("installed_files").to_h { |entry| [entry.fetch("path"), entry] }
      relocations.each do |runtime_path, legacy_path|
        assert_equal "legacy", migrated.fetch(legacy_path).fetch("state")
        assert_equal runtime_path, migrated.fetch(legacy_path).fetch("relocated_to")
        assert_equal "managed", migrated.fetch(runtime_path).fetch("state")
      end
      run!(RbConfig.ruby, File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "validators", "validate_install.rb"), project)
    end
  end

  def test_status_blocks_migration_while_a_stream_is_active
    with_project do |project|
      bootstrap!(project)
      write_yaml(
        File.join(project, ".ai", "local", "ACTIVE_CONTEXT.yaml"),
        "active_streams" => [{ "feature_id" => "FEATURE-TEST-001", "stream_id" => "backend-dev" }],
      )

      result = run_command(RbConfig.ruby, STATUS, "--json", project)
      refute result.success?
      record = JSON.parse(result.stdout)
      assert_equal "blocked", record.fetch("state")
      assert_equal 30, record.fetch("exit_code")
      assert_equal ["FEATURE-TEST-001/backend-dev"], record.dig("plan", "activity", "active_streams")
    end
  end

  def test_upgrade_preflight_blocks_all_targets_when_activity_is_present
    with_project do |project|
      bootstrap!(project)
      write_yaml(
        File.join(project, ".ai", "local", "locks", "migration.lock"),
        "owner" => "test",
      )

      plan = run_command(RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--replace-kit-owned", project)
      digest = JSON.parse(plan.stdout).fetch("projects").first.fetch("plan_digest")
      result = run_command(
        RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--apply",
        "--replace-kit-owned", "--plan-digest", digest, project,
      )
      refute result.success?
      assert_equal 30, result.status.exitstatus
      record = JSON.parse(result.stdout)
      assert_equal "blocked", record.fetch("mode")
      assert_includes record.fetch("error"), "active workflow"
    end
  end

  def test_upgrade_is_read_only_until_apply_and_preserves_project_owned_files
    with_project do |project|
      bootstrap!(project)
      project_rules_path = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      File.open(project_rules_path, "ab") { |file| file.write("\nProject-owned rule.\n") }
      project_rules_content = File.binread(project_rules_path)
      kit_path = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      File.open(kit_path, "ab") { |file| file.write("\n# drift\n") }
      kit_content = File.binread(kit_path)

      plan = run_command(RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, project)
      refute plan.success?
      plan_json = JSON.parse(plan.stdout)
      assert_equal "plan", plan_json.fetch("mode")
      assert_operator plan_json.fetch("projects").first.fetch("counts").fetch("conflict"), :>, 0
      assert_equal project_rules_content, File.binread(project_rules_path)
      assert_equal kit_content, File.binread(kit_path)

      reviewed = run!(
        RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--replace-kit-owned", project,
      )
      reviewed_json = JSON.parse(reviewed.stdout)
      assert_equal project_rules_content, File.binread(project_rules_path)
      assert_equal kit_content, File.binread(kit_path)
      digest = reviewed_json.fetch("projects").first.fetch("plan_digest")
      applied = run!(
        RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--apply",
        "--replace-kit-owned", "--plan-digest", digest, project,
      )
      applied_json = JSON.parse(applied.stdout)
      assert_equal "applied", applied_json.fetch("mode")
      assert_equal project_rules_content, File.binread(project_rules_path)
      refute_equal kit_content, File.binread(kit_path)

      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      rules_entry = manifest.fetch("installed_files").find { |entry| entry.fetch("path") == ".ai/canonical/PROJECT_RULES.md" }
      assert_equal Digest::SHA256.hexdigest(project_rules_content), rules_entry.fetch("sha256")
      refute_empty rules_entry.fetch("baseline_sha256")

      status = run!(RbConfig.ruby, STATUS, "--json", project)
      assert_equal "current", JSON.parse(status.stdout).fetch("state")
    end
  end

  def test_upgrade_apply_requires_a_separately_reviewed_plan_digest
    with_project do |project|
      bootstrap!(project)
      result = run_command(
        RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--apply", project,
      )
      refute result.success?
      assert_equal 40, result.status.exitstatus
      assert_includes result.stderr, "requires --plan-digest"
    end
  end

  def test_adopt_defaults_to_a_read_only_kit_owned_replacement_plan
    with_project do |project|
      bootstrap!(project)
      FileUtils.rm(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      kit_path = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      File.open(kit_path, "ab") { |file| file.write("\n# legacy drift\n") }
      before = File.binread(kit_path)

      result = run!(RbConfig.ruby, ADOPT, "--json", *reviewed_release_options, project)
      plan = JSON.parse(result.stdout)
      assert_equal "plan", plan.fetch("mode")
      assert_equal before, File.binread(kit_path)
    end
  end

  def test_inventory_discovers_manifest_projects
    FileUtils.mkdir_p(WorkflowKitTestHelpers::FIXTURES_ROOT)
    Dir.mktmpdir("workflow-kit-inventory", WorkflowKitTestHelpers::FIXTURES_ROOT) do |container|
      project = File.join(container, "project")
      run!("git", "init", "-b", "main", project)
      run!("git", "config", "user.name", "Workflow Kit Test", chdir: project)
      run!("git", "config", "user.email", "workflow-kit@example.invalid", chdir: project)
      run!("git", "commit", "--allow-empty", "-m", "baseline", chdir: project)
      bootstrap!(project)

      result = run!(RbConfig.ruby, INVENTORY, "--json", container)
      records = JSON.parse(result.stdout).fetch("projects")
      assert_equal [File.realpath(project)], records.map { |record| record.fetch("target") }
      assert_equal "current", records.first.fetch("state")
    end
  end

  def test_batch_apply_preflights_every_target_before_writing_any_target
    FileUtils.mkdir_p(WorkflowKitTestHelpers::FIXTURES_ROOT)
    Dir.mktmpdir("workflow-kit-batch", WorkflowKitTestHelpers::FIXTURES_ROOT) do |container|
      projects = %w[first second].map { |name| File.join(container, name) }
      projects.each do |project|
        run!("git", "init", "-b", "main", project)
        run!("git", "config", "user.name", "Workflow Kit Test", chdir: project)
        run!("git", "config", "user.email", "workflow-kit@example.invalid", chdir: project)
        run!("git", "commit", "--allow-empty", "-m", "baseline", chdir: project)
        bootstrap!(project)
      end

      conflicted_file = File.join(projects.last, ".ai", "runtime", "scripts", "collect_context.rb")
      File.open(conflicted_file, "ab") { |file| file.write("\n# batch conflict\n") }
      first_manifest = File.join(projects.first, ".ai", "KIT_INSTALLATION.yaml")
      first_before = File.binread(first_manifest)
      second_before = File.binread(conflicted_file)

      result = run_command(RbConfig.ruby, UPGRADE, "--json", *reviewed_release_options, "--apply", *projects)
      refute result.success?
      assert_equal 40, result.status.exitstatus
      assert_empty result.stdout
      assert_equal first_before, File.binread(first_manifest)
      assert_equal second_before, File.binread(conflicted_file)
    end
  end
end
