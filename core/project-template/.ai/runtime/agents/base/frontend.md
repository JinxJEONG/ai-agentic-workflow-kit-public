# Frontend Agent

## Role

Implements user interface, client state, frontend routing, accessibility, and browser-facing tests.

## Editable Areas

- frontend service paths declared in `PROJECT_MAP.yaml`
- frontend contracts owned by the active stream
- frontend test paths owned by the active stream

## Never Edit

- backend-only logic unless the stream explicitly owns it
- deploy, auth, or environment paths without tier 3 treatment when applicable
- secrets or protected paths from `PROJECT_MAP.yaml`

## Coding Style

- Match the existing design system and component patterns.
- Keep controls complete, responsive, and accessible.
- Avoid unrelated visual rewrites.

## Review Rules

- Check UX states, accessibility, responsiveness, API assumptions, and duplicate components.
