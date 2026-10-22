#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "open3"

module WorkflowKit
  module SourceTree
    Entry = Struct.new(:path, :mode, :object_id, :content, keyword_init: true)
    REGULAR_MODES = %w[100644 100755].freeze

    module_function

    def git(root, *arguments, binary: false)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      stdout.force_encoding(Encoding::BINARY) if binary
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def glob_match?(path, pattern)
      pattern_segments = pattern.to_s.split("/", -1)
      path_segments = path.to_s.split("/", -1)
      glob_segments_match?(pattern_segments, path_segments, 0, 0, {})
    end

    # File.fnmatch? with FNM_PATHNAME treats a trailing `**` like a single
    # path segment. Registry globs use the Git-style meaning instead: a `**`
    # segment consumes zero or more complete path segments. Match segments
    # explicitly while retaining Ruby's character-class and extglob behavior
    # inside ordinary segments.
    def glob_segments_match?(pattern_segments, path_segments, pattern_index, path_index, memo)
      key = [pattern_index, path_index]
      return memo[key] if memo.key?(key)

      result = if pattern_index == pattern_segments.length
                 path_index == path_segments.length
               elsif pattern_segments[pattern_index] == "**"
                 glob_segments_match?(
                   pattern_segments, path_segments, pattern_index + 1, path_index, memo,
                 ) || (
                   path_index < path_segments.length &&
                   glob_segments_match?(
                     pattern_segments, path_segments, pattern_index, path_index + 1, memo,
                   )
                 )
               elsif path_index < path_segments.length
                 segment_matches = File.fnmatch?(
                   pattern_segments[pattern_index],
                   path_segments[path_index],
                   File::FNM_DOTMATCH | File::FNM_EXTGLOB,
                 )
                 segment_matches && glob_segments_match?(
                   pattern_segments, path_segments, pattern_index + 1, path_index + 1, memo,
                 )
               else
                 false
               end

      memo[key] = result
    end

    def entries(root, globs, ref: "HEAD")
      root = File.realpath(root)
      patterns = Array(globs).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "at least one source glob is required" if patterns.empty?

      raw = git(root, "ls-tree", "-r", "-z", ref, binary: true)
      selected = raw.split("\0".b).reject(&:empty?).map do |record|
        header, path = record.split("\t".b, 2)
        next unless header && path

        mode, type, object_id = header.split(" ".b, 3).map(&:to_s)
        path = path.dup.force_encoding(Encoding::UTF_8)
        next unless patterns.any? { |pattern| glob_match?(path, pattern) }
        unless type == "blob" && REGULAR_MODES.include?(mode)
          raise ArgumentError, "non-regular source entry refused: mode=#{mode} type=#{type} path=#{path.inspect}"
        end

        content = git(root, "cat-file", "blob", object_id, binary: true)
        Entry.new(path: path, mode: mode, object_id: object_id, content: content)
      end.compact
      selected.sort_by { |entry| entry.path.b }
    end

    def digest(entries)
      value = Digest::SHA256.new
      entries.each do |entry|
        value.update(entry.path.b)
        value.update("\0")
        value.update(entry.mode)
        value.update("\0")
        value.update(Digest::SHA256.hexdigest(entry.content))
        value.update("\n")
      end
      "sha256:#{value.hexdigest}"
    end
  end
end
