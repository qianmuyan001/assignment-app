#!/usr/bin/env bash

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$PACKAGE_ROOT/dist"
APP_DIR="$DIST_DIR/Assignments.app"
ARCHIVE_PATH="$DIST_DIR/Assignments-macOS-arm64.zip"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PACKAGE_ROOT"
swift build -c release

mkdir -p "$MACOS_DIR"
cp "$PACKAGE_ROOT/.build/release/AssignmentNative" "$MACOS_DIR/AssignmentNative"
cp "$PACKAGE_ROOT/Info.plist" "$CONTENTS_DIR/Info.plist"

# Finder/File Provider metadata can be attached after the bundle has been opened.
# Clear only extended attributes from this generated app bundle before signing.
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

# A ZIP without macOS extra fields is stable even when the project itself lives
# in a File Provider/Desktop folder that immediately reattaches Finder metadata.
(
    cd "$DIST_DIR"
    COPYFILE_DISABLE=1 /usr/bin/zip -qry -FS -X \
        "$(basename "$ARCHIVE_PATH")" \
        "$(basename "$APP_DIR")"
)

echo "Built $APP_DIR"
echo "Archived $ARCHIVE_PATH"
