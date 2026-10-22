# frozen_string_literal: true

require_relative "test_helper"

class TestIsolationTest < Minitest::Test
  def test_second_suite_for_the_same_checkout_fails_fast
    result = run_command(
      RbConfig.ruby,
      "-Itest",
      "-e",
      "require './test/test_helper'",
      chdir: KIT_ROOT,
    )

    refute result.success?
    assert_equal 75, result.status.exitstatus
    assert_includes result.combined, "another test suite is already using"
    assert_includes result.combined, "use a disposable clone for parallel tests"
  end
end
