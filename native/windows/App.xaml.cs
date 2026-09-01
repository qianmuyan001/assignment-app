using Microsoft.UI.Xaml;
using AssignmentNative.Services;

namespace AssignmentNative;

public partial class App : Application
{
    private MainWindow? _window;
    private long? _pendingAssignmentId;

    public App()
    {
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
