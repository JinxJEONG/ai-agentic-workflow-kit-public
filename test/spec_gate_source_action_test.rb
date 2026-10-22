# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/release/release_digest"

class SpecGateSourceActionTest < Minitest::Test
  ACTION_DIRECTORY = File.join(KIT_ROOT, ".github", "actions", "spec-gate-source")
  ACTION_METADATA = File.join(ACTION_DIRECTORY, "action.yml")
  ACTION_SHA = "a" * 40

  def action_definition
    YAML.safe_load(
      File.read(ACTION_METADATA), permitted_classes: [], permitted_symbols: [], aliases: false,
    )
  end

  def action_step
    action_definition.fetch("runs").fetch("steps").fetch(0)
  end

  def default_expected_files
    action_definition.fetch("inputs").fetch("expected-files").fetch("default")
  end

  def with_action_source
    Dir.mktmpdir("spec-gate-source-", FIXTURES_ROOT) do |root|
      FileUtils.mkdir_p(File.dirname(File.join(root, ".github", "actions", "spec-gate-source")))
      FileUtils.cp_r(ACTION_DIRECTORY, File.join(root, ".github", "actions"), preserve: true)
      default_expected_files.lines(chomp: true).each do |relative|
        next if relative.empty? || relative.start_with?(".github/actions/spec-gate-source/")

        write_file(File.join(root, relative), "fixture: #{relative}\n")
        File.chmod(0o644, File.join(root, relative))
      end
      yield root
    end
  end

  def source_digest(root)
    "sha256:#{WorkflowKit::Release::ReleaseDigest.kit_bundle_digest_from_filesystem(root)}"
  end

  def run_action(root, expected_digest: source_digest(root), env: {})
    output = File.join(root, ".github", "github-output")
    write_file(output, "")
    File.chmod(0o644, output)
    action_path = File.join(root, ".github", "actions", "spec-gate-source")
    defaults = {
      "GITHUB_ACTION_PATH" => action_path,
      "GITHUB_OUTPUT" => output,
      "ACTION_PATH_CONTEXT" => action_path,
      "ACTION_REF" => ACTION_SHA,
      "ACTION_REPOSITORY" => "JinxJEONG/ai-agentic-workflow-kit-public",
      "EXPECTED_REF" => ACTION_SHA,
      "EXPECTED_REPOSITORY" => "JinxJEONG/ai-agentic-workflow-kit-public",
      "EXPECTED_BUNDLE_DIGEST" => expected_digest,
      "EXPECTED_FILES" => default_expected_files,
    }
    result = run_command("/bin/bash", "-c", action_step.fetch("run"), chdir: root, env: defaults.merge(env))
    [result, output]
  end

  def test_action_metadata_pins_contexts_and_inline_verifier_contract
    step = action_step
    assert_equal "${{ github.action_path }}", step.fetch("env").fetch("ACTION_PATH_CONTEXT")
    assert_equal "${{ github.action_ref }}", step.fetch("env").fetch("ACTION_REF")
    assert_equal "${{ github.action_repository }}", step.fetch("env").fetch("ACTION_REPOSITORY")
    assert_includes default_expected_files.lines(chomp: true), "engine/release/release_digest.rb"
    refute_includes default_expected_files.lines(chomp: true),
      ".github/actions/spec-gate-source/verify_source.rb"
    refute File.exist?(File.join(ACTION_DIRECTORY, "verify_source.rb"))

    verifier = step.fetch("run")
    assert_includes verifier, '<<\'RUBY\''
    refute_match(/require(?:_relative)? .*engine/, verifier)
    refute_match(/require(?:_relative)? .*release_digest/, verifier)
    assert_includes verifier, 'BUNDLE_DIGEST_ALGO = 2'
    assert_includes verifier, '"workflow-kit-bundle-digest\\0#{BUNDLE_DIGEST_ALGO}\\0#{sorted.length}\\0"'
    WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES.each do |pattern|
      assert_includes verifier, pattern.inspect
    end
  end

  def test_action_outputs_exact_root_only_after_independent_digest_verification
    with_action_source do |root|
      expected = source_digest(root)
      result, output = run_action(root, expected_digest: expected)

      assert result.success?, result.combined
      assert_includes result.stdout, "exact action source bundle verified"
      assert_equal "repository-root=#{root}\n", File.read(output)
    end
  end

  def test_tampered_engine_cannot_be_bypassed_by_excluded_github_verifier_files
    with_action_source do |root|
      expected = source_digest(root)
      engine_verifier = File.join(root, "engine", "release", "release_digest.rb")
      write_file(engine_verifier, 'puts ENV.fetch("EXPECTED_BUNDLE_DIGEST")' + "\n")
      File.chmod(0o644, engine_verifier)
      write_file(
        File.join(root, ".github", "actions", "spec-gate-source", "verify_source.rb"),
        "# excluded empty verifier replacement\n",
      )
      write_file(File.join(root, ".github", "ignored-bypass"), "excluded\n")
      result, output = run_action(root, expected_digest: expected)

      refute result.success?
      assert_includes result.combined, "source bundle digest mismatch"
      assert_empty File.read(output)
    end
  end

  def test_inline_verifier_rejects_noncanonical_regular_file_modes
    [0o777, 0o4755, 0o640].each do |mode|
      with_action_source do |root|
        expected = source_digest(root)
        selected = File.join(root, "VERSION")
        File.chmod(mode, selected)
        result, output = run_action(root, expected_digest: expected)

        refute result.success?
        assert_includes result.combined, format("mode=%04o", mode)
        assert_empty File.read(output)
      end
    end
  end

  def test_inline_verifier_rejects_fifo_and_selected_file_symlink
    with_action_source do |root|
      expected = source_digest(root)
      fifo = File.join(root, "selected-pipe")
      run!("mkfifo", fifo)
      result, output = run_action(root, expected_digest: expected)

      refute result.success?
      assert_includes result.combined, "non-regular entry"
      assert_empty File.read(output)
    end
    with_action_source do |root|
      expected = source_digest(root)
      File.symlink("VERSION", File.join(root, "selected-link"))
      result, output = run_action(root, expected_digest: expected)

      refute result.success?
      assert_includes result.combined, "mode=120000"
      assert_empty File.read(output)
    end
  end

  def test_inline_verifier_rejects_extra_selected_file_digest_drift
    with_action_source do |root|
      expected = source_digest(root)
      extra = File.join(root, "unexpected-selected-file")
      write_file(extra, "unexpected\n")
      File.chmod(0o644, extra)
      result, output = run_action(root, expected_digest: expected)

      refute result.success?
      assert_includes result.combined, "source bundle digest mismatch"
      assert_empty File.read(output)
    end
  end

  def test_action_rejects_repository_ref_path_and_sentinel_mismatches
    with_action_source do |root|
      result, = run_action(root, env: { "ACTION_REPOSITORY" => "attacker/example" })
      refute result.success?
      assert_includes result.combined, "action_repository"
    end
    with_action_source do |root|
      result, = run_action(root, env: { "ACTION_REF" => "b" * 40 })
      refute result.success?
      assert_includes result.combined, "action_ref"
    end
    with_action_source do |root|
      result, = run_action(root, env: { "ACTION_PATH_CONTEXT" => "#{root}/wrong" })
      refute result.success?
      assert_includes result.combined, "action_path"
    end
    with_action_source do |root|
      sentinel = File.join(root, ".github", "actions", "spec-gate-source", "repository-root.sentinel")
      write_file(sentinel, "wrong\n")
      result, = run_action(root)
      refute result.success?
      assert_includes result.combined, "sentinel is invalid"
    end
  end

  def test_action_rejects_relative_or_crlf_paths_and_outputs
    with_action_source do |root|
      action_path = File.join(root, ".github", "actions", "spec-gate-source")
      result, = run_action(
        root,
        env: { "GITHUB_ACTION_PATH" => "relative/action", "ACTION_PATH_CONTEXT" => "relative/action" },
      )
      refute result.success?
      assert_includes result.combined, "must be absolute"

      result, = run_action(
        root,
        env: { "GITHUB_ACTION_PATH" => "#{action_path}\r", "ACTION_PATH_CONTEXT" => "#{action_path}\r" },
      )
      refute result.success?
      assert_includes result.combined, "must not contain CR or LF"

      result, = run_action(root, env: { "GITHUB_OUTPUT" => "relative-output" })
      refute result.success?
      assert_includes result.combined, "GITHUB_OUTPUT must be absolute"

      output_with_cr = File.join(root, ".github", "github-output\r")
      result, = run_action(root, env: { "GITHUB_OUTPUT" => output_with_cr })
      refute result.success?
      assert_includes result.combined, "GITHUB_OUTPUT must be absolute and single-line"
    end
  end

  def test_action_rejects_parent_action_and_repository_root_symlinks
    with_action_source do |root|
      container = File.dirname(root)
      repository_link = File.join(container, "repository-link")
      File.symlink(root, repository_link)
      linked_action = File.join(repository_link, ".github", "actions", "spec-gate-source")
      result, = run_action(
        root,
        env: { "GITHUB_ACTION_PATH" => linked_action, "ACTION_PATH_CONTEXT" => linked_action },
      )
      refute result.success?
      assert_includes result.combined, "symbolic-link path component refused"

      real_parent = File.dirname(root)
      parent_link = File.join(real_parent, "parent-link-#{File.basename(root)}")
      File.symlink(real_parent, parent_link)
      parent_linked_action = File.join(parent_link, File.basename(root), ".github", "actions", "spec-gate-source")
      result, = run_action(
        root,
        env: {
          "GITHUB_ACTION_PATH" => parent_linked_action,
          "ACTION_PATH_CONTEXT" => parent_linked_action,
        },
      )
      refute result.success?
      assert_includes result.combined, "symbolic-link path component refused"

      wrapper = File.join(container, "action-link-wrapper")
      action_link = File.join(wrapper, ".github", "actions", "spec-gate-source")
      FileUtils.mkdir_p(File.dirname(action_link))
      File.symlink(File.join(root, ".github", "actions", "spec-gate-source"), action_link)
      result, = run_action(
        root,
        env: { "GITHUB_ACTION_PATH" => action_link, "ACTION_PATH_CONTEXT" => action_link },
      )
      refute result.success?
      assert_includes result.combined, "symbolic-link path component refused"
    ensure
      File.unlink(repository_link) if repository_link && File.symlink?(repository_link)
      File.unlink(parent_link) if parent_link && File.symlink?(parent_link)
      FileUtils.remove_entry(wrapper) if wrapper && File.exist?(wrapper)
    end
  end
end
