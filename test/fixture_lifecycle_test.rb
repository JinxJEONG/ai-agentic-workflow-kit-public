# frozen_string_literal: true

require "digest"
require "json"

require_relative "test_helper"
require_relative "../fixtures/build_fixture"
require_relative "../engine/release/dirty_snapshot"
require_relative "../engine/resolver/project_context"

class FixtureLifecycleTest < Minitest::Test
  BUILDER = WorkflowKit::FixtureBuilder
  VALIDATE = File.join(KIT_ROOT, "engine", "validators", "validate_install.rb")
  STATUS = File.join(KIT_ROOT, "engine", "install", "status.rb")

  def with_fixture(type)
    fixture = BUILDER.build(type, parent: WorkflowKitTestHelpers::FIXTURES_ROOT)
    yield fixture
  ensure
    BUILDER.cleanup(fixture) if fixture
  end

  def release_options(release)
    [
      "--source-manifest", release.fetch("manifest"),
      "--expected-kit-bundle-digest", release.fetch("digest"),
      "--expected-release-manifest-digest", release.fetch("manifest_digest"),
    ]
  end

  def release_env(release)
    { "KIT_RELEASE_CACHE" => release.fetch("cache") }
  end

  def release_plan(path, release, *options)
    run_command(
      RbConfig.ruby,
      BOOTSTRAP,
      "--dry-run",
      "--json",
      *release_options(release),
      *options,
      path,
      env: release_env(release),
    )
  end

  def apply_release(path, release, *options)
    reviewed = release_plan(path, release, *options)
    assert reviewed.success?, "release plan failed:\n#{reviewed.combined}"
    payload = JSON.parse(reviewed.stdout)
    applied = run_command(
      RbConfig.ruby,
      BOOTSTRAP,
      "--json",
      *release_options(release),
      *options,
      "--plan-digest",
      payload.fetch("plan_digest"),
      path,
      env: release_env(release),
    )
    [payload, applied]
  end

  def release_status(path, release)
    result = run_command(
      RbConfig.ruby,
      STATUS,
      "--json",
      *release_options(release),
      path,
      env: release_env(release),
    )
    [JSON.parse(result.stdout), result]
  end

  alias plan release_plan
  alias apply apply_release
  alias status release_status

  def sha256_files(root, paths)
    paths.each_with_object({}) do |relative, result|
      result[relative] = Digest::SHA256.file(File.join(root, relative)).hexdigest
    end
  end

  def git_status_digest(path)
    output = run!("git", "status", "--porcelain=v1", "-z", "--untracked-files=all", chdir: path).stdout
    Digest::SHA256.hexdigest(output)
  end

  def working_tree_digest(path)
    raw = run!(
      "git",
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
      "-z",
      chdir: path,
    ).stdout
    material = raw.split("\0").reject(&:empty?).sort.map do |relative|
      absolute = File.join(path, relative)
      content_digest = File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : "missing"
      "#{relative}\0#{content_digest}\0"
    end.join
    Digest::SHA256.hexdigest(material)
  end

  def test_builder_creates_all_nine_documented_topologies
    assert_equal 9, BUILDER::TYPES.length
    BUILDER::TYPES.each do |type|
      with_fixture(type) do |fixture|
        assert_equal type, fixture.fetch("type")
        assert File.directory?(fixture.fetch("path"))
        assert File.file?(fixture.fetch("metadata_path"))
        assert_match(/\A[0-9a-f]{40,64}\z/, fixture.fetch("baseline_commit"))
        assert fixture.fetch("worktrees").all? { |path| File.directory?(path) }
        release = fixture.fetch("release")
        assert File.file?(release.fetch("manifest"))
        assert File.file?(release.fetch("archive"))
        assert_match(/\Asha256:[0-9a-f]{64}\z/, release.fetch("digest"))
        assert_match(/\Asha256:[0-9a-f]{64}\z/, release.fetch("manifest_digest"))
      end
    end
  end

  def test_cleanup_refuses_a_non_fixture_path
    error = assert_raises(WorkflowKit::FixtureBuilder::FixtureError) do
      BUILDER.cleanup(KIT_ROOT)
    end
    assert_includes error.message, "refusing to remove"
    assert File.directory?(KIT_ROOT)
  end

  def test_project_helper_cleans_its_directory_when_the_test_block_fails
    project = nil
    error = assert_raises(RuntimeError) do
      with_project(prefix: "workflow-kit-test-cleanup") do |path|
        project = path
        raise "synthetic test failure"
      end
    end

    assert_equal "synthetic test failure", error.message
    refute_nil project
    refute File.exist?(project)
  end

  def test_fixture_builder_cleans_its_container_when_build_fails
    Dir.mktmpdir("workflow-kit-fixture-cleanup-parent") do |parent|
      error = assert_raises(RuntimeError) do
        BUILDER.stub(:build_in, ->(_container, _type) { raise "synthetic fixture failure" }) do
          BUILDER.build("legacy-unknown", parent: parent)
        end
      end

      assert_equal "synthetic fixture failure", error.message
      assert_empty Dir[File.join(parent, "workflow-kit-legacy-unknown-*")]
    end
  end

  def test_legacy_unknown_preserves_three_canonical_files_through_apply_validate_status
    with_fixture("legacy-unknown") do |fixture|
      root = fixture.fetch("path")
      release = fixture.fetch("release")
      canonical = BUILDER::LEGACY_CANONICAL_PATHS
      before = sha256_files(root, canonical)
      dirty_records = run!(
        "git",
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        chdir: root,
      ).stdout.split("\0").reject(&:empty?)
      dirty_paths = dirty_records.map { |record| record.byteslice(3, record.bytesize - 3) }.sort
      assert_equal fixture.fetch("dirty_paths").sort, dirty_paths
      refute File.exist?(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))
      hooks = run_command("git", "config", "--get", "core.hooksPath", chdir: root)
      refute hooks.success?
      assert_empty hooks.stdout

      _reviewed, applied = apply(root, release)
      assert applied.success?, applied.combined
      assert_equal before, sha256_files(root, canonical)

      validated = run!(RbConfig.ruby, VALIDATE, root, env: release_env(release))
      assert_includes validated.stdout, "installation is valid"
      record, status_result = status(root, release)
      assert status_result.success?, status_result.combined
      assert_equal "current", record.fetch("state")
      assert_equal "managed", record.dig("manifest", "installation_state")
    end
  end

  def test_managed_current_round_trip_is_current_with_exact_installed_digests
    with_fixture("managed-current") do |fixture|
      root = fixture.fetch("path")
      release = fixture.fetch("release")
      reviewed, applied = apply_release(root, release)
      assert applied.success?, applied.combined
      assert_equal 0, reviewed.dig("counts", "conflict").to_i

      manifest = load_yaml(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))
      assert_equal 2, manifest.fetch("schema_version")
      assert_equal "managed", manifest.fetch("installation_state")
      assert_equal release.fetch("version"), manifest.fetch("kit_version")
      assert_equal release.fetch("digest"), manifest.fetch("kit_bundle_digest")
      assert manifest.fetch("installed_files").all? do |entry|
        path = File.join(root, entry.fetch("path"))
        File.file?(path) && Digest::SHA256.file(path).hexdigest == entry.fetch("sha256")
      end

      run!(RbConfig.ruby, VALIDATE, root, env: release_env(release))
      record, status_result = release_status(root, release)
      assert status_result.success?, status_result.combined
      assert_equal "current", record.fetch("state")
    end
  end

  def test_same_version_template_drift_is_not_current
    with_fixture("managed-drifted") do |fixture|
      root = fixture.fetch("path")
      release = fixture.fetch("release")
      installed_release = fixture.fetch("installed_release")
      assert_equal installed_release.fetch("version"), release.fetch("version")
      refute_equal installed_release.fetch("digest"), release.fetch("digest")
      refute_equal installed_release.fetch("template_digest"), release.fetch("template_digest")

      installed_lock = load_yaml(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))
      assert_equal installed_release.fetch("digest"), installed_lock.fetch("kit_bundle_digest")
      run!(RbConfig.ruby, VALIDATE, root, env: release_env(installed_release))

      reviewed = release_plan(root, release)
      assert reviewed.success?, reviewed.combined
      payload = JSON.parse(reviewed.stdout)
      assert_operator payload.dig("counts", "update"), :>=, 1
      assert_equal release.fetch("version"), payload.dig("source", "kit_version")
      assert_equal release.fetch("digest"), payload.dig("source", "kit_bundle_digest")

      before_record, before_status = release_status(root, release)
      refute before_status.success?
      assert_equal "upgrade_available", before_record.fetch("state")

      applied = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *release_options(release),
        "--plan-digest",
        payload.fetch("plan_digest"),
        root,
        env: release_env(release),
      )
      assert applied.success?, applied.combined
      run!(RbConfig.ruby, VALIDATE, root, env: release_env(release))

      record, status_result = release_status(root, release)
      assert status_result.success?, status_result.combined
      assert_equal "current", record.fetch("state")
      upgraded_lock = load_yaml(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))
      assert_equal release.fetch("version"), upgraded_lock.fetch("kit_version")
      assert_equal release.fetch("digest"), upgraded_lock.fetch("kit_bundle_digest")
    end
  end

  def test_blocked_active_has_six_locks_and_refuses_apply_without_writes
    with_fixture("blocked-active") do |fixture|
      root = fixture.fetch("path")
      release = fixture.fetch("release")
      locks = Dir[File.join(root, ".ai", "tasks", "**", "LOCK.yaml")]
      assert_equal 6, locks.length
      before = git_status_digest(root)

      reviewed = plan(root, release)
      assert reviewed.success?, reviewed.combined
      assert_includes reviewed.stderr, "blocked"
      payload = JSON.parse(reviewed.stdout)
      assert_equal 6, payload.dig("activity", "lock_paths").length
      assert_equal 1, payload.dig("activity", "active_streams").length

      applied = run_command(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *release_options(release),
        "--plan-digest",
        payload.fetch("plan_digest"),
        root,
        env: release_env(release),
      )
      refute applied.success?
      assert_includes applied.combined, "blocked"
      assert_equal before, git_status_digest(root)
      refute File.exist?(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))

      record, status_result = status(root, release)
      assert_equal 30, status_result.status.exitstatus
      assert_equal "blocked", record.fetch("state")
      validation = run_command(RbConfig.ruby, VALIDATE, root, env: release_env(release))
      refute validation.success?
    end
  end

  def test_linked_worktrees_share_fingerprint_but_not_worktree_path
    with_fixture("linked-worktree") do |fixture|
      primary = fixture.fetch("primary")
      linked = fixture.fetch("linked")
      release = fixture.fetch("release")
      primary_context = WorkflowKit::ProjectContext.build(primary)
      linked_context = WorkflowKit::ProjectContext.build(linked)

      assert_equal primary_context.fetch("repository_fingerprint"),
        linked_context.fetch("repository_fingerprint")
      refute_equal primary_context.fetch("root"), linked_context.fetch("root")
      assert_equal "true", run!("git", "rev-parse", "--is-inside-work-tree", chdir: linked).stdout.strip

      _reviewed, applied = apply(primary, release)
      assert applied.success?, applied.combined
      run!(RbConfig.ruby, VALIDATE, primary, env: release_env(release))
      record, status_result = status(primary, release)
      assert status_result.success?, status_result.combined
      assert_equal "current", record.fetch("state")
    end
  end

  def test_volatile_linked_worktree_dirty_snapshot_is_worktree_local
    with_fixture("volatile-worktree") do |fixture|
      primary = fixture.fetch("primary")
      linked = fixture.fetch("linked")
      release = fixture.fetch("release")
      clean_snapshot = WorkflowKit::Release::DirtySnapshot.snapshot(primary)
      dirty_snapshot = WorkflowKit::Release::DirtySnapshot.snapshot(linked)
      clean = clean_snapshot.fetch("dirty_snapshot_digest")
      dirty = dirty_snapshot.fetch("dirty_snapshot_digest")

      assert_equal WorkflowKit::Release::DirtySnapshot::DIRTY_SNAPSHOT_ALGO,
        clean_snapshot.fetch("dirty_snapshot_algo")
      assert_equal 0, clean_snapshot.fetch("entry_count")
      assert_operator dirty_snapshot.fetch("entry_count"), :>=, 2
      refute_equal clean, dirty
      assert_equal "", run!("git", "status", "--porcelain", chdir: primary).stdout
      refute_empty run!("git", "status", "--porcelain", chdir: linked).stdout

      _reviewed, applied = apply(primary, release)
      assert applied.success?, applied.combined
      run!(RbConfig.ruby, VALIDATE, primary, env: release_env(release))
      record, status_result = status(primary, release)
      assert status_result.success?, status_result.combined
      assert_equal "current", record.fetch("state")
    end
  end

  def test_isolation_fixtures_survive_lifecycle_without_cross_project_context
    with_fixture("isolation-alpha") do |alpha_fixture|
      with_fixture("isolation-beta") do |beta_fixture|
        alpha = alpha_fixture.fetch("path")
        beta = beta_fixture.fetch("path")
        alpha_release = alpha_fixture.fetch("release")
        beta_release = beta_fixture.fetch("release")
        _alpha_plan, alpha_apply = apply(alpha, alpha_release)
        assert alpha_apply.success?, alpha_apply.combined
        beta_before = git_status_digest(beta)
        beta_plan, beta_apply = apply(beta, beta_release)
        assert beta_apply.success?, beta_apply.combined
        refute_equal beta_before, git_status_digest(beta)

        [[alpha, alpha_release], [beta, beta_release]].each do |root, release|
          run!(RbConfig.ruby, VALIDATE, root, env: release_env(release))
          record, status_result = status(root, release)
          assert status_result.success?, status_result.combined
          assert_equal "current", record.fetch("state")
        end
        alpha_context = WorkflowKit::ProjectContext.build(alpha)
        beta_context = WorkflowKit::ProjectContext.build(beta)
        alpha_json = JSON.generate(alpha_context)
        beta_json = JSON.generate(beta_context)
        refute_equal alpha_context.fetch("repository_fingerprint"), beta_context.fetch("repository_fingerprint")
        refute beta_context.fetch("services").keys.any? { |name| name.start_with?("alpha") }
        assert beta_context.fetch("services").keys.any? { |name| name.start_with?("beta") }
        refute_includes beta_json, alpha
        refute_includes beta_json, "alpha_db"
        refute_includes beta_json, "/api/alpha"
        refute_includes beta_context.fetch("environment_variable_names"), "ALPHA_ONLY_VAR"
        assert_includes beta_context.fetch("environment_variable_names"), "BETA_ONLY_VAR"
        refute_equal alpha_context.fetch("memory_scope"), beta_context.fetch("memory_scope")
        assert_equal beta, beta_plan.dig("target", "worktree_path")
        refute_includes JSON.generate(beta_plan.fetch("target")), alpha
        refute alpha_context.fetch("services").keys.any? { |name| name.start_with?("beta") }
        refute_includes alpha_json, beta
        refute_includes alpha_json, "beta_db"
        refute_includes alpha_json, "/api/beta"
        refute_includes alpha_context.fetch("environment_variable_names"), "BETA_ONLY_VAR"
      end
    end
  end

  def test_one_fixture_apply_does_not_mutate_the_other_fixture
    with_fixture("isolation-alpha") do |alpha_fixture|
      with_fixture("isolation-beta") do |beta_fixture|
        alpha = alpha_fixture.fetch("path")
        beta = beta_fixture.fetch("path")
        alpha_release = alpha_fixture.fetch("release")
        beta_before = git_status_digest(beta)
        beta_files_before = working_tree_digest(beta)
        _reviewed, applied = apply(alpha, alpha_release)

        assert applied.success?, applied.combined
        assert_equal beta_before, git_status_digest(beta)
        assert_equal beta_files_before, working_tree_digest(beta)
        refute File.exist?(File.join(beta, ".ai", "KIT_INSTALLATION.yaml"))
      end
    end
  end

  def test_two_verified_releases_install_side_by_side_without_cross_mutation
    Dir.mktmpdir("workflow-kit-side-by-side-", WorkflowKitTestHelpers::FIXTURES_ROOT) do |release_parent|
      alpha_release = BUILDER.build_release(
        release_parent,
        version: "0.4.0",
        identity: "side-by-side-alpha",
      )
      beta_release = BUILDER.build_release(
        release_parent,
        version: "0.4.1",
        identity: "side-by-side-beta",
      )
      refute_equal alpha_release.fetch("digest"), beta_release.fetch("digest")
      assert_equal alpha_release.fetch("cache"), beta_release.fetch("cache")

      with_fixture("isolation-alpha") do |alpha_fixture|
        with_fixture("isolation-beta") do |beta_fixture|
          alpha = alpha_fixture.fetch("path")
          beta = beta_fixture.fetch("path")
          _alpha_plan, alpha_apply = apply_release(alpha, alpha_release)
          assert alpha_apply.success?, alpha_apply.combined
          _beta_plan, beta_apply = apply_release(beta, beta_release)
          assert beta_apply.success?, beta_apply.combined

          alpha_lock = load_yaml(File.join(alpha, ".ai", "KIT_INSTALLATION.yaml"))
          beta_lock = load_yaml(File.join(beta, ".ai", "KIT_INSTALLATION.yaml"))
          assert_equal "0.4.0", alpha_lock.fetch("kit_version")
          assert_equal "0.4.1", beta_lock.fetch("kit_version")
          assert_equal alpha_release.fetch("digest"), alpha_lock.fetch("kit_bundle_digest")
          assert_equal beta_release.fetch("digest"), beta_lock.fetch("kit_bundle_digest")
          refute_equal alpha_lock.fetch("kit_bundle_digest"), beta_lock.fetch("kit_bundle_digest")

          beta_before = git_status_digest(beta)
          beta_files_before = working_tree_digest(beta)
          _second_plan, second_apply = apply_release(alpha, alpha_release)
          assert second_apply.success?, second_apply.combined
          assert_equal beta_before, git_status_digest(beta)
          assert_equal beta_files_before, working_tree_digest(beta)

          run!(RbConfig.ruby, VALIDATE, alpha, env: release_env(alpha_release))
          run!(RbConfig.ruby, VALIDATE, beta, env: release_env(beta_release))
          alpha_status, alpha_result = release_status(alpha, alpha_release)
          beta_status, beta_result = release_status(beta, beta_release)
          assert alpha_result.success?, alpha_result.combined
          assert beta_result.success?, beta_result.combined
          assert_equal "current", alpha_status.fetch("state")
          assert_equal "current", beta_status.fetch("state")

          cache_entries = Dir.children(alpha_release.fetch("cache")).grep(/\A[0-9a-f]{64}\z/)
          assert_equal 2, cache_entries.length
          assert_includes cache_entries, alpha_release.fetch("digest").delete_prefix("sha256:")
          assert_includes cache_entries, beta_release.fetch("digest").delete_prefix("sha256:")
        end
      end
    end
  end

  def test_unknown_project_fails_closed_for_database_authentication_and_deployment
    with_fixture("unknown-project") do |fixture|
      root = fixture.fetch("path")
      release = fixture.fetch("release")
      %w[database authentication deployment].each do |operation|
        error = assert_raises(WorkflowKit::ContextError) do
          WorkflowKit::ProjectContext.build(root, operation: operation)
        end
        assert_match(/(?:refusing to infer|not approved)/, error.message)
      end

      _reviewed, applied = apply(root, release)
      assert applied.success?, applied.combined
      run!(RbConfig.ruby, VALIDATE, root, env: release_env(release))
      status_record, status_result = status(root, release)
      assert_equal 20, status_result.status.exitstatus
      assert_equal "review_required", status_record.fetch("state")
      assert status_record.fetch("sensitive_context").values.all? { |value| value["ready"] == false }

      project_map = load_yaml(File.join(root, ".ai", "canonical", "PROJECT_MAP.yaml"))
      assert_equal({}, project_map.fetch("services"))
      refute project_map.key?("database")
      refute project_map.key?("api_prefix")
    end
  end

  def test_context_negative_control_detects_a_process_global_cache
    with_fixture("isolation-alpha") do |alpha_fixture|
      with_fixture("isolation-beta") do |beta_fixture|
        alpha_context = WorkflowKit::ProjectContext.build(alpha_fixture.fetch("path"))
        contaminated_beta = alpha_context
        beta_root = File.realpath(beta_fixture.fetch("path"))

        refute_equal beta_root, contaminated_beta.fetch("root")
        assert_includes JSON.generate(contaminated_beta), "alpha_db"
        assert_includes contaminated_beta.fetch("environment_variable_names"), "ALPHA_ONLY_VAR"
      end
    end
  end

end
