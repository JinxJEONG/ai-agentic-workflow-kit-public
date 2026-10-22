# Preparing a public release

Keep local release manifests private: their `file://` locators identify the
build machine. For a distributable manifest, use the public repository option.
It writes immutable-tag GitHub asset URLs and keeps local output paths out of
the manifest bytes. The archive, checksum and digest verification are unchanged.

```sh
ruby engine/release/release_manifest.rb build \
  --ref "$RELEASE_TAG" \
  --output-dir "$RELEASE_OUTPUT_DIR" \
  --public-repository "$PUBLIC_REPOSITORY"
ruby engine/release/release_manifest.rb verify \
  --ref "$RELEASE_TAG" \
  --output-dir "$RELEASE_OUTPUT_DIR"
```

`PUBLIC_REPOSITORY` must be `OWNER/REPO`, without credentials, query parameters
or a URL prefix. The equivalent Rake option is `RELEASE_PUBLIC_REPOSITORY`.
Upload only the archive, checksum and public manifest to the matching version
release. Build completion markers and console transcripts remain local.

Before publication, inspect every exported commit and tag, release metadata,
pull request and Actions log. A clean working tree does not prove that old
history is free of personal data. Use a noreply address for public commit and
tag identities. Keep machine configuration, memory indexes and real adoption
evidence outside the public repository.

The reusable workflow pins its action source by commit. A new repository or a
rewritten history requires a fresh source commit followed by a workflow-only
commit that pins that source. Rebuild and verify release artifacts after those
commits; do not reuse manifests from the old history or silently change existing
consumer locks. Set the workflow's repository identity to the actual published
repository and keep its identity checks enabled.

The `sample-*` canaries and `org.example.workflow-kit.disposable` container label
are examples. Existing local test containers using a different label must be
recreated or selected with the expected label; the loopback and disposable
container checks still apply.
