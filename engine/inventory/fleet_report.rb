#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"

module WorkflowKit
  module FleetReport
    KIT_ROOT = File.realpath(File.expand_path("../..", __dir__))
    STATUS = File.join(KIT_ROOT, "engine", "install", "status.rb")

    module_function

    def git(root, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
      raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?
      stdout
    end

    def status(root)
      stdout, stderr, process = Open3.capture3(RbConfig.ruby, STATUS, "--json", root)
      record = JSON.parse(stdout)
      record["status_exit_code"] = process.exitstatus
      record
    rescue JSON::ParserError => error
      { "target" => root, "state" => "invalid", "error" => "status output was invalid JSON: #{error.message}", "status_stderr" => stderr.to_s.lines.first.to_s.strip }
    end

    def record(path)
      root = File.realpath(path)
      raise ArgumentError, "not a Git top-level: #{root}" unless File.realpath(git(root, "rev-parse", "--show-toplevel").strip) == root
      item = status(root)
      item.delete("plan") # may expose local paths or a huge per-file plan; fleet report needs counts only
      item["project_id"] ||= begin
        manifest = item["manifest"] || {}
        manifest["project_id"] || File.basename(root)
      end
      item["head"] = git(root, "rev-parse", "HEAD").strip
      item["branch"] = git(root, "symbolic-ref", "--quiet", "--short", "HEAD").strip
      item["drift_state"] = case item["state"]
      when "current" then "none"
      when "upgrade_available", "not_installed" then "action_required"
      when "review_required", "legacy_review", "legacy_unknown" then "review_required"
      else "blocked"
      end
      item
    rescue ArgumentError, SystemCallError => error
      { "target" => File.expand_path(path), "state" => "invalid", "drift_state" => "blocked", "error" => error.message }
    end

    def build(paths)
      {
        "report_schema" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "read_only" => true,
        "repos" => paths.map { |path| record(path) }.sort_by { |item| item["target"] },
      }
    end

    def markdown(report)
      rows = report["repos"].map do |item|
        desired = item.dig("source", "kit_version") || "unknown"
        installed = item.dig("manifest", "kit_version") || "none"
        "| #{item['project_id']} | #{desired} | #{installed} | #{item['drift_state']} | #{item['state']} |"
      end
      <<~MARKDOWN
        # Workflow Kit Fleet Status

        Generated: #{report['generated_at']}

        | Project | Desired | Installed | Drift state | Status |
        |---|---:|---:|---|---|
        #{rows.join("\n")}
      MARKDOWN
    end

    def write(report, output)
      output = File.expand_path(output)
      FileUtils.mkdir_p(output)
      File.write(File.join(output, "report.json"), JSON.pretty_generate(report) + "\n")
      File.write(File.join(output, "report.md"), markdown(report))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: fleet_report.rb --out DIRECTORY REPOSITORY..."
    opts.on("--out DIRECTORY") { |value| options[:out] = value }
  end
  parser.parse!(ARGV)
  abort parser.to_s unless options[:out] && !ARGV.empty?
  report = WorkflowKit::FleetReport.build(ARGV)
  WorkflowKit::FleetReport.write(report, options[:out])
  puts JSON.generate({ "repos" => report["repos"].length, "output" => File.expand_path(options[:out]) })
  exit(report["repos"].any? { |repo| repo["state"] == "invalid" } ? 40 : 0)
end
