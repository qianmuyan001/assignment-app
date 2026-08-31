using AssignmentNative.Core;
using Microsoft.Windows.AppNotifications;
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

    public string Status
    {
        get
        {
            try
            {
                if (!AppNotificationManager.IsSupported())
                    return "Unavailable on this Windows installation";
                var setting = AppNotificationManager.Default.Setting switch
                {
                    AppNotificationSetting.Enabled => "Allowed",
                    AppNotificationSetting.DisabledForApplication => "Disabled for Assignment App",
                    AppNotificationSetting.DisabledForUser => "Disabled for this Windows user",
                    AppNotificationSetting.DisabledByGroupPolicy => "Disabled by Group Policy",
                    AppNotificationSetting.DisabledByManifest => "Disabled by app manifest",
                    _ => "Unavailable"
                };
                return _lastError is null ? setting : $"{setting} · {_lastError}";
            }
            catch (Exception error)
            {
                return $"Unavailable on this Windows installation ({error.GetType().Name})";
            }
        }
    }

    public bool Register()
    {
        if (_registered) return true;
        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                _lastError = "Notification API is not supported";
                return false;
            }
            AppNotificationManager.Default.Register();
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

            var notifier = ToastNotificationManager.CreateToastNotifier();
            foreach (var scheduled in notifier.GetScheduledToastNotifications()
                         .Where(item => item.Group == NotificationGroup && !desired.ContainsKey(item.Tag)))
            {
                notifier.RemoveFromSchedule(scheduled);
            }
            if (AppNotificationManager.Default.Setting != AppNotificationSetting.Enabled)
            {
                _lastError = null;
                return false;
            }
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
        if (AppNotificationManager.Default.Setting != AppNotificationSetting.Enabled)
            return false;
        try
        {
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

    private static void ScheduleCore(ReminderItem reminder, CoreAssignmentItem task)
    {
        CancelCore(reminder);
        if (!reminder.IsEnabled || reminder.TriggerAtUtc <= DateTimeOffset.UtcNow ||
            task.Status == TaskStatuses.Done ||
            AppNotificationManager.Default.Setting != AppNotificationSetting.Enabled) return;
        var payload = new AppNotificationBuilder()
            .AddArgument("assignmentId", task.Id.ToString())
            .AddText(task.Title)
            .AddText($"{task.CourseName} · Due {TaskDueDisplayFormatter.Format(task)}")
            .BuildNotification()
            .Payload;
        var document = new XmlDocument();
        document.LoadXml(payload);
        var scheduled = new ScheduledToastNotification(document, reminder.TriggerAtUtc)
        {
            Tag = Tag(reminder),
            Group = NotificationGroup
        };
        ToastNotificationManager.CreateToastNotifier().AddToSchedule(scheduled);
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

    private static void CancelCore(ReminderItem reminder)
    {
        var notifier = ToastNotificationManager.CreateToastNotifier();
        foreach (var scheduled in notifier.GetScheduledToastNotifications()
                     .Where(item => item.Group == NotificationGroup && item.Tag == Tag(reminder)))
        {
            notifier.RemoveFromSchedule(scheduled);
        }
    }

    private static string Tag(ReminderItem reminder) => $"r{reminder.Id}";

    private void RecordFailure(Exception error) =>
        _lastError = $"Last operation failed ({error.GetType().Name})";
}
