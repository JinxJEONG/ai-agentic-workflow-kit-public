# Project Rules

Last verified: {{DATE}}
Status: draft

## Purpose

This project uses the AI Agentic Workflow Kit.

Project-specific facts live in:

- `.ai/canonical/PROJECT_MAP.yaml`
- `.ai/canonical/ENV_MATRIX.yaml`

Canonical workflow knowledge lives in `.ai/canonical/`.

## Execution Rules

- Run agents from the workspace root: `{{PROJECT_ROOT}}`.
- Use feature and stream identity for substantial work.
- Treat `.ai/local/ACTIVE_CONTEXT.yaml` and `.ai/local/locks/` as ignored,
  worktree-local execution state.
- Treat `.ai/canonical/` as canonical project truth.
- Do not edit protected paths declared in `PROJECT_MAP.yaml` unless the active
  stream explicitly owns the work and the human approved the risk.

## Agent Roles

Execution identity and working role are separate:

- `owner_agent`: runtime surface, such as `codex-app`, `codex-cli`, `kiro-cli`, or `kiro-ide`
- `agent_profile`: working role, such as `architect`, `backend`, `frontend`, `reviewer`, `pm`, or `ai-worker`

Kit-owned base agent profiles live in `.ai/runtime/agents/base/`; project overrides
live in `.ai/project/agents/`.

## Workflow Tiers

- `tier1`: docs, copy, narrow UI, isolated tests, or metadata updates
- `tier2`: bounded feature or bugfix work
- `tier3`: DB, auth, deploy, env, permission, payment, data migration, or hot-spot work

When uncertain, choose the higher tier.

Actual changed paths and semantic risk signals can raise the required tier.
Tier 3 work requires structured reviewer and human approval evidence bound to
the current revision.

## Source Ownership

- Every application or documentation change must match exactly one active
  stream's writable scope.
- Unowned and ambiguously owned changes are rejected by default.
- Added, modified, deleted, and renamed paths are all in scope for validation.
- CI recomputes ownership from tracked manifests and the actual Git diff; local
  active state is never CI authority.

## Knowledge Layer

Durable context belongs in:

- `.ai/canonical/architecture/`
- `.ai/canonical/decisions/`
- `.ai/canonical/runbooks/`
- `.ai/canonical/feature-history/`
- `.ai/canonical/context-map.yaml`

Temporary execution notes belong in stream `handoff.md`.
