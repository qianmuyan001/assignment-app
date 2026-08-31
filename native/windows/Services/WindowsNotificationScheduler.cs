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

    public string Status
    {
        get
        {
            try
            {
                var setting = CreateNotifier().Setting switch
                {
                    NotificationSetting.Enabled => "Allowed",
                    NotificationSetting.DisabledForApplication => "Disabled for Assignment App",
                    NotificationSetting.DisabledForUser => "Disabled for this Windows user",
                    NotificationSetting.DisabledByGroupPolicy => "Disabled by Group Policy",
                    NotificationSetting.DisabledByManifest => "Disabled by app manifest",
                    _ => "Unavailable"
                };
                return _lastError is null ? setting : $"{setting} · {_lastError}";
            }
            catch (Exception error)
            {
                return $"Unavailable on this Windows installation " +
                    $"({error.GetType().Name}, 0x{error.HResult:X8})";
            }
        }
    }

    public bool Register()
    {
        if (_registered) return true;
        try
        {
            _ = CreateNotifier().Setting;
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
            if (notifier.Setting != NotificationSetting.Enabled)
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
        if (CreateNotifier().Setting != NotificationSetting.Enabled)
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
            CreateNotifier().Setting != NotificationSetting.Enabled) return;
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

    private static ToastNotifierCompat CreateNotifier() =>
        ToastNotificationManagerCompat.CreateToastNotifier();

    private void RecordFailure(Exception error) =>
        _lastError = $"Last operation failed ({error.GetType().Name}, 0x{error.HResult:X8})";
}
