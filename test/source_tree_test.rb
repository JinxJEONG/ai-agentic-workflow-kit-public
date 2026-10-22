# frozen_string_literal: true

require_relative "test_helper"
require_relative "../engine/facts/source_tree"

class SourceTreeTest < Minitest::Test
  def test_double_star_matches_zero_or_more_path_segments
    assert WorkflowKit::SourceTree.glob_match?("app/page.tsx", "app/**/page.*")
    assert WorkflowKit::SourceTree.glob_match?("app/admin/reports/page.tsx", "app/**/page.*")
    assert WorkflowKit::SourceTree.glob_match?("deploy/macos/bin/release.sh", "deploy/**")
    assert WorkflowKit::SourceTree.glob_match?("Dockerfile", "**/Dockerfile")
    assert WorkflowKit::SourceTree.glob_match?("services/api/Dockerfile", "**/Dockerfile")
  end

  def test_single_star_does_not_cross_a_path_separator
    assert WorkflowKit::SourceTree.glob_match?("src/main.rb", "src/*.rb")
    refute WorkflowKit::SourceTree.glob_match?("src/services/main.rb", "src/*.rb")
  end

  def test_double_star_does_not_match_unrelated_prefixes
    refute WorkflowKit::SourceTree.glob_match?("deployment/release.sh", "deploy/**")
    refute WorkflowKit::SourceTree.glob_match?("src/auth/login.rb", "src/admin/**")
  end
end
