# ADR-0001: Adopt Agentic Workflow Kit

## Status

Accepted

## Context

The project needs repeatable AI-assisted development with explicit ownership,
durable knowledge, risk tiers, review gates, and git guardrails.

## Decision

Adopt the AI Agentic Workflow Kit as the project workflow engine.

## Consequences

- Work is organized as features and streams.
- Agents declare both runtime owner and working profile.
- High-risk work uses tier 3 review gates.
- Project facts are configured through `PROJECT_MAP.yaml` and `ENV_MATRIX.yaml`.

