import SwiftUI


/// Why the learning pages cannot show anything.
///
/// It is a real state rather than an empty one: the repository is absent when
/// the database could not be opened or migrated, and saying "no classes yet"
/// then would be a lie.
struct LearningUnavailableView: View {
    let message: String
    let onReload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Learning Data Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Reload", systemImage: "arrow.clockwise", action: onReload)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


enum TimetableScope: String, CaseIterable, Identifiable {
    case week
    case today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Week"
        case .today: return "Today"
        }
    }
}


struct TimetableView: View {
    @ObservedObject var store: LearningSceneStore
    let displayMode: DisplayMode
    let isWriteEnabled: Bool

    @State private var scope: TimetableScope = .week
    @State private var editorState: MeetingEditorState?
    @State private var pendingDeletion: CourseMeeting?

    /// Below this width a seven-column grid stops being readable, so the page
    /// falls back to a list grouped by weekday.
    private static let gridWidthThreshold: CGFloat = 720

    private var overlapPairs: [(CourseMeeting, CourseMeeting)] {
        LearningScenePlanner.overlappingPairs(store.meetings)
    }

    private var todayWeekday: Int {
        LearningScenePlanner.isoWeekday(of: Date())
    }

    private var visibleDays: [(weekday: Int, meetings: [CourseMeeting])] {
        switch scope {
        case .week:
            return LearningScenePlanner.week(store.meetings)
        case .today:
            return [(todayWeekday, LearningScenePlanner.meetings(store.meetings, on: todayWeekday))]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(L10n.tr("Timetable"))
        .toolbar { toolbarContent }
        .sheet(item: $editorState) { state in
            MeetingEditorView(
                store: store,
                meeting: state.meeting,
                displayMode: displayMode,
                onSave: { draft in
                    guard store.saveMeeting(draft, editing: state.meeting) else {
                        return store.errorMessage ?? "The meeting could not be saved."
                    }
                    return nil
                },
                onDelete: state.meeting == nil ? nil : { meeting in
                    store.deleteMeeting(meeting)
                }
            )
        }
        .alert("Delete this meeting?", isPresented: deletionPrompt) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    store.deleteMeeting(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("The weekly class is removed from the timetable. Tasks are not affected.")
        }
        .task { store.reload() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Timetable view", selection: $scope) {
                ForEach(TimetableScope.allCases) { value in
                    Text(value.localizedTitle).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            .help("Switch between the whole week and today")

            Spacer(minLength: 8)

            Text(summaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(summaryText)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Reload", systemImage: "arrow.clockwise") {
                    store.reload()
                }
                .help("Reload the timetable")
            }

            Button("Add Meeting", systemImage: "plus") {
                editorState = MeetingEditorState(meeting: nil)
            }
            .disabled(!isWriteEnabled)
            .help(isWriteEnabled
                  ? "Add a weekly class meeting"
                  : "The local database is unavailable")
        }
    }

    private var summaryText: String {
        let total = store.meetings.filter { $0.deletedAt == nil }.count
        guard total > 0 else { return "No meetings yet" }
        return total == 1 ? "1 weekly meeting" : "\(total) weekly meetings"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isAvailable {
            LearningUnavailableView(
                message: store.errorMessage ?? "The local task database could not be opened.",
                onReload: { store.reload() }
            )
        } else if store.meetings.isEmpty {
            TimetableEmptyState {
                editorState = MeetingEditorState(meeting: nil)
            }
            .disabled(!isWriteEnabled)
        } else {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    if !overlapPairs.isEmpty {
                        OverlapBanner(pairs: overlapPairs) { meeting in
                            editorState = MeetingEditorState(meeting: meeting)
                        }
                    }

                    if scope == .today || proxy.size.width < Self.gridWidthThreshold {
                        dayList
                    } else {
                        weekGrid
                    }
                }
            }
        }
    }

    private var weekGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 92), spacing: 10),
                    count: 7
                ),
                spacing: 10
            ) {
                ForEach(visibleDays, id: \.weekday) { day in
                    TimetableDayColumn(
                        weekday: day.weekday,
                        meetings: day.meetings,
                        isToday: day.weekday == todayWeekday,
                        courseName: { store.courseName($0) },
                        onEdit: { editorState = MeetingEditorState(meeting: $0) },
                        onDelete: { pendingDeletion = $0 }
                    )
                }
            }
            .padding(12)
        }
    }

    private var dayList: some View {
        List {
            ForEach(visibleDays, id: \.weekday) { day in
                Section {
                    if day.meetings.isEmpty {
                        Text("No classes")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(day.meetings) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                courseName: store.courseName(meeting.courseID),
                                displayMode: displayMode
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = meeting
                                }
                            }
                            .onTapGesture {
                                editorState = MeetingEditorState(meeting: meeting)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(LearningRules.weekdayTitle(day.weekday))
                        if day.weekday == todayWeekday {
                            Text("Today")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}


private struct TimetableEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Classes Scheduled", systemImage: "calendar.day.timeline.leading")
        } description: {
            Text("Add a weekly meeting to build your timetable.")
        } actions: {
            Button("Add Meeting", systemImage: "plus", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// A collision notice. It never offers to fix anything by itself: the user
/// opens an editor and decides.
private struct OverlapBanner: View {
    let pairs: [(CourseMeeting, CourseMeeting)]
    let onEdit: (CourseMeeting) -> Void

    private var summary: String {
        let days = Set(pairs.flatMap { [$0.0.weekday, $0.1.weekday] })
        let dayTitles = days
            .sorted()
            .map(LearningRules.shortWeekdayTitle)
            .joined(separator: ", ")
        return "\(pairs.count) overlapping \(pairs.count == 1 ? "pair" : "pairs") on \(dayTitles)."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Overlapping classes")
                    .font(.subheadline.weight(.semibold))
                Text(summary + " Nothing was changed — open a meeting to adjust it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let first = pairs.first {
                Button("Review") {
                    onEdit(first.0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}


private struct TimetableDayColumn: View {
    let weekday: Int
    let meetings: [CourseMeeting]
    let isToday: Bool
    let courseName: (Int64) -> String
    let onEdit: (CourseMeeting) -> Void
    let onDelete: (CourseMeeting) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(LearningRules.shortWeekdayTitle(weekday))
                    .font(.headline)
                if isToday {
                    Text("Today")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }

            if meetings.isEmpty {
                Text("No classes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } else {
                ForEach(meetings) { meeting in
                    MeetingCard(
                        meeting: meeting,
                        courseName: courseName(meeting.courseID),
                        displayMode: .simple,
                        onEdit: { onEdit(meeting) },
                        onDelete: { onDelete(meeting) }
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isToday ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isToday ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(weekdayAccessibilityLabel)
    }

    private var weekdayAccessibilityLabel: String {
        let title = LearningRules.weekdayTitle(weekday)
        let suffix = isToday ? ", today" : ""
        return "\(title)\(suffix), \(meetings.count) \(meetings.count == 1 ? "class" : "classes")"
    }
}


private struct MeetingCard: View {
    let meeting: CourseMeeting
    let courseName: String
    let displayMode: DisplayMode
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 3) {
                Text(MeetingFormatting.timeRange(meeting))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(courseName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let location = meeting.location,
                   !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if displayMode == .professional,
                   let teacher = meeting.teacherOverride,
                   !teacher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(teacher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if MeetingFormatting.usesForeignTimeZone(meeting) {
                    Text(meeting.timezoneID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Meeting", systemImage: "pencil") { onEdit() }
            Button("Delete Meeting", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .accessibilityLabel(MeetingFormatting.accessibilityLabel(meeting, courseName: courseName))
    }
}


private struct MeetingRow: View {
    let meeting: CourseMeeting
    let courseName: String
    let displayMode: DisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MeetingFormatting.timeRange(meeting))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                Text(courseName)
                    .font(.headline)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                if let location = meeting.location,
                   !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                if displayMode == .professional,
                   let teacher = meeting.teacherOverride,
                   !teacher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(teacher, systemImage: "person")
                }
                if MeetingFormatting.usesForeignTimeZone(meeting) {
                    Label(meeting.timezoneID, systemImage: "globe")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MeetingFormatting.accessibilityLabel(meeting, courseName: courseName))
    }
}


enum MeetingFormatting {
    /// `HH:mm:ss` columns are shown as `HH:mm`; the contract keeps the seconds
    /// for exact comparisons.
    static func clock(_ text: String) -> String {
        text.count >= 5 ? String(text.prefix(5)) : text
    }

    static func timeRange(_ meeting: CourseMeeting) -> String {
        "\(clock(meeting.startTimeLocal)) – \(clock(meeting.endTimeLocal))"
    }

    static func usesForeignTimeZone(_ meeting: CourseMeeting) -> Bool {
        TimeZone(identifier: meeting.timezoneID)?.identifier != TimeZone.current.identifier
    }

    static func accessibilityLabel(_ meeting: CourseMeeting, courseName: String) -> String {
        var parts = [
            courseName,
            "\(clock(meeting.startTimeLocal)) to \(clock(meeting.endTimeLocal))",
            LearningRules.weekdayTitle(meeting.weekday)
        ]
        if let location = meeting.location,
           !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("at \(location)")
        }
        return parts.joined(separator: ", ")
    }
}


// MARK: - Editor

private struct MeetingEditorState: Identifiable {
    let id = UUID()
    let meeting: CourseMeeting?
}


struct MeetingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var store: LearningSceneStore
    let meeting: CourseMeeting?
    let displayMode: DisplayMode
    /// Returns an error message to keep the sheet open, or `nil` on success.
    let onSave: (CourseMeetingDraft) -> String?
    let onDelete: ((CourseMeeting) -> Void)?

    @State private var isCreatingCourse = false
    @State private var selectedCourseID: Int64?
    @State private var newCourseName = ""
    @State private var weekday: Int
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var location: String
    @State private var teacher: String
    @State private var timezoneChoice: LearningTimeZoneChoice
    @State private var customTimezone: String
    @State private var effectiveStart: Date
    @State private var hasEffectiveEnd: Bool
    @State private var effectiveEnd: Date
    @State private var validationMessage: String?
    @State private var isShowingDeleteConfirmation = false

    init(
        store: LearningSceneStore,
        meeting: CourseMeeting?,
        displayMode: DisplayMode,
        onSave: @escaping (CourseMeetingDraft) -> String?,
        onDelete: ((CourseMeeting) -> Void)? = nil
    ) {
        self.store = store
        self.meeting = meeting
        self.displayMode = displayMode
        self.onSave = onSave
        self.onDelete = onDelete

        let start = meeting?.startTimeLocal ?? "08:00:00"
        let end = meeting?.endTimeLocal ?? "09:00:00"
        _weekday = State(initialValue: meeting?.weekday ?? LearningScenePlanner.isoWeekday(of: Date()))
        _startDate = State(initialValue: LearningDateInput.date(fromClock: start))
        _endDate = State(initialValue: LearningDateInput.date(fromClock: end))
        _location = State(initialValue: meeting?.location ?? "")
        _teacher = State(initialValue: meeting?.teacherOverride ?? "")
        let startDay = LearningDateInput.date(fromDay: meeting?.effectiveStartDate)
        _effectiveStart = State(initialValue: startDay)
        _hasEffectiveEnd = State(initialValue: meeting?.effectiveEndDate != nil)
        _effectiveEnd = State(initialValue: LearningDateInput.date(
            fromDay: meeting?.effectiveEndDate
                ?? LearningDateInput.dayText(
                    Calendar.current.date(byAdding: .day, value: 120, to: startDay) ?? startDay
                )
        ))

        let zone = meeting?.timezoneID ?? TimeZone.current.identifier
        _timezoneChoice = State(initialValue: LearningTimeZoneChoice(identifier: zone))
        _customTimezone = State(initialValue: zone)
        _selectedCourseID = State(initialValue: meeting?.courseID ?? store.courses.first?.id)
        _isCreatingCourse = State(initialValue: meeting == nil && store.courses.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Course") {
                    if isCreatingCourse {
                        TextField("Course name", text: $newCourseName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)

                        if !store.courses.isEmpty {
                            Button("Choose an Existing Course") {
                                isCreatingCourse = false
                            }
                        }
                    } else {
                        Picker("Course", selection: $selectedCourseID) {
                            Text("Choose a course").tag(Optional<Int64>.none)
                            ForEach(store.courses) { course in
                                Text(course.name).tag(Optional(course.id))
                            }
                        }

                        Button("Add a New Course") {
                            isCreatingCourse = true
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Weekday", selection: $weekday) {
                        ForEach(1...7, id: \.self) { value in
                            Text(LearningRules.weekdayTitle(value)).tag(value)
                        }
                    }

                    DatePicker(
                        "Starts",
                        selection: $startDate,
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        "Ends",
                        selection: $endDate,
                        displayedComponents: .hourAndMinute
                    )
                    .accessibilityHint("Must be later than the start time.")
                }

                Section("Time Zone") {
                    Picker("Zone", selection: $timezoneChoice) {
                        ForEach(LearningTimeZoneChoice.allCases) { choice in
                            Text(choice.localizedTitle).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if timezoneChoice == .custom {
                        TextField("IANA identifier", text: $customTimezone)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }

                    Text(resolvedTimeZoneSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Effective Range") {
                    DatePicker(
                        "Starts on",
                        selection: $effectiveStart,
                        displayedComponents: .date
                    )

                    Toggle("Ends on a date", isOn: $hasEffectiveEnd)

                    if hasEffectiveEnd {
                        DatePicker(
                            "Ends on",
                            selection: $effectiveEnd,
                            displayedComponents: .date
                        )
                    }
                }

                Section("Where") {
                    TextField("Location", text: $location)
                        .textInputAutocapitalization(.words)
                    if displayMode == .professional {
                        TextField("Teacher override", text: $teacher)
                            .textInputAutocapitalization(.words)
                    }
                }

                if !overlapWarnings.isEmpty {
                    Section("Overlaps") {
                        ForEach(overlapWarnings) { other in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.courseName(other.courseID))
                                    Text("\(MeetingFormatting.timeRange(other)) · \(LearningRules.shortWeekdayTitle(other.weekday))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("This meeting can still be saved. Overlaps are warnings, not errors.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let meeting, onDelete != nil {
                    Section {
                        Button("Delete Meeting", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(meeting == nil ? L10n.tr("New Meeting") : L10n.tr("Edit Meeting"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert("Check the Meeting", isPresented: validationPrompt) {
                Button("OK", role: .cancel) { validationMessage = nil }
            } message: {
                Text(validationMessage ?? "Review the meeting and try again.")
            }
            .alert("Delete this meeting?", isPresented: $isShowingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    guard let meeting, let onDelete else { return }
                    onDelete(meeting)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The weekly class is removed from the timetable. Tasks are not affected.")
            }
        }
    }

    // MARK: Derived

    private var resolvedCourseID: Int64? {
        if let meeting { return meeting.courseID }
        if isCreatingCourse { return nil }
        return selectedCourseID
    }

    private var resolvedTimeZoneSummary: String {
        let identifier = resolvedTimeZoneIdentifier
        guard let zone = TimeZone(identifier: identifier) else {
            return "“\(identifier)” is not a recognized IANA time zone."
        }
        let offset = zone.secondsFromGMT() / 60
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 60
        let minutes = abs(offset) % 60
        return "Times are read in \(identifier) (UTC\(sign)\(hours):\(String(format: "%02d", minutes)))."
    }

    private var resolvedTimeZoneIdentifier: String {
        switch timezoneChoice {
        case .system:
            return TimeZone.current.identifier
        case .utc:
            return "UTC"
        case .custom:
            return customTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var currentDraft: CourseMeetingDraft? {
        guard let courseID = resolvedCourseID else { return nil }
        return CourseMeetingDraft(
            courseID: courseID,
            weekday: weekday,
            startTimeLocal: LearningDateInput.clockText(startDate),
            endTimeLocal: LearningDateInput.clockText(endDate),
            location: location.nilIfBlank,
            teacherOverride: teacher.nilIfBlank,
            timezoneID: resolvedTimeZoneIdentifier,
            effectiveStartDate: LearningDateInput.dayText(effectiveStart),
            effectiveEndDate: hasEffectiveEnd
                ? LearningDateInput.dayText(effectiveEnd)
                : nil,
            sortOrder: meeting?.sortOrder ?? 0
        )
    }

    private var overlapWarnings: [CourseMeeting] {
        guard let draft = currentDraft else { return [] }
        return store.overlaps(for: draft, excludingID: meeting?.id)
    }

    private var validationPrompt: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }

    // MARK: Actions

    private func save() {
        let resolvedID: Int64
        do {
            if isCreatingCourse {
                resolvedID = try store.resolveCourse(named: newCourseName).id
            } else {
                guard let id = selectedCourseID else {
                    throw OrganizationRepositoryError.validation("Choose a course for this meeting.")
                }
                resolvedID = id
            }
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        let draft = CourseMeetingDraft(
            courseID: resolvedID,
            weekday: weekday,
            startTimeLocal: LearningDateInput.clockText(startDate),
            endTimeLocal: LearningDateInput.clockText(endDate),
            location: location.nilIfBlank,
            teacherOverride: teacher.nilIfBlank,
            timezoneID: resolvedTimeZoneIdentifier,
            effectiveStartDate: LearningDateInput.dayText(effectiveStart),
            effectiveEndDate: hasEffectiveEnd
                ? LearningDateInput.dayText(effectiveEnd)
                : nil,
            sortOrder: meeting?.sortOrder ?? 0
        )

        do {
            _ = try MeetingWindow(
                weekday: draft.weekday,
                startTimeLocal: draft.startTimeLocal,
                endTimeLocal: draft.endTimeLocal,
                timezoneID: draft.timezoneID,
                effectiveStartDate: draft.effectiveStartDate,
                effectiveEndDate: draft.effectiveEndDate
            )
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        if let message = onSave(draft) {
            validationMessage = message
            return
        }
        dismiss()
    }
}


/// The three ways a learning record can name a time zone.
enum LearningTimeZoneChoice: String, CaseIterable, Identifiable {
    case system
    case utc
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "This Mac"
        case .utc: return "UTC"
        case .custom: return "Other"
        }
    }

    init(identifier: String) {
        if identifier == "UTC" {
            self = .utc
        } else if identifier == TimeZone.current.identifier {
            self = .system
        } else {
            self = .custom
        }
    }
}


/// Converts between SwiftUI date pickers and the contract's strict local text.
///
/// Pickers render in the system calendar, so the components are read back in
/// that same calendar. Reading them in UTC would shift the day across any
/// non-zero offset.
enum LearningDateInput {
    static func clockText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(
            format: "%02d:%02d:00",
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    static func dayText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    static func dateTimeText(_ date: Date) -> String {
        "\(dayText(date)) \(clockText(date))"
    }

    /// A picker value that shows `HH:mm:ss` exactly as the contract stores it.
    static func date(fromClock text: String) -> Date {
        let parts = text.split(separator: ":")
        let hour = parts.count > 0 ? Int(parts[0]) ?? 8 : 8
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let second = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return Calendar.current.date(
            from: DateComponents(
                year: today.year,
                month: today.month,
                day: today.day,
                hour: hour,
                minute: minute,
                second: second
            )
        ) ?? Date()
    }

    /// A picker value that shows `YYYY-MM-DD[ HH:mm:ss]` exactly as stored.
    static func date(fromDay text: String?) -> Date {
        guard let text else {
            return Calendar.current.startOfDay(for: Date())
        }
        let parts = text.split(separator: " ")
        let dayParts = parts[0].split(separator: "-")
        guard dayParts.count == 3,
              let year = Int(dayParts[0]),
              let month = Int(dayParts[1]),
              let day = Int(dayParts[2]) else {
            return Calendar.current.startOfDay(for: Date())
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        if parts.count > 1 {
            let clockParts = parts[1].split(separator: ":")
            components.hour = clockParts.count > 0 ? Int(clockParts[0]) : 0
            components.minute = clockParts.count > 1 ? Int(clockParts[1]) : 0
            components.second = clockParts.count > 2 ? Int(clockParts[2]) : 0
        } else {
            components.hour = 9
            components.minute = 0
            components.second = 0
        }
        return Calendar.current.date(from: components) ?? Date()
    }
}


private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
