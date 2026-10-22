# Changelog

All notable changes to the AI Agentic Workflow Kit are documented here.

## 0.4.12 - 2026-10-22

### Changed

- Public distribution starts from a clean history with synthetic canary names
  and an example disposable-container label.
- Public release manifests use GitHub asset URLs instead of builder file paths.
- Reusable workflows and source validation target this distribution repository.
- Local memory, MCP settings and credential files are excluded from Git.

## 0.4.11 - 2026-08-14

### Fixed

- Test repositories disable inherited Git auto-maintenance and clean up their
  exact temporary roots in force mode, preventing a disappearing maintenance
  lock from leaking a fixture into later release-digest tests on macOS Ruby
  3.3.

## 0.4.10 - 2026-08-14

### Fixed

- The one-commit Phase 4 registry bootstrap can carry one syntax-bounded
  historical reviewer-manifest digest rebind for a completed review stream.
  The validator requires an unchanged passed gate, regular non-executable Git
  blobs, and byte-identical handoff content outside the changed lowercase
  SHA-256 token; it does not treat the rebind as reviewer approval or prove the
  project-specific tree-manifest meaning.

## 0.4.9 - 2026-08-14

### Fixed

- Hosted pull-request review collection separates paginated API page capture
  from `jq` flattening so GitHub CLI never receives its incompatible `--slurp`
  and `--jq` or `--template` options in the same command.

## 0.4.8 - 2026-08-14

### Security

- Hosted specification freshness validation uses an explicit fail-closed
  execution profile that audits the complete registry before running adapters
  and rejects project dependency or runtime executable loaders.
- Hosted installation validation performs structure checks in trusted central
  code and never executes the target project's installed validator, even when
  both that payload and its target lock entry are forged together.

### Changed

- Workflow policy regression tests accept the v0.4.7 blank-environment bridge
  while requiring its v0.4.8 replacement to bind the main hosted runner, use
  no-project-code validator profiles, and execute receipt checks only from the
  trusted central kit.

## 0.4.7 - 2026-08-14

### Added

- A private remote composite action exposes the exact downloaded kit repository
  root only after binding the GitHub action repository, full commit reference,
  action path, root sentinel, required regular files, and symlink-free paths.
- Trusted installation validation can use an explicit action-source filesystem
  tree when Git metadata is intentionally unavailable while keeping installation
  provenance bound to the separately supplied exact release commit.
- Release digest tooling can compute the canonical bundle identity directly from
  a filesystem tree with Git-equivalent framing and exclusions, exact regular-file
  modes, and fail-closed handling for symlinks and special files.

## 0.4.6 - 2026-08-14

### Fixed

- Trusted hosted installation validation now accepts a reviewed project-specific
  merge-owned file only when one appended migration approval binds its Git base,
  selected staged or committed lock, worktree bytes, installed digests,
  ownership, and mode.
- Legacy runtime files preserved at canonical relocation paths remain verifiable
  only when the same path, content, mode, and ownership existed in the Git-bound
  base lock and tree and the new trusted runtime replacement is present; arbitrary
  or newly injected outside-template entries continue to fail closed.

## 0.4.5 - 2026-08-14

### Fixed

- Specification source globs now give `**` its documented recursive meaning,
  and change-set digests exactly match the documented names-and-patch framing.
- Approved no-impact evidence is bound to the base registry's CODEOWNER and
  the exact pull-request head review, preventing owner rebinding and replay.
- Reusable specification gates bind caller inputs to the immutable called
  workflow through GitHub OIDC evidence and validate installations against the
  trusted checked-out kit rather than a workstation-local release source.
- Phase 3 adoption receipts remain immutable historical evidence while Phase 4
  is free to add governed `.ai` registry and generated-fact files.
- The initial Phase 4 registry bootstrap has a one-commit, receipt-backed
  change-set boundary that accepts only manifest-bound harness files and the
  registry's exact canonical and generated paths.
- Python and Next.js fact adapters filter broad rules to the file types they
  understand, support monorepo route prefixes, collect common Python
  environment access forms, and avoid runtime-minor digest drift.
- Deploy receipt generation and verification pin repository reads to one
  commit, bind required checks to their GitHub App, and hash artifacts through
  a no-symlink `openat` walk with immutable-copy handoff requirements.

### Added

- Deterministic deploy receipt generation and CODEOWNER declarations for every
  specification registry rule.
- Explicit project ownership for `SPEC_REGISTRY.yaml` and `CODEOWNERS`, plus a
  reviewed merge path for the project-specific policy caller workflow.

## 0.4.4 - 2026-08-14

### Fixed

- Installed CI secret scanning now inspects the authoritative PR/push change
  range instead of reclassifying unchanged baseline fixtures, while local
  full-repository scans remain available and fail closed.

## 0.4.3 - 2026-08-14

### Fixed

- A verified one-commit adoption receipt now isolates the adoption change set
  from unrelated historical feature doc-sync and completion evidence while
  retaining exact receipt, ownership, digest, and mode validation.
- Installer-generated YAML removes trailing horizontal whitespace so adoption
  commits pass Git whitespace checks without changing manifest semantics.

## 0.4.2 - 2026-08-14

### Added

- Phase 3 adoption receipts that bind the reviewed plan, release identity,
  branch, and a deterministic self-excluding harness tree digest.
- An installed `validate-install` CI job and a bounded one-commit adoption
  change-set path with exact ownership, mode, and content validation.
- Structured merge-owned adoption through paired current-content approval and
  reviewed merged-content inputs.

### Changed

- Installation validation treats absolute linked-worktree paths as provenance
  hints so a committed adoption remains valid after maintenance worktree
  cleanup and in fresh clones.
- Adoption preflight evaluates semantic project context, every linked
  worktree's activity and locks, and per-worktree restore-verified checkpoint
  records including current algorithm-4 dirty snapshot digests and archives.

### Security

- Adoption change-set exceptions reject forged expected, desired, installed,
  or mode values and continue to deny modifications to project-owned and
  generated files.
- Merge-owned content is accepted only when the base blob, committed blob,
  migration approval digests, and installation manifest agree exactly.

## 0.4.1 - 2026-08-14

### Added

- Release-only synthetic fixture and installer regression lifecycles backed by
  pinnable archives, sidecars, independent digests, and isolated caches.
- Deterministic, fail-closed PostgreSQL introspection with an opt-in disposable
  container integration test that never collects credentials, rows, or values.

### Changed

- Canonical installer, validator, inventory, runtime agent, script, template,
  hook, and reference-fixture assets now live in the three-tier `engine`,
  `.ai/runtime`, and `fixtures` layout. Executable `installer` wrappers preserve
  compatibility while Git rename history remains traceable.
- The temporary fixture-only `--dev-source` interface and `dev_unmanaged`
  installation state are removed. Every plan and apply is release-only.
- Historical non-pinnable bootstrap manifests using dirty snapshot algorithm 3
  remain verifiable, while version releases continue to require algorithm 4.

### Security

- Release resolution fails before project writes unless the reviewed manifest,
  archive, bundle digest, and manifest digest all agree.
- Context-isolation tests include negative controls that prove cross-project
  cache, environment, repository, and generated-output contamination is caught.

## 0.4.0 - 2026-08-14

### Added

- Deterministic annotated-tag release manifests, bundle digests, archive
  verification, and a content-addressed release cache.
- Plan/apply binding to the exact source, target worktree, branch, repository,
  manifest, dirty snapshot, and reviewed per-file actions.
- Four-class ownership (`kit-owned`, `merge-owned`, `project-owned`, and
  `generated`) with approval-bound merge paths and tombstones.
- Three-tier runtime/project/generated layout, project-context isolation,
  deterministic source facts, specification-freshness validation, and a
  reusable required-check workflow.
- Read-only adoption and fleet preflight, PR-only gardener planning, exact
  deploy-receipt verification, and nested-clone retirement evidence.
- Dependency-free lock, registry, generated-fact, and deploy-receipt schemas,
  plus disposable PostgreSQL inspection safeguards.

### Changed

- Dirty worktree identity now uses algorithm 4. It records entry types, hashes
  symlink target bytes without following links, hashes staged symlink blobs,
  keeps exact plan paths separate from scope globs, and anchors worktree reads
  to no-follow directory descriptors so concurrent path swaps fail closed.

### Breaking changes

- `AGENTS.md` ownership changes from `project-owned` to approval-required
  `merge-owned`; an approved content digest is required before an installer can
  apply a merged result.
- The fleet-wide `--replace-project-owned` escape hatch is removed. Protected
  changes use per-path `--approve-path <path>=<expected_sha256>` review instead.
- Installation locks and release manifests now require
  `dirty_snapshot_algo: 4`; algorithm 3 remains readable only by the Phase 0
  checkpoint verifier and is never emitted by this release.

### Security

- Production installation refuses working-tree sources, non-pinnable releases,
  manifest or archive tampering, stale plans, multi-target apply, unreviewed
  protected paths, and non-regular release entries.
- Project-owned files and task evidence are preserved by default; generated
  outputs never collect credential values or database rows.

## 0.3.0

### Added

- Machine-readable installation status and multi-project inventory commands.
- Legacy installation detection with explicit safe-upgrade and replacement modes.
- Manifest schema 2 baseline, source-commit, template-digest, and installation-state metadata.
- Ownership-aware upgrades that preserve project-owned canonical files by default.
- Batch upgrade planning with non-zero review and blocked exit codes.

### Security

- `--force` no longer replaces project-owned files unless
  `--replace-project-owned` is explicitly provided.
- Upgrade plans are read-only by default and must pass a complete preflight
  before batch application.

## 0.2.0

### Added

- Versioned feature, stream, installation, evidence, review, and change-set metadata.
- Worktree-local active state and locks.
- Default-deny ownership, risk-tier, document-impact, and revision validation.
- Installation, lifecycle, hook, concurrency, and portability regression tests.
- GitHub Actions matrix for Ruby 3.1 and 3.3 on Linux and macOS.
- Installed-project GitHub policy workflow and high-confidence secret scan.

### Changed

- Stream scopes distinguish readable, writable, state, and shared paths.
- High-risk changes require tier 3 classification and structured approvals.
- Feature completion requires explicit validation and acceptance evidence.
- Installation normalizes real paths and preserves existing Git hook configuration.
- Change-set digests normalize untracked and committed additions so revision
  evidence remains stable across the candidate commit.
- Change sets resolve to one feature by default; unrelated features must be split.

### Security

- Limited featureless bootstrap ownership to the change set that first adds the
  installation manifest, contains exactly one complete installation commit,
  and stays inside fixed workflow namespaces.
- Installed validation rejects kit-owned digest, mode, and index/worktree drift.
- Protected project paths are excluded from context collection.
- Local execution and memory state are excluded from source control.
- Validation evidence stores digests instead of command output.
