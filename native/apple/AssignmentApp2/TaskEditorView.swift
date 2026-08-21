import CryptoKit
import Foundation
import SwiftUI


struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let assignment: Assignment?
    let displayMode: DisplayMode
    let onSave: (AssignmentDraft) -> String?
    let onDelete: ((Assignment) -> String?)?
    let organizationRepository: OrganizationRepository?
    let courses: [Course]
    let projects: [AssignmentProject]
    let tags: [AssignmentTag]
    let initialCourseID: Int64?
    let initialProjectID: Int64?
    let initialTagIDs: [Int64]

    @State private var draft: AssignmentDraft
    @State private var hasDueDate: Bool
    @State private var validationMessage: String?
    @State private var isShowingDeleteConfirmation = false

    // Professional-only organization selection.
    @State private var selectedCourseID: Int64?
    @State private var selectedProjectID: Int64?
    @State private var selectedTagIDs: Set<Int64>

    // Child records, edited directly through the repository for existing tasks.
    @State private var subtasks: [AssignmentSubtask] = []
    @State private var reminders: [TaskReminder] = []
    @State private var attachments: [AttachmentMetadata] = []
    @State private var isLoadingChildren = false
    @State private var newSubtaskTitle = ""
    @State private var newReminderDate = Date().addingTimeInterval(60 * 60)
    @State private var newReminderLead = 0
    @State private var newReminderRule = ""
    @State private var newReminderEnabled = true
    @State private var isShowingImporter = false
    @State private var childErrorMessage: String?

    init(
        assignment: Assignment? = nil,
        displayMode: DisplayMode,
        onSave: @escaping (AssignmentDraft) -> String?,
        onDelete: ((Assignment) -> String?)? = nil,
        organizationRepository: OrganizationRepository? = nil,
        courses: [Course] = [],
        projects: [AssignmentProject] = [],
        tags: [AssignmentTag] = [],
        initialCourseID: Int64? = nil,
        initialProjectID: Int64? = nil,
        initialTagIDs: [Int64] = []
    ) {
        self.assignment = assignment
        self.displayMode = displayMode
        self.onSave = onSave
        self.onDelete = onDelete
        self.organizationRepository = organizationRepository
        self.courses = courses
        self.projects = projects
        self.tags = tags
        self.initialCourseID = initialCourseID
        self.initialProjectID = initialProjectID
        self.initialTagIDs = initialTagIDs

        let initialDraft = assignment.map(AssignmentDraft.init(assignment:)) ?? AssignmentDraft()
        _draft = State(initialValue: initialDraft)
        _hasDueDate = State(initialValue: initialDraft.dueDate != nil)
        _selectedCourseID = State(initialValue: initialCourseID)
        _selectedProjectID = State(initialValue: initialProjectID)
        _selectedTagIDs = State(initialValue: Set(initialTagIDs))
    }

    private var canEditChildren: Bool {
        assignment != nil && organizationRepository != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $draft.title)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.next)

                    TextField("Course", text: $draft.courseName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.next)
                }

                Section("Due Date") {
                    Toggle("Set a due date", isOn: $hasDueDate)

                    if hasDueDate {
                        DatePicker(
                            "Due",
                            selection: dueDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("Status") {
                    Picker("Status", selection: $draft.status) {
                        ForEach(AssignmentStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if displayMode == .professional {
                    Section("Details") {
                        TextField(
                            "Description",
                            text: $draft.assignmentDescription,
                            axis: .vertical
                        )
                        .lineLimit(3...8)

                        Picker("Priority", selection: $draft.priority) {
                            ForEach(AssignmentPriority.allCases) { priority in
                                Text(priority.title).tag(priority)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Source link", text: $draft.link)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    Section("Organization") {
                        Picker("Existing Course", selection: $selectedCourseID) {
                            Text("Custom / none").tag(Optional<Int64>.none)
                            ForEach(courses) { course in
                                Text(course.name).tag(Optional(course.id))
                            }
                        }
                        .onChange(of: selectedCourseID) { _, newID in
                            if let id = newID,
                               let course = courses.first(where: { $0.id == id }) {
                                draft.courseName = course.name
                            }
                        }

                        Picker("Project", selection: $selectedProjectID) {
                            Text("None").tag(Optional<Int64>.none)
                            ForEach(eligibleProjects) { project in
                                Text(project.name).tag(Optional(project.id))
                            }
                        }

                        if !tags.isEmpty {
                            LabeledContent("Tags") {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(tags) { tag in
                                            TagChip(
                                                tag: tag,
                                                isSelected: selectedTagIDs.contains(tag.id)
                                            ) {
                                                toggleTag(tag.id)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .scrollIndicators(.hidden)
                            }
                        }
                    }

                    if canEditChildren {
                        Section("Subtasks") {
                            ForEach(subtasks) { subtask in
                                SubtaskRow(
                                    subtask: subtask,
                                    onToggle: { Task { await toggleSubtask(subtask) } },
                                    onDelete: { Task { await removeSubtask(subtask) } }
                                )
                            }

                            HStack {
                                TextField("Add subtask", text: $newSubtaskTitle)
                                    .textInputAutocapitalization(.sentences)
                                Button {
                                    Task { await addSubtask() }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                }
                                .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        Section("Reminders") {
                            ForEach(reminders) { reminder in
                                ReminderRow(
                                    reminder: reminder,
                                    onDelete: { Task { await removeReminder(reminder) } }
                                )
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                DatePicker(
                                    "Trigger",
                                    selection: $newReminderDate
                                )
                                Stepper("Lead: \(newReminderLead) min", value: $newReminderLead, in: 0...10080)
                                TextField("Repeat rule (optional)", text: $newReminderRule)
                                    .textInputAutocapitalization(.never)
                                Toggle("Enabled", isOn: $newReminderEnabled)
                                Button {
                                    Task { await addReminder() }
                                } label: {
                                    Label("Add Reminder", systemImage: "bell.badge.plus")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }

                        Section("Attachments") {
                            ForEach(attachments) { attachment in
                                AttachmentRow(
                                    attachment: attachment,
                                    onDelete: { Task { await removeAttachment(attachment) } }
                                )
                            }

                            Button {
                                isShowingImporter = true
                            } label: {
                                Label("Add Attachment", systemImage: "paperclip")
                            }
                        }
                    }
                }

                if assignment != nil, onDelete != nil {
                    Section {
                        Button("Delete Task", systemImage: "trash", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle(assignment == nil
                             ? (displayMode == .simple ? "Quick Add" : "New Task")
                             : "Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(isSaveDisabled)
                }
            }
            .onChange(of: draft.courseName) { _, newValue in
                if let id = selectedCourseID,
                   let course = courses.first(where: { $0.id == id }),
                   course.name != newValue {
                    selectedCourseID = nil
                }
            }
            .onChange(of: selectedCourseID) { _, _ in
                if let projectID = selectedProjectID,
                   !eligibleProjects.contains(where: { $0.id == projectID }) {
                    selectedProjectID = nil
                }
            }
            .onChange(of: hasDueDate) { _, isEnabled in
                if isEnabled, draft.dueDate == nil {
                    draft.dueDate = Date().addingTimeInterval(60 * 60)
                } else if !isEnabled {
                    draft.dueDate = nil
                }
            }
            .alert("Check Task Details", isPresented: validationAlert) {
                Button("OK", role: .cancel) {
                    validationMessage = nil
                }
            } message: {
                Text(validationMessage ?? "Review the task details and try again.")
            }
            .alert("Delete this task?", isPresented: $isShowingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteAssignment()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the task from the local database.")
            }
            .alert("Organization Error", isPresented: Binding(
                get: { childErrorMessage != nil },
                set: { if !$0 { childErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(childErrorMessage ?? "")
            }
            .fileImporter(
                isPresented: $isShowingImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                Task { await importAttachment(result) }
            }
            .task {
                if canEditChildren, let id = assignment?.id {
                    await loadChildren(assignmentID: id)
                }
            }
        }
    }

    private var eligibleProjects: [AssignmentProject] {
        guard let courseID = selectedCourseID else {
            return projects
        }
        let filtered = projects.filter { $0.courseID == courseID }
        return filtered.isEmpty ? projects : filtered
    }

    private func toggleTag(_ id: Int64) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if selectedTagIDs.contains(id) {
                selectedTagIDs.remove(id)
            } else {
                selectedTagIDs.insert(id)
            }
        }
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: { draft.dueDate ?? Date().addingTimeInterval(60 * 60) },
            set: { draft.dueDate = $0 }
        )
    }

    private var isSaveDisabled: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationAlert: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { isPresented in
                if !isPresented {
                    validationMessage = nil
                }
            }
        )
    }

    private func save() {
        draft.courseID = selectedCourseID
        draft.projectID = selectedProjectID
        draft.tagIDs = Array(selectedTagIDs)
        do {
            let validated = try draft.validated()
            if let message = onSave(validated) {
                validationMessage = message
            } else {
                dismiss()
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func deleteAssignment() {
        guard let assignment, let onDelete else { return }
        if let message = onDelete(assignment) {
            validationMessage = message
        } else {
            dismiss()
        }
    }

    // MARK: Child record loading

    private func loadChildren(assignmentID: Int64) async {
        guard let repository = organizationRepository else { return }
        isLoadingChildren = true
        defer { isLoadingChildren = false }
        do {
            subtasks = try repository.fetchSubtasks(assignmentID: assignmentID, includeDeleted: false)
            reminders = try repository.fetchReminders(assignmentID: assignmentID, includeDeleted: false)
            attachments = try repository.fetchAttachments(assignmentID: assignmentID, includeDeleted: false)
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func addSubtask() async {
        guard let repository = organizationRepository,
              let id = assignment?.id else { return }
        let title = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            let draft = SubtaskDraft(
                assignmentID: id,
                title: title,
                status: .todo,
                sortOrder: subtasks.count
            )
            let created = try repository.createSubtask(draft)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                subtasks.append(created)
                newSubtaskTitle = ""
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func toggleSubtask(_ subtask: AssignmentSubtask) async {
        guard let repository = organizationRepository else { return }
        do {
            var updated = subtask
            updated.status = subtask.status == .done ? .todo : .done
            let saved = try repository.updateSubtask(updated)
            if let index = subtasks.firstIndex(where: { $0.id == saved.id }) {
                subtasks[index] = saved
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func removeSubtask(_ subtask: AssignmentSubtask) async {
        guard let repository = organizationRepository else { return }
        do {
            try repository.deleteSubtask(id: subtask.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                subtasks.removeAll { $0.id == subtask.id }
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func addReminder() async {
        guard let repository = organizationRepository,
              let id = assignment?.id else { return }
        do {
            let draft = ReminderDraft(
                assignmentID: id,
                triggerAtUTC: newReminderDate,
                leadMinutes: newReminderLead,
                repeatRule: newReminderRule.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                isEnabled: newReminderEnabled
            )
            let created = try repository.createReminder(draft)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                reminders.append(created)
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func removeReminder(_ reminder: TaskReminder) async {
        guard let repository = organizationRepository else { return }
        do {
            try repository.deleteReminder(id: reminder.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                reminders.removeAll { $0.id == reminder.id }
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }

    private func importAttachment(_ result: Result<[URL], Error>) async {
        guard let repository = organizationRepository,
              let id = assignment?.id else { return }
        switch result {
        case .failure(let error):
            childErrorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let digest = CryptoKit.SHA256.hash(data: data)
                    .compactMap { String(format: "%02x", $0) }
                    .joined()
                let draft = AttachmentMetadataDraft(
                    assignmentID: id,
                    fileName: url.lastPathComponent,
                    mimeType: nil,
                    byteSize: Int64(data.count),
                    sha256: digest
                )
                let created = try repository.createAttachmentMetadata(draft)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    attachments.append(created)
                }
            } catch {
                childErrorMessage = error.localizedDescription
            }
        }
    }

    private func removeAttachment(_ attachment: AttachmentMetadata) async {
        guard let repository = organizationRepository else { return }
        do {
            try repository.deleteAttachmentMetadata(id: attachment.id)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                attachments.removeAll { $0.id == attachment.id }
            }
        } catch {
            childErrorMessage = error.localizedDescription
        }
    }
}


private struct TagChip: View {
    let tag: AssignmentTag
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let color = tag.colorHex, let ui = Color(hex: color) {
                    Circle()
                        .fill(ui)
                        .frame(width: 12, height: 12)
                }
                Text(tag.name)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}


private struct SubtaskRow: View {
    let subtask: AssignmentSubtask
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: subtask.status == .done
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(subtask.status == .done ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)

            Text(subtask.title)
                .strikethrough(subtask.status == .done)
                .foregroundStyle(subtask.status == .done ? .secondary : .primary)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        }
    }
}


private struct ReminderRow: View {
    let reminder: TaskReminder
    let onDelete: () -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.isEnabled ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(reminder.isEnabled ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.formatter.string(from: reminder.triggerAtUTC))
                if reminder.leadMinutes > 0 {
                    Text("Lead \(reminder.leadMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        }
    }
}


private struct AttachmentRow: View {
    let attachment: AttachmentMetadata
    let onDelete: () -> Void

    static let byteFormatter = ByteCountFormatter()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(1)
                Text(Self.byteFormatter.string(fromByteCount: attachment.byteSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        }
    }
}


private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
