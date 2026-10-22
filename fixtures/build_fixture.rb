#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require "yaml"

require_relative "../engine/release/release_digest"
require_relative "../engine/release/dirty_snapshot"
require_relative "../installer/lib/install_integrity"
require_relative "../installer/lib/release_source"

module WorkflowKit
  # Builds synthetic repositories that model the migration states documented
  # in Phase 2. The repositories contain no copied application data and are
  # always created below a caller-owned disposable parent.
  module FixtureBuilder
    KIT_ROOT = File.realpath(File.expand_path("..", __dir__)).freeze
    BOOTSTRAP = File.join(KIT_ROOT, "engine", "install", "bootstrap_project.rb").freeze
    TYPES = %w[
      legacy-unknown managed-current managed-drifted blocked-active
      linked-worktree volatile-worktree isolation-alpha isolation-beta unknown-project
    ].freeze
    LEGACY_CANONICAL_PATHS = [
      ".ai/canonical/PROJECT_RULES.md",
      ".ai/canonical/architecture/README.md",
      ".ai/canonical/context-map.yaml",
    ].freeze
    BLOCKED_LOCK_COUNT = 6

    class FixtureError < StandardError; end

    module_function

    def run!(*command, chdir: nil, env: {})
      stdout, stderr, status = if chdir
        Open3.capture3(env, *command, chdir: chdir)
      else
        Open3.capture3(env, *command)
      end
      return stdout if status.success?

      detail = [stdout, stderr].reject(&:empty?).join("\n").strip
      raise FixtureError, "#{command.join(' ')} failed#{detail.empty? ? '' : ": #{detail}"}"
    rescue SystemCallError => error
      raise FixtureError, "cannot run #{command.first}: #{error.message}"
    end

    def build(type, parent: nil)
      raise ArgumentError, "unknown fixture #{type.inspect}" unless TYPES.include?(type)

      parent = resolve_parent(parent)
      container = Dir.mktmpdir("workflow-kit-#{type}-", parent)
      result = build_in(container, type)
      result = result.merge("metadata_path" => metadata_path(result))
      write_metadata(result)
      result
    rescue StandardError
      FileUtils.remove_entry(container) if container && File.exist?(container)
      raise
    end

    def build_in(container, type)
      case type
      when "linked-worktree"
        build_linked_fixture(container, volatile: false).merge(
          "release" => build_release(container, version: "0.4.0", identity: "linked-worktree-reviewed"),
        )
      when "volatile-worktree"
        build_linked_fixture(container, volatile: true).merge(
          "release" => build_release(container, version: "0.4.0", identity: "volatile-worktree-reviewed"),
        )
      else
        # Keep the repository basename equal to the fixture identity. The
        # installer binds its project_id to that basename, so using a generic
        # "project" directory would make the two isolation fixtures appear to
        # be the same project after apply.
        root = File.join(container, type)
        init_repository(root)
        seed_committed_state(root, type)
        installed_release = if managed_fixture?(type)
          value = build_release(container, version: "0.4.0", identity: "managed-baseline")
          install_release(root, value)
          value
        end
        release = if type == "managed-drifted"
          build_release(
            container,
            version: installed_release.fetch("version"),
            identity: "managed-template-drift",
            template_variant: "same-version-template-drift",
          )
        else
          installed_release
        end
        release ||= build_release(container, version: "0.4.0", identity: "#{type}-reviewed")
        seed_post_commit_state(root, type, release: release, installed_release: installed_release)
        value = result(type, container, root, [root]).merge("dirty_paths" => dirty_paths_for(type, root))
        value = value.merge("release" => release)
        value = value.merge("installed_release" => installed_release) if installed_release && release != installed_release
        value
      end
    end

    def managed_fixture?(type)
      ["managed-current", "managed-drifted"].include?(type)
    end

    # Create a small but complete pinnable release source. It contains VERSION
    # and the real project template, is addressed by the canonical full-bundle
    # digest, and keeps its archive, sidecar, and digest cache below +parent+.
    # This is public so lifecycle tests can create two independent releases
    # without tags or writes to the user's default cache.
    def build_release(parent, version:, identity: version, template_variant: nil)
      unless version.to_s.match?(/\A[0-9A-Za-z][0-9A-Za-z.+-]*\z/)
        raise FixtureError, "invalid synthetic release version #{version.inspect}"
      end
      unless identity.to_s.match?(/\A[0-9A-Za-z][0-9A-Za-z._-]*\z/)
        raise FixtureError, "invalid synthetic release identity #{identity.inspect}"
      end

      parent = resolve_parent(parent)
      release_dir = File.join(parent, "release-#{identity}")
      raise FixtureError, "synthetic release already exists: #{release_dir}" if File.exist?(release_dir)

      root = File.join(release_dir, "ai-agentic-workflow-kit-#{version}")
      FileUtils.mkdir_p(File.join(root, "core"))
      FileUtils.cp_r(
        File.join(KIT_ROOT, "core", "project-template"),
        File.join(root, "core", "project-template"),
      )
      write(root, "VERSION", "#{version}\n")
      write(root, ".fixture-release-id", "#{identity}\n")
      if template_variant
        variant_path = [
          ".ai/scripts/collect_context.rb",
          ".ai/runtime/scripts/collect_context.rb",
        ].find { |relative| File.file?(File.join(root, "core", "project-template", relative)) }
        raise FixtureError, "synthetic release template has no collect_context.rb" unless variant_path

        append(
          File.join(root, "core", "project-template"),
          variant_path,
          "\n# synthetic release variant: #{template_variant}\n",
        )
      end

      excludes = WorkflowKit::Release::ReleaseDigest::DEFAULT_EXCLUDES
      digest = "sha256:#{WorkflowKit::Release::ReleaseDigest.digest_from_directory(root, excludes: excludes)}"
      auxiliary = WorkflowKit::Release::ReleaseDigest.auxiliary_digests_from_directory(root)
        .each_with_object({}) { |(name, value), result| result[name] = "sha256:#{value}" }
      archive = File.join(release_dir, "ai-agentic-workflow-kit-#{version}.tar.gz")
      run!("tar", "-czf", archive, "-C", release_dir, File.basename(root))
      manifest_path = File.join(release_dir, "ai-agentic-workflow-kit-#{version}.manifest.json")
      manifest = {
        "manifest_schema" => 2,
        "kit_version" => version,
        "release_ref" => "refs/tags/v#{version}",
        "release_commit" => Digest::SHA1.hexdigest("fixture-release:#{identity}:#{version}"),
        "pinnable" => true,
        "bundle_digest_algo" => WorkflowKit::Release::ReleaseDigest::BUNDLE_DIGEST_ALGO,
        "kit_bundle_digest" => digest,
        "excluded_paths" => excludes,
        "auxiliary_digests" => auxiliary,
        "rendered_digest_algo" => WorkflowKit::Install::Integrity::RENDERED_DIGEST_ALGO,
        "dirty_snapshot_algo" => WorkflowKit::Release::DirtySnapshot::DIRTY_SNAPSHOT_ALGO,
        "ownership_rules" => WorkflowKit::Install::Integrity::DEFAULT_OWNERSHIP_RULES,
        "protected_paths" => WorkflowKit::Install::Integrity::DEFAULT_PROTECTED_PATHS,
        "approval_required_paths" => WorkflowKit::Install::Integrity::DEFAULT_APPROVAL_REQUIRED_PATHS,
        "tombstones" => [],
        "source" => {
          "kind" => "local",
          "locator" => WorkflowKit::Install::ReleaseSource.file_uri(archive),
          "manifest_locator" => WorkflowKit::Install::ReleaseSource.file_uri(manifest_path),
          "bundle_archive_sha256" => "sha256:#{Digest::SHA256.file(archive).hexdigest}",
        },
        "provenance" => {
          "source_clean" => true,
          "source_tagged" => true,
          "synthetic_fixture" => true,
        },
      }
      File.open(manifest_path, "wb") do |file|
        file.write(JSON.pretty_generate(manifest))
        file.write("\n")
      end
      manifest_digest = "sha256:#{Digest::SHA256.file(manifest_path).hexdigest}"

      {
        "version" => version,
        "identity" => identity,
        "root" => root,
        "archive" => archive,
        "manifest" => manifest_path,
        "manifest_digest" => manifest_digest,
        "digest" => digest,
        "template_digest" => auxiliary.fetch("template_tree_digest"),
        "cache" => File.join(parent, "release-cache"),
      }
    rescue WorkflowKit::Release::ReleaseDigest::DigestError => error
      raise FixtureError, "cannot build synthetic release: #{error.message}"
    end

    def install_release(root, release)
      source_options = [
        "--source-manifest", release.fetch("manifest"),
        "--expected-kit-bundle-digest", release.fetch("digest"),
        "--expected-release-manifest-digest", release.fetch("manifest_digest"),
      ]
      env = { "KIT_RELEASE_CACHE" => release.fetch("cache") }
      plan_output = run!(
        RbConfig.ruby,
        BOOTSTRAP,
        "--dry-run",
        "--json",
        *source_options,
        root,
        env: env,
      )
      plan = JSON.parse(plan_output)
      run!(
        RbConfig.ruby,
        BOOTSTRAP,
        "--json",
        *source_options,
        "--plan-digest",
        plan.fetch("plan_digest"),
        root,
        env: env,
      )
    rescue JSON::ParserError, KeyError => error
      raise FixtureError, "cannot install synthetic release: #{error.message}"
    end

    def resolve_parent(parent)
      path = File.expand_path(parent || Dir.tmpdir)
      FileUtils.mkdir_p(path)
      raise FixtureError, "fixture parent must be a directory: #{path}" unless File.directory?(path)

      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES => error
      raise FixtureError, "cannot prepare fixture parent: #{error.message}"
    end

    def init_repository(root)
      FileUtils.mkdir_p(root)
      run!("git", "init", "-b", "main", root)
      configure_repository(root)
    end

    def configure_repository(root)
      run!("git", "config", "user.name", "Workflow Kit Fixture", chdir: root)
      run!("git", "config", "user.email", "fixture@example.invalid", chdir: root)
    end

    def seed_committed_state(root, type)
      write_project_map(root, type)
      write(root, "README.md", "# #{type}\n\nSynthetic workflow-kit fixture.\n")

      case type
      when "legacy-unknown"
        seed_legacy_baseline(root)
      when "managed-current", "managed-drifted"
        seed_managed_marker(root, type)
      when "blocked-active"
        seed_blocked_baseline(root)
      when "isolation-alpha", "isolation-beta"
        side = type.sub("isolation-", "")
        write(root, ".env.example", "#{side.upcase}_ONLY_VAR=fixture-only\nSHARED_VAR=shared\n")
        write(root, "config/#{side}.txt", "database=#{side}_db\napi_prefix=/api/#{side}\n")
      when "unknown-project"
        write(root, ".ai/canonical/PROJECT_RULES.md", "# Facts require human discovery\n")
      end

      commit_all(root, "fixture baseline: #{type}")
    end

    def seed_post_commit_state(root, type, release: nil, installed_release: nil)
      case type
      when "legacy-unknown"
        # Three canonical files diverge from their committed baseline, plus two
        # unrelated dirty files. There is deliberately no installation lock.
        LEGACY_CANONICAL_PATHS.each_with_index do |path, index|
          append(root, path, "\nLocal legacy decision #{index + 1}.\n")
        end
        write(root, "apps/newsroom/dirty-one.txt", "uncommitted legacy work one\n")
        write(root, "apps/newsroom/dirty-two.txt", "uncommitted legacy work two\n")
      when "blocked-active"
        write_blocked_activity(root)
      when "managed-drifted"
        write(root, ".fixture/template-tree-digest", YAML.dump({
          "kit_version" => release.fetch("version"),
          "installed" => installed_release.fetch("template_digest"),
          "candidate" => release.fetch("template_digest"),
        }))
      end
    end

    def seed_legacy_baseline(root)
      # These entrypoints already match the release baseline. The legacy
      # divergence is deliberately limited to the three project-owned
      # canonical files below; otherwise validation would correctly require a
      # separate review/staging step for tracked kit-owned changes.
      write(root, "AGENTS.md", template_file("AGENTS.md"))
      write(root, ".githooks/pre-commit", template_file(".ai/runtime/githooks/pre-commit"), mode: 0o755)
      write(root, ".ai/canonical/PROJECT_RULES.md", "# Legacy project rules\n")
      write(root, ".ai/canonical/architecture/README.md", "# Legacy architecture\n")
      write(root, ".ai/canonical/context-map.yaml", YAML.dump({ "contexts" => [] }))
      write(root, ".ai/tasks/README.md", "# Legacy tasks\n")
    end

    def template_file(relative)
      File.binread(File.expand_path(File.join("..", "core", "project-template", relative), __dir__))
    rescue Errno::ENOENT, Errno::EACCES => error
      raise FixtureError, "cannot read fixture template #{relative}: #{error.message}"
    end

    def seed_managed_marker(root, type)
      marker = {
        "fixture_state" => type,
        "schema_version" => 2,
        "installation_state" => "managed",
        "expected_kit_version" => type == "managed-current" ? "current" : "same-version-drift",
        "expected_installed_files" => "exact",
      }
      write(root, ".fixture/managed-seed.yaml", YAML.dump(marker))
    end

    def seed_blocked_baseline(root)
      write(root, ".ai/tasks/FEATURE-20260813-001/feature.yaml", YAML.dump({
        "feature_id" => "FEATURE-20260813-001",
        "status" => "in_progress",
      }))
    end

    def write_blocked_activity(root)
      active = {
        "schema_version" => 2,
        "status" => "streams_in_progress",
        "active_streams" => [
          { "feature_id" => "FEATURE-20260813-001", "stream_id" => "backend-dev" },
        ],
      }
      write(root, ".ai/ACTIVE_CONTEXT.yaml", YAML.dump(active))
      BLOCKED_LOCK_COUNT.times do |index|
        write(
          root,
          format(".ai/tasks/FEATURE-20260813-001/stream-%02d/LOCK.yaml", index + 1),
          YAML.dump({ "feature_id" => "FEATURE-20260813-001", "stream_id" => index + 1 }),
        )
      end
    end

    def build_linked_fixture(container, volatile:)
      type = volatile ? "volatile-worktree" : "linked-worktree"
      primary = File.join(container, type)
      linked = File.join(container, volatile ? "volatile-worktree-linked" : "public-preview")
      init_repository(primary)
      write_project_map(primary, type)
      write(primary, "README.md", "# #{type}\n")
      write(primary, "shared.txt", "committed shared state\n")
      commit_all(primary, "fixture baseline: #{type}")
      run!("git", "worktree", "add", "-b", "fixture-linked", linked, chdir: primary)
      configure_repository(linked)

      if volatile
        write(linked, "shared.txt", "dirty linked-worktree content\n")
        write(linked, "volatile-untracked.txt", "untracked linked-worktree content\n")
      end

      result(type, container, primary, [primary, linked]).merge(
        "primary" => primary,
        "linked" => linked,
        "volatile" => volatile,
      )
    end

    def write_project_map(root, type)
      id = type
      services = if type == "unknown-project"
        {}
      elsif type.start_with?("isolation-")
        side = type.sub("isolation-", "")
        {
          "#{side}_api" => {
            "path" => ".",
            "role" => "api",
            "api_prefix" => "/api/#{side}",
            "database" => "#{side}_db",
          },
        }
      else
        { "app" => { "path" => ".", "role" => "app" } }
      end

      project_map = {
        "schema_version" => 1,
        "project_id" => id,
        "workspace" => { "name" => id, "root" => File.realpath(root) },
        "services" => services,
      }
      # The unknown fixture isolates the "approved but incomplete" case. Its
      # empty service map must trigger the no-inference guard, rather than the
      # separate approval-state guard used by draft fixtures.
      project_map["status"] = "approved" if type == "unknown-project"
      if type.start_with?("isolation-")
        side = type.sub("isolation-", "")
        project_map["database"] = "#{side}_db"
        project_map["api_prefix"] = "/api/#{side}"
      end
      write(root, ".ai/canonical/PROJECT_MAP.yaml", YAML.dump(project_map))
    end

    def write(root, relative, content, mode: 0o644)
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "wb") { |file| file.write(content) }
      File.chmod(mode, path)
      path
    end

    def append(root, relative, content)
      path = File.join(root, relative)
      File.open(path, "ab") { |file| file.write(content) }
    end

    def commit_all(root, message)
      run!("git", "add", ".", chdir: root)
      run!("git", "commit", "--no-verify", "-m", message, chdir: root)
    end

    def git(root, *arguments)
      run!("git", *arguments, chdir: root).strip
    end

    def result(type, container, root, worktrees)
      {
        "type" => type,
        "container" => container,
        "path" => root,
        "worktrees" => worktrees,
        "baseline_commit" => git(root, "rev-parse", "HEAD"),
      }
    end

    def dirty_paths_for(type, root = nil)
      case type
      when "legacy-unknown"
        LEGACY_CANONICAL_PATHS + [
          "apps/newsroom/dirty-one.txt",
          "apps/newsroom/dirty-two.txt",
        ]
      when "managed-drifted"
        [".fixture/template-tree-digest"]
      when "blocked-active"
        [".ai/ACTIVE_CONTEXT.yaml"] + Array.new(BLOCKED_LOCK_COUNT) do |index|
          format(".ai/tasks/FEATURE-20260813-001/stream-%02d/LOCK.yaml", index + 1)
        end
      else
        []
      end
    end

    def metadata_path(result_value)
      File.join(result_value.fetch("container"), "fixture.json")
    end

    def write_metadata(result_value)
      metadata = result_value.merge(
        "container" => File.realpath(result_value.fetch("container")),
        "path" => File.realpath(result_value.fetch("path")),
        "worktrees" => result_value.fetch("worktrees").map { |path| File.realpath(path) },
      )
      File.open(metadata_path(result_value), "wb") do |file|
        file.write(JSON.pretty_generate(metadata))
        file.write("\n")
      end
      result_value.merge("metadata_path" => metadata_path(result_value))
    end

    def cleanup(value)
      container = value.is_a?(Hash) ? value["container"] : value
      return unless container && File.exist?(container)

      expanded = File.expand_path(container)
      basename = File.basename(expanded)
      unless basename.start_with?("workflow-kit-") && expanded != File::SEPARATOR && !File.symlink?(expanded)
        raise FixtureError, "refusing to remove a non-fixture path: #{expanded}"
      end

      FileUtils.remove_entry(expanded)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: build_fixture.rb [--parent DIR] TYPE"
    opts.on("--parent DIR", "Create the disposable fixture below DIR") { |value| options[:parent] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.length == 1

  begin
    puts JSON.generate(WorkflowKit::FixtureBuilder.build(ARGV.first, parent: options[:parent]))
  rescue ArgumentError, WorkflowKit::FixtureBuilder::FixtureError => error
    warn error.message
    exit 40
  end
end
