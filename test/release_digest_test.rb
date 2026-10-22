# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/release/release_digest"

class ReleaseDigestTest < Minitest::Test
  DigestModule = WorkflowKit::Release::ReleaseDigest

  def with_release_repository
    with_project(prefix: "release-digest-test") do |repository|
      yield repository
    end
  end

  def commit_file(repository, path, content, executable: false)
    write_file(File.join(repository, path), content)
    File.chmod(executable ? 0o755 : 0o644, File.join(repository, path))
    run!("git", "add", path, chdir: repository)
    run!("git", "commit", "--no-verify", "-m", "add #{path.inspect}", chdir: repository)
  end

  def test_same_ref_is_deterministic_and_ignores_worktree_changes
    with_release_repository do |repository|
      commit_file(repository, "lib/value.txt", "committed\n")
      first = DigestModule.kit_bundle_digest(repository, "HEAD")
      second = DigestModule.kit_bundle_digest(repository, "HEAD")
      write_file(File.join(repository, "lib/value.txt"), "dirty\n")
      write_file(File.join(repository, "untracked.txt"), "ignored by ref identity\n")

      assert_equal first, second
      assert_equal first, DigestModule.kit_bundle_digest(repository, "HEAD")
    end
  end

  def test_same_ref_in_a_clone_has_the_same_digest
    with_release_repository do |repository|
      commit_file(repository, "경로 with space.txt", "content\n")
      expected = DigestModule.kit_bundle_digest(repository, "HEAD")
      Dir.mktmpdir("release-digest-clone") do |parent|
        clone = File.join(parent, "clone")
        run!("git", "clone", "--quiet", repository, clone)
        assert_equal expected, DigestModule.kit_bundle_digest(clone, "HEAD")
      end
    end
  end

  def test_symlink_is_refused_without_a_partial_cli_digest
    with_release_repository do |repository|
      commit_file(repository, "target.txt", "target\n")
      File.symlink("target.txt", File.join(repository, "link.txt"))
      run!("git", "add", "link.txt", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "add symlink", chdir: repository)

      result = run_command(
        RbConfig.ruby,
        File.join(KIT_ROOT, "engine", "release", "release_digest.rb"),
        "--repo", repository,
        "--ref", "HEAD",
      )

      assert_equal DigestModule::EXIT_REFUSED, result.status.exitstatus
      assert_empty result.stdout
      assert_match(/REFUSED.*120000/m, result.stderr)
    end
  end

  def test_submodule_is_refused
    with_release_repository do |repository|
      commit_file(repository, "regular.txt", "regular\n")
      oid = run!("git", "rev-parse", "HEAD", chdir: repository).stdout.strip
      run!("git", "update-index", "--add", "--cacheinfo", "160000,#{oid},nested-kit", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "add gitlink", chdir: repository)

      error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest(repository, "HEAD")
      end
      assert_match(/160000/, error.message)
    end
  end

  def test_rows_are_sorted_by_path_bytes_not_content_digest
    with_release_repository do |repository|
      write_file(File.join(repository, "a.txt"), "first\n")
      write_file(File.join(repository, "z.txt"), "second\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "two files", chdir: repository)

      entries = DigestModule.tree_entries(repository, "HEAD")
      rows = entries.map do |entry|
        content = run!("git", "cat-file", "blob", entry.fetch(:oid), chdir: repository).stdout
        path = entry.fetch(:path)
        [path, Digest::SHA256.hexdigest(content), entry.fetch(:mode)]
      end
      expected = DigestModule.digest_rows(rows)
      row_sorted = DigestModule.digest_rows(rows.reverse)

      assert_equal expected, DigestModule.kit_bundle_digest(repository, "HEAD")
      assert_equal row_sorted, expected, "input order must not affect path-byte sorting"
    end
  end

  def test_newline_path_is_nul_safe
    with_release_repository do |repository|
      path = "line\nbreak.txt"
      commit_file(repository, path, "content\n")

      digest = DigestModule.kit_bundle_digest(repository, "HEAD")
      assert_match(/\A[0-9a-f]{64}\z/, digest)
      assert_equal digest, DigestModule.kit_bundle_digest(repository, "HEAD")
    end
  end

  def test_length_prefix_framing_prevents_newline_path_row_injection
    content_a = Digest::SHA256.hexdigest("A")
    content_b = Digest::SHA256.hexdigest("B")
    injected = "a\n#{content_b} 100644 b".b
    one_file = [[injected, content_a, "100644"]]
    two_files = [["a".b, content_a, "100644"], ["b".b, content_b, "100644"]]

    refute_equal DigestModule.digest_rows(one_file), DigestModule.digest_rows(two_files)
  end

  def test_default_exclusions_ignore_contents_and_policy_rejects_a_changed_list
    with_release_repository do |repository|
      write_file(File.join(repository, "lib.rb"), "main\n")
      write_file(File.join(repository, "test", "ignored.rb"), "one\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "baseline", chdir: repository)
      first = DigestModule.kit_bundle_digest(repository, "HEAD")

      write_file(File.join(repository, "test", "ignored.rb"), "two\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "test only", chdir: repository)
      assert_equal first, DigestModule.kit_bundle_digest(repository, "HEAD")

      assert_raises(DigestModule::DigestError) do
        DigestModule.kit_bundle_digest(repository, "HEAD", excludes: ["test/**"])
      end
    end
  end

  def test_directory_round_trip_matches_git_tree_and_ignores_dot_git
    with_release_repository do |repository|
      write_file(File.join(repository, "script.sh"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(repository, "script.sh"))
      write_file(File.join(repository, "test", "excluded.txt"), "excluded\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "archive", chdir: repository)
      expected = DigestModule.kit_bundle_digest(repository, "HEAD")

      Dir.mktmpdir("release-digest-archive") do |directory|
        archive = File.join(directory, "tree.tar")
        run!("git", "archive", "--format=tar", "-o", archive, "HEAD", chdir: repository)
        extracted = File.join(directory, "tree")
        FileUtils.mkdir_p(extracted)
        run!("tar", "-xf", archive, "-C", extracted)
        write_file(File.join(extracted, ".git", "local"), "must not count\n")

        assert_equal expected, DigestModule.digest_from_directory(extracted)
        assert_equal expected,
          DigestModule.kit_bundle_digest_from_filesystem(File.realpath(extracted))
      end
    end
  end

  def test_filesystem_tree_matches_clone_and_cli_git_identity
    with_release_repository do |repository|
      write_file(File.join(repository, "lib", "value.rb"), "VALUE = 1\n")
      write_file(File.join(repository, "bin", "tool"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(repository, "bin", "tool"))
      write_file(File.join(repository, "test", "excluded.rb"), "ignored\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "filesystem parity", chdir: repository)
      expected = DigestModule.kit_bundle_digest(repository, "HEAD")

      Dir.mktmpdir("release-digest-filesystem-clone") do |parent|
        clone = File.join(parent, "clone")
        run!("git", "clone", "--quiet", repository, clone)
        filesystem_root = File.realpath(clone)

        assert_equal expected, DigestModule.kit_bundle_digest_from_filesystem(filesystem_root)
        cli = run_command(
          RbConfig.ruby,
          File.join(KIT_ROOT, "engine", "release", "release_digest.rb"),
          "--filesystem-root", filesystem_root,
        )
        assert cli.success?, cli.combined
        assert_equal expected, cli.stdout.strip
      end
    end
  end

  def test_strict_filesystem_tree_refuses_root_and_parent_symlinks
    Dir.mktmpdir("release-digest-strict-", FIXTURES_ROOT) do |parent|
      real_parent = File.join(parent, "real")
      tree = File.join(real_parent, "tree")
      write_file(File.join(tree, "regular.txt"), "regular\n")

      root_link = File.join(real_parent, "tree-link")
      File.symlink(tree, root_link)
      error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest_from_filesystem(root_link)
      end
      assert_includes error.message, "symbolic link"

      parent_link = File.join(parent, "parent-link")
      File.symlink(real_parent, parent_link)
      error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest_from_filesystem(File.join(parent_link, "tree"))
      end
      assert_includes error.message, "symbolic link"
    end
  end

  def test_filesystem_tree_refuses_symlink_special_file_and_noncanonical_mode
    Dir.mktmpdir("release-digest-refusal-", FIXTURES_ROOT) do |tree|
      regular = File.join(tree, "regular.txt")
      write_file(regular, "regular\n")

      File.chmod(0o777, regular)
      mode_error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest_from_filesystem(tree)
      end
      assert_includes mode_error.message, "mode=0777"

      File.chmod(0o644, regular)
      File.symlink("regular.txt", File.join(tree, "link.txt"))
      symlink_error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest_from_filesystem(tree)
      end
      assert_includes symlink_error.message, "mode=120000"
      File.unlink(File.join(tree, "link.txt"))

      fifo = File.join(tree, "named-pipe")
      run!("mkfifo", fifo)
      special_error = assert_raises(DigestModule::RefusedEntry) do
        DigestModule.kit_bundle_digest_from_filesystem(tree)
      end
      assert_includes special_error.message, "non-regular entry"
    end
  end

  def test_filesystem_cli_refuses_git_selector_options
    result = run_command(
      RbConfig.ruby,
      File.join(KIT_ROOT, "engine", "release", "release_digest.rb"),
      "--filesystem-root", KIT_ROOT,
      "--ref", "HEAD",
    )

    refute result.success?
    assert_empty result.stdout
    assert_includes result.stderr, "cannot be combined"
  end

  def test_filesystem_cli_refuses_relative_root
    result = run_command(
      RbConfig.ruby,
      File.join(KIT_ROOT, "engine", "release", "release_digest.rb"),
      "--filesystem-root", ".",
    )

    refute result.success?
    assert_empty result.stdout
    assert_includes result.stderr, "normalized and absolute"
  end

  def test_auxiliary_engine_digest_uses_canonical_engine_path
    with_release_repository do |repository|
      write_file(File.join(repository, "engine", "release", "code.rb"), "engine\n")
      write_file(File.join(repository, "installer", "legacy.rb"), "wrapper\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "engine", chdir: repository)

      auxiliary = DigestModule.auxiliary_digests(repository, "HEAD")
      expected = DigestModule.subset_digest(
        repository,
        "HEAD",
        includes: ["engine/**"],
        excludes: [],
      )
      assert_equal expected, auxiliary.fetch("engine_digest")
    end
  end
end
