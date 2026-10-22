# frozen_string_literal: true

require_relative "test_helper"

class SecurityScanTest < Minitest::Test
  SCANNER = File.join(WorkflowKitTestHelpers::KIT_ROOT, "script", "scan_secrets.rb")

  def test_repository_secret_scan_passes
    result = run!(RbConfig.ruby, SCANNER)
    assert_includes result.stdout, "no high-confidence secret patterns"
  end

  def test_secret_scan_rejects_without_echoing_the_value
    with_project do |project|
      synthetic_secret = "ghp_" + ("A" * 36)
      write_file(File.join(project, "fixture.txt"), "credential=#{synthetic_secret}\n")

      result = run_command(RbConfig.ruby, SCANNER, project, chdir: project)
      refute result.success?
      assert_includes result.combined, "fixture.txt:1 [github-token]"
      refute_includes result.combined, synthetic_secret
    end
  end

  def test_range_scan_ignores_unchanged_baseline_fixture_but_rejects_new_secret
    with_project do |project|
      baseline_secret = "sk-" + ("B" * 24)
      write_file(File.join(project, "historical-fixture.txt"), "synthetic=#{baseline_secret}\n")
      commit_all!(project, "historical fixture")
      base = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip

      write_file(File.join(project, "safe.txt"), "safe change\n")
      commit_all!(project, "safe change")
      safe_head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      accepted = run_command(
        RbConfig.ruby, SCANNER, "--range", "#{base}..#{safe_head}", project, chdir: project
      )
      assert accepted.success?, accepted.combined

      new_secret = "ghp_" + ("C" * 36)
      write_file(File.join(project, "new-fixture.txt"), "credential=#{new_secret}\n")
      commit_all!(project, "new fixture")
      secret_head = run!("git", "rev-parse", "HEAD", chdir: project).stdout.strip
      rejected = run_command(
        RbConfig.ruby, SCANNER, "--range", "#{safe_head}..#{secret_head}", project, chdir: project
      )
      refute rejected.success?
      assert_includes rejected.combined, "new-fixture.txt:1 [github-token]"
      refute_includes rejected.combined, new_secret
    end
  end
end
