using System;
using System.Collections.Generic;
using System.Linq;
using AssignmentNative.Core;
using AssignmentNative.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;
using WinRT;
using WinRT.Interop;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative;

public sealed partial class TaskEditorDialog : ContentDialog
{
    private const string CustomCourseTag = "__custom__";
    private const string NoneProjectTag = "__none__";

    private readonly CoreAssignmentItem? _existing;
    private readonly bool _professionalMode;
    private readonly ITaskOrganizationRepository _organization;
    private readonly IntPtr _ownerHandle;
    private readonly Action? _notificationReconcile;
    private readonly TaskDueControlState _loadedDueState;
    private readonly AttachmentFileStore _attachmentStore;

    private IReadOnlyList<CourseItem> _courses = Array.Empty<CourseItem>();
    private IReadOnlyList<ProjectItem> _projects = Array.Empty<ProjectItem>();
    private IReadOnlyList<TagItem> _tags = Array.Empty<TagItem>();

    private long? _selectedCourseId;
    private long? _selectedProjectId;
    private readonly HashSet<long> _selectedTagIds = new();
    private string? _derivedSubtaskStatus;
    private int? _derivedSubtaskProgress;
    private bool _populating;

    public AssignmentDraft? Result { get; private set; }

    public IReadOnlyList<long> SelectedTagIds => _selectedTagIds.ToList();

    public TaskEditorDialog(
        CoreAssignmentItem? existing,
        bool professionalMode,
        ITaskOrganizationRepository organization,
        IntPtr ownerHandle = default,
        Action? notificationReconcile = null)
    {
        InitializeComponent();
        _existing = existing;
        _professionalMode = professionalMode;
        _organization = organization;
        _ownerHandle = ownerHandle;
        _notificationReconcile = notificationReconcile;
        _attachmentStore = new AttachmentFileStore(organization.DatabasePath);

        Title = AppText.Get(existing is null ? "AddAssignmentTitle" : "EditAssignmentTitle");
        PrimaryButtonText = AppText.Get("Save");
        CloseButtonText = AppText.Get("Cancel");
        ProfessionalFields.Visibility = professionalMode
            ? Visibility.Visible
            : Visibility.Collapsed;
        ModeHelpText.Visibility = !professionalMode && existing is not null
            ? Visibility.Visible
            : Visibility.Collapsed;

        _populating = true;
        Populate(existing);
        _loadedDueState = ReadDueControlState();
        if (professionalMode)
        {
            OrganizationSection.Visibility = Visibility.Visible;
            LoadCoursesAndTags();
            if (existing is not null)
            {
                SubtasksSection.Visibility = Visibility.Visible;
                RemindersSection.Visibility = Visibility.Visible;
                AttachmentsSection.Visibility = Visibility.Visible;
                LoadChildren(existing.Id);
            }
        }
        _populating = false;
    }

    private void Populate(CoreAssignmentItem? item)
    {
        if (item is null)
        {
            DueDatePicker.SelectedDate = DateTimeOffset.Now.Date;
            DueTimePicker.Time = new TimeSpan(23, 59, 0);
            return;
        }

        TitleBox.Text = item.Title;
        CourseBox.Text = item.CourseName;
        DescriptionBox.Text = item.Description ?? "";
        LinkBox.Text = item.Link ?? "";
        SelectByTag(StatusBox, item.Status);
        SelectByTag(PriorityBox, item.Priority);

        if (item.DueDate is { } dueDate)
        {
            var localDue = TimeZoneInfo.ConvertTime(dueDate, EffectiveTimeZone);
            HasDueDateBox.IsChecked = true;
            DueDatePicker.SelectedDate = localDue.Date;
            DueTimePicker.Time = localDue.TimeOfDay;
        }
    }

    private void LoadCoursesAndTags()
    {
        _courses = _organization.FetchCourses();
        _projects = _organization.FetchProjects();
        _tags = _organization.FetchTags();

        PopulateCoursePicker();
        if (_existing is not null)
        {
            _selectedCourseId = _existing.CourseId;
            SelectCoursePickerById(_existing.CourseId);
        }
        PopulateProjectPicker();
        if (_existing is not null && _existing.ProjectId is { } projectId)
        {
            SelectProjectPickerById(projectId);
        }
        PopulateTagPanel();
        if (_existing is not null)
        {
            foreach (var link in _organization.FetchTaskTags(_existing.Id))
            {
                _selectedTagIds.Add(link.TagId);
            }
            RefreshTagChecks();
        }
    }

    private void PopulateCoursePicker()
    {
        CoursePickerBox.Items.Clear();
        CoursePickerBox.Items.Add(new ComboBoxItem
        {
            Content = AppText.Get("CustomCourse"),
            Tag = CustomCourseTag
        });
        foreach (var course in _courses.OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            CoursePickerBox.Items.Add(new ComboBoxItem { Content = course.Name, Tag = course.Id });
        }
        CoursePickerBox.SelectedIndex = 0;
    }

    private void SelectCoursePickerById(long? id)
    {
        if (id is null)
        {
            CoursePickerBox.SelectedIndex = 0;
            return;
        }
        foreach (ComboBoxItem item in CoursePickerBox.Items)
        {
            if (item.Tag is long value && value == id)
            {
                CoursePickerBox.SelectedItem = item;
                return;
            }
        }
        CoursePickerBox.SelectedIndex = 0;
    }

    private void PopulateProjectPicker()
    {
        ProjectPickerBox.Items.Clear();
        ProjectPickerBox.Items.Add(new ComboBoxItem
        {
            Content = AppText.Get("NoProject"),
            Tag = NoneProjectTag
        });
        var eligible = _selectedCourseId is null
            ? _projects.Where(p => p.CourseId is null)
            : _projects.Where(p => p.CourseId == _selectedCourseId);
        foreach (var project in eligible.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            ProjectPickerBox.Items.Add(new ComboBoxItem { Content = project.Name, Tag = project.Id });
        }
        ProjectPickerBox.SelectedIndex = 0;
    }

    private void SelectProjectPickerById(long? id)
    {
        if (id is null)
        {
            ProjectPickerBox.SelectedIndex = 0;
            return;
        }
        foreach (ComboBoxItem item in ProjectPickerBox.Items)
        {
            if (item.Tag is long value && value == id)
            {
                ProjectPickerBox.SelectedItem = item;
                return;
            }
        }
        ProjectPickerBox.SelectedIndex = 0;
    }

    private void PopulateTagPanel()
    {
        TagPanel.Children.Clear();
        foreach (var tag in _tags.OrderBy(t => t.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            var box = new CheckBox
            {
                Content = tag.Name,
                Tag = tag.Id,
                Margin = new Thickness(0, 0, 14, 0)
            };
            box.Checked += TagCheckBox_Changed;
            box.Unchecked += TagCheckBox_Changed;
            TagPanel.Children.Add(box);
        }
        RefreshTagChecks();
    }

    private void RefreshTagChecks()
    {
        foreach (var child in TagPanel.Children.OfType<CheckBox>())
        {
            if (child.Tag is long id)
            {
                child.IsChecked = _selectedTagIds.Contains(id);
            }
        }
    }

    private void LoadChildren(long assignmentId)
    {
        RenderSubtasks(_organization.FetchSubtasks(assignmentId));
        RenderReminders(_organization.FetchReminders(assignmentId));
        RenderAttachments(_organization.FetchAttachments(assignmentId));
        var reconciliation = _attachmentStore.Reconcile(
            _organization.FetchAllAttachments());
        if (reconciliation.MissingPayloadNames.Count > 0)
        {
            ShowNotice(AppText.Format(
                "EditorAttachmentFilesMissing",
                string.Join(", ", reconciliation.MissingPayloadNames)));
        }
    }

    private void RenderSubtasks(
        IReadOnlyList<SubtaskItem> subtasks,
        bool synchronizeState = true,
        bool resetWhenEmpty = false)
    {
        SubtasksList.Children.Clear();
        foreach (var subtask in subtasks)
        {
            var check = new CheckBox
            {
                IsChecked = subtask.Status == TaskStatuses.Done,
                VerticalAlignment = VerticalAlignment.Center
            };
            check.Tag = subtask;
            check.Checked += SubtaskToggle_Changed;
            check.Unchecked += SubtaskToggle_Changed;

            var title = new TextBlock
            {
                Text = subtask.Title,
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap
            };
            var remove = new Button
            {
                Content = AppText.Get("Remove"),
                Tag = subtask,
                VerticalAlignment = VerticalAlignment.Center
            };
            var edit = new Button
            {
                Content = AppText.Get("Edit"),
                Tag = subtask,
                VerticalAlignment = VerticalAlignment.Center
            };
            AutomationProperties.SetName(check, AppText.Format("MarkSubtaskComplete", subtask.Title));
            AutomationProperties.SetName(edit, AppText.Format("EditSubtask", subtask.Title));
            AutomationProperties.SetName(remove, AppText.Format("RemoveSubtask", subtask.Title));
            edit.Click += EditSubtask_Click;
            remove.Click += RemoveSubtask_Click;

            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center
            };
            actions.Children.Add(edit);
            actions.Children.Add(remove);
            SubtasksList.Children.Add(BuildRow(check, title, actions));
        }

        if (!synchronizeState) return;
        if (subtasks.Count == 0)
        {
            _derivedSubtaskStatus = resetWhenEmpty ? TaskStatuses.Todo : null;
            _derivedSubtaskProgress = resetWhenEmpty ? 0 : null;
        }
        else
        {
            var completed = subtasks.Count(item => item.Status == TaskStatuses.Done);
            _derivedSubtaskProgress = completed * 100 / subtasks.Count;
            _derivedSubtaskStatus = completed == subtasks.Count
                ? TaskStatuses.Done
                : completed > 0 || subtasks.Any(item => item.Status == TaskStatuses.InProgress)
                    ? TaskStatuses.InProgress
                    : TaskStatuses.Todo;
        }
        if (_derivedSubtaskStatus is not null)
        {
            SelectByTag(StatusBox, _derivedSubtaskStatus);
        }
    }

    private void RenderReminders(IReadOnlyList<ReminderItem> reminders)
    {
        RemindersList.Children.Clear();
        foreach (var reminder in reminders)
        {
            var label = new TextBlock
            {
                Text = FormatReminder(reminder),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap
            };
            var remove = new Button
            {
                Content = AppText.Get("Remove"),
                Tag = reminder,
                VerticalAlignment = VerticalAlignment.Center
            };
            var edit = new Button
            {
                Content = AppText.Get("EditTime"),
                Tag = reminder,
                VerticalAlignment = VerticalAlignment.Center
            };
            var toggle = new Button
            {
                Content = AppText.Get(reminder.IsEnabled ? "Disable" : "Enable"),
                Tag = reminder,
                VerticalAlignment = VerticalAlignment.Center
            };
            AutomationProperties.SetName(
                edit,
                AppText.Format("EditReminder", FormatReminder(reminder)));
            AutomationProperties.SetName(
                toggle,
                AppText.Format("ToggleReminder", toggle.Content, FormatReminder(reminder)));
            AutomationProperties.SetName(
                remove,
                AppText.Format("RemoveReminder", FormatReminder(reminder)));
            edit.Click += EditReminder_Click;
            toggle.Click += ToggleReminder_Click;
            remove.Click += RemoveReminder_Click;
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center
            };
            actions.Children.Add(edit);
            actions.Children.Add(toggle);
            actions.Children.Add(remove);
            RemindersList.Children.Add(BuildRow(label, actions));
        }
    }

    private void RenderAttachments(IReadOnlyList<AttachmentMetadataItem> attachments)
    {
        AttachmentsList.Children.Clear();
        foreach (var attachment in attachments)
        {
            var payloadAvailable = true;
            try { _ = _attachmentStore.PayloadPath(attachment); }
            catch (IOException) { payloadAvailable = false; }
            catch (UnauthorizedAccessException) { payloadAvailable = false; }
            var label = new TextBlock
            {
                Text = payloadAvailable
                    ? AppText.Format("AttachmentSize", attachment.FileName, attachment.ByteSize)
                    : AppText.Format("AttachmentUnavailable", attachment.FileName),
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap
            };
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center
            };
            var open = new Button { Content = AppText.Get("Open"), Tag = attachment, IsEnabled = payloadAvailable };
            open.Click += OpenAttachment_Click;
            var export = new Button { Content = AppText.Get("Export"), Tag = attachment, IsEnabled = payloadAvailable };
            export.Click += ExportAttachment_Click;
            var remove = new Button
            {
                Content = AppText.Get("Remove"),
                Tag = attachment,
                VerticalAlignment = VerticalAlignment.Center
            };
            AutomationProperties.SetName(open, AppText.Format("OpenAttachment", attachment.FileName));
            AutomationProperties.SetName(export, AppText.Format("ExportAttachment", attachment.FileName));
            AutomationProperties.SetName(remove, AppText.Format("RemoveAttachment", attachment.FileName));
            remove.Click += RemoveAttachment_Click;
            actions.Children.Add(open);
            actions.Children.Add(export);
            actions.Children.Add(remove);
            AttachmentsList.Children.Add(BuildRow(label, actions));
        }
    }

    private static Grid BuildRow(FrameworkElement primary, FrameworkElement secondary)
    {
        var grid = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0, GridUnitType.Auto) });
        Grid.SetColumn(primary, 0);
        Grid.SetColumn(secondary, 1);
        grid.Children.Add(primary);
        grid.Children.Add(secondary);
        return grid;
    }

    private static Grid BuildRow(FrameworkElement leading, FrameworkElement middle, FrameworkElement trailing)
    {
        var grid = new Grid { ColumnSpacing = 8, Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0, GridUnitType.Auto) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(0, GridUnitType.Auto) });
        Grid.SetColumn(leading, 0);
        Grid.SetColumn(middle, 1);
        Grid.SetColumn(trailing, 2);
        grid.Children.Add(leading);
        grid.Children.Add(middle);
        grid.Children.Add(trailing);
        return grid;
    }

    private static string FormatReminder(ReminderItem reminder)
    {
        var local = reminder.TriggerAtUtc.ToLocalTime();
        var repeat = string.IsNullOrWhiteSpace(reminder.RepeatRule)
            ? ""
            : AppText.Format("ReminderRepeats", reminder.RepeatRule);
        var disabled = reminder.IsEnabled ? "" : AppText.Get("ReminderDisabled");
        return $"{local:g}{disabled}{repeat}";
    }

    private void CoursePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_populating) return;
        if (CoursePickerBox.SelectedItem is ComboBoxItem item && item.Tag is long id)
        {
            var course = _courses.FirstOrDefault(c => c.Id == id);
            if (course is not null)
            {
                _selectedCourseId = course.Id;
                _populating = true;
                CourseBox.Text = course.Name;
                _populating = false;
            }
        }
        else
        {
            _selectedCourseId = null;
        }
        _selectedProjectId = null;
        PopulateProjectPicker();
    }

    private void ProjectPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_populating) return;
        _selectedProjectId = ProjectPickerBox.SelectedItem is ComboBoxItem item && item.Tag is long id
            ? id
            : null;
    }

    private void CourseBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_populating) return;
        var text = CourseBox.Text.Trim();
        var matchesSelected = _selectedCourseId is { } id &&
            _courses.FirstOrDefault(c => c.Id == id) is { } course &&
            string.Equals(course.Name, text, StringComparison.Ordinal);
        if (matchesSelected) return;
        _selectedCourseId = null;
        _selectedProjectId = null;
        CoursePickerBox.SelectedIndex = 0;
        PopulateProjectPicker();
    }

    private void TagCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is CheckBox { Tag: long id } box)
        {
            if (box.IsChecked == true) _selectedTagIds.Add(id);
            else _selectedTagIds.Remove(id);
        }
    }

    private void AddSubtask_Click(object sender, RoutedEventArgs e) => CommitNewSubtask();

    private void NewSubtask_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) CommitNewSubtask();
    }

    private void CommitNewSubtask()
    {
        if (_existing is null) return;
        var title = NewSubtaskBox.Text.Trim();
        if (title.Length == 0) return;
        try
        {
            var sortOrder = _organization.FetchSubtasks(_existing.Id).Count;
            _organization.CreateSubtask(new SubtaskDraft(_existing.Id, title, TaskStatuses.Todo, sortOrder));
            NewSubtaskBox.Text = "";
            RenderSubtasks(_organization.FetchSubtasks(_existing.Id));
            ReconcileNotificationsAfterChildChange();
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("SubtaskAddError", error.Message));
        }
    }

    private void SubtaskToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { Tag: SubtaskItem subtask } check || _existing is null) return;
        var status = check.IsChecked == true ? TaskStatuses.Done : TaskStatuses.Todo;
        try
        {
            _organization.UpdateSubtask(
                subtask.Id,
                new SubtaskDraft(
                    subtask.AssignmentId,
                    subtask.Title,
                    status,
                    subtask.SortOrder));
            RenderSubtasks(_organization.FetchSubtasks(_existing.Id));
            ReconcileNotificationsAfterChildChange();
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("SubtaskUpdateError", error.Message));
        }
    }

    private void EditSubtask_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SubtaskItem subtask } editButton || _existing is null) return;
        var titleBox = new TextBox
        {
            Header = AppText.Get("Title"),
            Text = subtask.Title,
            MaxLength = 255,
            MinWidth = 280
        };
        AutomationProperties.SetName(titleBox, AppText.Get("SubtaskTitle"));
        var save = new Button { Content = AppText.Get("Save"), HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = AppText.Get("Cancel") };
        AutomationProperties.SetName(save, AppText.Get("SaveSubtaskTitle"));
        AutomationProperties.SetName(cancel, AppText.Get("CancelSubtaskTitleEdit"));
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        actions.Children.Add(cancel);
        actions.Children.Add(save);
        var fields = new StackPanel { Spacing = 8, MinWidth = 280 };
        fields.Children.Add(titleBox);
        fields.Children.Add(actions);
        var flyout = new Flyout { Content = fields };
        AutomationProperties.SetName(fields, AppText.Get("EditSubtaskTitle"));
        cancel.Click += (_, _) => flyout.Hide();
        save.Click += (_, _) =>
        {
            var title = titleBox.Text.Trim();
            if (title.Length == 0) return;
            try
            {
                _organization.UpdateSubtask(
                    subtask.Id,
                    new SubtaskDraft(
                        subtask.AssignmentId,
                        title,
                        subtask.Status,
                        subtask.SortOrder));
                RenderSubtasks(
                    _organization.FetchSubtasks(_existing.Id),
                    synchronizeState: false);
                ReconcileNotificationsAfterChildChange();
                flyout.Hide();
            }
            catch (Exception error)
            {
                ShowNotice(AppText.Format("SubtaskUpdateError", error.Message));
            }
        };
        flyout.ShowAt(editButton);
        titleBox.Focus(FocusState.Programmatic);
        titleBox.SelectAll();
    }

    private void RemoveSubtask_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SubtaskItem subtask } || _existing is null) return;
        try
        {
            _organization.DeleteSubtask(subtask.Id);
            RenderSubtasks(
                _organization.FetchSubtasks(_existing.Id),
                resetWhenEmpty: true);
            ReconcileNotificationsAfterChildChange();
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("SubtaskRemoveError", error.Message));
        }
    }

    private void AddReminder_Click(object sender, RoutedEventArgs e)
    {
        if (_existing is null || NewReminderDatePicker.SelectedDate is not { } date) return;
        var local = date.Date.Add(NewReminderTimePicker.Time);
        var trigger = new DateTimeOffset(local);
        try
        {
            var reminder = _organization.CreateReminder(new ReminderDraft(
                _existing.Id,
                trigger,
                LeadMinutes: 0,
                RepeatRule: null,
                IsEnabled: true));
            if (!WindowsNotificationScheduler.Shared.Schedule(reminder, _existing))
            {
                ShowNotice(AppText.Format(
                    "ReminderSavedNotificationError",
                    WindowsNotificationScheduler.Shared.Status));
            }
            RenderReminders(_organization.FetchReminders(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("ReminderAddError", error.Message));
        }
    }

    private void RemoveReminder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ReminderItem reminder } || _existing is null) return;
        try
        {
            _organization.DeleteReminder(reminder.Id);
            if (!WindowsNotificationScheduler.Shared.Cancel(reminder))
            {
                ShowNotice(AppText.Format(
                    "ReminderRemovedNotificationError",
                    WindowsNotificationScheduler.Shared.Status));
            }
            RenderReminders(_organization.FetchReminders(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("ReminderRemoveError", error.Message));
        }
    }

    private void EditReminder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ReminderItem reminder } editButton || _existing is null) return;
        var local = reminder.TriggerAtUtc.ToLocalTime();
        var datePicker = new DatePicker
        {
            Header = AppText.Get("Date"),
            SelectedDate = local.Date,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var timePicker = new TimePicker
        {
            Header = AppText.Get("Time"),
            Time = local.TimeOfDay,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        AutomationProperties.SetName(datePicker, AppText.Get("ReminderDate"));
        AutomationProperties.SetName(timePicker, AppText.Get("ReminderTime"));
        var save = new Button { Content = AppText.Get("Save"), HorizontalAlignment = HorizontalAlignment.Right };
        var cancel = new Button { Content = AppText.Get("Cancel") };
        AutomationProperties.SetName(save, AppText.Get("SaveReminderTime"));
        AutomationProperties.SetName(cancel, AppText.Get("CancelReminderTimeEdit"));
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        actions.Children.Add(cancel);
        actions.Children.Add(save);
        var fields = new StackPanel { Spacing = 8, MinWidth = 280 };
        fields.Children.Add(datePicker);
        fields.Children.Add(timePicker);
        fields.Children.Add(actions);
        var flyout = new Flyout
        {
            Content = fields
        };
        AutomationProperties.SetName(fields, AppText.Get("EditReminderTime"));
        cancel.Click += (_, _) => flyout.Hide();
        save.Click += (_, _) =>
        {
            if (datePicker.SelectedDate is not { } date) return;
            try
            {
                var trigger = new DateTimeOffset(date.Date.Add(timePicker.Time));
                var updated = _organization.UpdateReminder(
                    reminder.Id,
                    new ReminderDraft(
                        reminder.AssignmentId,
                        trigger,
                        reminder.LeadMinutes,
                        reminder.RepeatRule,
                        reminder.IsEnabled,
                        null));
                var notificationUpdated = updated.IsEnabled
                    ? WindowsNotificationScheduler.Shared.Schedule(updated, _existing)
                    : WindowsNotificationScheduler.Shared.Cancel(updated);
                if (!notificationUpdated)
                {
                    ShowNotice(AppText.Format(
                        "ReminderTimeSavedNotificationError",
                        WindowsNotificationScheduler.Shared.Status));
                }
                RenderReminders(_organization.FetchReminders(_existing.Id));
                flyout.Hide();
            }
            catch (Exception error)
            {
                ShowNotice(AppText.Format("ReminderUpdateError", error.Message));
            }
        };
        flyout.ShowAt(editButton);
    }

    private void ToggleReminder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ReminderItem reminder } || _existing is null) return;
        try
        {
            var updated = _organization.UpdateReminder(
                reminder.Id,
                new ReminderDraft(
                    reminder.AssignmentId,
                    reminder.TriggerAtUtc,
                    reminder.LeadMinutes,
                    reminder.RepeatRule,
                    !reminder.IsEnabled,
                    null));
            var notificationUpdated = updated.IsEnabled
                ? WindowsNotificationScheduler.Shared.Schedule(updated, _existing)
                : WindowsNotificationScheduler.Shared.Cancel(updated);
            if (!notificationUpdated)
            {
                ShowNotice(AppText.Format(
                    "ReminderUpdatedNotificationError",
                    WindowsNotificationScheduler.Shared.Status));
            }
            RenderReminders(_organization.FetchReminders(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("ReminderUpdateError", error.Message));
        }
    }

    private void ReconcileNotificationsAfterChildChange()
    {
        try
        {
            _notificationReconcile?.Invoke();
        }
        catch
        {
            ShowNotice(AppText.Get("TaskNotificationRefreshError"));
        }
    }

    private async void AddAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (_existing is null) return;
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            FileTypeFilter = { "*" }
        };
        if (_ownerHandle != IntPtr.Zero)
        {
            InitializeWithWindow.Initialize(picker, _ownerHandle);
        }

        StorageFile? file;
        try
        {
            file = await picker.PickSingleFileAsync();
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("FilePickerOpenError", error.Message));
            return;
        }
        if (file is null) return;

        try
        {
            _attachmentStore.Import(
                file.Path,
                _existing.Id,
                file.ContentType,
                _organization);
            RenderAttachments(_organization.FetchAttachments(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("AttachmentAddError", error.Message));
        }
    }

    private void RemoveAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: AttachmentMetadataItem attachment } || _existing is null) return;
        try
        {
            _attachmentStore.Delete(attachment, _organization);
            RenderAttachments(_organization.FetchAttachments(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("AttachmentRemoveError", error.Message));
        }
    }

    private async void OpenAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: AttachmentMetadataItem attachment }) return;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(
                _attachmentStore.PayloadPath(attachment));
            if (!await Launcher.LaunchFileAsync(file))
                ShowNotice(AppText.Get("AttachmentNoOpenApp"));
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("AttachmentOpenError", error.Message));
        }
    }

    private async void ExportAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: AttachmentMetadataItem attachment }) return;
        var extension = Path.GetExtension(attachment.FileName);
        try
        {
            if (string.IsNullOrWhiteSpace(extension))
            {
                var folderPicker = new FolderPicker();
                folderPicker.FileTypeFilter.Add("*");
                if (_ownerHandle != IntPtr.Zero)
                    InitializeWithWindow.Initialize(folderPicker, _ownerHandle);
                var folder = await folderPicker.PickSingleFolderAsync();
                if (folder is null) return;
                var folderDestination = await folder.CreateFileAsync(
                    attachment.FileName,
                    CreationCollisionOption.GenerateUniqueName);
                File.Copy(_attachmentStore.PayloadPath(attachment), folderDestination.Path, overwrite: true);
                return;
            }

            var picker = new FileSavePicker { SuggestedFileName = attachment.FileName };
            picker.FileTypeChoices.Add(AppText.Get("Attachment"), [extension]);
            if (_ownerHandle != IntPtr.Zero)
                InitializeWithWindow.Initialize(picker, _ownerHandle);
            var destination = await picker.PickSaveFileAsync();
            if (destination is null) return;
            File.Copy(_attachmentStore.PayloadPath(attachment), destination.Path, overwrite: true);
        }
        catch (Exception error)
        {
            ShowNotice(AppText.Format("AttachmentExportError", error.Message));
        }
    }

    private void HasDueDate_Changed(object sender, RoutedEventArgs e)
    {
        var enabled = HasDueDateBox.IsChecked == true;
        DueDatePicker.IsEnabled = enabled;
        DueTimePicker.IsEnabled = enabled;
    }

    private void ContentDialog_PrimaryButtonClick(
        ContentDialog sender,
        ContentDialogButtonClickEventArgs args)
    {
        var title = TitleBox.Text.Trim();
        var course = CourseBox.Text.Trim();
        if (title.Length == 0 || course.Length == 0)
        {
            ValidationText.Text = AppText.Get("TitleCourseRequired");
            ValidationText.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        if (title.Length > 255 || course.Length > 120)
        {
            ValidationText.Text = AppText.Get("TitleCourseTooLong");
            ValidationText.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        string? link;
        try
        {
            link = TaskLinkEditorPolicy.Resolve(_existing, _professionalMode, LinkBox.Text);
        }
        catch (ArgumentException error)
        {
            ValidationText.Text = LocalizeValidationError(error.Message);
            ValidationText.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        DateTimeOffset? dueDate;
        try
        {
            dueDate = ReadDueDate();
        }
        catch (ArgumentException error)
        {
            ValidationText.Text = LocalizeValidationError(error.Message);
            ValidationText.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        var draft = TaskEditorDraftProjection.Apply(
            _existing,
            course,
            title,
            dueDate,
            SelectedTag(StatusBox, TaskStatuses.Todo),
            _professionalMode ? Clean(DescriptionBox.Text) : _existing?.Description,
            _professionalMode
                ? SelectedTag(PriorityBox, TaskPriorities.Medium)
                : _existing?.Priority ?? TaskPriorities.Medium,
            link);
        draft.CourseId = _selectedCourseId;
        draft.ProjectId = _selectedProjectId;
        if (_derivedSubtaskStatus is not null)
        {
            draft.ProgressPercent = draft.Status == _derivedSubtaskStatus
                ? _derivedSubtaskProgress
                : null;
        }
        Result = draft;
    }

    private DateTimeOffset? ReadDueDate()
    {
        return TaskDueEditorProjection.Resolve(
            _existing,
            _loadedDueState,
            ReadDueControlState(),
            EffectiveTimeZone);
    }

    private TaskDueControlState ReadDueControlState() => new(
        HasDueDateBox.IsChecked == true,
        DueDatePicker.SelectedDate is { } selected
            ? DateOnly.FromDateTime(selected.Date)
            : null,
        DueTimePicker.Time);

    private TimeZoneInfo EffectiveTimeZone =>
        LocalWallTime.ResolveTimeZone(_existing?.TimezoneId);

    private void ShowNotice(string message)
    {
        ValidationText.Text = message;
        ValidationText.Visibility = Visibility.Visible;
        AutomationProperties.SetLiveSetting(
            ValidationText,
            AutomationLiveSetting.Assertive);
    }

    private static string LocalizeValidationError(string message) => message switch
    {
        "Source link must use http or https." => AppText.Get("SourceLinkHttpOnly"),
        "Due date and time are required." => AppText.Get("DueDateTimeRequired"),
        _ => message
    };

    private static string SelectedTag(ComboBox box, string fallback) =>
        (box.SelectedItem as ComboBoxItem)?.Tag as string ?? fallback;

    private static void SelectByTag(ComboBox box, string tag)
    {
        foreach (var item in box.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag as string, tag, StringComparison.Ordinal))
            {
                box.SelectedItem = item;
                return;
            }
        }
    }

    private static string? Clean(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
