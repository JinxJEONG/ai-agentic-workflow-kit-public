# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "../installer/lib/install_integrity"
require_relative "../installer/lib/release_digest"
require_relative "../installer/lib/release_source"

class SourceGateTest < Minitest::Test
  INSTALL_ENTRYPOINTS = %w[
    engine/install/bootstrap_project.rb
    engine/install/status.rb
    engine/install/upgrade.rb
    engine/install/adopt.rb
    installer/bootstrap_project.rb
    installer/status.rb
    installer/upgrade.rb
    installer/adopt.rb
  ].map { |relative| File.join(WorkflowKitTestHelpers::KIT_ROOT, relative) }.freeze

  def archive_release(directory, source_root)
    archive = File.join(directory, "release.tar.gz")
    run!(
      "tar",
      "-czf",
      archive,
      "--exclude=.git",
      "-C",
      File.dirname(source_root),
      File.basename(source_root),
    )
    archive
  end

  def release_manifest(path, source_root: WorkflowKitTestHelpers::KIT_ROOT, pinnable: true, bundle_digest: nil, release_ref: nil, release_commit: "a" * 40, tombstones: [])
    release_ref ||= "refs/tags/v#{File.read(File.join(source_root, "VERSION")).strip}"
    excludes = WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES
    digest = bundle_digest || WorkflowKit::Release::ReleaseDigest.digest_from_directory(
      source_root,
      excludes: excludes,
    )
    archive = archive_release(File.dirname(path), source_root)
    manifest = {
      "manifest_schema" => 2,
      "kit_version" => File.read(File.join(source_root, "VERSION")).strip,
      "release_ref" => release_ref,
      "release_commit" => release_commit,
      "pinnable" => pinnable,
      "bundle_digest_algo" => 2,
      "kit_bundle_digest" => "sha256:#{digest}",
      "excluded_paths" => excludes,
      "rendered_digest_algo" => 2,
      "dirty_snapshot_algo" => 4,
      "ownership_rules" => WorkflowKit::Install::Integrity::DEFAULT_OWNERSHIP_RULES,
      "protected_paths" => WorkflowKit::Install::Integrity::DEFAULT_PROTECTED_PATHS,
      "approval_required_paths" => WorkflowKit::Install::Integrity::DEFAULT_APPROVAL_REQUIRED_PATHS,
      "tombstones" => tombstones,
      "source" => {
        "kind" => "local",
        "locator" => WorkflowKit::Install::ReleaseSource.file_uri(archive),
        "manifest_locator" => WorkflowKit::Install::ReleaseSource.file_uri(path),
        "bundle_archive_sha256" => "sha256:#{Digest::SHA256.file(archive).hexdigest}",
      },
      "provenance" => { "source_clean" => true, "source_tagged" => true },
    }
    File.write(path, JSON.pretty_generate(manifest))
    [manifest, "sha256:#{digest}", "sha256:#{Digest::SHA256.file(path).hexdigest}"]
  end

  def cache_env(directory)
    { "KIT_RELEASE_CACHE" => File.join(directory, "release-cache") }
  end

  def with_release_cache(directory)
    previous = ENV["KIT_RELEASE_CACHE"]
    ENV["KIT_RELEASE_CACHE"] = File.join(directory, "release-cache")
    yield
  ensure
    if previous
      ENV["KIT_RELEASE_CACHE"] = previous
    else
      ENV.delete("KIT_RELEASE_CACHE")
    end
  end

  def with_external_project
    Dir.mktmpdir("workflow-kit-production-target") do |project|
      run!("git", "init", "-b", "main", project)
      run!("git", "config", "user.name", "Workflow Kit Test", chdir: project)
      run!("git", "config", "user.email", "workflow-kit@example.invalid", chdir: project)
      yield project
    end
  end

  def production_plan(project, manifest_path, expected, manifest_digest, directory, *options)
    run_command(
      RbConfig.ruby,
      BOOTSTRAP,
      "--dry-run",
      "--json",
      "--source-manifest",
      manifest_path,
      "--expected-kit-bundle-digest",
      expected,
      "--expected-release-manifest-digest",
      manifest_digest,
      *options,
      project,
      env: cache_env(directory),
    )
  end

  def apply_production_plan(project, manifest_path, expected, manifest_digest, plan_digest, directory, *options)
    run_command(
      RbConfig.ruby,
      BOOTSTRAP,
      "--json",
      "--source-manifest",
      manifest_path,
      "--expected-kit-bundle-digest",
      expected,
      "--expected-release-manifest-digest",
      manifest_digest,
      "--plan-digest",
      plan_digest,
      *options,
      project,
      env: cache_env(directory),
    )
  end

  def test_dev_source_option_is_unknown_for_every_install_entrypoint
    with_external_project do |project|
      INSTALL_ENTRYPOINTS.each do |entrypoint|
        result = run_command(RbConfig.ruby, entrypoint, "--dev-source", project)
        refute result.success?, "#{entrypoint} accepted the expired --dev-source flag"
        assert_includes result.combined, "invalid option: --dev-source"
      end
      refute File.exist?(File.join(project, ".ai"))
    end
  end

  def test_working_tree_source_cannot_apply_without_a_reviewed_release
    with_external_project do |project|
      result = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        "--plan-digest",
        "sha256:#{'0' * 64}",
        project,
      )

      refute result.success?
      assert_includes result.combined, "requires --source-manifest"
      refute File.exist?(File.join(project, ".ai"))
    end
  end

  def test_production_plan_requires_manifest_and_independent_expected_digest
    with_external_project do |project|
      missing = run_command(RbConfig.ruby, BOOTSTRAP, "--dry-run", "--json", project)
      refute missing.success?
      assert_includes missing.combined, "requires --source-manifest"

      Dir.mktmpdir("workflow-kit-sidecar") do |directory|
        manifest_path = File.join(directory, "release.manifest.json")
        _manifest, expected, manifest_digest = release_manifest(manifest_path)
        no_trust_root = run_command(RbConfig.ruby, BOOTSTRAP, "--dry-run", "--json", "--source-manifest", manifest_path, project)
        refute no_trust_root.success?
        assert_includes no_trust_root.combined, "expected kit bundle digest"

        no_manifest_trust_root = run_command(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          manifest_path,
          "--expected-kit-bundle-digest",
          expected,
          project,
        )
        refute no_manifest_trust_root.success?
        assert_includes no_manifest_trust_root.combined, "expected release manifest digest"

        plan = run!(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          manifest_path,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          manifest_digest,
          project,
          env: cache_env(directory),
        )
        payload = JSON.parse(plan.stdout)
        assert_equal expected, payload.dig("source", "kit_bundle_digest")

        applied = run!(
          RbConfig.ruby,
          BOOTSTRAP,
          "--json",
          "--source-manifest",
          manifest_path,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          manifest_digest,
          "--plan-digest",
          payload.fetch("plan_digest"),
          project,
          env: cache_env(directory),
        )
        assert_equal "installed", JSON.parse(applied.stdout).fetch("status")
        lock = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
        assert_equal "managed", lock.fetch("installation_state")
        assert_equal "local", lock.dig("source", "kind")
        assert_equal expected, lock.fetch("kit_bundle_digest")
        assert_equal manifest_digest, lock.fetch("release_manifest_digest")
        assert_match(/\Asha256:[0-9a-f]{64}\z/, lock.dig("source", "bundle_archive_sha256"))
        assert_equal "refs/tags/v#{File.read(File.join(WorkflowKitTestHelpers::KIT_ROOT, "VERSION")).strip}", lock.dig("provenance", "release_ref")
        assert_equal "a" * 40, lock.dig("provenance", "release_commit")

        status = run!(
          RbConfig.ruby,
          File.join(WorkflowKitTestHelpers::KIT_ROOT, "installer", "status.rb"),
          "--json",
          project,
          env: cache_env(directory),
        )
        assert_equal "current", JSON.parse(status.stdout).fetch("state")

        validation = run!(
          RbConfig.ruby,
          File.join(WorkflowKitTestHelpers::KIT_ROOT, "installer", "validate_install.rb"),
          project,
          env: cache_env(directory),
        )
        assert_includes validation.stdout, "installation is valid"
      end
    end
  end

  def test_forged_or_non_pinnable_release_manifest_is_rejected
    with_external_project do |project|
      Dir.mktmpdir("workflow-kit-sidecar") do |directory|
        forged_path = File.join(directory, "forged.json")
        _manifest, actual, manifest_digest = release_manifest(forged_path, bundle_digest: "0" * 64)
        forged = run_command(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          forged_path,
          "--expected-kit-bundle-digest",
          actual,
          "--expected-release-manifest-digest",
          manifest_digest,
          project,
          env: cache_env(directory),
        )
        refute forged.success?
        assert_includes forged.combined, "release contents do not match"

        baseline_path = File.join(directory, "baseline.json")
        _baseline, expected, baseline_digest = release_manifest(baseline_path, pinnable: false)
        baseline = run_command(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          baseline_path,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          baseline_digest,
          project,
          env: cache_env(directory),
        )
        refute baseline.success?
        assert_includes baseline.combined, "not pinnable"
      end
    end
  end

  def test_legacy_dirty_snapshot_release_manifest_is_rejected
    with_external_project do |project|
      Dir.mktmpdir("workflow-kit-legacy-snapshot") do |directory|
        manifest_path = File.join(directory, "release.manifest.json")
        manifest, expected, _manifest_digest = release_manifest(manifest_path)
        manifest["dirty_snapshot_algo"] = 3
        File.write(manifest_path, JSON.pretty_generate(manifest))
        manifest_digest = "sha256:#{Digest::SHA256.file(manifest_path).hexdigest}"

        result = production_plan(
          project,
          manifest_path,
          expected,
          manifest_digest,
          directory,
        )

        refute result.success?
        assert_includes result.combined, "dirty_snapshot_algo must be 4"
        refute File.exist?(File.join(project, ".ai"))
      end
    end
  end

  def test_policy_only_sidecar_tampering_is_rejected_before_it_can_change_ownership
    with_external_project do |project|
      Dir.mktmpdir("workflow-kit-policy-tamper") do |directory|
        sidecar = File.join(directory, "release.manifest.json")
        manifest, expected, manifest_digest = release_manifest(sidecar)
        manifest["ownership_rules"] = [{ "glob" => "**", "ownership" => "project-owned" }]
        File.write(sidecar, JSON.pretty_generate(manifest))

        result = run_command(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          sidecar,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          manifest_digest,
          project,
          env: cache_env(directory),
        )

        refute result.success?
        assert_includes result.combined, "manifest bytes do not match"
        refute File.exist?(File.join(project, ".ai"))
      end
    end
  end


  def test_production_bundle_verification_includes_files_outside_installer_scopes
    Dir.mktmpdir("workflow-kit-resolved-release") do |directory|
      release_root = File.join(directory, "release-root")
      FileUtils.mkdir_p(release_root)
      write_file(File.join(release_root, "VERSION"), "9.9.9\n")
      write_file(File.join(release_root, "Rakefile"), "task :outside_legacy_scope\n")
      expected = WorkflowKit::Release::ReleaseDigest.digest_from_directory(release_root)
      sidecar = File.join(directory, "release.manifest.json")
      _manifest, _bundle_digest, manifest_digest = release_manifest(sidecar, source_root: release_root)

      context = with_release_cache(directory) do
        WorkflowKit::Install::ReleaseSource.production_context(
          release_root,
          {},
          manifest_locator: sidecar,
          expected_bundle_digest: "sha256:#{expected}",
          expected_manifest_digest: manifest_digest,
        )
      end
      assert_equal "sha256:#{expected}", context.fetch("kit_bundle_digest")
      resolved_rakefile = File.join(context.fetch("resolved_release_root"), "Rakefile")
      assert_equal "task :outside_legacy_scope\n", File.read(resolved_rakefile)

      File.write(File.join(release_root, "Rakefile"), "task :tampered_outside_legacy_scope\n")
      updated_context = with_release_cache(directory) do
        WorkflowKit::Install::ReleaseSource.production_context(
          release_root,
          {},
          manifest_locator: sidecar,
          expected_bundle_digest: "sha256:#{expected}",
          expected_manifest_digest: manifest_digest,
        )
      end
      assert_equal "sha256:#{expected}", updated_context.fetch("kit_bundle_digest")
      assert_equal "task :outside_legacy_scope\n", File.read(updated_context.fetch("resolved_release_root") + "/Rakefile")
    end
  end

  def test_managed_install_renders_templates_from_the_verified_archive_not_the_local_worktree
    with_external_project do |project|
      Dir.mktmpdir("workflow-kit-archive-render") do |directory|
        source_root = File.join(directory, "release-root")
        FileUtils.cp_r(WorkflowKitTestHelpers::KIT_ROOT, source_root)
        archived_agents = "# Archived release policy\n"
        write_file(File.join(source_root, "core", "project-template", "AGENTS.md"), archived_agents)
        sidecar = File.join(directory, "release.manifest.json")
        _manifest, expected, manifest_digest = release_manifest(sidecar, source_root: source_root)

        plan = run!(
          RbConfig.ruby,
          BOOTSTRAP,
          "--dry-run",
          "--json",
          "--source-manifest",
          sidecar,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          manifest_digest,
          project,
          env: cache_env(directory),
        )
        payload = JSON.parse(plan.stdout)
        agents_plan = payload.fetch("files").find { |entry| entry.fetch("path") == "AGENTS.md" }
        assert_equal Digest::SHA256.hexdigest(archived_agents), agents_plan.fetch("desired_digest")

        applied = run!(
          RbConfig.ruby,
          BOOTSTRAP,
          "--json",
          "--source-manifest",
          sidecar,
          "--expected-kit-bundle-digest",
          expected,
          "--expected-release-manifest-digest",
          manifest_digest,
          "--plan-digest",
          payload.fetch("plan_digest"),
          project,
          env: cache_env(directory),
        )
        assert_equal "installed", JSON.parse(applied.stdout).fetch("status")
        assert_equal archived_agents, File.read(File.join(project, "AGENTS.md"))
      end
    end
  end


  def test_tombstone_requires_matching_digest_and_exact_approval_before_deletion
    with_external_project do |project|
      Dir.mktmpdir("workflow-kit-tombstone-release") do |directory|
        initial_directory = File.join(directory, "initial")
        initial_source = File.join(initial_directory, "source")
        FileUtils.mkdir_p(initial_directory)
        FileUtils.cp_r(WorkflowKitTestHelpers::KIT_ROOT, initial_source)
        relative = ".ai/runtime/scripts/removed-from-release.rb"
        write_file(File.join(initial_source, "core", "project-template", relative), "puts :installed\n")
        initial_sidecar = File.join(initial_directory, "release.manifest.json")
        _initial, initial_expected, initial_manifest_digest = release_manifest(
          initial_sidecar,
          source_root: initial_source,
          release_commit: "b" * 40,
        )

        initial_plan = production_plan(
          project,
          initial_sidecar,
          initial_expected,
          initial_manifest_digest,
          initial_directory,
        )
        assert initial_plan.success?, initial_plan.combined
        initial_payload = JSON.parse(initial_plan.stdout)
        initial_apply = apply_production_plan(
          project,
          initial_sidecar,
          initial_expected,
          initial_manifest_digest,
          initial_payload.fetch("plan_digest"),
          initial_directory,
        )
        assert initial_apply.success?, initial_apply.combined

        orphan = File.join(project, relative)
        assert File.file?(orphan)
        current_digest = Digest::SHA256.file(orphan).hexdigest

        mismatch_directory = File.join(directory, "mismatch")
        mismatch_source = File.join(mismatch_directory, "source")
        FileUtils.mkdir_p(mismatch_directory)
        FileUtils.cp_r(WorkflowKitTestHelpers::KIT_ROOT, mismatch_source)
        mismatch_sidecar = File.join(mismatch_directory, "release.manifest.json")
        _mismatch, mismatch_expected, mismatch_manifest_digest = release_manifest(
          mismatch_sidecar,
          source_root: mismatch_source,
          release_commit: "c" * 40,
          tombstones: [{ "path" => relative, "expected_digest" => "sha256:#{'0' * 64}" }],
        )
        mismatch_plan = production_plan(
          project,
          mismatch_sidecar,
          mismatch_expected,
          mismatch_manifest_digest,
          mismatch_directory,
          "--approve-path",
          "#{relative}=#{current_digest}",
        )
        refute mismatch_plan.success?
        mismatch_payload = JSON.parse(mismatch_plan.stdout)
        mismatch_entry = mismatch_payload.fetch("files").find { |entry| entry.fetch("path") == relative }
        assert_equal "conflict", mismatch_entry.fetch("action")
        assert_equal "tombstone_digest_mismatch", mismatch_entry.fetch("reason")
        assert File.file?(orphan)

        approved_directory = File.join(directory, "approved")
        approved_source = File.join(approved_directory, "source")
        FileUtils.mkdir_p(approved_directory)
        FileUtils.cp_r(WorkflowKitTestHelpers::KIT_ROOT, approved_source)
        approved_sidecar = File.join(approved_directory, "release.manifest.json")
        _approved, approved_expected, approved_manifest_digest = release_manifest(
          approved_sidecar,
          source_root: approved_source,
          release_commit: "d" * 40,
          tombstones: [{ "path" => relative, "expected_digest" => "sha256:#{current_digest}" }],
        )
        unapproved_plan = production_plan(
          project,
          approved_sidecar,
          approved_expected,
          approved_manifest_digest,
          approved_directory,
        )
        refute unapproved_plan.success?
        unapproved_payload = JSON.parse(unapproved_plan.stdout)
        unapproved_entry = unapproved_payload.fetch("files").find { |entry| entry.fetch("path") == relative }
        assert_equal "conflict", unapproved_entry.fetch("action")
        assert_equal "tombstone_approval_required", unapproved_entry.fetch("reason")
        assert File.file?(orphan)

        approval_options = ["--approve-path", "#{relative}=#{current_digest}"]
        approved_plan = production_plan(
          project,
          approved_sidecar,
          approved_expected,
          approved_manifest_digest,
          approved_directory,
          *approval_options,
        )
        assert approved_plan.success?, approved_plan.combined
        approved_payload = JSON.parse(approved_plan.stdout)
        approved_entry = approved_payload.fetch("files").find { |entry| entry.fetch("path") == relative }
        assert_equal "delete", approved_entry.fetch("action")
        assert_equal "approved_tombstone", approved_entry.fetch("reason")

        approved_apply = apply_production_plan(
          project,
          approved_sidecar,
          approved_expected,
          approved_manifest_digest,
          approved_payload.fetch("plan_digest"),
          approved_directory,
          *approval_options,
        )
        assert approved_apply.success?, approved_apply.combined
        refute File.exist?(orphan)
        lock = load_yaml(File.join(project, ".ai", "KIT_INSTALLATION.yaml"))
        refute_includes lock.fetch("installed_files").map { |entry| entry.fetch("path") }, relative
      end
    end
  end
end
