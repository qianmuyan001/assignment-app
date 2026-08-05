# macOS native app

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

The local package is ad-hoc signed for development. Public distribution still
requires an Apple Developer ID certificate and notarization.

## Existing database

When launched from this repository, the app locates
`backend/assignments.db`. To test against an isolated database:

```bash
ASSIGNMENT_DB_PATH=/absolute/path/to/test.db \
  .build/debug/AssignmentNative
```

The native client creates the existing schema only when it is missing. It does
not migrate, delete, or reset an existing assignment database.
