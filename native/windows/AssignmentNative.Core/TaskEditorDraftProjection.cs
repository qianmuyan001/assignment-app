namespace AssignmentNative.Core;

/// <summary>
/// Pure projection used by the WinUI editor so fields hidden in the current
/// presentation mode survive unrelated edits.
/// </summary>
public static class TaskEditorDraftProjection
{
    public static AssignmentDraft Apply(
        AssignmentItem? existing,
        string courseName,
        string title,
        DateTimeOffset? dueDate,
        string status,
        string? description,
        string priority,
        string? link)
    {
        var draft = existing is null
            ? new AssignmentDraft()
            : AssignmentDraft.From(existing);
        draft.CourseName = courseName;
        draft.Title = title;
        draft.DueDate = dueDate;
        draft.Status = TaskStatuses.Normalize(status);
        draft.Description = description;
        draft.Priority = TaskPriorities.Normalize(priority);
        draft.Link = link;

        if (existing is not null &&
            !string.Equals(courseName, existing.CourseName, StringComparison.Ordinal))
        {
            draft.CourseId = null;
            draft.ProjectId = null;
        }

        // A status command owns its derived progress/completion transition.
        // Reusing the old percentage would make todo -> done (0) and
        // done -> in-progress (100) internally contradictory.
        if (existing is not null && draft.Status != existing.Status)
        {
            draft.ProgressPercent = null;
        }
        return draft;
    }
}
