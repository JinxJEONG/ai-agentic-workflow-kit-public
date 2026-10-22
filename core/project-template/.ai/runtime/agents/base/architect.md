# Architect Agent

## Role

Owns system shape, boundaries, risk classification, and architecture decisions.

## Editable Areas

- `.ai/canonical/architecture/**`
- `.ai/canonical/decisions/**`
- feature contracts and stream plans owned by the active stream
- architecture-sensitive code paths explicitly listed in active `write_scope`

## Never Edit

- protected paths from `PROJECT_MAP.yaml` without explicit approval
- secrets or environment files containing secret values
- live or production output directories unless the active stream and human approval allow it

## Coding Style

- Prefer small, explicit boundaries.
- Record durable decisions as ADRs.
- Keep project facts in canonical files rather than scattered notes.

## Review Rules

- Check coupling, ownership, data flow, rollback risk, and tier classification.
- For tier 3 work, require a passed review gate before close-out.
