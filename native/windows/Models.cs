using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using CoreAssignmentCandidate = AssignmentNative.Core.AssignmentCandidate;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative;

public sealed class AssignmentItem : CoreAssignmentItem
{
    public string StatusDisplay => Status switch
    {
        "in_progress" => "In progress",
        "done" => "Done",
        _ => "To do"
    };

    public string PriorityDisplay => char.ToUpperInvariant(Priority[0]) + Priority[1..];

    public string DueDisplay => DueDate is null
        ? "No due date"
        : DueDate.Value.ToLocalTime().ToString("ddd, MMM d · h:mm tt");

    public string SourceDisplay => string.IsNullOrWhiteSpace(SourceName)
        ? "Manual"
        : SourceName!;

    public SolidColorBrush AccentBrush
    {
        get
        {
            var color = Status == "done"
                ? Colors.MediumSeaGreen
                : DueDate is not null && DueDate < DateTimeOffset.Now
                    ? Colors.IndianRed
                    : Status == "in_progress"
                        ? Colors.DodgerBlue
                        : Colors.MediumPurple;
            return new SolidColorBrush(color);
        }
    }

    public static AssignmentItem FromCore(CoreAssignmentItem item) => new()
    {
        Id = item.Id,
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
        CreatedAt = item.CreatedAt,
        UpdatedAt = item.UpdatedAt
    };
}

public sealed class AssignmentCandidate : CoreAssignmentCandidate
{
    public string DueDisplay =>
        $"{DueDate ?? "Unknown date"} {DueTime ?? ""}".Trim();

    public string CourseDisplay => string.IsNullOrWhiteSpace(CourseName)
        ? "Imported"
        : CourseName!;
}

public sealed class CandidateEnvelope
{
    [System.Text.Json.Serialization.JsonPropertyName("assignments")]
    public List<AssignmentCandidate> Assignments { get; set; } = [];
}

public sealed class CapturedPage
{
    [System.Text.Json.Serialization.JsonPropertyName("url")]
    public string Url { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("links")]
    public List<CapturedLink> Links { get; set; } = [];
}

public sealed class CapturedLink
{
    [System.Text.Json.Serialization.JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("url")]
    public string Url { get; set; } = "";
}

public sealed record StoredCredential(
    string Origin,
    string Username,
    string Password);
