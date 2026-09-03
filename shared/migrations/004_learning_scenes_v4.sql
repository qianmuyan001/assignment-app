-- Reference-only v3 -> v4 additive migration. Platform code owns backup,
-- transaction, validation, rollback, and fail-closed recovery.
ALTER TABLE reminders ADD COLUMN schedule_kind TEXT NOT NULL DEFAULT 'fixed'
    CHECK(schedule_kind IN ('fixed','due_relative'));

CREATE TABLE course_meetings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL,
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
    weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7),
    start_time_local TEXT NOT NULL,
    end_time_local TEXT NOT NULL CHECK(start_time_local < end_time_local),
    location TEXT, teacher_override TEXT, timezone_id TEXT NOT NULL,
    effective_start_date TEXT NOT NULL,
    effective_end_date TEXT CHECK(effective_end_date IS NULL OR effective_end_date >= effective_start_date),
    sort_order INTEGER NOT NULL DEFAULT 0 CHECK(sort_order >= 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at TEXT
);

CREATE TABLE exams (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid TEXT NOT NULL,
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE RESTRICT,
    name TEXT NOT NULL CHECK(length(trim(name)) > 0),
    starts_at_local TEXT NOT NULL, timezone_id TEXT NOT NULL,
    location TEXT, scope TEXT, notes TEXT,
    status TEXT NOT NULL DEFAULT 'upcoming' CHECK(status IN ('upcoming','completed','cancelled')),
    linked_assignment_id INTEGER REFERENCES assignments(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at TEXT
);

PRAGMA user_version = 4;
