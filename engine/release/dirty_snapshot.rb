# frozen_string_literal: true

require "digest"
require "fiddle"
require "json"
require "open3"
require "optparse"

require_relative "release_digest"

module WorkflowKit
  module Release
    # Content-aware identity for the uncommitted state of a Git worktree.
    # Worktree bytes and index bytes are intentionally represented separately.
    module DirtySnapshot
      DIRTY_SNAPSHOT_ALGO = 4
      DOMAIN_SEPARATOR = "ai-harness-governance-dirty-snapshot\0".b.freeze
      EMPTY_SHA256 = Digest::SHA256.hexdigest("".b).freeze
      GIT_READ_ENV = { "GIT_OPTIONAL_LOCKS" => "0" }.freeze
      SCOPE_MODES = %w[
        all
        custom
        plan_targets_plus_harness_allowlist
      ].freeze
      SPECIAL_ENTRY_OPEN_ERRNOS = [
        Errno::EACCES::Errno,
        Errno::EPERM::Errno,
        Errno::ENODEV::Errno,
        Errno::ENXIO::Errno,
        Errno::EOPNOTSUPP::Errno,
        Errno::ENOTSUP::Errno,
      ].uniq.freeze

      class SnapshotError < StandardError; end

      module NativeAt
        class OpenError < StandardError
          attr_reader :errno

          def initialize(errno)
            @errno = errno
            super("openat failed")
          end
        end

        module_function

        def openat_function
          @openat_function ||= Fiddle::Function.new(
            Fiddle.dlopen(nil)["openat"],
            [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
            Fiddle::TYPE_INT,
          )
        rescue Fiddle::DLError
          raise SnapshotError, "platform does not provide required openat support"
        end

        def readlinkat_function
          @readlinkat_function ||= Fiddle::Function.new(
            Fiddle.dlopen(nil)["readlinkat"],
            [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T],
            Fiddle::TYPE_SSIZE_T,
          )
        rescue Fiddle::DLError
          raise SnapshotError, "platform does not provide required readlinkat support"
        end

        def c_string(value)
          raise SnapshotError, "unsafe worktree path component" if value.empty? || value.include?("\0".b)

          value.b + "\0".b
        end

        def open_io(parent_fd, name)
          unless File.const_defined?(:NOFOLLOW)
            raise SnapshotError, "platform does not provide required no-follow support"
          end

          flags = File::RDONLY | File::NOFOLLOW
          flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
          flags |= File::CLOEXEC if File.const_defined?(:CLOEXEC)
          name_bytes = c_string(name)
          fd = openat_function.call(parent_fd, Fiddle::Pointer[name_bytes], flags)
          raise OpenError.new(Fiddle.last_error) if fd.negative?

          io = IO.for_fd(fd, "rb", autoclose: true)
          io.close_on_exec = true
          io
        rescue OpenError, SnapshotError
          raise
        rescue SystemCallError, ArgumentError => error
          begin
            if defined?(io) && io
              io.close unless io.closed?
            elsif defined?(fd) && fd && fd >= 0
              IO.for_fd(fd).close
            end
          rescue StandardError
            nil
          end
          raise SnapshotError, "cannot secure worktree entry: #{error.class}"
        end

        def readlink(parent_fd, name)
          size = 256
          name_bytes = c_string(name)
          loop do
            buffer = Fiddle::Pointer.malloc(size)
            length = readlinkat_function.call(parent_fd, Fiddle::Pointer[name_bytes], buffer, size)
            if length.negative?
              raise OpenError.new(Fiddle.last_error)
            end
            return buffer.to_s(length).force_encoding(Encoding::BINARY) if length < size

            size *= 2
            raise SnapshotError, "worktree symlink target is too large" if size > 1024 * 1024
          end
        end
      end

      module_function

      def capture_binary(*command)
        stdout, stderr, status = Open3.capture3(GIT_READ_ENV, *command, binmode: true)
        return stdout if status.success?

        detail = stderr.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
        detail = "exit #{status.exitstatus}" if detail.empty?
        raise SnapshotError, "command failed (#{command.join(' ')}): #{detail}"
      rescue SystemCallError => error
        raise SnapshotError, "cannot run #{command.first}: #{error.message}"
      end

      def status_entries(worktree)
        raw = capture_binary(
          "git", "-C", worktree, "status", "--porcelain=v1", "-z",
          "--untracked-files=all", "--ignore-submodules=none"
        )
        parse_status(raw)
      end

      def parse_status(raw)
        return [] if raw.empty?

        records = raw.split("\0".b, -1)
        raise SnapshotError, "malformed git status output" unless records.last == "".b

        records.pop
        entries = []
        index = 0

        while index < records.length
          record = records[index]
          index += 1
          if record.bytesize < 4 || record.getbyte(2) != 32
            raise SnapshotError, "malformed git status record"
          end

          xy = record.byteslice(0, 2)
          path = record.byteslice(3, record.bytesize - 3).dup.force_encoding(Encoding::BINARY)
          origin = nil
          if rename_or_copy?(xy)
            origin = records[index]
            if origin.nil? || origin.empty?
              raise SnapshotError, "rename/copy status is missing its origin path"
            end
            origin = origin.dup.force_encoding(Encoding::BINARY)
            index += 1
          end
          entries << { xy: xy, path: path, origin: origin }
        end
        entries
      end

      def rename_or_copy?(xy)
        [xy.getbyte(0), xy.getbyte(1)].any? { |byte| byte == 82 || byte == 67 }
      end

      def index_entries(worktree)
        raw = capture_binary(
          "git", "-C", worktree, "--literal-pathspecs", "ls-files", "--stage", "-z"
        )
        parse_index(raw)
      end

      def parse_index(raw)
        return {} if raw.empty?

        records = raw.split("\0".b, -1)
        raise SnapshotError, "malformed git index output" unless records.last == "".b

        records.pop
        records.each_with_object({}) do |record, result|
          metadata, path = record.split("\t".b, 2)
          mode, oid, stage = metadata.to_s.split(" ".b, 3)
          unless path && !path.empty? && mode && oid && stage && stage.match?(/\A[0-3]\z/)
            raise SnapshotError, "malformed git index record"
          end

          path = path.dup.force_encoding(Encoding::BINARY)
          result[path] ||= []
          result[path] << { mode: mode.to_s, oid: oid.to_s, stage: stage.to_s }
        end
      end

      def normalize_scope_values(values)
        Array(values).map do |value|
          string = value.to_s.dup
          string.force_encoding(Encoding::BINARY)
          raise ArgumentError, "dirty snapshot scope values cannot contain NUL" if string.include?("\0".b)
          raise ArgumentError, "dirty snapshot scope values cannot be empty" if string.empty?

          string
        end.uniq.sort
      end

      def normalize_scope(scope_globs:, scope_paths:, scope_mode:)
        globs = normalize_scope_values(scope_globs)
        paths = normalize_scope_values(scope_paths)
        mode = scope_mode.to_s
        mode = paths.empty? && globs.empty? ? "all" : "custom" if mode.empty?
        unless SCOPE_MODES.include?(mode)
          raise ArgumentError, "unsupported dirty snapshot scope mode: #{mode.inspect}"
        end
        if mode == "all" && (!paths.empty? || !globs.empty?)
          raise ArgumentError, "dirty snapshot all scope cannot include paths or globs"
        end
        if mode != "all" && paths.empty? && globs.empty?
          raise ArgumentError, "dirty snapshot scoped mode must include paths or globs"
        end

        { mode: mode, paths: paths, globs: globs }
      end

      def scope_glob_match?(pattern, path)
        flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
        candidates = [pattern.b]
        if pattern.end_with?("/**".b)
          candidates << (pattern.byteslice(0, pattern.bytesize - 2) + "**/*".b)
        end
        candidates.any? { |candidate| File.fnmatch(candidate, path.b, flags) }
      end

      def selected?(entry, scope)
        return true if scope.fetch(:mode) == "all"

        paths = [entry.fetch(:path), entry[:origin]].compact
        paths.any? do |path|
          scope.fetch(:paths).any? { |candidate| candidate.b == path.b } ||
            scope.fetch(:globs).any? { |pattern| scope_glob_match?(pattern, path) }
        end
      end

      def same_file_identity?(left, right)
        left.dev == right.dev && left.ino == right.ino && left.ftype == right.ftype
      end

      def stable_stat?(left, right)
        same_file_identity?(left, right) &&
          left.mode == right.mode &&
          left.nlink == right.nlink &&
          left.size == right.size &&
          left.mtime == right.mtime &&
          left.ctime == right.ctime
      end

      def directory_stat(directory)
        IO.for_fd(directory.fileno, "rb", autoclose: false).stat
      end

      def close_directory(directory)
        directory.close
      rescue IOError
        nil
      end

      def secure_path_components(path)
        normalized = path.b.dup
        normalized = normalized.byteslice(0, normalized.bytesize - 1) while normalized.end_with?("/".b)
        components = normalized.split("/".b, -1)
        if normalized.empty? || components.any? { |component| component.empty? || component == ".".b || component == "..".b }
          raise SnapshotError, "unsafe worktree path"
        end
        components
      end

      def open_directory_handle(anchored_io, logical_path)
        keep_directory = false
        expected = anchored_io.stat
        unless expected.directory?
          raise SnapshotError, "worktree path changed while calculating dirty snapshot"
        end

        directory = Dir.open(logical_path)
        actual = directory_stat(directory)
        unless actual.directory? && stable_stat?(expected, actual)
          raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
        end
        keep_directory = true
        [directory, actual]
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
      ensure
        close_directory(directory) if defined?(directory) && directory && !keep_directory
        anchored_io.close unless anchored_io.closed?
      end

      def validate_directory_chain!(worktree, checks)
        root = checks.fetch(0)
        root_path_stat = File.lstat(worktree)
        root_handle_stat = directory_stat(root.fetch(:directory))
        unless root_path_stat.directory? &&
            stable_stat?(root.fetch(:initial), root_path_stat) &&
            stable_stat?(root.fetch(:initial), root_handle_stat)
          raise SnapshotError, "worktree root changed while calculating dirty snapshot"
        end

        checks.drop(1).each do |check|
          begin
            current = NativeAt.open_io(check.fetch(:parent).fileno, check.fetch(:name))
            current_stat = current.stat
            handle_stat = directory_stat(check.fetch(:directory))
            unless current_stat.directory? &&
                stable_stat?(check.fetch(:initial), current_stat) &&
                stable_stat?(check.fetch(:initial), handle_stat)
              raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
            end
          rescue NativeAt::OpenError
            raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
          ensure
            current.close if defined?(current) && current && !current.closed?
          end
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
      end

      def with_parent_directory(worktree, path)
        directories = []
        checks = []
        validate_chain = false
        components = secure_path_components(path)
        root_before = File.lstat(worktree)
        root = Dir.open(worktree)
        directories << root
        root_opened = directory_stat(root)
        unless root_before.directory? && stable_stat?(root_before, root_opened)
          raise SnapshotError, "worktree root changed while calculating dirty snapshot"
        end

        checks = [{ directory: root, initial: root_opened }]
        logical = worktree.b
        components[0...-1].each do |component|
          logical = File.join(logical, component)
          parent = directories.last
          anchored = NativeAt.open_io(parent.fileno, component)
          directory, opened_stat = open_directory_handle(anchored, logical)
          directories << directory
          checks << {
            directory: directory,
            initial: opened_stat,
            parent: parent,
            name: component,
          }
        rescue NativeAt::OpenError => error
          if [Errno::ENOENT::Errno, Errno::ENOTDIR::Errno].include?(error.errno)
            validate_chain = true
            return yield(nil, components.last, nil)
          end
          raise SnapshotError, "worktree path changed while calculating dirty snapshot"
        end

        validate_chain = true
        yield(directories.last, components.last, File.join(logical, components.last))
      ensure
        begin
          validate_directory_chain!(worktree, checks) if validate_chain
        ensure
          directories.reverse_each { |directory| close_directory(directory) }
        end
      end

      def read_io_chunk(io, buffer)
        io.read(64 * 1024, buffer)
      end

      def regular_io_digest(io)
        before = io.stat
        raise SnapshotError, "worktree entry is not a regular file" unless before.file?

        digest = Digest::SHA256.new
        buffer = +"".b
        digest << buffer while read_io_chunk(io, buffer)
        after = io.stat
        unless stable_stat?(before, after)
          raise SnapshotError, "worktree file changed while calculating dirty snapshot"
        end
        digest.hexdigest
      end

      def symlink_digest(parent_directory, name)
        Digest::SHA256.hexdigest(NativeAt.readlink(parent_directory.fileno, name))
      rescue NativeAt::OpenError
        raise SnapshotError, "worktree symlink changed while calculating dirty snapshot"
      end

      # Sockets cannot be opened as ordinary file descriptors on the supported
      # platforms. Verify their lstat through the same anchored parent before
      # classifying them as an opaque special entry.
      def secure_other_entry?(parent_directory, logical_path)
        anchored_before = directory_stat(parent_directory)
        logical_parent = Dir.open(File.dirname(logical_path))
        logical_before = directory_stat(logical_parent)
        unless same_file_identity?(anchored_before, logical_before)
          raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
        end

        entry_before = File.lstat(logical_path)
        entry_after = File.lstat(logical_path)
        logical_after = directory_stat(logical_parent)
        anchored_after = directory_stat(parent_directory)
        unless stable_stat?(entry_before, entry_after) &&
            stable_stat?(logical_before, logical_after) &&
            stable_stat?(anchored_before, anchored_after)
          raise SnapshotError, "worktree entry changed while calculating dirty snapshot"
        end

        !entry_before.file? && !entry_before.directory? && !entry_before.symlink?
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise SnapshotError, "worktree entry changed while calculating dirty snapshot"
      ensure
        close_directory(logical_parent) if defined?(logical_parent) && logical_parent
      end

      def worktree_state(worktree, path)
        with_parent_directory(worktree, path) do |parent, name, logical_path|
          return ["m", EMPTY_SHA256] unless parent

          begin
            io = NativeAt.open_io(parent.fileno, name)
          rescue NativeAt::OpenError => error
            if error.errno == Errno::ELOOP::Errno
              return ["l", symlink_digest(parent, name)]
            end
            if [Errno::ENOENT::Errno, Errno::ENOTDIR::Errno].include?(error.errno)
              return ["m", EMPTY_SHA256]
            end
            if SPECIAL_ENTRY_OPEN_ERRNOS.include?(error.errno) && secure_other_entry?(parent, logical_path)
              return ["o", EMPTY_SHA256]
            end
            raise SnapshotError, "cannot securely open worktree entry"
          end

          begin
            stat = io.stat
            return ["f", regular_io_digest(io)] if stat.file?
            if stat.directory?
              directory, opened_stat = open_directory_handle(io, logical_path)
              begin
                return ["d", tree_digest(directory, logical_path, opened_stat)]
              ensure
                close_directory(directory)
              end
            end
            ["o", EMPTY_SHA256]
          ensure
            io.close if defined?(io) && io && !io.closed?
          end
        end
      end

      # Porcelain may collapse an untracked directory to one entry (notably a
      # nested Git clone). Hash every regular descendant so changes below that
      # entry invalidate a reviewed plan instead of looking like an empty file.
      def tree_digest(root_directory, root_path, root_before = nil)
        root_before ||= directory_stat(root_directory)
        rows = []
        collect_tree_rows(root_directory, root_path.b, "".b, rows, root_before)
        material = rows.sort { |left, right| left.first <=> right.first }.map do |relative, type, digest|
          line = +type.b
          line << "\t".b << digest.b << "\t".b << relative << "\0".b
          line
        end.join
        Digest::SHA256.hexdigest(material)
      end

      def directory_children(directory)
        directory.rewind
        children = []
        directory.each_child do |child|
          children << child.dup.force_encoding(Encoding::BINARY)
        end
        children
      end

      def collect_tree_rows(directory, logical_path, prefix, rows, expected_stat = nil)
        before = directory_stat(directory)
        unless before.directory? && (!expected_stat || same_file_identity?(expected_stat, before))
          raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
        end
        children = directory_children(directory)
        children.each do |child|
          relative = prefix.empty? ? child : File.join(prefix, child)
          child_path = File.join(logical_path, child)
          begin
            io = NativeAt.open_io(directory.fileno, child)
          rescue NativeAt::OpenError => error
            if error.errno == Errno::ELOOP::Errno
              rows << [relative, "l", symlink_digest(directory, child)]
              next
            end
            if SPECIAL_ENTRY_OPEN_ERRNOS.include?(error.errno) && secure_other_entry?(directory, child_path)
              rows << [relative, "o", EMPTY_SHA256]
              next
            end
            raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
          end

          stat = io.stat
          if stat.file?
            rows << [relative, "f", regular_io_digest(io)]
          elsif stat.directory?
            rows << [relative, "d", EMPTY_SHA256]
            child_directory, opened_stat = open_directory_handle(io, child_path)
            begin
              collect_tree_rows(child_directory, child_path, relative, rows, opened_stat)
            ensure
              close_directory(child_directory)
            end
          else
            rows << [relative, "o", EMPTY_SHA256]
          end
        ensure
          io.close if defined?(io) && io && !io.closed?
        end

        after_children = directory_children(directory)
        after = directory_stat(directory)
        unless stable_stat?(before, after) &&
            children.sort { |left, right| left <=> right } == after_children.sort { |left, right| left <=> right }
          raise SnapshotError, "worktree directory changed while calculating dirty snapshot"
        end
      end

      def staged_digest(worktree, path, index, cache)
        candidates = index[path]
        return "-" unless candidates && !candidates.empty?

        selected = candidates.find { |entry| entry.fetch(:stage) == "0" }
        unless selected
          material = candidates.sort_by { |entry| entry.fetch(:stage).to_i }.map do |entry|
            digest = staged_entry_digest(worktree, entry, cache)
            "#{entry.fetch(:stage)}\t#{digest}\n"
          end.join
          return Digest::SHA256.hexdigest(material)
        end

        staged_entry_digest(worktree, selected, cache)
      end

      def staged_entry_digest(worktree, entry, cache)
        return "-" if entry.fetch(:mode) == "160000"

        oid = entry.fetch(:oid)
        cache[oid] ||= Digest::SHA256.hexdigest(
          capture_binary("git", "-C", worktree, "cat-file", "blob", oid)
        )
      end

      def snapshot(worktree, scope_globs: nil, scope_paths: nil, scope_mode: nil)
        worktree = File.realpath(worktree)
        scope = normalize_scope(
          scope_globs: scope_globs,
          scope_paths: scope_paths,
          scope_mode: scope_mode,
        )
        dirty = status_entries(worktree).select { |entry| selected?(entry, scope) }
        index = index_entries(worktree)
        blob_cache = {}

        rows = dirty.map do |entry|
          path = entry.fetch(:path)
          worktree_type, worktree_sha = worktree_state(worktree, path)
          staged_sha = staged_digest(worktree, path, index, blob_cache)
          origin = entry[:origin] || "-".b
          record = [
            entry.fetch(:xy).b,
            worktree_type.b,
            worktree_sha.b,
            staged_sha.b,
            origin.b,
            path.b,
          ]
          serialized = entry.merge(
            worktree_type: worktree_type,
            worktree_sha256: worktree_sha,
            staged_sha256: staged_sha,
          )
          [path, record, serialized]
        end
        rows.sort! { |left, right| left.first <=> right.first }
        material = +DOMAIN_SEPARATOR
        material << "#{DIRTY_SNAPSHOT_ALGO}\0#{rows.length}\0".b
        rows.each do |row|
          row.fetch(1).each do |field|
            material << field.bytesize.to_s.b << ":".b << field
          end
        end
        digest = Digest::SHA256.hexdigest(material)

        {
          "dirty_snapshot_algo" => DIRTY_SNAPSHOT_ALGO,
          "dirty_snapshot_digest" => digest,
          "dirty_snapshot_scope" => serializable_scope(scope),
          "entry_count" => rows.length,
          "entries" => rows.map { |row| serializable_entry(row[2]) },
        }
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES, Errno::ELOOP => error
        raise SnapshotError, "cannot inspect worktree #{worktree}: #{error.message}"
      end

      def digest(worktree, scope_globs: nil, scope_paths: nil, scope_mode: nil)
        snapshot(
          worktree,
          scope_globs: scope_globs,
          scope_paths: scope_paths,
          scope_mode: scope_mode,
        ).fetch("dirty_snapshot_digest")
      end

      def serializable_scope(scope)
        {
          "mode" => scope.fetch(:mode),
          "paths" => scope.fetch(:paths).map { |path| printable(path) },
          "globs" => scope.fetch(:globs).map { |glob| printable(glob) },
        }
      end

      def serializable_entry(entry)
        {
          "xy" => printable(entry.fetch(:xy)),
          "path" => printable(entry.fetch(:path)),
          "origin" => entry[:origin] && printable(entry[:origin]),
          "worktree_type" => entry.fetch(:worktree_type),
          "worktree_sha256" => entry.fetch(:worktree_sha256),
          "staged_sha256" => entry.fetch(:staged_sha256),
        }
      end

      def printable(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      end

      def display_path(path)
        path.to_s.encode("UTF-8", invalid: :replace, undef: :replace).inspect
      end

      def run_cli(arguments)
        options = { worktree: nil, scopes: [], json: false }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: dirty_snapshot.rb --worktree PATH [--scope GLOB]"
          opts.on("--worktree PATH", "Git worktree to inspect") { |value| options[:worktree] = value }
          opts.on("--scope GLOB", "Limit paths to a glob (repeatable)") { |value| options[:scopes] << value }
          opts.on("--json", "Print snapshot metadata as JSON") { options[:json] = true }
        end
        parser.parse!(arguments)
        raise OptionParser::MissingArgument, "--worktree" unless options[:worktree]
        raise OptionParser::InvalidArgument, "unexpected argument(s): #{arguments.join(' ')}" unless arguments.empty?

        result = snapshot(
          options[:worktree],
          scope_globs: options[:scopes].empty? ? nil : options[:scopes],
        )
        if options[:json]
          $stdout.puts(JSON.pretty_generate(result))
        else
          $stdout.puts(result.fetch("dirty_snapshot_digest"))
        end
        0
      rescue SnapshotError, OptionParser::ParseError => error
        $stderr.puts("ERROR: #{error.message}")
        2
      end
    end
  end
end

exit WorkflowKit::Release::DirtySnapshot.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
