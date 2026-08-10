#!/bin/bash

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$SCRIPT_DIR/AssignmentApp2.xcodeproj"
DERIVED_DATA=/private/tmp/assignment-app-xcode-derived-data
RUN_STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
OUTPUT_DIR="$REPOSITORY_ROOT/artifacts/apple/debug-$RUN_STAMP"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug-maccatalyst/Assignment App.app"
OUTPUT_APP="$OUTPUT_DIR/Assignment App.app"
OUTPUT_ZIP="$OUTPUT_DIR/Assignment-App-2.0-Catalyst-Debug-arm64.zip"
ENTITLEMENTS="$SCRIPT_DIR/AssignmentApp2/AssignmentApp2.entitlements"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Required Xcode was not found at $DEVELOPER_DIR" >&2
  exit 1
fi

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Refusing to overwrite existing artifact directory: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/logs"

xcodebuild \
  -project "$PROJECT" \
  -scheme AssignmentApp2 \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64,variant=Mac Catalyst' \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build 2>&1 | tee "$OUTPUT_DIR/logs/catalyst-build.log"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Catalyst app was not produced at $SOURCE_APP" >&2
  exit 1
fi

{
  echo "Checking release payload for stale XCTest coverage instrumentation"
  for binary in "$SOURCE_APP/Contents/MacOS/"*; do
    [[ -f "$binary" ]] || continue
    file "$binary"
    if ! nm_output="$(nm "$binary" 2>/dev/null)"; then
      echo "Unable to inspect symbols in $binary" >&2
      exit 1
    fi
    if grep -Eq '__llvm_(profile|prf)' <<< "$nm_output"; then
      echo "Coverage symbol found in $binary" >&2
      exit 1
    fi
    if ! load_commands="$(otool -l "$binary" 2>/dev/null)"; then
      echo "Unable to inspect load commands in $binary" >&2
      exit 1
    fi
    if grep -q '__LLVM_COV' <<< "$load_commands"; then
      echo "Coverage segment found in $binary" >&2
      exit 1
    fi
  done
  echo "coverage_instrumentation=absent"
} 2>&1 | tee "$OUTPUT_DIR/logs/binary-profile-check.log"

# Desktop can be managed by a file provider, so never copy Finder metadata or
# extended attributes into the deliverable. They can invalidate strict
# signature verification and create AppleDouble entries in the ZIP.
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$OUTPUT_APP"
xattr -cr "$OUTPUT_APP"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$OUTPUT_APP" \
  2>&1 | tee "$OUTPUT_DIR/logs/codesign.log"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP" \
  2>&1 | tee "$OUTPUT_DIR/logs/codesign-verify.log"
codesign -d --entitlements :- "$OUTPUT_APP" \
  > "$OUTPUT_DIR/logs/codesign-entitlements.plist" \
  2> "$OUTPUT_DIR/logs/codesign-entitlements.log"
[[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
  "$OUTPUT_DIR/logs/codesign-entitlements.plist")" == "true" ]]
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$OUTPUT_APP" "$OUTPUT_ZIP"
unzip -t "$OUTPUT_ZIP" > "$OUTPUT_DIR/logs/zip-verify.log"
zip_entries="$(unzip -Z1 "$OUTPUT_ZIP")"
if grep -Eq '(^|/)(__MACOSX|\._)' <<< "$zip_entries"; then
  echo "ZIP contains Finder metadata or AppleDouble entries" >&2
  exit 1
fi
echo "appledouble_entries=absent" >> "$OUTPUT_DIR/logs/zip-verify.log"

# Verify the actual transferable payload after extracting it outside the
# Desktop file-provider tree. Finder may attach metadata to the visible app
# directory later, but that metadata is excluded from the ZIP.
VERIFY_DIR="$(mktemp -d /private/tmp/assignment-app-catalyst-verify.XXXXXX)"
case "$VERIFY_DIR" in
  /private/tmp/assignment-app-catalyst-verify.*) ;;
  *) echo "Unexpected verification directory: $VERIFY_DIR" >&2; exit 1 ;;
esac
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$OUTPUT_ZIP" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 \
  "$VERIFY_DIR/Assignment App.app" \
  > "$OUTPUT_DIR/logs/archive-codesign-verify.log" 2>&1
codesign -d --entitlements :- "$VERIFY_DIR/Assignment App.app" \
  > "$OUTPUT_DIR/logs/archive-entitlements.plist" \
  2> "$OUTPUT_DIR/logs/archive-entitlements.log"
[[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
  "$OUTPUT_DIR/logs/archive-entitlements.plist")" == "true" ]]

SOURCE_TREE_DIRTY=false
if [[ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain)" ]]; then
  SOURCE_TREE_DIRTY=true
fi

{
  echo "Assignment App 2.0 Apple Debug package"
  echo "created_utc=$RUN_STAMP"
  echo "scheme=AssignmentApp2"
  echo "configuration=Debug"
  echo "destination=platform=macOS,arch=arm64,variant=Mac Catalyst"
  echo "bundle_identifier=com.qianmuyan.assignmentapp"
  echo "derived_data=$DERIVED_DATA"
  echo "source_revision=$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
  echo "source_tree_dirty=$SOURCE_TREE_DIRTY"
  echo
  xcodebuild -version
  xcrun swift --version
  echo
  shasum -a 256 "$OUTPUT_ZIP"
} > "$OUTPUT_DIR/build-info.txt"

echo "$OUTPUT_DIR"
