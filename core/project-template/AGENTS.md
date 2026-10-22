# AGENTS

## Read First

Always read these before substantial work:

- `.ai/local/ACTIVE_CONTEXT.yaml` when present
- `.ai/canonical/PROJECT_RULES.md`
- `.ai/canonical/PROJECT_MAP.yaml`
- `.ai/canonical/ENV_MATRIX.yaml`
- assigned base agent profile under `.ai/runtime/agents/base/`
- `.ai/canonical/context-map.yaml`
- assigned feature `feature.yaml`
- assigned stream `manifest.yaml`
- current feature contracts: `api.md`, `db.md`, `acceptance.md`

## Execution Rules

- Run from the workspace root.
- Treat `.ai/canonical/` as canonical truth.
- Treat `.ai/local/ACTIVE_CONTEXT.yaml` and `.ai/local/locks/` as ignored,
  worktree-local execution state.
- Do not edit protected paths from `PROJECT_MAP.yaml` unless the active stream owns the work and the human approved the risk.
- Do not create arbitrary root markdown files for project truth; use canonical docs or stream handoffs.

## Agent Identity

- `owner_agent` is the runtime surface: `codex-app`, `codex-cli`, `kiro-cli`, `kiro-ide`, or `human`.
- `agent_profile` is the working role: `architect`, `backend`, `frontend`, `reviewer`, `pm`, or `ai-worker`.

## Before Starting a Stream

1. Resolve the assigned `feature_id` and `stream_id`.
2. Read `feature.yaml`, stream `manifest.yaml`, contracts, and sibling streams.
3. Read the declared `agent_profile`.
4. Run or consult `collect_context.rb` for intended paths.
5. Compare writable scopes with active streams in `.ai/local/ACTIVE_CONTEXT.yaml`.
6. Use `activate_stream.rb FEATURE-ID STREAM-ID OWNER_AGENT`.
7. Keep edits inside active stream scope.
8. Record validation, acceptance, and doc-sync evidence for the current revision.
9. Update only the current stream's handoff and evidence files.
10. Use `finish_stream.rb` and then `finish_feature.rb` when complete.

## Review Gate

For `workflow_tier: tier3`, the reviewer stream must record a passed structured
review and the required human approval for the current revision before the
feature can be closed. A handoff string alone is not approval evidence.
