using AssignmentNative.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using CoreAssignmentItem = AssignmentNative.Core.AssignmentItem;

namespace AssignmentNative;

public sealed partial class TaskEditorDialog : ContentDialog
{
    private readonly CoreAssignmentItem? _existing;
    private readonly bool _professionalMode;
    private readonly TaskDueControlState _loadedDueState;

    public AssignmentDraft? Result { get; private set; }

    public TaskEditorDialog(CoreAssignmentItem? existing, bool professionalMode)
    {
        InitializeComponent();
        _existing = existing;
        _professionalMode = professionalMode;

        Title = existing is null ? "Add assignment" : "Edit assignment";
        ProfessionalFields.Visibility = professionalMode
            ? Visibility.Visible
            : Visibility.Collapsed;
        ModeHelpText.Visibility = !professionalMode && existing is not null
            ? Visibility.Visible
            : Visibility.Collapsed;

        Populate(existing);
        _loadedDueState = ReadDueControlState();
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

        Result = TaskEditorDraftProjection.Apply(
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
