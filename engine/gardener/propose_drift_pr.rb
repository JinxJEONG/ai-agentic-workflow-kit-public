#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "time"

module WorkflowKit
  module Gardener
    ALLOWLIST = [
      ".ai/generated/**",
      ".ai/runtime/**",
      ".ai/KIT_INSTALLATION.yaml",
    ].freeze
    APPROVAL_REQUIRED = ["AGENTS.md"].freeze
    REVIEW_BRANCH_PREFIX = "automation/harness-drift".freeze
    PLAN_DIGEST_ALGO = 1
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze

    module_function

    def glob_match?(path, pattern)
      File.fnmatch?(pattern, path, File::FNM_DOTMATCH | File::FNM_EXTGLOB | File::FNM_PATHNAME)
    end

    def safe_path?(path)
      value = path.to_s
      return false if value.empty? || Pathname.new(value).absolute? || value.split(/[\\\/]/).include?("..")
      return false if APPROVAL_REQUIRED.include?(value)
      ALLOWLIST.any? { |pattern| glob_match?(value, pattern) }
    end

    def canonical_object(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical_object(value.fetch(original))
        end
      when Array
        value.map { |entry| canonical_object(entry) }
      when String, Integer, TrueClass, FalseClass, NilClass
        value
      else
        raise ArgumentError, "gardener plan cannot serialize #{value.class}"
      end
    end

    def plan_digest_payload(value)
      raise ArgumentError, "gardener plan must be a mapping" unless value.is_a?(Hash)

      changes = Array(value["changes"]).map do |change|
        raise ArgumentError, "gardener plan change must be a mapping" unless change.is_a?(Hash)

        %w[path state reason sha256 content].each_with_object({}) do |field, result|
          result[field] = change[field] if change.key?(field)
        end
      end
      changes.sort_by! do |change|
        [change["path"].to_s.b, change["state"].to_s.b, change["sha256"].to_s.b]
      end
      {
        "plan_digest_algo" => value["plan_digest_algo"],
        "base" => value["base"],
        "valid" => value["valid"],
        "changes" => changes,
      }
    end

    def canonical_plan_digest(value)
      material = JSON.generate(canonical_object(plan_digest_payload(value)))
      "sha256:#{Digest::SHA256.hexdigest(material)}"
    end

    def plan_base(base_branch, base_commit)
      branch = base_branch.to_s
      commit = base_commit.to_s
      raise ArgumentError, "gardener plan requires a reviewed base branch" if branch.empty?
      unless commit.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
        raise ArgumentError, "gardener plan requires a full lowercase base commit"
      end

      { "branch" => branch, "commit" => commit }
    end

    def plan(changes, base_branch:, base_commit:)
      normalized = Array(changes).map do |change|
        next { "path" => nil, "state" => "refused", "reason" => "change must be a mapping" } unless change.is_a?(Hash)
        path = change["path"].to_s
        content = change["content"]
        if !safe_path?(path)
          { "path" => path, "state" => "refused", "reason" => "path is outside the gardener allowlist" }
        elsif !content.is_a?(String)
          { "path" => path, "state" => "refused", "reason" => "content must be a string" }
        else
          { "path" => path, "state" => "proposed", "sha256" => "sha256:#{Digest::SHA256.hexdigest(content)}", "content" => content }
        end
      end
      duplicate_paths = normalized.select { |change| change["state"] == "proposed" }
        .group_by { |change| change["path"] }
        .select { |_path, entries| entries.length > 1 }
        .keys
      normalized.each do |change|
        next unless duplicate_paths.include?(change["path"])

        change["state"] = "refused"
        change["reason"] = "duplicate destination path"
      end
      normalized.sort_by! { |change| [change["path"].to_s.b, change["state"].to_s.b] }
      payload = {
        "plan_digest_algo" => PLAN_DIGEST_ALGO,
        "base" => plan_base(base_branch, base_commit),
        "valid" => !normalized.empty? && normalized.all? { |change| change["state"] == "proposed" },
        "changes" => normalized,
      }
      payload["plan_digest"] = canonical_plan_digest(payload)
      payload
    end

    def git(root, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?
      stdout.strip
    end

    def git_optional(root, *arguments)
      stdout, _stderr, status = Open3.capture3("git", "-C", root, *arguments)
      status.success? ? stdout.strip : nil
    end

    def git_top_level(path)
      root = File.realpath(path)
      top = File.realpath(git(root, "rev-parse", "--show-toplevel"))
      raise ArgumentError, "target must be a Git top-level" unless top == root

      root
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ArgumentError, "cannot resolve Git top-level: #{error.message}"
    end

    def resolved_git_path(root, value)
      candidate = value.start_with?(File::SEPARATOR) ? value : File.expand_path(value, root)
      File.realpath(candidate)
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ArgumentError, "cannot resolve Git metadata path: #{error.message}"
    end

    def assert_linked_worktree!(root)
      git_dir = resolved_git_path(root, git(root, "rev-parse", "--git-dir"))
      common_dir = resolved_git_path(root, git(root, "rev-parse", "--git-common-dir"))
      prefix = common_dir.end_with?(File::SEPARATOR) ? common_dir : "#{common_dir}#{File::SEPARATOR}"
      unless git_dir != common_dir && git_dir.start_with?("#{prefix}worktrees#{File::SEPARATOR}")
        raise ArgumentError, "gardener requires a separate linked worktree; the primary checkout is forbidden"
      end

      true
    end

    def validate_branch_name!(root, branch)
      value = branch.to_s
      raise ArgumentError, "branch name is required" if value.empty?

      git(root, "check-ref-format", "--branch", value)
      value
    end

    def reviewed_base_commit!(root, base_branch, expected_base_commit)
      branch = validate_branch_name!(root, base_branch)
      expected = expected_base_commit.to_s
      unless expected.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
        raise ArgumentError, "expected base commit must be a full lowercase object id"
      end
      resolved_expected = git(root, "rev-parse", "--verify", "#{expected}^{commit}")
      raise ArgumentError, "expected base commit is not canonical" unless resolved_expected == expected

      base_commit = git(root, "rev-parse", "--verify", "refs/heads/#{branch}^{commit}")
      raise ArgumentError, "base branch moved since review" unless base_commit == expected

      base_commit
    end

    def verify_plan!(value, expected_plan_digest, base_branch:, expected_base_commit:)
      expected = expected_plan_digest.to_s
      raise ArgumentError, "apply requires an explicit expected_plan_digest" unless expected.match?(DIGEST_PATTERN)
      raise ArgumentError, "gardener plan must be a mapping" unless value.is_a?(Hash)
      raise ArgumentError, "unsupported gardener plan digest algorithm" unless value["plan_digest_algo"] == PLAN_DIGEST_ALGO
      raise ArgumentError, "refused changes are present" unless value["valid"] == true

      actual = canonical_plan_digest(value)
      stored = value["plan_digest"].to_s
      raise ArgumentError, "gardener plan digest is missing or invalid" unless stored.match?(DIGEST_PATTERN)
      raise ArgumentError, "gardener plan was mutated after planning" unless stored == actual
      raise ArgumentError, "gardener plan does not match the reviewed digest" unless expected == actual
      reviewed_base = value["base"]
      unless reviewed_base.is_a?(Hash) &&
          reviewed_base["branch"] == base_branch &&
          reviewed_base["commit"] == expected_base_commit
        raise ArgumentError, "gardener plan does not match the reviewed base branch and commit"
      end

      changes = value["changes"]
      raise ArgumentError, "gardener plan must contain changes" unless changes.is_a?(Array) && !changes.empty?
      paths = changes.map do |change|
        raise ArgumentError, "gardener plan change must be a mapping" unless change.is_a?(Hash)
        raise ArgumentError, "gardener plan contains a non-proposed change" unless change["state"] == "proposed"
        raise ArgumentError, "gardener plan path is outside the allowlist" unless safe_path?(change["path"])
        content = change["content"]
        raise ArgumentError, "gardener plan content must be a string" unless content.is_a?(String)
        expected_content = "sha256:#{Digest::SHA256.hexdigest(content)}"
        unless change["sha256"] == expected_content
          raise ArgumentError, "gardener plan content digest mismatch for #{change['path']}"
        end
        change["path"]
      end
      raise ArgumentError, "gardener plan contains duplicate paths" unless paths.uniq.length == paths.length

      actual
    end

    def assert_safe_destination!(root, relative)
      destination = File.expand_path(relative, root)
      unless destination.start_with?("#{root}/")
        raise ArgumentError, "destination escapes the worktree"
      end

      cursor = File.dirname(destination)
      loop do
        if File.symlink?(cursor)
          raise ArgumentError, "destination has a symbolic-link ancestor"
        end
        break if cursor == root

        parent = File.dirname(cursor)
        unless parent.start_with?("#{root}/") || parent == root
          raise ArgumentError, "destination escapes the worktree"
        end
        cursor = parent
      end
      if File.symlink?(destination) || (File.exist?(destination) && !File.file?(destination))
        raise ArgumentError, "destination is not a regular file"
      end
      destination
    end

    def destination_snapshot(destination)
      if File.exist?(destination)
        {
          exists: true,
          content: File.binread(destination),
          mode: File.stat(destination).mode & 0o7777,
        }
      else
        { exists: false, content: nil, mode: nil }
      end
    end

    def atomic_replace(destination, content, mode)
      directory = File.dirname(destination)
      FileUtils.mkdir_p(directory)
      temporary = File.join(
        directory,
        ".#{File.basename(destination)}.gardener-#{Process.pid}-#{SecureRandom.hex(6)}.tmp",
      )
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(content)
          file.flush
          file.fsync
        end
        File.chmod(mode, temporary)
        File.rename(temporary, destination)
      ensure
        FileUtils.rm_f(temporary) if File.exist?(temporary)
      end
    end

    def rollback_destinations(root, attempted)
      errors = []
      attempted.reverse_each do |item|
        destination = item.fetch(:destination)
        snapshot = item.fetch(:snapshot)
        begin
          assert_safe_destination!(root, item.fetch(:change).fetch("path"))
          if snapshot.fetch(:exists)
            atomic_replace(destination, snapshot.fetch(:content), snapshot.fetch(:mode))
          else
            FileUtils.rm_f(destination)
          end
        rescue StandardError => error
          errors << "#{item.fetch(:change).fetch('path')}: #{error.message}"
        end
      end
      errors
    end

    def apply(worktree, base_branch, plan, expected_base_commit:, expected_plan_digest:)
      reviewed_plan_digest = verify_plan!(
        plan,
        expected_plan_digest,
        base_branch: base_branch,
        expected_base_commit: expected_base_commit,
      )
      root = git_top_level(worktree)
      assert_linked_worktree!(root)
      branch = git_optional(root, "symbolic-ref", "--quiet", "--short", "HEAD")
      raise ArgumentError, "detached worktree is not allowed" if branch.to_s.empty?
      raise ArgumentError, "gardener refuses to write the base branch" if branch == base_branch
      unless branch == REVIEW_BRANCH_PREFIX || branch.start_with?("#{REVIEW_BRANCH_PREFIX}/")
        raise ArgumentError, "gardener requires a dedicated #{REVIEW_BRANCH_PREFIX} review branch"
      end

      branch_head = git(root, "rev-parse", "HEAD")
      base_head = reviewed_base_commit!(root, base_branch, expected_base_commit)
      raise ArgumentError, "review branch is not based exactly on the reviewed base" unless branch_head == base_head

      destinations = plan["changes"].map do |change|
        destination = assert_safe_destination!(root, change["path"])
        {
          change: change,
          destination: destination,
          snapshot: destination_snapshot(destination),
        }
      end

      written = []
      attempted = []
      begin
        destinations.each do |item|
          change = item.fetch(:change)
          destination = assert_safe_destination!(root, change.fetch("path"))
          attempted << item
          mode = item.fetch(:snapshot).fetch(:exists) ? item.fetch(:snapshot).fetch(:mode) : 0o644
          atomic_replace(destination, change.fetch("content"), mode)
          written << change.fetch("path")
        end
      rescue StandardError => error
        rollback_errors = rollback_destinations(root, attempted)
        unless rollback_errors.empty?
          raise ArgumentError,
            "gardener apply failed (#{error.message}); rollback also failed: #{rollback_errors.join('; ')}"
        end
        raise error
      end
      {
        "status" => "applied_to_review_branch",
        "branch" => branch,
        "base_branch" => base_branch,
        "base_commit" => base_head,
        "plan_digest" => reviewed_plan_digest,
        "written" => written,
        "external_pr_required" => true,
      }
    end

    def prepare_maintenance_root(repository, maintenance_root)
      expanded = File.expand_path(maintenance_root.to_s)
      raise ArgumentError, "maintenance root is required" if maintenance_root.to_s.empty?
      raise ArgumentError, "maintenance root must not be a symbolic link" if File.symlink?(expanded)

      FileUtils.mkdir_p(expanded, mode: 0o700)
      raise ArgumentError, "maintenance root must not be a symbolic link" if File.symlink?(expanded)
      root = File.realpath(expanded)
      repository_prefix = repository.end_with?(File::SEPARATOR) ? repository : "#{repository}#{File::SEPARATOR}"
      if root == repository || root.start_with?(repository_prefix)
        raise ArgumentError, "maintenance root must be outside the repository"
      end
      root
    rescue Errno::ENOENT, Errno::EACCES => error
      raise ArgumentError, "cannot prepare maintenance root: #{error.message}"
    end

    def remove_maintenance_worktree(repository, worktree)
      _stdout, stderr, status = Open3.capture3(
        "git", "-C", repository, "worktree", "remove", "--force", worktree,
      )
      raise ArgumentError, "cannot remove maintenance worktree: #{stderr.strip}" unless status.success?

      true
    end

    def apply_in_maintenance_worktree(repository:, maintenance_root:, base_branch:, plan:,
        expected_base_commit:, expected_plan_digest:, branch_name: nil)
      source = git_top_level(repository)
      base_commit = reviewed_base_commit!(source, base_branch, expected_base_commit)
      verify_plan!(
        plan,
        expected_plan_digest,
        base_branch: base_branch,
        expected_base_commit: base_commit,
      )
      root = prepare_maintenance_root(source, maintenance_root)
      suffix = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{SecureRandom.hex(4)}"
      branch = branch_name || "#{REVIEW_BRANCH_PREFIX}/#{suffix}"
      validate_branch_name!(source, branch)
      unless branch == REVIEW_BRANCH_PREFIX || branch.start_with?("#{REVIEW_BRANCH_PREFIX}/")
        raise ArgumentError, "maintenance branch must use the #{REVIEW_BRANCH_PREFIX} prefix"
      end
      worktree = File.join(root, "#{File.basename(source).gsub(/[^A-Za-z0-9._-]/, '-')}-#{suffix}")

      result = nil
      operation_error = nil
      cleanup_error = nil
      added = false
      begin
        git(source, "worktree", "add", "--quiet", "-b", branch, worktree, base_commit)
        added = true
        result = apply(
          worktree,
          base_branch,
          plan,
          expected_base_commit: base_commit,
          expected_plan_digest: expected_plan_digest,
        )
      rescue StandardError => error
        operation_error = error
      ensure
        if added
          begin
            remove_maintenance_worktree(source, worktree)
          rescue StandardError => error
            cleanup_error = error
          end
        end
      end

      if operation_error
        if cleanup_error
          raise ArgumentError,
            "maintenance operation failed (#{operation_error.message}); cleanup failed: #{cleanup_error.message}"
        end
        raise operation_error
      end
      raise cleanup_error if cleanup_error

      result.merge(
        "maintenance_worktree" => worktree,
        "maintenance_worktree_removed" => true,
        "commit_performed" => false,
        "push_performed" => false,
        "pr_created" => false,
      )
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: propose_drift_pr.rb --changes FILE [apply options]"
    opts.on("--changes FILE") { |value| options[:changes] = value }
    opts.on("--apply-to WORKTREE") { |value| options[:worktree] = value }
    opts.on("--repository PATH", "Repository used to create a local maintenance worktree") { |value| options[:repository] = value }
    opts.on("--maintenance-root PATH", "Caller-owned root for the temporary linked worktree") { |value| options[:maintenance_root] = value }
    opts.on("--review-branch BRANCH", "Optional dedicated automation/harness-drift branch") { |value| options[:branch_name] = value }
    opts.on("--base BRANCH") { |value| options[:base] = value }
    opts.on("--expected-base-commit SHA") { |value| options[:expected_base_commit] = value }
    opts.on("--expected-plan-digest DIGEST") { |value| options[:expected_plan_digest] = value }
  end
  begin
    parser.parse!(ARGV)
    raise OptionParser::InvalidArgument, parser.to_s unless options[:changes] && ARGV.empty?
    if options[:worktree] && (options[:repository] || options[:maintenance_root])
      raise OptionParser::InvalidArgument, "--apply-to and --maintenance-root are mutually exclusive"
    end
    if options[:repository] || options[:maintenance_root]
      unless options[:repository] && options[:maintenance_root]
        raise OptionParser::InvalidArgument, "--repository and --maintenance-root must be used together"
      end
    end

    unless options[:base] && options[:expected_base_commit]
      raise OptionParser::InvalidArgument,
        "planning requires --base and --expected-base-commit so the digest binds the reviewed base"
    end
    plan = WorkflowKit::Gardener.plan(
      JSON.parse(File.read(options[:changes])),
      base_branch: options[:base],
      base_commit: options[:expected_base_commit],
    )
    applying = options[:worktree] || options[:maintenance_root]
    if applying
      unless options[:base] && options[:expected_base_commit] && options[:expected_plan_digest]
        raise OptionParser::InvalidArgument,
          "apply requires --base, --expected-base-commit, and --expected-plan-digest"
      end
      result = if options[:worktree]
        WorkflowKit::Gardener.apply(
          options[:worktree], options[:base], plan,
          expected_base_commit: options[:expected_base_commit],
          expected_plan_digest: options[:expected_plan_digest],
        )
      else
        WorkflowKit::Gardener.apply_in_maintenance_worktree(
          repository: options[:repository],
          maintenance_root: options[:maintenance_root],
          base_branch: options[:base],
          plan: plan,
          expected_base_commit: options[:expected_base_commit],
          expected_plan_digest: options[:expected_plan_digest],
          branch_name: options[:branch_name],
        )
      end
      puts JSON.pretty_generate({ "plan" => plan, "result" => result })
    else
      puts JSON.pretty_generate(plan)
    end
    exit(plan["valid"] ? 0 : 30)
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, ArgumentError, OptionParser::ParseError => error
    warn "ERROR: #{error.message}"
    exit 30
  end
end
