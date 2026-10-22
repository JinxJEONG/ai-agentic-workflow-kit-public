# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

require_relative "../fixtures/build_fixture"

module WorkflowKitTestHelpers
  KIT_ROOT = File.expand_path("..", __dir__)
  BOOTSTRAP = File.join(KIT_ROOT, "engine", "install", "bootstrap_project.rb")
  FIXTURES_ROOT = File.join(KIT_ROOT, "fixtures")
  GIT_ADMIN_DIR = begin
    output, status = Open3.capture2(
      { "GIT_OPTIONAL_LOCKS" => "0" },
      "git", "-C", KIT_ROOT, "rev-parse", "--absolute-git-dir",
    )
    raise "cannot resolve Git admin directory for test lock" unless status.success?

    File.realpath(output.strip)
  end
  TEST_SUITE_LOCK_PATH = File.join(GIT_ADMIN_DIR, "workflow-kit-test-suite.lock")
  begin
    TEST_SUITE_LOCK = File.open(
      TEST_SUITE_LOCK_PATH,
      File::RDWR | File::CREAT,
      0o600,
    )
    TEST_SUITE_LOCK.close_on_exec = true
    unless TEST_SUITE_LOCK.flock(File::LOCK_EX | File::LOCK_NB)
      warn "ERROR: another test suite is already using #{KIT_ROOT}; use a disposable clone for parallel tests"
      exit 75
    end
  rescue SystemCallError, NotImplementedError => error
    warn "ERROR: cannot establish test-suite isolation lock: #{error.class}: #{error.message}"
    exit 75
  end

  TEST_RELEASE_PARENT = Dir.mktmpdir("workflow-kit-reviewed-release-")
  TEST_RELEASE = WorkflowKit::FixtureBuilder.build_release(
    TEST_RELEASE_PARENT,
    version: File.read(File.join(KIT_ROOT, "VERSION")).strip,
    identity: "test-suite-reviewed",
  ).freeze
  at_exit do
    FileUtils.remove_entry(TEST_RELEASE_PARENT) if File.exist?(TEST_RELEASE_PARENT)
  end

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
    def success?
      status.success?
    end

    def combined
      [stdout, stderr].reject(&:empty?).join("\n")
    end
  end

  def run_command(*command, chdir: KIT_ROOT, stdin_data: "", env: {})
    command_env = reviewed_release_env.merge(env)
    stdout, stderr, status = Open3.capture3(command_env, *command, chdir: chdir, stdin_data: stdin_data)
    CommandResult.new(stdout: stdout, stderr: stderr, status: status)
  end

  def run!(*command, **options)
    result = run_command(*command, **options)
    assert result.success?, "command failed: #{command.join(' ')}\n#{result.combined}"
    result
  end

  def with_project(prefix: "workflow-kit-test", parent: nil, quoted: false)
    FileUtils.mkdir_p(FIXTURES_ROOT)
    base = Dir.mktmpdir(prefix, parent || FIXTURES_ROOT)
    path = base
    if quoted
      path = "#{base}'project"
      FileUtils.mv(base, path)
    end

    run!("git", "init", "-b", "main", path)
    run!("git", "config", "user.name", "Workflow Kit Test", chdir: path)
    run!("git", "config", "user.email", "workflow-kit@example.invalid", chdir: path)
    run!("git", "config", "maintenance.auto", "false", chdir: path)
    run!("git", "config", "gc.auto", "0", chdir: path)
    yield path
  ensure
    FileUtils.remove_entry(path, true) if path && File.exist?(path)
    FileUtils.remove_entry(base, true) if base && base != path && File.exist?(base)
  end

  def bootstrap!(path, *options)
    plan = bootstrap_plan(path, *options)
    assert plan.success?, "bootstrap plan failed:\n#{plan.combined}"
    payload = JSON.parse(plan.stdout)
    digest = payload.fetch("plan_digest")
    run!(RbConfig.ruby, BOOTSTRAP, *reviewed_release_options, *options, "--plan-digest", digest, path)
  end

  def bootstrap_plan(path, *options)
    run_command(RbConfig.ruby, BOOTSTRAP, "--dry-run", "--json", *reviewed_release_options, *options, path)
  end

  def apply_reviewed(path, *options)
    plan = bootstrap_plan(path, *options)
    return plan unless plan.success?

    digest = JSON.parse(plan.stdout).fetch("plan_digest")
    run_command(RbConfig.ruby, BOOTSTRAP, "--json", *reviewed_release_options, *options, "--plan-digest", digest, path)
  end

  def reviewed_release
    TEST_RELEASE
  end

  def reviewed_release_options(release = reviewed_release)
    [
      "--source-manifest", release.fetch("manifest"),
      "--expected-kit-bundle-digest", release.fetch("digest"),
      "--expected-release-manifest-digest", release.fetch("manifest_digest"),
    ]
  end

  def reviewed_release_env(release = reviewed_release)
    { "KIT_RELEASE_CACHE" => release.fetch("cache") }
  end

  def script(path, name)
    File.join(path, ".ai", "runtime", "scripts", name)
  end

  def load_yaml(path)
    YAML.load_file(path)
  end

  def write_yaml(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, value.to_yaml(line_width: -1))
  end

  def write_file(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def feature_dir(path)
    Dir[File.join(path, ".ai", "tasks", "FEATURE-*")].sort.last
  end

  def feature_id(path)
    File.basename(feature_dir(path)).split("--", 2).first
  end

  def commit_all!(path, message = "baseline")
    run!("git", "add", ".", chdir: path)
    run!("git", "commit", "--no-verify", "-m", message, chdir: path)
  end

  def create_feature!(path, tier:, title:)
    run!(RbConfig.ruby, script(path, "create_feature.rb"), "--tier", tier, title, chdir: path)
    feature_id(path)
  end
end

require "minitest/autorun"

class Minitest::Test
  include WorkflowKitTestHelpers
end
