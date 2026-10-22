# Installation

## Requirements

- Git working tree (a normal clone or a linked Git worktree)
- Ruby 2.6 or newer
- The exact Git top-level directory as the install target

The installer never commits, pushes, deploys, or changes `core.hooksPath`.
Paths are resolved with `File.realpath`, so macOS `/tmp` and `/private/tmp`
refer to the same normalized workspace. Spaces, single quotes, and Korean text
in a path or project name are serialized safely in `PROJECT_MAP.yaml`.

## Inspect the target

Run the read-only discovery command first when the repository layout is not
obvious:

```sh
ruby engine/resolver/discover_project.rb /path/to/project
```

`valid_install_target` must be `true`. A subdirectory of a repository is not a
valid target; use the reported `git_top_level` instead. Both a `.git` directory
and the `.git` file used by a linked worktree are supported.

## Preview and install

Production installs use a pinnable release sidecar plus two independently
reviewed trust roots. Preview the complete plan without creating directories,
files, backups, or Git configuration:

There is no development or working-tree source mode. This requirement also
applies to tests and synthetic fixtures: build a local reviewed archive and
sidecar, then supply both independent digests.

```sh
RELEASE_MANIFEST=/reviewed/releases/ai-agentic-workflow-kit-0.4.2.manifest.json
EXPECTED_BUNDLE=sha256:<reviewed-bundle-digest>
EXPECTED_MANIFEST=sha256:<reviewed-manifest-bytes-digest>
ruby engine/install/bootstrap_project.rb --dry-run --json \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project > /tmp/workflow-kit-plan.json
```

The plan classifies every managed file as:

- `CREATE`: the destination does not exist.
- `UNCHANGED`: the installed content already matches this kit.
- `UPDATE`: the file matches its digest in a previous installation manifest,
  so it is safe to update.
- `PRESERVE`: a project-owned file has local content or mode drift and remains
  untouched.
- `CONFLICT`: an unmanaged or locally modified file differs from the kit.
- `REPLACE`: with `--force`, a reviewed conflict will be backed up and
  replaced.

An unresolved conflict stops the complete installation before any file is
written. After reviewing the complete JSON plan, copy its `plan_digest` into a
separate apply invocation:

```sh
PLAN_DIGEST=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("plan_digest")' /tmp/workflow-kit-plan.json)
ruby engine/install/bootstrap_project.rb --json \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  --plan-digest "$PLAN_DIGEST" /path/to/project
```

Use `--force` only after reviewing every conflict. The installer backs up every
replaced regular file below
`.ai/local/backups/kit-installation-<UTC timestamp>-<process id>/`
and records that path in the migration history:

```sh
ruby engine/install/bootstrap_project.rb --dry-run --json --force \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project > /tmp/workflow-kit-plan.json
# Review the replacement list, then keep --force in the bound apply:
PLAN_DIGEST=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("plan_digest")' /tmp/workflow-kit-plan.json)
ruby engine/install/bootstrap_project.rb --json --force \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  --plan-digest "$PLAN_DIGEST" /path/to/project
```

For an existing installation, the higher-level read-only status and upgrade
commands expose the same plan as JSON and use exit codes suitable for scripts:

```sh
ruby engine/install/status.rb --json /path/to/project
ruby engine/install/upgrade.rb --json /path/to/project
```

Legacy installations without a manifest should be adopted explicitly. The
adoption plan replaces only reviewed kit-owned files; project-owned files are
preserved:

```sh
ruby engine/install/adopt.rb --json \
  --approve-path AGENTS.md=<sha256-of-current-AGENTS.md> \
  --merge-path AGENTS.md=/reviewed/AGENTS.merged.md \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project > /tmp/workflow-kit-adoption-plan.json
# Review first; then apply the exact plan with the same source arguments.
PLAN_DIGEST=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).fetch("projects").first.fetch("plan_digest")' /tmp/workflow-kit-adoption-plan.json)
ruby engine/install/adopt.rb --apply --plan-digest "$PLAN_DIGEST" \
  --approve-path AGENTS.md=<sha256-of-current-AGENTS.md> \
  --merge-path AGENTS.md=/reviewed/AGENTS.merged.md \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project
```

`--merge-path` is accepted only for an approval-required merge-owned path. Its
source must be a reviewed regular file; symlinks and project-owned paths are
rejected. Keep the exact `--approve-path`, `--merge-path`, source manifest, and
trust-root arguments identical between plan and apply.

After apply, stage the intended adoption paths and run
`.ai/runtime/scripts/adoption_receipt.rb generate --plan-digest ...`. Add the
generated `.ai/receipts/ADOPTION_RECEIPT.yaml`, verify with `--source index`,
then commit. The installed policy workflow verifies the same receipt from
`HEAD` in its `validate-install` job.

`engine/inventory/inventory.rb --json ROOT...` discovers candidate repositories and
returns their status records. Multi-target `engine/install/upgrade.rb` invocations are
read-only. `--apply` accepts exactly one target and an explicit reviewed
`--plan-digest`; fleet apply is deliberately unsupported.

`--force` does not replace directories or symbolic links. Resolve those target
types explicitly before installation so the kit cannot redirect writes outside
the reviewed worktree.

Writes use same-directory temporary files and atomic rename. If an install
step fails, files created during that attempt are removed and replaced files
are restored from their backups.

## Installation manifest

Every successful install writes `.ai/KIT_INSTALLATION.yaml`. It contains:

- manifest `schema_version`
- `kit_version` bound by the reviewed sidecar and verified against the
  extracted release's `VERSION` file
- normalized `workspace_root` and Git worktree metadata
- `installed_files`, including relative path, SHA-256 digest, installed mode,
  baseline/desired digests, and `kit-owned`, `project-owned`, `merge-owned`, or
  `generated` ownership.
- exact release ref/commit/version, bundle and release-manifest digests,
  rendered-install digest, and their algorithm versions
- `installation_state`
- append-only `migration_history` for install, upgrade, repair, and refresh
  actions

The manifest does not include its own digest, because doing so would require a
self-referential checksum. Local project changes to managed files are therefore
detectable without treating the manifest as a template file.

## Validate the result

Run the installer-level validation from this kit checkout:

```sh
ruby engine/validators/validate_install.rb /path/to/project
```

Validation checks the normalized Git top-level/worktree metadata, manifest
schema and version, timestamps, migration binding, safe relative paths,
duplicate entries, file existence, SHA-256 digests, file modes,
`PROJECT_MAP.yaml`, and the installed structure validator.

Canonical files under `.ai/canonical/**` are project-owned: their baseline
digest is retained for upgrade conflict detection, but intentional content drift
is reported as a notice. Root `AGENTS.md` is merge-owned and requires an exact
path approval for a proposed merge. Generated files are regenerated and
validated from source; scripts, hooks, and other kit-owned files must match their
recorded digests exactly.

## Establish the revision baseline

Feature evidence is bound to a real Git baseline. After validation, review the
installed and project-specific files, then create the initial commit through
the repository's normal approval process. The installer deliberately does not
perform these Git actions.

```sh
git status --short
git add .ai .github/workflows/agent-workflow-policy.yml AGENTS.md
git commit -m "chore: install AI agentic workflow kit"
```

Do not run the commit commands until the file set and project mapping have been
reviewed. `create_feature.rb` fails closed on an unborn repository without a
baseline commit.

The featureless bootstrap ownership exception applies only to one dedicated
commit that first adds `.ai/KIT_INSTALLATION.yaml`. Push that installation
commit by itself. If an empty remote does not yet contain the project's existing
history, push that history before installing the kit; a first push that bundles
earlier commits with the installation commit is rejected. After the installation
baseline is pushed, manifest edits and kit upgrades use normal feature and
stream ownership.

## Configure hooks explicitly

Hook activation is separate from file installation:

```sh
cd /path/to/project
.ai/runtime/scripts/setup_local_hooks.sh
```

The script configures a repository-local `core.hooksPath=.ai/runtime/githooks` only when
no effective `core.hooksPath` is already set. If Husky or another local/global
hook manager is configured, the script exits without changing it and reports
the existing value and origin. Review and integrate the two hook systems
explicitly; the kit does not guess how to chain third-party hooks.

To undo a hook setting created by the script:

```sh
git -C /path/to/project config --local --unset core.hooksPath
```

## CI policy gate

The installed `.github/workflows/agent-workflow-policy.yml` is the authoritative
tracked-state gate for GitHub pull requests and pushes. It fetches full history,
derives the event's actual base/head range, and runs the same change-set
validator as the local hooks without relying on `.ai/local/` state.

Review this workflow alongside the other installed files before the initial
commit. If that path already exists, bootstrap reports a conflict instead of
replacing the project's CI policy. Repositories hosted elsewhere should invoke
the equivalent command with their provider's trusted base and head revisions:

```sh
ruby .ai/runtime/scripts/validate_change_set.rb --mode range --range BASE..HEAD
```

See [MIGRATION.md](MIGRATION.md) for upgrades and
[COMPATIBILITY.md](COMPATIBILITY.md) for the supported environment matrix.
