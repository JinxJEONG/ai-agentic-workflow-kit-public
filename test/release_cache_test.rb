# frozen_string_literal: true

require "json"
require_relative "test_helper"
require_relative "../engine/resolver/release_cache"

class ReleaseCacheTest < Minitest::Test
  def build_archive(directory, source)
    archive = File.join(directory, "release.tar.gz")
    staging = File.join(directory, "staging")
    FileUtils.mkdir_p(staging)
    FileUtils.cp_r(source, File.join(staging, "package"))
    result = run_command("tar", "-czf", archive, "-C", staging, "package")
    raise result.combined unless result.success?
    archive
  end

  def release_inputs(directory)
    source = File.join(directory, "source")
    FileUtils.mkdir_p(source)
    write_file(File.join(source, "VERSION"), "0.4.0\n")
    archive = build_archive(directory, source)
    digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.digest_from_directory(source, excludes: WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES)}"
    manifest = {
      "kit_version" => "0.4.0",
      "release_commit" => "a" * 40,
      "pinnable" => true,
      "kit_bundle_digest" => digest,
      "excluded_paths" => WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES,
    }
    manifest_path = File.join(directory, "release.manifest.json")
    write_file(manifest_path, JSON.pretty_generate(manifest))
    lock = {
      "kit_bundle_digest" => digest,
      "release_manifest_digest" => "sha256:#{Digest::SHA256.file(manifest_path).hexdigest}",
      "source" => {
        "locator" => "file://#{archive}",
        "manifest_locator" => "file://#{manifest_path}",
        "bundle_archive_sha256" => "sha256:#{Digest::SHA256.file(archive).hexdigest}",
      },
    }
    [lock, manifest_path]
  end

  def test_verified_release_is_cached_by_digest
    Dir.mktmpdir("release-cache-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      path = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      assert_equal lock["kit_bundle_digest"].delete_prefix("sha256:"), File.basename(path)
      marker = File.join(cache, ".metadata", "#{File.basename(path)}.json")
      assert File.file?(marker)
      refute File.exist?(File.join(path, ".complete.json"))
      assert_equal path, WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
    end
  end

  def test_manifest_and_archive_tampering_is_rejected_against_lock
    Dir.mktmpdir("release-cache-test") do |directory|
      lock, manifest_path = release_inputs(directory)
      manifest = JSON.parse(File.read(manifest_path))
      manifest["kit_bundle_digest"] = "sha256:#{'f' * 64}"
      write_file(manifest_path, JSON.pretty_generate(manifest))
      assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: File.join(directory, "cache"))
      end
    end
  end

  def test_policy_only_manifest_tampering_is_rejected_against_the_manifest_trust_root
    Dir.mktmpdir("release-cache-policy-tamper-test") do |directory|
      lock, manifest_path = release_inputs(directory)
      manifest = JSON.parse(File.read(manifest_path))
      manifest["ownership_rules"] = [{ "glob" => "**", "ownership" => "project-owned" }]
      write_file(manifest_path, JSON.pretty_generate(manifest))

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: File.join(directory, "cache"))
      end
      assert_match(/manifest checksum mismatch/, error.message)
    end
  end

  def test_policy_only_manifest_tampering_is_rejected_on_a_cache_hit
    Dir.mktmpdir("release-cache-policy-hit-test") do |directory|
      lock, manifest_path = release_inputs(directory)
      cache = File.join(directory, "cache")
      WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      manifest = JSON.parse(File.read(manifest_path))
      manifest["protected_paths"] = []
      write_file(manifest_path, JSON.pretty_generate(manifest))

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      end
      assert_match(/manifest checksum mismatch/, error.message)
    end
  end

  def test_manifest_digest_is_required_by_the_resolver
    Dir.mktmpdir("release-cache-trust-root-test") do |directory|
      lock, = release_inputs(directory)
      lock.delete("release_manifest_digest")

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: File.join(directory, "cache"))
      end
      assert_match(/release_manifest_digest/, error.message)
    end
  end

  def test_non_pinnable_release_is_rejected
    Dir.mktmpdir("release-cache-test") do |directory|
      lock, manifest_path = release_inputs(directory)
      manifest = JSON.parse(File.read(manifest_path))
      manifest["pinnable"] = false
      write_file(manifest_path, JSON.pretty_generate(manifest))
      assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: File.join(directory, "cache"))
      end
    end
  end

  def test_archive_links_are_rejected_before_extraction
    Dir.mktmpdir("release-cache-link-test") do |directory|
      staging = File.join(directory, "staging", "package")
      FileUtils.mkdir_p(staging)
      write_file(File.join(staging, "VERSION"), "0.4.0\n")
      File.symlink("VERSION", File.join(staging, "version-link"))
      archive = File.join(directory, "linked.tar.gz")
      run!("tar", "-czf", archive, "-C", File.join(directory, "staging"), "package")

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.safe_archive_entries!(archive)
      end
      assert_match(/non-regular entry/, error.message)
    end
  end

  def test_tampered_cached_content_is_rejected
    Dir.mktmpdir("release-cache-tamper-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      path = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      write_file(File.join(path, "VERSION"), "tampered\n")

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      end
      assert_match(/cached release contents/, error.message)
    end
  end

  def test_percent_encoded_file_locators_support_spaces
    Dir.mktmpdir("release cache space test") do |directory|
      lock, = release_inputs(directory)
      lock.fetch("source").transform_values! do |value|
        value.is_a?(String) && value.start_with?("file://") ? value.gsub(" ", "%20") : value
      end
      path = WorkflowKit::Release::ReleaseCache.resolve(
        lock,
        cache_root: File.join(directory, "cache with space"),
      )
      assert File.directory?(path)
    end
  end

  def test_metadata_symlink_is_rejected
    Dir.mktmpdir("release-cache-symlink-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      outside = File.join(directory, "outside")
      FileUtils.mkdir_p(cache)
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(cache, ".metadata"))

      error = assert_raises(WorkflowKit::Release::ResolutionError) do
        WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      end
      assert_match(/metadata.*symbolic link/, error.message)
    end
  end

  def test_parallel_resolvers_publish_one_complete_entry
    Dir.mktmpdir("release-cache-race-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      results = 2.times.map do
        Thread.new { WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache) }
      end.map(&:value)

      assert_equal 1, results.uniq.length
      assert File.file?(File.join(cache, ".metadata", "#{File.basename(results.first)}.json"))
    end
  end

  def test_marker_only_crash_state_is_recovered_under_the_digest_lock
    Dir.mktmpdir("release-cache-marker-crash-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      path = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      marker = File.join(cache, ".metadata", "#{File.basename(path)}.json")
      FileUtils.rm_rf(path)

      recovered = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)

      assert_equal path, recovered
      assert File.directory?(recovered)
      assert File.file?(marker)
    end
  end

  def test_payload_only_crash_state_is_recovered_under_the_digest_lock
    Dir.mktmpdir("release-cache-payload-crash-test") do |directory|
      lock, = release_inputs(directory)
      cache = File.join(directory, "cache")
      path = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)
      marker = File.join(cache, ".metadata", "#{File.basename(path)}.json")
      FileUtils.rm_f(marker)

      recovered = WorkflowKit::Release::ReleaseCache.resolve(lock, cache_root: cache)

      assert_equal path, recovered
      assert File.directory?(recovered)
      assert File.file?(marker)
    end
  end
end
