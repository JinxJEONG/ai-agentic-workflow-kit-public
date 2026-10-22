# frozen_string_literal: true

require "yaml"
require_relative "test_helper"

class WorkflowPolicyTest < Minitest::Test
  WORKFLOW = File.join(KIT_ROOT, ".github", "workflows", "spec-gate.yml")
  CI_WORKFLOW = File.join(KIT_ROOT, ".github", "workflows", "ci.yml")
  CHECKOUT_COMMIT = "11d5960a326750d5838078e36cf38b85af677262"
  SETUP_RUBY_COMMIT = "95ef2b042f9d7a56d8268cba8559e2842e2ad01b"
  V048_ACTION_SOURCE_COMMIT = "1e9c7fcc0057ff4c70df7d0043cc2374e150b50d"

  def load_workflow(path)
    YAML.safe_load(
      File.read(path),
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
    )
  end

  def workflow
    load_workflow(WORKFLOW)
  end

  def spec_gate_steps
    workflow.fetch("jobs").fetch("spec-gate").fetch("steps")
  end

  def private_source_step
    spec_gate_steps.find { |step| step["id"] == "kit-source" }
  end

  def oidc_disable_confirmation_step
    spec_gate_steps.find { |step| step["name"] == "Confirm the OIDC request channel is disabled" }
  end

  def review_collection_step
    spec_gate_steps.find { |step| step["name"] == "Collect latest pull-request reviews" }
  end

  def transitional_v048_review_collection?
    private_source_step&.dig("with", "expected-ref") == V048_ACTION_SOURCE_COMMIT
  end

  def logical_shell_commands(script)
    script.gsub(/\\\r?\n/, " ").lines.map(&:strip).reject(&:empty?)
  end

  def test_reusable_workflow_requires_an_explicit_immutable_kit_identity
    inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")
    %w[kit_repository kit_commit kit_version kit_bundle_digest].each do |name|
      assert_equal true, inputs.fetch(name).fetch("required"), name
    end
  end

  def test_every_checkout_action_is_pinned_to_a_full_commit
    steps = workflow.fetch("jobs").fetch("spec-gate").fetch("steps")
    checkout_refs = steps.map do |step|
      value = step["uses"]
      value if value.to_s.start_with?("actions/checkout@")
    end.compact
    refute_empty checkout_refs
    checkout_refs.each do |value|
      assert_equal "actions/checkout@#{CHECKOUT_COMMIT}", value
      assert_match(/\Aactions\/checkout@[0-9a-f]{40}\z/, value)
    end
  end

  def test_gate_has_no_memory_or_provider_input
    raw = File.read(WORKFLOW)
    refute_match(/memsearch|obsidian|mcp|api[_-]?key|provider/i, raw)
    if private_source_step
      refute_includes raw, "repository: ${{ inputs.kit_repository }}"
      refute_includes raw, "path: .workflow-kit"
      assert_includes raw, "release_digest.rb\" --filesystem-root \"$KIT_ROOT"
    else
      assert_includes raw, "rev-parse HEAD"
      assert_includes raw, "release_digest.rb --repo .workflow-kit --ref HEAD"
    end
  end

  def test_spec_gate_binds_inputs_installation_and_pr_approval_evidence
    raw = File.read(WORKFLOW)
    permissions = workflow.fetch("permissions")
    assert_equal "read", permissions.fetch("contents")
    assert_equal "read", permissions.fetch("pull-requests")
    assert_includes raw, "JinxJEONG/ai-agentic-workflow-kit-public"
    assert_includes raw, "job_workflow_ref"
    assert_includes raw, "job_workflow_sha"
    assert_includes raw, 'test "$KIT_COMMIT" = "$workflow_sha"'
    assert_includes raw, "needs.trust-workflow-source.outputs.kit_commit"
    assert_includes raw, "^[0-9a-f]{40}$"
    assert_includes raw, "^sha256:[0-9a-f]{64}$"
    if private_source_step
      assert_includes raw, "runner_environment"
      assert_includes raw,
        'test "$workflow_ref" = "JinxJEONG/ai-agentic-workflow-kit-public/.github/workflows/spec-gate.yml@$KIT_COMMIT"'
      assert_includes raw, 'test "$runner_environment" = github-hosted'
      assert_includes raw, '--trusted-kit-root "$KIT_ROOT"'
      assert_includes raw, "--trusted-kit-source-mode action-source"
    else
      assert_includes raw, "--trusted-kit-root .workflow-kit"
    end
    assert_includes raw, "--expected-kit-commit"
    assert_includes raw, "git log --diff-filter=A --format=%H -- .ai/generated/adoption-receipt.json"
    assert_includes raw, 'test "${#receipt_commits[@]}" -eq 1'
    assert_includes raw, 'git diff --quiet "$receipt_commit" HEAD -- .ai/generated/adoption-receipt.json'
    if oidc_disable_confirmation_step
      assert_includes raw, 'adoption_receipt.rb verify --source "$receipt_commit"'
    else
      assert_match(
        %r{ruby\s+"\$KIT_ROOT/core/project-template/\.ai/runtime/scripts/adoption_receipt\.rb"\s+verify\s+--source\s+"\$receipt_commit"\s+\.},
        raw,
      )
      refute_match(%r{ruby\s+"?\.ai/runtime/scripts/}, raw)
    end
    refute_includes raw, "verify --source HEAD"
    assert_includes raw, "/pulls/$PR_NUMBER/reviews"
    assert_includes raw, "--github-event \"$GITHUB_EVENT_PATH\""
    assert_includes raw, "--github-repository \"$REPOSITORY\""
    assert_includes raw, "if [ \"$EVENT_NAME\" = pull_request ]"
  end

  def test_no_blank_env_workflow_collects_and_flattens_review_pages_separately
    return if oidc_disable_confirmation_step

    step = review_collection_step
    refute_nil step
    commands = logical_shell_commands(step.fetch("run"))

    if transitional_v048_review_collection?
      # B1 must test the already released v0.4.8 workflow unchanged. This
      # exact action-source pin is the only temporary exception; B2 changes
      # the pin and must use the compatible two-command form below.
      assert_equal 1, commands.length
      assert_match(/\Agh api\b/, commands.first)
      assert_match(/--slurp.*--jq/, commands.first)
      return
    end

    api_command = commands.find { |command| command.match?(/\Agh api\b/) }
    flatten_command = commands.find { |command| command.match?(/\Ajq\b/) }
    refute_nil api_command
    refute_nil flatten_command
    assert_includes api_command, "--paginate"
    assert_includes api_command, "--slurp"
    assert_includes api_command, "/pulls/$PR_NUMBER/reviews"
    assert_match(/>\s*"\$RUNNER_TEMP\/spec-gate-review-pages\.json"\z/, api_command)
    assert_match(
      /\Ajq\s+'add'\s+"\$RUNNER_TEMP\/spec-gate-review-pages\.json"\s+>\s+"\$RUNNER_TEMP\/spec-gate-reviews\.json"\z/,
      flatten_command,
    )

    commands.grep(/\Agh api\b/).each do |command|
      refute_match(
        /(?:--slurp.*(?:--jq|--template)|(?:--jq|--template).*--slurp)/,
        command,
        "gh api must not combine --slurp with --jq or --template",
      )
    end
  end

  def test_oidc_trust_is_bound_before_source_and_hidden_from_following_steps
    jobs = workflow.fetch("jobs")
    trust = jobs.fetch("trust-workflow-source")
    assert_equal "write", trust.fetch("permissions").fetch("id-token")
    refute trust.key?("needs")
    gate = jobs.fetch("spec-gate")
    assert_equal "trust-workflow-source", gate.fetch("needs")
    assert_equal "${{ always() }}", gate.fetch("if")
    trust_raw = trust.fetch("steps").map { |step| step["run"].to_s }.join("\n")
    assert_includes trust_raw, "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
    assert_includes trust_raw, "ai-agentic-workflow-kit-spec-gate"
    refute_match(/checkout|validate_spec_freshness|adapters\//, trust_raw)
    rejection = gate.fetch("steps").first
    assert_equal "needs.trust-workflow-source.result != 'success'", rejection.fetch("if")
    assert_equal "exit 1", rejection.fetch("run")

    if private_source_step
      assert_equal "write", gate.fetch("permissions").fetch("id-token")
      binding_index = spec_gate_steps.index { |step| step["id"] == "bind-validation-runner" }
      source_index = spec_gate_steps.index(private_source_step)
      refute_nil binding_index
      assert_operator binding_index, :<, source_index
      binding = spec_gate_steps.fetch(binding_index)
      assert_includes binding.fetch("run"), "runner_environment"
      assert_includes binding.fetch("run"), 'test "$runner_environment" = github-hosted'
      confirmation = oidc_disable_confirmation_step
      if confirmation
        spec_gate_steps[(binding_index + 1)..].each do |step|
          assert_equal "", step.fetch("env").fetch("ACTIONS_ID_TOKEN_REQUEST_URL"), step.fetch("name")
          assert_equal "", step.fetch("env").fetch("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), step.fetch("name")
        end
      else
        # v0.4.8 keeps the validation-runner OIDC binding as the main trust
        # boundary, then relies on central validators that never execute target
        # project code. No ineffective blank-env confirmation is accepted.
        raw = File.read(WORKFLOW)
        assert_includes binding.fetch("run"), "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
        install_step = spec_gate_steps.find do |step|
          step["run"].to_s.include?("validate_install.rb")
        end
        freshness_step = spec_gate_steps.find do |step|
          step["run"].to_s.include?("validate_spec_freshness.rb")
        end
        refute_nil install_step
        refute_nil freshness_step
        refute_equal install_step, freshness_step
        assert_match(
          /\A(?=.*validate_install\.rb)(?=.*--execution-profile hosted-no-project-code).+\z/m,
          install_step.fetch("run"),
        )
        assert_match(
          /\A(?=.*validate_spec_freshness\.rb)(?=.*--execution-profile hosted-no-project-code).+\z/m,
          freshness_step.fetch("run"),
        )
        refute_match(/Confirm the OIDC request channel is disabled/, raw)
      end
    else
      refute gate.fetch("permissions", {}).key?("id-token")
    end
  end

  def test_trusted_source_is_immutable_and_credentials_are_not_persisted
    source = private_source_step
    if source
      match = source.fetch("uses").match(
        %r{\AJinxJEONG/ai-agentic-workflow-kit-public/\.github/actions/spec-gate-source@([0-9a-f]{40})\z},
      )
      refute_nil match
      assert_equal match[1], source.fetch("with").fetch("expected-ref")
      assert_equal "${{ inputs.kit_bundle_digest }}",
        source.fetch("with").fetch("expected-bundle-digest")
      refute source.key?("if")
      refute source.key?("continue-on-error")

      checkout_index = spec_gate_steps.index do |step|
        step["uses"].to_s.start_with?("actions/checkout@")
      end
      assert_operator spec_gate_steps.index(source), :<, checkout_index
    else
      kit = spec_gate_steps.find do |step|
        step["uses"].to_s.start_with?("actions/checkout@") &&
          step.fetch("with", {}).key?("repository")
      end
      refute_nil kit
      assert_equal "${{ inputs.kit_repository }}", kit.fetch("with").fetch("repository")
      assert_equal "${{ needs.trust-workflow-source.outputs.kit_commit }}",
        kit.fetch("with").fetch("ref")
      assert_equal false, kit.fetch("with").fetch("persist-credentials")
    end
  end

  def test_project_checkout_does_not_persist_credentials
    checkouts = workflow.fetch("jobs").fetch("spec-gate").fetch("steps").select do |step|
      step["uses"].to_s.start_with?("actions/checkout@")
    end
    assert_equal(private_source_step ? 1 : 2, checkouts.length)
    checkouts.each { |step| assert_equal false, step.fetch("with").fetch("persist-credentials") }
    project = checkouts.find { |step| !step.fetch("with").key?("repository") }
    refute_nil project
    assert_equal "${{ github.event.pull_request.head.sha || github.sha }}", project.fetch("with").fetch("ref")
  end

  def test_ci_uses_immutable_actions_without_duplicate_feature_push_runs
    ci = load_workflow(CI_WORKFLOW)
    triggers = ci.fetch(true)
    assert_equal ["main"], triggers.fetch("push").fetch("branches")
    assert triggers.key?("pull_request")

    uses = ci.fetch("jobs").fetch("test").fetch("steps").map { |step| step["uses"] }.compact
    assert_includes uses, "actions/checkout@#{CHECKOUT_COMMIT}"
    assert_includes uses, "ruby/setup-ruby@#{SETUP_RUBY_COMMIT}"
    uses.each { |value| assert_match(/@[0-9a-f]{40}\z/, value) }
  end
end
