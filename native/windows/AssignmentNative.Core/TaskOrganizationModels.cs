namespace AssignmentNative.Core;

public static class ProjectStatuses
{
    public const string Active = "active";
    public const string OnHold = "on_hold";
    public const string Completed = "completed";
    public const string Archived = "archived";
    public static IReadOnlyList<string> All { get; } = [Active, OnHold, Completed, Archived];
    public static string Normalize(string value)
    {
        var normalized = value.Trim().ToLowerInvariant();
        return All.Contains(normalized, StringComparer.Ordinal)
            ? normalized
            : throw new ArgumentOutOfRangeException(nameof(value));
    }
}

public sealed record CourseItem(
    long Id,
    string Uuid,
    string Name,
    string NormalizedName,
    string? ColorHex,
    string? Teacher,
    string? Semester,
    bool IsArchived,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record ProjectItem(
    long Id,
    string Uuid,
    long? CourseId,
    string Name,
    string? Description,
    string Status,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record TagItem(
    long Id,
    string Uuid,
    string Name,
    string NormalizedName,
    string? ColorHex,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record TaskTagItem(
    long Id,
    string Uuid,
    long AssignmentId,
    long TagId,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record SubtaskItem(
    long Id,
    string Uuid,
    long AssignmentId,
    string Title,
    string Status,
    int SortOrder,
    DateTimeOffset? CompletedAt,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record AttachmentMetadataItem(
    long Id,
    string Uuid,
    long AssignmentId,
    string FileName,
    string RelativePath,
    string? MimeType,
    long ByteSize,
    string Sha256,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record ReminderItem(
    long Id,
    string Uuid,
    long AssignmentId,
    DateTimeOffset TriggerAtUtc,
    int LeadMinutes,
    string? RepeatRule,
    bool IsEnabled,
    DateTimeOffset? LastScheduledAt,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    DateTimeOffset? DeletedAt);

public sealed record CourseDraft(
    string Name,
    string? ColorHex = null,
    string? Teacher = null,
    string? Semester = null,
    bool IsArchived = false);

public sealed record ProjectDraft(
    string Name,
    long? CourseId = null,
    string? Description = null,
    string Status = ProjectStatuses.Active);

public sealed record TagDraft(string Name, string? ColorHex = null);

public sealed record SubtaskDraft(
    long AssignmentId,
    string Title,
    string Status = TaskStatuses.Todo,
    int SortOrder = 0);

public sealed record AttachmentMetadataDraft(
    long AssignmentId,
    string FileName,
    string? MimeType,
    long ByteSize,
    string Sha256,
    string? Uuid = null);

public sealed record ReminderDraft(
    long AssignmentId,
    DateTimeOffset TriggerAtUtc,
    int LeadMinutes = 0,
    string? RepeatRule = null,
    bool IsEnabled = true,
    DateTimeOffset? LastScheduledAt = null);

public sealed class OrganizationRepositoryException : Exception
{
    public OrganizationRepositoryException(string message) : base(message) { }
}
