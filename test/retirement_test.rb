# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/retirement/nested_clone"

class RetirementTest < Minitest::Test
  def with_outer_and_nested
    with_project do |outer|
      write_file(File.join(outer, ".gitignore"), "ai-agentic-workflow-kit/\n")
      write_file(File.join(outer, "README.md"), "outer\n")
      commit_all!(outer)
      nested = File.join(outer, "ai-agentic-workflow-kit")
      run!("git", "clone", KIT_ROOT, nested)
      yield outer, nested
    end
  end

  def test_preservation_creates_private_verified_bundle_without_removal
    with_outer_and_nested do |outer, nested|
      Dir.mktmpdir("retirement-bundle") do |directory|
        bundle = File.join(directory, "baseline.bundle")
        result = WorkflowKit::NestedClone.preserve(repo: outer, destination: bundle)
        assert File.file?(bundle)
        assert_equal "0600", result["mode"]
        assert_equal false, result["removal_performed"]
        assert Dir.exist?(nested)
      end
    end
  end

  def test_verify_fails_closed_without_phase_evidence_and_checkpoint
    with_outer_and_nested do |outer, _nested|
      Dir.mktmpdir("retirement-evidence") do |directory|
        bundle = File.join(directory, "baseline.bundle")
        WorkflowKit::NestedClone.preserve(repo: outer, destination: bundle)
        result = WorkflowKit::NestedClone.verify(
          repo: outer, central_kit: KIT_ROOT, baseline_ref: "HEAD",
          phase3: File.join(directory, "missing3"), phase4: File.join(directory, "missing4"),
          checkpoint_root: File.join(directory, "missing-checkpoint"), bundle: bundle, state: "deferred",
        )
        refute result["eligible"]
        refute result.dig("requirements", "R-1", "pass")
        refute result.dig("requirements", "R-2", "pass")
        refute result.dig("requirements", "R-5", "pass")
        assert result.dig("bundle", "verified")
      end
    end
  end

  def test_nonempty_unstructured_evidence_cannot_make_retirement_eligible
    with_outer_and_nested do |outer, _nested|
      Dir.mktmpdir("retirement-false-positive") do |directory|
        bundle = File.join(directory, "baseline.bundle")
        WorkflowKit::NestedClone.preserve(repo: outer, destination: bundle)
        phase3 = File.join(directory, "phase3.txt")
        phase4 = File.join(directory, "phase4.txt")
        write_file(phase3, "complete")
        write_file(phase4, "complete")
        checkpoint = File.join(directory, "checkpoint")
        FileUtils.mkdir_p(checkpoint, mode: 0o700)

        result = WorkflowKit::NestedClone.verify(
          repo: outer, central_kit: KIT_ROOT, baseline_ref: "HEAD",
          phase3: phase3, phase4: phase4, checkpoint_root: checkpoint,
          bundle: bundle, state: "migrated",
        )
        refute result["eligible"]
        refute result.dig("requirements", "R-2", "pass")
        refute result.dig("requirements", "R-3", "pass")
        refute result.dig("requirements", "R-5", "pass")
        assert result.dig("bundle", "contains_nested_head")
      end
    end
  end

  def test_preserve_refuses_dirty_nested_clone_instead_of_losing_uncommitted_bytes
    with_outer_and_nested do |outer, nested|
      write_file(File.join(nested, "uncommitted.txt"), "must survive\n")
      Dir.mktmpdir("retirement-dirty") do |directory|
        bundle = File.join(directory, "baseline.bundle")
        assert_raises(ArgumentError) do
          WorkflowKit::NestedClone.preserve(repo: outer, destination: bundle)
        end
        refute File.exist?(bundle)
        assert File.file?(File.join(nested, "uncommitted.txt"))
      end
    end
  end
end
