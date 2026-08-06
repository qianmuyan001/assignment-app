namespace AssignmentNative.Core;

public static class TaskRules
{
    public static IReadOnlyList<AssignmentItem> Apply(
        IEnumerable<AssignmentItem> assignments,
        AssignmentQuery? query = null)
    {
        ArgumentNullException.ThrowIfNull(assignments);
        query ??= new AssignmentQuery();

        var timeZone = query.TimeZone ?? TimeZoneInfo.Local;
        var now = query.Now ?? DateTimeOffset.Now;
        var search = Clean(query.Search);
        var status = Clean(query.Status) is { } requestedStatus
            ? TaskStatuses.Normalize(requestedStatus)
            : null;
        var priority = Clean(query.Priority) is { } requestedPriority
            ? TaskPriorities.Normalize(requestedPriority)
            : null;
        var course = Clean(query.Course);

        var filtered = assignments.Where(item =>
            MatchesView(item, query.View, now, timeZone) &&
            (status is null || TaskStatuses.Normalize(item.Status) == status) &&
            (priority is null || TaskPriorities.Normalize(item.Priority) == priority) &&
            (course is null || string.Equals(
                item.CourseName.Trim(),
                course,
                StringComparison.OrdinalIgnoreCase)) &&
            (search is null || MatchesSearch(item, search)));

        return Sort(filtered, query.Sort).ToList();
    }

    public static bool IsDueToday(
        AssignmentItem item,
        DateTimeOffset now,
        TimeZoneInfo? timeZone = null)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.DueDate is not { } dueDate)
        {
            return false;
        }

        var zone = timeZone ?? TimeZoneInfo.Local;
        return LocalDate(dueDate, zone) == LocalDate(now, zone);
    }

    public static bool IsDueThisWeek(
        AssignmentItem item,
        DateTimeOffset now,
        TimeZoneInfo? timeZone = null)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.DueDate is not { } dueDate)
        {
            return false;
        }

        var zone = timeZone ?? TimeZoneInfo.Local;
        var today = LocalDate(now, zone);
        var due = LocalDate(dueDate, zone);
        var mondayOffset = ((int)today.DayOfWeek + 6) % 7;
        var weekStart = today.AddDays(-mondayOffset);
        var nextWeekStart = weekStart.AddDays(7);
        return due >= weekStart && due < nextWeekStart;
    }

    public static bool IsOverdue(
        AssignmentItem item,
        DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(item);
        return item.DueDate is { } dueDate &&
            TaskStatuses.Normalize(item.Status) != TaskStatuses.Done &&
            dueDate.ToUniversalTime() < now.ToUniversalTime();
    }

    public static int ComparePriority(string left, string right) =>
        TaskPriorities.Rank(left).CompareTo(TaskPriorities.Rank(right));

    public static string FromDatabaseStatus(string value) =>
        TaskStatuses.FromDatabaseStatus(value);

    public static string ToDatabaseStatus(string value) =>
        TaskStatuses.ToDatabaseStatus(value);

    private static bool MatchesView(
        AssignmentItem item,
        AssignmentView view,
        DateTimeOffset now,
        TimeZoneInfo timeZone) => view switch
        {
            AssignmentView.Today => IsDueToday(item, now, timeZone),
            AssignmentView.ThisWeek => IsDueThisWeek(item, now, timeZone),
            AssignmentView.Overdue => IsOverdue(item, now),
            AssignmentView.Completed =>
                TaskStatuses.Normalize(item.Status) == TaskStatuses.Done,
            _ => true
        };

    private static bool MatchesSearch(AssignmentItem item, string search) =>
        item.Title.Contains(search, StringComparison.OrdinalIgnoreCase) ||
        item.CourseName.Contains(search, StringComparison.OrdinalIgnoreCase) ||
        (item.Description?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false);

    private static IOrderedEnumerable<AssignmentItem> Sort(
        IEnumerable<AssignmentItem> assignments,
        AssignmentSort sort) => sort switch
        {
            AssignmentSort.DueDateDescending => assignments
                .OrderBy(item => item.DueDate is null)
                .ThenByDescending(item => item.DueDate)
                .ThenBy(item => item.Id),
            AssignmentSort.PriorityDescending => assignments
                .OrderByDescending(item => TaskPriorities.Rank(item.Priority))
                .ThenBy(item => item.DueDate is null)
                .ThenBy(item => item.DueDate)
                .ThenBy(item => item.Id),
            AssignmentSort.PriorityAscending => assignments
                .OrderBy(item => TaskPriorities.Rank(item.Priority))
                .ThenBy(item => item.DueDate is null)
                .ThenBy(item => item.DueDate)
                .ThenBy(item => item.Id),
            _ => assignments
                .OrderBy(item => item.DueDate is null)
                .ThenBy(item => item.DueDate)
                .ThenBy(item => item.Id)
        };

    private static DateOnly LocalDate(DateTimeOffset value, TimeZoneInfo timeZone) =>
        DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(value, timeZone).DateTime);

    private static string? Clean(string? value)
    {
        var clean = value?.Trim();
        return string.IsNullOrEmpty(clean) ? null : clean;
    }
}
