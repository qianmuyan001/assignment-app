using System.Text.Json.Serialization;

namespace AssignmentNative.Core;

public static class TaskStatuses
{
    public const string Todo = "todo";
    public const string InProgress = "in_progress";
    public const string Done = "done";

    public static IReadOnlyList<string> All { get; } = [Todo, InProgress, Done];

    public static bool IsValid(string? value) =>
        value is not null && All.Contains(value, StringComparer.OrdinalIgnoreCase);

    public static string Normalize(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        Todo or "not_started" => Todo,
        InProgress => InProgress,
        Done or "completed" => Done,
        _ => throw new ArgumentOutOfRangeException(
            nameof(value),
            value,
            $"Status must be one of: {string.Join(", ", All)}.")
    };

    public static string FromDatabaseStatus(string value) => Normalize(value);

    public static string ToDatabaseStatus(string value) => Normalize(value) switch
    {
        Todo => "not_started",
        InProgress => "in_progress",
        Done => "completed",
        _ => throw new InvalidOperationException("Unexpected normalized status.")
    };
}

public static class TaskPriorities
{
    public const string Low = "low";
    public const string Medium = "medium";
    public const string High = "high";

    public static IReadOnlyList<string> All { get; } = [Low, Medium, High];

    public static bool IsValid(string? value) =>
        value is not null && All.Contains(value, StringComparer.OrdinalIgnoreCase);

    public static string Normalize(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        Low => Low,
        Medium => Medium,
        High => High,
        _ => throw new ArgumentOutOfRangeException(
            nameof(value),
            value,
            $"Priority must be one of: {string.Join(", ", All)}.")
    };

    public static int Rank(string value) => Normalize(value) switch
    {
        High => 3,
        Medium => 2,
        Low => 1,
        _ => 0
    };
}

public class AssignmentItem
{
    public long Id { get; init; }
    public string Uuid { get; init; } = "";
    public string CourseName { get; init; } = "";
    public string Title { get; init; } = "";
    public DateTimeOffset? DueDate { get; init; }
    public string? Description { get; init; }
    public string? Link { get; init; }
    public string Status { get; init; } = TaskStatuses.Todo;
    public string Priority { get; init; } = TaskPriorities.Medium;
    public string? SourceName { get; init; }
    public string? SourceType { get; init; }
    public string? SourceFile { get; init; }
    public string? SourceUrl { get; init; }
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset UpdatedAt { get; init; }
    public long? CourseId { get; init; }
    public long? ProjectId { get; init; }
    public DateTimeOffset? CompletedAt { get; init; }
    public int ProgressPercent { get; init; }
    public bool AllDay { get; init; }
    public string? TimezoneId { get; init; }
    public DateTimeOffset? DeletedAt { get; init; }
    public string? StoredDueDateText { get; init; }
    public DateTimeOffset? StoredDueDateValue { get; init; }
}

public sealed class AssignmentDraft
{
    public string CourseName { get; set; } = "";
    public string Title { get; set; } = "";
    public DateTimeOffset? DueDate { get; set; }
    public string? Description { get; set; }
    public string? Link { get; set; }
    public string Status { get; set; } = TaskStatuses.Todo;
    public string Priority { get; set; } = TaskPriorities.Medium;
    public string? SourceName { get; set; }
    public string? SourceType { get; set; } = "manual";
    public string? SourceFile { get; set; }
    public string? SourceUrl { get; set; }
    public long? CourseId { get; set; }
    public long? ProjectId { get; set; }
    public int? ProgressPercent { get; set; }
    public bool AllDay { get; set; }
    public string? TimezoneId { get; set; }
    public string? StoredDueDateText { get; set; }
    public DateTimeOffset? StoredDueDateValue { get; set; }

    public static AssignmentDraft From(AssignmentItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return new AssignmentDraft
        {
            CourseName = item.CourseName,
            Title = item.Title,
            DueDate = item.DueDate,
            Description = item.Description,
            Link = item.Link,
            Status = item.Status,
            Priority = item.Priority,
            SourceName = item.SourceName,
            SourceType = item.SourceType,
            SourceFile = item.SourceFile,
            SourceUrl = item.SourceUrl,
            CourseId = item.CourseId,
            ProjectId = item.ProjectId,
            ProgressPercent = item.ProgressPercent,
            AllDay = item.AllDay,
            TimezoneId = item.TimezoneId,
            StoredDueDateText = item.StoredDueDateText,
            StoredDueDateValue = item.StoredDueDateValue
        };
    }
}

public class AssignmentCandidate
{
    [JsonPropertyName("course_name")]
    public string? CourseName { get; set; }

    [JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [JsonPropertyName("due_date")]
    public string? DueDate { get; set; }

    [JsonPropertyName("due_time")]
    public string? DueTime { get; set; }

    [JsonPropertyName("description")]
    public string? Description { get; set; }

    [JsonPropertyName("source_name")]
    public string? SourceName { get; set; }

    [JsonPropertyName("source_url")]
    public string? SourceUrl { get; set; }

    [JsonPropertyName("priority")]
    public string? Priority { get; set; }

    [JsonPropertyName("confidence")]
    public string Confidence { get; set; } = "low";

    [JsonPropertyName("warnings")]
    public List<string> Warnings { get; set; } = [];
}

public enum AssignmentView
{
    All,
    Today,
    ThisWeek,
    Overdue,
    Completed
}

public enum AssignmentSort
{
    DueDateAscending,
    DueDateDescending,
    PriorityDescending,
    PriorityAscending
}

public sealed class AssignmentQuery
{
    public AssignmentView View { get; set; } = AssignmentView.All;
    public string? Search { get; set; }
    public string? Status { get; set; }
    public string? Course { get; set; }
    public string? Priority { get; set; }
    public AssignmentSort Sort { get; set; } = AssignmentSort.DueDateAscending;
    public DateTimeOffset? Now { get; set; }
    public TimeZoneInfo? TimeZone { get; set; }
}

public enum AssignmentDisplayMode
{
    Simple,
    Professional
}

public enum AppTheme
{
    System,
    Light,
    Dark
}

public enum NavigationPaneMode
{
    Expanded,
    Compact
}

public enum AppLanguage
{
    English,
    SimplifiedChinese
}

public sealed class AppSettings
{
    public AssignmentDisplayMode DetailMode { get; set; } = AssignmentDisplayMode.Simple;
    public AppTheme Theme { get; set; } = AppTheme.System;
    public NavigationPaneMode NavigationPaneMode { get; set; } = NavigationPaneMode.Expanded;
    public AppLanguage Language { get; set; } = AppLanguage.English;
}
