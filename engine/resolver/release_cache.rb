#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open-uri"
require "open3"
require "optparse"
require "pathname"
require "tmpdir"
require "uri"

require_relative "../release/release_digest"

module WorkflowKit
  module Release
    class ResolutionError < StandardError; end

    module ReleaseCache
      module_function

      def fetch(locator, destination)
        uri = URI.parse(locator.to_s)
        case uri.scheme
        when "file"
          unless uri.host.nil? || uri.host.empty? || uri.host == "localhost"
            raise ResolutionError, "file release locator must not name a remote host"
          end
          source = File.realpath(URI::DEFAULT_PARSER.unescape(uri.path))
          FileUtils.cp(source, destination)
        when "https"
          URI.open(uri, "rb") { |input| File.open(destination, "wb") { |output| IO.copy_stream(input, output) } }
        else
          raise ResolutionError, "unsupported release locator scheme #{uri.scheme.inspect}"
        end
        destination
      rescue URI::InvalidURIError, OpenURI::HTTPError, SystemCallError => error
        raise ResolutionError, "cannot fetch release input: #{error.message}"
      end

      def sha256(path)
        "sha256:#{Digest::SHA256.file(path).hexdigest}"
      end

      def safe_archive_entries!(archive)
        raw, error, status = Open3.capture3("tar", "-tzf", archive)
        raise ResolutionError, "cannot list release archive: #{error.strip}" unless status.success?
        raw.lines.each do |line|
          path = line.strip.sub(%r{/\z}, "")
          next if path.empty?
          candidate = Pathname.new(path)
          if candidate.absolute? || path.split("/").include?("..")
            raise ResolutionError, "release archive contains an unsafe path"
          end
        end

        # Refuse links and special files before extraction. Digest verification
        # also rejects them, but that check happens after tar has written to
        # disk and is therefore too late to prevent link traversal.
        verbose, verbose_error, verbose_status = Open3.capture3("tar", "-tvzf", archive)
        unless verbose_status.success?
          raise ResolutionError, "cannot inspect release archive: #{verbose_error.strip}"
        end
        verbose.each_line do |line|
          next if line.strip.empty?

          entry_type = line.getbyte(0)
          next if entry_type == "-".ord || entry_type == "d".ord

          raise ResolutionError, "release archive contains a non-regular entry"
        end
      end

      def resolve(lock, cache_root: ENV["KIT_RELEASE_CACHE"] || File.join(Dir.home, ".cache", "orca", "kit-releases"))
        expected = lock["kit_bundle_digest"].to_s
        unless expected.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise ResolutionError, "lock kit_bundle_digest is missing or invalid"
        end
        expected_manifest = lock["release_manifest_digest"].to_s
        unless expected_manifest.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise ResolutionError, "lock release_manifest_digest is missing or invalid"
        end
        source = lock["source"]
        raise ResolutionError, "lock source is missing" unless source.is_a?(Hash)

        if File.symlink?(cache_root)
          raise ResolutionError, "release cache root must not be a symbolic link"
        end
        FileUtils.mkdir_p(cache_root, mode: 0o700)
        resolved_cache_root = File.realpath(cache_root)
        digest_key = expected.delete_prefix("sha256:")
        cache_dir = File.join(resolved_cache_root, digest_key)
        metadata_dir = File.join(resolved_cache_root, ".metadata")
        complete = File.join(metadata_dir, "#{digest_key}.json")
        lock_path = File.join(resolved_cache_root, ".lock-#{digest_key}")
        File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock_file|
          lock_file.flock(File::LOCK_EX)
          return resolve_locked(
            lock,
            expected: expected,
            expected_manifest: expected_manifest,
            source: source,
            cache_dir: cache_dir,
            metadata_dir: metadata_dir,
            complete: complete,
          )
        end
      rescue JSON::ParserError => error
        raise ResolutionError, "release metadata is invalid JSON: #{error.message}"
      end

      def resolve_locked(lock, expected:, expected_manifest:, source:, cache_dir:, metadata_dir:, complete:)
        if File.symlink?(metadata_dir) || File.symlink?(complete)
          raise ResolutionError, "release cache metadata must not be a symbolic link"
        end
        if File.exist?(cache_dir) && File.symlink?(cache_dir)
          raise ResolutionError, "release cache entry must not be a symbolic link"
        end
        recover_interrupted_publish!(cache_dir, complete)
        if File.file?(complete) && File.directory?(cache_dir)
          data = JSON.parse(File.read(complete))
          if data["kit_bundle_digest"] == expected && data["release_manifest_digest"] == expected_manifest
            Dir.mktmpdir("workflow-kit-release-manifest-") do |temporary|
              manifest_path = fetch(source["manifest_locator"], File.join(temporary, "release.manifest.json"))
              unless sha256(manifest_path) == expected_manifest
                raise ResolutionError, "release manifest checksum mismatch"
              end
            end
            actual = "sha256:#{WorkflowKit::Release::ReleaseDigest.digest_from_directory(cache_dir, excludes: data["excluded_paths"])}"
            raise ResolutionError, "cached release contents do not match their digest" unless actual == expected
            return cache_dir
          end
        end
        if File.exist?(cache_dir) || File.exist?(complete)
          raise ResolutionError, "incomplete or mismatched release cache entry exists"
        end

        Dir.mktmpdir("workflow-kit-release-") do |temporary|
          archive = fetch(source["locator"], File.join(temporary, "release.tar.gz"))
          manifest_path = fetch(source["manifest_locator"], File.join(temporary, "release.manifest.json"))
          unless sha256(manifest_path) == expected_manifest
            raise ResolutionError, "release manifest checksum mismatch"
          end
          expected_archive = source["bundle_archive_sha256"].to_s
          raise ResolutionError, "release archive checksum mismatch" unless sha256(archive) == expected_archive
          manifest = JSON.parse(File.read(manifest_path))
          raise ResolutionError, "release is not pinnable" unless manifest["pinnable"] == true
          raise ResolutionError, "release manifest digest does not match the lock" unless manifest["kit_bundle_digest"] == expected
          safe_archive_entries!(archive)
          unpacked = File.join(temporary, "unpacked")
          FileUtils.mkdir_p(unpacked)
          system("tar", "-xzf", archive, "-C", unpacked) or raise ResolutionError, "cannot unpack release archive"
          roots = Dir.children(unpacked).map { |child| File.join(unpacked, child) }.select { |child| File.directory?(child) }
          release_root = roots.length == 1 ? roots.first : unpacked
          actual = "sha256:#{WorkflowKit::Release::ReleaseDigest.digest_from_directory(release_root, excludes: manifest["excluded_paths"])}"
          raise ResolutionError, "release contents do not match the lock" unless actual == expected

          staging = "#{cache_dir}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          FileUtils.mkdir_p(File.dirname(cache_dir), mode: 0o700)
          FileUtils.cp_r(release_root, staging)
          metadata = JSON.pretty_generate({
            "kit_bundle_digest" => expected,
            "release_manifest_digest" => expected_manifest,
            "kit_version" => manifest["kit_version"],
            "release_commit" => manifest["release_commit"],
            "excluded_paths" => manifest["excluded_paths"],
          }) + "\n"
          FileUtils.mkdir_p(metadata_dir, mode: 0o700)
          metadata_staging = "#{complete}.tmp-#{Process.pid}-#{Thread.current.object_id}"
          File.open(metadata_staging, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(metadata)
            file.flush
            file.fsync
          end
          # Publish the payload first and the metadata as the completion marker.
          # A process kill between the two renames leaves a recognizable payload-
          # only state that the next resolver can discard and reconstruct while
          # holding the same per-digest lock.
          File.rename(staging, cache_dir)
          begin
            File.rename(metadata_staging, complete)
          rescue StandardError
            FileUtils.rm_rf(cache_dir)
            raise
          end
        ensure
          FileUtils.rm_rf(staging) if staging && File.exist?(staging)
          FileUtils.rm_f(metadata_staging) if metadata_staging && File.exist?(metadata_staging)
        end
        cache_dir
      end

      def recover_interrupted_publish!(cache_dir, complete)
        cache_exists = File.exist?(cache_dir)
        marker_exists = File.exist?(complete)

        if cache_exists && !File.directory?(cache_dir)
          raise ResolutionError, "release cache entry must be a directory"
        end
        if marker_exists && !File.file?(complete)
          raise ResolutionError, "release cache metadata marker must be a regular file"
        end
        return if cache_exists == marker_exists

        # Both paths are content-addressed, resolver-owned derived state. A
        # one-sided pair can only be an interrupted publish; remove that exact
        # artifact so resolution can safely rebuild it from the independently
        # verified archive and manifest.
        FileUtils.rm_rf(cache_dir) if cache_exists
        FileUtils.rm_f(complete) if marker_exists
      rescue SystemCallError => error
        raise ResolutionError, "cannot recover interrupted release cache publish: #{error.message}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: release_cache.rb --lock FILE [--cache DIR]"
    opts.on("--lock FILE") { |value| options[:lock] = value }
    opts.on("--cache DIR") { |value| options[:cache_root] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless options[:lock] && ARGV.empty?
  require "yaml"
  lock = YAML.safe_load(File.read(options.delete(:lock)), permitted_classes: [], permitted_symbols: [], aliases: false)
  begin
    puts WorkflowKit::Release::ReleaseCache.resolve(lock, **options)
  rescue WorkflowKit::Release::ResolutionError => error
    warn error.message
    exit 30
  end
end
