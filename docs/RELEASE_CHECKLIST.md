# Release Checklist

This checklist separates a locally complete implementation from a published
release. No step here authorizes a commit, push, tag, package publication, or
deployment by itself.

## Required before tagging

- [ ] Confirm the intended semantic version and update `VERSION` and
  `CHANGELOG.md`.
- [ ] Select and add the repository license with the owner's explicit approval.
- [ ] Run `rake` on every supported Ruby and operating-system entry documented
  in `COMPATIBILITY.md`.
- [ ] Confirm the GitHub Actions matrix completed successfully for the candidate
  commit.
- [ ] Run a clean-clone bootstrap smoke test, then validate the installation
  manifest.
- [ ] Exercise `status`, legacy adoption, JSON plan/apply output, inventory,
  project-owned preservation, kit-owned replacement, conflict exit codes, and
  active-stream blocking.
- [ ] Exercise install, dry-run, repair, migration, rollback, linked-worktree,
  special-path, existing-hook, and protected-context cases.
- [ ] Confirm that no active local stream or lock is packaged.
- [ ] Run the high-confidence secret scan and review the diff for private data.
- [ ] Verify that completion evidence and review approvals bind to the candidate
  change-set digest.
- [ ] Obtain explicit owner approval for commit, push, tag, and publication as
  separate actions.

## After publication

- [ ] Record the tag and published artifact digest in the release notes.
- [ ] Re-run a consumer-project installation smoke test from the published tag.
- [ ] Record known limitations without treating deployment or production
  acceptance as implied by a successful release.
