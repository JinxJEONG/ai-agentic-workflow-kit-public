#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"
require "yaml"

module WorkflowKit
  module NestedClone
    module_function

    def git(root, *arguments, allow_failure: false)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      return nil if allow_failure && !status.success?
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?
      stdout
    end

    def tree_digest(root, ref)
      raw = git(root, "ls-tree", "-r", "-z", ref)
      "sha256:#{Digest::SHA256.hexdigest(raw)}"
    end

    def runtime_references(repo, nested_relative)
      files = git(repo, "ls-files", "-z").split("\0").reject(&:empty?).reject do |path|
        path.start_with?("#{nested_relative}/") || path.start_with?(".ai/tasks/") || path.end_with?(".md")
      end
      files.select do |path|
        absolute = File.join(repo, path)
        File.file?(absolute) && !File.binread(absolute).include?("\0") && File.read(absolute).include?(nested_relative)
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        false
      end.sort
    end

    def completion_evidence(path, phase, repository_head)
      value = JSON.parse(File.binread(path))
      valid = value.is_a?(Hash) && value["evidence_schema"] == 1 &&
        value["phase"] == phase && value["status"] == "complete" &&
        value["repository_head"] == repository_head &&
        value["completion_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
      { "pass" => valid, "path" => File.expand_path(path), "phase" => phase }
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      { "pass" => false, "path" => File.expand_path(path), "phase" => phase }
    end

    def checkpoint_evidence(repo, checkpoint_root)
      root = File.realpath(checkpoint_root)
      return { "pass" => false, "reason" => "checkpoint_root_permissions" } unless (File.stat(root).mode & 0o777) == 0o700

      indexes = Dir.glob(File.join(root, "**", "*.json"))
      matching = indexes.flat_map do |path|
        document = JSON.parse(File.binread(path))
        next [] unless document.is_a?(Hash) && document["schema_version"] == 1
        source = document.dig("repository", "source_path")
        next [] unless source && File.realpath(source) == repo

        Array(document["worktrees"]).select do |record|
          next false unless record["restore_verified"] == true &&
            record["worktree_path"] && File.realpath(record["worktree_path"]) == repo
          ref = record["checkpoint_ref"].to_s
          target = git(repo, "rev-parse", "--verify", ref, allow_failure: true).to_s.strip
          next false unless !target.empty? && target == record["ref_target"]

          archive = record["untracked_archive"]
          if archive
            next false unless File.file?(archive) && !File.symlink?(archive) &&
              (File.stat(archive).mode & 0o777) == 0o600
            next false unless Digest::SHA256.file(archive).hexdigest == record["untracked_archive_sha256"]
          end
          true
        end
      rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
        []
      end
      { "pass" => !matching.empty?, "records" => matching.length }
    rescue Errno::ENOENT, Errno::EACCES
      { "pass" => false, "reason" => "checkpoint_root_missing" }
    end

    def verify_bundle(nested, bundle, nested_head)
      return { "verified" => false, "contains_nested_head" => false } unless File.file?(bundle) && !File.symlink?(bundle)

      _stdout, _stderr, status = Open3.capture3("git", "-C", nested, "bundle", "verify", bundle)
      heads, _list_error, list_status = Open3.capture3("git", "bundle", "list-heads", bundle)
      contains = list_status.success? && heads.lines.any? { |line| line.split.first == nested_head }
      { "verified" => status.success?, "contains_nested_head" => contains }
    end

    def verify(repo:, central_kit:, baseline_ref:, phase3:, phase4:, checkpoint_root:, bundle:, state:)
      repo = File.realpath(repo)
      central_kit = File.realpath(central_kit)
      nested_relative = "ai-agentic-workflow-kit"
      nested = File.join(repo, nested_relative)
      repository_head = git(repo, "rev-parse", "HEAD").strip
      results = {}
      results["R-1"] = { "pass" => state == "migrated", "detail" => "state=#{state}" }
      results["R-2"] = completion_evidence(phase3, 3, repository_head)
      results["R-3"] = completion_evidence(phase4, 4, repository_head)

      nested_digest = Dir.exist?(nested) ? tree_digest(nested, "HEAD") : nil
      central_digest = tree_digest(central_kit, baseline_ref)
      results["R-4"] = { "pass" => nested_digest == central_digest, "nested" => nested_digest, "central" => central_digest }
      results["R-5"] = checkpoint_evidence(repo, checkpoint_root)
      dirty = Dir.exist?(nested) ? git(nested, "status", "--porcelain=v1", "-z") : "missing"
      results["R-6"] = { "pass" => dirty == "", "dirty_entries" => dirty == "missing" ? nil : dirty.split("\0").reject(&:empty?).length }
      references = runtime_references(repo, nested_relative)
      results["R-7"] = { "pass" => references.empty?, "references" => references }

      bundle_result = Dir.exist?(nested) ? verify_bundle(nested, bundle, git(nested, "rev-parse", "HEAD").strip) : { "verified" => false, "contains_nested_head" => false }
      {
        "eligible" => results.values.all? { |result| result["pass"] } && bundle_result.values.all?,
        "requirements" => results,
        "bundle" => {
          "path" => File.expand_path(bundle),
          "verified" => bundle_result["verified"],
          "contains_nested_head" => bundle_result["contains_nested_head"],
          "sha256" => File.file?(bundle) ? "sha256:#{Digest::SHA256.file(bundle).hexdigest}" : nil,
        },
      }
    end

    def preserve(repo:, destination:)
      nested = File.join(File.realpath(repo), "ai-agentic-workflow-kit")
      raise ArgumentError, "nested clone is missing" unless Dir.exist?(nested)
      dirty = git(nested, "status", "--porcelain=v1", "-z")
      unless dirty.empty?
        raise ArgumentError, "dirty nested clone cannot be represented by a Git bundle; checkpoint it before preservation"
      end
      destination = File.expand_path(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      raise ArgumentError, "refusing to overwrite an existing bundle" if File.exist?(destination)
      _stdout, stderr, status = Open3.capture3("git", "-C", nested, "bundle", "create", destination, "--all")
      raise ArgumentError, "bundle creation failed: #{stderr.strip}" unless status.success?
      File.chmod(0o600, destination)
      _stdout, stderr, status = Open3.capture3("git", "-C", nested, "bundle", "verify", destination)
      raise ArgumentError, "bundle verification failed: #{stderr.strip}" unless status.success?
      {
        "bundle_path" => destination,
        "bundle_sha256" => "sha256:#{Digest::SHA256.file(destination).hexdigest}",
        "head_before_removal" => git(nested, "rev-parse", "HEAD").strip,
        "uncommitted_in_clone" => 0,
        "preserved_at" => Time.now.utc.iso8601,
        "mode" => format("%04o", File.stat(destination).mode & 0o7777),
        "removal_performed" => false,
      }
    end
  end
end
