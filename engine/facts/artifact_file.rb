#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"

module WorkflowKit
  # Opens an external deployment artifact without following any symbolic-link
  # component. Each path component is resolved relative to the already-opened
  # parent directory, so parent-directory rename or symlink swaps cannot redirect
  # the file descriptor used for fstat and hashing.
  module ArtifactFile
    module LibC
      extend Fiddle::Importer
      dlload Fiddle.dlopen(nil)
      extern "int openat(int, const char*, int, int)"
    end

    class Refused < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    Snapshot = Struct.new(:digest, :identity, keyword_init: true) do
      def same_artifact?(other)
        other.is_a?(Snapshot) && identity == other.identity && digest == other.digest
      end
    end

    module_function

    def open_component(parent, name)
      flags = File::RDONLY | File::NONBLOCK | File::NOFOLLOW
      descriptor = LibC.openat(parent.fileno, name, flags, 0)
      if descriptor.negative?
        error_number = Fiddle.last_error
        code = error_number == Errno::ELOOP::Errno ? :symlink : :unavailable
        raise Refused.new(code, "cannot securely open deployment artifact component #{name.inspect}")
      end

      io = IO.new(descriptor, "rb", autoclose: true)
      io.binmode
      io.close_on_exec = true
      io
    rescue SystemCallError, ArgumentError => error
      raise Refused.new(:unavailable, "cannot securely open deployment artifact component #{name.inspect}: #{error.message}")
    end

    def with_open_regular(path)
      raise Refused.new(:unavailable, "deployment artifact path is required") if path.to_s.empty?

      absolute = File.expand_path(path)
      segments = absolute.split(File::SEPARATOR).reject(&:empty?)
      current = File.open(File::SEPARATOR, File::RDONLY | File::NONBLOCK)
      current.close_on_exec = true

      segments.each_with_index do |segment, index|
        child = open_component(current, segment)
        stat = child.stat
        final = index == segments.length - 1
        if final
          unless stat.file?
            child.close
            raise Refused.new(:not_regular, "deployment artifact must be a regular file")
          end
        elsif !stat.directory?
          child.close
          raise Refused.new(:not_directory, "deployment artifact parent must be a directory")
        end
        current.close
        current = child
      end

      stat = current.stat
      raise Refused.new(:not_regular, "deployment artifact must be a regular file") unless stat.file?
      yield current
    ensure
      current.close if current && !current.closed?
    end

    def identity(stat)
      {
        "device" => stat.dev,
        "inode" => stat.ino,
        "mode" => stat.mode,
        "size" => stat.size,
        "mtime" => [stat.mtime.to_i, stat.mtime.nsec],
        "ctime" => [stat.ctime.to_i, stat.ctime.nsec],
      }
    end

    def snapshot(path)
      with_open_regular(path) do |io|
        before = io.stat
        digest = Digest::SHA256.new
        bytes = 0
        io.rewind
        while (chunk = io.read(1024 * 1024))
          digest.update(chunk)
          bytes += chunk.bytesize
        end
        after = io.stat
        unless identity(before) == identity(after) && bytes == after.size
          raise Refused.new(:changed, "deployment artifact changed while it was being hashed")
        end

        Snapshot.new(
          digest: "sha256:#{digest.hexdigest}",
          identity: identity(after),
        )
      end
    end
  end
end
