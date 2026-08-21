using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Security.Cryptography;
using AssignmentNative.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage;
using Windows.Storage.Pickers;
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
    private readonly TaskDueControlState _loadedDueState;

    private IReadOnlyList<CourseItem> _courses = Array.Empty<CourseItem>();
    private IReadOnlyList<ProjectItem> _projects = Array.Empty<ProjectItem>();
    private IReadOnlyList<TagItem> _tags = Array.Empty<TagItem>();

    private long? _selectedCourseId;
    private long? _selectedProjectId;
    private readonly HashSet<long> _selectedTagIds = new();
    private bool _populating;

    public AssignmentDraft? Result { get; private set; }

    public IReadOnlyList<long> SelectedTagIds => _selectedTagIds.ToList();

    public TaskEditorDialog(
        CoreAssignmentItem? existing,
        bool professionalMode,
        ITaskOrganizationRepository organization,
        IntPtr ownerHandle = default)
    {
        InitializeComponent();
        _existing = existing;
        _professionalMode = professionalMode;
        _organization = organization;
        _ownerHandle = ownerHandle;

        Title = existing is null ? "Add assignment" : "Edit assignment";
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
            Content = "(Custom — type above)",
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
            Content = "(No project)",
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
    }

    private void RenderSubtasks(IReadOnlyList<SubtaskItem> subtasks)
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
                Content = "Remove",
                Tag = subtask,
                VerticalAlignment = VerticalAlignment.Center
            };
            remove.Click += RemoveSubtask_Click;

            SubtasksList.Children.Add(BuildRow(check, title, remove));
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
                Content = "Remove",
                Tag = reminder,
                VerticalAlignment = VerticalAlignment.Center
            };
            remove.Click += RemoveReminder_Click;
            RemindersList.Children.Add(BuildRow(label, remove));
        }
    }

    private void RenderAttachments(IReadOnlyList<AttachmentMetadataItem> attachments)
    {
        AttachmentsList.Children.Clear();
        foreach (var attachment in attachments)
        {
            var label = new TextBlock
            {
                Text = $"{attachment.FileName} ({attachment.ByteSize} bytes)",
                VerticalAlignment = VerticalAlignment.Center,
                TextWrapping = TextWrapping.Wrap
            };
            var remove = new Button
            {
                Content = "Remove",
                Tag = attachment,
                VerticalAlignment = VerticalAlignment.Center
            };
            remove.Click += RemoveAttachment_Click;
            AttachmentsList.Children.Add(BuildRow(label, remove));
        }
    }

    private static Grid BuildRow(UIElement primary, UIElement secondary)
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

    private static Grid BuildRow(UIElement leading, UIElement middle, UIElement trailing)
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
            : $" · repeats {reminder.RepeatRule}";
        return $"{local:g}{(reminder.IsEnabled ? "" : " (disabled)")}{repeat}";
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
        _selectedProjectId = CoursePickerBox.SelectedItem is ComboBoxItem item && item.Tag is long id
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
        }
        catch (Exception error)
        {
            ShowNotice($"The subtask could not be added: {error.Message}");
        }
    }

    private void SubtaskToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox { Tag: SubtaskItem subtask } check || _existing is null) return;
        var status = check.IsChecked == true ? TaskStatuses.Done : TaskStatuses.Todo;
        try
        {
            _organization.UpdateSubtask(subtask with { Status = status });
            RenderSubtasks(_organization.FetchSubtasks(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The subtask could not be updated: {error.Message}");
        }
    }

    private void RemoveSubtask_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SubtaskItem subtask } || _existing is null) return;
        try
        {
            _organization.DeleteSubtask(subtask.Id);
            RenderSubtasks(_organization.FetchSubtasks(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The subtask could not be removed: {error.Message}");
        }
    }

    private void AddReminder_Click(object sender, RoutedEventArgs e)
    {
        if (_existing is null || NewReminderDatePicker.SelectedDate is not { } date) return;
        var local = date.Date.Add(NewReminderTimePicker.Time);
        var trigger = new DateTimeOffset(local);
        try
        {
            _organization.CreateReminder(new ReminderDraft(
                _existing.Id,
                trigger,
                leadMinutes: 0,
                repeatRule: null,
                isEnabled: true));
            RenderReminders(_organization.FetchReminders(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The reminder could not be added: {error.Message}");
        }
    }

    private void RemoveReminder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ReminderItem reminder } || _existing is null) return;
        try
        {
            _organization.DeleteReminder(reminder.Id);
            RenderReminders(_organization.FetchReminders(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The reminder could not be removed: {error.Message}");
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
            ShowNotice($"The file picker could not be opened: {error.Message}");
            return;
        }
        if (file is null) return;

        try
        {
            var buffer = await FileIO.ReadBufferAsync(file);
            var bytes = buffer.ToArray();
            using var sha = SHA256.Create();
            var digest = string.Concat(sha.ComputeHash(bytes).Select(b => b.ToString("x2")));
            _organization.CreateAttachment(new AttachmentMetadataDraft(
                _existing.Id,
                file.Name,
                file.ContentType,
                bytes.LongLength,
                digest));
            RenderAttachments(_organization.FetchAttachments(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The attachment could not be added: {error.Message}");
        }
    }

    private void RemoveAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: AttachmentMetadataItem attachment } || _existing is null) return;
        try
        {
            _organization.DeleteAttachment(attachment.Id);
            RenderAttachments(_organization.FetchAttachments(_existing.Id));
        }
        catch (Exception error)
        {
            ShowNotice($"The attachment could not be removed: {error.Message}");
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
            ValidationText.Text = "Title and course are required.";
            ValidationText.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        if (title.Length > 255 || course.Length > 120)
        {
            ValidationText.Text = "Title or course is too long.";
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
            ValidationText.Text = error.Message;
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
            ValidationText.Text = error.Message;
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

    private async void ShowNotice(string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = "Assignment",
            Content = message,
            CloseButtonText = "OK"
        };
        await dialog.ShowAsync();
    }

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
