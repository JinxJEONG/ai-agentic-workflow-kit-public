# frozen_string_literal: true

require "digest"
require "find"
require "open3"
require "optparse"
require "pathname"

module WorkflowKit
  module Release
    # Computes release identities from Git trees. The digest deliberately does
    # not depend on a checkout, archive format, timestamp, uid, or gid.
    module ReleaseDigest
      BUNDLE_DIGEST_ALGO = 2
      EXIT_REFUSED = 3
      DEFAULT_EXCLUDES = [
        ".github/**",
        ".gitignore",
        ".memsearch/**",
        "test/**",
      ].freeze
      AUXILIARY_INCLUDES = {
        "template_tree_digest" => ["core/project-template/**"].freeze,
        "engine_digest" => ["engine/**"].freeze,
        "test_tree_digest" => ["test/**"].freeze,
      }.freeze
      REGULAR_MODES = ["100644", "100755"].freeze

      class DigestError < StandardError; end
      class RefusedEntry < DigestError; end

      module_function

      def capture_binary(*command)
        stdout, stderr, status = Open3.capture3(*command, binmode: true)
        return stdout if status.success?

        detail = stderr.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
        detail = "exit #{status.exitstatus}" if detail.empty?
        raise DigestError, "command failed (#{command.join(' ')}): #{detail}"
      rescue SystemCallError => error
        raise DigestError, "cannot run #{command.first}: #{error.message}"
      end

      # Git's pathspec rules are not used here: the manifest records portable
      # slash-separated globs. A trailing /** means the complete subtree.
      def glob_match?(pattern, path)
        pattern = pattern.to_s.b
        path = path.to_s.b
        if pattern.end_with?("/**".b)
          prefix = pattern.byteslice(0, pattern.bytesize - 2)
          return true if path.start_with?(prefix)
        end

        flags = File::FNM_PATHNAME | File::FNM_DOTMATCH
        File.fnmatch?(pattern, path, flags) || File.fnmatch?(pattern, path, File::FNM_DOTMATCH)
      end

      def selected_path?(path, includes:, excludes:)
        return false if excludes.any? { |pattern| glob_match?(pattern, path) }
        return true if includes.nil?

        includes.any? { |pattern| glob_match?(pattern, path) }
      end

      def tree_entries(repository, ref)
        raw = capture_binary("git", "-C", File.expand_path(repository), "ls-tree", "-r", "-z", ref.to_s)
        raw.split("\0".b).reject(&:empty?).map do |record|
          metadata, path = record.split("\t".b, 2)
          mode, type, oid = metadata.to_s.split(" ".b, 3)
          unless path && mode && type && oid
            raise DigestError, "malformed git ls-tree record"
          end

          {
            mode: mode.to_s,
            type: type.to_s,
            oid: oid.to_s,
            path: path.dup.force_encoding(Encoding::BINARY),
          }
        end
      end

      def validate_bundle_policy!(includes, excludes)
        return unless includes.nil?

        normalized = excludes.map(&:to_s)
        return if normalized == DEFAULT_EXCLUDES

        raise DigestError,
          "bundle_digest_algo #{BUNDLE_DIGEST_ALGO} requires excluded_paths=#{DEFAULT_EXCLUDES.inspect}"
      end

      def rows_from_tree(repository, ref, includes:, excludes:, enforce_bundle_policy:)
        validate_bundle_policy!(includes, excludes) if enforce_bundle_policy
        selected = tree_entries(repository, ref).select do |entry|
          selected_path?(entry.fetch(:path), includes: includes, excludes: excludes)
        end

        # Validate the whole selected set before reading or emitting any
        # digest material. This prevents a partial digest on refusal.
        selected.each do |entry|
          mode = entry.fetch(:mode)
          type = entry.fetch(:type)
          next if REGULAR_MODES.include?(mode) && type == "blob"

          raise RefusedEntry,
            "non-regular entry: mode=#{mode} type=#{type} path=#{display_path(entry.fetch(:path))}"
        end

        selected.map do |entry|
          content = capture_binary(
            "git", "-C", File.expand_path(repository), "cat-file", "blob", entry.fetch(:oid)
          )
          path = entry.fetch(:path)
          [path, Digest::SHA256.hexdigest(content), entry.fetch(:mode)]
        end
      end

      def digest_rows(rows)
        sorted = rows.sort { |left, right| left.first <=> right.first }
        material = +"workflow-kit-bundle-digest\0#{BUNDLE_DIGEST_ALGO}\0#{sorted.length}\0".b
        sorted.each do |path, content_digest, mode|
          material << path.bytesize.to_s.b << ":".b << path
          material << mode.bytesize.to_s.b << ":".b << mode.b
          material << content_digest.bytesize.to_s.b << ":".b << content_digest.b
        end
        Digest::SHA256.hexdigest(material)
      end

      def kit_bundle_digest(repository, ref, includes: nil, excludes: DEFAULT_EXCLUDES)
        rows = rows_from_tree(
          repository,
          ref,
          includes: includes,
          excludes: Array(excludes),
          enforce_bundle_policy: true,
        )
        digest_rows(rows)
      end

      def digest(repository, ref, includes: nil, excludes: DEFAULT_EXCLUDES)
        kit_bundle_digest(repository, ref, includes: includes, excludes: excludes)
      end

      # Computes a subset with caller-supplied include/exclude globs. This is
      # used for auxiliary and source-tree digests, not bundle identity.
      def subset_digest(repository, ref, includes:, excludes: [])
        rows = rows_from_tree(
          repository,
          ref,
          includes: Array(includes),
          excludes: Array(excludes),
          enforce_bundle_policy: false,
        )
        digest_rows(rows)
      end

      def auxiliary_digests(repository, ref)
        AUXILIARY_INCLUDES.each_with_object({}) do |(name, includes), result|
          result[name] = subset_digest(repository, ref, includes: includes, excludes: [])
        end
      end

      def strict_filesystem_root(root)
        candidate = root.to_s
        unless Pathname.new(candidate).absolute? && Pathname.new(candidate).cleanpath.to_s == candidate
          raise DigestError, "filesystem tree root must be normalized and absolute: #{root}"
        end
        expanded = File.expand_path(candidate)

        current = File::SEPARATOR
        expanded.delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
          next if component.empty?

          current = current == File::SEPARATOR ? "#{current}#{component}" : File.join(current, component)
          stat = File.lstat(current)
          if stat.symlink?
            raise RefusedEntry, "filesystem tree path contains a symbolic link: #{current}"
          end
        end
        raise DigestError, "filesystem tree root is not a directory: #{expanded}" unless File.directory?(expanded)

        expanded
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => error
        raise DigestError, "cannot resolve filesystem tree root #{root}: #{error.message}"
      end

      def digest_regular_file(absolute, relative, initial_stat)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(absolute, flags) do |file|
          opened_stat = file.stat
          unless opened_stat.file? && opened_stat.dev == initial_stat.dev && opened_stat.ino == initial_stat.ino
            raise RefusedEntry, "filesystem entry changed while hashing: path=#{display_path(relative)}"
          end
          permissions = opened_stat.mode & 0o7777
          unless [0o644, 0o755].include?(permissions)
            raise RefusedEntry,
              "non-canonical regular-file mode=#{format('%04o', permissions)} path=#{display_path(relative)}"
          end

          digest = Digest::SHA256.new
          buffer = +"".b
          digest.update(buffer) while file.read(64 * 1024, buffer)
          mode = permissions == 0o755 ? "100755" : "100644"
          [relative, digest.hexdigest, mode]
        end
      rescue Errno::ELOOP => error
        raise RefusedEntry, "symbolic link refused while hashing #{display_path(relative)}: #{error.message}"
      end

      def rows_from_directory(root, includes:, excludes:, enforce_bundle_policy:, strict_root: false)
        validate_bundle_policy!(includes, excludes) if enforce_bundle_policy
        root = strict_root ? strict_filesystem_root(root) : File.realpath(root)
        rows = []

        Find.find(root) do |absolute|
          next if absolute == root

          binary_absolute = absolute.dup.force_encoding(Encoding::BINARY)
          prefix = "#{root}#{File::SEPARATOR}".b
          relative = binary_absolute.byteslice(
            prefix.bytesize,
            binary_absolute.bytesize - prefix.bytesize,
          ).dup
          stat = File.lstat(absolute)

          if relative == ".git".b && stat.directory?
            Find.prune
            next
          end
          next if relative == ".git".b || relative.start_with?(".git/".b)
          next if stat.directory?
          next unless selected_path?(relative, includes: includes, excludes: excludes)

          unless stat.file?
            mode = stat.symlink? ? "120000" : format("%06o", stat.mode & 0o177777)
            raise RefusedEntry,
              "non-regular entry: mode=#{mode} path=#{display_path(relative)}"
          end

          rows << digest_regular_file(absolute, relative, stat)
        end
        rows
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR => error
        raise DigestError, "cannot read release directory #{root}: #{error.message}"
      end

      # Computes bundle identity from a downloaded action or extracted archive
      # without trusting Git metadata. The caller-provided path is preserved
      # long enough to reject symlinked roots and parent components.
      def kit_bundle_digest_from_filesystem(root, includes: nil, excludes: DEFAULT_EXCLUDES)
        rows = rows_from_directory(
          root,
          includes: includes,
          excludes: Array(excludes),
          enforce_bundle_policy: true,
          strict_root: true,
        )
        digest_rows(rows)
      end

      # Recomputes bundle identity after extracting a release archive. .git is
      # unconditionally ignored even if a caller supplies unusual exclusions.
      def digest_from_directory(root, excludes: DEFAULT_EXCLUDES)
        rows = rows_from_directory(
          root,
          includes: nil,
          excludes: Array(excludes),
          enforce_bundle_policy: true,
          strict_root: false,
        )
        digest_rows(rows)
      end

      def subset_digest_from_directory(root, includes:, excludes: [])
        rows = rows_from_directory(
          root,
          includes: Array(includes),
          excludes: Array(excludes),
          enforce_bundle_policy: false,
          strict_root: false,
        )
        digest_rows(rows)
      end

      def auxiliary_digests_from_directory(root)
        AUXILIARY_INCLUDES.each_with_object({}) do |(name, includes), result|
          result[name] = subset_digest_from_directory(root, includes: includes, excludes: [])
        end
      end

      def display_path(path)
        path.to_s.encode("UTF-8", invalid: :replace, undef: :replace).inspect
      end

      def run_cli(arguments)
        options = {
          repository: Dir.pwd,
          ref: "HEAD",
          filesystem_root: nil,
          repository_explicit: false,
          ref_explicit: false,
          includes: [],
          excludes: nil,
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: release_digest.rb [--repo PATH --ref REF | --filesystem-root PATH]"
          opts.on("--repo PATH", "Git repository (default: current directory)") do |value|
            options[:repository] = value
            options[:repository_explicit] = true
          end
          opts.on("--ref REF", "Git ref (default: HEAD)") do |value|
            options[:ref] = value
            options[:ref_explicit] = true
          end
          opts.on("--filesystem-root PATH", "Downloaded action or extracted archive tree") do |value|
            options[:filesystem_root] = value
          end
          opts.on("--include GLOB", "Limit the digest to a glob (repeatable)") do |value|
            options[:includes] << value
          end
          opts.on("--exclude GLOB", "Override bundle exclusions (repeatable)") do |value|
            options[:excludes] ||= []
            options[:excludes] << value
          end
        end
        parser.parse!(arguments)
        raise OptionParser::InvalidArgument, "unexpected argument(s): #{arguments.join(' ')}" unless arguments.empty?
        if options[:filesystem_root] && (options[:repository_explicit] || options[:ref_explicit])
          raise OptionParser::InvalidArgument,
            "--filesystem-root cannot be combined with --repo or --ref"
        end

        includes = options[:includes].empty? ? nil : options[:includes]
        excludes = options[:excludes] || (includes ? [] : DEFAULT_EXCLUDES)
        value = if options[:filesystem_root]
          kit_bundle_digest_from_filesystem(
            options[:filesystem_root], includes: includes, excludes: excludes,
          )
        elsif includes
          subset_digest(options[:repository], options[:ref], includes: includes, excludes: excludes)
        else
          kit_bundle_digest(options[:repository], options[:ref], excludes: excludes)
        end
        $stdout.puts(value)
        0
      rescue RefusedEntry => error
        $stderr.puts("REFUSED: #{error.message}")
        EXIT_REFUSED
      rescue DigestError, OptionParser::ParseError => error
        $stderr.puts("ERROR: #{error.message}")
        2
      end
    end
  end
end

exit WorkflowKit::Release::ReleaseDigest.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
