# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/release/release_manifest"

class ReleaseManifestTest < Minitest::Test
  ReleaseManifest = WorkflowKit::Release::ReleaseManifest

  def refresh_completion_marker(repository, output, paths, version: "0.4.0")
    builder = ReleaseManifest::Builder.new(repository: repository, output_dir: output)
    payload = builder.send(:completion_payload, paths, version)
    File.write(
      File.join(output, ".ai-agentic-workflow-kit-#{version}.complete.json"),
      "#{JSON.pretty_generate(payload)}\n",
    )
  end

  def rewrite_manifest(repository, output, result, version:)
    manifest_path = result.dig("paths", "manifest")
    manifest = JSON.parse(File.binread(manifest_path))
    yield manifest
    File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
    refresh_completion_marker(repository, output, result.fetch("paths"), version: version)
    manifest
  end

  def with_tagged_repository(version:, tag:)
    with_project(prefix: "release-manifest-test") do |repository|
      write_file(File.join(repository, "VERSION"), "#{version}\n")
      write_file(File.join(repository, "engine", "release", "engine.rb"), "engine\n")
      write_file(File.join(repository, "core", "project-template", "AGENTS.md"), "template\n")
      write_file(File.join(repository, "test", "release_test.rb"), "test\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "release", chdir: repository)
      run!("git", "tag", "-a", tag, "-m", tag, chdir: repository)
      yield repository
    end
  end

  def test_build_and_verify_create_three_sidecar_artifacts
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("release-artifacts") do |output|
        result = ReleaseManifest.build_release(
          repository: repository,
          ref: "v0.4.0",
          output_dir: output,
          channel: "candidate",
        )
        paths = result.fetch("paths")
        assert_equal %w[archive checksum manifest], paths.keys.sort
        assert paths.values.all? { |path| File.file?(path) }

        manifest = result.fetch("manifest")
        assert_equal "candidate", manifest.fetch("channel")
        assert_equal true, manifest.fetch("pinnable")
        assert_equal "refs/tags/v0.4.0", manifest.fetch("release_ref")
        assert_equal 4, manifest.fetch("dirty_snapshot_algo")
        assert_equal WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES,
          manifest.fetch("excluded_paths")
        assert_equal %w[engine_digest template_tree_digest test_tree_digest],
          manifest.fetch("auxiliary_digests").keys.sort

        verified = ReleaseManifest.verify_release(
          repository: repository,
          ref: "v0.4.0",
          output_dir: output,
        )
        assert_equal manifest.fetch("kit_bundle_digest"), verified.fetch("kit_bundle_digest")
      end
    end
  end

  def test_two_builds_from_the_same_tag_have_identical_identity
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("release-one") do |one|
        Dir.mktmpdir("release-two") do |two|
          first = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: one)
          write_file(File.join(repository, "dirty.txt"), "working tree does not define the release\n")
          second = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: two)

          assert_equal first.dig("manifest", "kit_bundle_digest"),
            second.dig("manifest", "kit_bundle_digest")
          assert_equal first.dig("manifest", "auxiliary_digests"),
            second.dig("manifest", "auxiliary_digests")
          assert_equal Digest::SHA256.file(first.dig("paths", "archive")).hexdigest,
            Digest::SHA256.file(second.dig("paths", "archive")).hexdigest
        end
      end
    end
  end

  def test_public_manifests_are_portable_and_do_not_disclose_build_paths
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("private-builder-one") do |one|
        Dir.mktmpdir("private-builder-two") do |two|
          results = [one, two].map do |output|
            ReleaseManifest.build_release(
              repository: repository,
              ref: "v0.4.0",
              output_dir: output,
              public_repository: "example/workflow-kit",
            )
          end

          first, second = results.map { |result| File.binread(result.dig("paths", "manifest")) }
          assert_equal first, second
          [repository, one, two].each { |path| refute_includes first, path }
          refute_includes first, "file://"
          source = JSON.parse(first).fetch("source")
          assert_equal "github-release", source.fetch("kind")
          assert_equal "https://github.com/example/workflow-kit/releases/download/v0.4.0/ai-agentic-workflow-kit-0.4.0.tar.gz",
            source.fetch("locator")
          assert_equal "https://github.com/example/workflow-kit/releases/download/v0.4.0/ai-agentic-workflow-kit-0.4.0.manifest.json",
            source.fetch("manifest_locator")
          verified = ReleaseManifest.verify_release(repository: repository, ref: "v0.4.0", output_dir: one)
          assert_equal results.first.dig("manifest", "kit_bundle_digest"), verified.fetch("kit_bundle_digest")
        end
      end
    end
  end

  def test_public_repository_rejects_credentials_queries_and_path_traversal
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      ["https://github.com/example/kit", "user:password/kit", "example/../kit", "example/..", "example/kit?token=sample"].each do |invalid|
        Dir.mktmpdir("invalid-public-release") do |output|
          assert_raises(ReleaseManifest::ManifestError) do
            ReleaseManifest.build_release(
              repository: repository, ref: "v0.4.0", output_dir: output,
              public_repository: invalid,
            )
          end
          assert_empty Dir.children(output)
        end
      end
    end
  end

  def test_bootstrap_tag_is_never_pinnable
    with_tagged_repository(version: "0.3.0", tag: "baseline/pre-integrity-20260813") do |repository|
      Dir.mktmpdir("bootstrap-release") do |output|
        result = ReleaseManifest.build_release(
          repository: repository,
          ref: "baseline/pre-integrity-20260813",
          output_dir: output,
        )
        manifest = result.fetch("manifest")

        assert_equal "bootstrap", manifest.fetch("channel")
        assert_equal false, manifest.fetch("pinnable")
      end
    end
  end

  def test_verify_accepts_legacy_dirty_snapshot_algo_for_non_pinnable_bootstrap_baseline
    with_tagged_repository(version: "0.3.0", tag: "baseline/pre-integrity-20260813") do |repository|
      Dir.mktmpdir("legacy-bootstrap-release") do |output|
        result = ReleaseManifest.build_release(
          repository: repository,
          ref: "baseline/pre-integrity-20260813",
          output_dir: output,
        )
        rewrite_manifest(repository, output, result, version: "0.3.0") do |manifest|
          manifest["dirty_snapshot_algo"] = 3
        end

        verified = ReleaseManifest.verify_release(
          repository: repository,
          ref: "baseline/pre-integrity-20260813",
          output_dir: output,
        )

        assert_equal "bootstrap", verified.fetch("channel")
        assert_equal false, verified.fetch("pinnable")
        assert_equal 3, verified.fetch("dirty_snapshot_algo")
      end
    end
  end

  def test_verify_rejects_legacy_dirty_snapshot_algo_for_pinnable_version_release
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("legacy-pinnable-release") do |output|
        result = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        rewrite_manifest(repository, output, result, version: "0.4.0") do |manifest|
          manifest["dirty_snapshot_algo"] = 3
        end

        error = assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.verify_release(repository: repository, ref: "v0.4.0", output_dir: output)
        end
        assert_match(/only allowed for baseline-tag bootstrap non-pinnable artifacts/, error.message)
      end
    end
  end

  def test_verify_rejects_unsupported_dirty_snapshot_algorithms
    with_tagged_repository(version: "0.3.0", tag: "baseline/pre-integrity-20260813") do |repository|
      Dir.mktmpdir("unsupported-snapshot-release") do |output|
        result = ReleaseManifest.build_release(
          repository: repository,
          ref: "baseline/pre-integrity-20260813",
          output_dir: output,
        )

        [2, 5, "3", nil].each do |unsupported|
          rewrite_manifest(repository, output, result, version: "0.3.0") do |manifest|
            manifest["dirty_snapshot_algo"] = unsupported
          end

          error = assert_raises(ReleaseManifest::ManifestError) do
            ReleaseManifest.verify_release(
              repository: repository,
              ref: "baseline/pre-integrity-20260813",
              output_dir: output,
            )
          end
          assert_match(/dirty_snapshot_algo mismatch/, error.message)
        end
      end
    end
  end

  def test_release_tag_must_match_version_and_be_annotated
    with_tagged_repository(version: "0.4.0", tag: "v0.4.1") do |repository|
      Dir.mktmpdir("wrong-version-release") do |output|
        assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.build_release(repository: repository, ref: "v0.4.1", output_dir: output)
        end
      end
    end

    with_project(prefix: "lightweight-release") do |repository|
      write_file(File.join(repository, "VERSION"), "0.4.0\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "release", chdir: repository)
      run!("git", "tag", "v0.4.0", chdir: repository)
      Dir.mktmpdir("lightweight-output") do |output|
        assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        end
      end
    end
  end

  def test_refusal_leaves_no_partial_artifacts
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      File.symlink("VERSION", File.join(repository, "version-link"))
      run!("git", "add", "version-link", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "symlink", chdir: repository)
      run!("git", "tag", "-a", "v0.4.1", "-m", "bad", chdir: repository)
      # Match the tag name so refusal, not the version guard, is exercised.
      run!("git", "tag", "-d", "v0.4.1", chdir: repository)
      write_file(File.join(repository, "VERSION"), "0.4.1\n")
      run!("git", "add", "VERSION", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "version", chdir: repository)
      run!("git", "tag", "-a", "v0.4.1", "-m", "bad", chdir: repository)

      Dir.mktmpdir("refused-release") do |output|
        error = assert_raises(WorkflowKit::Release::ReleaseDigest::RefusedEntry) do
          ReleaseManifest.build_release(repository: repository, ref: "v0.4.1", output_dir: output)
        end
        assert_match(/120000/, error.message)
        assert_empty Dir.children(output)
      end
    end
  end

  def test_output_directory_inside_repository_is_rejected
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      assert_raises(ReleaseManifest::ManifestError) do
        ReleaseManifest.build_release(
          repository: repository,
          ref: "v0.4.0",
          output_dir: File.join(repository, "dist"),
        )
      end
    end
  end

  def test_verify_rejects_archive_tampering
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("tampered-release") do |output|
        result = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        File.open(result.dig("paths", "archive"), "ab") { |file| file.write("tamper") }

        assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.verify_release(repository: repository, ref: "v0.4.0", output_dir: output)
        end
      end
    end
  end

  def test_verify_refuses_links_before_extracting_a_self_consistent_archive
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("linked-release") do |output|
        result = ReleaseManifest.build_release(
          repository: repository,
          ref: "v0.4.0",
          output_dir: output,
        )
        paths = result.fetch("paths")
        Dir.mktmpdir("linked-release-source") do |source|
          package = File.join(source, "ai-agentic-workflow-kit-0.4.0")
          FileUtils.mkdir_p(package)
          File.symlink("VERSION", File.join(package, "unsafe-link"))
          run!("tar", "-czf", paths.fetch("archive"), "-C", source, File.basename(package))
        end

        archive_sha = Digest::SHA256.file(paths.fetch("archive")).hexdigest
        File.write(
          paths.fetch("checksum"),
          "#{archive_sha}  #{File.basename(paths.fetch('archive'))}\n",
        )
        manifest = JSON.parse(File.read(paths.fetch("manifest")))
        manifest.fetch("source")["bundle_archive_sha256"] = "sha256:#{archive_sha}"
        File.write(paths.fetch("manifest"), "#{JSON.pretty_generate(manifest)}\n")
        refresh_completion_marker(repository, output, paths)

        error = assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.verify_release(
            repository: repository,
            ref: "v0.4.0",
            output_dir: output,
          )
        end
        assert_match(/non-regular entry/, error.message)
      end
    end
  end

  def test_verify_rejects_a_self_consistent_manifest_and_archive_from_another_tree
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("wrong-tree-release") do |output|
        result = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        manifest_path = result.dig("paths", "manifest")
        manifest = JSON.parse(File.binread(manifest_path))
        manifest["kit_bundle_digest"] = "sha256:#{'a' * 64}"
        File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
        refresh_completion_marker(repository, output, result.fetch("paths"))

        error = assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.verify_release(repository: repository, ref: "v0.4.0", output_dir: output)
        end
        assert_match(/does not identify/, error.message)
      end
    end
  end

  def test_verify_requires_the_last_published_completion_marker
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("incomplete-release") do |output|
        ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        FileUtils.rm_f(File.join(output, ".ai-agentic-workflow-kit-0.4.0.complete.json"))

        error = assert_raises(ReleaseManifest::ManifestError) do
          ReleaseManifest.verify_release(repository: repository, ref: "v0.4.0", output_dir: output)
        end
        assert_match(/completion marker/, error.message)
      end
    end
  end

  def test_a_partial_publish_can_be_rebuilt_into_one_complete_set
    with_tagged_repository(version: "0.4.0", tag: "v0.4.0") do |repository|
      Dir.mktmpdir("recover-release") do |output|
        first = ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        FileUtils.rm_f(File.join(output, ".ai-agentic-workflow-kit-0.4.0.complete.json"))
        FileUtils.rm_f(first.dig("paths", "checksum"))

        ReleaseManifest.build_release(repository: repository, ref: "v0.4.0", output_dir: output)
        verified = ReleaseManifest.verify_release(
          repository: repository,
          ref: "v0.4.0",
          output_dir: output,
        )

        assert_equal "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest(repository, 'refs/tags/v0.4.0')}",
          verified.fetch("kit_bundle_digest")
      end
    end
  end
end
