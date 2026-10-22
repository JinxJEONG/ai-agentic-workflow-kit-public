# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "uri"

require_relative "install_integrity"
require_relative "release_digest"
require_relative "../../engine/resolver/release_cache"

module WorkflowKit
  module Install
    module ReleaseSource
      class SourceError < StandardError; end

      module_function

      def locator_path(value, base: nil)
        raw = value.to_s
        raise SourceError, "release manifest locator is missing" if raw.empty?

        uri = URI.parse(raw)
        if uri.scheme.nil?
          File.expand_path(raw, base || Dir.pwd)
        elsif uri.scheme == "file"
          raise SourceError, "file release manifest locator must not name a remote host" unless uri.host.nil? || uri.host.empty? || uri.host == "localhost"
          URI::DEFAULT_PARSER.unescape(uri.path)
        else
          raise SourceError, "unsupported release manifest locator scheme #{uri.scheme.inspect}; use a reviewed local sidecar"
        end
      rescue URI::InvalidURIError => error
        raise SourceError, "invalid release manifest locator: #{error.message}"
      end

      def file_uri(path)
        "file://#{URI::DEFAULT_PARSER.escape(File.expand_path(path))}"
      end

      def load_manifest(path)
        resolved = File.realpath(path)
        bytes = File.binread(resolved)
        value = JSON.parse(bytes)
        raise SourceError, "release manifest must contain a JSON object" unless value.is_a?(Hash)
        [resolved, value, bytes]
      rescue Errno::ENOENT, Errno::EACCES => error
        raise SourceError, "cannot read reviewed release manifest #{path}: #{error.message}"
      rescue JSON::ParserError => error
        raise SourceError, "cannot parse reviewed release manifest #{path}: #{error.message}"
      end

      def expected_from(previous_manifest, explicit)
        return explicit unless explicit.nil? || explicit.to_s.empty?
        return nil unless previous_manifest.is_a?(Hash)
        previous_manifest["kit_bundle_digest"]
      end

      def expected_manifest_from(previous_manifest, explicit)
        return explicit unless explicit.nil? || explicit.to_s.empty?
        return nil unless previous_manifest.is_a?(Hash)
        previous_manifest["release_manifest_digest"]
      end

      def manifest_locator_from(previous_manifest, explicit)
        return explicit unless explicit.nil? || explicit.to_s.empty?
        return nil unless previous_manifest.is_a?(Hash)
        source = previous_manifest["source"]
        source.is_a?(Hash) ? source["manifest_locator"] : nil
      end

      def production_context(kit_root, previous_manifest, manifest_locator:, expected_bundle_digest:, expected_manifest_digest:)
        locator = manifest_locator_from(previous_manifest, manifest_locator)
        raise SourceError, "production plan/apply requires --source-manifest or a reviewed manifest_locator in the project lock" if locator.to_s.empty?

        expected_value = expected_from(previous_manifest, expected_bundle_digest)
        expected = Integrity.digest_label(expected_value, "expected kit bundle digest")
        expected_manifest_value = expected_manifest_from(previous_manifest, expected_manifest_digest)
        expected_manifest = Integrity.digest_label(expected_manifest_value, "expected release manifest digest")
        path, manifest, manifest_bytes = load_manifest(locator_path(locator, base: kit_root))
        actual_manifest = "sha256:#{Digest::SHA256.hexdigest(manifest_bytes)}"
        unless actual_manifest == expected_manifest
          raise SourceError, "release manifest bytes do not match the independently reviewed expected digest"
        end
        unless manifest["bundle_digest_algo"] == WorkflowKit::Release::ReleaseDigest::BUNDLE_DIGEST_ALGO
          raise SourceError, "release manifest bundle_digest_algo must be #{WorkflowKit::Release::ReleaseDigest::BUNDLE_DIGEST_ALGO}"
        end
        unless manifest["dirty_snapshot_algo"] == Integrity::DIRTY_SNAPSHOT_ALGO
          raise SourceError, "release manifest dirty_snapshot_algo must be #{Integrity::DIRTY_SNAPSHOT_ALGO}"
        end

        unless manifest["pinnable"] == true
          raise SourceError, "release manifest is not pinnable"
        end
        release_ref = manifest["release_ref"].to_s
        release_commit = manifest["release_commit"].to_s
        unless release_ref.start_with?("refs/tags/") && !release_ref.include?("..")
          raise SourceError, "pinnable release manifest must bind a safe refs/tags release_ref"
        end
        unless release_commit.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
          raise SourceError, "pinnable release manifest must bind a release_commit"
        end
        manifest_digest = Integrity.digest_label(manifest["kit_bundle_digest"], "release manifest kit_bundle_digest")
        unless manifest_digest == expected
          raise SourceError, "release manifest kit_bundle_digest does not match the reviewed expected digest"
        end

        excluded_paths = Array(manifest["excluded_paths"])
        source = manifest["source"]
        raise SourceError, "release manifest source must be a mapping" unless source.is_a?(Hash)
        unless %w[local github-release].include?(source["kind"].to_s)
          raise SourceError, "production release source.kind must be local or github-release"
        end
        source_locator = source["locator"].to_s
        archive_digest = Integrity.digest_label(source["bundle_archive_sha256"], "release archive digest")
        raise SourceError, "release manifest source.locator is missing" if source_locator.empty?

        reviewed_manifest_locator = file_uri(path)
        resolved_source = source.merge(
          "manifest_locator" => reviewed_manifest_locator,
          "bundle_archive_sha256" => archive_digest,
        )
        lock = {
          "kit_bundle_digest" => expected,
          "release_manifest_digest" => expected_manifest,
          "source" => resolved_source,
        }
        resolved_root = WorkflowKit::Release::ReleaseCache.resolve(lock)

        actual_hex = WorkflowKit::Release::ReleaseDigest.digest_from_directory(
          resolved_root,
          excludes: excluded_paths,
        )
        actual = "sha256:#{actual_hex}"
        unless actual == expected
          raise SourceError, "resolved release content does not match the reviewed expected kit_bundle_digest"
        end

        rules = Integrity.validate_ownership_rules!(manifest["ownership_rules"])
        protected_paths = Array(manifest["protected_paths"])
        approval_required_paths = Array(manifest["approval_required_paths"])
        (protected_paths + approval_required_paths).each do |glob|
          if glob.to_s.empty? || Pathname.new(glob.to_s).absolute? || glob.to_s.split(/[\\\/]/).include?("..")
            raise SourceError, "release manifest contains an unsafe protected or approval-required path"
          end
        end

        {
          "kind" => "release",
          "kit_version" => manifest["kit_version"].to_s,
          "kit_bundle_digest" => expected,
          "bundle_digest_algo" => Integer(manifest.fetch("bundle_digest_algo")),
          "rendered_digest_algo" => Integer(manifest.fetch("rendered_digest_algo", Integrity::RENDERED_DIGEST_ALGO)),
          "dirty_snapshot_algo" => Integer(manifest.fetch("dirty_snapshot_algo", Integrity::DIRTY_SNAPSHOT_ALGO)),
          "pinnable" => true,
          "release_manifest_digest" => expected_manifest,
          "release_manifest_path" => path,
          "ownership_rules" => rules.map(&:dup),
          "protected_paths" => protected_paths,
          "approval_required_paths" => approval_required_paths,
          "tombstones" => Array(manifest["tombstones"]),
          "source" => resolved_source,
          "resolved_release_root" => resolved_root,
          "provenance" => (manifest["provenance"].is_a?(Hash) ? manifest["provenance"].dup : {}).merge(
            "release_ref" => release_ref,
            "release_commit" => release_commit,
          ),
        }
      rescue ArgumentError, KeyError, Integrity::IntegrityError, WorkflowKit::Release::ReleaseDigest::DigestError, WorkflowKit::Release::ResolutionError => error
        raise SourceError, error.message
      end

      def resolve(kit_root:, previous_manifest:, manifest_locator:, expected_bundle_digest:, expected_manifest_digest:)
        production_context(
          kit_root,
          previous_manifest,
          manifest_locator: manifest_locator,
          expected_bundle_digest: expected_bundle_digest,
          expected_manifest_digest: expected_manifest_digest,
        )
      end
    end
  end
end
