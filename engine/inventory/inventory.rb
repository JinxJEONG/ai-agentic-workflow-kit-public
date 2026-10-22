#!/usr/bin/env ruby

require "find"
require "json"
require "open3"
require "optparse"
require "rbconfig"

KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
STATUS = File.join(KIT_ROOT, "engine", "install", "status.rb")

options = { json: false, max_depth: 6 }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: inventory.rb [options] ROOT..."
  opts.on("--json", "Print machine-readable inventory") { options[:json] = true }
  opts.on("--max-depth N", Integer, "Maximum scan depth (default: 6)") { |value| options[:max_depth] = value }
end
parser.parse!(ARGV)

roots = ARGV
if roots.empty?
  warn parser
  exit 40
end

invalid_roots = []

def marker_directory?(path)
  File.file?(File.join(path, ".ai", "KIT_INSTALLATION.yaml")) ||
    File.file?(File.join(path, ".ai", "ACTIVE_CONTEXT.yaml")) ||
    File.file?(File.join(path, ".ai", "runtime", "scripts", "validate_agent_structure.rb")) ||
    File.file?(File.join(path, ".ai", "scripts", "validate_agent_structure.rb"))
end

def status_for(path)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, STATUS, "--json", path)
  return JSON.parse(stdout) unless stdout.empty?

  { "target" => path, "state" => "invalid", "exit_code" => status.exitstatus, "error" => stderr }
rescue JSON::ParserError
  { "target" => path, "state" => "invalid", "exit_code" => status.exitstatus, "error" => [stdout, stderr].reject(&:empty?).join("\n") }
end

targets = {}
roots.each do |root|
  begin
    root = File.realpath(root)
    raise Errno::ENOTDIR unless Dir.exist?(root)
  rescue SystemCallError => error
    invalid_roots << { "root" => root, "error" => "#{error.class}: #{error.message}" }
    next
  end
  Find.find(root) do |path|
    if File.directory?(path)
      relative = path.delete_prefix("#{root}/")
      depth = relative == path ? 0 : relative.split(File::SEPARATOR).length
      if depth > options[:max_depth]
        Find.prune
        next
      end
      if %w[.git .Trash ai-agentic-workflow-kit node_modules .local].include?(File.basename(path))
        Find.prune
        next
      end
      if File.basename(path) == ".ai"
        candidate = File.dirname(path)
        targets[File.realpath(candidate)] = true if marker_directory?(candidate)
      end
      next
    end
    next unless %w[ACTIVE_CONTEXT.yaml KIT_INSTALLATION.yaml].include?(File.basename(path))

    candidate = File.dirname(File.dirname(path))
    targets[File.realpath(candidate)] = true if marker_directory?(candidate)
  end
end

records = targets.keys.sort.map { |target| status_for(target) }
if options[:json]
  puts JSON.pretty_generate({ "source" => { "kit_root" => KIT_ROOT }, "roots" => invalid_roots, "projects" => records })
else
  puts "Workflow Kit inventory (#{records.length} project(s))"
  invalid_roots.each { |root| puts "- invalid root #{root['root']}: #{root['error']}" }
  records.each do |record|
    puts "- #{record['state']} #{record['target']} (dirty=#{record.dig('worktree', 'dirty_entries')})"
  end
end

exit(invalid_roots.empty? ? 0 : 40)
