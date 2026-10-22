# frozen_string_literal: true

require_relative "test_helper"
require File.join(
  WorkflowKitTestHelpers::KIT_ROOT,
  "core",
  "project-template",
  ".ai",
  "runtime",
  "scripts",
  "workflow_lib",
)

class WorkflowLibTest < Minitest::Test
  def test_legacy_scope_is_read_conservatively_without_becoming_scope_v2
    manifest = {
      "write_scope" => ["backend/**"],
      "doc_scope" => {
        "can_edit" => ["docs/editable.md"],
        "must_update" => ["docs/required.md"],
        "must_review" => ["docs/review-only.md"],
      },
    }

    assert_equal 1, AgentWorkflow.manifest_scope_version(manifest)
    scopes = AgentWorkflow.scope_sets(manifest)
    assert_empty scopes.fetch("read_scope")
    assert_empty scopes.fetch("state_write_scope")
    assert_empty scopes.fetch("shared_write_scope")
    assert_equal(
      ["backend/**", "docs/editable.md", "docs/required.md", "docs/review-only.md"],
      scopes.fetch("write_scope"),
    )
  end

  def test_yaml_loader_rejects_object_deserialization
    Dir.mktmpdir("workflow-yaml-safety") do |directory|
      path = File.join(directory, "unsafe.yaml")
      write_file(path, "--- !ruby/object:Object {}\n")

      error = assert_raises(RuntimeError) { AgentWorkflow.load_yaml(path) }
      assert_includes error.message, "Cannot safely parse YAML"
    end
  end
end
