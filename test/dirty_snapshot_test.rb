# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/release/dirty_snapshot"
require "socket"

class DirtySnapshotTest < Minitest::Test
  Snapshot = WorkflowKit::Release::DirtySnapshot

  def baseline_repository
    with_project(prefix: "dirty-snapshot-test") do |repository|
      write_file(File.join(repository, "tracked.txt"), "baseline\n")
      run!("git", "add", ".", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "baseline", chdir: repository)
      yield repository
    end
  end

  def test_clean_tree_is_sha256_of_empty_material
    baseline_repository do |repository|
      expected = Digest::SHA256.hexdigest(
        "ai-harness-governance-dirty-snapshot\0#{Snapshot::DIRTY_SNAPSHOT_ALGO}\0" \
          "0\0",
      )

      assert_equal 4, Snapshot::DIRTY_SNAPSHOT_ALGO
      assert_equal "e2de68851d3aaf1d1d886b472d159bfcb0b8e6d524941f06835c2662c324c0ad", expected
      assert_equal expected, Snapshot.digest(repository)
      snapshot = Snapshot.snapshot(repository)
      assert_equal 0, snapshot.fetch("entry_count")
      assert_equal(
        { "mode" => "all", "paths" => [], "globs" => [] },
        snapshot.fetch("dirty_snapshot_scope"),
      )
    end
  end

  def test_length_prefix_framing_distinguishes_newline_path_injection
    fields_one = ["??", "f", "a" * 64, "-", "-", "a\n#{'b' * 64}\t-\t-\tb"]
    fields_two = [
      ["??", "f", "a" * 64, "-", "-", "a"],
      ["??", "f", "b" * 64, "-", "-", "b"],
    ]
    frame = lambda do |rows|
      material = +"ai-harness-governance-dirty-snapshot\0".b
      material << "#{Snapshot::DIRTY_SNAPSHOT_ALGO}\0#{rows.length}\0".b
      rows.each do |row|
        row.each do |field|
          field = field.b
          material << field.bytesize.to_s.b << ":".b << field
        end
      end
      Digest::SHA256.hexdigest(material)
    end

    refute_equal frame.call([fields_one]), frame.call(fields_two)
  end

  def test_same_status_with_different_file_contents_changes_digest
    baseline_repository do |repository|
      write_file(File.join(repository, "tracked.txt"), "first dirty value\n")
      first = Snapshot.digest(repository)
      write_file(File.join(repository, "tracked.txt"), "second dirty value\n")
      second = Snapshot.digest(repository)

      refute_equal first, second
    end
  end

  def test_staged_and_worktree_bytes_are_distinct
    baseline_repository do |repository|
      write_file(File.join(repository, "tracked.txt"), "staged value\n")
      run!("git", "add", "tracked.txt", chdir: repository)
      staged_only = Snapshot.snapshot(repository)

      write_file(File.join(repository, "tracked.txt"), "worktree value\n")
      split = Snapshot.snapshot(repository)
      entry = split.fetch("entries").first

      refute_equal staged_only.fetch("dirty_snapshot_digest"), split.fetch("dirty_snapshot_digest")
      assert_equal Digest::SHA256.hexdigest("staged value\n"), entry.fetch("staged_sha256")
      assert_equal Digest::SHA256.hexdigest("worktree value\n"), entry.fetch("worktree_sha256")
    end
  end

  def test_untracked_space_and_newline_paths_are_content_sensitive
    baseline_repository do |repository|
      path = "untracked space\nand newline.txt"
      write_file(File.join(repository, path), "one\n")
      first = Snapshot.snapshot(repository)
      write_file(File.join(repository, path), "two\n")
      second = Snapshot.snapshot(repository)

      assert_equal path, second.fetch("entries").first.fetch("path")
      refute_equal first.fetch("dirty_snapshot_digest"), second.fetch("dirty_snapshot_digest")
    end
  end

  def test_scope_globs_ignore_unrelated_dirty_paths
    baseline_repository do |repository|
      write_file(File.join(repository, "tracked.txt"), "in scope\n")
      write_file(File.join(repository, "notes", "local.txt"), "out of scope one\n")
      selected = Snapshot.snapshot(repository, scope_globs: ["tracked.txt"])
      first = selected.fetch("dirty_snapshot_digest")
      write_file(File.join(repository, "notes", "local.txt"), "out of scope two\n")

      assert_equal first, Snapshot.digest(repository, scope_globs: ["tracked.txt"])
      refute_equal first, Snapshot.digest(repository)
      assert_equal(
        { "mode" => "custom", "paths" => [], "globs" => ["tracked.txt"] },
        selected.fetch("dirty_snapshot_scope"),
      )
    end
  end

  def test_exact_scope_paths_are_not_reinterpreted_as_globs
    baseline_repository do |repository|
      exact = "src/target[1].rb"
      write_file(File.join(repository, exact), "exact\n")
      write_file(File.join(repository, "src", "target1.rb"), "glob lookalike\n")
      write_file(File.join(repository, ".ai", "runtime", "policy.rb"), "policy\n")

      result = Snapshot.snapshot(
        repository,
        scope_paths: [exact],
        scope_globs: [".ai/**"],
        scope_mode: "plan_targets_plus_harness_allowlist",
      )

      assert_equal [".ai/runtime/policy.rb", exact], result.fetch("entries").map { |entry| entry.fetch("path") }
      assert_equal(
        {
          "mode" => "plan_targets_plus_harness_allowlist",
          "paths" => [exact],
          "globs" => [".ai/**"],
        },
        result.fetch("dirty_snapshot_scope"),
      )
    end
  end

  def test_scoped_snapshot_includes_a_rename_out_of_scope_by_its_origin
    baseline_repository do |repository|
      write_file(File.join(repository, ".ai", "runtime", "policy.rb"), "policy\n")
      run!("git", "add", ".ai/runtime/policy.rb", chdir: repository)
      run!("git", "commit", "--no-verify", "-m", "add scoped file", chdir: repository)
      run!("git", "mv", ".ai/runtime/policy.rb", "outside-policy.rb", chdir: repository)

      result = Snapshot.snapshot(
        repository,
        scope_globs: [".ai/**"],
        scope_mode: "plan_targets_plus_harness_allowlist",
      )
      entry = result.fetch("entries").fetch(0)

      assert_equal "outside-policy.rb", entry.fetch("path")
      assert_equal ".ai/runtime/policy.rb", entry.fetch("origin")
      assert_equal 1, result.fetch("entry_count")
    end
  end

  def test_scoped_modes_reject_empty_or_unknown_scope
    baseline_repository do |repository|
      empty = assert_raises(ArgumentError) do
        Snapshot.snapshot(repository, scope_mode: "custom")
      end
      unknown = assert_raises(ArgumentError) do
        Snapshot.snapshot(repository, scope_paths: ["tracked.txt"], scope_mode: "typo")
      end
      blank = assert_raises(ArgumentError) do
        Snapshot.snapshot(repository, scope_paths: [nil], scope_mode: "custom")
      end

      assert_match(/must include paths or globs/, empty.message)
      assert_match(/unsupported dirty snapshot scope mode/, unknown.message)
      assert_match(/scope values cannot be empty/, blank.message)
    end
  end

  def test_rename_records_origin_path
    baseline_repository do |repository|
      run!("git", "mv", "tracked.txt", "renamed.txt", chdir: repository)
      result = Snapshot.snapshot(repository)
      entry = result.fetch("entries").first

      assert_equal "renamed.txt", entry.fetch("path")
      assert_equal "tracked.txt", entry.fetch("origin")
      assert_equal "f", entry.fetch("worktree_type")
      expected_file_digest = Digest::SHA256.hexdigest("baseline\n")
      assert_equal expected_file_digest, entry.fetch("worktree_sha256")
      assert_equal expected_file_digest, entry.fetch("staged_sha256")
      assert_equal "e308c5fe79ccf74f38ed7cfcb876e92493225df99bd8c96a445ad3ced2426631",
        result.fetch("dirty_snapshot_digest")
    end
  end

  def test_symlink_uses_target_blob_digest_for_worktree_and_index
    baseline_repository do |repository|
      link = File.join(repository, "link.txt")
      File.symlink("staged-private-target", link)
      run!("git", "add", "link.txt", chdir: repository)
      File.unlink(link)
      File.symlink("worktree-private-target", link)
      entry = Snapshot.snapshot(repository).fetch("entries").find do |candidate|
        candidate.fetch("path") == "link.txt"
      end

      assert_equal "l", entry.fetch("worktree_type")
      assert_equal Digest::SHA256.hexdigest("worktree-private-target"), entry.fetch("worktree_sha256")
      assert_equal Digest::SHA256.hexdigest("staged-private-target"), entry.fetch("staged_sha256")
    end
  end

  def test_entry_type_distinguishes_regular_file_from_symlink_with_same_content_digest
    baseline_repository do |regular_repository|
      write_file(File.join(regular_repository, "entry"), "same-target-bytes")
      regular = Snapshot.snapshot(regular_repository)
      regular_entry = regular.fetch("entries").find { |entry| entry.fetch("path") == "entry" }

      baseline_repository do |symlink_repository|
        File.symlink("same-target-bytes", File.join(symlink_repository, "entry"))
        symlink = Snapshot.snapshot(symlink_repository)
        symlink_entry = symlink.fetch("entries").find { |entry| entry.fetch("path") == "entry" }

        assert_equal regular_entry.fetch("worktree_sha256"), symlink_entry.fetch("worktree_sha256")
        assert_equal "f", regular_entry.fetch("worktree_type")
        assert_equal "l", symlink_entry.fetch("worktree_type")
        refute_equal regular.fetch("dirty_snapshot_digest"), symlink.fetch("dirty_snapshot_digest")
      end
    end
  end

  def test_top_level_symlink_target_only_change_changes_digest
    baseline_repository do |repository|
      link = File.join(repository, "current-target")
      File.symlink("first-private-target", link)
      first = Snapshot.snapshot(repository)
      first_entry = first.fetch("entries").find { |entry| entry.fetch("path") == "current-target" }

      File.unlink(link)
      File.symlink("second-private-target", link)
      second = Snapshot.snapshot(repository)
      second_entry = second.fetch("entries").find { |entry| entry.fetch("path") == "current-target" }

      assert_equal "l", first_entry.fetch("worktree_type")
      assert_equal Digest::SHA256.hexdigest("first-private-target"), first_entry.fetch("worktree_sha256")
      assert_equal Digest::SHA256.hexdigest("second-private-target"), second_entry.fetch("worktree_sha256")
      refute_equal first.fetch("dirty_snapshot_digest"), second.fetch("dirty_snapshot_digest")
    end
  end

  def test_regular_file_replacement_with_a_symlink_is_rejected
    baseline_repository do |repository|
      Dir.mktmpdir("dirty-snapshot-outside") do |outside_root|
        path = File.join(repository, "tracked.txt")
        outside = File.join(outside_root, "private-outside.txt")
        write_file(outside, "must not be hashed\n")
        write_file(path, "dirty regular file\n")
        original_open = Snapshot::NativeAt.method(:open_io)
        swapped = false

        Snapshot::NativeAt.stub(:open_io, lambda { |parent_fd, name|
          io = original_open.call(parent_fd, name)
          if !swapped && name == "tracked.txt"
            swapped = true
            File.unlink(path)
            File.symlink(outside, path)
          end
          io
        }) do
          error = assert_raises(Snapshot::SnapshotError) { Snapshot.snapshot(repository) }
          assert_match(/changed while calculating dirty snapshot/, error.message)
          refute_includes error.message, "must not be hashed"
        end
        assert swapped
      end
    end
  end

  def test_in_place_regular_file_mutation_is_rejected
    baseline_repository do |repository|
      path = File.join(repository, "tracked.txt")
      write_file(path, "dirty regular file\n")
      original_read = Snapshot.method(:read_io_chunk)
      mutated = false

      Snapshot.stub(:read_io_chunk, lambda { |io, buffer|
        unless mutated
          mutated = true
          write_file(path, "mutated during snapshot with a different size\n")
        end
        original_read.call(io, buffer)
      }) do
        error = assert_raises(Snapshot::SnapshotError) { Snapshot.snapshot(repository) }
        assert_match(/file changed while calculating dirty snapshot/, error.message)
      end
      assert mutated
    end
  end

  def test_nested_directory_symlink_swap_is_rejected_without_recursing_outside
    baseline_repository do |repository|
      Dir.mktmpdir("dirty-snapshot-outside") do |outside_root|
        nested = File.join(repository, "nested-clone")
        outside = File.join(outside_root, "private-outside-directory")
        FileUtils.mkdir_p(nested)
        run!("git", "init", "-b", "main", nested)
        FileUtils.mkdir_p(outside)
        write_file(File.join(nested, "inside.txt"), "inside\n")
        write_file(File.join(outside, "outside.txt"), "must not be hashed\n")
        original_open = Dir.method(:open)
        swapped = false

        Dir.stub(:open, lambda { |candidate, *arguments, &block|
          if !swapped && candidate == nested
            swapped = true
            FileUtils.mv(nested, "#{nested}-held")
            File.symlink(outside, nested)
          end
          original_open.call(candidate, *arguments, &block)
        }) do
          error = assert_raises(Snapshot::SnapshotError) { Snapshot.snapshot(repository) }
          assert_match(/changed while calculating dirty snapshot/, error.message)
          refute_includes error.message, "private-outside-directory"
        end
        assert swapped
      end
    end
  end

  def test_ancestor_directory_symlink_swap_is_rejected_before_reading_outside
    baseline_repository do |repository|
      Dir.mktmpdir("dirty-snapshot-outside") do |outside_root|
        ancestor = File.join(repository, "scoped")
        outside = File.join(outside_root, "private-outside-ancestor")
        FileUtils.mkdir_p(ancestor)
        FileUtils.mkdir_p(outside)
        write_file(File.join(ancestor, "entry.txt"), "inside\n")
        write_file(File.join(outside, "entry.txt"), "must not be hashed\n")
        original_open = Dir.method(:open)
        swapped = false

        Dir.stub(:open, lambda { |candidate, *arguments, &block|
          if !swapped && candidate == ancestor
            swapped = true
            FileUtils.mv(ancestor, "#{ancestor}-held")
            File.symlink(outside, ancestor)
          end
          original_open.call(candidate, *arguments, &block)
        }) do
          error = assert_raises(Snapshot::SnapshotError) { Snapshot.snapshot(repository) }
          assert_match(/changed while calculating dirty snapshot/, error.message)
          refute_includes error.message, "private-outside-ancestor"
        end
        assert swapped
      end
    end
  end

  def test_directory_handles_close_when_post_validation_rejects_a_race
    baseline_repository do |repository|
      write_file(File.join(repository, "tracked.txt"), "dirty\n")
      original_close = Snapshot.method(:close_directory)
      closed = []

      Snapshot.stub(:validate_directory_chain!, lambda { |_worktree, _checks|
        raise Snapshot::SnapshotError, "simulated post-validation race"
      }) do
        Snapshot.stub(:close_directory, lambda { |directory|
          closed << directory
          original_close.call(directory)
        }) do
          error = assert_raises(Snapshot::SnapshotError) { Snapshot.snapshot(repository) }
          assert_match(/simulated post-validation race/, error.message)
        end
      end

      refute_empty closed
      closed.each { |directory| assert_raises(IOError) { directory.fileno } }
    end
  end

  def test_collapsed_untracked_directory_is_content_sensitive
    baseline_repository do |repository|
      nested = File.join(repository, "nested-clone")
      FileUtils.mkdir_p(nested)
      run!("git", "init", "-b", "main", nested)
      write_file(File.join(nested, "payload.txt"), "first\n")
      first = Snapshot.snapshot(repository)

      write_file(File.join(nested, "payload.txt"), "second\n")
      second = Snapshot.snapshot(repository)

      assert_equal 1, first.fetch("entry_count")
      assert_equal "nested-clone/", first.fetch("entries").first.fetch("path")
      assert_equal "d", first.fetch("entries").first.fetch("worktree_type")
      refute_equal first.fetch("dirty_snapshot_digest"), second.fetch("dirty_snapshot_digest")
    end
  end

  def test_collapsed_directory_hashes_nested_symlink_target_without_following_it
    baseline_repository do |repository|
      nested = File.join(repository, "nested-clone")
      FileUtils.mkdir_p(nested)
      run!("git", "init", "-b", "main", nested)
      link = File.join(nested, "current-target")
      File.symlink("first-private-target", link)
      first = Snapshot.snapshot(repository)

      File.unlink(link)
      File.symlink("second-private-target", link)
      second = Snapshot.snapshot(repository)

      assert_equal ["nested-clone/"], first.fetch("entries").map { |entry| entry.fetch("path") }
      refute_equal first.fetch("entries").first.fetch("worktree_sha256"),
        second.fetch("entries").first.fetch("worktree_sha256")
      refute_equal first.fetch("dirty_snapshot_digest"), second.fetch("dirty_snapshot_digest")
    end
  end

  def test_deleted_file_is_serialized_as_missing_type
    baseline_repository do |repository|
      File.unlink(File.join(repository, "tracked.txt"))
      entry = Snapshot.snapshot(repository).fetch("entries").first

      assert_equal "m", entry.fetch("worktree_type")
      assert_equal Snapshot::EMPTY_SHA256, entry.fetch("worktree_sha256")
    end
  end

  def test_special_entry_is_serialized_as_other_without_reading_it
    baseline_repository do |repository|
      path = File.join(repository, "tracked.txt")
      File.unlink(path)
      Dir.mktmpdir("dirty-socket", "/tmp") do |socket_root|
        socket_path = File.join(socket_root, "entry")
        server = UNIXServer.new(socket_path)
        File.rename(socket_path, path)
        begin
          entry = Snapshot.snapshot(repository).fetch("entries").first

          assert_equal "o", entry.fetch("worktree_type")
          assert_equal Snapshot::EMPTY_SHA256, entry.fetch("worktree_sha256")
        ensure
          server.close
        end
      end
    end
  end

  def test_unopenable_fifo_is_serialized_as_other_after_anchored_metadata_check
    baseline_repository do |repository|
      path = File.join(repository, "tracked.txt")
      File.unlink(path)
      run!("mkfifo", path)
      File.chmod(0o000, path)

      entry = Snapshot.snapshot(repository).fetch("entries").first

      assert_equal "o", entry.fetch("worktree_type")
      assert_equal Snapshot::EMPTY_SHA256, entry.fetch("worktree_sha256")
    ensure
      File.chmod(0o600, path) if path && File.exist?(path)
    end
  end

  def test_status_and_index_parsers_require_trailing_nul
    status_error = assert_raises(Snapshot::SnapshotError) do
      Snapshot.parse_status("?? file.txt".b)
    end
    index_error = assert_raises(Snapshot::SnapshotError) do
      Snapshot.parse_index("100644 #{'a' * 40} 0\tfile.txt".b)
    end

    assert_match(/malformed git status output/, status_error.message)
    assert_match(/malformed git index output/, index_error.message)
  end

  def test_cli_outputs_only_digest_by_default
    baseline_repository do |repository|
      write_file(File.join(repository, "tracked.txt"), "dirty\n")
      result = run!(
        RbConfig.ruby,
        File.join(KIT_ROOT, "engine", "release", "dirty_snapshot.rb"),
        "--worktree", repository,
      )
      assert_match(/\A[0-9a-f]{64}\n\z/, result.stdout)
      assert_empty result.stderr
    end
  end

  def test_cli_json_does_not_expose_raw_symlink_target
    baseline_repository do |repository|
      target = "do-not-print-private-target"
      File.symlink(target, File.join(repository, "current-target"))
      result = run!(
        RbConfig.ruby,
        File.join(KIT_ROOT, "engine", "release", "dirty_snapshot.rb"),
        "--worktree", repository,
        "--json",
      )

      payload = JSON.parse(result.stdout)
      entry = payload.fetch("entries").find { |candidate| candidate.fetch("path") == "current-target" }
      assert_equal "l", entry.fetch("worktree_type")
      refute_includes result.stdout, target
      assert_empty result.stderr
    end
  end
end
