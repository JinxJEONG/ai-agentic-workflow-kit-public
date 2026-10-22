# frozen_string_literal: true

require_relative "test_helper"

class WorktreePortabilityTest < Minitest::Test
  def test_installed_validation_survives_maintenance_worktree_removal_and_fresh_checkout
    with_project(prefix: "workflow-kit-portable-source") do |source|
      run!("git", "remote", "add", "origin", "https://example.invalid/portable-project.git", chdir: source)
      run!("git", "commit", "--allow-empty", "-m", "baseline", chdir: source)

      Dir.mktmpdir("workflow-kit-portable-checkout", WorkflowKitTestHelpers::FIXTURES_ROOT) do |parent|
        maintenance = File.join(parent, "maintenance")
        checkout = File.join(parent, "checkout")
        run!("git", "worktree", "add", "-b", "harness/adopt-portability", maintenance, "main", chdir: source)

        bootstrap!(maintenance)
        commit_all!(maintenance, "adopt workflow kit")
        run!("git", "worktree", "remove", maintenance, chdir: source)

        run!("git", "clone", "--branch", "harness/adopt-portability", source, checkout)
        run!("git", "remote", "set-url", "origin", "https://example.invalid/portable-project.git", chdir: checkout)

        result = run!(RbConfig.ruby, script(checkout, "validate_agent_structure.rb"), chdir: checkout)
        assert_includes result.stdout, "OK: agent workflow structure is valid."
        assert_includes result.stdout, "NOTICE:"
        assert_includes result.stdout, "installation-worktree"
      end
    end
  end
end
