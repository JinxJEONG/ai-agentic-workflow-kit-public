# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "tempfile"
require "tmpdir"
require "time"
require "uri"

require_relative "release_digest"
require_relative "dirty_snapshot"

module WorkflowKit
  module Release
    module ReleaseManifest
      MANIFEST_SCHEMA = 2
      RENDERED_DIGEST_ALGO = 2
      SOURCE_DIGEST_ALGO = 1
      # The Phase 1 bootstrap artifact predates algorithm 4. It remains
      # verifiable for provenance, but its non-pinnable policy prevents install.
      LEGACY_BOOTSTRAP_DIRTY_SNAPSHOT_ALGO = 3
      SUPPORTED_MANIFEST_SCHEMAS = [1, 2].freeze
      RENDERED_DIGEST_EXCLUDED_FIELDS = [
        "installed_at",
        "updated_at",
        "workspace_root",
      ].freeze
      OWNERSHIP_RULES = [
        { "glob" => ".ai/runtime/**", "ownership" => "kit-owned" }.freeze,
        { "glob" => ".ai/SPEC_REGISTRY.yaml", "ownership" => "project-owned" }.freeze,
        { "glob" => ".ai/project/**", "ownership" => "project-owned" }.freeze,
        { "glob" => ".ai/canonical/**", "ownership" => "project-owned" }.freeze,
        { "glob" => ".ai/tasks/**", "ownership" => "project-owned" }.freeze,
        { "glob" => ".ai/local/**", "ownership" => "project-owned" }.freeze,
        { "glob" => ".ai/generated/**", "ownership" => "generated" }.freeze,
        { "glob" => ".github/CODEOWNERS", "ownership" => "project-owned" }.freeze,
        { "glob" => ".github/workflows/agent-workflow-policy.yml", "ownership" => "merge-owned" }.freeze,
        { "glob" => "AGENTS.md", "ownership" => "merge-owned" }.freeze,
      ].freeze
      PROTECTED_PATHS = [
        ".ai/SPEC_REGISTRY.yaml", ".ai/tasks/**", ".ai/canonical/**", ".ai/local/**",
        ".github/CODEOWNERS",
      ].freeze
      APPROVAL_REQUIRED_PATHS = ["AGENTS.md", ".github/workflows/agent-workflow-policy.yml"].freeze

      class ManifestError < StandardError; end

      class Builder
        DEFAULT_OUTPUT_DIR = File.join(Dir.tmpdir, "ai-agentic-workflow-kit-releases").freeze

        attr_reader :repository, :output_dir

        def initialize(repository:, output_dir: nil, public_repository: nil)
          @repository = File.realpath(repository)
          @public_repository = public_repository
          if public_repository
            owner, name, extra = public_repository.split("/", -1)
            unless extra.nil? && owner.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9-]*\z/) &&
              name.to_s.match?(/\A[A-Za-z0-9_.-]+\z/) && !%w[. ..].include?(name)
              raise ManifestError, "public repository must be OWNER/REPO without credentials or URL parameters"
            end
          end
          @output_dir = File.expand_path(
            output_dir || ENV["WORKFLOW_KIT_RELEASE_DIR"] || DEFAULT_OUTPUT_DIR
          )
          reject_repository_output!
        rescue Errno::ENOENT, Errno::EACCES => error
          raise ManifestError, "cannot resolve release path: #{error.message}"
        end

        def build(ref:, channel: nil)
          tag = resolve_tag(ref, channel: channel)
          if @public_repository && !tag.fetch(:pinnable)
            raise ManifestError, "public artifacts require a versioned release tag"
          end

          # Compute every content identity before creating an artifact. A
          # refused symlink/submodule therefore leaves no partial release or
          # digest output behind.
          bundle_digest = ReleaseDigest.kit_bundle_digest(repository, tag.fetch(:full_ref))
          auxiliary = ReleaseDigest.auxiliary_digests(repository, tag.fetch(:full_ref))

          prepare_output_dir!
          Dir.mktmpdir(".workflow-kit-release-", output_dir) do |staging|
            paths = artifact_paths(tag.fetch(:version), staging)
            create_archive(tag.fetch(:full_ref), tag.fetch(:version), paths.fetch("archive"))
            archive_sha = Digest::SHA256.file(paths.fetch("archive")).hexdigest
            write_checksum(
              paths.fetch("checksum"),
              archive_sha,
              File.basename(paths.fetch("archive")),
            )
            manifest = manifest_payload(tag, bundle_digest, auxiliary, archive_sha)
            write_json(paths.fetch("manifest"), manifest)
            published = publish(paths, tag.fetch(:version))
            return { "paths" => published, "manifest" => manifest }
          end
        end

        def verify(ref:)
          tag = resolve_tag(ref, channel: nil)
          paths = artifact_paths(tag.fetch(:version), output_dir)
          paths.each_value do |path|
            raise ManifestError, "missing release artifact: #{path}" unless File.file?(path)
            raise ManifestError, "release artifact must not be a symbolic link: #{path}" if File.symlink?(path)
          end
          verify_completion_marker!(paths, tag.fetch(:version))

          manifest = parse_manifest(paths.fetch("manifest"))
          validate_manifest!(manifest, tag)
          verify_tag_identities!(manifest, tag)
          archive_sha = verify_checksum!(paths)
          expected_archive_sha = prefixed_digest(manifest.dig("source", "bundle_archive_sha256"))
          unless archive_sha == expected_archive_sha
            raise ManifestError, "archive checksum differs from release manifest"
          end

          Dir.mktmpdir("workflow-kit-release-verify-") do |temporary|
            safe_archive_entries!(paths.fetch("archive"))
            extract_archive(paths.fetch("archive"), temporary)
            extracted = extracted_root(temporary, tag.fetch(:version))
            actual_bundle = ReleaseDigest.digest_from_directory(
              extracted,
              excludes: manifest.fetch("excluded_paths"),
            )
            expected_bundle = prefixed_digest(manifest.fetch("kit_bundle_digest"))
            unless actual_bundle == expected_bundle
              raise ManifestError,
                "kit bundle digest mismatch: expected #{expected_bundle}, got #{actual_bundle}"
            end

            actual_auxiliary = ReleaseDigest.auxiliary_digests_from_directory(extracted)
            expected_auxiliary = manifest.fetch("auxiliary_digests")
            actual_auxiliary.each do |name, actual|
              expected = prefixed_digest(expected_auxiliary.fetch(name))
              next if actual == expected

              raise ManifestError,
                "#{name} mismatch: expected #{expected}, got #{actual}"
            end
          end
          manifest
        rescue JSON::ParserError, KeyError => error
          raise ManifestError, "invalid release manifest: #{error.message}"
        end

        private

        def capture_binary(*command)
          stdout, stderr, status = Open3.capture3(*command, binmode: true)
          return stdout if status.success?

          detail = stderr.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
          detail = "exit #{status.exitstatus}" if detail.empty?
          raise ManifestError, "command failed (#{command.join(' ')}): #{detail}"
        rescue SystemCallError => error
          raise ManifestError, "cannot run #{command.first}: #{error.message}"
        end

        def resolve_tag(ref, channel:)
          name = ref.to_s.sub(%r{\Arefs/tags/}, "")
          if name.empty? || name.include?("..") || name.start_with?("-")
            raise ManifestError, "invalid release tag: #{ref.inspect}"
          end
          full_ref = "refs/tags/#{name}"
          object_type = capture_binary("git", "-C", repository, "cat-file", "-t", full_ref).strip
          unless object_type == "tag"
            raise ManifestError, "release ref must be an annotated tag: #{full_ref}"
          end

          commit = capture_binary("git", "-C", repository, "rev-parse", "#{full_ref}^{commit}").strip
          version = capture_binary("git", "-C", repository, "show", "#{full_ref}:VERSION").strip
          validate_version!(version)

          bootstrap = name.start_with?("baseline/pre-integrity-")
          if bootstrap
            if channel && channel != "bootstrap"
              raise ManifestError, "baseline tags require channel bootstrap"
            end
            release_channel = "bootstrap"
            pinnable = false
          else
            expected_name = "v#{version}"
            unless name == expected_name
              raise ManifestError,
                "release tag #{name.inspect} must match VERSION as #{expected_name.inspect}"
            end
            release_channel = channel || "stable"
            unless ["candidate", "stable"].include?(release_channel)
              raise ManifestError, "release tags require channel candidate or stable"
            end
            pinnable = true
          end

          created_at = capture_binary(
            "git", "-C", repository, "for-each-ref", "--format=%(taggerdate:iso-strict)", full_ref
          ).strip
          if created_at.empty?
            raise ManifestError, "annotated tag has no tagger timestamp: #{full_ref}"
          end

          {
            name: name,
            full_ref: full_ref,
            commit: commit,
            version: version,
            channel: release_channel,
            pinnable: pinnable,
            created_at: Time.parse(created_at).utc.iso8601,
          }
        rescue ArgumentError => error
          raise ManifestError, "invalid annotated-tag timestamp for #{ref}: #{error.message}"
        end

        def validate_version!(version)
          return if version.match?(/\A[0-9A-Za-z][0-9A-Za-z.+-]*\z/)

          raise ManifestError, "unsafe or empty VERSION value in release tree"
        end

        def reject_repository_output!
          return unless output_dir == repository || output_dir.start_with?("#{repository}#{File::SEPARATOR}")

          raise ManifestError, "release output directory must be outside the repository: #{output_dir}"
        end

        def prepare_output_dir!
          raise ManifestError, "release output directory cannot be the filesystem root" if output_dir == File::SEPARATOR

          FileUtils.mkdir_p(output_dir, mode: 0o700)
          resolved = File.realpath(output_dir)
          if resolved == repository || resolved.start_with?("#{repository}#{File::SEPARATOR}")
            raise ManifestError, "release output directory resolves inside the repository: #{resolved}"
          end
        rescue SystemCallError => error
          raise ManifestError, "cannot prepare release output directory #{output_dir}: #{error.message}"
        end

        def artifact_paths(version, directory)
          stem = "ai-agentic-workflow-kit-#{version}"
          {
            "archive" => File.join(directory, "#{stem}.tar.gz"),
            "checksum" => File.join(directory, "#{stem}.tar.gz.sha256"),
            "manifest" => File.join(directory, "#{stem}.manifest.json"),
          }
        end

        def create_archive(ref, version, destination)
          Tempfile.create(["workflow-kit-release-", ".tar"], File.dirname(destination)) do |tar|
            tar.binmode
            archive_error_path = "#{tar.path}.archive-stderr"
            File.open(archive_error_path, "wb", 0o600) do |errors|
              pid = Process.spawn(
                "git", "-C", repository, "archive", "--format=tar",
                "--prefix=ai-agentic-workflow-kit-#{version}/", ref,
                out: tar,
                err: errors,
              )
              _pid, status = Process.wait2(pid)
              unless status.success?
                errors.flush
                detail = File.binread(archive_error_path).encode(
                  "UTF-8", invalid: :replace, undef: :replace
                ).strip
                raise ManifestError, "git archive failed: #{detail}"
              end
            end
            FileUtils.rm_f(archive_error_path)
            tar.flush

            gzip_error_path = "#{tar.path}.gzip-stderr"
            File.open(destination, "wb", 0o600) do |output|
              File.open(gzip_error_path, "wb", 0o600) do |errors|
                pid = Process.spawn("gzip", "-n", "-c", tar.path, out: output, err: errors)
                _pid, status = Process.wait2(pid)
                unless status.success?
                  errors.flush
                  detail = File.binread(gzip_error_path).encode(
                    "UTF-8", invalid: :replace, undef: :replace
                  ).strip
                  raise ManifestError, "gzip failed: #{detail}"
                end
              end
            end
            FileUtils.rm_f(gzip_error_path)
          ensure
            FileUtils.rm_f(archive_error_path) if defined?(archive_error_path) && archive_error_path
            FileUtils.rm_f(gzip_error_path) if defined?(gzip_error_path) && gzip_error_path
          end
        rescue SystemCallError => error
          raise ManifestError, "cannot create release archive: #{error.message}"
        end

        def write_checksum(path, digest, archive_name)
          File.open(path, "wb", 0o600) { |file| file.write("#{digest}  #{archive_name}\n") }
        end

        def write_json(path, value)
          File.open(path, "wb", 0o600) do |file|
            file.write(JSON.pretty_generate(value))
            file.write("\n")
          end
        end

        def manifest_payload(tag, bundle_digest, auxiliary, archive_sha)
          final_paths = artifact_paths(tag.fetch(:version), output_dir)
          {
            "manifest_schema" => MANIFEST_SCHEMA,
            "kit_version" => tag.fetch(:version),
            "release_ref" => tag.fetch(:full_ref),
            "release_commit" => tag.fetch(:commit),
            "channel" => tag.fetch(:channel),
            "pinnable" => tag.fetch(:pinnable),
            "created_at" => tag.fetch(:created_at),
            "bundle_digest_algo" => ReleaseDigest::BUNDLE_DIGEST_ALGO,
            "kit_bundle_digest" => "sha256:#{bundle_digest}",
            "excluded_paths" => ReleaseDigest::DEFAULT_EXCLUDES.dup,
            "auxiliary_digests" => auxiliary.each_with_object({}) do |(name, value), result|
              result[name] = "sha256:#{value}"
            end,
            "rendered_digest_algo" => RENDERED_DIGEST_ALGO,
            "source_digest_algo" => SOURCE_DIGEST_ALGO,
            "dirty_snapshot_algo" => DirtySnapshot::DIRTY_SNAPSHOT_ALGO,
            "rendered_digest_excluded_fields" => RENDERED_DIGEST_EXCLUDED_FIELDS.dup,
            "manifest_schema_version_supported" => SUPPORTED_MANIFEST_SCHEMAS.dup,
            "tombstones" => [],
            "ownership_rules" => OWNERSHIP_RULES.map(&:dup),
            "protected_paths" => PROTECTED_PATHS.dup,
            "approval_required_paths" => APPROVAL_REQUIRED_PATHS.dup,
            "source" => {
              "kind" => @public_repository ? "github-release" : "local",
              "locator" => artifact_uri(final_paths.fetch("archive"), tag),
              "manifest_locator" => artifact_uri(final_paths.fetch("manifest"), tag),
              "bundle_archive_sha256" => "sha256:#{archive_sha}",
              "signature" => nil,
            },
            "provenance" => {
              "producer" => "local",
              "source_clean" => source_clean?,
              "source_tagged" => true,
            },
          }
        end

        def source_clean?
          capture_binary(
            "git", "-C", repository, "status", "--porcelain=v1", "--untracked-files=all"
          ).empty?
        end

        def file_uri(path)
          "file://#{URI::DEFAULT_PARSER.escape(File.expand_path(path))}"
        end

        def artifact_uri(path, tag)
          return file_uri(path) unless @public_repository

          "https://github.com/#{@public_repository}/releases/download/v#{tag.fetch(:version)}/#{File.basename(path)}"
        end

        def publish(staged_paths, version)
          final_paths = artifact_paths(version, output_dir)
          marker = completion_path(version)
          lock_path = File.join(output_dir, ".#{File.basename(marker)}.lock")
          if File.symlink?(lock_path) || File.symlink?(marker) || final_paths.values.any? { |path| File.symlink?(path) }
            raise ManifestError, "release publish paths must not be symbolic links"
          end
          File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock_file|
            lock_file.flock(File::LOCK_EX)
            marker_staging = "#{marker}.tmp-#{Process.pid}-#{Thread.current.object_id}"
            begin
              staged_paths.each do |name, staged|
                File.rename(staged, final_paths.fetch(name))
              end
              write_json(marker_staging, completion_payload(final_paths, version))
              File.rename(marker_staging, marker)
            ensure
              FileUtils.rm_f(marker_staging) if marker_staging && File.exist?(marker_staging)
            end
          end
          final_paths
        rescue SystemCallError => error
          raise ManifestError, "cannot publish release artifacts: #{error.message}"
        end

        def completion_path(version)
          stem = "ai-agentic-workflow-kit-#{version}"
          File.join(output_dir, ".#{stem}.complete.json")
        end

        def completion_payload(paths, version)
          {
            "completion_schema" => 1,
            "kit_version" => version,
            "artifacts" => paths.keys.sort.each_with_object({}) do |name, result|
              path = paths.fetch(name)
              result[name] = {
                "file" => File.basename(path),
                "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
              }
            end,
          }
        end

        def verify_completion_marker!(paths, version)
          marker = completion_path(version)
          unless File.file?(marker) && !File.symlink?(marker)
            raise ManifestError, "release artifact set has no valid completion marker"
          end
          completion = parse_manifest(marker)
          unless completion["completion_schema"] == 1 && completion["kit_version"] == version
            raise ManifestError, "release artifact completion marker is invalid"
          end
          expected_names = paths.keys.sort
          artifacts = completion["artifacts"]
          unless artifacts.is_a?(Hash) && artifacts.keys.sort == expected_names
            raise ManifestError, "release artifact completion marker is incomplete"
          end
          paths.each do |name, path|
            entry = artifacts.fetch(name)
            expected = "sha256:#{Digest::SHA256.file(path).hexdigest}"
            unless entry.is_a?(Hash) && entry["file"] == File.basename(path) && entry["sha256"] == expected
              raise ManifestError, "release artifact set does not match its completion marker"
            end
          end
          true
        rescue JSON::ParserError, KeyError, TypeError
          raise ManifestError, "release artifact completion marker is invalid"
        end

        def parse_manifest(path)
          value = JSON.parse(File.binread(path))
          raise ManifestError, "release manifest root must be an object" unless value.is_a?(Hash)

          value
        rescue Errno::ENOENT, Errno::EACCES => error
          raise ManifestError, "cannot read release manifest: #{error.message}"
        end

        def validate_manifest!(manifest, tag)
          checks = {
            "manifest_schema" => MANIFEST_SCHEMA,
            "kit_version" => tag.fetch(:version),
            "release_ref" => tag.fetch(:full_ref),
            "release_commit" => tag.fetch(:commit),
            "bundle_digest_algo" => ReleaseDigest::BUNDLE_DIGEST_ALGO,
            "rendered_digest_algo" => RENDERED_DIGEST_ALGO,
            "source_digest_algo" => SOURCE_DIGEST_ALGO,
            "excluded_paths" => ReleaseDigest::DEFAULT_EXCLUDES,
          }
          checks.each do |field, expected|
            actual = manifest.fetch(field)
            next if actual == expected

            raise ManifestError,
              "release manifest #{field} mismatch: expected #{expected.inspect}, got #{actual.inspect}"
          end
          if tag.fetch(:pinnable)
            unless ["candidate", "stable"].include?(manifest.fetch("channel")) && manifest.fetch("pinnable") == true
              raise ManifestError, "version-tag manifests must be candidate/stable and pinnable"
            end
          else
            unless manifest.fetch("channel") == "bootstrap" && manifest.fetch("pinnable") == false
              raise ManifestError, "baseline-tag manifests must be bootstrap and non-pinnable"
            end
          end
          validate_dirty_snapshot_algo!(manifest, tag)
          unless manifest.fetch("kit_bundle_digest").to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
            raise ManifestError, "release manifest has an invalid kit_bundle_digest"
          end
          auxiliary = manifest.fetch("auxiliary_digests")
          ReleaseDigest::AUXILIARY_INCLUDES.each_key do |name|
            unless auxiliary.fetch(name).to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
              raise ManifestError, "release manifest has an invalid #{name}"
            end
          end
          archive_digest = manifest.dig("source", "bundle_archive_sha256")
          unless archive_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
            raise ManifestError, "release manifest has an invalid bundle archive checksum"
          end
        end

        def validate_dirty_snapshot_algo!(manifest, tag)
          actual = manifest.fetch("dirty_snapshot_algo")
          return if actual == DirtySnapshot::DIRTY_SNAPSHOT_ALGO

          legacy_bootstrap = actual == LEGACY_BOOTSTRAP_DIRTY_SNAPSHOT_ALGO &&
            tag.fetch(:pinnable) == false &&
            manifest.fetch("channel") == "bootstrap" &&
            manifest.fetch("pinnable") == false
          return if legacy_bootstrap

          if actual == LEGACY_BOOTSTRAP_DIRTY_SNAPSHOT_ALGO
            raise ManifestError,
              "release manifest dirty_snapshot_algo #{actual} is only allowed for " \
              "baseline-tag bootstrap non-pinnable artifacts"
          end

          raise ManifestError,
            "release manifest dirty_snapshot_algo mismatch: expected " \
            "#{DirtySnapshot::DIRTY_SNAPSHOT_ALGO.inspect}, got #{actual.inspect}"
        end

        def verify_tag_identities!(manifest, tag)
          expected_bundle = ReleaseDigest.kit_bundle_digest(repository, tag.fetch(:full_ref))
          manifest_bundle = prefixed_digest(manifest.fetch("kit_bundle_digest"))
          unless manifest_bundle == expected_bundle
            raise ManifestError,
              "release manifest bundle digest does not identify #{tag.fetch(:full_ref)}"
          end

          manifest_auxiliary = manifest.fetch("auxiliary_digests")
          ReleaseDigest.auxiliary_digests(repository, tag.fetch(:full_ref)).each do |name, expected|
            actual = prefixed_digest(manifest_auxiliary.fetch(name))
            next if actual == expected

            raise ManifestError,
              "release manifest #{name} does not identify #{tag.fetch(:full_ref)}"
          end
        end

        def verify_checksum!(paths)
          checksum_content = File.binread(paths.fetch("checksum"))
          match = checksum_content.match(/\A([0-9a-f]{64})  ([^\r\n]+)\r?\n?\z/)
          raise ManifestError, "invalid checksum sidecar format" unless match

          expected_name = File.basename(paths.fetch("archive"))
          unless match[2] == expected_name
            raise ManifestError,
              "checksum sidecar names #{match[2].inspect}, expected #{expected_name.inspect}"
          end
          actual = Digest::SHA256.file(paths.fetch("archive")).hexdigest
          unless actual == match[1]
            raise ManifestError, "archive checksum verification failed"
          end
          actual
        rescue Errno::ENOENT, Errno::EACCES => error
          raise ManifestError, "cannot verify release checksum: #{error.message}"
        end

        def prefixed_digest(value)
          match = value.to_s.match(/\Asha256:([0-9a-f]{64})\z/)
          raise ManifestError, "invalid sha256 digest: #{value.inspect}" unless match

          match[1]
        end

        def extract_archive(archive, destination)
          _stdout, stderr, status = Open3.capture3(
            "tar", "-xzf", archive, "-C", destination, binmode: true
          )
          return if status.success?

          detail = stderr.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
          raise ManifestError, "cannot extract release archive: #{detail}"
        rescue SystemCallError => error
          raise ManifestError, "cannot run tar: #{error.message}"
        end

        # Verification must treat an artifact as hostile even when its
        # checksum sidecar was updated with it.  The checksum detects transit
        # corruption; it does not make tar paths or entry types safe.  Inspect
        # before extraction so a link or ../ entry cannot write outside the
        # disposable verification directory.
        def safe_archive_entries!(archive)
          names, names_error, names_status = Open3.capture3("tar", "-tzf", archive)
          unless names_status.success?
            raise ManifestError, "cannot list release archive: #{names_error.strip}"
          end
          names.each_line do |line|
            path = line.chomp.sub(%r{/\z}, "")
            next if path.empty?

            if Pathname.new(path).absolute? || path.split("/").include?("..")
              raise ManifestError, "release archive contains an unsafe path"
            end
          end

          verbose, verbose_error, verbose_status = Open3.capture3("tar", "-tvzf", archive)
          unless verbose_status.success?
            raise ManifestError, "cannot inspect release archive: #{verbose_error.strip}"
          end
          verbose.each_line do |line|
            next if line.strip.empty?

            entry_type = line.getbyte(0)
            next if entry_type == "-".ord || entry_type == "d".ord

            raise ManifestError, "release archive contains a non-regular entry"
          end
        rescue SystemCallError => error
          raise ManifestError, "cannot inspect release archive: #{error.message}"
        end

        def extracted_root(directory, version)
          expected = File.join(directory, "ai-agentic-workflow-kit-#{version}")
          children = Dir.children(directory)
          unless children == [File.basename(expected)] && File.directory?(expected) && !File.symlink?(expected)
            raise ManifestError, "release archive has an unexpected top-level layout"
          end
          expected
        end
      end

      module_function

      def build_release(repository:, ref:, output_dir: nil, channel: nil, public_repository: nil)
        Builder.new(repository: repository, output_dir: output_dir, public_repository: public_repository).
          build(ref: ref, channel: channel)
      end

      def verify_release(repository:, ref:, output_dir: nil)
        Builder.new(repository: repository, output_dir: output_dir).verify(ref: ref)
      end

      def run_cli(arguments)
        command = arguments.shift
        unless ["build", "verify"].include?(command)
          raise OptionParser::InvalidArgument, "first argument must be build or verify"
        end

        options = { repository: Dir.pwd, output_dir: nil, ref: nil, channel: nil, public_repository: nil }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: release_manifest.rb #{command} --ref TAG [options]"
          opts.on("--repo PATH", "Kit Git repository") { |value| options[:repository] = value }
          opts.on("--ref TAG", "Annotated release tag") { |value| options[:ref] = value }
          opts.on("--output-dir PATH", "Artifact directory outside the repository") do |value|
            options[:output_dir] = value
          end
          opts.on("--channel CHANNEL", "candidate or stable for a version tag") do |value|
            options[:channel] = value
          end
          opts.on("--public-repository OWNER/REPO", "Use GitHub release URLs instead of private build paths") do |value|
            options[:public_repository] = value
          end
        end
        parser.parse!(arguments)
        raise OptionParser::MissingArgument, "--ref" unless options[:ref]
        raise OptionParser::InvalidArgument, "unexpected argument(s): #{arguments.join(' ')}" unless arguments.empty?

        if command == "build"
          result = build_release(
            repository: options[:repository],
            ref: options[:ref],
            output_dir: options[:output_dir],
            channel: options[:channel],
            public_repository: options[:public_repository],
          )
          $stdout.puts(JSON.pretty_generate(result))
        else
          result = verify_release(
            repository: options[:repository],
            ref: options[:ref],
            output_dir: options[:output_dir],
          )
          $stdout.puts(JSON.pretty_generate(result))
        end
        0
      rescue ReleaseDigest::RefusedEntry => error
        $stderr.puts("REFUSED: #{error.message}")
        ReleaseDigest::EXIT_REFUSED
      rescue ManifestError, ReleaseDigest::DigestError, OptionParser::ParseError => error
        $stderr.puts("ERROR: #{error.message}")
        2
      end
    end
  end
end

exit WorkflowKit::Release::ReleaseManifest.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
