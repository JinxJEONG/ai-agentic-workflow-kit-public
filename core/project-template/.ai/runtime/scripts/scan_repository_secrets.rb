#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "optparse"

options = { root: Dir.pwd, range: nil }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: scan_repository_secrets.rb [--range BASE..HEAD] [REPOSITORY]"
  opts.on("--range RANGE", "Scan added or modified blobs in an exact Git range") { |value| options[:range] = value }
end
parser.parse!(ARGV)
if ARGV.length > 1
  warn parser.to_s
  exit 2
end

requested_root = ARGV.fetch(0, options.fetch(:root))
stdout, stderr, status = Open3.capture3("git", "-C", requested_root, "rev-parse", "--show-toplevel")
unless status.success?
  warn "Secret scan requires a Git work tree: #{stderr.strip}"
  exit 2
end
root = File.realpath(stdout.strip)

patterns = {
  "private-key" => Regexp.new(["-----BEGIN ", "(?:RSA |EC |OPENSSH )?", "PRIVATE KEY-----"].join),
  "aws-access-key" => Regexp.new(["\\b(?:AK", "IA|AS", "IA)[0-9A-Z]{16}\\b"].join),
  "github-token" => Regexp.new(["\\bgh", "(?:p|o|u|s|r)_", "[A-Za-z0-9]{30,}\\b"].join),
  "openai-key" => Regexp.new(["\\bsk", "-(?:proj-)?", "[A-Za-z0-9_-]{20,}\\b"].join),
  "slack-token" => Regexp.new(["\\bxox", "(?:b|p|a|r|s)-", "[A-Za-z0-9-]{20,}\\b"].join),
}.freeze

range = options[:range].to_s
range_source = nil
if range.empty?
  stdout, stderr, status = Open3.capture3(
    "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"
  )
else
  unless range.match?(/\A[0-9a-f]{40,64}\.\.[0-9a-f]{40,64}\z/)
    warn "Secret scan range must be exact BASE..HEAD object ids"
    exit 2
  end
  range_source = range.split("..", 2).last
  stdout, stderr, status = Open3.capture3(
    "git", "-C", root, "diff", "--name-only", "--diff-filter=ACMR", "-z", range, "--"
  )
end
unless status.success?
  warn "Secret scan could not enumerate repository files: #{stderr.strip}"
  exit 2
end

findings = []
stdout.split("\0").reject(&:empty?).sort.each do |relative_path|
  content = if range_source
    entry, entry_error, entry_status = Open3.capture3(
      "git", "-C", root, "ls-tree", "-z", range_source, "--", relative_path
    )
    unless entry_status.success?
      warn "Secret scan could not inspect #{relative_path}: #{entry_error.strip}"
      exit 2
    end
    record = entry.split("\0").reject(&:empty?)
    next if record.empty?
    match = record.fetch(0).match(/\A[0-7]{6} blob ([0-9a-f]{40,64})\t/m)
    unless match
      warn "Secret scan refuses non-blob changed path: #{relative_path}"
      exit 2
    end
    blob, blob_error, blob_status = Open3.capture3("git", "-C", root, "cat-file", "blob", match[1])
    unless blob_status.success?
      warn "Secret scan could not read #{relative_path}: #{blob_error.strip}"
      exit 2
    end
    blob.b
  else
    path = File.join(root, relative_path)
    next unless File.file?(path)
    next if File.size(path) > 2 * 1024 * 1024
    File.binread(path)
  end
  next if content.bytesize > 2 * 1024 * 1024
  next if content.include?("\0")

  content.force_encoding(Encoding::UTF_8)
  next unless content.valid_encoding?

  content.each_line.with_index(1) do |line, line_number|
    patterns.each do |name, pattern|
      findings << [relative_path, line_number, name] if line.match?(pattern)
    end
  end
end

unless findings.empty?
  warn "Potential secrets detected (values are intentionally omitted):"
  findings.each { |path, line, rule| warn "- #{path}:#{line} [#{rule}]" }
  exit 1
end

puts "OK: no high-confidence secret patterns detected."
