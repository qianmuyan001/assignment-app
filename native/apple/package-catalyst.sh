#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT="$SCRIPT_DIR/AssignmentApp2.xcodeproj"
VERSION="$(tr -d '[:space:]' < "$REPOSITORY_ROOT/VERSION")"

: "${DEVELOPER_DIR:=/Applications/Xcode-beta.app/Contents/Developer}"
: "${ASSIGNMENT_DERIVED_DATA:=/private/tmp/assignment-app-xcode-derived-data}"
: "${ASSIGNMENT_ARTIFACT_ROOT:=$REPOSITORY_ROOT/artifacts/apple}"
: "${ASSIGNMENT_RUN_STAMP:=$(date -u +%Y%m%d-%H%M%SZ)}"
: "${ASSIGNMENT_CATALYST_ARCH:=arm64}"
: "${ASSIGNMENT_REQUIRE_CLEAN_TREE:=0}"
: "${ASSIGNMENT_SKIP_LAUNCH_SMOKE:=0}"
: "${ASSIGNMENT_IPAD_TESTS:=not-run-by-packager}"
: "${ASSIGNMENT_IPAD_UI_TESTS:=not-run-by-packager}"
: "${ASSIGNMENT_CATALYST_TESTS:=not-run-by-packager}"
export DEVELOPER_DIR

DERIVED_DATA="$ASSIGNMENT_DERIVED_DATA"
RUN_STAMP="$ASSIGNMENT_RUN_STAMP"
OUTPUT_DIR="$ASSIGNMENT_ARTIFACT_ROOT/debug-$RUN_STAMP"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug-maccatalyst/Assignment App.app"
OUTPUT_APP="$OUTPUT_DIR/Assignment App.app"
OUTPUT_ZIP="$OUTPUT_DIR/Assignment-App-$VERSION-Catalyst-Debug-$ASSIGNMENT_CATALYST_ARCH.zip"
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
if [[ "$SOURCE_TREE_DIRTY" == "true" ]]; then
  printf '%s\n' "$SOURCE_STATUS" > "$OUTPUT_DIR/logs/source-status.log"
else
  echo "clean" > "$OUTPUT_DIR/logs/source-status.log"
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme AssignmentApp2 \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO \
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

SMOKE_DIR=""
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$SMOKE_DIR" ]]; then
    case "$SMOKE_DIR" in
      "$HOME/Library/Containers/com.qianmuyan.assignmentapp/Data/tmp/assignment-app-smoke-"*)
        rm -rf "$SMOKE_DIR"
        ;;
      *) echo "Refusing to clean unexpected smoke directory: $SMOKE_DIR" >&2 ;;
    esac
  fi
  case "$VERIFY_DIR" in
    /private/tmp/assignment-app-catalyst-verify.*) rm -rf "$VERIFY_DIR" ;;
  esac
}
trap cleanup EXIT

ditto -x -k "$OUTPUT_ZIP" "$VERIFY_DIR"
ARCHIVE_APP="$VERIFY_DIR/Assignment App.app"
codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP" \
  > "$OUTPUT_DIR/logs/archive-codesign-verify.log" 2>&1
codesign -d --entitlements :- "$ARCHIVE_APP" \
  > "$OUTPUT_DIR/logs/archive-entitlements.plist" \
  2> "$OUTPUT_DIR/logs/archive-entitlements.log"
[[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - \
  "$OUTPUT_DIR/logs/archive-entitlements.plist")" == "true" ]]

LAUNCH_SMOKE_RESULT="skipped"
SMOKE_SCHEMA_VERSION="not-checked"
if [[ "$ASSIGNMENT_SKIP_LAUNCH_SMOKE" != "1" ]]; then
  CONTAINER_TMP="$HOME/Library/Containers/com.qianmuyan.assignmentapp/Data/tmp"
  SMOKE_DIR="$CONTAINER_TMP/assignment-app-smoke-$RUN_STAMP-$$"
  SMOKE_DATABASE="$SMOKE_DIR/assignments.db"
  mkdir -p "$SMOKE_DIR"

  ASSIGNMENT_DB_PATH="$SMOKE_DATABASE" \
    "$ARCHIVE_APP/Contents/MacOS/Assignment App" \
    > "$OUTPUT_DIR/logs/catalyst-launch-smoke.log" 2>&1 &
  APP_PID=$!

  SMOKE_STARTED_AT="$(date +%s)"
  SMOKE_READY=false
  for _ in {1..100}; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      wait "$APP_PID" || true
      echo "Packaged Catalyst app exited during launch smoke." >&2
      exit 1
    fi
    if [[ -f "$SMOKE_DATABASE" ]] && \
      CANDIDATE_SCHEMA_VERSION="$(sqlite3 "$SMOKE_DATABASE" 'PRAGMA user_version;' 2>/dev/null)" && \
      [[ "$CANDIDATE_SCHEMA_VERSION" == "4" ]]; then
      SMOKE_READY=true
      break
    fi
    sleep 0.2
  done
  if [[ "$SMOKE_READY" != "true" ]]; then
    echo "Packaged Catalyst app did not initialize a v4 smoke database within 20 seconds." >&2
    exit 1
  fi
  SMOKE_READY_SECONDS="$(( $(date +%s) - SMOKE_STARTED_AT ))"

  SMOKE_SCHEMA_VERSION="$(sqlite3 "$SMOKE_DATABASE" 'PRAGMA user_version;')"
  SMOKE_QUICK_CHECK="$(sqlite3 "$SMOKE_DATABASE" 'PRAGMA quick_check;')"
  SMOKE_FOREIGN_KEY_ERRORS="$(sqlite3 "$SMOKE_DATABASE" \
    'SELECT COUNT(*) FROM pragma_foreign_key_check;')"
  SMOKE_TABLES="$(sqlite3 "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name);")"
  SMOKE_COLUMNS="$(sqlite3 "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM pragma_table_info('assignments') ORDER BY name);")"
  SMOKE_INDEXES="$(sqlite3 "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name);")"
  SMOKE_TRIGGERS="$(sqlite3 "$SMOKE_DATABASE" \
    "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name);")"
  SMOKE_IDENTITY_ROWS="$(sqlite3 "$SMOKE_DATABASE" \
    "SELECT COUNT(*) FROM database_identity WHERE singleton = 1 AND length(instance_uuid) = 36 AND instance_uuid = lower(instance_uuid) AND substr(instance_uuid, 9, 1) = '-' AND substr(instance_uuid, 14, 1) = '-' AND substr(instance_uuid, 15, 1) = '4' AND substr(instance_uuid, 19, 1) = '-' AND substr(instance_uuid, 20, 1) IN ('8', '9', 'a', 'b') AND substr(instance_uuid, 24, 1) = '-' AND replace(instance_uuid, '-', '') NOT GLOB '*[^0-9a-f]*';")"
  EXPECTED_V4_TABLES="assignments,attachments,course_meetings,courses,database_identity,exams,projects,reminders,subtasks,tags,task_tags"
  EXPECTED_ASSIGNMENT_COLUMNS="all_day,completed_at,course_id,course_name,created_at,deleted_at,description,due_date,id,link,priority,progress_percent,project_id,source_file,source_name,source_type,source_url,status,timezone_id,title,updated_at,uuid"
  EXPECTED_V4_INDEXES="ix_assignments_course_id,ix_assignments_deleted_at,ix_assignments_due_date,ix_assignments_priority,ix_assignments_project_id,ix_assignments_status,ix_attachments_assignment,ix_attachments_sha256,ix_course_meetings_deleted_at,ix_course_meetings_week,ix_courses_archived_name,ix_courses_normalized_name,ix_exams_course_start,ix_exams_deleted_at,ix_exams_status_start,ix_projects_course_status,ix_projects_deleted_at,ix_reminders_assignment,ix_reminders_enabled_trigger,ix_subtasks_assignment_order,ix_subtasks_status,ix_tags_deleted_at,ix_task_tags_assignment,ix_task_tags_tag,ux_assignments_uuid,ux_attachments_relative_path,ux_attachments_uuid,ux_course_meetings_uuid,ux_courses_uuid,ux_exams_linked_assignment,ux_exams_uuid,ux_projects_uuid,ux_reminders_uuid,ux_subtasks_uuid,ux_tags_normalized_name,ux_tags_uuid,ux_task_tags_active_pair,ux_task_tags_uuid"
  EXPECTED_V4_TRIGGERS="assignments_uuid_immutable,assignments_v3_contract_insert,assignments_v3_contract_update,attachments_uuid_immutable,course_meetings_uuid_immutable,courses_uuid_immutable,database_identity_immutable_delete,database_identity_immutable_update,exams_uuid_immutable,projects_uuid_immutable,reminders_uuid_immutable,subtasks_uuid_immutable,tags_uuid_immutable,task_tags_uuid_immutable"
  if [[ "$SMOKE_SCHEMA_VERSION" != "4" || "$SMOKE_QUICK_CHECK" != "ok" || \
        "$SMOKE_FOREIGN_KEY_ERRORS" != "0" || "$SMOKE_IDENTITY_ROWS" != "1" || \
        "$SMOKE_TABLES" != "$EXPECTED_V4_TABLES" || \
        "$SMOKE_COLUMNS" != "$EXPECTED_ASSIGNMENT_COLUMNS" || \
        "$SMOKE_INDEXES" != "$EXPECTED_V4_INDEXES" || \
        "$SMOKE_TRIGGERS" != "$EXPECTED_V4_TRIGGERS" ]]; then
    echo "Packaged Catalyst database smoke validation failed." >&2
    exit 1
  fi
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "Packaged Catalyst app exited after database initialization." >&2
    exit 1
  fi
  {
    echo "runtime_database_path=$SMOKE_DATABASE"
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
  LAUNCH_SMOKE_RESULT="passed"
fi

{
  echo "Assignment App $VERSION Apple Debug package"
  echo "created_utc=$RUN_STAMP"
  echo "scheme=AssignmentApp2"
  echo "configuration=Debug"
  echo "destination=$DESTINATION"
  echo "architecture=$ASSIGNMENT_CATALYST_ARCH"
  echo "bundle_identifier=com.qianmuyan.assignmentapp"
  echo "version=$VERSION"
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
  echo "app_sandbox=true"
  echo "coverage_instrumentation=absent"
  echo "zip_appledouble=absent"
  echo
  xcodebuild -version
  xcrun swift --version
  echo
  shasum -a 256 "$OUTPUT_ZIP"
} > "$OUTPUT_DIR/build-info.txt"

echo "$OUTPUT_DIR"
