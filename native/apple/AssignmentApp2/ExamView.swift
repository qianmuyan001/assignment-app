import SwiftUI


struct ExamListView: View {
    @ObservedObject var store: LearningSceneStore
    let displayMode: DisplayMode
    let isWriteEnabled: Bool

    @State private var editorState: ExamEditorState?
    @State private var pendingDeletion: Exam?
    @State private var reviewNotice: ReviewTaskNotice?

    private var sections: [ExamSection] {
        LearningScenePlanner.examSections(store.exams)
    }

    private var totalCount: Int {
        store.exams.filter { $0.deletedAt == nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Exams")
        .toolbar { toolbarContent }
        .sheet(item: $editorState) { state in
            ExamEditorView(
                store: store,
                exam: state.exam,
                displayMode: displayMode,
                onSave: { draft in
                    guard store.saveExam(draft, editing: state.exam) else {
                        return store.errorMessage ?? "The exam could not be saved."
                    }
                    return nil
                },
                onDelete: state.exam == nil ? nil : { exam in
                    store.deleteExam(exam)
                }
            )
        }
        .alert(item: $reviewNotice) { notice in
            Alert(
                title: Text(notice.localizedTitle),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Delete this exam?", isPresented: deletionPrompt) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    store.deleteExam(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("The exam is removed from this list. A linked Review Task stays untouched — it is an ordinary task you own.")
        }
        .task { store.reload() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Text(summaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(ExamFormatting.timeZoneSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                .help("Reload exams")
            }

            Button("Add Exam", systemImage: "plus") {
                editorState = ExamEditorState(exam: nil)
            }
            .disabled(!isWriteEnabled)
            .help(isWriteEnabled
                  ? "Add an exam"
                  : "The local database is unavailable")
        }
    }

    private var summaryText: String {
        guard totalCount > 0 else { return "No exams yet" }
        let upcoming = store.exams.filter { $0.deletedAt == nil && $0.status == .upcoming }.count
        guard upcoming > 0 else { return "\(totalCount) exams" }
        return "\(upcoming) upcoming · \(totalCount) total"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !store.isAvailable {
            LearningUnavailableView(
                message: store.errorMessage ?? "The local task database could not be opened.",
                onReload: { store.reload() }
            )
        } else if store.exams.isEmpty {
            ContentUnavailableView {
                Label("No Exams Yet", systemImage: "graduationcap")
            } description: {
                Text("Add an exam to track its date, place, and scope.")
            } actions: {
                Button("Add Exam", systemImage: "plus") {
                    editorState = ExamEditorState(exam: nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(!isWriteEnabled)
        } else {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.exams) { exam in
                            ExamRow(
                                exam: exam,
                                courseName: store.courseName(exam.courseID),
                                displayMode: displayMode,
                                onEdit: { editorState = ExamEditorState(exam: exam) },
                                onSetStatus: { status in
                                    store.setExamStatus(status, for: exam)
                                },
                                onCreateReviewTask: {
                                    createReviewTask(for: exam)
                                },
                                onDelete: { pendingDeletion = exam }
                            )
                        }
                    } header: {
                        Label(section.kind.localizedTitle, systemImage: section.kind.systemImage)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func createReviewTask(for exam: Exam) {
        guard let link = store.createReviewTask(for: exam) else {
            reviewNotice = ReviewTaskNotice(
                title: "Review Task Not Created",
                message: store.errorMessage ?? "The local database is unavailable."
            )
            return
        }
        let due = link.assignment.dueDate
            .map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? "no due date"
        reviewNotice = ReviewTaskNotice(
            title: link.created ? "Review Task Created" : "Review Task Already Exists",
            message: link.created
                ? L10n.tr(
                    "“%@” was added and is due %@.",
                    link.assignment.title,
                    due
                )
                : L10n.tr(
                    "“%@” is already linked and is due %@. Nothing new was created.",
                    link.assignment.title,
                    due
                )
        )
    }
}


private struct ReviewTaskNotice: Identifiable, LocalizableTitled {
    let id = UUID()
    let title: String
    /// Already localized at the point it is built, because it is composed from
    /// an assignment title and a formatted due date.
    let message: String
}


private struct ExamEditorState: Identifiable {
    let id = UUID()
    let exam: Exam?
}


enum ExamFormatting {
    static var timeZoneSummary: String {
        let zone = TimeZone.current
        return "Times are shown in \(zone.identifier)"
    }

    /// `YYYY-MM-DD HH:mm:ss`, with the seconds dropped for display.
    static func startsAtText(_ exam: Exam) -> String {
        let text = exam.startsAtLocal
        return text.count >= 16 ? String(text.prefix(16)) : text
    }

    /// How long from now, or `nil` when the wall time has no instant.
    static func relativeText(_ exam: Exam, now: Date = Date()) -> String? {
        guard let start = exam.startsAtUTC else { return nil }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: start)
        ).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case ..<0: return "\(abs(days)) days ago"
        default: return "In \(days) days"
        }
    }

    static func accessibilityLabel(_ exam: Exam, courseName: String) -> String {
        var parts = [exam.name, courseName, startsAtText(exam), exam.status.localizedTitle]
        if let relative = relativeText(exam) {
            parts.append(relative)
        }
        if let location = exam.location,
           !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("at \(location)")
        }
        return parts.joined(separator: ", ")
    }
}


private struct ExamRow: View {
    let exam: Exam
    let courseName: String
    let displayMode: DisplayMode
    let onEdit: () -> Void
    let onSetStatus: (ExamStatus) -> Void
    let onCreateReviewTask: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exam.name)
                    .font(.headline)
                Spacer(minLength: 0)
                Text(exam.status.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusTint.opacity(0.16), in: Capsule())
                    .foregroundStyle(statusTint)
            }

            HStack(spacing: 10) {
                Label(ExamFormatting.startsAtText(exam), systemImage: "calendar")
                if let relative = ExamFormatting.relativeText(exam) {
                    Text(relative)
                        .foregroundStyle(.secondary)
                }
                if exam.startsAtUTC == nil {
                    Label("Skipped by a clock change", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)

            Label(courseName, systemImage: "book.closed")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let location = exam.location, !location.isBlank {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if displayMode == .professional {
                if let scope = exam.scope, !scope.isBlank {
                    Label(scope, systemImage: "list.bullet.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = exam.notes, !notes.isBlank {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let zone = TimeZone(identifier: exam.timezoneID),
               zone.identifier != TimeZone.current.identifier {
                Label(exam.timezoneID, systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if exam.linkedAssignmentID == nil {
                    Button("Add Review Task", systemImage: "plus.circle", action: onCreateReviewTask)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Create a review task one day before the exam")
                        .frame(minHeight: 32)
                } else {
                    Label("Review task linked", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Menu("Status", systemImage: "circle.dashed") {
                    ForEach(ExamStatus.allCases) { status in
                        Button {
                            onSetStatus(status)
                        } label: {
                            Label(
                                status.localizedTitle,
                                systemImage: exam.status == status ? "checkmark" : "circle"
                            )
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(minHeight: 32)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                onDelete()
            }
            Button("Edit", systemImage: "pencil") {
                onEdit()
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Edit Exam", systemImage: "pencil") { onEdit() }
            if exam.linkedAssignmentID == nil {
                Button("Add Review Task", systemImage: "plus.circle") { onCreateReviewTask() }
            }
            Button("Delete Exam", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ExamFormatting.accessibilityLabel(exam, courseName: courseName))
    }

    private var statusTint: Color {
        switch exam.status {
        case .upcoming: return .blue
        case .completed: return .green
        case .cancelled: return .secondary
        }
    }
}


// MARK: - Editor

struct ExamEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var store: LearningSceneStore
    let exam: Exam?
    let displayMode: DisplayMode
    let onSave: (ExamDraft) -> String?
    let onDelete: ((Exam) -> Void)?

    @State private var name: String
    @State private var isCreatingCourse = false
    @State private var selectedCourseID: Int64?
    @State private var newCourseName = ""
    @State private var startsAt: Date
    @State private var timezoneChoice: LearningTimeZoneChoice
    @State private var customTimezone: String
    @State private var location: String
    @State private var scope: String
    @State private var notes: String
    @State private var status: ExamStatus
    @State private var validationMessage: String?
    @State private var isShowingDeleteConfirmation = false

    init(
        store: LearningSceneStore,
        exam: Exam?,
        displayMode: DisplayMode,
        onSave: @escaping (ExamDraft) -> String?,
        onDelete: ((Exam) -> Void)? = nil
    ) {
        self.store = store
        self.exam = exam
        self.displayMode = displayMode
        self.onSave = onSave
        self.onDelete = onDelete

        _name = State(initialValue: exam?.name ?? "")
        _startsAt = State(initialValue: LearningDateInput.date(fromDay: exam?.startsAtLocal))
        _location = State(initialValue: exam?.location ?? "")
        _scope = State(initialValue: exam?.scope ?? "")
        _notes = State(initialValue: exam?.notes ?? "")
        _status = State(initialValue: exam?.status ?? .upcoming)

        let zone = exam?.timezoneID ?? TimeZone.current.identifier
        _timezoneChoice = State(initialValue: LearningTimeZoneChoice(identifier: zone))
        _customTimezone = State(initialValue: zone)
        _selectedCourseID = State(initialValue: exam?.courseID ?? store.courses.first?.id)
        _isCreatingCourse = State(initialValue: exam == nil && store.courses.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exam") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.next)

                    Picker("Status", selection: $status) {
                        ForEach(ExamStatus.allCases) { value in
                            Text(value.localizedTitle).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Course") {
                    if isCreatingCourse {
                        TextField("Course name", text: $newCourseName)
                            .textInputAutocapitalization(.words)
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

                Section("When") {
                    DatePicker(
                        "Starts",
                        selection: $startsAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    Picker("Time zone", selection: $timezoneChoice) {
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

                    if resolvedStart == nil {
                        Label(
                            "This exact time does not exist in the chosen time zone because a daylight-saving transition skips it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Where") {
                    TextField("Location", text: $location)
                        .textInputAutocapitalization(.words)
                }

                if displayMode == .professional {
                    Section("Scope") {
                        TextField("Scope", text: $scope, axis: .vertical)
                            .lineLimit(2...6)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(2...6)
                    }
                }

                if let exam, onDelete != nil {
                    Section {
                        Button("Delete Exam", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                    } footer: {
                        Text("Deleting an exam never deletes its Review Task.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(exam == nil ? L10n.tr("New Exam") : L10n.tr("Edit Exam"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Check the Exam", isPresented: validationPrompt) {
                Button("OK", role: .cancel) { validationMessage = nil }
            } message: {
                Text(validationMessage ?? "Review the exam and try again.")
            }
            .alert("Delete this exam?", isPresented: $isShowingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    guard let exam, let onDelete else { return }
                    onDelete(exam)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A linked Review Task stays untouched.")
            }
        }
    }

    private var resolvedTimeZoneIdentifier: String {
        switch timezoneChoice {
        case .system: return TimeZone.current.identifier
        case .utc: return "UTC"
        case .custom: return customTimezone.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var resolvedTimeZoneSummary: String {
        let identifier = resolvedTimeZoneIdentifier
        guard let zone = TimeZone(identifier: identifier) else {
            return "“\(identifier)” is not a recognized IANA time zone."
        }
        let offset = zone.secondsFromGMT() / 60
        let sign = offset < 0 ? "-" : "+"
        return "Read in \(identifier) (UTC\(sign)\(abs(offset) / 60):\(String(format: "%02d", abs(offset) % 60)))."
    }

    /// `nil` when the chosen wall time is skipped by a clock change.
    private var resolvedStart: Date? {
        guard let wall = try? LocalWallDateTime(startsAtLocalText),
              let zone = try? LearningRules.validatedTimeZone(resolvedTimeZoneIdentifier) else {
            return nil
        }
        return LearningRules.resolveWallTime(wall, in: zone)
    }

    private var startsAtLocalText: String {
        LearningDateInput.dateTimeText(startsAt)
    }

    private var validationPrompt: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Give the exam a name."
            return
        }

        let resolvedID: Int64
        do {
            if isCreatingCourse {
                resolvedID = try store.resolveCourse(named: newCourseName).id
            } else {
                guard let id = selectedCourseID else {
                    throw OrganizationRepositoryError.validation("Choose a course for this exam.")
                }
                resolvedID = id
            }
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        do {
            _ = try LearningRules.validatedTimeZone(resolvedTimeZoneIdentifier)
            _ = try LocalWallDateTime(startsAtLocalText)
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        let draft = ExamDraft(
            courseID: resolvedID,
            name: trimmedName,
            startsAtLocal: startsAtLocalText,
            timezoneID: resolvedTimeZoneIdentifier,
            location: location.nilIfBlank,
            scope: scope.nilIfBlank,
            notes: notes.nilIfBlank,
            status: status
        )

        if let message = onSave(draft) {
            validationMessage = message
            return
        }
        dismiss()
    }
}


private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var nilIfBlank: String? {
        isBlank ? nil : trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
