#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "yaml"

require_relative "../release/dirty_snapshot"

module WorkflowKit
  module Adoption
    class PreflightError < StandardError; end

    # Read-only technical gate for one repository. Human approval is kept as
    # an explicit external requirement and can never be inferred by this tool.
    module Preflight
      PLACEHOLDER_STATUS_TOKENS = %w[draft example missing placeholder tbd template todo unknown unset].freeze
      module_function

      def git(root, *arguments, allow_failure: false)
        stdout, stderr, status = Open3.capture3(
          { "GIT_OPTIONAL_LOCKS" => "0" },
          "git", "-C", root, *arguments,
        )
        return nil if allow_failure && !status.success?
        raise PreflightError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

        stdout
      end

      def yaml(path)
        value = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
        value.is_a?(Hash) ? value : {}
      rescue Psych::Exception => error
        raise PreflightError, "cannot parse #{path}: #{error.message}"
      end

      def relative_path(root, path)
        path.delete_prefix("#{root}/")
      end

      def normalized_branch(value)
        branch = value.to_s.strip
        return nil if branch.empty?

        branch.delete_prefix("refs/heads/")
      end

      def status_ready?(value)
        return false unless value.is_a?(String)

        normalized = value.strip.downcase
        return false if normalized.empty?

        tokens = normalized.split(/[^a-z0-9]+/).reject(&:empty?)
        (tokens & PLACEHOLDER_STATUS_TOKENS).empty?
      end

      def populated_collection?(value)
        (value.is_a?(Array) || value.is_a?(Hash)) && !value.empty?
      end

      def context_file_evidence(root, relative, section)
        path = File.join(root, relative)
        unless File.file?(path)
          return {
            "path" => relative,
            "present" => false,
            "status" => nil,
            "status_ready" => false,
            "required_section" => section,
            "section_count" => 0,
            "section_ready" => false,
            "ready" => false,
            "reasons" => ["missing_file"],
          }
        end

        data = yaml(path)
        status = data["status"]
        collection = data[section]
        status_ok = status_ready?(status)
        section_ok = populated_collection?(collection)
        reasons = []
        reasons << "draft_or_placeholder_status" unless status_ok
        reasons << "missing_or_empty_#{section}" unless section_ok
        {
          "path" => relative,
          "present" => true,
          "status" => status,
          "status_ready" => status_ok,
          "required_section" => section,
          "section_count" => section_ok ? collection.length : 0,
          "section_ready" => section_ok,
          "ready" => status_ok && section_ok,
          "reasons" => reasons,
        }
      end

      def context_evidence(root)
        project_map = context_file_evidence(root, ".ai/canonical/PROJECT_MAP.yaml", "services")
        env_matrix = context_file_evidence(root, ".ai/canonical/ENV_MATRIX.yaml", "environments")
        {
          "ready" => project_map["ready"] && env_matrix["ready"],
          "project_map" => project_map,
          "env_matrix" => env_matrix,
        }
      end

      def activity(root)
        candidates = [
          File.join(root, ".ai", "local", "ACTIVE_CONTEXT.yaml"),
          File.join(root, ".ai", "ACTIVE_CONTEXT.yaml"),
        ]
        contexts = candidates.select { |candidate| File.file?(candidate) }.map do |path|
          data = yaml(path)
          status = data["status"].to_s
          streams = Array(data["active_streams"])
          {
            "path" => relative_path(root, path),
            "status" => status,
            "active_streams" => streams,
            "idle" => status.strip.downcase == "idle" && streams.empty?,
          }
        end
        ready = contexts.all? { |context| context["idle"] }
        primary = contexts.first || { "path" => nil, "status" => "idle", "active_streams" => [] }
        {
          "path" => primary["path"],
          "status" => primary["status"],
          "active_streams" => contexts.flat_map { |context| context["active_streams"] },
          "contexts" => contexts,
          "ready" => ready,
          "reason" => ready ? nil : "active_context_not_idle",
        }
      end

      def stream_locks(root)
        Dir.glob(File.join(root, ".ai", "tasks", "**", "LOCK.yaml"))
          .map { |lock| relative_path(root, lock) }.sort
      end

      def worktrees(root)
        raw = git(root, "worktree", "list", "--porcelain", "-z")
        records = []
        current = {}
        raw.split("\0").each do |field|
          key, value = field.split(" ", 2)
          if key == "worktree"
            records << current unless current.empty?
            current = { "path" => value }
          elsif key && current.any?
            current[key] = value || true
          end
        end
        records << current unless current.empty?
        records.map do |record|
          path = File.realpath(record.fetch("path"))
          dirty = git(path, "status", "--porcelain=v1", "-z", "--untracked-files=all")
            .split("\0").reject(&:empty?).length
          {
            "path" => path,
            "head" => record["HEAD"],
            "branch" => normalized_branch(record["branch"]),
            "detached" => record.key?("detached"),
            "dirty_entries" => dirty,
            "activity" => activity(path),
            "lock_paths" => stream_locks(path),
          }
        end
      end

      def checkpoint_documents(record_directory)
        expanded = record_directory && File.expand_path(record_directory)
        unless expanded && Dir.exist?(expanded)
          return {
            "record_directory" => expanded,
            "record_directory_present" => false,
            "record_files" => 0,
            "parse_errors" => [],
            "records" => [],
          }
        end

        directory = File.realpath(expanded)
        records = []
        errors = []
        files = Dir.glob(File.join(directory, "*.json")).sort
        files.each do |file|
          begin
            document = JSON.parse(File.read(file))
            candidates = document.is_a?(Hash) && document["worktrees"].is_a?(Array) ? document["worktrees"] : [document]
            candidates.each do |record|
              records << record.merge("_record_file" => file) if record.is_a?(Hash)
            end
          rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES
            errors << File.basename(file)
          end
        end
        {
          "record_directory" => directory,
          "record_directory_present" => true,
          "record_files" => files.length,
          "parse_errors" => errors,
          "records" => records,
        }
      end

      def canonical_record_path(record)
        path = record["worktree_path"]
        return nil unless path.is_a?(String) && !path.empty? && File.exist?(path)

        File.realpath(path)
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def archive_required?(record)
        record["untracked_entries"].to_i.positive? || !record["untracked_archive"].to_s.empty?
      end

      def archive_present?(record)
        return true unless archive_required?(record)

        path = record["untracked_archive"]
        path.is_a?(String) && !path.empty? && File.file?(path) && !File.symlink?(path)
      end

      def checkpoint_candidate(root, tree, record, refs)
        ref = record["checkpoint_ref"].to_s
        ref_value = ref.empty? ? nil : git(root, "rev-parse", "--verify", ref, allow_failure: true).to_s.strip
        ref_matches = !ref.empty? && refs.include?(ref) && !ref_value.empty?
        ref_matches &&= ref_value == record["ref_target"] if record["ref_target"].is_a?(String)
        scope = record["dirty_snapshot_scope"]
        snapshot_digest = if scope.is_a?(Hash)
                            WorkflowKit::Release::DirtySnapshot.digest(
                              tree["path"],
                              scope_mode: scope["mode"],
                              scope_paths: scope["paths"],
                              scope_globs: scope["globs"],
                            )
                          end
        checks = {
          "restore_verified" => record["restore_verified"] == true,
          "head_matches" => record["head"] == tree["head"],
          "branch_matches" => normalized_branch(record["branch"]) == tree["branch"],
          "checkpoint_ref_matches" => ref_matches,
          "archive_present_when_required" => archive_present?(record),
          "dirty_snapshot_algo_current" => record["dirty_snapshot_algo"] == WorkflowKit::Release::DirtySnapshot::DIRTY_SNAPSHOT_ALGO,
          "dirty_snapshot_digest_matches" => !snapshot_digest.nil? && record["dirty_snapshot_digest"] == snapshot_digest,
        }
        {
          "record_file" => File.basename(record["_record_file"].to_s),
          "archive_required" => archive_required?(record),
          "checks" => checks,
          "ready" => checks.values.all?,
        }
      rescue WorkflowKit::Release::DirtySnapshot::SnapshotError, ArgumentError
        {
          "record_file" => File.basename(record["_record_file"].to_s),
          "archive_required" => archive_required?(record),
          "checks" => {
            "restore_verified" => record["restore_verified"] == true,
            "head_matches" => record["head"] == tree["head"],
            "branch_matches" => normalized_branch(record["branch"]) == tree["branch"],
            "checkpoint_ref_matches" => ref_matches,
            "archive_present_when_required" => archive_present?(record),
            "dirty_snapshot_algo_current" => false,
            "dirty_snapshot_digest_matches" => false,
          },
          "ready" => false,
        }
      end

      def checkpoint_evidence(root, trees, record_directory)
        documents = checkpoint_documents(record_directory)
        refs = git(root, "for-each-ref", "--format=%(refname)", "refs/harness-checkpoint/")
          .lines.map(&:strip).reject(&:empty?)
        tree_evidence = trees.map do |tree|
          unless tree["dirty_entries"].positive?
            next {
              "path" => tree["path"],
              "required" => false,
              "candidate_records" => 0,
              "ready" => true,
              "reason" => "clean_worktree",
            }
          end

          records = documents["records"].select { |record| canonical_record_path(record) == tree["path"] }
          candidates = records.map { |record| checkpoint_candidate(root, tree, record, refs) }
          matching = candidates.find { |candidate| candidate["ready"] }
          {
            "path" => tree["path"],
            "required" => true,
            "candidate_records" => candidates.length,
            "ready" => !matching.nil?,
            "matched_record" => matching,
            "candidate_checks" => matching ? [] : candidates,
            "reason" => if !documents["record_directory_present"]
                          "checkpoint_record_directory_missing"
                        elsif candidates.empty?
                          "matching_checkpoint_record_missing"
                        elsif matching.nil?
                          "checkpoint_record_not_current_or_incomplete"
                        end,
          }
        end
        {
          "record_directory" => documents["record_directory"],
          "record_directory_present" => documents["record_directory_present"],
          "record_files" => documents["record_files"],
          "parse_errors" => documents["parse_errors"],
          "worktrees" => tree_evidence,
          "ready" => documents["parse_errors"].empty? && tree_evidence.all? { |entry| entry["ready"] },
          "checkpoint_refs" => refs,
        }
      end

      def inspect_repository(path, dirty_limit: 0, checkpoint_record_directory: nil)
        root = File.realpath(path)
        top = File.realpath(git(root, "rev-parse", "--show-toplevel").strip)
        raise PreflightError, "target must be a Git top-level" unless top == root

        branch = normalized_branch(git(root, "symbolic-ref", "--quiet", "--short", "HEAD", allow_failure: true))
        trees = worktrees(root)
        primary = trees.find { |tree| tree["path"] == root }
        raise PreflightError, "primary worktree is missing from Git worktree inventory" unless primary

        context = context_evidence(root)
        checkpoints = checkpoint_evidence(root, trees, checkpoint_record_directory)
        locks = trees.flat_map do |tree|
          tree["lock_paths"].map do |lock|
            tree["path"] == root ? lock : "#{tree['path']}:#{lock}"
          end
        end
        managed = File.file?(File.join(root, ".ai", "KIT_INSTALLATION.yaml"))

        checks = {
          "attached_branch" => !branch.nil?,
          "active_context_idle" => trees.all? { |tree| tree.dig("activity", "ready") },
          "stream_locks_absent" => locks.empty?,
          "dirty_within_limit" => trees.all? { |tree| tree["dirty_entries"] <= Integer(dirty_limit) },
          "checkpoint_available_when_dirty" => checkpoints["ready"],
          "project_context_ready" => context["ready"],
        }
        {
          "preflight_schema" => 1,
          "read_only" => true,
          "target" => root,
          "track" => managed ? "managed_upgrade" : "legacy_adoption",
          "branch" => branch,
          "activity" => primary["activity"],
          "worktree_activity" => trees.map do |tree|
            { "path" => tree["path"], "activity" => tree["activity"], "lock_paths" => tree["lock_paths"] }
          end,
          "lock_paths" => locks,
          "worktrees" => trees,
          "project_context" => context,
          "checkpoint_evidence" => checkpoints,
          "checkpoint_refs" => checkpoints["checkpoint_refs"],
          "checks" => checks,
          "technically_eligible" => checks.values.all?,
          "apply_authorized" => false,
          "external_requirements" => [
            "fleet freeze release",
            "repository-specific human approval",
            "reviewed plan in the same worktree and branch",
          ],
        }
      rescue Errno::ENOENT, Errno::EACCES => error
        raise PreflightError, "cannot inspect repository: #{error.message}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { dirty_limit: 0 }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: preflight.rb [--dirty-limit N] [--checkpoint-record-directory DIR] REPOSITORY"
    opts.on("--dirty-limit N", Integer) { |value| options[:dirty_limit] = value }
    opts.on("--checkpoint-record-directory DIR") { |value| options[:checkpoint_record_directory] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless ARGV.length == 1 && options[:dirty_limit] >= 0
  begin
    result = WorkflowKit::Adoption::Preflight.inspect_repository(ARGV.first, **options)
    puts JSON.pretty_generate(result)
    exit(result["technically_eligible"] ? 0 : 30)
  rescue WorkflowKit::Adoption::PreflightError, ArgumentError => error
    warn JSON.generate({ "state" => "invalid", "error" => error.message })
    exit 40
  end
end
