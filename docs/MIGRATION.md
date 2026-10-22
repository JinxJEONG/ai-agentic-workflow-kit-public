# Migration

## Safety boundary

A kit migration changes project-local workflow files only. It does not commit,
push, deploy, migrate application data, or replace Git hook configuration.
Before migration, finish or pause active workflow streams and ensure the target
worktree has no workflow lock that belongs to another process.

The bootstrapper inspects both current local-state locks and legacy stream
`LOCK.yaml` files. A real install or upgrade stops while an active stream or
stream lock exists. `--dry-run` remains read-only and reports the blocker so the
plan can still be reviewed.

Do not copy project facts from another repository. Migrate the workflow engine,
then review `PROJECT_MAP.yaml`, `context-map.yaml`, protected paths, service
paths, and environment facts for this project.

## Legacy install without a manifest

An installation created before `.ai/KIT_INSTALLATION.yaml` has no trustworthy
managed-file baseline. The status command identifies it as `legacy_unknown` and
the safe planner does not guess which local files are disposable. `AGENTS.md`
and `.ai/canonical/**` are project-owned and remain untouched; differing
kit-owned files are reported as conflicts.

1. Confirm the exact Git top-level:

   ```sh
   ruby engine/resolver/discover_project.rb /path/to/project
   ```

2. Inspect the installation state and capture the non-mutating safe plan:

   ```sh
   ruby engine/install/status.rb /path/to/project
   ```

3. Review every `CONFLICT` and `PRESERVE` entry. The one-time adoption helper
   previews replacement of kit-owned legacy files only:

   ```sh
   RELEASE_MANIFEST=/reviewed/releases/ai-agentic-workflow-kit-0.4.2.manifest.json
   EXPECTED_BUNDLE=sha256:<reviewed-bundle-digest>
   EXPECTED_MANIFEST=sha256:<reviewed-manifest-bytes-digest>
   ruby engine/install/adopt.rb --json \
     --source-manifest "$RELEASE_MANIFEST" \
     --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
     --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
     /path/to/project > /tmp/workflow-kit-adoption-plan.json
   ```

4. Apply the reviewed adoption. Replaced regular files are backed up
   automatically; project-owned files remain in place:

   ```sh
   ruby engine/install/adopt.rb --apply \
     --plan-digest sha256:<reviewed-plan-digest> \
     --source-manifest "$RELEASE_MANIFEST" \
     --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
     --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
     /path/to/project
   ```

5. Review `.ai/KIT_INSTALLATION.yaml` and the backup path recorded in its latest
   `migration_history` entry.
6. Validate the complete result:

   ```sh
   ruby engine/validators/validate_install.rb /path/to/project
   ```

## Manifest-based upgrade

For installations that already have a valid manifest, the planner compares the
current file to both the last accepted baseline and the new rendered template:

- an unmodified kit-owned baseline is updated automatically;
- a file already matching the new kit stays unchanged;
- a project-owned file with local drift is preserved;
- a locally modified kit-owned file is reported as a conflict;
- `--replace-kit-owned` is required to approve backup and replacement of a
  kit-owned conflict.

Canonical files are `project-owned`; their current digest may drift after
intentional project customization while the accepted baseline remains available
for audit. `AGENTS.md` is `merge-owned` and any proposed change requires
both `--approve-path PATH=EXPECTED_SHA256` for the current reviewed bytes and
`--merge-path PATH=FILE` for the reviewed merged result. Both digests are bound
into the plan and migration history. The installer never replaces or deletes
project-owned content during a normal upgrade. A missing project-owned file is a
blocking conflict so an intentional deletion is not silently undone.

For one project:

```sh
RELEASE_MANIFEST=/reviewed/releases/ai-agentic-workflow-kit-0.4.2.manifest.json
EXPECTED_BUNDLE=sha256:<reviewed-bundle-digest>
EXPECTED_MANIFEST=sha256:<reviewed-manifest-bytes-digest>
ruby engine/install/upgrade.rb --json --replace-kit-owned \
  --approve-path AGENTS.md=<sha256-of-current-AGENTS.md> \
  --merge-path AGENTS.md=/reviewed/AGENTS.merged.md \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project > /tmp/workflow-kit-upgrade-plan.json
# After review, pass projects[0].plan_digest explicitly:
ruby engine/install/upgrade.rb --apply --replace-kit-owned \
  --approve-path AGENTS.md=<sha256-of-current-AGENTS.md> \
  --merge-path AGENTS.md=/reviewed/AGENTS.merged.md \
  --plan-digest sha256:<reviewed-plan-digest> \
  --source-manifest "$RELEASE_MANIFEST" \
  --expected-kit-bundle-digest "$EXPECTED_BUNDLE" \
  --expected-release-manifest-digest "$EXPECTED_MANIFEST" \
  /path/to/project
```

For several projects, `upgrade.rb` can produce read-only plans. It refuses
`--apply` with more than one target; review and apply one repository at a time,
keeping its plan digest and backup path as the migration record.

After the reviewed apply, stage only the adoption paths and generate the
self-excluding receipt from that exact index. The receipt binds the release,
plan, branch, and complete harness tree; verification fails if staged or
committed harness bytes drift:

```sh
git -C /path/to/project add .ai AGENTS.md .githooks \
  .github/workflows/agent-workflow-policy.yml
ruby /path/to/project/.ai/runtime/scripts/adoption_receipt.rb generate \
  --plan-digest sha256:<reviewed-plan-digest> /path/to/project
git -C /path/to/project add .ai/receipts/ADOPTION_RECEIPT.yaml
ruby /path/to/project/.ai/runtime/scripts/adoption_receipt.rb verify --source index \
  /path/to/project
```

The installed `validate-install` workflow repeats structure and receipt
verification against `HEAD` on every pull request and push.

The existing `installed_at` value and valid history entries are preserved. A
new history record binds the previous and current schema/kit versions and the
backup path, when one was needed.

Before committing an upgrade in a repository that already tracks
`.ai/KIT_INSTALLATION.yaml`, declare a maintenance feature and stream whose
writable scopes cover the reviewed managed paths. The initial featureless
bootstrap exception cannot be reused for an upgrade.

## Project-specific review after migration

After installing the new engine:

1. Review `.ai/canonical/PROJECT_MAP.yaml`.
2. Add the real service and repository paths.
3. Confirm protected paths and tier-3 patterns.
4. Update `.ai/canonical/context-map.yaml` to match the code layout.
5. Review active-context and stream schema changes described in the release
   notes.
6. Run `ruby engine/validators/validate_install.rb /path/to/project`.
7. Confirm the status command reports `current` and no active streams or locks.
8. Create and complete a small `tier1` feature as an isolated smoke test.

## Existing Git hook manager

Migration never overwrites an effective `core.hooksPath`. If hook setup reports
Husky, Lefthook, a global hooks directory, or another path, keep that setting
until the repository owner chooses an integration method. Options include
calling the kit checks from the existing manager or writing a reviewed wrapper;
there is no universal safe automatic merge.

Record the current setting before any manual change:

```sh
git -C /path/to/project config --show-origin --get core.hooksPath
```

If the kit hook path was configured locally and must be rolled back:

```sh
git -C /path/to/project config --local --unset core.hooksPath
```

## File rollback

The latest migration entry names its ignored `.ai/local/backups/` directory
when files were replaced.
To roll back, stop workflow activity, compare the backup with the current files,
and restore only the reviewed paths. Do not copy the entire `.ai` directory over
new evidence, task records, or local state. Re-run installer validation after
either a migration or a rollback.
