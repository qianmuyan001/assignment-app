namespace AssignmentNative.Core;

public static class TaskLinkEditorPolicy
{
    public static string? Resolve(
        AssignmentItem? existing,
        bool professionalMode,
        string? enteredValue)
    {
        if (!professionalMode)
            return existing?.Link;
        if (existing is not null &&
            string.Equals(enteredValue, existing.Link, StringComparison.Ordinal))
        {
            return existing.Link;
        }
        var value = Clean(enteredValue);
        if (value is not null &&
            (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
             uri.Scheme is not ("http" or "https")))
        {
            throw new ArgumentException(
                "Source link must be a complete http or https URL.",
                nameof(enteredValue));
        }
        return value;
    }

    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
