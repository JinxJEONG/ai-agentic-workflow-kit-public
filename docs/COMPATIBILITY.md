# Compatibility

## Supported baseline

| Area | Supported baseline | Notes |
|---|---|---|
| Ruby | 2.6 or newer | Installer and project scripts use the standard library. |
| Git | Work-tree commands with `rev-parse` and local config | Normal clones and linked worktrees are supported. |
| macOS | Supported | `/tmp` is normalized to its physical `/private/tmp` path. |
| Linux | Supported design target | CI and release smoke tests should run before publishing a version. |
| Paths | Spaces, single quotes, UTF-8/Korean, symlinked parent aliases | The installed root is recorded as `File.realpath`. |

The local regression suite also runs on the macOS system Ruby 2.6 baseline.
The hosted GitHub Actions matrix covers Ruby 3.1 and 3.3 on Linux and macOS;
publishing a tag still requires the release checklist's hosted results.

The bootstrap target must be the exact Git top-level. Bare repositories,
non-Git directories, and repository subdirectories are rejected. A symbolic
link may be used to address the top-level, but the installation manifest and
`PROJECT_MAP.yaml` record its physical path.

## Git hooks

The installed hooks are POSIX `sh` scripts. Hook activation is opt-in and
repository-local. An existing effective `core.hooksPath`, including a value
inherited from global Git configuration, is never replaced automatically.

## Manifest compatibility

Manifest schema version 2 contains:

- `schema_version`
- `project_id`, `kit_version`, exact release ref/commit, and `profile`
- `kit_bundle_digest`, `release_manifest_digest`, `rendered_install_digest`,
  `repository_fingerprint`, and their algorithm versions
- verified release `source` locator and archive checksum
- `installed_at` and `updated_at`
- `workspace_root`
- `git`
- `installed_files` with `kit-owned`, `project-owned`, `merge-owned`, or
  `generated` ownership plus current, baseline, and desired SHA-256 digests
- protected paths, approval-required paths, and tombstones
- `migration_history`

Schema version 1 remains readable for a migration, but the validator still
requires the installed kit version to match the validator version. Run the
upgrade planner to write schema 2. Unknown future schema versions must be
migrated with a compatible kit rather than silently rewritten.

The installer uses the manifest as a three-way record: the last accepted kit
baseline, the current project file, and the new rendered template. An unchanged
kit-owned baseline may be updated automatically; kit-owned drift is a review
conflict; project-owned drift is preserved and recorded as a notice.

## Status and exit codes

`engine/install/status.rb --json PROJECT` reports `not_installed`, `legacy_unknown`,
`upgrade_available`, `legacy_review`, `review_required`, `blocked`,
`unsupported`, `invalid`, or `current`.

- `0`: current and unblocked
- `10`: installation or upgrade action is available
- `20`: legacy/review decision is required
- `30`: active workflow stream or lock blocks migration
- `40`: target or manifest is invalid

## Legacy feature and local-state compatibility

New features use schema/scope version 2. A stream manifest without
`scope_version` is treated as version 1: its legacy `write_scope` plus editable
document scopes are conservatively considered writable. This preserves safety
but may block parallel activation until the manifest is reviewed and converted
to explicit `read_scope`, `write_scope`, `state_write_scope`, and
`shared_write_scope` entries.

The runtime can read legacy `.ai/ACTIVE_CONTEXT.yaml` and stream `LOCK.yaml`
files only as a migration fallback. It never silently deletes or takes over a
legacy lock. Finish active work first, review the generated `.ai/local/` state,
and remove tracked legacy state in a separately reviewed change. Existing
feature records are not rewritten automatically; newly created features use
version 2 while historical records remain auditable.

## Known boundaries

- File modes are validated on macOS and Linux filesystems that expose POSIX
  permission bits.
- The installer does not merge third-party Git hook managers.
- The installer does not rewrite project-specific workflow facts during an
  upgrade; conflicts require review.
- Installation success is local evidence only. It is not evidence of CI,
  deployment, provider, or production acceptance.
