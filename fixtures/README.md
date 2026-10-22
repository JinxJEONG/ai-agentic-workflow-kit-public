# Synthetic fixtures

`build_fixture.rb` creates disposable Git repositories for the Phase 2
governance regression suite. It never reads an application repository or copies
production data. The returned `container` owns every created worktree and is the
single cleanup boundary.

```sh
ruby fixtures/build_fixture.rb --parent /tmp legacy-unknown
```

The command prints JSON containing `path`, `worktrees`, `baseline_commit`,
`metadata_path`, and a `release` object with a sidecar, archive, independently
reviewed bundle and sidecar digests, and fixture-local cache path. Callers must
remove `container` when finished. Every fixture plan, apply, validation, and
status check uses that verified release; the installer has no working-tree
source exception.

## Fixture states

| Name | Reproduced state |
|---|---|
| `legacy-unknown` | No installation lock; legacy `.ai/**`, `AGENTS.md`, and an inactive `.githooks/pre-commit`; three modified canonical files plus two additional dirty files. |
| `managed-current` | A real schema-2 `managed` install made from a verified synthetic archive. Every `installed_files` digest matches and production status is `current`. |
| `managed-drifted` | A valid managed install plus a candidate whose version is unchanged but whose template and bundle digests differ; status is `upgrade_available` until reviewed apply. |
| `blocked-active` | `ACTIVE_CONTEXT` reports `streams_in_progress` and six tracked `LOCK.yaml` files remain. Plan is visible, but apply must fail closed. |
| `linked-worktree` | A primary repository and linked preview worktree sharing Git history while retaining distinct worktree paths. |
| `volatile-worktree` | A clean primary repository with dirty tracked and untracked content only in its linked worktree. |
| `isolation-alpha` | `alpha_db`, `/api/alpha`, `alpha_api`, and `ALPHA_ONLY_VAR`. |
| `isolation-beta` | `beta_db`, `/api/beta`, `beta_api`, and `BETA_ONLY_VAR`. |
| `unknown-project` | An explicit project identity but empty `services`; sensitive DB/auth/deploy context resolution must refuse inference. |

The committed fixture seed is deterministic in shape, while absolute worktree
paths and Git commit identifiers necessarily vary per run. Dirty states are
created only after the baseline commit. `core.hooksPath` is never configured.
The lifecycle suite executes plan, apply (or the expected blocked apply),
validate, and status for all nine fixture types.

## Verified release fixtures

`FixtureBuilder.build_release` copies the current project template into a
minimal release root, adds an explicit `VERSION`, computes the canonical full
bundle digest, and writes a local tarball plus pinnable sidecar. Production
bootstrap then resolves and renders from that extracted archive root. This
exercises the same manifest and digest gate as a managed install without
creating a Git tag. The original checkout is only fixture input at release
construction time; installer commands never render directly from it.

The side-by-side lifecycle creates `0.4.0` and `0.4.1`, installs them into
`isolation-alpha` and `isolation-beta`, and proves that both version and bundle
digest pins differ. It also hashes beta's complete porcelain status before and
after re-applying alpha, so a cross-project write fails the test.

## Safety and boundaries

- Fixtures contain placeholder values only; no passwords or customer rows.
- No hook is activated and no remote is configured.
- Installer apply targets only a repository created by this builder and always
  uses a reviewed plan digest.
- `managed-current` and `managed-drifted` do not hand-write a production lock.
  The builder obtains the lock through a real production installer lifecycle,
  so installed-file digests and repository fingerprints cannot silently become
  stale.
- Side-by-side release tests use test-local archives and cache directories.
  They do not write `$HOME/.cache`, create tags in this repository, or mutate an
  application checkout.
