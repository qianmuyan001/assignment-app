# Main consolidation — 2026-09-08

## Scope

The owner requested all committed updates on main, one Windows package and one Mac package, both retaining Web, and removal of redundant GitHub branches. The selected policy keeps only main. Existing tags/releases and uncommitted local files remain untouched.

## Integrated branch tips

| Source branch | Original commit | Included in integration history |
| --- | --- | --- |
| `local-source/main` | `e487dc21bc636906e717986844e5b4227e7f127a` | yes |
| `local-source/qianmuyan001/apple-2.1.2-preparation` | `7086f6f06efd0db1dcf145c36f7106e29f8d5167` | yes |
| `local-source/qianmuyan001/apple-foundation-rc` | `e2785589fcc5160492903ae53888b87b6a6149bd` | yes |
| `local-source/qianmuyan001/apple-phase3a` | `21ec6b26d49bd8da4905ce5eecc6e9ee4a215d6e` | yes |
| `local-source/qianmuyan001/apple-phase3a-preview` | `b0d69f7976519c3d816e97e0368658eb00ef471b` | yes |
| `local-source/qianmuyan001/apple-rc-ci-stability` | `566850ea0da33e619108162b6dbf6bbe636e3aa8` | yes |
| `local-source/qianmuyan001/apple-rc-hardening` | `7086f6f06efd0db1dcf145c36f7106e29f8d5167` | yes |
| `local-source/qianmuyan001/apple-rc-test-lifetime` | `9f231717289a0d03b081a2270356ced6ac7a7316` | yes |
| `local-source/qianmuyan001/integrate-release-apple-20260904` | `a181e9ef706f5e254c1bd33c74f26f0be9f5bba5` | yes |
| `local-source/qianmuyan001/phase2-5-checkpoint` | `61205f63a41923b5d3926aec66baf04b47f09147` | yes |
| `local-source/qianmuyan001/web-phase3a-v4` | `809917b3ce8aa13cde043c1f7129107c935f4702` | yes |
| `local-source/qianmuyan001/web-phase3a-v4-data` | `4d7cd848eb7258fb1f35ea082917ac9bb428901d` | yes |
| `local-source/qianmuyan001/web-phase3a-v4-scenes` | `18f6a9ab397c4b28731be5e392f47a91225771a0` | yes |
| `local-source/qianmuyan001/web-phase3a-v4-ui` | `c61d4373c10c343a911874562e515a4b56984bb7` | yes |
| `local-source/release/2.1` | `d79403303e69b1ed92c0ae058f4681e8bfab8af2` | yes |
| `origin/feature/nls-milestone1` | `ec92dc86c5df3e7b05fd8bf366fff634f17edd2f` | yes |
| `origin/feature/nls-winui-preview` | `d35c39d54deda6e5ca46b658f12d6a7520517a15` | yes |
| `origin/main` | `a181e9ef706f5e254c1bd33c74f26f0be9f5bba5` | yes |
| `origin/qianmuyan001/apple-foundation-rc` | `e2785589fcc5160492903ae53888b87b6a6149bd` | yes |
| `origin/qianmuyan001/integrate-release-apple-20260904` | `a181e9ef706f5e254c1bd33c74f26f0be9f5bba5` | yes |
| `origin/qianmuyan001/phase2-5-checkpoint` | `61205f63a41923b5d3926aec66baf04b47f09147` | yes |
| `origin/qianmuyan001/phase4-multiview` | `50e7c3e786dc3566bba841f190280546d4f91a40` | yes |
| `origin/qianmuyan001/sync-adr` | `bcc7c5ab8d3f7d57ee60330dae140d493b602647` | yes |
| `origin/qianmuyan001/windows-parity` | `0eeca68abdeb96ad3368b20d641c7adb30e34abc` | yes |
| `origin/release/1.1` | `36615c1761193c19a6a299eacb5bfe4250882a4b` | yes |
| `origin/release/2.1` | `d79403303e69b1ed92c0ae058f4681e8bfab8af2` | yes |

Five local supporting branches had already been cherry-picked into the Apple/Web aggregate branches. `git cherry HEAD <branch>` showed only patch-equivalent commits for every one. Their history was recorded with content-preserving merges after this check; no unique patch was discarded.

## Validation before publication

- Shared contract/migration suite: 131 passed.
- Backend/API/Web suite: 140 passed using disposable databases and loopback services.
- Windows Core: 60/60 passed locally using the .NET 10 runtime with major-version roll-forward; the Windows workflow runs on .NET 8.
- Web rules: 21 passed.
- Real Chromium acceptance: 18 passed, zero failed; included multilingual/narrow layouts, task/course/exam/reminder flows and backup/restore with attachments.
- Mac Catalyst Release compilation: passed with local Xcode, signing disabled for this build check.
- Platform bundler: real source inclusion, fixture archive structure/checksum, dirty-source and mismatched-evidence rejection verified.

Full platform packages are produced from the final clean revision by the platform scripts/workflows. The local build checks above preceded documentation/packaging-only changes. They do not assert Windows interactive acceptance or Apple notarization. See native build evidence for actual package results.

## Cleanup rule

Immediately before deletion, require each remote branch tip to still equal the inspected SHA and be an ancestor of published main. Delete only those remote branch refs. Preserve tags and existing local worktrees, including uncommitted files. A changed/new branch must be inspected before cleanup.

## Platform boundaries

See [platform packages](../platform-packages.md). Both bundles include standalone Web. Python is required; Windows native remains schema v3, Apple/Web v4, and automatic synchronization remains unimplemented.
