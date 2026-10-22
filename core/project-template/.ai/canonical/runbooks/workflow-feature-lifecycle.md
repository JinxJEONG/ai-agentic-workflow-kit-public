# Workflow Feature Lifecycle

1. Create a feature with `create_feature.rb`.
2. Read `feature.yaml`, stream `manifest.yaml`, contracts, agent profile, and context map.
3. Confirm tier, risk signals, contracts, and stream scope ownership.
4. Activate one or more non-overlapping, parallel-allowed streams.
5. Keep every edit inside exactly one active writable scope.
6. Record structured validation, acceptance, and doc-sync evidence for the
   current revision.
7. Finish each stream while its worktree-local lock is owned by that stream.
8. Complete structured reviewer and human approval for tier 3 work.
9. Finish the feature after all declared streams, contracts, evidence, and
   document requirements pass.
10. Commit and push through separately authorized Git review rules.
11. Record deployment and production acceptance separately from feature status.
