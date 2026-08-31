import SwiftUI


/// Professional-mode surface for managing Courses, Projects, and Tags.
/// It is a thin SwiftUI consumer of `OrganizationRepository` (the same
/// Phase 1 data layer the backend and Web client use) and never fabricates
/// data — every row is read through the repository.
struct OrganizationManagerView: View {
    let repository: OrganizationRepository?

    @Environment(\.dismiss) private var dismiss
    @State private var selection: OrgTab = .courses
    @State private var errorMessage: String?

    init(repository: OrganizationRepository?) {
        self.repository = repository
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Category", selection: $selection) {
                    ForEach(OrgTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 12)

                Divider()

                switch selection {
                case .courses:
                    CourseManager(repository: repository)
                case .projects:
                    ProjectManager(repository: repository)
                case .tags:
                    TagManager(repository: repository)
                }
            }
            .navigationTitle("Manage Organization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .environment(\.organizationError, present)
            .alert(
                "Couldn’t update organization",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    func present(_ message: String) {
        errorMessage = message
    }
}


enum OrgTab: String, CaseIterable, Identifiable {
    case courses
    case projects
    case tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .courses:
            return "Courses"
        case .projects:
            return "Projects"
        case .tags:
            return "Tags"
        }
    }
}


// MARK: - Courses

private struct CourseManager: View {
    let repository: OrganizationRepository?

    @State private var courses: [Course] = []
    @State private var draftName = ""
    @State private var draftTeacher = ""
    @State private var draftSemester = ""
    @State private var draftColorHex = ""
    @State private var draftIsArchived = false
    @State private var editingID: Int64?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @Environment(\.organizationError) private var presentError

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OrgFormCard {
                    TextField("Course name", text: $draftName)
                        .textInputAutocapitalization(.words)
                    TextField("Teacher (optional)", text: $draftTeacher)
                    TextField("Semester (optional)", text: $draftSemester)
                    TextField("Color #RRGGBB (optional)", text: $draftColorHex)
                        .textInputAutocapitalization(.characters)
                    Toggle("Archived", isOn: $draftIsArchived)

                    HStack {
                        Button(action: commit) {
                            Label(editingID == nil ? "Add Course" : "Save Changes",
                                  systemImage: editingID == nil ? "plus" : "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)

                        if editingID != nil {
                            Button("Cancel", role: .cancel, action: resetForm)
                        }
                    }
                }

                LazyVStack(spacing: 10) {
                    ForEach(courses) { course in
                        CourseRow(
                            course: course,
                            onEdit: { beginEdit(course) },
                            onDelete: { Task { await remove(course) } }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .task { await reload() }
    }

    private func beginEdit(_ course: Course) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = course.id
            draftName = course.name
            draftTeacher = course.teacher ?? ""
            draftSemester = course.semester ?? ""
            draftColorHex = course.colorHex ?? ""
            draftIsArchived = course.isArchived
        }
    }

    private func resetForm() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = nil
            draftName = ""
            draftTeacher = ""
            draftSemester = ""
            draftColorHex = ""
            draftIsArchived = false
        }
    }

    private func commit() {
        guard let repository else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let draft = CourseDraft(
                name: name,
                colorHex: draftColorHex.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                teacher: draftTeacher.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                semester: draftSemester.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                isArchived: draftIsArchived
            )
            if let id = editingID {
                var course = try repository.fetchCourses(includeDeleted: true).first(where: { $0.id == id })
                course?.name = draft.name
                course?.colorHex = draft.colorHex
                course?.teacher = draft.teacher
                course?.semester = draft.semester
                course?.isArchived = draft.isArchived
                if let course {
                    _ = try repository.updateCourse(course)
                }
            } else {
                _ = try repository.createCourse(draft)
            }
            resetForm()
            Task { await reload() }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func remove(_ course: Course) async {
        guard let repository else { return }
        do {
            try repository.deleteCourse(id: course.id)
            await reload()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func reload() async {
        guard let repository else { return }
        do {
            courses = try repository.fetchCourses(includeDeleted: false)
        } catch {
            presentError(error.localizedDescription)
        }
    }
}


private struct CourseRow: View {
    let course: Course
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let color = course.colorHex, let ui = Color(hex: color) {
                Circle()
                    .fill(ui)
                    .frame(width: 16, height: 16)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.headline)
                if let detail = [course.teacher, course.semester]
                    .compactMap({ $0?.nilIfEmpty })
                    .joined(separator: " · ")
                    .nilIfEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if course.isArchived {
                Text("Archived")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Edit course")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Delete course")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}


// MARK: - Projects

private struct ProjectManager: View {
    let repository: OrganizationRepository?

    @State private var projects: [AssignmentProject] = []
    @State private var courses: [Course] = []
    @State private var draftName = ""
    @State private var draftCourseID: Int64?
    @State private var draftDescription = ""
    @State private var draftStatus: ProjectStatus = .active
    @State private var editingID: Int64?
    @State private var isBusy = false
    @Environment(\.organizationError) private var presentError

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OrgFormCard {
                    TextField("Project name", text: $draftName)
                        .textInputAutocapitalization(.words)
                    Picker("Course (optional)", selection: $draftCourseID) {
                        Text("None").tag(Optional<Int64>.none)
                        ForEach(courses) { course in
                            Text(course.name).tag(Optional(course.id))
                        }
                    }
                    TextField("Description (optional)", text: $draftDescription, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Status", selection: $draftStatus) {
                        ForEach(ProjectStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Button(action: commit) {
                            Label(editingID == nil ? "Add Project" : "Save Changes",
                                  systemImage: editingID == nil ? "plus" : "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)

                        if editingID != nil {
                            Button("Cancel", role: .cancel, action: resetForm)
                        }
                    }
                }

                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        ProjectRow(
                            project: project,
                            courseName: courses.first(where: { $0.id == project.courseID })?.name,
                            onEdit: { beginEdit(project) },
                            onDelete: { Task { await remove(project) } }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .task { await reload() }
    }

    private var filteredCourses: [Course] { courses }

    private func beginEdit(_ project: AssignmentProject) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = project.id
            draftName = project.name
            draftCourseID = project.courseID
            draftDescription = project.projectDescription ?? ""
            draftStatus = project.status
        }
    }

    private func resetForm() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = nil
            draftName = ""
            draftCourseID = nil
            draftDescription = ""
            draftStatus = .active
        }
    }

    private func commit() {
        guard let repository else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let draft = ProjectDraft(
                courseID: draftCourseID,
                name: name,
                projectDescription: draftDescription.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                status: draftStatus
            )
            if let id = editingID {
                var project = try repository.fetchProjects(
                    courseID: nil,
                    includeDeleted: true
                ).first(where: { $0.id == id })
                project?.name = draft.name
                project?.courseID = draft.courseID
                project?.projectDescription = draft.projectDescription
                project?.status = draft.status
                if let project {
                    _ = try repository.updateProject(project)
                }
            } else {
                _ = try repository.createProject(draft)
            }
            resetForm()
            Task { await reload() }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func remove(_ project: AssignmentProject) async {
        guard let repository else { return }
        do {
            try repository.deleteProject(id: project.id)
            await reload()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func reload() async {
        guard let repository else { return }
        do {
            courses = try repository.fetchCourses(includeDeleted: false)
            projects = try repository.fetchProjects(
                courseID: nil,
                includeDeleted: false
            )
        } catch {
            presentError(error.localizedDescription)
        }
    }
}


private struct ProjectRow: View {
    let project: AssignmentProject
    let courseName: String?
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(project.status.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if let courseName {
                        Text(courseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Edit project")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Delete project")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}


// MARK: - Tags

private struct TagManager: View {
    let repository: OrganizationRepository?

    @State private var tags: [AssignmentTag] = []
    @State private var draftName = ""
    @State private var draftColorHex = ""
    @State private var editingID: Int64?
    @State private var isBusy = false
    @Environment(\.organizationError) private var presentError

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OrgFormCard {
                    TextField("Tag name", text: $draftName)
                        .textInputAutocapitalization(.words)
                    TextField("Color #RRGGBB (optional)", text: $draftColorHex)
                        .textInputAutocapitalization(.characters)

                    HStack {
                        Button(action: commit) {
                            Label(editingID == nil ? "Add Tag" : "Save Changes",
                                  systemImage: editingID == nil ? "plus" : "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)

                        if editingID != nil {
                            Button("Cancel", role: .cancel, action: resetForm)
                        }
                    }
                }

                LazyVStack(spacing: 10) {
                    ForEach(tags) { tag in
                        TagRow(
                            tag: tag,
                            onEdit: { beginEdit(tag) },
                            onDelete: { Task { await remove(tag) } }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .task { await reload() }
    }

    private func beginEdit(_ tag: AssignmentTag) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = tag.id
            draftName = tag.name
            draftColorHex = tag.colorHex ?? ""
        }
    }

    private func resetForm() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            editingID = nil
            draftName = ""
            draftColorHex = ""
        }
    }

    private func commit() {
        guard let repository else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let draft = TagDraft(
                name: name,
                colorHex: draftColorHex.trimmingCharacters(in: .whitespaces).nilIfEmpty
            )
            if let id = editingID {
                var tag = try repository.fetchTags(includeDeleted: true).first(where: { $0.id == id })
                tag?.name = draft.name
                tag?.colorHex = draft.colorHex
                if let tag {
                    _ = try repository.updateTag(tag)
                }
            } else {
                _ = try repository.createTag(draft)
            }
            resetForm()
            Task { await reload() }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func remove(_ tag: AssignmentTag) async {
        guard let repository else { return }
        do {
            try repository.deleteTag(id: tag.id)
            await reload()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func reload() async {
        guard let repository else { return }
        do {
            tags = try repository.fetchTags(includeDeleted: false)
        } catch {
            presentError(error.localizedDescription)
        }
    }
}


private struct TagRow: View {
    let tag: AssignmentTag
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let color = tag.colorHex, let ui = Color(hex: color) {
                Circle()
                    .fill(ui)
                    .frame(width: 16, height: 16)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 16, height: 16)
            }

            Text(tag.name)
                .font(.headline)

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Edit tag")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help("Delete tag")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}


// MARK: - Shared helpers

private struct OrgFormCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
            )
            .padding(.horizontal)
    }
}


private struct OrganizationErrorKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}


extension EnvironmentValues {
    var organizationError: (String) -> Void {
        get { self[OrganizationErrorKey.self] }
        set { self[OrganizationErrorKey.self] = newValue }
    }
}


extension ProjectStatus {
    var title: String {
        switch self {
        case .active:
            return "Active"
        case .onHold:
            return "On Hold"
        case .completed:
            return "Completed"
        case .archived:
            return "Archived"
        }
    }
}


extension Color {
    /// Parses a `#RRGGBB` (or `RRGGBB`) string into a `Color`, or `nil` when
    /// the string is not a valid six-digit hex color.
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6,
              let value = UInt64(trimmed, radix: 16) else {
            return nil
        }
        let red = Double((value & 0xFF0000) >> 16) / 255.0
        let green = Double((value & 0x00FF00) >> 8) / 255.0
        let blue = Double(value & 0x0000FF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}


private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
