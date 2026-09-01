using System.Runtime.InteropServices;
using AssignmentNative.Core;
using CommunityToolkit.WinUI.Notifications;
using Microsoft.Windows.AppNotifications.Builder;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative.Services;

public sealed class WindowsNotificationScheduler
{
    public static WindowsNotificationScheduler Shared { get; } = new();

    private const string NotificationGroup = "assignments";
    private bool _registered;
    private string? _lastError;

    public event EventHandler<NotificationActivationEventArgs>? Activated;

    public string Status
    {
        get
        {
            if (!Register())
            {
                return _lastError ?? AppText.Get("NotificationUnavailableWindows");
            }

            try
            {
                var setting = CreateNotifier().Setting switch
                {
                    NotificationSetting.Enabled => AppText.Get("NotificationAllowed"),
                    NotificationSetting.DisabledForApplication => AppText.Get("NotificationDisabledApp"),
                    NotificationSetting.DisabledForUser => AppText.Get("NotificationDisabledUser"),
                    NotificationSetting.DisabledByGroupPolicy => AppText.Get("NotificationDisabledPolicy"),
                    NotificationSetting.DisabledByManifest => AppText.Get("NotificationDisabledManifest"),
                    _ => AppText.Get("NotificationUnavailable")
                };
                return _lastError is null ? setting : $"{setting} · {_lastError}";
            }
            catch (COMException error) when (error.HResult == unchecked((int)0x80070490))
            {
                // A newly registered unpackaged sender can return E_NOTFOUND until
                // its first toast is sent, even though Show and scheduling work.
                return _lastError is null ? AppText.Get("NotificationRegistered") : _lastError;
            }
            catch (Exception error)
            {
                return $"{AppText.Get("NotificationUnavailableWindows")} " +
                    $"({error.GetType().Name}, 0x{error.HResult:X8})";
            }
        }
    }

    public bool Register()
    {
        if (_registered) return true;
        try
        {
            WindowsToastIdentity.InstallShortcut();
#pragma warning disable CS0618 // Explicit AUMID/CLSID identity is required for unpackaged self-contained builds.
            DesktopNotificationManagerCompat
                .RegisterAumidAndComServer<AssignmentNotificationActivator>(WindowsToastIdentity.AppUserModelId);
            DesktopNotificationManagerCompat.RegisterActivator<AssignmentNotificationActivator>();
#pragma warning restore CS0618
            _registered = true;
            _lastError = null;
            return true;
        }
        catch (Exception error)
        {
            RecordFailure(error);
            return false;
        }
    }

    public bool Reconcile(AssignmentDatabase database)
    {
        if (!Register()) return false;
        try
        {
            var assignments = database.FetchCoreAssignments().ToDictionary(item => item.Id);
            var desired = new Dictionary<string, (ReminderItem Reminder, CoreAssignmentItem Task)>();
            foreach (var task in assignments.Values)
            {
                foreach (var reminder in database.Organization.FetchReminders(task.Id))
                {
                    if (reminder.IsEnabled && reminder.TriggerAtUtc > DateTimeOffset.UtcNow &&
                        task.Status != TaskStatuses.Done)
                    {
                        desired[Tag(reminder)] = (reminder, task);
                    }
                }
            }

            var notifier = CreateNotifier();
            foreach (var scheduled in notifier.GetScheduledToastNotifications()
                         .Where(item => item.Group == NotificationGroup && !desired.ContainsKey(item.Tag)))
            {
                notifier.RemoveFromSchedule(scheduled);
            }
            if (!NotificationsEnabled(notifier)) return false;
            foreach (var value in desired.Values) ScheduleCore(value.Reminder, value.Task);
            _lastError = null;
            return true;
        }
        catch (Exception error)
        {
            RecordFailure(error);
            return false;
        }
    }

    public bool Schedule(ReminderItem reminder, CoreAssignmentItem task)
    {
        if (!Register()) return false;
        try
        {
            if (!NotificationsEnabled(CreateNotifier())) return false;
            ScheduleCore(reminder, task);
            _lastError = null;
            return true;
        }
        catch (Exception error)
        {
            RecordFailure(error);
            return false;
        }
    }

    public bool ScheduleTestNotification(TimeSpan delay)
    {
        if (!Register()) return false;
        try
        {
            var notifier = CreateNotifier();
            if (!NotificationsEnabled(notifier)) return false;

            var notification = new ScheduledToastNotification(
                CreatePayload(
                    assignmentId: 0,
                    title: AppText.Get("NotificationTestTitle"),
                    message: AppText.Get("NotificationTestMessage")),
                DateTimeOffset.Now.Add(delay))
            {
                Tag = $"test-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}",
                Group = NotificationGroup,
                SuppressPopup = false
            };
            notifier.AddToSchedule(notification);
            _lastError = null;
            return true;
        }
        catch (Exception error)
        {
            RecordFailure(error);
            return false;
        }
    }

    private static void ScheduleCore(ReminderItem reminder, CoreAssignmentItem task)
    {
        CancelCore(reminder);
        if (!reminder.IsEnabled || reminder.TriggerAtUtc <= DateTimeOffset.UtcNow ||
            task.Status == TaskStatuses.Done) return;

        var scheduled = new ScheduledToastNotification(
            CreatePayload(
                task.Id,
                task.Title,
                AppText.Format("NotificationTaskMessage", task.CourseName, AppText.FormatDue(task))),
            reminder.TriggerAtUtc)
        {
            Tag = Tag(reminder),
            Group = NotificationGroup,
            SuppressPopup = false
        };
        CreateNotifier().AddToSchedule(scheduled);
    }

    public bool Cancel(ReminderItem reminder)
    {
        if (!Register()) return false;
        try
        {
            CancelCore(reminder);
            _lastError = null;
            return true;
        }
        catch (Exception error)
        {
            RecordFailure(error);
            return false;
        }
    }

    internal void HandleActivation(string arguments)
    {
        long? assignmentId = null;
        try
        {
            var values = ToastArguments.Parse(arguments);
            if (values.TryGetValue("assignmentId", out var rawId) &&
                long.TryParse(rawId, out var parsedId) && parsedId > 0)
            {
                assignmentId = parsedId;
            }
        }
        catch (Exception)
        {
            // Invalid activation arguments still open the app safely.
        }
        Activated?.Invoke(this, new NotificationActivationEventArgs(assignmentId));
    }

    private bool NotificationsEnabled(ToastNotifier notifier)
    {
        try
        {
            var setting = notifier.Setting;
            if (setting == NotificationSetting.Enabled) return true;
            _lastError = setting switch
            {
                NotificationSetting.DisabledForApplication => AppText.Get("NotificationBlockedApp"),
                NotificationSetting.DisabledForUser => AppText.Get("NotificationBlockedUser"),
                NotificationSetting.DisabledByGroupPolicy => AppText.Get("NotificationBlockedPolicy"),
                NotificationSetting.DisabledByManifest => AppText.Get("NotificationBlockedManifest"),
                _ => AppText.Get("NotificationUnknown")
            };
            return false;
        }
        catch (COMException error) when (error.HResult == unchecked((int)0x80070490))
        {
            return true;
        }
    }

    private static XmlDocument CreatePayload(long assignmentId, string title, string message)
    {
        var payload = new AppNotificationBuilder()
            .AddArgument("assignmentId", assignmentId.ToString())
            .AddText(title)
            .AddText(message)
            .SetScenario(AppNotificationScenario.Reminder)
            .AddButton(new AppNotificationButton(AppText.Get("NotificationOpenButton"))
                .AddArgument("assignmentId", assignmentId.ToString()))
            .BuildNotification()
            .Payload;
        var document = new XmlDocument();
        document.LoadXml(payload);
        return document;
    }

    private static void CancelCore(ReminderItem reminder)
    {
        var notifier = CreateNotifier();
        foreach (var scheduled in notifier.GetScheduledToastNotifications()
                     .Where(item => item.Group == NotificationGroup && item.Tag == Tag(reminder)))
        {
            notifier.RemoveFromSchedule(scheduled);
        }
    }

    private static string Tag(ReminderItem reminder) => $"r{reminder.Id}";

    private static ToastNotifier CreateNotifier()
    {
#pragma warning disable CS0618 // See Register: this preserves a stable sender identity in Windows.
        return DesktopNotificationManagerCompat.CreateToastNotifier();
#pragma warning restore CS0618
    }

    private void RecordFailure(Exception error) =>
        _lastError = AppText.Format(
            "NotificationFailure",
            error.GetType().Name,
            error.HResult.ToString("X8"));
}

public sealed record NotificationActivationEventArgs(long? AssignmentId);
