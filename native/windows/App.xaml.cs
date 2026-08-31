using Microsoft.UI.Xaml;
using AssignmentNative.Services;

namespace AssignmentNative;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        WindowsNotificationScheduler.Shared.Register();
        UnhandledException += (_, args) =>
        {
            // Keep diagnostics useful without copying exception messages that
            // could contain untrusted page data into a log.
            System.Diagnostics.Debug.WriteLine(
                $"Unhandled exception type: {args.Exception.GetType().Name}");
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
