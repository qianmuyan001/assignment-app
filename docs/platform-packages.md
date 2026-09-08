# Windows / Mac packages with Web

`main` is the single development and integration branch. The platform split is
in the native implementations and downloadable packages, not long-lived branches.

## What is included

- Windows x64: the complete self-contained WinUI Release publish directory.
- Mac (Apple Silicon): the sandboxed, ad-hoc-signed Catalyst Debug `.app`.
- Both: the same committed Web/backend/shared sources, platform Web launcher,
  dependency list, native build evidence, file manifest and archive SHA-256.

Web runs independently in the default browser; Python 3.12+ must be installed.
The first launch installs Python dependencies over the internet. Leave the
launcher open while using the Web app, and stop it before starting another copy
on port 8000. This does not add an embedded browser to the Apple native client.

Native and Web default to separate databases. The Web app stores its data under
its own `Web/backend/` directory, unless `ASSIGNMENT_DB_PATH` overrides it.
Automatic synchronization is still an architecture proposal, not an implemented
feature. Windows native supports schema v3; Apple/Web support v4. Do not point
Windows native at a v4 database. Preserve existing database/attachment backups
before manually moving data. No personal data is shipped in a distribution.

## Download from GitHub

Open the successful workflow for the desired `main` commit under Actions:

- `Windows x64`: download `assignment-app-windows-with-web-<SHA>`.
- `Apple iPad and Catalyst`: download `assignment-app-macos-with-web-<SHA>`.

Extract the GitHub artifact, then the enclosed platform ZIP. The archive's
`README.txt` identifies the desktop executable and Web launcher. Artifacts are
kept for 30 days. Existing version tags and public releases are unchanged.

## Build locally

Always use a clean checkout. Build the native package first, then combine it
with the same commit's Web sources. The bundler rejects dirty source, mismatched
native build evidence, missing native executables and existing output ZIPs.

Windows (Visual Studio / .NET 8, signed-in Windows x64):

```powershell
./native/windows/publish-x64.ps1 -RequireCleanTree
python scripts/package_distribution.py --platform windows --native artifacts/windows/x64-<run>/publish --build-info artifacts/windows/x64-<run>/build-info.txt
```

Mac (installed Xcode toolchain):

```bash
ASSIGNMENT_REQUIRE_CLEAN_TREE=1 ./native/apple/package-catalyst.sh
python3 scripts/package_distribution.py --platform macos \
  --native 'artifacts/apple/debug-<run>/Assignment App.app' \
  --build-info artifacts/apple/debug-<run>/build-info.txt
```

Both produce ZIPs and checksums in `artifacts/distributions/`. The Windows build
requires Windows; generating an archive with a fixture executable is only a
packager test and must never be presented as a working Windows application.

## Acceptance boundaries

The Mac package is an internal Debug build, not Developer ID signed/notarized.
Windows CI validates Core tests and WinUI build/publish; its service session
cannot prove interactive desktop behavior or cold-start notification activation.
Consult the included `native-build-info.txt` for the exact source revision,
test, smoke and signing state. Release compilation alone is not GUI acceptance.
