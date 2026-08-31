import Foundation
import SQLite3


/// Phase 3A learning scenes on top of the existing organization repository.
///
/// Meetings, exams, and the reminder schedule kind reuse `courses`,
/// `assignments`, and `reminders`. This extension deliberately adds no second
/// course, task, or notification model: it only reads and writes the v4
/// additions through the organization repository's single connection, so every
/// write joins the same transaction discipline as the rest of the app.
extension SQLiteOrganizationRepository: LearningSceneRepository {
    // MARK: - Course meetings

    func fetchMeetings(courseID: Int64?, includeDeleted: Bool = false) throws -> [CourseMeeting] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, course_id, weekday, start_time_local, end_time_local,
                       location, teacher_override, timezone_id, effective_start_date,
                       effective_end_date, sort_order, created_at, updated_at, deleted_at
                FROM course_meetings
                \(Self.scopePredicate(courseID: courseID, includeDeleted: includeDeleted))
                ORDER BY weekday, start_time_local, sort_order, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            try Self.bindCourseScope(courseID, to: statement, index: 1)
            return try Self.collect(statement, on: database, mapper: Self.meeting)
        }
    }

    func fetchMeetings(weekday: Int, includeDeleted: Bool = false) throws -> [CourseMeeting] {
        guard (1...7).contains(weekday) else {
            throw LearningSceneError.meetingWeekdayOutOfRange(weekday)
        }
        return try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, course_id, weekday, start_time_local, end_time_local,
                       location, teacher_override, timezone_id, effective_start_date,
                       effective_end_date, sort_order, created_at, updated_at, deleted_at
                FROM course_meetings
                WHERE weekday = ? \(includeDeleted ? "" : "AND deleted_at IS NULL")
                ORDER BY start_time_local, sort_order, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(weekday))
            return try Self.collect(statement, on: database, mapper: Self.meeting)
        }
    }

    func createMeeting(_ draft: CourseMeetingDraft) throws -> CourseMeeting {
        let values = try Self.validatedMeetingDraft(draft)
        return try withWrite { database in
            try Self.requireActiveCourse(values.courseID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO course_meetings (
                    uuid, course_id, weekday, start_time_local, end_time_local,
                    location, teacher_override, timezone_id, effective_start_date,
                    effective_end_date, sort_order, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, values.courseID)
            sqlite3_bind_int64(statement, 3, Int64(values.weekday))
            SQLiteSupport.bind(values.startTimeLocal, to: statement, index: 4)
            SQLiteSupport.bind(values.endTimeLocal, to: statement, index: 5)
            SQLiteSupport.bind(values.location, to: statement, index: 6)
            SQLiteSupport.bind(values.teacherOverride, to: statement, index: 7)
            SQLiteSupport.bind(values.timezoneID, to: statement, index: 8)
            SQLiteSupport.bind(values.effectiveStartDate, to: statement, index: 9)
            SQLiteSupport.bind(values.effectiveEndDate, to: statement, index: 10)
            sqlite3_bind_int64(statement, 11, Int64(values.sortOrder))
            SQLiteSupport.bind(timestamp, to: statement, index: 12)
            SQLiteSupport.bind(timestamp, to: statement, index: 13)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchMeeting(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateMeeting(_ meeting: CourseMeeting) throws -> CourseMeeting {
        let values = try Self.validatedMeetingDraft(.init(
            courseID: meeting.courseID,
            weekday: meeting.weekday,
            startTimeLocal: meeting.startTimeLocal,
            endTimeLocal: meeting.endTimeLocal,
            location: meeting.location,
            teacherOverride: meeting.teacherOverride,
            timezoneID: meeting.timezoneID,
            effectiveStartDate: meeting.effectiveStartDate,
            effectiveEndDate: meeting.effectiveEndDate,
            sortOrder: meeting.sortOrder
        ))
        return try withWrite { database in
            let stored = try Self.fetchMeeting(id: meeting.id, on: database)
            guard stored.uuid == meeting.uuid, stored.courseID == values.courseID else {
                throw OrganizationRepositoryError.validation(
                    "A course meeting's UUID and course cannot be changed."
                )
            }
            try Self.requireActiveCourse(values.courseID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE course_meetings
                SET weekday = ?, start_time_local = ?, end_time_local = ?, location = ?,
                    teacher_override = ?, timezone_id = ?, effective_start_date = ?,
                    effective_end_date = ?, sort_order = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(values.weekday))
            SQLiteSupport.bind(values.startTimeLocal, to: statement, index: 2)
            SQLiteSupport.bind(values.endTimeLocal, to: statement, index: 3)
            SQLiteSupport.bind(values.location, to: statement, index: 4)
            SQLiteSupport.bind(values.teacherOverride, to: statement, index: 5)
            SQLiteSupport.bind(values.timezoneID, to: statement, index: 6)
            SQLiteSupport.bind(values.effectiveStartDate, to: statement, index: 7)
            SQLiteSupport.bind(values.effectiveEndDate, to: statement, index: 8)
            sqlite3_bind_int64(statement, 9, Int64(values.sortOrder))
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 10)
            sqlite3_bind_int64(statement, 11, meeting.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Course meeting", meeting.id)
            }
            return try Self.fetchMeeting(id: meeting.id, on: database)
        }
    }

    func deleteMeeting(id: Int64) throws {
        try softDelete(table: "course_meetings", entity: "Course meeting", id: id)
    }

    func restoreMeeting(id: Int64) throws -> CourseMeeting {
        return try withWrite { database in
            try Self.restoreRow(
                table: "course_meetings",
                entity: "Course meeting",
                id: id,
                on: database
            )
            return try Self.fetchMeeting(id: id, on: database)
        }
    }

    /// Colliding active meetings. This never mutates anything: an overlap is a
    /// warning the user decides about.
    func meetingsOverlapping(
        _ draft: CourseMeetingDraft,
        excludingID: Int64?
    ) throws -> [CourseMeeting] {
        let candidate = try MeetingWindow(
            weekday: draft.weekday,
            startTimeLocal: draft.startTimeLocal,
            endTimeLocal: draft.endTimeLocal,
            timezoneID: draft.timezoneID,
            effectiveStartDate: draft.effectiveStartDate,
            effectiveEndDate: draft.effectiveEndDate
        )
        return try fetchMeetings(courseID: nil, includeDeleted: false).filter { meeting in
            guard meeting.id != excludingID, let window = meeting.meetingWindow else {
                return false
            }
            return (try? LearningRules.meetingsOverlap(candidate, window)) == true
        }
    }

    // MARK: - Exams

    func fetchExams(courseID: Int64?, includeDeleted: Bool = false) throws -> [Exam] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, course_id, name, starts_at_local, timezone_id,
                       location, scope, notes, status, linked_assignment_id,
                       created_at, updated_at, deleted_at
                FROM exams
                \(Self.scopePredicate(courseID: courseID, includeDeleted: includeDeleted))
                ORDER BY starts_at_local, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            try Self.bindCourseScope(courseID, to: statement, index: 1)
            return try Self.collect(statement, on: database, mapper: Self.exam)
        }
    }

    func createExam(_ draft: ExamDraft) throws -> Exam {
        let values = try Self.validatedExamDraft(draft)
        return try withWrite { database in
            try Self.requireActiveCourse(values.courseID, on: database)
            let statement = try SQLiteSupport.prepare(
                """
                INSERT INTO exams (
                    uuid, course_id, name, starts_at_local, timezone_id, location,
                    scope, notes, status, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            let timestamp = DatabaseTimestamp.string(from: Date())
            SQLiteSupport.bind(UUID().canonicalString, to: statement, index: 1)
            sqlite3_bind_int64(statement, 2, values.courseID)
            SQLiteSupport.bind(values.name, to: statement, index: 3)
            SQLiteSupport.bind(values.startsAtLocal, to: statement, index: 4)
            SQLiteSupport.bind(values.timezoneID, to: statement, index: 5)
            SQLiteSupport.bind(values.location, to: statement, index: 6)
            SQLiteSupport.bind(values.scope, to: statement, index: 7)
            SQLiteSupport.bind(values.notes, to: statement, index: 8)
            SQLiteSupport.bind(values.status.rawValue, to: statement, index: 9)
            SQLiteSupport.bind(timestamp, to: statement, index: 10)
            SQLiteSupport.bind(timestamp, to: statement, index: 11)
            try SQLiteSupport.checkDone(statement, on: database)
            return try Self.fetchExam(id: sqlite3_last_insert_rowid(database), on: database)
        }
    }

    func updateExam(_ exam: Exam) throws -> Exam {
        let values = try Self.validatedExamDraft(.init(
            courseID: exam.courseID,
            name: exam.name,
            startsAtLocal: exam.startsAtLocal,
            timezoneID: exam.timezoneID,
            location: exam.location,
            scope: exam.scope,
            notes: exam.notes,
            status: exam.status
        ))
        return try withWrite { database in
            let stored = try Self.fetchExam(id: exam.id, on: database)
            guard stored.uuid == exam.uuid, stored.courseID == values.courseID else {
                throw OrganizationRepositoryError.validation(
                    "An exam's UUID and course cannot be changed."
                )
            }
            try Self.requireActiveCourse(values.courseID, on: database)
            guard stored.linkedAssignmentID == exam.linkedAssignmentID else {
                throw OrganizationRepositoryError.validation(
                    "Link or unlink an exam's review task through the exam action instead."
                )
            }
            let statement = try SQLiteSupport.prepare(
                """
                UPDATE exams
                SET name = ?, starts_at_local = ?, timezone_id = ?, location = ?,
                    scope = ?, notes = ?, status = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            SQLiteSupport.bind(values.name, to: statement, index: 1)
            SQLiteSupport.bind(values.startsAtLocal, to: statement, index: 2)
            SQLiteSupport.bind(values.timezoneID, to: statement, index: 3)
            SQLiteSupport.bind(values.location, to: statement, index: 4)
            SQLiteSupport.bind(values.scope, to: statement, index: 5)
            SQLiteSupport.bind(values.notes, to: statement, index: 6)
            SQLiteSupport.bind(values.status.rawValue, to: statement, index: 7)
            SQLiteSupport.bind(DatabaseTimestamp.string(from: Date()), to: statement, index: 8)
            sqlite3_bind_int64(statement, 9, exam.id)
            try SQLiteSupport.checkDone(statement, on: database)
            guard sqlite3_changes(database) == 1 else {
                throw OrganizationRepositoryError.notFound("Exam", exam.id)
            }
            return try Self.fetchExam(id: exam.id, on: database)
        }
    }

    func deleteExam(id: Int64) throws {
        // Only the exam row is soft-deleted. Its review task is a normal task
        // the user owns, so it is never removed as a side effect.
        try softDelete(table: "exams", entity: "Exam", id: id)
    }

    func restoreExam(id: Int64) throws -> Exam {
        try withWrite { database in
            try Self.restoreRow(table: "exams", entity: "Exam", id: id, on: database)
            return try Self.fetchExam(id: id, on: database)
        }
    }

    // MARK: - Reminders

    func fetchReminders(includeDeleted: Bool = false) throws -> [TaskReminder] {
        try lock.withLock {
            let database = try requireDatabase()
            let statement = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes,
                       repeat_rule, is_enabled, last_scheduled_at,
                       created_at, updated_at, deleted_at, schedule_kind
                FROM reminders
                \(includeDeleted ? "" : "WHERE deleted_at IS NULL")
                ORDER BY assignment_id, trigger_at_utc, id
                """,
                on: database
            )
            defer { sqlite3_finalize(statement) }
            return try Self.collect(statement, on: database, mapper: Self.reminder)
        }
    }

    /// Recomputes every due-relative reminder from the deadlines stored today.
    ///
    /// Fixed reminders are never touched. A due-relative reminder whose task has
    /// lost its deadline, or whose task has been deleted, is disabled rather
    /// than deleted so the reason stays visible in the UI.
    @discardableResult
    func rescheduleRelativeReminders() throws -> [TaskReminder] {
        try withWrite { database in
            let scan = try SQLiteSupport.prepare(
                """
                SELECT reminders.id, reminders.lead_minutes, assignments.due_date,
                       assignments.timezone_id, assignments.deleted_at
                FROM reminders
                LEFT JOIN assignments ON assignments.id = reminders.assignment_id
                WHERE reminders.schedule_kind = 'due_relative'
                  AND reminders.deleted_at IS NULL
                ORDER BY reminders.id
                """,
                on: database
            )
            defer { sqlite3_finalize(scan) }

            var recalculated: [(id: Int64, trigger: Date)] = []
            var disabled: [Int64] = []
            var result = sqlite3_step(scan)
            while result == SQLITE_ROW {
                let id = sqlite3_column_int64(scan, 0)
                let leadMinutes = Int(sqlite3_column_int64(scan, 1))
                let dueText = SQLiteSupport.text(scan, 2)
                let taskDeleted = SQLiteSupport.text(scan, 4) != nil
                if !taskDeleted, let dueText {
                    var timeZone = TimeZone.current
                    if let identifier = SQLiteSupport.text(scan, 3),
                       let resolved = TimeZone(identifier: identifier) {
                        timeZone = resolved
                    }
                    if let due = try? LocalWallTime.legacyDate(from: dueText, timeZone: timeZone),
                       let trigger = try? LearningRules.relativeReminderTrigger(
                           dueAtUTC: due,
                           leadMinutes: leadMinutes
                       ) {
                        recalculated.append((id, trigger))
                    } else {
                        disabled.append(id)
                    }
                } else {
                    disabled.append(id)
                }
                result = sqlite3_step(scan)
            }
            guard result == SQLITE_DONE else {
                throw AssignmentRepositoryError.execute(
                    String(cString: sqlite3_errmsg(database))
                )
            }

            let timestamp = DatabaseTimestamp.string(from: Date())
            if !recalculated.isEmpty {
                let update = try SQLiteSupport.prepare(
                    """
                    UPDATE reminders SET trigger_at_utc = ?, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    on: database
                )
                defer { sqlite3_finalize(update) }
                for entry in recalculated {
                    SQLiteSupport.bind(
                        DatabaseTimestamp.string(from: entry.trigger),
                        to: update,
                        index: 1
                    )
                    SQLiteSupport.bind(timestamp, to: update, index: 2)
                    sqlite3_bind_int64(update, 3, entry.id)
                    try SQLiteSupport.checkDone(update, on: database)
                    sqlite3_reset(update)
                }
            }
            if !disabled.isEmpty {
                let disable = try SQLiteSupport.prepare(
                    """
                    UPDATE reminders SET is_enabled = 0, updated_at = ?
                    WHERE id = ? AND deleted_at IS NULL
                    """,
                    on: database
                )
                defer { sqlite3_finalize(disable) }
                for id in disabled {
                    SQLiteSupport.bind(timestamp, to: disable, index: 1)
                    sqlite3_bind_int64(disable, 2, id)
                    try SQLiteSupport.checkDone(disable, on: database)
                    sqlite3_reset(disable)
                }
            }

            let reread = try SQLiteSupport.prepare(
                """
                SELECT id, uuid, assignment_id, trigger_at_utc, lead_minutes,
                       repeat_rule, is_enabled, last_scheduled_at,
                       created_at, updated_at, deleted_at, schedule_kind
                FROM reminders
                WHERE schedule_kind = 'due_relative' AND deleted_at IS NULL
                ORDER BY assignment_id, trigger_at_utc, id
                """,
                on: database
            )
            defer { sqlite3_finalize(reread) }
            return try Self.collect(reread, on: database, mapper: Self.reminder)
        }
    }
}


// MARK: - Row mapping and single-row queries

extension SQLiteOrganizationRepository {
    static func meeting(_ statement: OpaquePointer) throws -> CourseMeeting {
        guard let weekday = Int(exactly: sqlite3_column_int64(statement, 3)),
              let startTime = SQLiteSupport.text(statement, 4),
              let endTime = SQLiteSupport.text(statement, 5),
              let timezoneID = SQLiteSupport.text(statement, 8),
              let startDate = SQLiteSupport.text(statement, 9),
              let sortOrder = Int(exactly: sqlite3_column_int64(statement, 11)) else {
            throw OrganizationRepositoryError.corruptData(
                "Course meeting has missing required fields."
            )
        }
        return CourseMeeting(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            courseID: sqlite3_column_int64(statement, 2),
            weekday: weekday,
            startTimeLocal: startTime,
            endTimeLocal: endTime,
            location: SQLiteSupport.text(statement, 6),
            teacherOverride: SQLiteSupport.text(statement, 7),
            timezoneID: timezoneID,
            effectiveStartDate: startDate,
            effectiveEndDate: SQLiteSupport.text(statement, 10),
            sortOrder: sortOrder,
            createdAt: try parsedDate(statement, 12),
            updatedAt: try parsedDate(statement, 13),
            deletedAt: try optionalDate(statement, 14)
        )
    }

    static func exam(_ statement: OpaquePointer) throws -> Exam {
        guard let name = SQLiteSupport.text(statement, 3),
              let startsAt = SQLiteSupport.text(statement, 4),
              let timezoneID = SQLiteSupport.text(statement, 5),
              let statusText = SQLiteSupport.text(statement, 9),
              let status = ExamStatus(rawValue: statusText) else {
            throw OrganizationRepositoryError.corruptData(
                "Exam has missing required fields."
            )
        }
        return Exam(
            id: sqlite3_column_int64(statement, 0),
            uuid: try parsedUUID(statement, 1),
            courseID: sqlite3_column_int64(statement, 2),
            name: name,
            startsAtLocal: startsAt,
            timezoneID: timezoneID,
            location: SQLiteSupport.text(statement, 6),
            scope: SQLiteSupport.text(statement, 7),
            notes: SQLiteSupport.text(statement, 8),
            status: status,
            linkedAssignmentID: SQLiteSupport.int64(statement, 10),
            createdAt: try parsedDate(statement, 11),
            updatedAt: try parsedDate(statement, 12),
            deletedAt: try optionalDate(statement, 13)
        )
    }

    static func fetchMeeting(id: Int64, on database: OpaquePointer) throws -> CourseMeeting {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, course_id, weekday, start_time_local, end_time_local,
                   location, teacher_override, timezone_id, effective_start_date,
                   effective_end_date, sort_order, created_at, updated_at, deleted_at
            FROM course_meetings WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Course meeting", id)
        }
        return try meeting(statement)
    }

    static func fetchExam(id: Int64, on database: OpaquePointer) throws -> Exam {
        let statement = try SQLiteSupport.prepare(
            """
            SELECT id, uuid, course_id, name, starts_at_local, timezone_id,
                   location, scope, notes, status, linked_assignment_id,
                   created_at, updated_at, deleted_at
            FROM exams WHERE id = ? AND deleted_at IS NULL
            """,
            on: database
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw OrganizationRepositoryError.notFound("Exam", id)
        }
        return try exam(statement)
    }

    static func requireActiveCourse(_ id: Int64, on database: OpaquePointer) throws {
        guard try activeRowExists(table: "courses", id: id, on: database) else {
            throw OrganizationRepositoryError.validation(
                "Meetings and exams require an active course."
            )
        }
    }

    /// Builds the shared `WHERE`/`ORDER BY` prefix for course-scoped reads.
    /// Returns an empty string when there is no predicate, so callers can
    /// always interpolate it safely.
    private static func scopePredicate(courseID: Int64?, includeDeleted: Bool) -> String {
        var clauses: [String] = []
        if courseID != nil { clauses.append("course_id = ?") }
        if !includeDeleted { clauses.append("deleted_at IS NULL") }
        guard !clauses.isEmpty else { return "" }
        return "WHERE " + clauses.joined(separator: " AND ")
    }

    private static func bindCourseScope(_ courseID: Int64?, to statement: OpaquePointer, index: Int32) throws {
        guard let courseID else { return }
        sqlite3_bind_int64(statement, index, courseID)
    }
}


// MARK: - Draft validation

extension SQLiteOrganizationRepository {
    static func validatedMeetingDraft(_ draft: CourseMeetingDraft) throws -> CourseMeetingDraft {
        var value = draft
        value.startTimeLocal = draft.startTimeLocal.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        value.endTimeLocal = draft.endTimeLocal.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        value.location = normalizedOptional(draft.location)
        value.teacherOverride = normalizedOptional(draft.teacherOverride)
        value.timezoneID = draft.timezoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.effectiveStartDate = draft.effectiveStartDate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        value.effectiveEndDate = normalizedOptional(draft.effectiveEndDate)
        guard value.courseID > 0, value.sortOrder >= 0 else {
            throw OrganizationRepositoryError.validation(
                "Course meeting course and sort order are invalid."
            )
        }
        guard value.location == nil || value.location!.count <= 255,
              value.teacherOverride == nil || value.teacherOverride!.count <= 255 else {
            throw OrganizationRepositoryError.validation(
                "Course meeting location and teacher must be 255 characters or fewer."
            )
        }
        // The shared window rules own weekday, clock, zone, and date validity.
        _ = try MeetingWindow(
            weekday: value.weekday,
            startTimeLocal: value.startTimeLocal,
            endTimeLocal: value.endTimeLocal,
            timezoneID: value.timezoneID,
            effectiveStartDate: value.effectiveStartDate,
            effectiveEndDate: value.effectiveEndDate
        )
        return value
    }

    static func validatedExamDraft(_ draft: ExamDraft) throws -> ExamDraft {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.startsAtLocal = draft.startsAtLocal.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        value.timezoneID = draft.timezoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.location = normalizedOptional(draft.location)
        value.scope = normalizedOptional(draft.scope)
        value.notes = normalizedOptional(draft.notes)
        guard value.courseID > 0 else {
            throw OrganizationRepositoryError.validation("An exam requires a course.")
        }
        guard !value.name.isEmpty, value.name.count <= 255 else {
            throw OrganizationRepositoryError.validation(
                "Exam name must contain 1 to 255 characters."
            )
        }
        guard value.location == nil || value.location!.count <= 255,
              value.scope == nil || value.scope!.count <= 1_000,
              value.notes == nil || value.notes!.count <= 4_000 else {
            throw OrganizationRepositoryError.validation(
                "Exam location, scope, or notes are too long."
            )
        }
        _ = try LearningRules.validatedTimeZone(value.timezoneID)
        _ = try LocalWallDateTime(value.startsAtLocal)
        return value
    }
}
