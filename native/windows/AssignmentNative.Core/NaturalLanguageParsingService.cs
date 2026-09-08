namespace AssignmentNative.Core;

public enum ScheduleParsingFailure
{
    NotConfigured,
    InvalidConfiguration,
    Network,
    Unauthorized,
    RateLimited,
    Rejected,
    Server,
    InvalidResponse
}

public sealed class ScheduleParsingProviderException : Exception
{
    public ScheduleParsingFailure Failure { get; }

    public ScheduleParsingProviderException(
        ScheduleParsingFailure failure,
        string message,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
    }
}

public interface IScheduleParsingProvider
{
    string Name { get; }

    Task<NaturalLanguageParseResult> ParseAsync(
        string text,
        DateTimeOffset referenceTime,
        CancellationToken cancellationToken = default);
}

public sealed record NaturalLanguageParsingOutcome(
    NaturalLanguageParseResult Result,
    string ProviderName,
    bool FallbackUsed,
    ScheduleParsingFailure? FallbackFailure = null);

public sealed class NaturalLanguageParsingService
{
    private readonly NaturalLanguageScheduleParser _offlineParser;

    public NaturalLanguageParsingService(NaturalLanguageScheduleParser? offlineParser = null)
    {
        _offlineParser = offlineParser ?? new NaturalLanguageScheduleParser();
    }

    public async Task<NaturalLanguageParsingOutcome> ParseAsync(
        string text,
        DateTimeOffset referenceTime,
        NaturalLanguageParserMode mode,
        IScheduleParsingProvider? apiProvider,
        CancellationToken cancellationToken = default)
    {
        if (mode == NaturalLanguageParserMode.OfflineRules)
        {
            return Offline(text, referenceTime, fallbackUsed: false, failure: null);
        }

        if (apiProvider is null)
        {
            if (mode == NaturalLanguageParserMode.CloudApi)
            {
                throw new ScheduleParsingProviderException(
                    ScheduleParsingFailure.NotConfigured,
                    "The schedule parsing API is not configured.");
            }
            return Offline(
                text,
                referenceTime,
                fallbackUsed: true,
                ScheduleParsingFailure.NotConfigured);
        }

        try
        {
            var result = await apiProvider.ParseAsync(
                text,
                referenceTime,
                cancellationToken);
            return new NaturalLanguageParsingOutcome(
                result,
                apiProvider.Name,
                FallbackUsed: false);
        }
        catch (ScheduleParsingProviderException error)
            when (mode == NaturalLanguageParserMode.Auto)
        {
            return Offline(text, referenceTime, fallbackUsed: true, error.Failure);
        }
    }

    private NaturalLanguageParsingOutcome Offline(
        string text,
        DateTimeOffset referenceTime,
        bool fallbackUsed,
        ScheduleParsingFailure? failure) => new(
            _offlineParser.Parse(text, referenceTime),
            "rule",
            fallbackUsed,
            failure);
}
