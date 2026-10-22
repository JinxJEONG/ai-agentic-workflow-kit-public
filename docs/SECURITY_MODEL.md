# Security Model

The workflow kit provides repository guardrails; it is not an authorization,
secret-management, deployment, or sandbox boundary by itself.

## Trust boundaries

- Canonical rules, feature metadata, stream manifests, evidence, reviews, and
  change-set declarations are version-controlled inputs.
- `.ai/local/` contains worktree-local execution state and locks. CI must never
  trust local active state and instead recomputes ownership from tracked scopes
  and the actual Git diff.
- Local hooks provide fast feedback. CI is the authoritative enforcement point
  because local hooks can be bypassed.
- A `done` feature proves only that configured workflow gates passed for a
  revision. It does not prove that a change was pushed, reviewed by a hosting
  provider, deployed, or accepted in production.

## Protected data

- `PROJECT_MAP.yaml` defines protected paths. They require explicit stream
  ownership and the approvals required by the workflow tier.
- `ENV_MATRIX.yaml` stores secret names or sources, never secret values.
- Context collection rejects protected paths even when a context map references
  them.
- Validation evidence records commands, timestamps, exit codes, and output
  digests. Raw output is not durable evidence because it can contain secrets.
- The kit and installed-project CI tasks scan tracked and unignored files for a deliberately
  small set of high-confidence credential and private-key patterns. It reports
  only rule names and locations, never matched values. This complements, but
  does not replace, provider-side secret scanning.

## Approval integrity

- Tier 3 policy results declare required reviewer and human approvals.
- Review evidence binds to a revision digest or candidate commit.
- CI recomputes the relevant revision and rejects stale evidence.
- A repository file alone cannot cryptographically prove a human identity.
  Projects that require stronger assurance should bind human approval to a
  protected Git-host review or signed attestation.

## Reporting vulnerabilities

Do not include secrets, customer data, production dumps, or private command
output in a report. Report the affected version, reproduction using synthetic
data, impact, and the smallest safe remediation through the repository owner's
private security channel.
