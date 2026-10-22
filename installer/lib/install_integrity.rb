# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "uri"

require_relative "dirty_snapshot"

module WorkflowKit
  module Install
    module Integrity
      DIGEST_PATTERN = /\A(?:sha256:)?([0-9a-f]{64})\z/.freeze
      RENDERED_DIGEST_ALGO = 2
      PLAN_DIGEST_ALGO = 1
      DIRTY_SNAPSHOT_ALGO = WorkflowKit::Release::DirtySnapshot::DIRTY_SNAPSHOT_ALGO
      DIGEST_EXCLUDED_FIELDS = %w[created_at dry_run mode counts manifest plan_digest].freeze

      DEFAULT_OWNERSHIP_RULES = [
        { "glob" => ".ai/runtime/**", "ownership" => "kit-owned" },
        { "glob" => ".ai/SPEC_REGISTRY.yaml", "ownership" => "project-owned" },
        { "glob" => ".ai/project/**", "ownership" => "project-owned" },
        { "glob" => ".ai/canonical/**", "ownership" => "project-owned" },
        { "glob" => ".ai/tasks/**", "ownership" => "project-owned" },
        { "glob" => ".ai/local/**", "ownership" => "project-owned" },
        { "glob" => ".ai/generated/**", "ownership" => "generated" },
        { "glob" => ".github/CODEOWNERS", "ownership" => "project-owned" },
        { "glob" => ".github/workflows/agent-workflow-policy.yml", "ownership" => "merge-owned" },
        { "glob" => "AGENTS.md", "ownership" => "merge-owned" },
      ].freeze
      DEFAULT_PROTECTED_PATHS = [
        ".ai/SPEC_REGISTRY.yaml",
        ".ai/project/**",
        ".ai/canonical/**",
        ".ai/tasks/**",
        ".ai/local/**",
        ".github/CODEOWNERS",
      ].freeze
      DEFAULT_APPROVAL_REQUIRED_PATHS = [
        "AGENTS.md", ".github/workflows/agent-workflow-policy.yml",
      ].freeze
      LEGACY_RELOCATIONS = [
        [".ai/scripts/", ".ai/runtime/scripts/"],
        [".ai/templates/", ".ai/runtime/templates/"],
        [".githooks/", ".ai/runtime/githooks/"],
        [".ai/canonical/agents/", ".ai/runtime/agents/base/"],
      ].freeze
      HARNESS_DIRTY_SNAPSHOT_SCOPE = [
        ".ai/**",
        "AGENTS.md",
        ".githooks/**",
        ".github/workflows/**",
      ].freeze
      OWNERSHIPS = %w[kit-owned merge-owned project-owned generated].freeze
      ACTIONS = %w[create update delete skip conflict].freeze

      class IntegrityError < StandardError; end

      module_function

      def sha256(content)
        Digest::SHA256.hexdigest(content)
      end

      def digest_hex(value, label = "digest", allow_nil: false)
        return nil if allow_nil && (value.nil? || value.to_s.empty?)

        match = DIGEST_PATTERN.match(value.to_s)
        raise IntegrityError, "#{label} must be a lowercase SHA-256 digest" unless match

        match[1]
      end

      def digest_label(value, label = "digest", allow_nil: false)
        hex = digest_hex(value, label, allow_nil: allow_nil)
        hex && "sha256:#{hex}"
      end

      def safe_relative_path!(value, label = "path")
        path = value.to_s
        pathname = Pathname.new(path)
        if path.empty? || pathname.absolute? || path.split(/[\\\/]/).include?("..") || pathname.cleanpath.to_s != path
          raise IntegrityError, "#{label} must be a normalized relative path: #{value.inspect}"
        end
        path
      end

      def glob_match?(glob, path)
        if glob.end_with?("/**")
          prefix = glob.delete_suffix("**")
          return true if path.start_with?(prefix)
        end
        File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          File.fnmatch?(glob, path, File::FNM_DOTMATCH)
      end

      def glob_specificity(glob)
        literal = glob.gsub(/[\*\?\[\]]/, "")
        [literal.bytesize, glob.split("/").count { |part| !part.match?(/[\*\?\[]/) }]
      end

      def validate_ownership_rules!(rules)
        unless rules.is_a?(Array) && !rules.empty?
          raise IntegrityError, "release ownership_rules must be a non-empty array"
        end

        rules.each_with_index do |rule, index|
          unless rule.is_a?(Hash)
            raise IntegrityError, "ownership_rules[#{index}] must be a mapping"
          end
          safe_relative_glob = rule["glob"].to_s
          if safe_relative_glob.empty? || Pathname.new(safe_relative_glob).absolute? || safe_relative_glob.split(/[\\\/]/).include?("..")
            raise IntegrityError, "ownership_rules[#{index}].glob must be a safe relative glob"
          end
          ownership = rule["ownership"].to_s
          unless OWNERSHIPS.include?(ownership)
            raise IntegrityError, "ownership_rules[#{index}].ownership must be one of #{OWNERSHIPS.join(', ')}"
          end
        end
        rules
      end

      def ownership_for(path, rules)
        relative = safe_relative_path!(path)
        matches = validate_ownership_rules!(rules).select { |rule| glob_match?(rule.fetch("glob"), relative) }
        return "kit-owned" if matches.empty?

        best_specificity = matches.map { |rule| glob_specificity(rule.fetch("glob")) }.max
        winners = matches.select { |rule| glob_specificity(rule.fetch("glob")) == best_specificity }
        ownerships = winners.map { |rule| rule.fetch("ownership") }.uniq
        if ownerships.length != 1
          descriptions = winners.map { |rule| "#{rule['glob']}=#{rule['ownership']}" }.join(", ")
          raise IntegrityError, "ambiguous ownership rules for #{relative}: #{descriptions}"
        end
        ownerships.first
      end

      def path_matches_any?(path, globs)
        Array(globs).any? { |glob| glob_match?(glob.to_s, path) }
      end

      def legacy_relocation_target(path)
        relative = safe_relative_path!(path)
        relocation = LEGACY_RELOCATIONS.find { |old_prefix, _new_prefix| relative.start_with?(old_prefix) }
        return nil unless relocation

        old_prefix, new_prefix = relocation
        suffix = relative.delete_prefix(old_prefix)
        return nil if suffix.empty?

        safe_relative_path!("#{new_prefix}#{suffix}")
      end

      def normalize_previous_ownership(value, path, rules)
        case value.to_s
        when "kit", "legacy"
          "kit-owned"
        when "project"
          path == "AGENTS.md" ? "merge-owned" : "project-owned"
        when *OWNERSHIPS
          value.to_s
        else
          ownership_for(path, rules)
        end
      end

      def rendered_install_digest(plans)
        rows = plans.select { |plan| %w[kit-owned merge-owned].include?(plan.fetch(:ownership)) }.map do |plan|
          relative = plan.fetch(:relative)
          [
            relative.b,
            plan.fetch(:digest).to_s.b,
            format("%04o", plan.fetch(:mode)).b,
            plan.fetch(:ownership).to_s.b,
          ]
        end
        rows.sort_by!(&:first)
        material = +"workflow-kit-rendered-install\0#{RENDERED_DIGEST_ALGO}\0#{rows.length}\0".b
        rows.each do |row|
          row.each do |field|
            material << field.bytesize.to_s.b << ":".b << field
          end
        end
        "sha256:#{sha256(material)}"
      end

      def capture_git(root, *args)
        stdout, stderr, status = Open3.capture3("git", "-C", root, *args)
        [stdout.strip, stderr.strip, status.success?]
      end

      def git_optional(root, *args)
        stdout, _stderr, ok = capture_git(root, *args)
        ok && !stdout.empty? ? stdout : nil
      end

      def normalize_remote_url(value)
        raw = value.to_s.strip
        return "" if raw.empty?

        normalized = if raw.match?(/\A[^@\/:]+@[^:]+:/)
          user_host, path = raw.split(":", 2)
          "#{user_host.split('@', 2).last}/#{path}"
        else
          begin
            uri = URI.parse(raw)
            if uri.host
              [uri.host.downcase, uri.path.to_s.sub(%r{\A/+}, "")].reject(&:empty?).join("/")
            elsif uri.scheme == "file"
              File.expand_path(uri.path)
            else
              raw
            end
          rescue URI::InvalidURIError
            raw
          end
        end
        normalized.sub(/\.git\z/, "").sub(%r{/+\z}, "")
      end

      def repository_fingerprint(root, project_id)
        roots, _error, ok = capture_git(root, "rev-list", "--max-parents=0", "HEAD")
        roots = "" unless ok
        first_commits = roots.lines.map(&:strip).reject(&:empty?).sort.join("\n")

        remotes_output, _remote_error, remotes_ok = capture_git(root, "remote", "-v")
        remotes = if remotes_ok
          remotes_output.lines.map do |line|
            _name, url, kind = line.strip.split(/\s+/, 3)
            next unless kind.nil? || kind == "(fetch)"
            normalized = normalize_remote_url(url)
            normalized unless normalized.empty?
          end.compact.uniq.sort
        else
          []
        end
        material = "#{first_commits}\n#{remotes.join("\n")}\n#{project_id}"
        ["sha256:#{sha256(material)}", remotes]
      end

      def target_context(root, manifest_path, project_id:, scope_paths: [], scope_globs: [], scope_mode: "custom")
        fingerprint, remotes = repository_fingerprint(root, project_id)
        branch = git_optional(root, "symbolic-ref", "--quiet", "--short", "HEAD")
        branch ||= git_optional(root, "rev-parse", "--abbrev-ref", "HEAD")
        branch = nil if branch == "HEAD"
        head = git_optional(root, "rev-parse", "HEAD")
        manifest_digest = File.file?(manifest_path) ? "sha256:#{Digest::SHA256.file(manifest_path).hexdigest}" : nil
        normalized_paths = Array(scope_paths).map(&:to_s).reject(&:empty?).uniq.sort
        normalized_globs = Array(scope_globs).map(&:to_s).reject(&:empty?).uniq.sort
        if normalized_paths.empty? && normalized_globs.empty?
          raise IntegrityError, "dirty snapshot scope must not be empty"
        end
        dirty_snapshot = WorkflowKit::Release::DirtySnapshot.snapshot(
          root,
          scope_paths: normalized_paths,
          scope_globs: normalized_globs,
          scope_mode: scope_mode,
        )

        {
          "repository_fingerprint" => fingerprint,
          "repository_remotes" => remotes,
          "head_commit" => head,
          "worktree_path" => File.realpath(root),
          "branch" => branch,
          "dirty_snapshot_digest" => "sha256:#{dirty_snapshot.fetch("dirty_snapshot_digest")}",
          "dirty_snapshot_scope" => dirty_snapshot.fetch("dirty_snapshot_scope"),
          "manifest_digest" => manifest_digest,
        }
      rescue WorkflowKit::Release::DirtySnapshot::SnapshotError => error
        raise IntegrityError, "cannot calculate target dirty snapshot: #{error.message}"
      end

      def canonical_object(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            original_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            result[key] = canonical_object(value[original_key])
          end
        when Array
          value.map { |entry| canonical_object(entry) }
        when String, Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise IntegrityError, "plan digest cannot serialize #{value.class}"
        end
      end

      def plan_digest_input(plan)
        {
          "plan_digest_algo" => PLAN_DIGEST_ALGO,
          "source" => plan.fetch("source"),
          "target" => plan.fetch("target"),
          "files" => Array(plan["files"] || plan["plans"]).sort_by { |entry| entry.fetch("path") },
          "approvals" => plan.fetch("approvals"),
          "activity" => plan.fetch("activity"),
          "digest_excluded_fields" => plan.fetch("digest_excluded_fields"),
        }
      end

      def plan_digest(plan)
        canonical_json = JSON.generate(canonical_object(plan_digest_input(plan)))
        "sha256:#{sha256(canonical_json)}"
      end

      def parse_approvals(values)
        Array(values).each_with_object({}) do |value, result|
          path, digest = value.to_s.split("=", 2)
          safe_relative_path!(path, "approved path")
          raise IntegrityError, "duplicate --approve-path for #{path}" if result.key?(path)
          result[path] = digest_hex(digest, "approved digest for #{path}")
        end
      end
    end
  end
end
