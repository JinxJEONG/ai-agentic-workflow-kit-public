# frozen_string_literal: true

require "rake/testtask"
require "yaml"

require_relative "engine/release/release_manifest"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
  task.verbose = true
end

desc "Check Ruby and POSIX shell syntax"
task :syntax do
  ruby_files = Dir[
    "engine/**/*.rb",
    "installer/**/*.rb",
    "core/project-template/.ai/runtime/scripts/*.rb",
    "script/*.rb",
    "test/**/*.rb",
  ]
  shell_files = Dir[
    "core/project-template/.ai/runtime/githooks/*",
    "core/project-template/.ai/runtime/scripts/*.sh",
  ]
  python_files = Dir["adapters/**/*.py"]
  javascript_files = Dir["adapters/**/*.mjs"]

  ruby_files.each { |path| sh RbConfig.ruby, "-c", path }
  shell_files.each { |path| sh "/bin/sh", "-n", path }
  python_files.each do |path|
    sh ENV.fetch("PYTHON", "python3"), "-c", "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read(), filename=sys.argv[1])", path
  end
  javascript_files.each { |path| sh ENV.fetch("NODE", "node"), "--check", path }
end

desc "Reject high-confidence secret material from the repository"
task :security do
  sh RbConfig.ruby, "script/scan_secrets.rb"
end

desc "Parse bundled GitHub Actions workflows as YAML"
task :workflow_yaml do
  Dir[".github/workflows/*.{yml,yaml}", "core/project-template/.github/workflows/*.{yml,yaml}"].sort.each do |path|
    YAML.parse_file(path)
  end
end

desc "Parse repository JSON policy files"
task :policy_json do
  require "json"
  Dir["release-channels.json", "schemas/*.json"].sort.each { |path| JSON.parse(File.read(path)) }
end

namespace :release do
  desc "Build release artifacts for an annotated tag (RELEASE_OUTPUT_DIR may override output)"
  task :build, [:ref] do |_task, arguments|
    ref = arguments[:ref]
    abort "usage: rake release:build[ANNOTATED_TAG]" if ref.to_s.empty?

    result = WorkflowKit::Release::ReleaseManifest.build_release(
      repository: __dir__,
      ref: ref,
      output_dir: ENV["RELEASE_OUTPUT_DIR"],
      channel: ENV["RELEASE_CHANNEL"],
      public_repository: ENV["RELEASE_PUBLIC_REPOSITORY"],
    )
    result.fetch("paths").each do |kind, path|
      puts "#{kind}: #{path}"
    end
  rescue WorkflowKit::Release::ReleaseDigest::RefusedEntry => error
    warn "REFUSED: #{error.message}"
    exit WorkflowKit::Release::ReleaseDigest::EXIT_REFUSED
  end

  desc "Verify release archive, checksum, manifest, and extracted tree digest"
  task :verify, [:ref] do |_task, arguments|
    ref = arguments[:ref]
    abort "usage: rake release:verify[ANNOTATED_TAG]" if ref.to_s.empty?

    manifest = WorkflowKit::Release::ReleaseManifest.verify_release(
      repository: __dir__,
      ref: ref,
      output_dir: ENV["RELEASE_OUTPUT_DIR"],
    )
    puts "verified: #{manifest.fetch('release_ref')} #{manifest.fetch('kit_bundle_digest')}"
  rescue WorkflowKit::Release::ReleaseDigest::RefusedEntry => error
    warn "REFUSED: #{error.message}"
    exit WorkflowKit::Release::ReleaseDigest::EXIT_REFUSED
  end
end

task default: %i[syntax workflow_yaml policy_json test security]
