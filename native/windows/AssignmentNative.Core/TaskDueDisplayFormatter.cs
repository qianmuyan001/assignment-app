using System.Globalization;

namespace AssignmentNative.Core;

public static class TaskDueDisplayFormatter
{
    public static DateTimeOffset? DisplayValue(AssignmentItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return item.DueDate is { } due
            ? TimeZoneInfo.ConvertTime(due, LocalWallTime.ResolveTimeZone(item.TimezoneId))
            : null;
    }

    public static string Format(AssignmentItem item, IFormatProvider? formatProvider = null)
    {
        var display = DisplayValue(item);
        if (display is null) return "No due date";
        var provider = formatProvider ?? CultureInfo.CurrentCulture;
        return item.AllDay
            ? display.Value.ToString("ddd, MMM d · 'All day'", provider)
            : display.Value.ToString("ddd, MMM d · h:mm tt", provider);
    }
}
