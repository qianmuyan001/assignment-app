import SwiftUI


/// The restrained summary at the top of Today.
///
/// It only points at things that exist elsewhere — the timetable, the exam
/// list, and the task list — and every button goes somewhere real.
struct TodayOverviewCard: View {
    let overview: TodayOverview
    let displayMode: DisplayMode
    let courseName: (Int64) -> String
    let onOpenTask: (Assignment) -> Void
    let onShowTimetable: () -> Void
    let onShowExams: () -> Void
    let onShowOverdue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group(
                title: "Classes Today",
                systemImage: "calendar.day.timeline.leading",
                tint: .blue,
                action: onShowTimetable,
                actionLabel: "Open Timetable"
            ) {
                if overview.meetings.isEmpty {
                    hint("No classes today.")
                } else {
                    ForEach(overview.meetings) { meeting in
                        row(
                            systemImage: "clock",
                            text: "\(MeetingFormatting.timeRange(meeting)) · \(courseName(meeting.courseID))",
                            detail: meeting.location.nilIfBlank
                        )
                    }
                }
            }

            Divider()

            group(
                title: "Exams Soon",
                systemImage: "graduationcap",
                tint: .purple,
                action: onShowExams,
                actionLabel: "Open Exams"
            ) {
                if overview.exams.isEmpty {
                    hint("No exams in the next 14 days.")
                } else {
                    ForEach(overview.exams) { exam in
                        row(
                            systemImage: "calendar.badge.clock",
                            text: "\(exam.name) · \(ExamFormatting.startsAtText(exam))",
                            detail: ExamFormatting.relativeText(exam)
                        )
                    }
                }
            }

            Divider()

            group(
                title: "Due Today",
                systemImage: "checkmark.circle",
                tint: .green,
                action: nil,
                actionLabel: nil
            ) {
                if overview.dueToday.isEmpty {
                    hint("Nothing due today.")
                } else {
                    ForEach(overview.dueToday) { assignment in
                        taskRow(assignment, tint: .primary)
                    }
                }
            }

            Divider()

            group(
                title: "Overdue",
                systemImage: "exclamationmark.triangle",
                tint: .red,
                action: overview.overdue.isEmpty ? nil : onShowOverdue,
                actionLabel: overview.overdue.isEmpty ? nil : "Show Overdue"
            ) {
                if overview.overdue.isEmpty {
                    hint("Nothing overdue.")
                } else {
                    ForEach(overview.overdue) { assignment in
                        taskRow(assignment, tint: .red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: Pieces

    private func group<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        action: (() -> Void)?,
        actionLabel: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)

                Spacer(minLength: 8)

                if let action, let actionLabel {
                    Button(actionLabel, action: action)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .frame(minHeight: 32)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func row(
        systemImage: String,
        text: String,
        detail: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.subheadline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }

    private func taskRow(_ assignment: Assignment, tint: Color) -> some View {
        Button {
            onOpenTask(assignment)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: assignment.status.systemImage)
                    .foregroundStyle(assignment.status == .done ? .green : tint)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assignment.title)
                        .font(.subheadline)
                        .strikethrough(assignment.status == .done)
                    if displayMode == .professional,
                       let dueDate = assignment.dueDate {
                        Text(dueDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.tr("%1$@, %2$@", assignment.title, assignment.status.localizedTitle)
        )
    }
}


private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
