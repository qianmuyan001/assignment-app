#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$SCRIPT_DIR/AssignmentApp2.xcodeproj"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"

: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
: "${ASSIGNMENT_DERIVED_DATA:=/private/tmp/assignment-app-catalyst-derived-$(uuidgen)}"
: "${ASSIGNMENT_ARTIFACT_ROOT:=$REPOSITORY_ROOT/artifacts/apple}"
: "${ASSIGNMENT_RUN_STAMP:=$(date -u +%Y%m%d-%H%M%SZ)}"
: "${ASSIGNMENT_CATALYST_ARCH:=arm64}"
: "${ASSIGNMENT_CONFIGURATION:=Debug}"
: "${ASSIGNMENT_CREATE_DMG:=1}"
[[ "$ASSIGNMENT_CONFIGURATION" == Debug || "$ASSIGNMENT_CONFIGURATION" == Release ]] || exit 1
[[ "$ASSIGNMENT_CATALYST_ARCH" == arm64 ]] || { echo "Only arm64 is validated" >&2; exit 1; }
CONFIGURATION="$ASSIGNMENT_CONFIGURATION"
CONFIGURATION_LOWER="$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
: "${ASSIGNMENT_REQUIRE_CLEAN_TREE:=0}"
: "${ASSIGNMENT_SKIP_LAUNCH_SMOKE:=0}"
: "${ASSIGNMENT_IPAD_TESTS:=not-run-by-packager}"
: "${ASSIGNMENT_IPAD_UI_TESTS:=not-run-by-packager}"
: "${ASSIGNMENT_CATALYST_TESTS:=not-run-by-packager}"
export DEVELOPER_DIR

# The Xcode 27.0 beta Swift macro plugin server (`swift-plugin-server`)
# reports a malformed response when the host sandbox blocks the plugin
# process, which breaks every `@State` / `@Binding` expansion. The
# `-Xfrontend -disable-sandbox` flag passed to the build below disables the
# *Swift compiler's own* frontend sandbox for this one build. It is an
# invocation flag only: the app's `ENABLE_APP_SANDBOX` build setting and the
# `com.apple.security.app-sandbox` entitlement are untouched, so the signed
# deliverable is still sandboxed. Without it the build fails at the very
# first macro with:
#   external macro implementation type 'SwiftUIMacros.StateMacro'
#   could not be found

DERIVED_DATA="$ASSIGNMENT_DERIVED_DATA"
RUN_STAMP="$ASSIGNMENT_RUN_STAMP"
PACKAGE_CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "${ASSIGNMENT_LOCAL_RUNNABLE:-0}" != "0" ]]; then
  echo "Internal packages require App Sandbox; unsandboxed packaging is no longer supported." >&2
  exit 1
fi
SANDBOX_ENABLED=true
OUTPUT_DIR="$ASSIGNMENT_ARTIFACT_ROOT/$CONFIGURATION_LOWER-$RUN_STAMP"
SMOKE_BUNDLE_ID="com.qianmuyan.assignmentapp.rcsmoke.$(uuidgen | tr '[:upper:]' '[:lower:]')"
SMOKE_CONTAINER="$HOME/Library/Containers/$SMOKE_BUNDLE_ID"
SMOKE_DIR="$SMOKE_CONTAINER/Data/Library/Application Support/AssignmentApp2"
SMOKE_DATABASE="$SMOKE_DIR/assignments.db"
if [[ -e "$SMOKE_CONTAINER" ]]; then
  echo "Refusing to reuse an existing smoke container: $SMOKE_CONTAINER" >&2
  exit 1
fi
SOURCE_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-maccatalyst/Assignment App.app"
OUTPUT_APP="$OUTPUT_DIR/Assignment App.app"
OUTPUT_ZIP="$OUTPUT_DIR/Assignment-App-$VERSION-Catalyst-$CONFIGURATION-$ASSIGNMENT_CATALYST_ARCH.zip"
ENTITLEMENTS="$SCRIPT_DIR/AssignmentApp2/AssignmentApp2.entitlements"
DESTINATION="platform=macOS,arch=$ASSIGNMENT_CATALYST_ARCH,variant=Mac Catalyst"

if [[ ! "$RUN_STAMP" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ASSIGNMENT_RUN_STAMP contains unsupported path characters: $RUN_STAMP" >&2
  exit 1
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Required Xcode developer directory was not found: $DEVELOPER_DIR" >&2
  exit 1
fi

SOURCE_REVISION="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
SOURCE_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=all)"
SOURCE_TREE_DIRTY=false
if [[ -n "$SOURCE_STATUS" ]]; then
  SOURCE_TREE_DIRTY=true
fi
if [[ "$ASSIGNMENT_REQUIRE_CLEAN_TREE" == "1" && "$SOURCE_TREE_DIRTY" == "true" ]]; then
  echo "Refusing a release-baseline package from a dirty source tree." >&2
  exit 1
fi

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Refusing to overwrite existing artifact directory: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/logs"
python3 "$SCRIPT_DIR/scripts/protected-data-fingerprint.py" "$OUTPUT_DIR/logs/protected-before.json"

SIGN_ROOT=""
VERIFY_DIR=""
SMOKE_APP_LAUNCHED=false
SMOKE_PID=""
stop_smoke() {
  if [[ "$SMOKE_APP_LAUNCHED" == "true" ]]; then
    local pid
    pid="$(pgrep -f "$VERIFY_DIR/Assignment App.app/Contents/MacOS" || :)"
    for pid in $pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || return 1
      if ! kill -TERM "$pid"; then
        if kill -0 "$pid" 2>/dev/null; then return 1; fi
      fi
      for attempt in {1..100}; do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "Smoke process did not exit; retaining its database directory." >&2
        return 1
      fi
    done
    SMOKE_APP_LAUNCHED=false
  fi
}
cleanup() {
  local result=$?
  trap - EXIT
  if stop_smoke; then
    if [[ -d "$SMOKE_DIR" ]]; then
      # Only delete this run's data after ALL processes have released its files.
      local open_files inspection_status=0
      open_files="$(lsof -t +D "$SMOKE_DIR" 2> "$OUTPUT_DIR/logs/smoke-handle-inspection.log")" || inspection_status=$?
      if [[ -n "$open_files" || -s "$OUTPUT_DIR/logs/smoke-handle-inspection.log" || "$inspection_status" -gt 1 ]]; then
        echo "Smoke data is still in use; preserving $SMOKE_DIR" >&2
        result=1
      else
        case "$SMOKE_DIR" in
          "$HOME/Library/Containers/com.qianmuyan.assignmentapp.rcsmoke."*/Data/Library/Application\ Support/AssignmentApp2)
            rm -rf "$SMOKE_DIR" ;;
          *) echo "Refusing unexpected cleanup path" >&2; result=1 ;;
        esac
      fi
    fi
    case "$VERIFY_DIR" in
      /private/tmp/assignment-app-catalyst-verify.*) rm -rf "$VERIFY_DIR" ;;
    esac
    case "$SIGN_ROOT" in
      /private/tmp/assignment-app-catalyst-sign.*) rm -rf "$SIGN_ROOT" ;;
    esac
  else
    result=1
  fi
  if ! python3 "$SCRIPT_DIR/scripts/protected-data-fingerprint.py" \
    "$OUTPUT_DIR/logs/protected-after.json" --compare "$OUTPUT_DIR/logs/protected-before.json" \
    > "$OUTPUT_DIR/logs/protected-comparison.log" 2>&1; then
    cat "$OUTPUT_DIR/logs/protected-comparison.log" >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT

if [[ "$SOURCE_TREE_DIRTY" == "true" ]]; then
  printf '%s\n' "$SOURCE_STATUS" > "$OUTPUT_DIR/logs/source-status.log"
else
  echo "clean" > "$OUTPUT_DIR/logs/source-status.log"
fi

# The artifact root can sit under a file-provider-managed tree (anything
# Desktop-backed, for example). There, Finder re-attaches com.apple.FinderInfo
# and com.apple.fileprovider.fpfs#P to a freshly created directory within a
# second or two, and codesign rejects an app bundle carrying that metadata
# ("resource fork, Finder information, or similar detritus not allowed").
# Stripping it is a losing race, so the whole copy / sign / package pipeline
# runs inside /private/tmp and only the finished deliverable is published into
# the artifact directory. Metadata attached to that final copy is harmless,
# because nothing is signed or verified afterwards.
SIGN_ROOT="$(mktemp -d /private/tmp/assignment-app-catalyst-sign.XXXXXX)"
case "$SIGN_ROOT" in
  /private/tmp/assignment-app-catalyst-sign.*) ;;
  *) echo "Unexpected signing directory: $SIGN_ROOT" >&2; exit 1 ;;
esac
SIGN_APP="$SIGN_ROOT/Assignment App.app"
SIGN_ZIP="$SIGN_ROOT/Assignment-App-$VERSION-Catalyst-$CONFIGURATION-$ASSIGNMENT_CATALYST_ARCH.zip"


xcodebuild \
  -project "$PROJECT" \
  -scheme AssignmentApp2 \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO \
  "OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -disable-sandbox" \
  clean build 2>&1 | tee "$OUTPUT_DIR/logs/catalyst-build.log"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Catalyst app was not produced at $SOURCE_APP" >&2
  exit 1
fi

BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$SOURCE_APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "Built Apple version $BUILT_VERSION does not match VERSION $VERSION" >&2
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
ditto --norsrc --noextattr --noqtn --noacl "$SOURCE_APP" "$SIGN_APP"
# Re-identify the actual transferable app BEFORE signing. Finder launches of
# this internal package can never select the production sandbox container.
plutil -replace CFBundleIdentifier -string "$SMOKE_BUNDLE_ID" "$SIGN_APP/Contents/Info.plist"
plutil -insert AssignmentGitSHA -string "$SOURCE_REVISION" "$SIGN_APP/Contents/Info.plist"
xattr -cr "$SIGN_APP"
python3 "$SCRIPT_DIR/scripts/sign-apple-bundle.py" "$SIGN_APP" --entitlements "$ENTITLEMENTS" \
  2>&1 | tee "$OUTPUT_DIR/logs/codesign.log"
codesign --verify --deep --strict --verbose=2 "$SIGN_APP" \
  2>&1 | tee "$OUTPUT_DIR/logs/codesign-verify.log"
codesign -d --entitlements :- "$SIGN_APP" \
  > "$OUTPUT_DIR/logs/codesign-entitlements.plist" \
  2> "$OUTPUT_DIR/logs/codesign-entitlements.log"
if [[ "$SANDBOX_ENABLED" == "true" ]]; then
  [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
    "$OUTPUT_DIR/logs/codesign-entitlements.plist")" == "true" ]]
fi

COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$SIGN_APP" "$SIGN_ZIP"
unzip -t "$SIGN_ZIP" > "$OUTPUT_DIR/logs/zip-verify.log"
zip_entries="$(unzip -Z1 "$SIGN_ZIP")"
if grep -Eq '(^|/)(__MACOSX|\._)' <<< "$zip_entries"; then
  echo "ZIP contains Finder metadata or AppleDouble entries" >&2
  exit 1
fi
echo "appledouble_entries=absent" >> "$OUTPUT_DIR/logs/zip-verify.log"

# Publish the signed deliverable into the artifact directory.
ditto --norsrc --noextattr --noqtn --noacl "$SIGN_APP" "$OUTPUT_APP"
cp "$SIGN_ZIP" "$OUTPUT_ZIP"

# Verify the actual transferable payload after extracting it outside the
# Desktop file-provider tree. Finder may attach metadata to the visible app
# directory later, but that metadata is excluded from the ZIP.
VERIFY_DIR="$(mktemp -d /private/tmp/assignment-app-catalyst-verify.XXXXXX)"
case "$VERIFY_DIR" in
  /private/tmp/assignment-app-catalyst-verify.*) ;;
  *) echo "Unexpected verification directory: $VERIFY_DIR" >&2; exit 1 ;;
esac


ditto -x -k "$OUTPUT_ZIP" "$VERIFY_DIR"
ARCHIVE_APP="$VERIFY_DIR/Assignment App.app"
codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP" \
  > "$OUTPUT_DIR/logs/archive-codesign-verify.log" 2>&1
codesign -d --entitlements :- "$ARCHIVE_APP" \
  > "$OUTPUT_DIR/logs/archive-entitlements.plist" \
  2> "$OUTPUT_DIR/logs/archive-entitlements.log"
if [[ "$SANDBOX_ENABLED" == "true" ]]; then
  [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
    "$OUTPUT_DIR/logs/archive-entitlements.plist")" == "true" ]]
fi

OUTPUT_DMG="${OUTPUT_ZIP%.zip}.dmg"
DMG_RESULT=not-created
if [[ "$ASSIGNMENT_CREATE_DMG" == "1" ]]; then
  mkdir "$SIGN_ROOT/dmg"
  ditto --norsrc --noextattr --noqtn --noacl "$SIGN_APP" "$SIGN_ROOT/dmg/Assignment App.app"
  ln -s /Applications "$SIGN_ROOT/dmg/Applications"
  hdiutil create -volname "Assignment App $VERSION Internal" -srcfolder "$SIGN_ROOT/dmg" \
    -format UDZO "$OUTPUT_DMG" > "$OUTPUT_DIR/logs/dmg-create.log" 2>&1
  hdiutil verify "$OUTPUT_DMG" > "$OUTPUT_DIR/logs/dmg-verify.log" 2>&1
  DMG_RESULT=verified-not-installed
fi
python3 "$SCRIPT_DIR/scripts/check-apple-version.py" "$OUTPUT_APP" > "$OUTPUT_DIR/logs/apple-version.log"
LAUNCH_SMOKE_RESULT="skipped"
SMOKE_SCHEMA_VERSION="not-checked"

# A blocked launch must still leave traceable evidence behind. The package is
# never reported as passing, but the failure has to be reproducible from the
# artifact directory and tied to a source revision.
capture_crash_report() {
  local newest="" candidate
  local reports_dir="$HOME/Library/Logs/DiagnosticReports"
  for candidate in "$reports_dir"/Assignment\ App-*.ips \
                   "$reports_dir"/Retired/Assignment\ App-*.ips; do
    [[ -f "$candidate" ]] || continue
    if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
      newest="$candidate"
    fi
  done
  if [[ -n "$newest" ]] && grep -Fq "$VERIFY_DIR/Assignment App.app/" "$newest"; then
    cp "$newest" "$OUTPUT_DIR/logs/catalyst-launch-crash.ips"
  fi
}

write_build_info() {
  {
    echo "Assignment App $VERSION Apple $CONFIGURATION internal package"
    echo "created_utc=$PACKAGE_CREATED_UTC"
    echo "run_stamp=$RUN_STAMP"
    echo "scheme=AssignmentApp2"
    echo "configuration=$CONFIGURATION"
    echo "destination=$DESTINATION"
    echo "architecture=$ASSIGNMENT_CATALYST_ARCH"
    echo "bundle_identifier=$SMOKE_BUNDLE_ID"
    echo "runtime_database_path=$SMOKE_DATABASE"
    echo "distribution=internal-testing-only; ad-hoc; not-notarized; not-a-production-release"
    echo "version=$VERSION"
    echo "build_number=$(plutil -extract CFBundleVersion raw -o - "$OUTPUT_APP/Contents/Info.plist")"
    echo "minimum_system=$(plutil -extract LSMinimumSystemVersion raw -o - "$OUTPUT_APP/Contents/Info.plist")"
    echo "sdk=$(xcrun --sdk macosx --show-sdk-version)"
    echo "actual_architectures=$(lipo -archs "$OUTPUT_APP/Contents/MacOS/Assignment App")"
    echo "formal_acceptance=not-executed"
    echo "developer_id=not-executed; notarization=not-executed; gatekeeper=not-executed"
    echo "dmg_structure=$DMG_RESULT"
    echo "derived_data=$DERIVED_DATA"
    echo "source_revision=$SOURCE_REVISION"
    echo "source_tree_dirty=$SOURCE_TREE_DIRTY"
    echo "source_status_log=logs/source-status.log"
    echo "ipad_tests=$ASSIGNMENT_IPAD_TESTS"
    echo "ipad_ui_tests=$ASSIGNMENT_IPAD_UI_TESTS"
    echo "catalyst_tests=$ASSIGNMENT_CATALYST_TESTS"
    echo "launch_smoke=$LAUNCH_SMOKE_RESULT"
    echo "smoke_schema_version=$SMOKE_SCHEMA_VERSION"
    echo "signing=ad-hoc"
    echo "app_sandbox=$SANDBOX_ENABLED"
    echo "coverage_instrumentation=absent"
    echo "zip_appledouble=absent"
    echo
    xcodebuild -version
    xcrun swift --version
    echo
    shasum -a 256 "$OUTPUT_ZIP"
    if [[ -f "$OUTPUT_DMG" ]]; then shasum -a 256 "$OUTPUT_DMG"; fi
  } > "$OUTPUT_DIR/build-info.txt"
}

fail_launch() {
  LAUNCH_SMOKE_RESULT="failed"
  capture_crash_report
  write_build_info
  echo "$1" >&2
  echo "build-info.txt written with launch_smoke=failed at $OUTPUT_DIR/build-info.txt" >&2
  exit 1
}

if [[ "$ASSIGNMENT_SKIP_LAUNCH_SMOKE" != "1" ]]; then
  : > "$OUTPUT_DIR/logs/catalyst-launch-smoke.log"
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$ARCHIVE_APP/Contents/Info.plist")" == "$SMOKE_BUNDLE_ID" ]]
  [[ ! -e "$SMOKE_CONTAINER" ]]
  # `open -n` addresses this exact app, creates a fresh process, and lets
  # LaunchServices install the sandbox. No environment propagation is used.
  open -n "$ARCHIVE_APP" --stdout "$OUTPUT_DIR/logs/catalyst-runtime-stdout.log" \
    --stderr "$OUTPUT_DIR/logs/catalyst-runtime-stderr.log" \
    >> "$OUTPUT_DIR/logs/catalyst-launch-smoke.log" 2>&1
  SMOKE_APP_LAUNCHED=true
  SMOKE_STARTED_AT="$(date +%s)"
  SMOKE_PID=""
  SMOKE_READY=false
  for attempt in {1..100}; do
    if [[ -z "$SMOKE_PID" ]]; then
      SMOKE_PID="$(pgrep -f "$VERIFY_DIR/Assignment App.app/Contents/MacOS" | head -1 || true)"
      if [[ -n "$SMOKE_PID" ]]; then
        echo "attempt=$attempt pid=$SMOKE_PID" >> "$OUTPUT_DIR/logs/catalyst-launch-smoke.log"
      fi
    fi
    if [[ -n "$SMOKE_PID" ]]; then
      lsof -a -p "$SMOKE_PID" -Fn > "$OUTPUT_DIR/logs/catalyst-open-files.log" 2>/dev/null
      # Inspect path strings first; never point sqlite3 at a discovered user DB.
      if grep -Fqx "n$SMOKE_DATABASE" "$OUTPUT_DIR/logs/catalyst-open-files.log"; then
        if grep -F -e 'n'"$HOME/Library/Containers/com.qianmuyan.assignmentapp/" \
          -e 'n'"$HOME/Library/Application Support/AssignmentApp2/" \
          "$OUTPUT_DIR/logs/catalyst-open-files.log"; then
          fail_launch "Smoke process unexpectedly opened the production container."
        fi
        if CANDIDATE_SCHEMA_VERSION="$(sqlite3 -readonly "$SMOKE_DATABASE" 'PRAGMA user_version;')" && \
          [[ "$CANDIDATE_SCHEMA_VERSION" == "4" ]]; then
          SMOKE_READY=true
          break
        fi
      fi
    fi
    sleep 0.2
  done
  if [[ "$SMOKE_READY" != "true" ]]; then
    fail_launch "Packaged Catalyst app did not launch and open a v4 database within 20 seconds."
  fi
  SMOKE_READY_SECONDS="$(( $(date +%s) - SMOKE_STARTED_AT ))"

  SMOKE_SCHEMA_VERSION="$(sqlite3 -readonly "$SMOKE_DATABASE" 'PRAGMA user_version;')"
  SMOKE_QUICK_CHECK="$(sqlite3 -readonly "$SMOKE_DATABASE" 'PRAGMA quick_check;')"
  SMOKE_FOREIGN_KEY_ERRORS="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    'SELECT COUNT(*) FROM pragma_foreign_key_check;')"
  SMOKE_TABLES="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name);")"
  SMOKE_COLUMNS="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('assignments') ORDER BY name);")"
  SMOKE_INDEXES="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name);")"
  SMOKE_TRIGGERS="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name);")"
  SMOKE_IDENTITY_ROWS="$(sqlite3 -readonly "$SMOKE_DATABASE" \
    "SELECT COUNT(*) FROM database_identity WHERE singleton = 1 AND length(instance_uuid) = 36 AND instance_uuid = lower(instance_uuid) AND substr(instance_uuid, 9, 1) = '-' AND substr(instance_uuid, 14, 1) = '-' AND substr(instance_uuid, 15, 1) = '4' AND substr(instance_uuid, 19, 1) = '-' AND substr(instance_uuid, 20, 1) IN ('8', '9', 'a', 'b') AND substr(instance_uuid, 24, 1) = '-' AND replace(instance_uuid, '-', '') NOT GLOB '*[^0-9a-f]*';")"
  EXPECTED_V4_TABLES="assignments,attachments,course_meetings,courses,database_identity,exams,projects,reminders,subtasks,tags,task_tags"
  EXPECTED_ASSIGNMENT_COLUMNS="all_day,completed_at,course_id,course_name,created_at,deleted_at,description,due_date,id,link,priority,progress_percent,project_id,source_file,source_name,source_type,source_url,status,timezone_id,title,updated_at,uuid"
  EXPECTED_V4_INDEXES="ix_assignments_course_id,ix_assignments_deleted_at,ix_assignments_due_date,ix_assignments_priority,ix_assignments_project_id,ix_assignments_status,ix_attachments_assignment,ix_attachments_sha256,ix_course_meetings_deleted_at,ix_course_meetings_week,ix_courses_archived_name,ix_courses_normalized_name,ix_exams_course_start,ix_exams_deleted_at,ix_exams_status_start,ix_projects_course_status,ix_projects_deleted_at,ix_reminders_assignment,ix_reminders_enabled_trigger,ix_subtasks_assignment_order,ix_subtasks_status,ix_tags_deleted_at,ix_task_tags_assignment,ix_task_tags_tag,ux_assignments_uuid,ux_attachments_relative_path,ux_attachments_uuid,ux_course_meetings_uuid,ux_courses_uuid,ux_exams_linked_assignment,ux_exams_uuid,ux_projects_uuid,ux_reminders_uuid,ux_subtasks_uuid,ux_tags_normalized_name,ux_tags_uuid,ux_task_tags_active_pair,ux_task_tags_uuid"
  EXPECTED_V4_TRIGGERS="assignments_uuid_immutable,assignments_v3_contract_insert,assignments_v3_contract_update,attachments_uuid_immutable,course_meetings_uuid_immutable,courses_uuid_immutable,database_identity_immutable_delete,database_identity_immutable_update,exams_uuid_immutable,projects_uuid_immutable,reminders_uuid_immutable,subtasks_uuid_immutable,tags_uuid_immutable,task_tags_uuid_immutable"
  # Indexes are checked as a superset, not for equality: the contract says
  # which indexes a v4 store must carry, and a store that arrived at v4 by
  # migrating an older schema legitimately keeps legacy indexes. Only a
  # missing contract index is a defect.
  MISSING_CONTRACT_INDEXES=""
  IFS=',' read -r -a EXPECTED_INDEX_LIST <<< "$EXPECTED_V4_INDEXES"
  for expected_index in "${EXPECTED_INDEX_LIST[@]}"; do
    if [[ ",$SMOKE_INDEXES," != *",$expected_index,"* ]]; then
      MISSING_CONTRACT_INDEXES+="$expected_index "
    fi
  done
  if [[ "$SMOKE_SCHEMA_VERSION" != "4" || "$SMOKE_QUICK_CHECK" != "ok" || \
        "$SMOKE_FOREIGN_KEY_ERRORS" != "0" || "$SMOKE_IDENTITY_ROWS" != "1" || \
        "$SMOKE_TABLES" != "$EXPECTED_V4_TABLES" || \
        "$SMOKE_COLUMNS" != "$EXPECTED_ASSIGNMENT_COLUMNS" || \
        -n "$MISSING_CONTRACT_INDEXES" || \
        "$SMOKE_TRIGGERS" != "$EXPECTED_V4_TRIGGERS" ]]; then
    if [[ -n "$MISSING_CONTRACT_INDEXES" ]]; then
      fail_launch "Packaged Catalyst database is missing contract indexes: $MISSING_CONTRACT_INDEXES"
    fi
    fail_launch "Packaged Catalyst database smoke validation failed."
  fi
  # The process was launched by LaunchServices, so liveness is checked by
  # this run's extraction path rather than by a PID we never owned. It must
  # still be running after the schema validation above has had its turn.
  if ! pgrep -f "$VERIFY_DIR/Assignment App.app/Contents/MacOS" > /dev/null 2>&1; then
    fail_launch "Packaged Catalyst app exited after database initialization."
  fi
  {
    echo "smoke_pid=$SMOKE_PID"
    echo "runtime_database_path=$SMOKE_DATABASE"
    echo "bundle_identifier=$SMOKE_BUNDLE_ID"
    echo "database_provenance=fresh-per-run-container; app-opened (lsof-verified)"
    echo "user_version=$SMOKE_SCHEMA_VERSION"
    echo "quick_check=$SMOKE_QUICK_CHECK"
    echo "foreign_key_errors=$SMOKE_FOREIGN_KEY_ERRORS"
    echo "database_identity_rows=$SMOKE_IDENTITY_ROWS"
    echo "tables=$SMOKE_TABLES"
    echo "assignment_columns=$SMOKE_COLUMNS"
    echo "assignment_column_count=22"
    echo "contract_indexes=$SMOKE_INDEXES"
    echo "contract_index_count=38"
    echo "contract_triggers=$SMOKE_TRIGGERS"
    echo "contract_trigger_count=14"
    echo "database_ready_seconds=$SMOKE_READY_SECONDS"
    echo "process_alive_after_schema_validation=true"
  } >> "$OUTPUT_DIR/logs/catalyst-launch-smoke.log"
  stop_smoke
  # Preserve only the isolated database after the process has released it.
  cp "$SMOKE_DATABASE" "$OUTPUT_DIR/logs/isolated-assignments.db"
  for sidecar in -wal -shm; do
    if [[ -f "$SMOKE_DATABASE$sidecar" ]]; then
      cp "$SMOKE_DATABASE$sidecar" "$OUTPUT_DIR/logs/isolated-assignments.db$sidecar"
    fi
  done
  python3 "$SCRIPT_DIR/scripts/protected-data-fingerprint.py" \
    "$OUTPUT_DIR/logs/protected-after.json" --compare "$OUTPUT_DIR/logs/protected-before.json" \
    | tee "$OUTPUT_DIR/logs/protected-comparison.log"
  LAUNCH_SMOKE_RESULT="passed"
fi

write_build_info

echo "$OUTPUT_DIR"
