import SwiftUI


struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let assignment: Assignment?
    let displayMode: DisplayMode
    let onSave: (AssignmentDraft) -> String?
    let onDelete: ((Assignment) -> String?)?

    @State private var draft: AssignmentDraft
    @State private var hasDueDate: Bool
    @State private var validationMessage: String?
    @State private var isShowingDeleteConfirmation = false

    init(
        assignment: Assignment? = nil,
        displayMode: DisplayMode,
        onSave: @escaping (AssignmentDraft) -> String?,
        onDelete: ((Assignment) -> String?)? = nil
    ) {
        self.assignment = assignment
        self.displayMode = displayMode
        self.onSave = onSave
        self.onDelete = onDelete

        let initialDraft = assignment.map(AssignmentDraft.init(assignment:)) ?? AssignmentDraft()
        _draft = State(initialValue: initialDraft)
        _hasDueDate = State(initialValue: initialDraft.dueDate != nil)
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
}
