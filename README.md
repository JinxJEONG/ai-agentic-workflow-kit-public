# AI Agentic Workflow Kit

Reusable, repository-enforced AI-agent workflow engine for new and existing
software projects.

This repository packages the workflow foundation extracted from the Academy SaaS
agent workflow into a project-agnostic installer:

- feature / stream execution model
- agent identity profiles
- canonical knowledge layer and ADRs
- risk-tier workflow policy
- reviewer gate for high-risk work
- deterministic context retrieval
- PM feature draft helper
- work-scope and docs-sync validators
- local git hooks
- worktree-local execution state and locks
- structured completion, review, and approval evidence
- CI-ready change-set validation

The kit intentionally does not carry project-specific facts such as service
names, domains, ports, deployment paths, or database names. Those are generated
per project in `.ai/canonical/PROJECT_MAP.yaml` and `.ai/canonical/ENV_MATRIX.yaml`.

## Quick Start

```sh
git clone https://github.com/JinxJEONG/ai-agentic-workflow-kit-public.git
KIT=/absolute/path/to/ai-agentic-workflow-kit-public
# Use a reviewed pinnable release sidecar and independently recorded bundle and
# manifest digests. Preview JSON first, then apply only its exact plan_digest.
ruby "$KIT/engine/install/bootstrap_project.rb" --dry-run --json \
  --source-manifest /reviewed/release.manifest.json \
  --expected-kit-bundle-digest sha256:<reviewed-bundle-digest> \
  --expected-release-manifest-digest sha256:<reviewed-manifest-digest> \
  /path/to/project
# After the reviewed apply described in docs/INSTALL.md:
ruby "$KIT/engine/validators/validate_install.rb" /path/to/project
cd /path/to/project
```

See `docs/INSTALL.md` for the separate reviewed apply command. There is no
working-tree source mode; synthetic fixtures use reviewed local release archives
and the same independent digest gates as every other installation.

For an existing installation, inspect first and apply only after reviewing the
read-only plan:

```sh
ruby "$KIT/engine/install/status.rb" --json /path/to/project
ruby "$KIT/engine/install/upgrade.rb" --json /path/to/project > /tmp/upgrade-plan.json
# Apply one target only, with the exact plan_digest and identical plan options.
ruby "$KIT/engine/install/upgrade.rb" --apply \
  --plan-digest sha256:<reviewed-plan-digest> /path/to/project
```

`.ai/canonical/**` is project-owned and its local changes are preserved.
`AGENTS.md` is merge-owned and requires an exact current-content approval plus
a reviewed merged-content file when changed (`--approve-path` and
`--merge-path`).
Generated facts are source-derived. Kit-owned scripts, hooks, templates, and CI
files are updated only when their recorded baseline is unchanged; otherwise the
plan reports a conflict and apply stops until the replacement is reviewed.
Phase 3 adoption commits include a self-verifying receipt generated from the
staged harness tree; the installed `validate-install` CI job verifies it from
the committed tree.
Use `engine/inventory/inventory.rb --json ROOT...` to inspect multiple repositories.
The `installer/*.rb` entrypoints remain compatibility wrappers for existing automation.

Review the installed files and create a dedicated installation commit before
creating the first feature. When a remote is used, its existing project history
must already be present; do not bundle earlier commits or feature work with the
first kit push. After committing, enable the hooks and push the installation
commit by itself:

```sh
.ai/runtime/scripts/setup_local_hooks.sh
git push
```

Feature revision evidence requires a real baseline commit; the installer never
creates or pushes that commit for you.

Then create and run workflow features inside the target project:

```sh
ruby .ai/runtime/scripts/create_feature.rb --tier tier2 "Add billing report"
ruby .ai/runtime/scripts/activate_stream.rb FEATURE-YYYYMMDD-NNN backend-dev codex-app
ruby .ai/runtime/scripts/collect_context.rb FEATURE-YYYYMMDD-NNN backend-dev
```

Active execution state and locks live under the ignored `.ai/local/` directory.
Tracked feature, stream, evidence, review, and change-set files provide durable
inputs that CI can verify without trusting local state.

The kit never commits, pushes, opens a pull request, or deploys on its own.
Feature completion, publication, and production acceptance remain separate
states and approvals.

## Development

Run the repository's syntax and regression suite with:

```sh
rake
```

See `docs/INSTALL.md`, `docs/WORKFLOW.md`, `docs/PROJECT_MAP.md`,
`docs/SECURITY_MODEL.md`, and `docs/RELEASE_CHECKLIST.md`.
