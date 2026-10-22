# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "yaml"

require_relative "test_helper"
require_relative "../engine/resolver/release_cache"

class ReleaseSideBySideIntegrationTest < Minitest::Test
  ENABLE_ENV = "WORKFLOW_KIT_REAL_RELEASE_TEST"
  CACHE_ENV = "WORKFLOW_KIT_REAL_RELEASE_CACHE"
  DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze
  CACHE_KEY_PATTERN = /\A[0-9a-f]{64}\z/.freeze

  V040_BUNDLE_DIGEST = "sha256:e1af399f57bacebebedfecb60da09b51deadca162802b207d623b814f08350c5"
  V040_MANIFEST_DIGEST = "sha256:72a176e4951106d0954d22c7c9bf6bddfbe51d86d5d072430c70d92ecb5d7be2"
  V040_RELEASE_COMMIT = "8dd25d33fe8e87a77a0ff3cfaa004f2481fe135b"

  RELEASE_ENV = {
    "0.4.0" => {
      "manifest" => "WORKFLOW_KIT_RELEASE_V040_MANIFEST",
      "bundle_digest" => "WORKFLOW_KIT_RELEASE_V040_BUNDLE_DIGEST",
      "manifest_digest" => "WORKFLOW_KIT_RELEASE_V040_MANIFEST_DIGEST",
    }.freeze,
    "0.4.1" => {
      "manifest" => "WORKFLOW_KIT_RELEASE_V041_MANIFEST",
      "bundle_digest" => "WORKFLOW_KIT_RELEASE_V041_BUNDLE_DIGEST",
      "manifest_digest" => "WORKFLOW_KIT_RELEASE_V041_MANIFEST_DIGEST",
    }.freeze,
  }.freeze

  RUNNER_PATHS = {
    "bootstrap" => File.join("engine", "install", "bootstrap_project.rb"),
    "validate" => File.join("engine", "validators", "validate_install.rb"),
    "status" => File.join("engine", "install", "status.rb"),
  }.freeze

  def test_actual_v040_and_v041_releases_run_side_by_side_without_cross_mutation
    skip "set #{ENABLE_ENV}=1 to run the actual release artifact integration" unless ENV[ENABLE_ENV] == "1"

    required_environment = [CACHE_ENV] + RELEASE_ENV.values.flat_map(&:values)
    missing = required_environment.select { |name| ENV[name].to_s.empty? }
    assert_empty missing, "missing actual release test environment: #{missing.join(', ')}"

    cache_root = nil
    cache_started_empty = false
    cache_cleaned = false
    releases = []
    alpha_fixture = nil
    beta_fixture = nil

    begin
      cache_root = verified_empty_cache_root(ENV.fetch(CACHE_ENV))
      cache_started_empty = true

      releases = [verified_release("0.4.0"), verified_release("0.4.1")]
      alpha_release, beta_release = releases
      refute_equal alpha_release.fetch("bundle_digest"), beta_release.fetch("bundle_digest")
      refute_equal alpha_release.fetch("manifest_digest"), beta_release.fetch("manifest_digest")

      releases.each do |release|
        release["root"] = WorkflowKit::Release::ReleaseCache.resolve(
          release.fetch("lock"),
          cache_root: cache_root,
        )
        release["runners"] = verified_release_runners(release.fetch("root"))
      end
      assert_cache_payloads(cache_root, releases)

      alpha_fixture = WorkflowKit::FixtureBuilder.build(
        "isolation-alpha",
        parent: WorkflowKitTestHelpers::FIXTURES_ROOT,
      )
      beta_fixture = WorkflowKit::FixtureBuilder.build(
        "isolation-beta",
        parent: WorkflowKitTestHelpers::FIXTURES_ROOT,
      )
      alpha = alpha_fixture.fetch("path")
      beta = beta_fixture.fetch("path")

      apply_release(alpha, alpha_release, cache_root)
      apply_release(beta, beta_release, cache_root)

      alpha_lock = load_installation_lock(alpha)
      beta_lock = load_installation_lock(beta)
      assert_release_lock(alpha_lock, alpha_release)
      assert_release_lock(beta_lock, beta_release)

      validate_release(alpha, alpha_release, cache_root)
      validate_release(beta, beta_release, cache_root)
      assert_current_status(alpha, alpha_release, cache_root)
      assert_current_status(beta, beta_release, cache_root)

      beta_porcelain_before = git_porcelain(beta)
      beta_tree_before = repository_tree_digest(beta)
      apply_release(alpha, alpha_release, cache_root)
      assert_equal beta_porcelain_before, git_porcelain(beta), "alpha re-apply changed beta porcelain state"
      assert_equal beta_tree_before, repository_tree_digest(beta), "alpha re-apply changed beta file tree"

      assert_release_lock(load_installation_lock(alpha), alpha_release)
      assert_release_lock(load_installation_lock(beta), beta_release)
      validate_release(alpha, alpha_release, cache_root)
      validate_release(beta, beta_release, cache_root)
      assert_current_status(alpha, alpha_release, cache_root)
      assert_current_status(beta, beta_release, cache_root)
      assert_cache_payloads(cache_root, releases)

      alpha_container = alpha_fixture.fetch("container")
      beta_container = beta_fixture.fetch("container")
      WorkflowKit::FixtureBuilder.cleanup(alpha_fixture)
      WorkflowKit::FixtureBuilder.cleanup(beta_fixture)
      alpha_fixture = nil
      beta_fixture = nil
      refute File.exist?(alpha_container), "alpha fixture cleanup did not remove its container"
      refute File.exist?(beta_container), "beta fixture cleanup did not remove its container"

      cleanup_release_cache(cache_root, releases)
      cache_cleaned = true
      assert_empty Dir.children(cache_root), "actual release test cache was not cleaned"
    ensure
      WorkflowKit::FixtureBuilder.cleanup(alpha_fixture) if alpha_fixture
      WorkflowKit::FixtureBuilder.cleanup(beta_fixture) if beta_fixture
      cleanup_release_cache(cache_root, releases) if cache_started_empty && !cache_cleaned
    end
  end

  private

  def verified_empty_cache_root(requested)
    expanded = File.expand_path(requested)
    refute File.symlink?(expanded), "actual release cache root must not be a symbolic link"
    assert File.directory?(expanded), "actual release cache root must already be a directory: #{expanded}"

    resolved = File.realpath(expanded)
    assert_equal expanded, resolved, "actual release cache root must be a direct, normalized path"
    assert_equal 0, File.stat(resolved).mode & 0o077, "actual release cache root must not be group/world accessible"
    assert_empty Dir.children(resolved), "actual release cache root must start empty"
    resolved
  end

  def verified_release(version)
    variables = RELEASE_ENV.fetch(version)
    manifest_path = File.expand_path(ENV.fetch(variables.fetch("manifest")))
    bundle_digest = ENV.fetch(variables.fetch("bundle_digest"))
    manifest_digest = ENV.fetch(variables.fetch("manifest_digest"))
    release_ref = "refs/tags/v#{version}"

    assert_match DIGEST_PATTERN, bundle_digest, "invalid independently reviewed bundle digest for v#{version}"
    assert_match DIGEST_PATTERN, manifest_digest, "invalid independently reviewed manifest digest for v#{version}"
    refute File.symlink?(manifest_path), "release manifest must not be a symbolic link: #{manifest_path}"
    assert File.file?(manifest_path), "release manifest is not a regular file: #{manifest_path}"
    assert_equal manifest_digest, "sha256:#{Digest::SHA256.file(manifest_path).hexdigest}",
      "v#{version} sidecar bytes do not match the independently reviewed digest"

    manifest = JSON.parse(File.binread(manifest_path))
    assert_equal version, manifest.fetch("kit_version")
    assert_equal release_ref, manifest.fetch("release_ref")
    assert_equal "candidate", manifest.fetch("channel")
    assert_equal true, manifest.fetch("pinnable")
    assert_equal 4, manifest.fetch("dirty_snapshot_algo")
    assert_equal bundle_digest, manifest.fetch("kit_bundle_digest")
    assert_equal true, manifest.dig("provenance", "source_clean")
    assert_equal true, manifest.dig("provenance", "source_tagged")
    assert_includes [nil, false], manifest.dig("provenance", "synthetic_fixture"),
      "v#{version} sidecar identifies a synthetic fixture, not an actual release"

    source = manifest.fetch("source")
    assert source.is_a?(Hash), "v#{version} release source must be a mapping"
    assert_equal "local", source.fetch("kind"), "v#{version} actual release test must remain local-only"
    assert_match DIGEST_PATTERN, source.fetch("bundle_archive_sha256")
    %w[locator manifest_locator].each do |field|
      assert_match(/\Afile:\/\//, source.fetch(field), "v#{version} source.#{field} must be local-only")
    end

    tag_type = run!("git", "cat-file", "-t", release_ref, chdir: KIT_ROOT).stdout.strip
    assert_equal "tag", tag_type, "#{release_ref} must be an annotated tag"
    tag_commit = run!("git", "rev-parse", "#{release_ref}^{commit}", chdir: KIT_ROOT).stdout.strip
    assert_match(/\A[0-9a-f]{40,64}\z/, tag_commit)
    assert_equal tag_commit, manifest.fetch("release_commit"),
      "v#{version} sidecar commit does not match its annotated tag"
    tag_bundle_digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest(KIT_ROOT, release_ref)}"
    assert_equal tag_bundle_digest, bundle_digest,
      "v#{version} reviewed bundle digest does not match the annotated tag tree"

    if version == "0.4.0"
      assert_equal V040_BUNDLE_DIGEST, bundle_digest
      assert_equal V040_MANIFEST_DIGEST, manifest_digest
      assert_equal V040_RELEASE_COMMIT, tag_commit
    end

    {
      "version" => version,
      "ref" => release_ref,
      "commit" => tag_commit,
      "manifest_path" => manifest_path,
      "bundle_digest" => bundle_digest,
      "manifest_digest" => manifest_digest,
      "lock" => {
        "kit_bundle_digest" => bundle_digest,
        "release_manifest_digest" => manifest_digest,
        "source" => source,
      },
    }
  rescue JSON::ParserError, KeyError => error
    flunk "invalid v#{version} actual release sidecar: #{error.message}"
  end

  def verified_release_runners(release_root)
    resolved_root = File.realpath(release_root)
    RUNNER_PATHS.each_with_object({}) do |(name, relative), result|
      path = File.join(resolved_root, relative)
      refute File.symlink?(path), "cached release runner must not be a symbolic link: #{relative}"
      assert File.file?(path), "cached release runner is missing: #{relative}"
      assert File.realpath(path).start_with?("#{resolved_root}/"), "cached release runner escaped its release root"
      result[name] = path
    end
  end

  def source_options(release)
    [
      "--source-manifest", release.fetch("manifest_path"),
      "--expected-kit-bundle-digest", release.fetch("bundle_digest"),
      "--expected-release-manifest-digest", release.fetch("manifest_digest"),
    ]
  end

  def release_environment(cache_root)
    { "KIT_RELEASE_CACHE" => cache_root }
  end

  def apply_release(project, release, cache_root)
    bootstrap = release.fetch("runners").fetch("bootstrap")
    options = source_options(release)
    environment = release_environment(cache_root)
    plan = run_command(
      RbConfig.ruby,
      bootstrap,
      "--dry-run",
      "--json",
      *options,
      project,
      env: environment,
    )
    assert plan.success?, "v#{release.fetch('version')} cached bootstrap plan failed:\n#{plan.combined}"
    plan_payload = JSON.parse(plan.stdout)
    assert_match(/\Asha256:[0-9a-f]{64}\z/, plan_payload.fetch("plan_digest"))
    assert_equal release.fetch("bundle_digest"), plan_payload.dig("source", "kit_bundle_digest")
    assert_equal release.fetch("manifest_digest"), plan_payload.dig("source", "release_manifest_digest")

    applied = run_command(
      RbConfig.ruby,
      bootstrap,
      "--json",
      *options,
      "--plan-digest",
      plan_payload.fetch("plan_digest"),
      project,
      env: environment,
    )
    assert applied.success?, "v#{release.fetch('version')} cached bootstrap apply failed:\n#{applied.combined}"
    JSON.parse(applied.stdout)
  rescue JSON::ParserError, KeyError => error
    flunk "v#{release.fetch('version')} cached bootstrap returned invalid JSON: #{error.message}"
  end

  def validate_release(project, release, cache_root)
    result = run_command(
      RbConfig.ruby,
      release.fetch("runners").fetch("validate"),
      project,
      env: release_environment(cache_root),
    )
    assert result.success?, "v#{release.fetch('version')} cached validator failed:\n#{result.combined}"
  end

  def assert_current_status(project, release, cache_root)
    result = run_command(
      RbConfig.ruby,
      release.fetch("runners").fetch("status"),
      "--json",
      *source_options(release),
      project,
      env: release_environment(cache_root),
    )
    assert result.success?, "v#{release.fetch('version')} cached status failed:\n#{result.combined}"
    payload = JSON.parse(result.stdout)
    assert_equal "current", payload.fetch("state")
    assert_equal 0, payload.fetch("exit_code")
    assert_equal release.fetch("version"), payload.dig("source", "kit_version")
    assert_equal release.fetch("bundle_digest"), payload.dig("source", "kit_bundle_digest")
    assert_equal release.fetch("manifest_digest"), payload.dig("source", "release_manifest_digest")
    assert_equal release.fetch("ref"), payload.dig("source", "release_ref")
    assert_equal release.fetch("commit"), payload.dig("source", "release_commit")
  rescue JSON::ParserError, KeyError => error
    flunk "v#{release.fetch('version')} cached status returned invalid JSON: #{error.message}"
  end

  def load_installation_lock(project)
    path = File.join(project, ".ai", "KIT_INSTALLATION.yaml")
    assert File.file?(path), "installation lock is missing: #{path}"
    YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue ArgumentError
    YAML.safe_load(File.read(path), [], [], false)
  end

  def assert_release_lock(lock, release)
    assert_equal "managed", lock.fetch("installation_state")
    assert_equal release.fetch("version"), lock.fetch("kit_version")
    assert_equal release.fetch("bundle_digest"), lock.fetch("kit_bundle_digest")
    assert_equal release.fetch("manifest_digest"), lock.fetch("release_manifest_digest")
    assert_equal release.fetch("ref"), lock.dig("provenance", "release_ref")
    assert_equal release.fetch("commit"), lock.dig("provenance", "release_commit")
    assert_includes [nil, false], lock.dig("provenance", "synthetic_fixture")
  end

  def git_porcelain(project)
    run!(
      "git",
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      chdir: project,
    ).stdout
  end

  def repository_tree_digest(project)
    paths = run!(
      "git",
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
      "-z",
      chdir: project,
    ).stdout.split("\0").reject(&:empty?).sort

    material = paths.map do |relative|
      absolute = File.join(project, relative)
      stat = File.lstat(absolute)
      content = if stat.symlink?
        "link\0#{File.readlink(absolute)}"
      elsif stat.file?
        "file\0#{Digest::SHA256.file(absolute).hexdigest}"
      else
        "#{stat.ftype}\0"
      end
      "#{relative}\0#{format('%04o', stat.mode & 0o7777)}\0#{content}\0"
    end.join
    Digest::SHA256.hexdigest(material)
  end

  def assert_cache_payloads(cache_root, releases)
    expected = releases.map { |release| release.fetch("bundle_digest").delete_prefix("sha256:") }.sort
    actual = Dir.children(cache_root).select do |entry|
      entry.match?(CACHE_KEY_PATTERN) && File.directory?(File.join(cache_root, entry))
    end.sort
    assert_equal expected, actual, "isolated cache must contain exactly the two reviewed release payloads"
  end

  def cleanup_release_cache(cache_root, releases)
    return unless cache_root && File.directory?(cache_root) && !File.symlink?(cache_root)

    releases.each do |release|
      digest_key = release["bundle_digest"].to_s.delete_prefix("sha256:")
      next unless digest_key.match?(CACHE_KEY_PATTERN)

      payload = File.join(cache_root, digest_key)
      if File.directory?(payload) && !File.symlink?(payload)
        FileUtils.remove_entry(payload)
      elsif File.exist?(payload) || File.symlink?(payload)
        FileUtils.rm_f(payload)
      end
      FileUtils.rm_f(File.join(cache_root, ".lock-#{digest_key}"))
      FileUtils.rm_f(File.join(cache_root, ".metadata", "#{digest_key}.json"))
    end

    metadata = File.join(cache_root, ".metadata")
    Dir.rmdir(metadata) if File.directory?(metadata) && !File.symlink?(metadata) && Dir.empty?(metadata)
  end
end
