#!/usr/bin/env ruby

require "optparse"
require "open3"
require "digest"
require_relative "workflow_lib"
require_relative "workflow_evidence"
require_relative "workflow_policy"
require_relative "adoption_receipt"

options = {
  mode: "staged",
  repo_root: AgentWorkflow::ROOT,
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: validate_change_set.rb --mode staged|pre-push|range [--range REV] [--repo-root PATH]"
  opts.on("--mode MODE", "staged, pre-push, or range") { |value| options[:mode] = value }
  opts.on("--range REV", "Explicit Git diff range for range mode") { |value| options[:range] = value }
  opts.on("--repo-root PATH", "Git repository root") { |value| options[:repo_root] = File.expand_path(value) }
  opts.on("--remote NAME", "Remote name used by pre-push") { |value| options[:remote] = value }
end
parser.parse!(ARGV)

unless %w[staged pre-push range].include?(options[:mode])
  warn "--mode must be staged, pre-push, or range"
  exit 1
end
if options[:mode] == "range" && options[:range].to_s.empty?
  warn "--range is required for range mode"
  exit 1
end

def run_git(repo_root, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", repo_root, *args)
  raise "git #{args.join(' ')} failed: #{stderr.strip}" unless status.success?

  stdout.strip
end

def pushed_ranges(repo_root, remote_name, input)
  ranges = []
  input.each_line do |line|
    local_ref, local_sha, remote_ref, remote_sha = line.split
    next unless local_ref && local_sha && remote_ref && remote_sha
    next if local_sha.match?(/\A0+\z/) # deleting a remote ref changes no tree content

    if remote_sha.match?(/\A0+\z/)
      remote_selector = remote_name.to_s.empty? ? "--remotes" : "--remotes=#{remote_name}"
      commits = run_git(repo_root, "rev-list", "--reverse", local_sha, "--not", remote_selector).lines.map(&:strip).reject(&:empty?)
      next if commits.empty?

      first = commits.first
      parent, _stderr, parent_status = Open3.capture3("git", "-C", repo_root, "rev-parse", "--verify", "#{first}^")
      base = if parent_status.success?
        parent.strip
      else
        empty_tree, empty_stderr, empty_status = Open3.capture3("git", "-C", repo_root, "mktree", stdin_data: "")
        raise "cannot calculate empty tree: #{empty_stderr.strip}" unless empty_status.success?
        empty_tree.strip
      end
      ranges << "#{base}..#{local_sha}"
    else
      ranges << "#{remote_sha}..#{local_sha}"
    end
  end
  ranges.uniq
end

def feature_ids_for_changes(changes)
  ids = Array(AgentWorkflow.active_context["active_streams"]).map { |entry| entry["feature_id"].to_s }
  changes.each do |change|
    WorkflowEvidence.entry_paths(change).each do |path|
      rel = AgentWorkflow.relative_to_root(path)
      ids << AgentWorkflow.task_feature_id(rel).to_s if rel
      next unless File.file?(path) && File.basename(path) == "change-set.yaml"

      data = AgentWorkflow.load_yaml(path, {})
      ids << data["feature_id"].to_s
      ids.concat(Array(data["features"]).map { |item| item.is_a?(Hash) ? item["feature_id"] : item }.map(&:to_s))
    end
  end
  ids = ids.reject(&:empty?).uniq
  return ids unless ids.empty?

  matching = AgentWorkflow.feature_dirs.select do |feature_dir|
    manifests = Dir.glob(File.join(feature_dir, "streams", "*", "manifest.yaml")).map do |path|
      AgentWorkflow.load_yaml(path, {})
    end
    changes.any? do |change|
      WorkflowEvidence.entry_paths(change).any? do |path|
        manifests.any? { |manifest| AgentWorkflow.effective_scopes(manifest).any? { |scope| AgentWorkflow.path_in_scope?(path, scope) } }
      end
    end
  end
  open_features = matching.select do |feature_dir|
    AgentWorkflow.load_yaml(File.join(feature_dir, "feature.yaml"), {})["status"].to_s != "done"
  end
  selected = open_features.empty? ? matching : open_features
  selected.map { |feature_dir| AgentWorkflow.feature_id_from_task_folder(feature_dir) }.uniq
end

def policy_paths_for_feature(feature_id, changes)
  scopes = WorkflowEvidence.feature_scopes(feature_id)
  changes.select do |change|
    task_owned = WorkflowEvidence.entry_paths(change).any? do |path|
      rel = AgentWorkflow.relative_to_root(path)
      rel && AgentWorkflow.task_feature_id(rel).to_s == feature_id
    end
    task_owned || WorkflowEvidence.entry_matches_scopes?(change, scopes)
  end.flat_map { |change| WorkflowEvidence.entry_paths(change) }.uniq
end

def installation_bootstrap_change_set?(changes, repo_root:, range:)
  return false unless AgentWorkflow.feature_dirs.empty?
  return false if !range.to_s.empty? && !WorkflowEvidence.single_commit_range?(repo_root, range)

  manifest_added = changes.any? do |change|
    change["status"].to_s == "A" &&
      change["old_relative_path"].nil? &&
      change["new_relative_path"].to_s == ".ai/KIT_INSTALLATION.yaml"
  end
  return false unless manifest_added

  path = File.join(AgentWorkflow::AI_ROOT, "KIT_INSTALLATION.yaml")
  return false unless File.file?(path)

  manifest = AgentWorkflow.load_yaml(path, {})
  entries = manifest["installed_files"] || manifest["files"]
  allowed = Array(entries).map { |entry| entry.is_a?(Hash) ? entry["path"] : entry }.map(&:to_s)
  allowed << ".ai/KIT_INSTALLATION.yaml"
  return false unless WorkflowEvidence.git_index_contains_paths?(repo_root, allowed)
  return false unless WorkflowEvidence.git_index_matches_worktree?(repo_root, ".ai/KIT_INSTALLATION.yaml")

  changed = changes.flat_map { |change| WorkflowEvidence.entry_paths(change) }.map { |item| AgentWorkflow.relative_to_root(item) }
  !changed.empty? && changed.all? do |item|
    item && allowed.include?(item) && AgentWorkflow.installation_bootstrap_path?(item)
  end
end

def adoption_receipt_change_set?(changes, repo_root:, range:)
  return false if !range.to_s.empty? && !WorkflowEvidence.single_commit_range?(repo_root, range)
  return false unless Array(AgentWorkflow.active_context["active_streams"]).empty?

  receipt_added = changes.any? do |change|
    change["status"].to_s == "A" &&
      change["old_relative_path"].nil? &&
      change["new_relative_path"].to_s == AgentWorkflow::AdoptionReceipt::RECEIPT_PATH
  end
  return false unless receipt_added

  source = range.to_s.empty? ? "index" : range.to_s.split("..", -1).last
  base_source = range.to_s.empty? ? "HEAD" : range.to_s.split("..", -1).first
  begin
    receipt = AgentWorkflow::AdoptionReceipt.verify!(path: repo_root, source: source)
    manifest = AgentWorkflow::AdoptionReceipt.installation_lock(repo_root, source)
  rescue AgentWorkflow::AdoptionReceipt::ReceiptError => error
    puts "[policy] adoption receipt is invalid: #{error.message}"
    return false
  end

  migration = Array(manifest["migration_history"]).reverse.find do |entry|
    entry.is_a?(Hash) && entry["plan_digest"].to_s == receipt["plan_digest"].to_s
  end
  return false unless migration

  approvals = Array(migration["reviewed_path_approvals"]).each_with_object({}) do |entry, result|
    next unless entry.is_a?(Hash)

    result[entry["path"].to_s] = entry
  end
  installed = Array(manifest["installed_files"] || manifest["files"]).each_with_object({}) do |entry, result|
    next unless entry.is_a?(Hash)

    result[entry["path"].to_s] = entry
  end

  changes.all? do |change|
    status = change["status"].to_s
    paths = WorkflowEvidence.entry_relative_paths(change)
    next false if paths.empty? || %w[R C D].include?(status)

    paths.all? do |path|
      if path == ".ai/KIT_INSTALLATION.yaml"
        %w[A M].include?(status)
      elsif path == AgentWorkflow::AdoptionReceipt::RECEIPT_PATH
        status == "A"
      else
        entry = installed[path]
        next false unless entry && AgentWorkflow.installation_bootstrap_path?(path)
        begin
          source_entry = AgentWorkflow::AdoptionReceipt.source_entry(repo_root, source, path)
          source_digest = Digest::SHA256.hexdigest(
            AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, path),
          )
        rescue AgentWorkflow::AdoptionReceipt::ReceiptError
          next false
        end
        installed_digest = entry["sha256"].to_s
        installed_mode = entry["mode"].to_s
        source_mode = format("%04o", source_entry.fetch("mode").to_i(8) & 0o7777)
        next false unless installed_digest.match?(/\A[0-9a-f]{64}\z/) && installed_digest == source_digest
        next false unless installed_mode.match?(/\A[0-7]{3,4}\z/) && format("%04o", installed_mode.to_i(8)) == source_mode

        case entry["ownership"].to_s
        when "kit", "kit-owned", "legacy"
          %w[A M].include?(status)
        when "merge-owned"
          if status == "A"
            true
          elsif status == "M"
            approval = approvals[path]
            expected = approval.is_a?(Hash) ? approval["expected_digest"].to_s : ""
            desired = approval.is_a?(Hash) ? approval["desired_digest"].to_s : ""
            next false unless expected.match?(/\A[0-9a-f]{64}\z/) && desired.match?(/\A[0-9a-f]{64}\z/)

            begin
              base_digest = Digest::SHA256.hexdigest(
                AgentWorkflow::AdoptionReceipt.source_blob(repo_root, base_source, path),
              )
            rescue AgentWorkflow::AdoptionReceipt::ReceiptError
              next false
            end
            expected == base_digest && desired == source_digest && desired == installed_digest
          else
            false
          end
        when "project", "project-owned", "generated"
          status == "A"
        else
          false
        end
      end
    end
  end
end

def immutable_adoption_receipt?(repo_root, source)
  receipt_path = AgentWorkflow::AdoptionReceipt::RECEIPT_PATH
  history_source = source == "index" ? "HEAD" : source
  commits = run_git(
    repo_root, "log", "--diff-filter=A", "--format=%H", history_source, "--", receipt_path,
  ).lines.map(&:strip).reject(&:empty?)
  return false unless commits.length == 1

  adoption_commit = commits.first
  original = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, adoption_commit, receipt_path)
  current = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, receipt_path)
  return false unless original == current

  AgentWorkflow::AdoptionReceipt.verify!(path: repo_root, source: adoption_commit)
  true
rescue AgentWorkflow::AdoptionReceipt::ReceiptError, StandardError => error
  puts "[policy] immutable adoption receipt is invalid: #{error.message}"
  false
end

def phase4_front_matter_only?(repo_root, base_source, source, path)
  base = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, base_source, path)
  head = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, path)
  return false unless head.start_with?("---\n")

  closing = head.index("\n---\n", 4)
  return false unless closing
  metadata = AgentWorkflow.safe_yaml_load(head[4...closing])
  return false unless metadata.is_a?(Hash) && metadata.keys.map(&:to_s) == ["verified_against"]
  verified = metadata["verified_against"]
  return false unless verified.is_a?(Hash)
  return false unless verified.keys.map(&:to_s).sort == %w[rule_id source_tree_digest]
  return false if verified["rule_id"].to_s.empty?
  return false unless verified["source_tree_digest"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)

  head[(closing + 5)..-1] == "\n#{base}"
rescue AgentWorkflow::AdoptionReceipt::ReceiptError, Psych::Exception
  false
end

def phase4_review_gate_digest(content)
  text = content.dup.force_encoding(Encoding::UTF_8)
  return nil unless text.valid_encoding?

  lines = text.lines(chomp: true).map { |line| line.end_with?("\r") ? line[0...-1] : line }
  first_content = lines.index { |line| !line.empty? }
  return nil unless first_content && lines[first_content] == "# Handoff"
  return nil unless lines.grep(/\A# Handoff\z/).length == 1
  return nil if lines.any? { |line| line.match?(/\A[ \t]{0,3}(?:`{3,}|~{3,})/) }
  return nil if text.match?(/<!--|-->|<\/?[A-Za-z][^>]*>/)
  return nil if lines.any? { |line| line.match?(/\A(?:=+|-+)\z/) }

  headings = lines.each_index.select { |index| lines[index].match?(/\A\#{1,6} /) }
  return nil unless headings.all? { |index| lines[index].start_with?("# ", "## ") }
  return nil unless headings.count { |index| lines[index] == "## Review Gate" } == 1
  review_index = headings.find { |index| lines[index] == "## Review Gate" }
  next_heading = headings.find { |index| index > review_index }
  section_lines = lines[(review_index + 1)...(next_heading || lines.length)].reject(&:empty?)
  return nil unless section_lines.length == 2
  return nil unless section_lines[0] == "- Status: passed"
  return nil unless section_lines[1].match?(/\A- Approved Manifest SHA256: [0-9a-f]{64}\z/)

  statuses = text.enum_for(:scan, /^- Status: ([^\r\n]+)\r?$/).map { Regexp.last_match }
  digests = text.enum_for(:scan, /^- Approved Manifest SHA256: ([^\r\n]+)\r?$/).map { Regexp.last_match }
  return nil unless statuses.length == 1 && digests.length == 1
  return nil unless statuses.first[1] == "passed"
  return nil unless digests.first[1].match?(/\A[0-9a-f]{64}\z/)

  digest_start = digests.first.begin(1)
  digest_end = digests.first.end(1)
  {
    "digest" => digests.first[1],
    "normalized" => text[0...digest_start] + "<review-manifest-sha256>" + text[digest_end..-1].to_s,
  }
end

def phase4_reviewer_handoff_rebind?(repo_root, base_source, source, path)
  match = path.match(
    %r{\A\.ai/tasks/(FEATURE-[0-9]{8}-[0-9]{3}(?:--[a-z0-9]+(?:-[a-z0-9]+)*)?)/streams/reviewer/handoff\.md\z},
  )
  return false unless match

  task_root = ".ai/tasks/#{match[1]}"
  feature_path = "#{task_root}/feature.yaml"
  manifest_path = "#{task_root}/streams/reviewer/manifest.yaml"
  handoff_entries = [base_source, source].map do |revision|
    AgentWorkflow::AdoptionReceipt.source_entry(repo_root, revision, path)
  end
  return false unless handoff_entries.all? { |entry| entry.fetch("mode") == "100644" }

  metadata = [feature_path, manifest_path].map do |metadata_path|
    base_entry = AgentWorkflow::AdoptionReceipt.source_entry(repo_root, base_source, metadata_path)
    head_entry = AgentWorkflow::AdoptionReceipt.source_entry(repo_root, source, metadata_path)
    return false unless base_entry.fetch("mode") == "100644" && head_entry.fetch("mode") == "100644"

    base = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, base_source, metadata_path)
    head = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, metadata_path)
    return false unless base == head

    AgentWorkflow.safe_yaml_load(base)
  end
  feature, manifest = metadata
  feature_id = match[1].split("--", 2).first
  return false unless feature.is_a?(Hash) && feature["feature_id"].to_s == feature_id
  return false unless feature["status"].to_s == "done"
  return false unless feature["workflow_tier"].to_s == "tier3"
  return false unless manifest.is_a?(Hash) && manifest["feature_id"].to_s == feature_id
  return false unless manifest["stream_id"].to_s == "reviewer"
  return false unless manifest["stream_type"].to_s == "review"
  return false unless manifest["agent_profile"].to_s == "reviewer"
  return false unless manifest["status"].to_s == "done"
  return false unless manifest["review_required"] == true && manifest["handoff_required"] == true

  base_handoff = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, base_source, path)
  head_handoff = AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, path)
  base_gate = phase4_review_gate_digest(base_handoff)
  head_gate = phase4_review_gate_digest(head_handoff)
  return false unless base_gate && head_gate
  return false if base_gate.fetch("digest") == head_gate.fetch("digest")

  base_gate.fetch("normalized") == head_gate.fetch("normalized")
rescue Psych::Exception, AgentWorkflow::AdoptionReceipt::ReceiptError, StandardError
  false
end

def phase4_registry_bootstrap_change_set?(changes, repo_root:, range:)
  return false if !range.to_s.empty? && !WorkflowEvidence.single_commit_range?(repo_root, range)
  return false unless Array(AgentWorkflow.active_context["active_streams"]).empty?

  registry_path = ".ai/SPEC_REGISTRY.yaml"
  codeowners_path = ".github/CODEOWNERS"
  workflow_path = ".github/workflows/agent-workflow-policy.yml"
  changed = changes.flat_map { |change| WorkflowEvidence.entry_relative_paths(change) }
  return false unless changed.include?(registry_path)
  return false unless changed.include?(codeowners_path)
  return false unless changed.include?(workflow_path)
  registry_added = changes.any? do |change|
    change["status"].to_s == "A" && change["old_relative_path"].nil? &&
      change["new_relative_path"].to_s == registry_path
  end
  return false unless registry_added

  source = range.to_s.empty? ? "index" : range.to_s.split("..", -1).last
  base_source = range.to_s.empty? ? "HEAD" : range.to_s.split("..", -1).first
  return false unless immutable_adoption_receipt?(repo_root, source)

  registry = AgentWorkflow.safe_yaml_load(
    AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, registry_path),
  )
  return false unless registry.is_a?(Hash)
  rules = Array(registry["rules"])
  return false if rules.empty? || rules.any? { |rule| !rule.is_a?(Hash) }

  canonical = rules.flat_map { |rule| Array(rule["canonical_specs"]) }.map(&:to_s)
  generated = rules.flat_map { |rule| Array(rule["generated_facts"]) }.map(&:to_s)
  return false unless canonical.all? { |path| path.start_with?(".ai/canonical/") }
  return false unless generated.all? do |path|
    path.start_with?(".ai/generated/") && path != AgentWorkflow::AdoptionReceipt::RECEIPT_PATH
  end
  governed_paths = [registry_path, codeowners_path] + canonical + generated
  return false if governed_paths.any? do |path|
    path.empty? || path.start_with?("/") || path.split(/[\\\/]/).include?("..")
  end

  manifest = AgentWorkflow::AdoptionReceipt.installation_lock(repo_root, source)
  installed = Array(manifest["installed_files"] || manifest["files"]).each_with_object({}) do |entry, result|
    result[entry["path"].to_s] = entry if entry.is_a?(Hash)
  end
  migration = Array(manifest["migration_history"]).last
  approvals = Array(migration.is_a?(Hash) ? migration["reviewed_path_approvals"] : []).each_with_object({}) do |entry, result|
    result[entry["path"].to_s] = entry if entry.is_a?(Hash)
  end

  reviewer_handoff_pattern = %r{\A\.ai/tasks/FEATURE-[0-9]{8}-[0-9]{3}(?:--[a-z0-9]+(?:-[a-z0-9]+)*)?/streams/reviewer/handoff\.md\z}
  reviewer_handoffs = changes.select do |change|
    WorkflowEvidence.entry_relative_paths(change).any? { |path| path.match?(reviewer_handoff_pattern) }
  end
  return false if reviewer_handoffs.length > 1
  if reviewer_handoffs.length == 1
    handoff_change = reviewer_handoffs.first
    handoff_paths = WorkflowEvidence.entry_relative_paths(handoff_change)
    return false unless handoff_change["status"].to_s == "M" && handoff_paths.length == 1
    return false unless handoff_change["old_relative_path"].nil?
  end
  governance_changes = changes - reviewer_handoffs

  governance_valid = governance_changes.all? do |change|
    status = change["status"].to_s
    paths = WorkflowEvidence.entry_relative_paths(change)
    next false if paths.empty? || %w[R C D].include?(status)

    paths.all? do |path|
      if path == ".ai/KIT_INSTALLATION.yaml"
        status == "M"
      elsif path == registry_path
        status == "A"
      elsif path == codeowners_path
        status == "A"
      elsif canonical.include?(path)
        status == "A" || (status == "M" && phase4_front_matter_only?(repo_root, base_source, source, path))
      elsif generated.include?(path)
        status == "A"
      else
        entry = installed[path]
        next false unless entry && AgentWorkflow.installation_bootstrap_path?(path)
        next false unless %w[kit kit-owned legacy merge-owned].include?(entry["ownership"].to_s)
        next false unless %w[A M].include?(status)

        begin
          source_entry = AgentWorkflow::AdoptionReceipt.source_entry(repo_root, source, path)
          source_digest = Digest::SHA256.hexdigest(
            AgentWorkflow::AdoptionReceipt.source_blob(repo_root, source, path),
          )
        rescue AgentWorkflow::AdoptionReceipt::ReceiptError
          next false
        end
        installed_digest = entry["sha256"].to_s
        installed_mode = entry["mode"].to_s
        source_mode = format("%04o", source_entry.fetch("mode").to_i(8) & 0o7777)
        content_bound = installed_digest.match?(/\A[0-9a-f]{64}\z/) && installed_digest == source_digest &&
          installed_mode.match?(/\A[0-7]{3,4}\z/) && format("%04o", installed_mode.to_i(8)) == source_mode
        next false unless content_bound

        if path == workflow_path
          next false unless status == "M" && entry["ownership"].to_s == "merge-owned"
          approval = approvals[path]
          expected = approval.is_a?(Hash) ? approval["expected_digest"].to_s : ""
          desired = approval.is_a?(Hash) ? approval["desired_digest"].to_s : ""
          begin
            base_digest = Digest::SHA256.hexdigest(
              AgentWorkflow::AdoptionReceipt.source_blob(repo_root, base_source, path),
            )
          rescue AgentWorkflow::AdoptionReceipt::ReceiptError
            next false
          end
          expected.match?(/\A[0-9a-f]{64}\z/) && desired.match?(/\A[0-9a-f]{64}\z/) &&
            expected == base_digest && desired == source_digest && desired == installed_digest
        else
          entry["ownership"].to_s != "merge-owned"
        end
      end
    end
  end
  return false unless governance_valid
  return true if reviewer_handoffs.empty?

  handoff_path = reviewer_handoffs.first["new_relative_path"].to_s
  return false unless phase4_reviewer_handoff_rebind?(
    repo_root,
    base_source,
    source,
    handoff_path,
  )

  puts "[policy] reviewer handoff digest rebind preserves prior review metadata; it is not approval evidence"
  true
rescue Psych::Exception, AgentWorkflow::AdoptionReceipt::ReceiptError, StandardError => error
  puts "[policy] phase 4 registry bootstrap is invalid: #{error.message}"
  false
end

def run_validator(script, *args)
  command = ["ruby", File.join(AgentWorkflow::AI_ROOT, "runtime", "scripts", script), *args]
  puts "+ #{command.join(' ')}"
  system(*command)
end

ranges = case options[:mode]
when "staged"
  [nil]
when "range"
  [options[:range]]
when "pre-push"
  pushed_ranges(options[:repo_root], options[:remote], STDIN.read)
end

all_ok = run_validator("validate_agent_structure.rb")
if ranges.empty?
  if all_ok
    puts "OK: no new commit range requires validation."
    exit 0
  end

  puts "ERROR: change-set validation failed."
  exit 1
end

ranges.each do |range|
  mode_args = range ? ["--range", range] : ["--staged"]
  puts "[change-set] validating #{range || 'staged index'}"
  changes = WorkflowEvidence.git_changes(repo_root: options[:repo_root], staged: range.nil?, range: range)
  feature_ids = feature_ids_for_changes(changes)
  bootstrap_change_set = installation_bootstrap_change_set?(
    changes,
    repo_root: options[:repo_root],
    range: range,
  )
  adoption_change_set = adoption_receipt_change_set?(
    changes,
    repo_root: options[:repo_root],
    range: range,
  )
  if adoption_change_set
    puts "[work-scope] reviewed adoption receipt supplies bounded ownership"
    puts "[docs] reviewed adoption receipt isolates unrelated historical feature evidence"
    puts "[policy] reviewed adoption receipt owns this bounded change set"
    next
  end
  phase4_change_set = phase4_registry_bootstrap_change_set?(
    changes,
    repo_root: options[:repo_root],
    range: range,
  )
  if phase4_change_set
    puts "[work-scope] bounded Phase 4 registry bootstrap owns governance paths"
    puts "[docs] specification freshness is enforced by the required spec-gate"
    puts "[policy] immutable adoption receipt authorizes this Phase 4 bootstrap boundary"
    next
  end

  all_ok = false unless run_validator("validate_work_scope.rb", *mode_args, "--repo-root", options[:repo_root])
  all_ok = false unless run_validator("validate_docs_sync.rb", "--active-registry", *mode_args, "--repo-root", options[:repo_root])

  if !changes.empty? && feature_ids.empty? && !bootstrap_change_set && !adoption_change_set
    puts "ERROR: change set does not declare or activate an owning feature"
    all_ok = false
  end
  if feature_ids.length > 1
    puts "ERROR: one feature is allowed per change set; split these features: #{feature_ids.sort.join(', ')}"
    all_ok = false
  end
  puts "[policy] initial kit installation manifest owns this bootstrap change set" if bootstrap_change_set
  feature_ids.each do |feature_id|
    paths = policy_paths_for_feature(feature_id, changes)
    next if paths.empty?

    feature = AgentWorkflow.load_feature(feature_id)
    finish = feature["status"].to_s == "done"
    result = WorkflowPolicy.evaluate(feature_id, finish: finish, paths: paths)
    if Array(result["errors"]).empty?
      puts "[policy] #{feature_id}: OK (#{result['effective_tier']})"
    else
      all_ok = false
      Array(result["errors"]).each { |error| puts "[policy] ERROR [#{error['code']}] #{error['message']}" }
    end
    if finish
      completion_errors, = WorkflowEvidence.completed_feature_errors(feature_id, repo_root: options[:repo_root])
      unless completion_errors.empty?
        all_ok = false
        completion_errors.each { |message| puts "[completion] ERROR [POLICY_COMPLETION_INVALID] #{message}" }
      end
    end
  rescue StandardError => error
    all_ok = false
    puts "[policy] ERROR #{feature_id}: #{error.message}"
  end
end

if all_ok
  puts "OK: change-set validation passed."
  exit 0
end

puts "ERROR: change-set validation failed."
exit 1
