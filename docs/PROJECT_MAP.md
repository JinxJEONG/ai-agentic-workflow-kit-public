# PROJECT_MAP

`.ai/canonical/PROJECT_MAP.yaml` is the per-project adapter layer.

The workflow engine reads this file for:

- workspace root
- repo paths and branches
- service paths
- protected paths
- tier 3 path patterns
- optional database safety rules
- project-specific high-risk path patterns

Keep project facts here rather than hardcoding them in scripts.

Minimal shape:

```yaml
workspace:
  name: my-project
  root: /absolute/path/to/my-project
  mode: single-repo

repos:
  main:
    path: .
    branch: main

services: {}

protected_paths:
  - .env
  - secrets/
  - production/

tier3_path_patterns:
  - db/**
  - migrations/**
  - deploy/**
  - auth/**
  - payments/**
  - .github/workflows/**
```

The path list is a project adapter, not the entire risk model. Feature metadata
also records semantic signals for database, authentication, authorization,
payments, deployment, environment, privacy, and secrets. Either a matching path
or a true semantic signal can require tier 3.
