using System.Text.Json.Serialization;
using Microsoft.UI;
using Microsoft.UI.Xaml.Media;

namespace AssignmentNative;

public sealed class AssignmentItem
{
    public long Id { get; init; }
    public string CourseName { get; init; } = "";
    public string Title { get; init; } = "";
    public DateTimeOffset? DueDate { get; init; }
    public string? Description { get; init; }
    public string? Link { get; init; }
    public string Status { get; init; } = "not_started";
    public string? SourceName { get; init; }
    public string? SourceUrl { get; init; }

    public string StatusDisplay => Status switch
    {
        "in_progress" => "In progress",
        "completed" => "Completed",
        _ => "Not started"
    };

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
            var color = Status == "completed"
                ? Colors.MediumSeaGreen
                : DueDate is not null && DueDate < DateTimeOffset.Now
                    ? Colors.IndianRed
                    : Status == "in_progress"
                        ? Colors.DodgerBlue
                        : Colors.MediumPurple;
            return new SolidColorBrush(color);
        }
    }
}

public sealed class AssignmentCandidate
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

    [JsonPropertyName("confidence")]
    public string Confidence { get; set; } = "low";

    [JsonPropertyName("warnings")]
    public List<string> Warnings { get; set; } = [];

    public string DueDisplay =>
        $"{DueDate ?? "Unknown date"} {DueTime ?? ""}".Trim();

    public string CourseDisplay => string.IsNullOrWhiteSpace(CourseName)
        ? "Imported"
        : CourseName!;
}

public sealed class CandidateEnvelope
{
    [JsonPropertyName("assignments")]
    public List<AssignmentCandidate> Assignments { get; set; } = [];
}

public sealed class CapturedPage
{
    [JsonPropertyName("url")]
    public string Url { get; set; } = "";

    [JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("links")]
    public List<CapturedLink> Links { get; set; } = [];
}

public sealed class CapturedLink
{
    [JsonPropertyName("text")]
    public string Text { get; set; } = "";

    [JsonPropertyName("url")]
    public string Url { get; set; } = "";
}

public sealed record StoredCredential(
    string Origin,
    string Username,
    string Password);
