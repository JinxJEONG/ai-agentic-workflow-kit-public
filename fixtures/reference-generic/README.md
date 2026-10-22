# Generic Example

Install into a generic project:

```sh
mkdir -p /tmp/generic-project
git -C /tmp/generic-project init -b main
ruby engine/install/bootstrap_project.rb /tmp/generic-project
cd /tmp/generic-project
git add .ai .github/workflows/agent-workflow-policy.yml AGENTS.md
git commit -m "chore: install AI agentic workflow kit"
ruby .ai/runtime/scripts/create_feature.rb --tier tier1 "Smoke test"
```

The commit is an explicit user step. The installer does not commit or push.
