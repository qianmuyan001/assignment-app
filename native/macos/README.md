# macOS native app

> **2.0 Catalyst status:** paused. This directory is a pure macOS SwiftPM app,
> not an iPadOS or Mac Catalyst project. The repository currently has no
> `.xcodeproj`/`.xcworkspace`, iPadOS app target, or UIKit lifecycle to migrate.
> Provide the original iPadOS project and resources to resume the requested
> Catalyst port. The commands below build the unchanged 1.0 native baseline;
> they do not produce the 2.0 Catalyst acceptance package.

## Run the packaged build

Start the local model in one Terminal window:

```bash
cd /path/to/assignment-app
./native/local-ai/start-macos.command
```

Then open:

```bash
open native/macos/dist/Assignments.app
```

`dist/Assignments-macOS-arm64.zip` is the clean archive for copying the app.

## Build and test

Requires Xcode with Swift 6.2 or newer:

```bash
cd /path/to/assignment-app/native/macos
swift test
./package_app.sh
codesign --verify --deep --strict dist/Assignments.app
```

The packaging script applies an ad-hoc development signature. The historical
bundle currently checked into `dist/` is not a 2.0 deliverable and should be
recreated on a full-Xcode machine before testing; in this checkout its copied
Finder/file-provider metadata prevents strict code-signature verification.
Public distribution still requires an Apple Developer ID certificate and
notarization.

## Existing database

When launched from this repository, the app locates
`backend/assignments.db`. To test against an isolated database:

```bash
ASSIGNMENT_DB_PATH=/absolute/path/to/test.db \
  .build/debug/AssignmentNative
```

The native client creates the existing schema only when it is missing. It does
not migrate, delete, or reset an existing assignment database.
