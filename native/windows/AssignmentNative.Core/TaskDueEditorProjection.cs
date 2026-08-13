namespace AssignmentNative.Core;

public readonly record struct TaskDueControlState(
    bool HasDueDate,
    DateOnly? Date,
    TimeSpan Time);

/// <summary>
/// Keeps the loaded database value when WinUI controls are visually unchanged.
/// This prevents a minute-granularity TimePicker from truncating legacy seconds
/// or fractional seconds during an unrelated edit.
/// </summary>
public static class TaskDueEditorProjection
{
    public static DateTimeOffset? Resolve(
        AssignmentItem? existing,
        TaskDueControlState loaded,
        TaskDueControlState current,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        if (existing is not null && current == loaded)
            return existing.DueDate;
        if (!current.HasDueDate)
            return null;
        var date = current.Date
            ?? throw new ArgumentException("A selected due date is required.", nameof(current));
        if (current.Time < TimeSpan.Zero || current.Time >= TimeSpan.FromDays(1))
            throw new ArgumentOutOfRangeException(nameof(current), "Due time must be within one day.");
        return LocalWallTime.FromLocalDateTime(
            date.ToDateTime(TimeOnly.MinValue) + current.Time,
            timeZone);
    }
}
