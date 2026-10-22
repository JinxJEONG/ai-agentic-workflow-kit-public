# frozen_string_literal: true

require "json"
require "digest"
require_relative "test_helper"
require_relative "../engine/release/release_manifest"

class InstallerTest < Minitest::Test
  VALIDATE_INSTALL = File.join(WorkflowKitTestHelpers::KIT_ROOT, "engine", "validators", "validate_install.rb")

  def trusted_checkout_identity!(project)
    commit = run!("git", "rev-parse", "HEAD", chdir: WorkflowKitTestHelpers::KIT_ROOT).stdout.strip
    digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest(WorkflowKitTestHelpers::KIT_ROOT, commit)}"
    manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
    manifest = load_yaml(manifest_path)
    manifest["kit_bundle_digest"] = digest
    manifest["provenance"]["release_commit"] = commit
    manifest["ownership_rules"] = WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES.map(&:dup)
    manifest["protected_paths"] = WorkflowKit::Release::ReleaseManifest::PROTECTED_PATHS.dup
    manifest["approval_required_paths"] = WorkflowKit::Release::ReleaseManifest::APPROVAL_REQUIRED_PATHS.dup
    write_yaml(manifest_path, manifest)
    [commit, digest]
  end

  def trusted_action_source_identity!(project, source_root)
    commit = run!("git", "rev-parse", "HEAD", chdir: WorkflowKitTestHelpers::KIT_ROOT).stdout.strip
    digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest_from_filesystem(source_root)}"
    manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
    manifest = load_yaml(manifest_path)
    manifest["kit_bundle_digest"] = digest
    manifest["provenance"]["release_commit"] = commit
    manifest["ownership_rules"] = WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES.map(&:dup)
    manifest["protected_paths"] = WorkflowKit::Release::ReleaseManifest::PROTECTED_PATHS.dup
    manifest["approval_required_paths"] = WorkflowKit::Release::ReleaseManifest::APPROVAL_REQUIRED_PATHS.dup
    write_yaml(manifest_path, manifest)
    [commit, digest]
  end

  def with_action_source_copy
    Dir.mktmpdir("workflow-kit-action-source-") do |temporary|
      source_root = File.realpath(temporary)
      Dir.children(WorkflowKitTestHelpers::KIT_ROOT).each do |entry|
        next if %w[.git .github .memsearch test].include?(entry)

        FileUtils.cp_r(
          File.join(WorkflowKitTestHelpers::KIT_ROOT, entry),
          source_root,
          preserve: true,
        )
      end
      yield source_root
    end
  end

  def run_trusted_validation(
    project, commit, digest, source_root: WorkflowKitTestHelpers::KIT_ROOT, source_mode: "git",
    execution_profile: nil, env: {}
  )
    command = [
      RbConfig.ruby, VALIDATE_INSTALL,
      "--trusted-kit-root", source_root,
      "--trusted-kit-source-mode", source_mode,
      "--expected-kit-commit", commit,
      "--expected-kit-bundle-digest", digest,
    ]
    command.concat(["--execution-profile", execution_profile]) if execution_profile
    command << project
    run_command(*command, env: env)
  end

  def test_installer_entrypoints_are_executable_compatibility_wrappers
    wrappers = {
      "adopt.rb" => "../engine/install/adopt.rb",
      "bootstrap_project.rb" => "../engine/install/bootstrap_project.rb",
      "discover_project.rb" => "../engine/resolver/discover_project.rb",
      "inventory.rb" => "../engine/inventory/inventory.rb",
      "status.rb" => "../engine/install/status.rb",
      "upgrade.rb" => "../engine/install/upgrade.rb",
      "validate_install.rb" => "../engine/validators/validate_install.rb",
    }

    wrappers.each do |name, canonical|
      path = File.join(WorkflowKitTestHelpers::KIT_ROOT, "installer", name)
      assert File.file?(path), "missing compatibility wrapper #{path}"
      assert File.executable?(path), "compatibility wrapper is not executable: #{path}"
      content = File.read(path)
      assert_includes content, canonical
      assert_operator content.lines.length, :<=, 8
    end

    with_project do |project|
      wrapper = File.join(WorkflowKitTestHelpers::KIT_ROOT, "installer", "bootstrap_project.rb")
      result = run_command(RbConfig.ruby, wrapper, "--dry-run", "--json", *reviewed_release_options, project)
      assert result.success?, result.combined
      assert_match(/\Asha256:[0-9a-f]{64}\z/, JSON.parse(result.stdout).fetch("plan_digest"))
    end
  end

  def test_bootstrap_installs_and_validates_a_git_project
    with_project do |project|
      bootstrap!(project)

      result = run!(RbConfig.ruby, script(project, "validate_agent_structure.rb"))
      assert_includes result.stdout, "OK: agent workflow structure is valid."

      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      assert File.exist?(manifest_path), "expected #{manifest_path} to exist"
      refute File.binread(manifest_path).lines.any? { |line| line.match?(/[ \t]+\n\z/) },
             "installation manifest must not contain trailing horizontal whitespace"
      manifest = load_yaml(manifest_path)
      assert_equal 2, manifest.fetch("schema_version")
      assert_equal reviewed_release.fetch("digest"), manifest.fetch("kit_bundle_digest")
      assert_equal reviewed_release.fetch("manifest_digest"), manifest.fetch("release_manifest_digest")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, manifest.fetch("rendered_install_digest"))
      assert_equal "managed", manifest.fetch("installation_state")
      assert_equal 4, manifest.fetch("dirty_snapshot_algo")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, manifest.fetch("repository_fingerprint"))
      assert_equal "generic", manifest.fetch("profile")
      assert_includes manifest.fetch("protected_paths"), ".ai/tasks/**"
      assert_equal "local", manifest.dig("source", "kind")
      assert_match(/\Afile:/, manifest.dig("source", "locator"))
      refute_empty manifest.fetch("installed_files")
      assert manifest.fetch("installed_files").all? { |entry| entry["path"] && entry["sha256"] }
      ci_path = File.join(project, ".github", "workflows", "agent-workflow-policy.yml")
      assert File.file?(ci_path)
      assert_includes File.read(ci_path), "validate-install:"
      workflow = File.read(ci_path)
      assert_includes workflow, "git log --diff-filter=A --format=%H -- .ai/generated/adoption-receipt.json"
      assert_includes workflow, 'adoption_receipt.rb verify --source "$receipt_commit"'
      refute_includes workflow, "adoption_receipt.rb verify --source HEAD"
      refute_includes File.read(ci_path), "spec-gate"
      assert_includes File.read(ci_path), "validate_change_set.rb --mode range"
      assert_includes File.read(ci_path), "scan_repository_secrets.rb --range"
      assert_includes File.read(ci_path), "CHANGE_RANGE:"
    end
  end

  def test_validate_install_runs_the_installation_lock_schema
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      manifest.delete("repository_fingerprint")
      write_yaml(manifest_path, manifest)

      result = run_command(RbConfig.ruby, VALIDATE_INSTALL, project)

      refute result.success?
      assert_includes result.combined, "Installation manifest schema violation"
      assert_includes result.combined, "repository_fingerprint"
    end
  end

  def test_trusted_install_validation_replaces_unavailable_local_release_with_exact_kit_identity
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      commit = run!("git", "rev-parse", "HEAD", chdir: WorkflowKitTestHelpers::KIT_ROOT).stdout.strip
      digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest(WorkflowKitTestHelpers::KIT_ROOT, commit)}"
      manifest["kit_bundle_digest"] = digest
      manifest["source"]["locator"] = "file:///path/that/is/not/on/the/hosted/runner/archive.tar.gz"
      manifest["source"]["manifest_locator"] = "file:///path/that/is/not/on/the/hosted/runner/manifest.json"
      manifest["provenance"]["release_commit"] = commit
      manifest["ownership_rules"] = WorkflowKit::Release::ReleaseManifest::OWNERSHIP_RULES.map(&:dup)
      manifest["protected_paths"] = WorkflowKit::Release::ReleaseManifest::PROTECTED_PATHS.dup
      manifest["approval_required_paths"] = WorkflowKit::Release::ReleaseManifest::APPROVAL_REQUIRED_PATHS.dup
      write_yaml(manifest_path, manifest)

      unavailable = run_command(RbConfig.ruby, VALIDATE_INSTALL, project)
      refute unavailable.success?
      assert_includes unavailable.combined, "Cannot verify current rendered installation/source"
      run!("git", "add", ".", chdir: project)

      trusted = run_command(
        RbConfig.ruby, VALIDATE_INSTALL,
        "--trusted-kit-root", WorkflowKitTestHelpers::KIT_ROOT,
        "--expected-kit-commit", commit,
        "--expected-kit-bundle-digest", digest,
        project,
      )
      assert trusted.success?, trusted.combined
      assert_includes trusted.stdout, "installation is valid"

      write_file(File.join(project, ".ai", "SPEC_REGISTRY.yaml"), "schema_version: 1\n")
      missing_caller = run_command(
        RbConfig.ruby, VALIDATE_INSTALL,
        "--trusted-kit-root", WorkflowKitTestHelpers::KIT_ROOT,
        "--expected-kit-commit", commit,
        "--expected-kit-bundle-digest", digest,
        project,
      )
      refute missing_caller.success?
      assert_includes missing_caller.combined, "Phase 4 spec-gate caller does not match"
      FileUtils.rm(File.join(project, ".ai", "SPEC_REGISTRY.yaml"))

      forged = load_yaml(manifest_path)
      entry = forged.fetch("installed_files").find { |item| item["ownership"] == "kit-owned" }
      entry["template_sha256"] = "0" * 64
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_command(
        RbConfig.ruby, VALIDATE_INSTALL,
        "--trusted-kit-root", WorkflowKitTestHelpers::KIT_ROOT,
        "--expected-kit-commit", commit,
        "--expected-kit-bundle-digest", digest,
        project,
      )
      refute rejected.success?
      assert_includes rejected.combined, "trusted kit template digest mismatch"
    end
  end

  def test_trusted_action_source_validates_filesystem_identity_without_git_metadata
    with_project do |project|
      bootstrap!(project)
      with_action_source_copy do |source_root|
        refute File.exist?(File.join(source_root, ".git"))
        commit, digest = trusted_action_source_identity!(project, source_root)
        run!("git", "add", ".", chdir: project)

        accepted = run_trusted_validation(
          project, commit, digest, source_root: source_root, source_mode: "action-source",
        )
        assert accepted.success?, accepted.combined
        assert_includes accepted.stdout, "installation is valid"

        manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
        forged = load_yaml(manifest_path)
        forged["provenance"]["release_commit"] = "0" * 40
        write_yaml(manifest_path, forged)
        run!("git", "add", manifest_path, chdir: project)
        rejected = run_trusted_validation(
          project, commit, digest, source_root: source_root, source_mode: "action-source",
        )
        refute rejected.success?
        assert_includes rejected.combined, "installation provenance does not match trusted kit commit"
      end
    end
  end

  def test_hosted_install_profile_validates_structure_without_running_target_code
    with_project do |project|
      bootstrap!(project)
      with_action_source_copy do |source_root|
        commit, digest = trusted_action_source_identity!(project, source_root)
        run!("git", "add", ".", chdir: project)

        accepted = run_trusted_validation(
          project,
          commit,
          digest,
          source_root: source_root,
          source_mode: "action-source",
          execution_profile: "hosted-no-project-code",
        )

        assert accepted.success?, accepted.combined
        assert_includes accepted.stdout,
          "hosted structure validation used trusted central code; target executables were not run"

        runtime_library = script(project, "workflow_lib.rb")
        FileUtils.rm(runtime_library)
        run!("git", "add", "-u", chdir: project)
        missing_runtime = run_trusted_validation(
          project,
          commit,
          digest,
          source_root: source_root,
          source_mode: "action-source",
          execution_profile: "hosted-no-project-code",
        )
        refute missing_runtime.success?
        assert_includes missing_runtime.combined, "Missing managed file: .ai/runtime/scripts/workflow_lib.rb"
      end
    end
  end

  def test_hosted_install_profile_rejects_forged_target_validator_without_executing_it
    with_project do |project|
      bootstrap!(project)
      with_action_source_copy do |source_root|
        commit, digest = trusted_action_source_identity!(project, source_root)
        Dir.mktmpdir("target-validator-payload-") do |temporary|
          validator_marker = File.join(temporary, "validator-executed")
          library_marker = File.join(temporary, "workflow-lib-executed")
          target_script = script(project, "validate_agent_structure.rb")
          target_library = script(project, "workflow_lib.rb")
          payload = <<~RUBY
            require_relative "workflow_lib"
            File.write(ENV.fetch("TARGET_VALIDATOR_MARKER"), ENV.fetch("ACTIONS_ID_TOKEN_REQUEST_TOKEN"))
            exit 0
          RUBY
          library_payload = <<~RUBY
            File.write(ENV.fetch("TARGET_LIBRARY_MARKER"), ENV.fetch("ACTIONS_ID_TOKEN_REQUEST_TOKEN"))
          RUBY
          write_file(target_script, payload)
          write_file(target_library, library_payload)
          manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
          manifest = load_yaml(manifest_path)
          payloads = {
            ".ai/runtime/scripts/validate_agent_structure.rb" => payload,
            ".ai/runtime/scripts/workflow_lib.rb" => library_payload,
          }
          payloads.each do |relative, content|
            entry = manifest.fetch("installed_files").find { |item| item["path"] == relative }
            refute_nil entry
            payload_digest = Digest::SHA256.hexdigest(content)
            entry["sha256"] = payload_digest
            entry["baseline_sha256"] = payload_digest
            entry["template_sha256"] = payload_digest
          end
          write_yaml(manifest_path, manifest)
          run!("git", "add", ".", chdir: project)

          rejected = run_trusted_validation(
            project,
            commit,
            digest,
            source_root: source_root,
            source_mode: "action-source",
            execution_profile: "hosted-no-project-code",
            env: {
              "TARGET_VALIDATOR_MARKER" => validator_marker,
              "TARGET_LIBRARY_MARKER" => library_marker,
              "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "mock-oidc-token-that-must-remain-unread",
            },
          )

          refute rejected.success?
          assert_includes rejected.combined,
            "trusted kit template digest mismatch: .ai/runtime/scripts/validate_agent_structure.rb"
          assert_includes rejected.combined,
            "trusted kit template digest mismatch: .ai/runtime/scripts/workflow_lib.rb"
          refute File.exist?(validator_marker), "hosted validation executed the forged target validator"
          refute File.exist?(library_marker), "hosted validation executed the forged target workflow library"
        end
      end
    end
  end

  def test_validate_install_rejects_unknown_execution_profile
    with_project do |project|
      bootstrap!(project)

      rejected = run_command(
        RbConfig.ruby,
        VALIDATE_INSTALL,
        "--execution-profile",
        "hosted-trust-me",
        project,
      )

      refute rejected.success?
      assert_includes rejected.combined, "execution-profile"
    end
  end

  def test_trusted_action_source_rejects_source_digest_drift
    with_project do |project|
      bootstrap!(project)
      with_action_source_copy do |source_root|
        commit, digest = trusted_action_source_identity!(project, source_root)
        run!("git", "add", ".", chdir: project)
        source = File.join(source_root, "engine", "release", "release_digest.rb")
        File.open(source, "ab") { |file| file.write("# untrusted source drift\n") }

        rejected = run_trusted_validation(
          project, commit, digest, source_root: source_root, source_mode: "action-source",
        )
        refute rejected.success?
        assert_includes rejected.combined, "trusted kit source does not match expected bundle digest"
      end
    end
  end

  def test_trusted_install_accepts_only_git_bound_reviewed_merge_content
    with_project do |project|
      bootstrap!(project)
      commit_all!(project, "installed baseline")

      workflow_relative = ".github/workflows/agent-workflow-policy.yml"
      workflow_path = File.join(project, workflow_relative)
      base_digest = Digest::SHA256.file(workflow_path).hexdigest
      Dir.mktmpdir("workflow-kit-reviewed-merge-") do |reviewed|
        merged_path = File.join(reviewed, "agent-workflow-policy.yml")
        write_file(merged_path, "#{File.binread(workflow_path)}\n# reviewed project merge\n")
        applied = apply_reviewed(
          project,
          "--approve-path", "#{workflow_relative}=#{base_digest}",
          "--merge-path", "#{workflow_relative}=#{merged_path}",
        )
        assert applied.success?, applied.combined
      end

      commit, digest = trusted_checkout_identity!(project)
      run!("git", "add", ".", chdir: project)
      accepted = run_trusted_validation(project, commit, digest)
      assert accepted.success?, accepted.combined

      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      valid_manifest = load_yaml(manifest_path)
      valid_manifest_bytes = File.binread(manifest_path)
      File.open(manifest_path, "ab") { |file| file.write("# unstaged lock split\n") }
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "worktree installation lock does not match the selected Git content"
      write_file(manifest_path, valid_manifest_bytes)

      forged = Marshal.load(Marshal.dump(valid_manifest))
      approval = forged.fetch("migration_history").last.fetch("reviewed_path_approvals")
        .find { |entry| entry.fetch("path") == workflow_relative }
      approval["expected_digest"] = "0" * 64
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "expected digest does not match the Git base"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      workflow_entry = forged.fetch("installed_files")
        .find { |entry| entry.fetch("path") == workflow_relative }
      workflow_entry["template_sha256"] = Digest::SHA256.file(
        File.join(WorkflowKitTestHelpers::KIT_ROOT, "core", "project-template", workflow_relative),
      ).hexdigest
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "desired digest does not bind the installed Git content"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      workflow_entry = forged.fetch("installed_files")
        .find { |entry| entry.fetch("path") == workflow_relative }
      workflow_entry["template_sha256"] = Digest::SHA256.file(
        File.join(WorkflowKitTestHelpers::KIT_ROOT, "core", "project-template", workflow_relative),
      ).hexdigest
      forged.fetch("migration_history").last.fetch("reviewed_path_approvals")
        .reject! { |entry| entry.fetch("path") == workflow_relative }
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "must contain exactly one latest record"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      workflow_entry = forged.fetch("installed_files")
        .find { |entry| entry.fetch("path") == workflow_relative }
      workflow_entry["mode"] = "0600"
      write_yaml(manifest_path, forged)
      File.chmod(0o600, workflow_path)
      run!("git", "add", manifest_path, workflow_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "trusted kit mode mismatch: #{workflow_relative}"

      write_yaml(manifest_path, valid_manifest)
      File.chmod(0o644, workflow_path)
      run!("git", "add", manifest_path, workflow_path, chdir: project)
      commit_all!(project, "reviewed merge upgrade")
      committed = run_trusted_validation(project, commit, digest)
      assert committed.success?, committed.combined
    end
  end

  def test_trusted_install_accepts_only_canonical_legacy_relocations
    with_project do |project|
      bootstrap!(project)
      manifest_path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
      manifest = load_yaml(manifest_path)
      runtime_relative = ".ai/runtime/scripts/collect_context.rb"
      legacy_relative = ".ai/scripts/collect_context.rb"
      FileUtils.mkdir_p(File.dirname(File.join(project, legacy_relative)))
      FileUtils.mv(File.join(project, runtime_relative), File.join(project, legacy_relative))
      entry = manifest.fetch("installed_files").find { |item| item.fetch("path") == runtime_relative }
      entry["path"] = legacy_relative
      write_yaml(manifest_path, manifest)
      commit_all!(project, "legacy relocated baseline")

      applied = apply_reviewed(project)
      assert applied.success?, applied.combined
      commit, digest = trusted_checkout_identity!(project)
      run!("git", "add", ".", chdir: project)
      accepted = run_trusted_validation(project, commit, digest)
      assert accepted.success?, accepted.combined

      valid_manifest = load_yaml(manifest_path)
      forged = Marshal.load(Marshal.dump(valid_manifest))
      legacy_entry = forged.fetch("installed_files")
        .find { |item| item.fetch("path") == legacy_relative }
      legacy_entry["relocated_to"] = ".ai/runtime/scripts/create_feature.rb"
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "installation lock contains a path outside the trusted template: #{legacy_relative}"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      legacy_entry = forged.fetch("installed_files")
        .find { |item| item.fetch("path") == legacy_relative }
      legacy_entry["ownership"] = "project-owned"
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "installation lock contains a path outside the trusted template: #{legacy_relative}"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      extra_path = ".ai/unexpected-legacy.rb"
      extra_file = File.join(project, extra_path)
      write_file(extra_file, "# untrusted legacy entry\n")
      forged.fetch("installed_files") << {
        "path" => extra_path,
        "sha256" => Digest::SHA256.file(extra_file).hexdigest,
        "baseline_sha256" => Digest::SHA256.file(extra_file).hexdigest,
        "template_sha256" => Digest::SHA256.file(extra_file).hexdigest,
        "mode" => "0644",
        "ownership" => "kit-owned",
        "state" => "legacy",
        "relocated_to" => runtime_relative,
      }
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, extra_file, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "installation lock contains a path outside the trusted template: #{extra_path}"

      forged = Marshal.load(Marshal.dump(valid_manifest))
      injected_relative = ".githooks/pre-push"
      injected_file = File.join(project, injected_relative)
      runtime_hook = File.join(project, ".ai", "runtime", "githooks", "pre-push")
      FileUtils.mkdir_p(File.dirname(injected_file))
      FileUtils.cp(runtime_hook, injected_file)
      File.chmod(0o755, injected_file)
      injected_digest = Digest::SHA256.file(injected_file).hexdigest
      forged.fetch("installed_files") << {
        "path" => injected_relative,
        "sha256" => injected_digest,
        "baseline_sha256" => injected_digest,
        "template_sha256" => injected_digest,
        "mode" => "0755",
        "ownership" => "kit-owned",
        "state" => "legacy",
        "relocated_to" => ".ai/runtime/githooks/pre-push",
      }
      write_yaml(manifest_path, forged)
      run!("git", "add", manifest_path, injected_file, chdir: project)
      rejected = run_trusted_validation(project, commit, digest)
      refute rejected.success?
      assert_includes rejected.combined, "installation lock contains a path outside the trusted template: #{injected_relative}"
    end
  end

  def test_dry_run_does_not_create_workflow_files
    with_project do |project|
      result = run!(RbConfig.ruby, BOOTSTRAP, "--dry-run", *reviewed_release_options, project)

      assert_includes result.stdout.downcase, "dry"
      refute File.exist?(File.join(project, ".ai"))
      refute File.exist?(File.join(project, "AGENTS.md"))
    end
  end

  def test_bootstrap_normalizes_macos_tmp_symlink
    skip "macOS /tmp symlink test" unless File.realpath("/tmp") != "/tmp"

    with_project do |project|
      bootstrap!(project)
      run!(RbConfig.ruby, script(project, "validate_agent_structure.rb"))

      configured_root = load_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml")).dig("workspace", "root")
      assert_equal File.realpath(project), configured_root
    end
  end

  def test_bootstrap_serializes_a_quoted_path_safely
    with_project(quoted: true) do |project|
      bootstrap!(project)
      run!(RbConfig.ruby, script(project, "validate_agent_structure.rb"))

      configured_root = load_yaml(File.join(project, ".ai", "canonical", "PROJECT_MAP.yaml")).dig("workspace", "root")
      assert_equal File.realpath(project), configured_root
    end
  end

  def test_bootstrap_rejects_a_non_git_directory
    Dir.mktmpdir("workflow-kit-not-git") do |directory|
      result = run_command(RbConfig.ruby, BOOTSTRAP, directory)

      refute result.success?
      assert_match(/git/i, result.combined)
      refute File.exist?(File.join(directory, ".ai"))
    end
  end

  def test_hook_setup_preserves_an_existing_hook_manager
    with_project do |project|
      bootstrap!(project)
      run!("git", "config", "core.hooksPath", ".husky", chdir: project)

      result = run_command(File.join(project, ".ai", "runtime", "scripts", "setup_local_hooks.sh"), chdir: project)
      refute result.success?
      assert_equal ".husky", run!("git", "config", "--get", "core.hooksPath", chdir: project).stdout.strip
    end
  end

  def test_bootstrap_installs_and_validates_a_linked_worktree
    FileUtils.mkdir_p(WorkflowKitTestHelpers::FIXTURES_ROOT)
    Dir.mktmpdir("workflow-kit-linked-worktree", WorkflowKitTestHelpers::FIXTURES_ROOT) do |container|
      primary = File.join(container, "primary")
      linked = File.join(container, "linked")
      run!("git", "init", "-b", "main", primary)
      run!("git", "config", "user.name", "Workflow Kit Test", chdir: primary)
      run!("git", "config", "user.email", "workflow-kit@example.invalid", chdir: primary)
      run!("git", "commit", "--allow-empty", "-m", "baseline", chdir: primary)
      run!("git", "worktree", "add", "-b", "linked-test", linked, chdir: primary)

      bootstrap!(linked)
      result = run!(RbConfig.ruby, VALIDATE_INSTALL, linked)

      assert_includes result.stdout, "installation is valid"
      manifest = load_yaml(File.join(linked, ".ai", "KIT_INSTALLATION.yaml"))
      assert_equal "file", manifest.dig("git", "git_dir_kind")
      assert_equal true, manifest.dig("git", "linked_worktree")
      assert_equal File.realpath(linked), manifest.fetch("workspace_root")
      assert_equal File.realpath(linked), load_yaml(File.join(linked, ".ai", "canonical", "PROJECT_MAP.yaml")).dig("workspace", "root")
    end
  end

  def test_validate_install_allows_project_owned_drift_and_rejects_kit_owned_drift
    with_project do |project|
      bootstrap!(project)
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      entries = manifest.fetch("installed_files").to_h { |entry| [entry.fetch("path"), entry] }
      assert_equal "project-owned", entries.fetch(".ai/canonical/PROJECT_RULES.md").fetch("ownership")
      assert_equal "kit-owned", entries.fetch(".ai/runtime/scripts/collect_context.rb").fetch("ownership")

      project_rules = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      File.open(project_rules, "ab") { |file| file.write("\nProject-specific customization.\n") }

      project_result = run!(RbConfig.ruby, VALIDATE_INSTALL, project)
      assert_includes project_result.stdout, "installation is valid"
      assert_includes project_result.stdout, "NOTICE"
      assert_includes project_result.stdout, ".ai/canonical/PROJECT_RULES.md"

      kit_script = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      File.open(kit_script, "ab") { |file| file.write("\n# unexpected kit drift\n") }

      kit_result = run_command(RbConfig.ruby, VALIDATE_INSTALL, project)
      refute kit_result.success?
      assert_includes kit_result.combined, "Digest mismatch for .ai/runtime/scripts/collect_context.rb"
    end
  end

  def test_force_replacement_preserves_project_owned_files_and_records_repair_history
    with_project do |project|
      bootstrap!(project)
      project_rules = File.join(project, ".ai", "canonical", "PROJECT_RULES.md")
      File.open(project_rules, "ab") { |file| file.write("\nProject-specific conflicting rule.\n") }
      project_content = File.binread(project_rules)
      kit_path = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      File.open(kit_path, "ab") { |file| file.write("\n# local kit drift\n") }
      kit_content = File.binread(kit_path)

      safe_result = bootstrap_plan(project)
      refute safe_result.success?
      assert_includes safe_result.combined, "conflict"
      assert_equal project_content, File.binread(project_rules)
      assert_equal kit_content, File.binread(kit_path)

      json_result = run_command(RbConfig.ruby, BOOTSTRAP, "--json", project)
      refute json_result.success?
      assert_equal "blocked", JSON.parse(json_result.stdout).fetch("status")

      rejected_project_replacement = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--replace-project-owned",
        project,
      )
      refute rejected_project_replacement.success?
      assert_includes rejected_project_replacement.combined, "invalid option"

      bootstrap!(project, "--force")
      manifest = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
      history = manifest.fetch("migration_history")
      assert_equal 2, history.length

      repair = history.last
      assert_equal "repair", repair.fetch("action")
      assert_equal manifest.fetch("schema_version"), repair.fetch("to_schema_version")
      assert_equal manifest.fetch("kit_version"), repair.fetch("to_kit_version")
      assert_match(%r{\A\.ai/local/backups/kit-installation-}, repair.fetch("backup_path"))

      backup_relative = File.join(repair.fetch("backup_path"), ".ai", "runtime", "scripts", "collect_context.rb")
      backup_path = File.join(project, backup_relative)
      assert_equal kit_content, File.binread(backup_path)
      assert_equal project_content, File.binread(project_rules)
      refute_equal kit_content, File.binread(kit_path)
      run!("git", "check-ignore", "-q", backup_relative, chdir: project)
      run!(RbConfig.ruby, VALIDATE_INSTALL, project)

      approval = Digest::SHA256.hexdigest(project_content)
      bootstrap!(project, "--force", "--approve-path", ".ai/canonical/PROJECT_RULES.md=#{approval}")
      refute_equal project_content, File.binread(project_rules)
      run!(RbConfig.ruby, VALIDATE_INSTALL, project)
    end
  end

  def test_force_does_not_replace_a_symbolic_link_destination
    with_project do |project|
      bootstrap!(project)
      kit_path = File.join(project, ".ai", "runtime", "scripts", "collect_context.rb")
      FileUtils.rm(kit_path)
      FileUtils.ln_s("../../../AGENTS.md", kit_path)

      result = bootstrap_plan(project, "--force")
      refute result.success?
      assert_includes result.combined, "symbolic-link"
      assert File.symlink?(kit_path)
      assert_equal File.realpath(File.join(project, "AGENTS.md")), File.realpath(kit_path)
    end
  end
end
