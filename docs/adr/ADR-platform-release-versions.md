# Independent Apple release versions

Date: 2026-09-21

Status: Implemented in the Apple 2.1.2 integration candidate; not a release approval.

The Apple roadmap advances its existing 2.1.2 implementation independently of
Windows/Web. The previous shared gate required every marketing version to equal
the root VERSION, which rejected otherwise consistent Apple metadata and blocked
all platform workflows. Application versions must not stand in for data contracts.

## Decision

- `native/apple/VERSION` and `BUILD_NUMBER` own Apple marketing/build versions.
  Every Apple target configuration and its changelog must match them. The Apple
  build also verifies the generated app's Info.plist and bundled changelog.
- Root `VERSION`, root README/CHANGELOG, and Windows project/binary/manifest
  versions retain their existing contract. This change does not advance them.
  Separating Windows/Web version ownership later requires its own explicit change.
- `scripts/check_version_sync.py` remains mandatory. It checks internal platform
  consistency rather than cross-platform marketing-version equality. Regression
  tests verify that stale targets, binaries, manifests and release notes still fail.
- Distribution names and `manifest.version` identify the native platform version.
  `manifest.web_version` and README identify the bundled Web version separately.
  Both components must originate from the same clean source SHA. Mac packaging
  additionally verifies native VERSION/build evidence against the actual Info.plist.
- Database migrations, Schema v4, UUID/time/status/reminder semantics and shared
  tests remain unchanged. Independent marketing versions neither grant data
  compatibility nor authorize a platform to invent a different schema.
- Platform feature branches/worktrees are permitted. Integration preserves the
  common source history; the distribution bundle records its exact integrated SHA.

## Scope and validation

The integration candidate combines main `8267cdb` with Apple `6ec3f40`, preserving
main's other-platform changes. The historical candidate patch under
`docs/release/patches/platform-version-contract.patch` is superseded by the live
checker and tests; do not reapply it.

Current versions remain Apple 2.1.2/build 2 and Windows/Web 2.1.0. Version checks
and packaging tests do not constitute notification, UI, signing or installation
acceptance. Publish only from an independently accepted source revision.
