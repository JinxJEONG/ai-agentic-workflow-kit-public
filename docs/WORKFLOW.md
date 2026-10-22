# Workflow

The workflow unit is a feature. A feature contains one or more streams. Streams
allow parallel work while keeping read, write, state, and shared scopes
explicit.

Core concepts:

- `feature_id`: stable machine identity, such as `FEATURE-20260710-001`
- `stream_id`: execution unit inside a feature, such as `backend-dev`
- `owner_agent`: runtime surface, such as `codex-app` or `kiro-cli`
- `agent_profile`: working role, such as `backend`, `frontend`, or `reviewer`
- `workflow_tier`: `tier1`, `tier2`, or `tier3`
- `revision digest`: a reproducible digest of the relevant change set used by
  completion and review evidence before a final Git commit exists

Tier guidance:

- `tier1`: docs, copy, isolated tests, narrow UI polish
- `tier2`: bounded product feature or bugfix
- `tier3`: DB, auth, deploy, env, permissions, payments, data backfill, or hot spots

Tier 3 features require structured reviewer and human approval evidence bound
to the current revision before `finish_feature.rb` closes the feature.

## Stream scopes

Version 2 stream manifests distinguish:

- `read_scope`: context that may be read but not written
- `write_scope`: implementation paths owned by the stream
- `state_write_scope`: the stream's own manifest, plan, handoff, and evidence
- `shared_write_scope`: shared metadata that must be serialized or explicitly
  coordinated

Two parallel streams may run when their writable scopes do not overlap and both
allow parallel work. Shared read scopes do not cause a conflict. Local active
state and locks live in `.ai/local/` and are never CI authority.

## Lifecycle

1. Create a feature and review its tier, risk signals, contracts, and scopes.
2. Activate a stream with its runtime owner.
3. Collect the deterministic context bundle.
4. Keep every source and documentation change inside exactly one owning scope.
5. Record validation, acceptance, and document-sync evidence.
6. Finish the stream while its local lock is owned by the same runtime owner.
7. For tier 3, bind reviewer and human approval to the current revision.
8. Finish the feature only after every declared stream and contract is complete.
9. Commit, push, pull-request review, deployment, and production acceptance are
   separate, explicitly authorized steps.

## Enforcement

- Work-scope validation is default-deny, including added, modified, deleted, and
  renamed paths.
- Actual changed paths can raise a feature to tier 3 even when its metadata says
  tier 1 or tier 2.
- Default handoff text, unchecked acceptance items, `TBD`, `Pending`, or stale
  revision evidence cannot close a feature.
- Pre-commit validates the staged change set. Pre-push validates the actual
  local-to-remote commit range supplied by Git.
- A staged or pushed change set may resolve to exactly one feature. Split
  unrelated features into separate commits or push ranges; the default policy
  has no implicit multi-feature exception.
- CI recomputes ownership and policy from tracked scopes and the real diff; it
  does not trust `.ai/local/ACTIVE_CONTEXT.yaml`.

The installer includes `.github/workflows/agent-workflow-policy.yml`. It checks
the pull-request base/head range or push before/after range with the same
`validate_change_set.rb` entrypoint used by local hooks. Existing workflow-file
conflicts stop installation for review; they are never silently overwritten.
