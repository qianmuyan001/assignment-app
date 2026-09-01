using Microsoft.UI.Xaml;
using AssignmentNative.Core;
using AssignmentNative.Services;
using CommunityToolkit.WinUI.Notifications;
using Microsoft.Windows.Globalization;

namespace AssignmentNative;

public partial class App : Application
{
    private MainWindow? _window;
    private long? _pendingAssignmentId;

    public App()
    {
        ApplyAcceptancePathOverrides();
        ApplySavedLanguage();
        ResetToastRegistrationForAcceptance();
        InitializeComponent();
        WindowsNotificationScheduler.Shared.Activated += NotificationScheduler_Activated;
        WindowsNotificationScheduler.Shared.Register();
        UnhandledException += (_, args) =>
        {
            // Keep diagnostics useful without copying exception messages that
            // could contain untrusted page data into a log.
            System.Diagnostics.Debug.WriteLine(
                $"Unhandled exception type: {args.Exception.GetType().Name}");
        };
    }

    private static void ApplySavedLanguage()
    {
        AppLanguage language;
        try
        {
            language = new AppSettingsStore().Load().Language;
        }
        catch
        {
            language = AppLanguage.English;
        }
        ApplicationLanguages.PrimaryLanguageOverride = AppText.LanguageTag(language);
        AppText.SetLanguage(language);
    }

    public void SwitchLanguage(AppLanguage language, MainWindow sourceWindow)
    {
        if (!ReferenceEquals(_window, sourceWindow)) return;

        ApplicationLanguages.PrimaryLanguageOverride = AppText.LanguageTag(language);
        AppText.SetLanguage(language);

        var replacement = new MainWindow();
        _window = replacement;
        replacement.Activate();
        sourceWindow.CloseAuxiliaryWindows();
        sourceWindow.Close();
    }

    private static void ResetToastRegistrationForAcceptance()
    {
        if (Environment.GetCommandLineArgs().Any(argument =>
                string.Equals(
                    argument,
                    "--acceptance-reset-toast-registration",
                    StringComparison.Ordinal)))
        {
            ToastNotificationManagerCompat.Uninstall();
        }
    }

    private static void ApplyAcceptancePathOverrides()
    {
        var arguments = Environment.GetCommandLineArgs();
        ApplyAcceptancePathOverride(
            arguments,
            "--acceptance-database-path",
            "ASSIGNMENT_DB_PATH");
        ApplyAcceptancePathOverride(
            arguments,
            "--acceptance-settings-path",
            "ASSIGNMENT_SETTINGS_PATH");
    }

    private static void ApplyAcceptancePathOverride(
        IReadOnlyList<string> arguments,
        string option,
        string environmentVariable)
    {
        for (var index = 1; index < arguments.Count - 1; index++)
        {
            if (!string.Equals(arguments[index], option, StringComparison.Ordinal)) continue;
            var path = arguments[index + 1];
            if (Path.IsPathFullyQualified(path))
            {
                Environment.SetEnvironmentVariable(environmentVariable, Path.GetFullPath(path));
            }
            return;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
        if (_pendingAssignmentId is not null)
        {
            _window.OpenFromNotification(_pendingAssignmentId);
            _pendingAssignmentId = null;
        }
    }

    private void NotificationScheduler_Activated(
        object? sender,
        NotificationActivationEventArgs args)
    {
        _pendingAssignmentId = args.AssignmentId;
        var window = _window;
        if (window is null) return;

        window.DispatcherQueue.TryEnqueue(() =>
        {
            window.Activate();
            window.OpenFromNotification(args.AssignmentId);
            _pendingAssignmentId = null;
        });
    }
}
