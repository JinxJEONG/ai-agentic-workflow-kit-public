# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/validators/schema"
require_relative "../engine/validators/spec_registry"

class SchemaValidatorTest < Minitest::Test
  def test_installation_lock_accepts_complete_document
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "kit-installation.schema.yaml"))
    document = {
      "schema_version" => 2,
      "project_id" => "alpha",
      "kit_version" => "0.4.0",
      "kit_bundle_digest" => "sha256:#{'a' * 64}",
      "release_manifest_digest" => "sha256:#{'d' * 64}",
      "bundle_digest_algo" => 2,
      "rendered_digest_algo" => 2,
      "dirty_snapshot_algo" => 4,
      "repository_fingerprint" => "sha256:#{'b' * 64}",
      "installation_state" => "managed",
      "profile" => "generic",
      "protected_paths" => [".ai/tasks/**"],
      "source" => {
        "kind" => "local",
        "locator" => "file:///tmp/release.tar.gz",
        "manifest_locator" => "file:///tmp/release.manifest.json",
        "bundle_archive_sha256" => "sha256:#{'c' * 64}",
      },
    }

    assert_empty WorkflowKit::Schema.validate(document, schema)
  end

  def test_installation_lock_rejects_missing_trust_root_and_bad_paths
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "kit-installation.schema.yaml"))
    errors = WorkflowKit::Schema.validate({ "schema_version" => 2 }, schema)

    assert errors.any? { |error| error.include?("kit_bundle_digest") }
    assert errors.any? { |error| error.include?("dirty_snapshot_algo") }
    assert errors.any? { |error| error.include?("source") }
  end

  def test_installation_lock_schema_rejects_development_source_and_state
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "kit-installation.schema.yaml"))
    document = {
      "schema_version" => 2,
      "project_id" => "fixture-project",
      "kit_version" => "0.4.0",
      "kit_bundle_digest" => nil,
      "release_manifest_digest" => nil,
      "bundle_digest_algo" => 2,
      "rendered_digest_algo" => 2,
      "dirty_snapshot_algo" => 4,
      "repository_fingerprint" => "sha256:#{'b' * 64}",
      "installation_state" => "dev_unmanaged",
      "profile" => "generic",
      "protected_paths" => [".ai/tasks/**"],
      "source" => {
        "kind" => "development",
        "locator" => "file:///tmp/workflow-kit-fixture",
      },
    }

    errors = WorkflowKit::Schema.validate(document, schema)
    assert errors.any? { |error| error.include?("installation_state") }
    assert errors.any? { |error| error.include?("source.kind") }
  end

  def test_spec_registry_rejects_unknown_properties
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "spec-registry.schema.yaml"))
    document = {
      "schema_version" => 1,
      "project_id" => "alpha",
      "rules" => [{
        "id" => "db",
        "source_globs" => ["db/**"],
        "canonical_specs" => [".ai/canonical/database.md"],
        "generated_facts" => [],
        "checks" => ["migration-checksum"],
        "impact_policy" => "spec_update_required",
        "codeowners" => ["@database-owner"],
        "typo" => true,
      }],
    }

    errors = WorkflowKit::Schema.validate(document, schema)
    assert errors.any? { |error| error.include?("typo") }
  end

  def test_spec_registry_forbids_project_replacement_of_central_high_risk_globs
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "spec-registry.schema.yaml"))
    document = {
      "schema_version" => 1,
      "project_id" => "alpha",
      "high_risk_globs" => ["only/this/path/**"],
      "additional_high_risk_globs" => ["project/specific/**"],
      "rules" => [{
        "id" => "db",
        "source_globs" => ["db/**"],
        "canonical_specs" => [".ai/canonical/database.md"],
        "generated_facts" => [],
        "checks" => ["migration-checksum"],
        "impact_policy" => "spec_update_required",
        "codeowners" => ["@database-owner"],
      }],
    }

    errors = WorkflowKit::Schema.validate(document, schema)
    assert_includes errors, "$.high_risk_globs: is not allowed"
    document.delete("high_risk_globs")
    assert_empty WorkflowKit::Schema.validate(document, schema)
  end

  def test_spec_registry_requires_valid_rule_codeowners
    document = {
      "schema_version" => 1,
      "project_id" => "alpha",
      "rules" => [{
        "id" => "db",
        "source_globs" => ["db/**"],
        "canonical_specs" => [".ai/canonical/database.md"],
        "generated_facts" => [],
        "checks" => ["migration-checksum"],
        "impact_policy" => "spec_update_required",
      }],
    }

    errors = WorkflowKit::SpecRegistry.validate(document)
    assert_includes errors, "$.rules[0].codeowners: is required"

    document["rules"].first["codeowners"] = []
    errors = WorkflowKit::SpecRegistry.validate(document)
    assert_includes errors, "$.rules[0].codeowners: must contain at least 1 item(s)"

    document["rules"].first["codeowners"] = ["owner-without-at-sign"]
    errors = WorkflowKit::SpecRegistry.validate(document)
    assert_includes errors, "$.rules[0].codeowners[0]: does not match required pattern"
  end

  def test_spec_registry_rejects_duplicate_rule_codeowners
    document = {
      "schema_version" => 1,
      "project_id" => "alpha",
      "rules" => [{
        "id" => "db",
        "source_globs" => ["db/**"],
        "canonical_specs" => [".ai/canonical/database.md"],
        "generated_facts" => [],
        "checks" => ["migration-checksum"],
        "impact_policy" => "spec_update_required",
        "codeowners" => ["@database-owner", "@database-owner"],
      }],
    }

    errors = WorkflowKit::SpecRegistry.validate(document)
    assert_includes errors, '$.rules[0].codeowners: duplicate owner "@database-owner"'
  end

  def test_generated_facts_schema_matches_generated_document_metadata
    schema = WorkflowKit::Schema.load_yaml(File.join(KIT_ROOT, "schemas", "generated-facts.schema.yaml"))
    document = {
      "generated_schema" => 2,
      "rule_id" => "database",
      "fact_type" => "migration-checksums",
      "generator_version" => "1.0.0",
      "generated_at" => "2026-08-13T01:02:03Z",
      "source_digest_algo" => 1,
      "source_tree_digest" => "sha256:#{'a' * 64}",
      "source_commit_hint" => "b" * 40,
      "content_digest" => "sha256:#{'c' * 64}",
      "facts" => { "migrations" => [] },
    }

    assert_empty WorkflowKit::Schema.validate(document, schema)
    document.delete("generated_at")
    assert_includes WorkflowKit::Schema.validate(document, schema), "$.generated_at: is required"
  end
end
