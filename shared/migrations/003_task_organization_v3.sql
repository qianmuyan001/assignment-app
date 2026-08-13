-- Assignment App schema v3 reference migration.
--
-- DO NOT execute this file directly against a user database. The executable
-- shared primitive is shared/schema_v3.py. A platform runner must:
--   1. create a unique, verified backup with SQLite Online Backup;
--   2. enable foreign keys and begin one IMMEDIATE transaction;
--   3. call migrate_v2_to_v3(connection);
--   4. validate identity, payload, schema, foreign keys and integrity;
--   5. commit, or roll back and restore the online backup on any failure.
--
-- assignments is upgraded only with additive ALTER statements. This preserves
-- v2's physical table, unknown extension columns, indexes, and triggers.
-- UUID is physically nullable because SQLite cannot add a non-null unique value
-- per existing row. It is backfilled before a unique index and triggers enforce
-- logical non-null for every later INSERT/UPDATE.

-- Production creates this UUID v4 inside the same migration transaction.
-- A database copy retains it; an independently created database gets another.
CREATE TABLE database_identity (
    singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
    instance_uuid TEXT NOT NULL CHECK (
        length(instance_uuid) = 36
        AND length(replace(instance_uuid, '-', '')) = 32
        AND instance_uuid = lower(instance_uuid)
        AND substr(instance_uuid, 9, 1) = '-'
        AND substr(instance_uuid, 14, 1) = '-'
        AND substr(instance_uuid, 15, 1) = '4'
        AND substr(instance_uuid, 19, 1) = '-'
        AND substr(instance_uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(instance_uuid, 24, 1) = '-'
        AND replace(instance_uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
-- INSERT INTO database_identity (singleton, instance_uuid) VALUES (1, :uuid_v4);

CREATE TABLE courses (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) IN ('4', '5')
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
    normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
    color_hex TEXT CHECK (
        color_hex IS NULL OR
        (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
         AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
    ),
    teacher TEXT,
    semester TEXT,
    is_archived INTEGER NOT NULL DEFAULT 0 CHECK (is_archived IN (0, 1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

CREATE TABLE projects (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
    name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 255),
    description TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'on_hold', 'completed', 'archived')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

CREATE TABLE tags (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
    normalized_name TEXT NOT NULL CHECK (length(normalized_name) >= 1),
    color_hex TEXT CHECK (
        color_hex IS NULL OR
        (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
         AND substr(color_hex, 2) NOT GLOB '*[^0-9A-Fa-f]*')
    ),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

ALTER TABLE assignments ADD COLUMN uuid TEXT;
ALTER TABLE assignments ADD COLUMN course_id INTEGER
    REFERENCES courses(id) ON DELETE SET NULL;
ALTER TABLE assignments ADD COLUMN project_id INTEGER
    REFERENCES projects(id) ON DELETE SET NULL;
ALTER TABLE assignments ADD COLUMN completed_at TEXT;
ALTER TABLE assignments ADD COLUMN progress_percent INTEGER NOT NULL DEFAULT 0
    CHECK (progress_percent BETWEEN 0 AND 100);
ALTER TABLE assignments ADD COLUMN all_day INTEGER NOT NULL DEFAULT 0
    CHECK (all_day IN (0, 1));
ALTER TABLE assignments ADD COLUMN timezone_id TEXT;
ALTER TABLE assignments ADD COLUMN deleted_at TEXT;

-- Platform-neutral code inserts one course for each byte-for-byte distinct,
-- nonblank v2 course_name. It uses the exact stored name in UUID v5 input.
-- Every v2 assignment is then backfilled as follows without changing a v2
-- column. These tokens are descriptive; they are not runnable SQL parameters:
--   uuid             = UUIDv5(database_identity.instance_uuid,
--                             'task:' + decimal(id))
--   course_id        = the exact-name course match
--   project_id       = NULL
--   completed_at     = updated_at when status='completed', otherwise NULL
--   progress_percent = 100 when status='completed', otherwise 0
--   all_day          = 0
--   timezone_id      = NULL
--   deleted_at       = NULL

CREATE TABLE task_tags (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

CREATE TABLE subtasks (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 255),
    status TEXT NOT NULL DEFAULT 'not_started'
        CHECK (status IN ('not_started', 'in_progress', 'completed')),
    sort_order INTEGER NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT,
    CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR (status != 'completed' AND completed_at IS NULL)
    )
);

CREATE TABLE attachments (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    file_name TEXT NOT NULL CHECK (
        length(file_name) BETWEEN 1 AND 255
        AND file_name NOT IN ('.', '..')
        AND instr(file_name, char(0)) = 0
        AND instr(file_name, '/') = 0
        AND instr(file_name, char(92)) = 0
    ),
    relative_path TEXT NOT NULL CHECK (
        relative_path = 'attachments/' || uuid
        AND instr(relative_path, char(0)) = 0
        AND instr(relative_path, '//') = 0
        AND instr(relative_path, char(92)) = 0
        AND instr(relative_path, ':') = 0
        AND ('/' || relative_path || '/') NOT LIKE '%/./%'
        AND ('/' || relative_path || '/') NOT LIKE '%/../%'
    ),
    mime_type TEXT,
    byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
    sha256 TEXT NOT NULL CHECK (
        length(sha256) = 64 AND sha256 = lower(sha256)
        AND sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

CREATE TABLE reminders (
    id INTEGER NOT NULL PRIMARY KEY,
    uuid TEXT NOT NULL CHECK (
        length(uuid) = 36 AND length(replace(uuid, '-', '')) = 32
        AND uuid = lower(uuid)
        AND substr(uuid, 9, 1) = '-' AND substr(uuid, 14, 1) = '-'
        AND substr(uuid, 15, 1) = '4'
        AND substr(uuid, 19, 1) = '-'
        AND substr(uuid, 20, 1) IN ('8', '9', 'a', 'b')
        AND substr(uuid, 24, 1) = '-'
        AND replace(uuid, '-', '') NOT GLOB '*[^0-9a-f]*'
    ),
    assignment_id INTEGER NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    trigger_at_utc TEXT NOT NULL,
    lead_minutes INTEGER NOT NULL DEFAULT 0 CHECK (lead_minutes >= 0),
    repeat_rule TEXT,
    is_enabled INTEGER NOT NULL DEFAULT 1 CHECK (is_enabled IN (0, 1)),
    last_scheduled_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    deleted_at TEXT
);

CREATE UNIQUE INDEX ux_assignments_uuid ON assignments(uuid);
CREATE INDEX ix_assignments_course_id ON assignments(course_id);
CREATE INDEX ix_assignments_project_id ON assignments(project_id);
-- These names may exist in v2. The executable runner verifies owner, ordered
-- columns, uniqueness and partial predicate before reusing a named index;
-- IF NOT EXISTS alone is not a sufficient migration check.
CREATE INDEX IF NOT EXISTS ix_assignments_due_date ON assignments(due_date);
CREATE INDEX IF NOT EXISTS ix_assignments_status ON assignments(status);
CREATE INDEX IF NOT EXISTS ix_assignments_priority ON assignments(priority);
CREATE INDEX ix_assignments_deleted_at ON assignments(deleted_at);
CREATE UNIQUE INDEX ux_courses_uuid ON courses(uuid);
CREATE INDEX ix_courses_normalized_name ON courses(normalized_name);
CREATE INDEX ix_courses_archived_name ON courses(is_archived, name);
CREATE UNIQUE INDEX ux_projects_uuid ON projects(uuid);
CREATE INDEX ix_projects_course_status ON projects(course_id, status);
CREATE INDEX ix_projects_deleted_at ON projects(deleted_at);
CREATE UNIQUE INDEX ux_tags_uuid ON tags(uuid);
CREATE UNIQUE INDEX ux_tags_normalized_name ON tags(normalized_name);
CREATE INDEX ix_tags_deleted_at ON tags(deleted_at);
CREATE UNIQUE INDEX ux_task_tags_uuid ON task_tags(uuid);
CREATE UNIQUE INDEX ux_task_tags_active_pair
    ON task_tags(assignment_id, tag_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_task_tags_assignment ON task_tags(assignment_id);
CREATE INDEX ix_task_tags_tag ON task_tags(tag_id);
CREATE UNIQUE INDEX ux_subtasks_uuid ON subtasks(uuid);
CREATE INDEX ix_subtasks_assignment_order
    ON subtasks(assignment_id, sort_order, id);
CREATE INDEX ix_subtasks_status ON subtasks(status);
CREATE UNIQUE INDEX ux_attachments_uuid ON attachments(uuid);
CREATE UNIQUE INDEX ux_attachments_relative_path
    ON attachments(relative_path);
CREATE INDEX ix_attachments_assignment ON attachments(assignment_id);
CREATE INDEX ix_attachments_sha256 ON attachments(sha256);
CREATE UNIQUE INDEX ux_reminders_uuid ON reminders(uuid);
CREATE INDEX ix_reminders_assignment ON reminders(assignment_id);
CREATE INDEX ix_reminders_enabled_trigger
    ON reminders(is_enabled, trigger_at_utc);

CREATE TRIGGER assignments_v3_contract_insert
BEFORE INSERT ON assignments
WHEN NEW.uuid IS NULL
  OR length(NEW.uuid) != 36
  OR length(replace(NEW.uuid, '-', '')) != 32
  OR NEW.uuid != lower(NEW.uuid)
  OR substr(NEW.uuid, 9, 1) != '-'
  OR substr(NEW.uuid, 14, 1) != '-'
  OR substr(NEW.uuid, 15, 1) NOT IN ('4', '5')
  OR substr(NEW.uuid, 19, 1) != '-'
  OR substr(NEW.uuid, 20, 1) NOT IN ('8', '9', 'a', 'b')
  OR substr(NEW.uuid, 24, 1) != '-'
  OR replace(NEW.uuid, '-', '') GLOB '*[^0-9a-f]*'
  OR NEW.status IS NULL
  OR NEW.priority IS NULL
  OR NEW.status NOT IN ('not_started', 'in_progress', 'completed')
  OR NEW.priority NOT IN ('low', 'medium', 'high')
  OR NEW.progress_percent NOT BETWEEN 0 AND 100
  OR NEW.all_day NOT IN (0, 1)
  OR (NEW.all_day = 1 AND NEW.due_date IS NULL)
  OR (NEW.status = 'completed'
      AND (NEW.progress_percent != 100 OR NEW.completed_at IS NULL))
  OR (NEW.status != 'completed'
      AND (NEW.progress_percent = 100 OR NEW.completed_at IS NOT NULL))
BEGIN
    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
END;

CREATE TRIGGER assignments_v3_contract_update
BEFORE UPDATE ON assignments
WHEN NEW.uuid IS NULL
  OR length(NEW.uuid) != 36
  OR length(replace(NEW.uuid, '-', '')) != 32
  OR NEW.uuid != lower(NEW.uuid)
  OR substr(NEW.uuid, 9, 1) != '-'
  OR substr(NEW.uuid, 14, 1) != '-'
  OR substr(NEW.uuid, 15, 1) NOT IN ('4', '5')
  OR substr(NEW.uuid, 19, 1) != '-'
  OR substr(NEW.uuid, 20, 1) NOT IN ('8', '9', 'a', 'b')
  OR substr(NEW.uuid, 24, 1) != '-'
  OR replace(NEW.uuid, '-', '') GLOB '*[^0-9a-f]*'
  OR NEW.status IS NULL
  OR NEW.priority IS NULL
  OR NEW.status NOT IN ('not_started', 'in_progress', 'completed')
  OR NEW.priority NOT IN ('low', 'medium', 'high')
  OR NEW.progress_percent NOT BETWEEN 0 AND 100
  OR NEW.all_day NOT IN (0, 1)
  OR (NEW.all_day = 1 AND NEW.due_date IS NULL)
  OR (NEW.status = 'completed'
      AND (NEW.progress_percent != 100 OR NEW.completed_at IS NULL))
  OR (NEW.status != 'completed'
      AND (NEW.progress_percent = 100 OR NEW.completed_at IS NOT NULL))
BEGIN
    SELECT RAISE(ABORT, 'assignment violates schema v3 contract');
END;

CREATE TRIGGER database_identity_immutable_update
BEFORE UPDATE ON database_identity
BEGIN
    SELECT RAISE(ABORT, 'database identity is immutable');
END;

CREATE TRIGGER database_identity_immutable_delete
BEFORE DELETE ON database_identity
BEGIN
    SELECT RAISE(ABORT, 'database identity is immutable');
END;

CREATE TRIGGER assignments_uuid_immutable
BEFORE UPDATE OF uuid ON assignments
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'assignments UUID is immutable');
END;

CREATE TRIGGER courses_uuid_immutable
BEFORE UPDATE OF uuid ON courses
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'courses UUID is immutable');
END;

CREATE TRIGGER projects_uuid_immutable
BEFORE UPDATE OF uuid ON projects
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'projects UUID is immutable');
END;

CREATE TRIGGER tags_uuid_immutable
BEFORE UPDATE OF uuid ON tags
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'tags UUID is immutable');
END;

CREATE TRIGGER task_tags_uuid_immutable
BEFORE UPDATE OF uuid ON task_tags
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'task_tags UUID is immutable');
END;

CREATE TRIGGER subtasks_uuid_immutable
BEFORE UPDATE OF uuid ON subtasks
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'subtasks UUID is immutable');
END;

CREATE TRIGGER attachments_uuid_immutable
BEFORE UPDATE OF uuid ON attachments
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'attachments UUID is immutable');
END;

CREATE TRIGGER reminders_uuid_immutable
BEFORE UPDATE OF uuid ON reminders
WHEN NEW.uuid IS NOT OLD.uuid
BEGIN
    SELECT RAISE(ABORT, 'reminders UUID is immutable');
END;

PRAGMA user_version = 3;
