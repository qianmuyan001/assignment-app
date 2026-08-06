-- Assignment App schema v2 reference DDL.
-- The executable migration is backend/app/database.py because it must use the
-- sqlite3 backup API, inspect v1 columns, and restore on failure. Do not run
-- this file directly against a user database.
--
-- v1 status -> canonical UI mapping:
-- not_started -> todo; in_progress -> in_progress; completed -> done.
-- Stored values remain the v1 values to avoid a risky constraint rewrite.
-- The current v1 table is upgraded additively with the equivalent of:
-- ALTER TABLE assignments ADD COLUMN priority VARCHAR(10) NOT NULL
--     DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high'));

CREATE TABLE assignments_v2_reference (
    id INTEGER NOT NULL PRIMARY KEY,
    course_name VARCHAR(120) NOT NULL,
    title VARCHAR(255) NOT NULL,
    due_date DATETIME,
    description TEXT,
    link VARCHAR(1000),
    status VARCHAR(20) NOT NULL DEFAULT 'not_started'
        CHECK (status IN ('not_started', 'in_progress', 'completed')),
    priority VARCHAR(10) NOT NULL DEFAULT 'medium'
        CHECK (priority IN ('low', 'medium', 'high')),
    source_name VARCHAR(255),
    source_type VARCHAR(80),
    source_file VARCHAR(1000),
    source_url VARCHAR(1000),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP NOT NULL
);

PRAGMA user_version = 2;
