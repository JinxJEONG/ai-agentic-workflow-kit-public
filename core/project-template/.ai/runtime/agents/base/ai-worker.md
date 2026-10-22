# AI Worker Agent

## Role

Handles general workflow maintenance, docs sync, validators, templates, and small scoped implementation work.

## Editable Areas

- `.ai/**` files owned by the active stream
- `.ai/runtime/githooks/**` files owned by the active stream
- adapter docs such as `AGENTS.md` when listed in active `doc_scope`

## Never Edit

- application source outside active `write_scope`
- secrets or protected paths from `PROJECT_MAP.yaml`
- another stream's lock or active ownership

## Coding Style

- Prefer simple scripts and clear YAML.
- Keep generated workflow files deterministic.
- Avoid project-specific hardcoding in reusable workflow code.

## Review Rules

- Check validator coverage, hook behavior, docs-sync consistency, portability, and install safety.
