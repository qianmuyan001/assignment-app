import SwiftUI


/// The task calendar: a month grid plus the tasks due on the selected day.
///
/// This is a task view, not a timetable. It groups the same `Assignment`
/// records the list shows by civil day, using `CalendarPlanner`, which shares
/// `TaskRules`' day arithmetic so the calendar and the Today list cannot
/// disagree about the same database.
struct TaskCalendarView: View {
    let assignments: [Assignment]
    let displayMode: DisplayMode
    let isWriteEnabled: Bool
    let onOpenTask: (Assignment) -> Void
    let onQuickAdd: (Date) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AssignmentPreferenceKeys.calendarShowsCompleted)
    private var showsCompleted = true

    @State private var monthReference: Date = Date()
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private let calendar = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            weekdayHeader
            grid
            Divider()
            dayDetail
        }
        .navigationTitle(L10n.tr("Calendar"))
        .toolbar { toolbarContent }
        .onAppear(perform: moveToTodayIfNeeded)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                stepMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help(L10n.tr("Previous month"))
            .accessibilityLabel(L10n.tr("Previous month"))
            .accessibilityIdentifier("calendar-previous-month")

            Text(CalendarPlanner.monthTitle(for: monthReference, calendar: calendar))
                .font(.headline)
                .lineLimit(1)
                .frame(minWidth: 160, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Button {
                stepMonth(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .help(L10n.tr("Next month"))
            .accessibilityLabel(L10n.tr("Next month"))
            .accessibilityIdentifier("calendar-next-month")

            Spacer(minLength: 8)

            Toggle(isOn: $showsCompleted) {
                Label(L10n.tr("Show completed"), systemImage: "checkmark.circle")
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .help(completedToggleHelp)
            .accessibilityLabel(completedToggleHelp)
            .accessibilityIdentifier("calendar-show-completed")

            Button(L10n.tr("Today")) {
                moveToToday()
            }
            .disabled(isViewingCurrentMonth && selectedDay == todayStart)
            .accessibilityIdentifier("calendar-today")
        }
        .font(.body)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var weekdayHeader: some View {
        let titles = CalendarPlanner.shortWeekdayTitles(calendar: calendar)
        return HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: Grid

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: max(1, CalendarPlanner.shortWeekdayTitles(calendar: calendar).count)
        )
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(buckets) { bucket in
                dayCell(bucket)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private func dayCell(_ bucket: CalendarDayBucket) -> some View {
        let isSelected = bucket.day.date == selectedDay
        let count = bucket.tasks.count
        return Button {
            select(bucket.day.date)
        } label: {
            VStack(spacing: 3) {
                Text(dayNumber(bucket.day.date))
                    .font(.system(.body, design: .rounded, weight: bucket.day.isToday ? .bold : .regular))
                    .foregroundStyle(
                        bucket.day.isInDisplayedMonth ? Color.primary : Color.secondary
                    )

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(" ")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }

                statusDots(bucket.tasks)
                    .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 5)
            .background {
                cellBackground(isSelected: isSelected, isToday: bucket.day.isToday)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            CalendarAccessibility.dayLabel(
                day: bucket.day,
                taskCount: count,
                isSelected: isSelected,
                calendar: calendar
            )
        )
        .accessibilityHint(L10n.tr("Shows the tasks due on this day."))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("calendar-day-\(bucket.day.date.timeIntervalSince1970)")
    }

    /// At most three restrained markers: overdue, in progress, done. Their
    /// meaning is also in the accessibility label, so colour is never the only
    /// carrier of state.
    private func statusDots(_ tasks: [Assignment]) -> some View {
        let overdue = tasks.contains { $0.status != .done && isOverdue($0) }
        let inProgress = tasks.contains { $0.status == .inProgress }
        let done = tasks.contains { $0.status == .done }
        return HStack(spacing: 3) {
            if overdue {
                Circle().fill(Color.red).frame(width: 5, height: 5)
            }
            if inProgress {
                Circle().fill(Color.blue).frame(width: 5, height: 5)
            }
            if done {
                Circle().fill(Color.green).frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cellBackground(isSelected: Bool, isToday: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isSelected {
            shape
                .fill(Color.accentColor.opacity(0.18))
                .overlay {
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
        } else if isToday {
            shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        } else {
            shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: Day detail

    private var dayDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dayTitle)
                    .font(.headline)

                Spacer(minLength: 8)

                if isWriteEnabled {
                    Button(L10n.tr("Add Task"), systemImage: "plus") {
                        onQuickAdd(selectedDay)
                    }
                    .disabled(!isWriteEnabled)
                    .help(L10n.tr("Add a task on %@", dayTitle))
                    .accessibilityIdentifier("calendar-add-task")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            if selectedTasks.isEmpty {
                emptyDayState
            } else {
                dayList
            }

            if !undatedTasks.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.minus")
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("%lld tasks have no due date and do not appear on the calendar.", undatedTasks.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var emptyDayState: some View {
        ContentUnavailableView {
            Label(L10n.tr("No Tasks on This Day"), systemImage: "calendar")
        } description: {
            Text(L10n.tr("Tasks due on this day will appear here. Pick another day or add one."))
        } actions: {
            if isWriteEnabled {
                Button(L10n.tr("Add Task"), systemImage: "plus") {
                    onQuickAdd(selectedDay)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dayList: some View {
        List {
            ForEach(selectedTasks) { assignment in
                Button {
                    onOpenTask(assignment)
                } label: {
                    CalendarTaskRow(
                        assignment: assignment,
                        displayMode: displayMode,
                        calendar: calendar
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendar-task-\(assignment.id)")
            }
        }
        .listStyle(.inset)
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isWriteEnabled {
                Button(L10n.tr("Add Task"), systemImage: "plus") {
                    onQuickAdd(selectedDay)
                }
                .help(L10n.tr("Add a task on %@", dayTitle))
            }
        }
    }

    // MARK: Data

    private var buckets: [CalendarDayBucket] {
        CalendarPlanner.buckets(
            for: CalendarPlanner.monthGrid(
                containing: monthReference,
                calendar: calendar,
                now: Date()
            ),
            assignments: assignments,
            calendar: calendar,
            includeCompleted: showsCompleted
        )
    }

    private var selectedTasks: [Assignment] {
        CalendarPlanner.orderedForDay(
            assignments.filter { assignment in
                guard showsCompleted || assignment.status != .done else { return false }
                guard let due = assignment.dueDate else { return false }
                return calendar.startOfDay(for: due) == selectedDay
            }
        )
    }

    private var undatedTasks: [Assignment] {
        CalendarPlanner.undatedTasks(assignments)
    }

    private var todayStart: Date { calendar.startOfDay(for: Date()) }

    private var isViewingCurrentMonth: Bool {
        CalendarPlanner.monthStart(containing: monthReference, calendar: calendar)
            == CalendarPlanner.monthStart(containing: Date(), calendar: calendar)
    }

    private var dayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.calendar = Calendar(identifier: calendar.identifier)
        formatter.setLocalizedDateFormatFromTemplate("EEEE, MMMM d")
        return formatter.string(from: selectedDay)
    }

    private var completedToggleHelp: String {
        showsCompleted
            ? L10n.tr("Completed tasks are shown. Turn this off to hide them.")
            : L10n.tr("Completed tasks are hidden. Turn this on to show them.")
    }

    private func dayNumber(_ date: Date) -> String {
        String(calendar.component(.day, from: date))
    }

    private func isOverdue(_ assignment: Assignment) -> Bool {
        guard let due = assignment.dueDate else { return false }
        return due < Date()
    }

    // MARK: Actions

    private func select(_ date: Date) {
        guard selectedDay != date else { return }
        if reduceMotion {
            selectedDay = date
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedDay = date
            }
        }
    }

    private func stepMonth(_ delta: Int) {
        let next = CalendarPlanner.addingMonths(delta, to: monthReference, calendar: calendar)
        if reduceMotion {
            monthReference = next
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                monthReference = next
            }
        }
        // Keep the selection visible: clamp it into the new month.
        let grid = CalendarPlanner.monthGrid(containing: next, calendar: calendar, now: Date())
        if !grid.contains(where: { $0.date == selectedDay }) {
            let fallback = grid.first(where: { $0.isInDisplayedMonth })
                ?? grid.first
            if let fallback { selectedDay = fallback.date }
        }
    }

    private func moveToToday() {
        let today = Date()
        monthReference = today
        selectedDay = calendar.startOfDay(for: today)
    }

    /// Re-anchors on first appearance so a long-running window does not keep
    /// showing a stale month after the device date rolls over.
    private func moveToTodayIfNeeded() {
        guard !CalendarPlanner.monthGrid(
            containing: monthReference,
            calendar: calendar,
            now: Date()
        ).contains(where: { $0.date == selectedDay }) else { return }
        selectedDay = todayStart
        monthReference = Date()
    }
}


/// One task inside the selected day.
private struct CalendarTaskRow: View {
    let assignment: Assignment
    let displayMode: DisplayMode
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: assignment.status.systemImage)
                .foregroundStyle(assignment.status.tint)
                .font(.body)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.title)
                    .font(.body.weight(assignment.status == .done ? .regular : .medium))
                    .strikethrough(assignment.status == .done)
                    .foregroundStyle(assignment.status == .done ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Label(assignment.courseName, systemImage: "book.closed")
                    Text(clockText)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if displayMode == .professional {
                Capsule()
                    .fill(assignment.priority.tint)
                    .frame(width: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.tr(
                "%1$@, %2$@, %3$@, %4$@",
                assignment.title,
                assignment.courseName,
                clockText,
                assignment.status.localizedTitle
            )
        )
    }

    private var clockText: String {
        guard let due = assignment.dueDate else {
            return L10n.tr("No due date")
        }
        let zone = CalendarPlanner.displayTimeZone(for: assignment, calendar: calendar)
        if assignment.allDay {
            return L10n.tr("All day")
        }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = zone
        formatter.calendar = Calendar(identifier: calendar.identifier)
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        let time = formatter.string(from: due)
        return zone == calendar.timeZone
            ? time
            : "\(time) \(zone.abbreviation() ?? zone.identifier)"
    }
}
