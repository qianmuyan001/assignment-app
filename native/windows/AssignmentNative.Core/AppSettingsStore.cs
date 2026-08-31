using System.Text.Json;
using System.Text.Json.Serialization;

namespace AssignmentNative.Core;

public sealed class AppSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseLower) }
    };

    public string SettingsPath { get; }

    public AppSettingsStore(string? path = null)
    {
        SettingsPath = Path.GetFullPath(path ?? DefaultSettingsPath());
    }

    public AppSettings Load()
    {
        if (!File.Exists(SettingsPath))
        {
            return new AppSettings();
        }

        var settings = JsonSerializer.Deserialize<AppSettings>(
            File.ReadAllText(SettingsPath),
            JsonOptions);
        return settings ?? new AppSettings();
    }

    public void Save(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var directory = Path.GetDirectoryName(SettingsPath)
            ?? throw new InvalidOperationException("Settings path has no parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = $"{SettingsPath}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(
                temporaryPath,
                JsonSerializer.Serialize(settings, JsonOptions));
            File.Move(temporaryPath, SettingsPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static string DefaultSettingsPath()
    {
        var overridePath = Environment.GetEnvironmentVariable("ASSIGNMENT_SETTINGS_PATH");
        return string.IsNullOrWhiteSpace(overridePath)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "AssignmentNative",
                "settings-v2.json")
            : overridePath;
    }
}
