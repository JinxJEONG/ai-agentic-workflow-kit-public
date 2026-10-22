#!/usr/bin/env ruby

require "json"
require "open3"

def git_value(target, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", target, *args)
  [stdout.strip, stderr.strip, status.success?]
end

requested_target = ARGV.first || Dir.pwd
begin
  target = File.realpath(requested_target)
rescue Errno::ENOENT, Errno::EACCES => error
  abort "Missing or inaccessible target directory: #{requested_target} (#{error.message})"
end
abort "Target is not a directory: #{target}" unless Dir.exist?(target)

inside, git_error, inside_git = git_value(target, "rev-parse", "--is-inside-work-tree")
inside_git &&= inside == "true"
top_level = nil
if inside_git
  value, error, ok = git_value(target, "rev-parse", "--show-toplevel")
  if ok
    top_level = File.realpath(value)
  else
    git_error = error
    inside_git = false
  end
end

dot_git = File.join(target, ".git")
git_dir_kind = if File.directory?(dot_git)
  "directory"
elsif File.file?(dot_git)
  "file"
else
  "missing"
end

linked_worktree = false
if inside_git
  git_dir_value, = git_value(target, "rev-parse", "--git-dir")
  common_dir_value, = git_value(target, "rev-parse", "--git-common-dir")
  git_dir = File.realpath(File.expand_path(git_dir_value, target))
  common_dir = File.realpath(File.expand_path(common_dir_value, target))
  linked_worktree = git_dir != common_dir
end

facts = {
  requested_root: File.expand_path(requested_target),
  root: target,
  name: File.basename(target),
  has_git: inside_git,
  git_top_level: top_level,
  is_git_top_level: inside_git && top_level == target,
  git_dir_kind: git_dir_kind,
  linked_worktree: linked_worktree,
  valid_install_target: inside_git && top_level == target,
  git_error: git_error.empty? ? nil : git_error,
  has_package_json: File.file?(File.join(target, "package.json")),
  has_pyproject: File.file?(File.join(target, "pyproject.toml")),
  has_requirements: File.file?(File.join(target, "requirements.txt")),
  has_apps_dir: Dir.exist?(File.join(target, "apps")),
  candidate_services: Dir.glob(File.join(target, "{apps,services}", "*")).select { |path| Dir.exist?(path) }.map { |path| path.delete_prefix("#{target}/") },
}

puts JSON.pretty_generate(facts)
