using System.Globalization;
using System.Text.RegularExpressions;

namespace AssignmentNative.Core;

public static partial class LocalWallTime
{
    public static TimeZoneInfo ResolveTimeZone(string? ianaIdentifier)
    {
        if (ianaIdentifier is null) return TimeZoneInfo.Local;
        if (!SchemaV3Contract.IsIanaTimeZoneId(ianaIdentifier))
            throw new ArgumentException("timezone_id must use valid IANA syntax.");
        if (ianaIdentifier == "UTC") return TimeZoneInfo.Utc;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                if (!TimeZoneInfo.TryConvertIanaIdToWindowsId(ianaIdentifier, out var windowsId))
                    throw new TimeZoneNotFoundException();
                return TimeZoneInfo.FindSystemTimeZoneById(windowsId);
            }
            return TimeZoneInfo.FindSystemTimeZoneById(ianaIdentifier);
        }
        catch (Exception error) when (
            error is TimeZoneNotFoundException or InvalidTimeZoneException)
        {
            throw new ArgumentException(
                $"timezone_id '{ianaIdentifier}' is not installed or is invalid.",
                nameof(ianaIdentifier),
                error);
        }
    }

    public static DateTimeOffset? ParseLegacy(string? value, TimeZoneInfo timeZone)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var trimmed = value.Trim();
        if (ContainsOffset(trimmed))
            throw new InvalidDataException(
                $"due_date '{trimmed}' contains a UTC marker or offset; local wall time is required.");
        var match = WallTimeRegex().Match(trimmed);
        if (!match.Success) throw new InvalidDataException($"Invalid local due_date '{trimmed}'.");

        var year = Number(match, "year");
        var month = Number(match, "month");
        var day = Number(match, "day");
        var hour = Number(match, "hour");
        var minute = Number(match, "minute");
        var second = match.Groups["second"].Success ? Number(match, "second") : 0;
        DateTime local;
        try
        {
            local = new DateTime(year, month, day, hour, minute, second, DateTimeKind.Unspecified);
        }
        catch (ArgumentOutOfRangeException error)
        {
            throw new InvalidDataException($"Invalid local due_date '{trimmed}'.", error);
        }

        var result = FromLocalDateTime(local, timeZone);
        var fraction = match.Groups["fraction"].Value;
        if (fraction.Length > 0)
        {
            var ticks = long.Parse(fraction.PadRight(7, '0'), CultureInfo.InvariantCulture);
            result = result.AddTicks(ticks);
        }
        return result;
    }

    public static DateTimeOffset FromLocalDateTime(
        DateTime localDateTime,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var local = DateTime.SpecifyKind(localDateTime, DateTimeKind.Unspecified);
        // Match Foundation's next-time-preserving-smaller-components policy:
        // 02:30 inside a one-hour gap becomes 03:30, rather than disappearing.
        while (timeZone.IsInvalidTime(local)) local = local.AddHours(1);
        var offset = timeZone.IsAmbiguousTime(local)
            ? timeZone.GetAmbiguousTimeOffsets(local).Max()
            : timeZone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset);
    }

    public static string Format(DateTimeOffset value, TimeZoneInfo timeZone) =>
        TimeZoneInfo.ConvertTime(value, timeZone)
            .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    public static string? StoredText(
        DateTimeOffset? value,
        string? originalText,
        DateTimeOffset? originalValue,
        TimeZoneInfo timeZone)
    {
        if (originalText is not null && originalValue == value) return originalText;
        if (value is null) return null;
        return Format(value.Value, timeZone);
    }

    private static int Number(Match match, string group) =>
        int.Parse(match.Groups[group].Value, NumberStyles.None, CultureInfo.InvariantCulture);

    private static bool ContainsOffset(string value)
    {
        var separator = Math.Max(value.IndexOf('T'), value.IndexOf(' '));
        if (value.EndsWith("Z", StringComparison.OrdinalIgnoreCase)) return true;
        return separator >= 0 &&
               (value.IndexOf('+', separator) >= 0 || value.IndexOf('-', separator + 1) >= 0);
    }

    [GeneratedRegex(
        "^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})[ T]" +
        "(?<hour>[0-9]{2}):(?<minute>[0-9]{2})(?::(?<second>[0-9]{2})" +
        "(?:\\.(?<fraction>[0-9]{1,6}))?)?$",
        RegexOptions.CultureInvariant)]
    private static partial Regex WallTimeRegex();
}
