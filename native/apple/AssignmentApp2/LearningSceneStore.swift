import Combine
import Foundation


// MARK: - Planning (pure, no database)

/// One row group in the exam list.
struct ExamSection: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case today
        case upcoming
        case completed
        case cancelled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "Today"
            case .upcoming: return "Upcoming"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            }
        }

        var systemImage: String {
            switch self {
            case .today: return "sun.max"
            case .upcoming: return "calendar.badge.clock"
            case .completed: return "checkmark.circle"
            case .cancelled: return "slash.circle"
            }
        }
    }

    let kind: Kind
    var exams: [Exam]

    var id: String { kind.rawValue }
}


/// What the Today page summarises.
///
/// It is deliberately small: today's classes, exams that are close, tasks due
/// today, and overdue tasks. Nothing here duplicates the task list; it only
/// points at it.
struct TodayOverview: Equatable {
    var meetings: [CourseMeeting] = []
    var exams: [Exam] = []
    var dueToday: [Assignment] = []
    var overdue: [Assignment] = []

    var isEmpty: Bool {
        meetings.isEmpty && exams.isEmpty && dueToday.isEmpty && overdue.isEmpty
    }
}


enum LearningScenePlanner {
    /// ISO weekday of an instant: 1 is Monday, 7 is Sunday.
    static func isoWeekday(of date: Date, calendar: Calendar = .current) -> Int {
        ((calendar.component(.weekday, from: date) + 5) % 7) + 1
    }

    static func activeMeetings(_ meetings: [CourseMeeting]) -> [CourseMeeting] {
        meetings.filter { $0.deletedAt == nil }
    }

    /// Meetings on one weekday, earliest start first.
    static func meetings(
        _ meetings: [CourseMeeting],
        on weekday: Int
    ) -> [CourseMeeting] {
        activeMeetings(meetings)
            .filter { $0.weekday == weekday }
            .sorted { lhs, rhs in
                if lhs.startTimeLocal != rhs.startTimeLocal {
                    return lhs.startTimeLocal < rhs.startTimeLocal
                }
                if lhs.endTimeLocal != rhs.endTimeLocal {
                    return lhs.endTimeLocal < rhs.endTimeLocal
                }
                return lhs.id < rhs.id
            }
    }

    /// Monday through Sunday, including the empty days.
    ///
    /// Empty days are kept so the week view can say "no classes" instead of
    /// silently dropping a column.
    static func week(
        _ meetings: [CourseMeeting]
    ) -> [(weekday: Int, meetings: [CourseMeeting])] {
        (1...7).map { weekday in
            (weekday, self.meetings(meetings, on: weekday))
        }
    }

    /// Every clashing pair among the active meetings.
    ///
    /// A warning only. The planner never merges, moves, or drops a meeting; the
    /// caller decides how to present the pairs.
    static func overlappingPairs(
        _ meetings: [CourseMeeting]
    ) -> [(CourseMeeting, CourseMeeting)] {
        let active = activeMeetings(meetings)
        var pairs: [(CourseMeeting, CourseMeeting)] = []
        for index in active.indices {
            guard index < active.endIndex else { break }
            for other in active.index(after: index)..<active.endIndex {
                guard let lhs = active[index].meetingWindow,
                      let rhs = active[other].meetingWindow,
                      (try? LearningRules.meetingsOverlap(lhs, rhs)) == true else {
                    continue
                }
                pairs.append((active[index], active[other]))
            }
        }
        return pairs
    }

    static func sortedExams(_ exams: [Exam]) -> [Exam] {
        exams.sorted { lhs, rhs in
            let lhsKey = LearningRules.examSortKey(
                status: lhs.status,
                startsAtUTC: lhs.startsAtUTC ?? .distantFuture
            )
            let rhsKey = LearningRules.examSortKey(
                status: rhs.status,
                startsAtUTC: rhs.startsAtUTC ?? .distantFuture
            )
            if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
            if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }
            return lhs.id < rhs.id
        }
    }

    /// Groups exams into the sections the list renders, skipping empty ones.
    ///
    /// An exam whose wall time a daylight-saving transition skipped has no
    /// instant, so it cannot land in "Today" and sorts to the end of
    /// "Upcoming" instead of vanishing.
    static func examSections(
        _ exams: [Exam],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ExamSection] {
        let active = exams.filter { $0.deletedAt == nil }
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        var today: [Exam] = []
        var upcoming: [Exam] = []
        var completed: [Exam] = []
        var cancelled: [Exam] = []

        for exam in active {
            switch exam.status {
            case .cancelled:
                cancelled.append(exam)
            case .completed:
                completed.append(exam)
            case .upcoming:
                if let start = exam.startsAtUTC, start >= dayStart, start < dayEnd {
                    today.append(exam)
                } else {
                    upcoming.append(exam)
                }
            }
        }

        let buckets: [(ExamSection.Kind, [Exam])] = [
            (.today, today),
            (.upcoming, upcoming),
            (.completed, completed),
            (.cancelled, cancelled)
        ]
        return buckets.compactMap { kind, list in
            list.isEmpty ? nil : ExamSection(kind: kind, exams: sortedExams(list))
        }
    }

    /// Exams inside the near horizon, for the Today overview.
    static func upcomingExams(
        _ exams: [Exam],
        withinDays days: Int = 14,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Exam] {
        let dayStart = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: days, to: dayStart) ?? dayStart
        return sortedExams(
            exams.filter { exam in
                guard exam.deletedAt == nil,
                      exam.status == .upcoming,
                      let start = exam.startsAtUTC else {
                    return false
                }
                return start >= dayStart && start <= horizon
            }
        )
    }

    static func todayOverview(
        meetings: [CourseMeeting],
        exams: [Exam],
        assignments: [Assignment],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TodayOverview {
        let weekday = isoWeekday(of: now, calendar: calendar)
        return TodayOverview(
            meetings: self.meetings(meetings, on: weekday),
            exams: upcomingExams(exams, now: now, calendar: calendar),
            dueToday: TaskRules.tasks(
                assignments,
                in: .today,
                now: now,
                calendar: calendar
            ),
            overdue: TaskRules.tasks(
                assignments,
                in: .overdue,
                now: now,
                calendar: calendar
            )
        )
    }
}


// MARK: - Store

/// The Phase 3A learning scenes, bound to the repository the task list already
/// uses.
///
/// It owns no database handle of its own. A meeting, an exam, and a task
/// therefore always share one file, one migration, and one notification
/// scheduler.
@MainActor
final class LearningSceneStore: ObservableObject {
    @Published private(set) var meetings: [CourseMeeting] = []
    @Published private(set) var exams: [Exam] = []
    @Published private(set) var courses: [Course] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isAvailable = false
    @Published var errorMessage: String?

    private let learningRepository: LearningSceneRepository?
    private let organizationRepository: OrganizationRepository?
    private let assignmentRepository: SQLiteAssignmentRepository?

    /// Called after a write so the task list can catch up. A Review Task is an
    /// ordinary task, so it has to appear on the task pages too.
    var onDidMutate: (() -> Void)?

    init(
        learningRepository: LearningSceneRepository?,
        organizationRepository: OrganizationRepository?,
        assignmentRepository: SQLiteAssignmentRepository?
    ) {
        self.learningRepository = learningRepository
        self.organizationRepository = organizationRepository
        self.assignmentRepository = assignmentRepository
        isAvailable = learningRepository != nil
        reload()
    }

    // MARK: Reading

    func reload() {
        guard let learningRepository else {
            isAvailable = false
            meetings = []
            exams = []
            courses = []
            return
        }
        isAvailable = true
        isLoading = true
        defer { isLoading = false }
        do {
            meetings = try learningRepository.fetchMeetings(
                courseID: nil,
                includeDeleted: false
            )
            exams = try learningRepository.fetchExams(courseID: nil, includeDeleted: false)
            courses = try organizationRepository?.fetchCourses(includeDeleted: false) ?? []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func courseName(_ courseID: Int64) -> String {
        courses.first(where: { $0.id == courseID })?.name ?? "Untitled course"
    }

    /// Collisions for a draft that has not been saved yet. Warnings only.
    func overlaps(
        for draft: CourseMeetingDraft,
        excludingID: Int64? = nil
    ) -> [CourseMeeting] {
        (try? learningRepository?.meetingsOverlapping(draft, excludingID: excludingID)) ?? []
    }

    var overlappingPairs: [(CourseMeeting, CourseMeeting)] {
        LearningScenePlanner.overlappingPairs(meetings)
    }

    // MARK: Course meetings

    @discardableResult
    func saveMeeting(_ draft: CourseMeetingDraft, editing meeting: CourseMeeting?) -> Bool {
        guard let learningRepository else { return false }
        do {
            if var target = meeting {
                target.courseID = draft.courseID
                target.weekday = draft.weekday
                target.startTimeLocal = draft.startTimeLocal
                target.endTimeLocal = draft.endTimeLocal
                target.location = draft.location
                target.teacherOverride = draft.teacherOverride
                target.timezoneID = draft.timezoneID
                target.effectiveStartDate = draft.effectiveStartDate
                target.effectiveEndDate = draft.effectiveEndDate
                target.sortOrder = draft.sortOrder
                _ = try learningRepository.updateMeeting(target)
            } else {
                _ = try learningRepository.createMeeting(draft)
            }
            errorMessage = nil
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteMeeting(_ meeting: CourseMeeting) {
        guard let learningRepository else { return }
        do {
            try learningRepository.deleteMeeting(id: meeting.id)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Exams

    @discardableResult
    func saveExam(_ draft: ExamDraft, editing exam: Exam?) -> Bool {
        guard let learningRepository else { return false }
        do {
            if var target = exam {
                target.courseID = draft.courseID
                target.name = draft.name
                target.startsAtLocal = draft.startsAtLocal
                target.timezoneID = draft.timezoneID
                target.location = draft.location
                target.scope = draft.scope
                target.notes = draft.notes
                target.status = draft.status
                _ = try learningRepository.updateExam(target)
            } else {
                _ = try learningRepository.createExam(draft)
            }
            errorMessage = nil
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Soft-deletes an exam. The linked Review Task is an ordinary task the
    /// user owns, so it is never removed here.
    func deleteExam(_ exam: Exam) {
        guard let learningRepository else { return }
        do {
            try learningRepository.deleteExam(id: exam.id)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setExamStatus(_ status: ExamStatus, for exam: Exam) -> Bool {
        guard let learningRepository else { return false }
        do {
            var target = exam
            target.status = status
            _ = try learningRepository.updateExam(target)
            errorMessage = nil
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates the Review Task for an exam, or returns the one that exists.
    func createReviewTask(
        for exam: Exam,
        daysBeforeExam: Int = 1
    ) -> ExamReviewTaskLink? {
        guard let assignmentRepository else { return nil }
        do {
            let link = try assignmentRepository.createOrFetchReviewTask(
                forExam: exam.id,
                daysBeforeExam: daysBeforeExam
            )
            errorMessage = nil
            reload()
            onDidMutate?()
            return link
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Courses

    /// Finds a course by name, creating it when the timetable names a course
    /// that has no row yet. Courses are shared with the task list.
    func resolveCourse(named name: String) throws -> Course {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OrganizationRepositoryError.validation("A meeting needs a course.")
        }
        if let existing = courses.first(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return existing
        }
        guard let organizationRepository else {
            throw AssignmentRepositoryError.readOnlyAfterMigrationFailure
        }
        let created = try organizationRepository.createCourse(CourseDraft(name: trimmed))
        courses.append(created)
        courses.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return created
    }
}
